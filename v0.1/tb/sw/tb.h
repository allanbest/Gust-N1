/* Helpers shared by the core-level testbench programs. */
#ifndef GUST_TB_H
#define GUST_TB_H
#include <stdint.h>

#ifdef __riscv
/* test device in tb/core/tb_core.v */
#define IO_BASE      0xF0000000u
#define IO_REG(off)  (*(volatile uint32_t *)(IO_BASE + (off)))
#define IO_PUTC      IO_REG(0x00)
#define IO_IRQ_ARM   IO_REG(0x04)
#define IO_IRQ_DELAY IO_REG(0x08)
#define IO_IRQ_CLR   IO_REG(0x0C)
#define IO_IRQ_STATE IO_REG(0x10)
#define IO_CYCLE     IO_REG(0x14)

#define csr_read(csr) ({ uint32_t v_; __asm__ volatile("csrr %0, " #csr : "=r"(v_)); v_; })
#define csr_write(csr, v) __asm__ volatile("csrw " #csr ", %0" : : "r"((uint32_t)(v)))
#define csr_set(csr, v)   __asm__ volatile("csrs " #csr ", %0" : : "r"((uint32_t)(v)))
#define csr_clear(csr, v) __asm__ volatile("csrc " #csr ", %0" : : "r"((uint32_t)(v)))

void _exit(unsigned code) __attribute__((noreturn));
static inline void tb_putc(char c) { IO_PUTC = (uint8_t)c; }
#else
/* host build (reference run of the differential test) */
#include <stdio.h>
#include <stdlib.h>
static inline void tb_putc(char c) { putchar(c); }
static inline void _exit(unsigned code) { exit((int)code); }
#endif

#define CHECK(cond, code) do { if (!(cond)) _exit(code); } while (0)

static inline void tb_puts(const char *s) { while (*s) tb_putc(*s++); }
static inline void tb_puthex(uint32_t v)
{
    for (int i = 28; i >= 0; i -= 4) tb_putc("0123456789abcdef"[(v >> i) & 15]);
    tb_putc('\n');
}

#endif
