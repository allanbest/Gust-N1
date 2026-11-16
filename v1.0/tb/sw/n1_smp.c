/* Gust N1 - two-core system test.
 *   1. Both harts hammer three shared counters at the same time: one with
 *      amoadd.w, one with an lr.w/sc.w loop, one plain counter guarded by an
 *      amoswap.w spinlock.  Any lost update means atomics are broken.
 *   2. Inter-core interrupts through the CLINT, in both directions.
 *   3. A separate timer interrupt on each hart.
 *   4. External interrupts through the PLIC: machine context (claim/complete)
 *      and supervisor context (visible as mip.SEIP).
 *   5. Both harts compute the same multiply-heavy checksum; with the
 *      asymmetric pair hart 1 (sequential multiplier) must take longer.
 */
#include "tb.h"

#define N 300
#define REG(a)        (*(volatile uint32_t *)(a))
#define MSIP(h)       REG(0x02000000u + 4 * (h))
#define MTIMECMP(h)   REG(0x02004000u + 8 * (h))
#define MTIMECMPH(h)  REG(0x02004004u + 8 * (h))
#define MTIME         REG(0x0200BFF8u)
#define PLIC_PRIO(i)  REG(0x0C000000u + 4 * (i))
#define PLIC_PEND     REG(0x0C001000u)
#define PLIC_EN(c)    REG(0x0C002000u + 0x80 * (c))
#define PLIC_THR(c)   REG(0x0C200000u + 0x1000 * (c))
#define PLIC_CLAIM(c) REG(0x0C200004u + 0x1000 * (c))
#define EXT_LINES     REG(0xF0000004u)

volatile uint32_t amo_cnt, lrsc_cnt, plain_cnt, lock;
volatile uint32_t done[2], ipi_seen[2], tmr_seen[2], plic_id, mul_sum[2], mul_cyc[2];
extern volatile uint32_t smp_go;

static inline uint32_t hart(void) { return csr_read(mhartid); }

uint32_t trap_handler(uint32_t cause, uint32_t epc, uint32_t tval)
{
    (void)tval;
    uint32_t h = hart();
    if (cause == 0x80000003u) {                 /* software interrupt = IPI */
        MSIP(h) = 0;
        if (++ipi_seen[h] == 1 && h == 1) MSIP(0) = 1;     /* answer hart 0 */
    } else if (cause == 0x80000007u) {          /* timer */
        MTIMECMPH(h) = 0xFFFFFFFFu;
        tmr_seen[h]++;
    } else if (cause == 0x8000000Bu) {          /* machine external (PLIC) */
        uint32_t id = PLIC_CLAIM(2 * h);
        EXT_LINES = 0;                          /* device lowers its line */
        PLIC_CLAIM(2 * h) = id;                 /* complete */
        plic_id = id;
    } else {
        _exit(0x70 | (cause & 15));
    }
    return epc;
}

static void worker(uint32_t h)
{
    for (uint32_t i = 0; i < N; i++) {
        __asm__ volatile("amoadd.w zero, %1, (%0)" : : "r"(&amo_cnt), "r"(1u) : "memory");
        __asm__ volatile("1: lr.w t0, (%0)\n addi t0, t0, 1\n sc.w t1, t0, (%0)\n bnez t1, 1b"
                         : : "r"(&lrsc_cnt) : "t0", "t1", "memory");
        uint32_t was;
        do {
            __asm__ volatile("amoswap.w %0, %2, (%1)" : "=&r"(was) : "r"(&lock), "r"(1u) : "memory");
        } while (was);
        plain_cnt = plain_cnt + 1;              /* not atomic: needs the lock */
        lock = 0;
    }
    uint32_t t0 = csr_read(mcycle), s = h * 0 + 12345;
    for (uint32_t i = 1; i <= 200; i++) s = s * 1103515245u + i * s;
    mul_cyc[h] = csr_read(mcycle) - t0;
    mul_sum[h] = s;
}

void secondary_main(void)
{
    csr_write(mie, (1u << 3) | (1u << 7));
    csr_set(mstatus, 8);
    worker(1);
    MTIMECMPH(1) = 0;
    MTIMECMP(1)  = MTIME + 400;
    done[1] = 1;
}

int main(void)
{
    CHECK(hart() == 0, 1);
    CHECK(csr_read(misa) == 0x40141107u, 2);
    smp_go = 1;
    worker(0);
    while (!done[1]) { }
    CHECK(amo_cnt == 2 * N, 10);
    CHECK(lrsc_cnt == 2 * N, 11);
    CHECK(plain_cnt == 2 * N, 12);
    CHECK(mul_sum[0] == mul_sum[1], 13);
#ifdef ASYM
    CHECK(mul_cyc[1] > 2 * mul_cyc[0], 14);     /* sequential vs single-cycle multiply */
#endif
    /* inter-core interrupts, both directions */
    csr_write(mie, (1u << 3) | (1u << 7) | (1u << 11));
    csr_set(mstatus, 8);
    MSIP(1) = 1;
    while (!ipi_seen[0]) { }
    CHECK(ipi_seen[1] == 1 && ipi_seen[0] == 1, 20);
    /* timers */
    MTIMECMPH(0) = 0;
    MTIMECMP(0)  = MTIME + 300;
    while (!tmr_seen[0] || !tmr_seen[1]) { }
    CHECK(tmr_seen[0] == 1 && tmr_seen[1] == 1, 21);
    /* PLIC, machine context of hart 0: source 2 */
    PLIC_PRIO(2) = 3;
    PLIC_EN(0)   = 1u << 2;
    PLIC_THR(0)  = 3;                           /* threshold masks it ... */
    EXT_LINES    = 1u << 2;
    for (volatile int i = 0; i < 20; i++) { }
    CHECK(plic_id == 0 && (PLIC_PEND & 4), 30);
    PLIC_THR(0)  = 0;                           /* ... until it is lowered */
    while (!plic_id) { }
    CHECK(plic_id == 2, 31);
    for (volatile int i = 0; i < 10; i++) { }
    CHECK(PLIC_PEND == 0, 32);
    /* PLIC, supervisor context of hart 0: shows up as mip.SEIP */
    PLIC_PRIO(3) = 1;
    PLIC_EN(1)   = 1u << 3;
    CHECK((csr_read(mip) & (1u << 9)) == 0, 33);
    EXT_LINES    = 1u << 3;
    for (volatile int i = 0; i < 10; i++) { }
    CHECK(csr_read(mip) & (1u << 9), 34);
    CHECK(PLIC_CLAIM(1) == 3, 35);
    EXT_LINES    = 0;
    PLIC_CLAIM(1) = 3;
    for (volatile int i = 0; i < 10; i++) { }
    CHECK((csr_read(mip) & (1u << 9)) == 0, 36);
    return 0;
}
