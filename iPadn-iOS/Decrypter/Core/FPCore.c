//
//  FPCore.c
//  TetherDecrypt
//
//  On-device FairPlay decryption + minimal zip I/O.
//
//  Decryption is the private mremap_encrypted(2) syscall (XNU number 489):
//      int mremap_encrypted(caddr_t addr, size_t len,
//                           uint32_t cryptid, uint32_t cputype, uint32_t cpusubtype);
//  The trick is cryptid = 2 (CRYPTID_MODEL_ENCRYPTION): vm_map_apple_protected()
//  only requires VM_PROT_EXECUTE on the mapping when cryptid != 2, so a plain
//  PROT_READ mapping of an App Store binary gets decrypted by fairplayd instead
//  of being rejected as "not executable".
//

#include "FPCore.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__) || defined(FP_TESTING)
#include <dlfcn.h>
#include <sys/mman.h>
#endif
#if defined(__APPLE__)
#include <mach/mach.h>
#endif

#include <zlib.h>

#ifndef SYS_mremap_encrypted
#define SYS_mremap_encrypted 489
#endif

#define MH_MAGIC               0xfeedfaceu
#define MH_MAGIC_64            0xfeedfacfu
#define FAT_MAGIC              0xcafebabeu
#define FAT_MAGIC_64           0xcafebabfu
#define LC_ENCRYPTION_INFO     0x21u
#define LC_ENCRYPTION_INFO_64  0x2cu
#ifndef CPU_TYPE_ARM64
#define CPU_TYPE_ARM64         0x0100000cu
#endif

#define FP_MAX_FILE    (3ull * 1024 * 1024 * 1024)
#define FP_MAX_SLICES  8
#define FP_PATHMAX     4096

/* ------------------------------------------------------------------ utils */

static _Thread_local fp_progress_fn g_progress_fn;
static _Thread_local void *g_progress_ctx;

void fp_set_progress(fp_progress_fn fn, void *ctx)
{
    g_progress_fn = fn;
    g_progress_ctx = ctx;
}

void fp_log_append(char *log, size_t loglen, const char *fmt, ...)
{
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);

    if (g_progress_fn && line[0]) {
        g_progress_fn(line, g_progress_ctx);
    }
    if (!log || loglen == 0) return;
    size_t used = strlen(log);
    if (used + 2 >= loglen) return;
    strncat(log, line, loglen - used - 1);
}

static void set_err(char *err, size_t errlen, const char *fmt, ...)
{
    if (!err || errlen == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errlen, fmt, ap);
    va_end(ap);
}

static uint32_t rd32le(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint32_t rd32be(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint64_t rd64be(const uint8_t *p)
{
    return ((uint64_t)rd32be(p) << 32) | (uint64_t)rd32be(p + 4);
}

static uint16_t rd16le(const uint8_t *p)
{
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static void put16le(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
}

static void put32le(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

static int read_full(int fd, void *buf, size_t len, uint64_t off)
{
    uint8_t *p = (uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        ssize_t n = pread(fd, p + done, len - done, (off_t)(off + done));
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        done += (size_t)n;
    }
    return 0;
}

static int write_full(int fd, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, p + done, len - done);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) { errno = EIO; return -1; }
        done += (size_t)n;
    }
    return 0;
}

static int mkdir_p(const char *path)
{
    char tmp[FP_PATHMAX];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(tmp)) return -1;
    memcpy(tmp, path, len + 1);
    if (tmp[len - 1] == '/') tmp[len - 1] = '\0';

    for (char *p = tmp + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
        *p = '/';
    }
    return (mkdir(tmp, 0755) != 0 && errno != EEXIST) ? -1 : 0;
}

static int mkdir_parent(const char *file_path)
{
    char dir[FP_PATHMAX];
    size_t len = strlen(file_path);
    if (len == 0 || len >= sizeof(dir)) return -1;
    memcpy(dir, file_path, len + 1);
    char *slash = strrchr(dir, '/');
    if (!slash || slash == dir) return 0;
    *slash = '\0';
    return mkdir_p(dir);
}

/* ------------------------------------------------------------ Mach-O scan */

typedef struct {
    uint32_t cputype;
    uint32_t cpusubtype;
    uint64_t offset;
    uint64_t size;
    bool     encrypted;
    uint32_t cryptoff;
    uint32_t cryptsize;
    uint32_t cryptid;
    uint64_t cryptid_off;
    uint32_t signature_offset;
    uint32_t signature_size;
    uint64_t signature_fields_offset;
    uint64_t linkedit_vmsize_offset;
    uint64_t linkedit_filesize_offset;
    uint32_t linkedit_word_size;
    uint64_t commands_end;
} fp_slice;

static int parse_slice(int fd, uint64_t off, uint64_t avail, fp_slice *s)
{
    uint8_t hdr[32];
    memset(s, 0, sizeof(*s));
    if (avail < 28) return -1;
    if (read_full(fd, hdr, avail < sizeof(hdr) ? (size_t)avail : sizeof(hdr), off) != 0) return -1;

    uint32_t magic = rd32le(hdr);
    uint32_t hsize, ncmds, sizeofcmds;
    if (magic == MH_MAGIC_64) {
        hsize = 32;
    } else if (magic == MH_MAGIC) {
        hsize = 28;
    } else {
        return -1;
    }
    s->cputype = rd32le(hdr + 4);
    s->cpusubtype = rd32le(hdr + 8);
    ncmds = rd32le(hdr + 16);
    sizeofcmds = rd32le(hdr + 20);

    if (ncmds == 0 || sizeofcmds < 8) return -1;
    if (sizeofcmds > (64u << 20)) return -1;
    if ((uint64_t)hsize + sizeofcmds > avail) return -1;

    uint8_t *cmds = (uint8_t *)malloc(sizeofcmds);
    if (!cmds) return -1;
    if (read_full(fd, cmds, sizeofcmds, off + hsize) != 0) {
        free(cmds);
        return -1;
    }

    uint64_t cmd_off = 0;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (cmd_off + 8 > sizeofcmds) { free(cmds); return -1; }
        uint32_t cmd = rd32le(cmds + cmd_off);
        uint32_t size = rd32le(cmds + cmd_off + 4);
        if (size < 8 || cmd_off + size > sizeofcmds) { free(cmds); return -1; }
        if (cmd == LC_ENCRYPTION_INFO_64 || cmd == LC_ENCRYPTION_INFO) {
            if (size < 20) { free(cmds); return -1; }
            s->cryptoff = rd32le(cmds + cmd_off + 8);
            s->cryptsize = rd32le(cmds + cmd_off + 12);
            s->cryptid = rd32le(cmds + cmd_off + 16);
            s->cryptid_off = off + hsize + cmd_off + 16;
            s->encrypted = s->cryptid != 0;
        } else if (cmd == 0x1du) { /* LC_CODE_SIGNATURE */
            if (size < 16 || s->signature_fields_offset) { free(cmds); return -1; }
            s->signature_offset = rd32le(cmds + cmd_off + 8);
            s->signature_size = rd32le(cmds + cmd_off + 12);
            s->signature_fields_offset = hsize + cmd_off + 8;
        } else if (cmd == 0x19u || cmd == 0x1u) { /* LC_SEGMENT[_64] */
            uint32_t minimum = cmd == 0x19u ? 72 : 56;
            if (size < minimum) { free(cmds); return -1; }
            const char linkedit[16] = "__LINKEDIT";
            if (memcmp(cmds + cmd_off + 8, linkedit, sizeof(linkedit)) == 0) {
                if (s->linkedit_word_size) { free(cmds); return -1; }
                s->linkedit_word_size = cmd == 0x19u ? 8 : 4;
                s->linkedit_vmsize_offset = hsize + cmd_off + (cmd == 0x19u ? 32 : 28);
                s->linkedit_filesize_offset = hsize + cmd_off + (cmd == 0x19u ? 48 : 36);
            }
        }
        cmd_off += size;
    }
    free(cmds);

    s->offset = off;
    s->size = avail;
    s->commands_end = hsize + sizeofcmds;
    if (s->encrypted && (s->cryptsize == 0 || s->cryptoff < hsize + sizeofcmds ||
                         (uint64_t)s->cryptoff + s->cryptsize > avail)) return -1;
    if ((uint64_t)s->signature_offset + s->signature_size > avail) return -1;
    return 0;
}

static int scan_file(const char *path, fp_slice *slices, uint32_t max,
                     uint32_t *count, char *err, size_t errlen)
{
    *count = 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        set_err(err, errlen, "open(%s): %s", path, strerror(errno));
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        set_err(err, errlen, "fstat: %s", strerror(errno));
        close(fd);
        return -1;
    }
    uint64_t fsize = (uint64_t)st.st_size;
    if (fsize < 32) {
        close(fd);
        return 0;
    }

    uint8_t head[32];
    if (read_full(fd, head, sizeof(head), 0) != 0) {
        set_err(err, errlen, "read header: %s", strerror(errno));
        close(fd);
        return -1;
    }

    uint32_t magic = rd32le(head);
    if (magic == MH_MAGIC || magic == MH_MAGIC_64) {
        int rc = parse_slice(fd, 0, fsize, &slices[0]);
        if (rc == 0) *count = 1;
        else set_err(err, errlen, "invalid Mach-O commands or encrypted range");
        close(fd);
        return rc;
    }

    uint32_t bem = rd32be(head);
    if (bem != FAT_MAGIC && bem != FAT_MAGIC_64) {
        close(fd);
        return 0;                    /* not a Mach-O (resource file) */
    }

    bool fat64 = (bem == FAT_MAGIC_64);
    uint32_t nfat = rd32be(head + 4);
    if (nfat == 0 || nfat > max) {
        set_err(err, errlen, "unsupported fat architecture count %u (maximum %u)", nfat, max);
        close(fd);
        return -1;
    }
    uint32_t arch_size = fat64 ? 32 : 20;

    for (uint32_t i = 0; i < nfat; i++) {
        uint8_t arch[32];
        if (read_full(fd, arch, arch_size, 8 + (uint64_t)i * arch_size) != 0) goto invalid_fat;
        uint64_t off, size;
        if (fat64) {
            off = rd64be(arch + 8);
            size = rd64be(arch + 16);
        } else {
            off = rd32be(arch + 8);
            size = rd32be(arch + 12);
        }
        if (off < 8 + (uint64_t)nfat * arch_size || off >= fsize || size > fsize - off ||
            parse_slice(fd, off, size, &slices[*count]) != 0) goto invalid_fat;
        (*count)++;
    }
    close(fd);
    return 0;
invalid_fat:
    set_err(err, errlen, "invalid or truncated fat Mach-O slice");
    close(fd);
    return -1;
}

int fp_probe(const char *path, fp_info *out)
{
    memset(out, 0, sizeof(*out));
    fp_slice slices[FP_MAX_SLICES];
    uint32_t n = 0;
    char err[FP_ERRMAX] = {0};
    if (scan_file(path, slices, FP_MAX_SLICES, &n, err, sizeof(err)) != 0) return -1;
    if (n == 0) return 0;

    out->is_macho = true;
    out->is_fat = (n > 1);
    out->slices = n;
    for (uint32_t i = 0; i < n; i++) {
        if (slices[i].cputype == CPU_TYPE_ARM64) out->arm64_slices++;
        if (!out->encrypted && slices[i].encrypted) {
            out->encrypted = true;
            out->cputype = slices[i].cputype;
            out->cpusubtype = slices[i].cpusubtype;
            out->cryptoff = slices[i].cryptoff;
            out->cryptsize = slices[i].cryptsize;
            out->cryptid = slices[i].cryptid;
        }
    }
    return 0;
}

int fp_signing_layout(const char *path, fp_signing_slice *out, uint32_t capacity,
                      uint32_t *count, char *err, size_t errlen)
{
    *count = 0;
    fp_slice slices[FP_MAX_SLICES];
    uint32_t n = 0;
    if (scan_file(path, slices, FP_MAX_SLICES, &n, err, errlen) != 0) return -1;
    if (!n || n > capacity) { set_err(err, errlen, "unsupported signing slice inventory"); return -1; }
    for (uint32_t i = 0; i < n; i++) {
        const fp_slice *s = &slices[i];
        uint64_t prefix = s->signature_size ? s->signature_offset : s->size;
        if (s->signature_size && (prefix < s->commands_end ||
            (s->encrypted && prefix < (uint64_t)s->cryptoff + s->cryptsize) ||
            s->signature_fields_offset + 8 > prefix)) {
            set_err(err, errlen, "code signature overlaps load commands or encrypted pages"); return -1;
        }
        fp_signing_slice record = {
            .cputype = s->cputype, .cpusubtype = s->cpusubtype,
            .slice_offset = s->offset, .slice_size = s->size,
            .signature_offset = s->signature_size ? s->signature_offset : 0,
            .signature_size = s->signature_size,
            .signature_fields_offset = s->signature_size ? s->signature_fields_offset : 0,
            .linkedit_vmsize_offset = s->signature_size ? s->linkedit_vmsize_offset : 0,
            .linkedit_filesize_offset = s->signature_size ? s->linkedit_filesize_offset : 0,
            .linkedit_word_size = s->signature_size ? s->linkedit_word_size : 0
        };
        out[i] = record;
    }
    *count = n;
    return 0;
}

/* ---------------------------------------------------- FairPlay page reads */

/* FP_TESTING substitutes the kernel boundary only. Tests still exercise the
   production parser, mapping, page validation, file writes and ZIP functions. */
#if defined(FP_TESTING)
extern int fp_test_mremap(void *, size_t, uint32_t, uint32_t, uint32_t);
extern int fp_test_read(const void *, void *, size_t);
#endif

#if defined(__APPLE__) || defined(FP_TESTING)
typedef int (*mremap_fn_t)(void *, size_t, uint32_t, uint32_t, uint32_t);

static int call_mremap(void *addr, size_t len, uint32_t cpu, uint32_t subtype)
{
#if defined(FP_TESTING)
    return fp_test_mremap(addr, len, 2, cpu, subtype);
#else
    mremap_fn_t fn = (mremap_fn_t)dlsym(RTLD_DEFAULT, "mremap_encrypted");
    if (fn) return fn(addr, len, 2, cpu, subtype);
#if defined(__arm64__)
    /* The iOS arm64 syscall ABI puts the number in x16 and reports errno in
       x0 with carry set. libc's variadic syscall() is unavailable on iOS. */
    register uint64_t a0 __asm__("x0") = (uintptr_t)addr;
    register uint64_t a1 __asm__("x1") = len;
    register uint64_t a2 __asm__("x2") = 2;
    register uint64_t a3 __asm__("x3") = cpu;
    register uint64_t a4 __asm__("x4") = subtype;
    register uint64_t number __asm__("x16") = SYS_mremap_encrypted;
    uint64_t failed;
    __asm__ volatile("svc #0x80\n\tcset %0, cs"
                     : "=r"(failed), "+r"(a0), "+r"(a1)
                     : "r"(a2), "r"(a3), "r"(a4), "r"(number)
                     : "memory", "cc");
    if (failed) { errno = (int)a0; return -1; }
    return (int)a0;
#else
    errno = ENOTSUP;
    return -1;
#endif
#endif
}

static int read_page(const void *src, void *dst, size_t len,
                      char *err, size_t errlen)
{
#if defined(FP_TESTING)
    if (fp_test_read(src, dst, len) == 0) return 0;
    set_err(err, errlen, "decrypted page could not be read (test page-in failure)");
#else
    /* A successful remap does not guarantee a successful lazy page-in.
       memcpy() here can kill the app with SIGBUS. Ask Mach to read our own
       mapping and require every requested byte instead. */
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
        (vm_address_t)(uintptr_t)src, (vm_size_t)len,
        (vm_address_t)(uintptr_t)dst, &got);
    if (kr == KERN_SUCCESS && got == len) return 0;
    set_err(err, errlen, "decrypted page-in failed (Mach %d, %llu/%zu bytes)",
            kr, (unsigned long long)got, len);
#endif
    return -1;
}

static int write_at(int fd, const void *buf, size_t len, uint64_t offset)
{
    const uint8_t *p = buf;
    size_t done = 0;
    while (done < len) {
        ssize_t n = pwrite(fd, p + done, len - done, (off_t)(offset + done));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (n == 0) errno = EIO; return -1; }
        done += (size_t)n;
    }
    return 0;
}

static int copy_fd(int in, int out, uint64_t size)
{
    uint8_t buf[65536];
    for (uint64_t offset = 0; offset < size; ) {
        size_t n = size - offset < sizeof(buf) ? (size_t)(size - offset) : sizeof(buf);
        if (read_full(in, buf, n, offset) != 0 || write_full(out, buf, n) != 0) return -1;
        offset += n;
    }
    return 0;
}

static int decrypt_slice(int fd, int out, const fp_slice *s, bool add_signature,
                          char *log, size_t loglen, char *err, size_t errlen)
{
    const size_t page = (size_t)getpagesize();
    const size_t window = (size_t)16 << 20;
    if (s->offset % page || s->cryptoff % page) {
        set_err(err, errlen, "slice/encryption offset is not aligned to this device's %zu-byte pages", page);
        return -1;
    }

#if defined(__APPLE__) && defined(F_ADDFILESIGS_RETURN)
    if (add_signature && s->signature_size) {
        fsignatures_t sig = {
            .fs_file_start = (off_t)s->offset,
            .fs_blob_start = (void *)(uintptr_t)s->signature_offset,
            .fs_blob_size = s->signature_size
        };
        if (fcntl(fd, F_ADDFILESIGS_RETURN, &sig) == -1) {
            fp_log_append(log, loglen, "    signature registration: %s\n", strerror(errno));
        }
    }
#else
    (void)add_signature;
#endif

    /* Map this slice at its actual file offset, as the FairPlay interface
       expects. Each attempt gets a fresh mapping; never remap a page twice. */
    uint8_t *map = mmap(NULL, (size_t)s->size, PROT_READ, MAP_PRIVATE, fd, (off_t)s->offset);
    if (map == MAP_FAILED) { set_err(err, errlen, "mmap: %s", strerror(errno)); return -1; }
    size_t capacity = s->cryptsize < window ? s->cryptsize : window;
    uint8_t *before = malloc(capacity), *after = malloc(capacity);
    int rc = -1;
    bool changed = false;
    if (!before || !after) {
        set_err(err, errlen, "cannot allocate the decryption window");
        goto done;
    }

    for (uint64_t offset = 0; offset < s->cryptsize; ) {
        size_t n = s->cryptsize - offset < capacity ? (size_t)(s->cryptsize - offset) : capacity;
        uint64_t file_offset = s->offset + s->cryptoff + offset;
        if (read_full(fd, before, n, file_offset) != 0) {
            set_err(err, errlen, "read ciphertext: %s", strerror(errno));
            goto done;
        }
        errno = 0;
        if (call_mremap(map + s->cryptoff + offset, n, s->cputype, s->cpusubtype) != 0) {
            int saved = errno;
            set_err(err, errlen,
                "R/cryptid2 failed at 0x%llx: errno %d (%s). "
                "Check the installed helper's SC_Info, the IPA/account match, and OS compatibility; "
                "this error alone does not prove an account mismatch.",
                (unsigned long long)(s->cryptoff + offset), saved, strerror(saved));
            goto done;
        }
        for (size_t p = 0; p < n; p += page) {
            size_t count = n - p < page ? n - p : page;
            if (read_page(map + s->cryptoff + offset + p, after + p, count, err, errlen) != 0) {
                fp_log_append(log, loglen, "    failed page at file offset 0x%llx\n",
                              (unsigned long long)(file_offset + p));
                goto done;
            }
        }
        if (memcmp(before, after, n) != 0) changed = true;
        if (write_at(out, after, n, file_offset) != 0) {
            set_err(err, errlen, "write plaintext: %s", strerror(errno));
            goto done;
        }
        offset += n;
        fp_log_append(log, loglen, "    R/cryptid2: %llu/%u bytes read and written\n",
                      (unsigned long long)offset, s->cryptsize);
    }

    /* Never clear cryptid on the basis of entropy, or just a successful syscall.
       All pages must be readable and the ciphertext must actually change. */
    if (!changed) {
        set_err(err, errlen, "remap returned unchanged bytes; refusing to clear cryptid");
        goto done;
    }
    const uint8_t zero[4] = {0};
    if (write_at(out, zero, sizeof(zero), s->cryptid_off) != 0) {
        set_err(err, errlen, "write cryptid: %s", strerror(errno));
        goto done;
    }
    rc = 0;
done:
    free(before);
    free(after);
    munmap(map, (size_t)s->size);
    return rc;
}
#endif

static int fp_decrypt_impl(const char *src, const char *dst,
                           char *log, size_t loglen, char *err, size_t errlen)
{
    if (log && loglen) log[0] = '\0';
    if (err && errlen) err[0] = '\0';
    fp_slice slices[FP_MAX_SLICES];
    uint32_t count = 0, encrypted = 0;
    if (scan_file(src, slices, FP_MAX_SLICES, &count, err, errlen) != 0) return -1;
    if (count == 0) { set_err(err, errlen, "not a supported Mach-O"); return -1; }
    for (uint32_t i = 0; i < count; i++) {
        if (!slices[i].encrypted) continue;
        encrypted++;
        if (slices[i].cputype != CPU_TYPE_ARM64) {
            set_err(err, errlen, "encrypted architecture 0x%x is unsupported; refusing a partially decrypted binary",
                    slices[i].cputype);
            return -1;
        }
    }
    if (!encrypted && strcmp(src, dst) == 0) return 0;
#if !defined(__APPLE__) && !defined(FP_TESTING)
    set_err(err, errlen, "FairPlay decryption requires an Apple device");
    return -1;
#else
    int fd = open(src, O_RDONLY), out = -1, rc = -1;
    char temporary[FP_PATHMAX] = {0};
    struct stat st;
    if (fd < 0) { set_err(err, errlen, "open: %s", strerror(errno)); return -1; }
    if (fstat(fd, &st) != 0 || st.st_size <= 0 || (uint64_t)st.st_size > FP_MAX_FILE) {
        set_err(err, errlen, "invalid or unsupported source file size");
        goto done;
    }
    if (snprintf(temporary, sizeof(temporary), "%s.fpdec.XXXXXX", dst) >= (int)sizeof(temporary)) {
        temporary[0] = '\0';
        set_err(err, errlen, "destination path is too long");
        goto done;
    }
    out = mkstemp(temporary);
    if (out < 0 || copy_fd(fd, out, (uint64_t)st.st_size) != 0) {
        set_err(err, errlen, "create plaintext copy: %s", strerror(errno));
        goto done;
    }
    for (uint32_t i = 0; i < count; i++) {
        const fp_slice *s = &slices[i];
        if (!s->encrypted) continue;
        fp_log_append(log, loglen, "  slice[%u] cpu=0x%x/0x%x offset=0x%llx cryptoff=0x%x size=0x%x\n",
                      i, s->cputype, s->cpusubtype, (unsigned long long)s->offset,
                      s->cryptoff, s->cryptsize);
        if (decrypt_slice(fd, out, s, false, log, loglen, err, errlen) != 0) {
            fp_log_append(log, loglen, "    %s\n", err ? err : "decryption failed");
#if defined(__APPLE__) && defined(F_ADDFILESIGS_RETURN)
            if (!s->signature_size ||
                decrypt_slice(fd, out, s, true, log, loglen, err, errlen) != 0) goto done;
#else
            goto done;
#endif
        }
    }
    if (fchmod(out, st.st_mode & 0777) != 0) {
        set_err(err, errlen, "set output permissions: %s", strerror(errno));
        goto done;
    }
    if (close(out) != 0) {
        out = -1;
        set_err(err, errlen, "close plaintext copy: %s", strerror(errno));
        goto done;
    }
    out = -1;
    if (rename(temporary, dst) != 0) {
        set_err(err, errlen, "replace output: %s", strerror(errno));
        goto done;
    }
    temporary[0] = '\0';
    if (err && errlen) err[0] = '\0';
    rc = 0;
done:
    if (out >= 0) close(out);
    if (temporary[0]) unlink(temporary);
    close(fd);
    return rc;
#endif
}

int fp_decrypt_file(const char *path, char *log, size_t loglen, char *err, size_t errlen)
{
    return fp_decrypt_impl(path, path, log, loglen, err, errlen);
}

int fp_decrypt_copy(const char *src, const char *dst,
                    char *log, size_t loglen, char *err, size_t errlen)
{
    return fp_decrypt_impl(src, dst, log, loglen, err, errlen);
}

/* ---------------------------------------------------------------- zip read */

#define ZIP_LOCAL_SIG   0x04034b50u
#define ZIP_CENTRAL_SIG 0x02014b50u
#define ZIP_EOCD_SIG    0x06054b50u

static bool entry_name_safe(const char *name)
{
    if (!name || !*name) return false;
    if (name[0] == '/' || name[0] == '\\') return false;
    if (strchr(name, ':') || strchr(name, '\\')) return false;
    const char *p = name;
    for (;;) {
        const char *slash = strchr(p, '/');
        size_t len = slash ? (size_t)(slash - p) : strlen(p);
        if (len == 0) return false;
        if (len == 1 && p[0] == '.') return false;
        if (len == 2 && p[0] == '.' && p[1] == '.') return false;
        if (!slash) break;
        p = slash + 1;
        if (!*p) break; /* a directory's final slash is allowed */
    }
    return true;
}

static bool link_target_safe(const char *name, const char *target)
{
    if (!target[0] || target[0] == '/' || strchr(target, '\\') || strchr(target, ':')) return false;
    int depth = 0;
    for (const char *p = name; *p; p++) if (*p == '/') depth++;
    for (const char *p = target; *p; ) {
        const char *slash = strchr(p, '/');
        size_t n = slash ? (size_t)(slash - p) : strlen(p);
        if (n == 2 && p[0] == '.' && p[1] == '.') { if (--depth < 0) return false; }
        else if (n && !(n == 1 && p[0] == '.')) depth++;
        if (!slash) break;
        p = slash + 1;
    }
    return true;
}

/* Do not write an archive entry through a symlink created by an earlier entry. */
static int safe_parents(const char *root, const char *name)
{
    char path[FP_PATHMAX];
    if (snprintf(path, sizeof(path), "%s/%s", root, name) >= (int)sizeof(path)) return -1;
    for (char *p = path + strlen(root) + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        struct stat st;
        if (lstat(path, &st) == 0) {
            if (!S_ISDIR(st.st_mode)) { *p = '/'; errno = EINVAL; return -1; }
        } else if (errno != ENOENT || mkdir(path, 0755) != 0) {
            *p = '/'; return -1;
        }
        *p = '/';
    }
    return 0;
}

static int check_links(const char *root, const char *directory, char *err, size_t errlen)
{
    char resolved_root[FP_PATHMAX];
    if (!realpath(root, resolved_root)) return -1;
    DIR *dir = opendir(directory);
    if (!dir) { set_err(err, errlen, "cannot inspect extracted links"); return -1; }
    int rc = 0;
    struct dirent *entry;
    while (rc == 0 && (entry = readdir(dir)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        char path[FP_PATHMAX];
        if (snprintf(path, sizeof(path), "%s/%s", directory, entry->d_name) >= (int)sizeof(path)) {
            set_err(err, errlen, "link path is too long"); rc = -1; break;
        }
        struct stat st;
        if (lstat(path, &st) != 0) { set_err(err, errlen, "cannot inspect %s", path); rc = -1; break; }
        if (S_ISLNK(st.st_mode)) {
            char resolved[FP_PATHMAX];
            size_t length = strlen(resolved_root);
            if (!realpath(path, resolved) || strncmp(resolved, resolved_root, length) != 0 ||
                (resolved[length] && resolved[length] != '/')) {
                set_err(err, errlen, "broken or escaping symbolic link: %s", path); rc = -1;
            }
        } else if (S_ISDIR(st.st_mode)) {
            rc = check_links(root, path, err, errlen);
        }
    }
    closedir(dir);
    return rc;
}

static int copy_or_inflate(int fd, uint64_t data_off, uint16_t method,
                           uint32_t csize, uint32_t usize,
                           const char *dest, uint16_t mode, uint32_t expect_crc,
                           char *err, size_t errlen)
{
    int out = open(dest, O_WRONLY | O_CREAT | O_TRUNC, (mode & 0777) ? (mode_t)(mode & 0777) : 0644);
    if (out < 0) {
        set_err(err, errlen, "create %s: %s", dest, strerror(errno));
        return -1;
    }

    uint8_t inbuf[65536];
    uint8_t outbuf[65536];
    uint32_t crc = crc32(0L, Z_NULL, 0);
    uint64_t written = 0;
    uint64_t offset = data_off;
    uint32_t remaining = csize;
    int rc = 0;

    if (method == 0) {
        while (remaining > 0 && rc == 0) {
            size_t chunk = remaining < sizeof(inbuf) ? remaining : sizeof(inbuf);
            if (read_full(fd, inbuf, chunk, offset) != 0) {
                set_err(err, errlen, "short read in %s", dest);
                rc = -1;
                break;
            }
            crc = crc32(crc, inbuf, (uInt)chunk);
            if (write_full(out, inbuf, chunk) != 0) {
                set_err(err, errlen, "write %s: %s", dest, strerror(errno));
                rc = -1;
                break;
            }
            offset += chunk;
            remaining -= (uint32_t)chunk;
            written += chunk;
        }
    } else if (method == 8) {
        z_stream zs;
        memset(&zs, 0, sizeof(zs));
        if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) {
            set_err(err, errlen, "inflateInit2 failed");
            close(out);
            return -1;
        }
        int zr = Z_OK;
        while (remaining > 0 && zr != Z_STREAM_END && rc == 0) {
            size_t chunk = remaining < sizeof(inbuf) ? remaining : sizeof(inbuf);
            if (read_full(fd, inbuf, chunk, offset) != 0) {
                set_err(err, errlen, "short read in %s", dest);
                rc = -1;
                break;
            }
            offset += chunk;
            remaining -= (uint32_t)chunk;

            zs.next_in = inbuf;
            zs.avail_in = (uInt)chunk;
            while (zs.avail_in > 0 && zr != Z_STREAM_END && rc == 0) {
                zs.next_out = outbuf;
                zs.avail_out = (uInt)sizeof(outbuf);
                zr = inflate(&zs, Z_NO_FLUSH);
                if (zr != Z_OK && zr != Z_STREAM_END && zr != Z_BUF_ERROR) {
                    set_err(err, errlen, "inflate(%s): %d", dest, zr);
                    rc = -1;
                    break;
                }
                size_t have = sizeof(outbuf) - zs.avail_out;
                if (have) {
                    crc = crc32(crc, outbuf, (uInt)have);
                    if (write_full(out, outbuf, have) != 0) {
                        set_err(err, errlen, "write %s: %s", dest, strerror(errno));
                        rc = -1;
                        break;
                    }
                    written += have;
                }
                if (zr == Z_BUF_ERROR && zs.avail_in == 0 && have == 0) break;
                if (written > usize) {           /* corrupt entry guard */
                    set_err(err, errlen, "%s inflates past its declared size", dest);
                    rc = -1;
                    break;
                }
            }
        }
        if (rc == 0 && zr != Z_STREAM_END) {
            set_err(err, errlen, "truncated deflate stream in %s", dest);
            rc = -1;
        }
        inflateEnd(&zs);
    } else {
        set_err(err, errlen, "unsupported compression method %u for %s", method, dest);
        rc = -1;
    }

    close(out);
    if (rc != 0) return -1;
    if (written != usize) {
        set_err(err, errlen, "%s: size mismatch (%llu != %u)", dest,
                (unsigned long long)written, usize);
        return -1;
    }
    if (crc != expect_crc) {
        set_err(err, errlen, "%s: crc mismatch", dest);
        return -1;
    }
    return 0;
}

int fp_unzip(const char *zip_path, const char *dest_dir, char *err, size_t errlen)
{
    int fd = open(zip_path, O_RDONLY);
    if (fd < 0) {
        set_err(err, errlen, "open %s: %s", zip_path, strerror(errno));
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        set_err(err, errlen, "fstat: %s", strerror(errno));
        close(fd);
        return -1;
    }
    uint64_t fsize = (uint64_t)st.st_size;
    if (fsize < 22) {
        set_err(err, errlen, "%s is too small to be a zip", zip_path);
        close(fd);
        return -1;
    }

    size_t tail_len = fsize < 66000 ? (size_t)fsize : 66000;
    uint8_t *tail = (uint8_t *)malloc(tail_len);
    if (!tail) {
        set_err(err, errlen, "oom");
        close(fd);
        return -1;
    }
    if (read_full(fd, tail, tail_len, fsize - tail_len) != 0) {
        set_err(err, errlen, "read tail: %s", strerror(errno));
        free(tail);
        close(fd);
        return -1;
    }

    ssize_t eocd = -1;
    for (ssize_t i = (ssize_t)tail_len - 22; i >= 0; i--) {
        if (rd32le(tail + i) == ZIP_EOCD_SIG) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) {
        set_err(err, errlen, "no end-of-central-directory record (not a zip?)");
        free(tail);
        close(fd);
        return -1;
    }

    uint32_t n_entries = rd16le(tail + eocd + 10);
    uint32_t cd_size = rd32le(tail + eocd + 12);
    uint32_t cd_off = rd32le(tail + eocd + 16);
    free(tail);

    if (cd_off == 0xFFFFFFFFu || cd_size == 0xFFFFFFFFu || n_entries == 0xFFFFu) {
        set_err(err, errlen, "zip64 archives are not supported");
        close(fd);
        return -1;
    }
    if (mkdir_p(dest_dir) != 0) {
        set_err(err, errlen, "mkdir %s: %s", dest_dir, strerror(errno));
        close(fd);
        return -1;
    }

    uint64_t pos = cd_off;
    uint64_t cd_end = (uint64_t)cd_off + cd_size;
    int rc = 0;
    if (cd_end > fsize) { set_err(err, errlen, "central directory extends past archive"); close(fd); return -1; }

    for (uint32_t i = 0; i < n_entries && rc == 0; i++) {
        uint8_t cd[46];
        if (pos + 46 > cd_end || pos + 46 > fsize || read_full(fd, cd, 46, pos) != 0) {
            set_err(err, errlen, "truncated central directory at entry %u", i);
            rc = -1;
            break;
        }
        if (rd32le(cd) != ZIP_CENTRAL_SIG) {
            set_err(err, errlen, "bad central directory signature at entry %u", i);
            rc = -1;
            break;
        }

        uint16_t method = rd16le(cd + 10);
        uint32_t crc = rd32le(cd + 16);
        uint32_t csize = rd32le(cd + 20);
        uint32_t usize = rd32le(cd + 24);
        uint16_t nlen = rd16le(cd + 28);
        uint16_t elen = rd16le(cd + 30);
        uint16_t clen = rd16le(cd + 32);
        uint32_t xattr = rd32le(cd + 38);
        uint32_t lho = rd32le(cd + 42);
        uint16_t unix_mode = (uint16_t)((xattr >> 16) & 0xFFFF);

        if (nlen == 0 || nlen > 1024) {
            set_err(err, errlen, "suspicious entry name length %u", nlen);
            rc = -1;
            break;
        }
        char name[1025];
        if (read_full(fd, name, nlen, pos + 46) != 0) {
            set_err(err, errlen, "short read of entry name");
            rc = -1;
            break;
        }
        name[nlen] = '\0';
        pos += 46 + nlen + elen + clen;
        if (pos > cd_end || strlen(name) != nlen) {
            set_err(err, errlen, "invalid central directory entry"); rc = -1; break;
        }

        if (strncmp(name, "__MACOSX/", 9) == 0) continue;
        if (!entry_name_safe(name) || safe_parents(dest_dir, name) != 0) {
            set_err(err, errlen, "unsafe archive path: %s", name); rc = -1; break;
        }
        bool is_link = (unix_mode & 0xF000) == 0xA000;
        if (rd16le(cd + 8) & 1) { set_err(err, errlen, "password-encrypted ZIP entries are unsupported"); rc = -1; break; }

        size_t nl = strlen(name);
        bool is_dir = (nl > 0 && name[nl - 1] == '/');
        char dest[FP_PATHMAX];
        if (snprintf(dest, sizeof(dest), "%s/%s", dest_dir, name) >= (int)sizeof(dest)) {
            set_err(err, errlen, "path too long: %s", name);
            rc = -1;
            break;
        }
        if (is_dir) {
            if (mkdir_p(dest) != 0 && errno != EEXIST) {
                set_err(err, errlen, "mkdir %s: %s", dest, strerror(errno));
                rc = -1;
            }
            continue;
        }
        struct stat existing;
        if (lstat(dest, &existing) == 0 && S_ISLNK(existing.st_mode)) {
            set_err(err, errlen, "duplicate entry would overwrite a symlink: %s", name); rc = -1; break;
        }
        if (mkdir_parent(dest) != 0) {
            set_err(err, errlen, "mkdir -p for %s: %s", dest, strerror(errno));
            rc = -1;
            break;
        }

        uint8_t lh[30];
        if (read_full(fd, lh, 30, lho) != 0 || rd32le(lh) != ZIP_LOCAL_SIG) {
            set_err(err, errlen, "bad local header for %s", name);
            rc = -1;
            break;
        }
        uint64_t data_off = (uint64_t)lho + 30 + rd16le(lh + 26) + rd16le(lh + 28);
        if (data_off + csize > fsize) {
            set_err(err, errlen, "%s extends past the end of the archive", name);
            rc = -1;
            break;
        }

        uint16_t fmode = (unix_mode & 0777) ? (uint16_t)(unix_mode & 0777) : 0644;
        if (copy_or_inflate(fd, data_off, method, csize, usize, dest, fmode, crc, err, errlen) != 0) {
            rc = -1;
        } else if (is_link) {
            char target[FP_PATHMAX];
            int link_fd = open(dest, O_RDONLY);
            if (link_fd < 0 || usize == 0 || usize >= sizeof(target) ||
                read_full(link_fd, target, usize, 0) != 0) {
                if (link_fd >= 0) close(link_fd);
                set_err(err, errlen, "invalid symbolic link: %s", name); rc = -1; break;
            }
            close(link_fd);
            target[usize] = '\0';
            if (strlen(target) != usize || !link_target_safe(name, target) ||
                unlink(dest) != 0 || symlink(target, dest) != 0) {
                set_err(err, errlen, "unsafe or invalid symbolic link: %s", name); rc = -1; break;
            }
        }
    }

    close(fd);
    if (rc == 0) rc = check_links(dest_dir, dest_dir, err, errlen);
    return rc;
}

/* --------------------------------------------------------------- zip write */

#define ZIP_MAX_ENTRIES 65534

typedef struct {
    char    *name;
    uint32_t crc;
    uint32_t size;
    uint32_t offset;
    uint16_t mode;
    char    *link;
} zip_out_entry;

static int crc_of_file(const char *path, uint32_t *crc_out, uint32_t *size_out,
                       char *err, size_t errlen)
{
    int f = open(path, O_RDONLY);
    if (f < 0) {
        set_err(err, errlen, "open %s: %s", path, strerror(errno));
        return -1;
    }
    uint8_t buf[65536];
    uint32_t crc = crc32(0L, Z_NULL, 0);
    uint64_t total = 0;
    ssize_t n;
    while ((n = read(f, buf, sizeof(buf))) > 0) {
        crc = crc32(crc, buf, (uInt)n);
        total += (uint64_t)n;
    }
    close(f);
    if (n < 0) {
        set_err(err, errlen, "read %s: %s", path, strerror(errno));
        return -1;
    }
    if (total > 0xFFFFFFF0ull) {
        set_err(err, errlen, "%s is too large for a non-zip64 archive", path);
        return -1;
    }
    *crc_out = crc;
    *size_out = (uint32_t)total;
    return 0;
}

static int collect_walk(const char *root, const char *rel, zip_out_entry *entries,
                        uint32_t *count, char *err, size_t errlen)
{
    char dirpath[FP_PATHMAX];
    if (rel && *rel) snprintf(dirpath, sizeof(dirpath), "%s/%s", root, rel);
    else snprintf(dirpath, sizeof(dirpath), "%s", root);

    DIR *d = opendir(dirpath);
    if (!d) {
        set_err(err, errlen, "opendir %s: %s", dirpath, strerror(errno));
        return -1;
    }

    int rc = 0;
    struct dirent *de;
    while (rc == 0 && (de = readdir(d)) != NULL) {
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0) continue;

        char full[FP_PATHMAX], relname[FP_PATHMAX];
        if (rel && *rel) snprintf(relname, sizeof(relname), "%s/%s", rel, de->d_name);
        else snprintf(relname, sizeof(relname), "%s", de->d_name);
        snprintf(full, sizeof(full), "%s/%s", root, relname);

        struct stat st;
        if (lstat(full, &st) != 0) {
            set_err(err, errlen, "lstat %s: %s", full, strerror(errno));
            rc = -1;
            break;
        }
        if (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode)) continue;
        if (*count >= ZIP_MAX_ENTRIES) {
            set_err(err, errlen, "more than %d entries", ZIP_MAX_ENTRIES);
            rc = -1;
            break;
        }

        zip_out_entry *e = &entries[*count];
        if (S_ISLNK(st.st_mode)) {
            char target[FP_PATHMAX];
            ssize_t n = readlink(full, target, sizeof(target) - 1);
            if (n < 0 || n >= (ssize_t)sizeof(target) - 1) {
                set_err(err, errlen, "cannot read symlink %s", full); rc = -1; break;
            }
            target[n] = '\0';
            if (!link_target_safe(relname, target)) {
                set_err(err, errlen, "unsafe symlink %s", relname); rc = -1; break;
            }
            e->link = strdup(target);
            if (!e->link) { set_err(err, errlen, "oom"); rc = -1; break; }
            e->size = (uint32_t)n;
            e->crc = crc32(0L, (const Bytef *)target, (uInt)n);
        } else if (S_ISDIR(st.st_mode)) {
            size_t n = strlen(relname);
            if (n + 1 >= sizeof(relname)) { set_err(err, errlen, "path too long"); rc = -1; break; }
            relname[n] = '/'; relname[n + 1] = '\0';
        } else if (crc_of_file(full, &e->crc, &e->size, err, errlen) != 0) {
            rc = -1;
            break;
        }
        e->name = strdup(relname);
        if (!e->name) {
            set_err(err, errlen, "oom");
            free(e->link); e->link = NULL;
            rc = -1;
            break;
        }
        e->mode = (uint16_t)(st.st_mode & 0170777);
        e->offset = 0;
        (*count)++;
        if (S_ISDIR(st.st_mode)) {
            relname[strlen(relname) - 1] = '\0';
            rc = collect_walk(root, relname, entries, count, err, errlen);
        }
    }
    closedir(d);
    return rc;
}

int fp_zip_dir(const char *src_dir, const char *zip_path, char *err, size_t errlen)
{
    if (check_links(src_dir, src_dir, err, errlen) != 0) return -1;
    zip_out_entry *entries = (zip_out_entry *)calloc(ZIP_MAX_ENTRIES, sizeof(zip_out_entry));
    if (!entries) {
        set_err(err, errlen, "oom");
        return -1;
    }

    uint32_t count = 0;
    int rc = collect_walk(src_dir, "", entries, &count, err, errlen);

    int fd = -1;
    if (rc == 0) {
        fd = open(zip_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) {
            set_err(err, errlen, "create %s: %s", zip_path, strerror(errno));
            rc = -1;
        }
    }

    /* Local headers + stored data. */
    uint64_t pos = 0;
    uint8_t buf[65536];
    for (uint32_t i = 0; rc == 0 && i < count; i++) {
        zip_out_entry *e = &entries[i];
        size_t nl = strlen(e->name);

        uint8_t lh[30] = {0};
        put32le(lh, ZIP_LOCAL_SIG);
        put16le(lh + 4, 20);
        put16le(lh + 6, 0x0800);            /* UTF-8 names */
        put16le(lh + 8, 0);                 /* stored */
        put16le(lh + 10, 0);                /* mod time */
        put16le(lh + 12, 0x0021);           /* mod date: 1980-01-01 */
        put32le(lh + 14, e->crc);
        put32le(lh + 18, e->size);
        put32le(lh + 22, e->size);
        put16le(lh + 26, (uint16_t)nl);
        put16le(lh + 28, 0);

        e->offset = (uint32_t)pos;
        if (pos > 0xFFFFFFF0ull) {
            set_err(err, errlen, "archive would exceed the non-zip64 limit");
            rc = -1;
            break;
        }
        if (write_full(fd, lh, sizeof(lh)) != 0 || write_full(fd, e->name, nl) != 0) {
            set_err(err, errlen, "write %s: %s", zip_path, strerror(errno));
            rc = -1;
            break;
        }
        pos += sizeof(lh) + nl;

        if (e->link) {
            if (write_full(fd, e->link, e->size) != 0) {
                set_err(err, errlen, "write symlink: %s", strerror(errno)); rc = -1; break;
            }
            pos += e->size;
            continue;
        }
        if (S_ISDIR(e->mode)) continue;

        char full[FP_PATHMAX];
        snprintf(full, sizeof(full), "%s/%s", src_dir, e->name);
        int in = open(full, O_RDONLY);
        if (in < 0) {
            set_err(err, errlen, "reopen %s: %s", full, strerror(errno));
            rc = -1;
            break;
        }
        uint64_t copied = 0;
        ssize_t n;
        while ((n = read(in, buf, sizeof(buf))) > 0) {
            if (write_full(fd, buf, (size_t)n) != 0) {
                set_err(err, errlen, "write %s: %s", zip_path, strerror(errno));
                rc = -1;
                break;
            }
            copied += (uint64_t)n;
        }
        close(in);
        if (rc != 0) break;
        if (copied != e->size) {
            set_err(err, errlen, "%s changed size while packing", full);
            rc = -1;
            break;
        }
        pos += e->size;
    }

    /* Central directory. */
    uint64_t cd_start = pos;
    for (uint32_t i = 0; rc == 0 && i < count; i++) {
        zip_out_entry *e = &entries[i];
        size_t nl = strlen(e->name);
        uint8_t cd[46] = {0};
        put32le(cd, ZIP_CENTRAL_SIG);
        put16le(cd + 4, 0x031E);            /* made by unix 3.0 */
        put16le(cd + 6, 20);
        put16le(cd + 8, 0x0800);
        put16le(cd + 10, 0);
        put16le(cd + 12, 0);                /* mod time */
        put16le(cd + 14, 0x0021);           /* mod date */
        put32le(cd + 16, e->crc);
        put32le(cd + 20, e->size);
        put32le(cd + 24, e->size);
        put16le(cd + 28, (uint16_t)nl);
        put16le(cd + 30, 0);
        put16le(cd + 32, 0);
        put16le(cd + 34, 0);
        put16le(cd + 36, 0);
        put32le(cd + 38, ((uint32_t)e->mode << 16) | (S_ISDIR(e->mode) ? 0x10u : 0));
        put32le(cd + 42, e->offset);
        if (write_full(fd, cd, sizeof(cd)) != 0 || write_full(fd, e->name, nl) != 0) {
            set_err(err, errlen, "write central directory: %s", strerror(errno));
            rc = -1;
            break;
        }
        pos += sizeof(cd) + nl;
    }

    if (rc == 0) {
        uint8_t eocd[22] = {0};
        put32le(eocd, ZIP_EOCD_SIG);
        put16le(eocd + 8, (uint16_t)count);
        put16le(eocd + 10, (uint16_t)count);
        put32le(eocd + 12, (uint32_t)(pos - cd_start));
        put32le(eocd + 16, (uint32_t)cd_start);
        if (write_full(fd, eocd, sizeof(eocd)) != 0) {
            set_err(err, errlen, "write EOCD: %s", strerror(errno));
            rc = -1;
        }
    }

    if (fd >= 0) close(fd);
    for (uint32_t i = 0; i < count; i++) { free(entries[i].name); free(entries[i].link); }
    free(entries);
    return rc;
}
