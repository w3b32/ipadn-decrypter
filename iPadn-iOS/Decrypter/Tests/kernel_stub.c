/* Tests substitute only the iOS kernel operations, not the decryption pipeline. */
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int mode, calls, reads;
void fp_test_reset(int value) { mode = value; calls = 0; reads = 0; }
int fp_test_calls(void) { return calls; }

int fp_test_mremap(void *address, size_t length, uint32_t cryptid,
                    uint32_t cpu, uint32_t subtype)
{
    (void)subtype;
    calls++;
    if (mode == 1) { errno = EPERM; return -1; }
    if (cryptid != 2 || cpu != 0x0100000c) { errno = EINVAL; return -1; }
    if (mode == 2) return 0; /* accepted syscall, unchanged ciphertext */
    if (mprotect(address, length, PROT_READ | PROT_WRITE) != 0) return -1;
    uint8_t *p = address;
    for (size_t i = 0; i < length; i++) p[i] ^= 0xa5;
    return mprotect(address, length, PROT_READ);
}

int fp_test_read(const void *source, void *destination, size_t length)
{
    reads++;
    if (mode == 3 && reads == 2) return -1; /* lazy decryption failed */
    memcpy(destination, source, length);
    return 0;
}
