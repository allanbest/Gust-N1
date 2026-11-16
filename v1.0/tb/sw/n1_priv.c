/* Gust N1 stage 1 - directed test of what the standard RISC-V tests do not
 * cover: privilege checks on instructions and CSRs, TSR/TVM/TW, counter
 * enables, interrupt delegation to S-mode, SUM, MXR, read-only pages,
 * sfence.vma, misaligned superpages, and an instruction that straddles a page
 * boundary whose second page is not mapped (mtval must name the second page).
 *
 * Runs in M-mode on the core test bench; every trap comes to M-mode unless a
 * test delegates it.  Returns 0 on success or the number of the failed check.
 */
#include "tb.h"

#define PTE_V 1u
#define PTE_R 2u
#define PTE_W 4u
#define PTE_X 8u
#define PTE_U 16u
#define PTE_A 64u
#define PTE_D 128u
#define PTE(pa, fl) ((((uint32_t)(pa)) >> 12 << 10) | (fl))
#define UBASE 0x40000000u

static uint32_t l1[1024] __attribute__((aligned(4096)));
static uint32_t l0[1024] __attribute__((aligned(4096)));
static uint8_t  pg[5][4096] __attribute__((aligned(4096)));

volatile uint32_t resume_pc, s_cause, s_epc;
static volatile uint32_t n_ill, n_pf, last_cause, last_epc, last_tval, last_mpp;
static volatile uint32_t fix_page, clear_stip;

uint32_t trap_handler(uint32_t cause, uint32_t epc, uint32_t tval)
{
    last_cause = cause; last_epc = epc; last_tval = tval;
    last_mpp   = (csr_read(mstatus) >> 11) & 3;
    if (cause >> 31) {                         /* interrupt taken in M-mode */
        csr_clear(mip, 1u << 5);
        return epc;
    }
    if (cause == 8 || cause == 9) {            /* ecall from U or S: back to M */
        csr_set(mstatus, 3u << 11);
        if (clear_stip) { csr_clear(mip, 1u << 5); clear_stip = 0; }
        uint32_t r = resume_pc;
        resume_pc = 0;
        return r ? r : epc + 4;
    }
    if (cause == 2) { n_ill++; return epc + 4; }
    if (cause == 12 && fix_page) {             /* demand-map the second page */
        /* the fault must name the page that is missing, not the page the
         * instruction starts in - an OS maps whatever mtval points at */
        if (tval != UBASE + 0x1000 || epc != UBASE + 0xFFE) _exit(40);
        fix_page = 0;
        n_pf++;
        l0[1] = PTE(pg[1], PTE_V | PTE_R | PTE_X | PTE_U | PTE_A);
        return epc;
    }
    n_pf++;                                    /* other page faults: skip */
    return epc + (((*(volatile uint16_t *)epc) & 3) == 3 ? 4 : 2);
}

/* continue inline at a lower privilege; RAISE() comes back to M-mode */
#define DROP(prv) do {                                                        \
        csr_clear(mstatus, 3u << 11); csr_set(mstatus, (uint32_t)(prv) << 11); \
        __asm__ volatile("la t0, 1f\n csrw mepc, t0\n mret\n .balign 4\n 1:"  \
                         : : : "t0");                                          \
    } while (0)
#define RAISE() __asm__ volatile(".option push\n.option norvc\n ecall\n.option pop")
#define I4(s)   __asm__ volatile(".option push\n.option norvc\n" s "\n.option pop" : : : "t0")

/* run code at `pc` with privilege `prv`; it returns with an ecall */
__attribute__((noinline)) static uint32_t enter(uint32_t prv, uint32_t pc, uint32_t arg)
{
    csr_clear(mstatus, 3u << 11);
    csr_set(mstatus, prv << 11);
    csr_write(mepc, pc);
    register uint32_t a0 __asm__("a0") = arg;
    __asm__ volatile("la t0, 1f\n sw t0, resume_pc, t1\n mret\n .balign 4\n 1:"
                     : "+r"(a0) : : "t0", "t1", "memory");
    return a0;
}

__asm__(".text\n .balign 4\n .globl s_stub\n s_stub:\n"
        " csrr t0, scause\n sw t0, s_cause, t1\n"
        " csrr t0, sepc\n sw t0, s_epc, t1\n ecall\n");
extern char s_stub[];

int main(void)
{
    volatile uint32_t sink;

    /* ---- 1: instructions and CSRs that are illegal below M ------------- */
    CHECK(csr_read(misa) == 0x40141107u, 1);
    DROP(0);
    I4("sret"); I4("wfi"); I4("csrr t0, sstatus"); I4("sfence.vma");
    RAISE();
    CHECK(n_ill == 4 && last_cause == 8, 2);
    DROP(1);
    I4("csrr t0, mstatus"); I4("rdcycle t0");
    RAISE();
    CHECK(n_ill == 6 && last_cause == 9, 3);
    csr_write(mcounteren, 1);
    csr_set(mstatus, 7u << 20);                /* TVM, TW, TSR */
    DROP(1);
    I4("rdcycle t0");                          /* now allowed */
    I4("sret"); I4("csrr t0, satp"); I4("sfence.vma"); I4("wfi");
    RAISE();
    CHECK(n_ill == 10, 4);
    csr_clear(mstatus, 7u << 20);
    DROP(1);
    I4("csrr t0, satp"); I4("sfence.vma");
    RAISE();
    CHECK(n_ill == 10, 5);

    /* ---- 2: supervisor timer interrupt, delegated and not --------------- */
    csr_write(mie, 1u << 5);
    csr_set(mstatus, 8);                       /* MIE */
    csr_set(mip, 1u << 5);                     /* not delegated: M takes it */
    __asm__ volatile("nop\n nop");
    CHECK(last_cause == 0x80000005u && (csr_read(mip) & 32) == 0, 6);
    csr_write(stvec, (uint32_t)s_stub);
    csr_write(mideleg, 1u << 5);
    csr_set(mstatus, 2);                       /* SIE */
    last_cause = 0;
    csr_set(mip, 1u << 5);                     /* delegated: ignored in M-mode */
    __asm__ volatile("nop\n nop\n nop");
    CHECK(last_cause == 0 && (csr_read(mip) & 32), 7);
    CHECK(csr_read(sip) == 32 && csr_read(sie) == 32, 8);
    clear_stip = 1;
    csr_clear(mstatus, 3u << 11); csr_set(mstatus, 1u << 11);
    __asm__ volatile("la t0, 2f\n sw t0, resume_pc, t1\n la t0, 1f\n csrw mepc, t0\n"
                     " mret\n .balign 4\n 1: nop\n nop\n 2:" : : : "t0", "t1", "memory");
    CHECK(s_cause == 0x80000005u, 9);          /* taken in S-mode, by stvec */
    CHECK((csr_read(mstatus) & 0x122) == 0x120, 10);   /* SPP=S, SPIE=1, SIE=0 */
    csr_write(mideleg, 0);
    csr_write(mie, 0);

    /* ---- 3: paging ------------------------------------------------------ */
    l1[0x80000000u >> 22] = PTE(0x80000000u, PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D);
    l1[0xF0000000u >> 22] = PTE(0xF0000000u, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D);
    l1[UBASE >> 22]       = PTE(l0, PTE_V);
    l1[(UBASE >> 22) + 1] = PTE(0x80001000u, PTE_V | PTE_R | PTE_A);      /* misaligned superpage */
    l0[0] = PTE(pg[0], PTE_V | PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D);
    l0[2] = PTE(pg[2], PTE_V | PTE_R | PTE_U | PTE_A);                    /* read-only user page  */
    l0[3] = PTE(pg[3], PTE_V | PTE_X | PTE_A);                            /* execute-only page    */
    l0[4] = PTE(pg[4], PTE_V | PTE_R | PTE_W | PTE_A | PTE_D);
    *(uint32_t *)pg[0] = 0x11111111u;
    *(uint32_t *)pg[3] = 0x33333333u;
    *(uint32_t *)pg[4] = 0x44444444u;
    /* "addi a0,a0,1" across the page 0 / page 1 boundary, then "ecall" */
    *(uint16_t *)(pg[0] + 0xFFE) = 0x0513;
    *(uint16_t *)(pg[1] + 0)     = 0x0015;
    *(uint32_t *)(pg[1] + 2)     = 0x00000073;
    csr_write(satp, 0x80000000u | ((uint32_t)l1 >> 12));
    n_pf = 0;

    DROP(1);
    sink = *(volatile uint32_t *)UBASE;                    /* user page, SUM = 0 */
    CHECK(n_pf == 1 && last_cause == 13 && last_tval == UBASE && last_mpp == 1, 20);
    csr_set(sstatus, 1u << 18);                            /* SUM */
    CHECK(*(volatile uint32_t *)UBASE == 0x11111111u && n_pf == 1, 21);
    sink = *(volatile uint32_t *)(UBASE + 0x3000);         /* execute-only */
    CHECK(n_pf == 2 && last_cause == 13 && last_tval == UBASE + 0x3000, 22);
    csr_set(sstatus, 1u << 19);                            /* MXR */
    CHECK(*(volatile uint32_t *)(UBASE + 0x3000) == 0x33333333u && n_pf == 2, 23);
    *(volatile uint32_t *)(UBASE + 0x2004) = 5;            /* read-only page */
    CHECK(n_pf == 3 && last_cause == 15 && last_tval == UBASE + 0x2004, 24);
    CHECK(*(volatile uint32_t *)(UBASE + 0x4000) == 0x44444444u, 25);
    l0[4] = PTE(pg[0], PTE_V | PTE_R | PTE_W | PTE_A | PTE_D);   /* remap, then flush */
    __asm__ volatile("sfence.vma");
    CHECK(*(volatile uint32_t *)(UBASE + 0x4000) == 0x11111111u && n_pf == 3, 26);
    sink = *(volatile uint32_t *)(UBASE + 0x400000);       /* misaligned superpage */
    CHECK(n_pf == 4 && last_cause == 13, 27);
    sink = *(volatile uint32_t *)(UBASE + 0x1000);         /* unmapped */
    CHECK(n_pf == 5 && last_cause == 13 && last_tval == UBASE + 0x1000, 28);
    RAISE();

    /* instruction straddling into an unmapped page, run in U-mode */
    n_pf = 0;
    fix_page = 1;
    uint32_t r = enter(0, UBASE + 0xFFE, 41);
    CHECK(n_pf == 1 && fix_page == 0, 30);
    CHECK(r == 42, 31);
    CHECK(last_cause == 8 && last_mpp == 0 && last_epc == UBASE + 0x1002, 32);
    (void)sink;
    csr_write(satp, 0);
    return 0;
}
