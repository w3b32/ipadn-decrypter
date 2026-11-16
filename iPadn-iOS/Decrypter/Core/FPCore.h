//
//  FPCore.h
//  TetherDecrypt
//
//  FairPlay page decryption via the private mremap_encrypted(2) syscall,
//  plus a minimal zip reader/writer so the whole pipeline runs on-device.
//
//  The decryption path relies on cryptid = 2 (CRYPTID_MODEL_ENCRYPTION):
//  XNU's vm_map_apple_protected() only demands a VM_PROT_EXECUTE mapping
//  when cryptid != 2, so a plain PROT_READ mapping of an App Store binary
//  is decrypted by fairplayd instead of being rejected as unexecutable.
//

#ifndef FPCORE_H
#define FPCORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FP_ERRMAX 512
#define FP_LOGMAX 16384

typedef struct {
    bool     is_macho;
    bool     is_fat;
    uint32_t slices;          /* arch count (1 for thin) */
    uint32_t arm64_slices;
    bool     encrypted;       /* any slice with cryptid != 0 */
    uint32_t cputype;
    uint32_t cpusubtype;
    uint32_t cryptoff;
    uint32_t cryptsize;
    uint32_t cryptid;
} fp_info;

/* Parse the Mach-O (thin or fat) at `path`. Returns 0 if the file was read;
   is_macho == false means "not a Mach-O", which is not an error. */
int fp_probe(const char *path, fp_info *out);

#define FP_SIGNING_MAX_SLICES 8
typedef struct {
    uint32_t cputype;
    uint32_t cpusubtype;
    uint64_t slice_offset;
    uint64_t slice_size;
    uint64_t signature_offset;       /* relative to the slice; zero if unsigned */
    uint64_t signature_size;
    uint64_t signature_fields_offset; /* LC_CODE_SIGNATURE dataoff/datasize */
    uint64_t linkedit_vmsize_offset;
    uint64_t linkedit_filesize_offset;
    uint32_t linkedit_word_size;
} fp_signing_slice;

/* Describe only the fields and blob that a code signer is allowed to rewrite.
   The caller can hash all remaining bytes, including encrypted pages and their
   load commands. Unknown layout changes must not be accepted as re-signing. */
int fp_signing_layout(const char *path, fp_signing_slice *out, uint32_t capacity,
                      uint32_t *count, char *err, size_t errlen);

/* Decrypt every encrypted arm64 slice of `path`, replacing the file atomically.
   Encrypted non-arm64 slices are rejected rather than passed through as plain.
   Returns 0 on success, -1 on error with a reason in `err`.
   Progress, including which (alignment, cryptid) combination worked, goes to `log`. */
int fp_decrypt_file(const char *path, char *log, size_t loglen, char *err, size_t errlen);

/* Same, but read `src` and write a plaintext copy to `dst`. The helper app needs
   this: the encrypted original must stay untouched inside its own installed
   bundle (that is the only place fairplayd cooperates), while the plaintext
   lands somewhere writable. */
int fp_decrypt_copy(const char *src, const char *dst, char *log, size_t loglen,
                    char *err, size_t errlen);

/* Extract a zip (stored + deflate), preserving safe relative symlinks.
   Traversal, absolute links and writes through symlink parents are rejected. */
int fp_unzip(const char *zip_path, const char *dest_dir, char *err, size_t errlen);

/* Repack a directory as a zip using stored entries only (no zlib needed to read it). */
int fp_zip_dir(const char *src_dir, const char *zip_path, char *err, size_t errlen);

/* Live progress: called for every log line while a decrypt is running. */
typedef void (*fp_progress_fn)(const char *line, void *ctx);
void fp_set_progress(fp_progress_fn fn, void *ctx);

/* Append to a bounded log buffer. */
void fp_log_append(char *log, size_t loglen, const char *fmt, ...);

#ifdef __cplusplus
}
#endif

#endif /* FPCORE_H */
