/* Minimal runtime for freestanding test programs. */
#include <stddef.h>
#include <stdint.h>

void *memcpy(void *d, const void *s, size_t n)
{
    unsigned char *dd = d;
    const unsigned char *ss = s;
    while (n--) *dd++ = *ss++;
    return d;
}

void *memset(void *d, int c, size_t n)
{
    unsigned char *dd = d;
    while (n--) *dd++ = (unsigned char)c;
    return d;
}

#ifdef __riscv
void _exit(unsigned code) __attribute__((noreturn));
/* Tests that expect traps provide their own handler. */
__attribute__((weak)) uint32_t trap_handler(uint32_t cause, uint32_t epc, uint32_t tval)
{
    (void)epc; (void)tval;
    _exit(0x7000 | (cause & 0xff));
}
#endif
