# Multi-core startup for the Gust N1 system test.
# Every hart starts here.  Hart 0 clears .bss and runs main(); the others get
# their own 16 KiB stack, wait for smp_go, then run secondary_main().
    .section .text.init
    .globl _start
_start:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    csrr    a0, mhartid
    la      sp, __stack_top
    slli    t0, a0, 14
    sub     sp, sp, t0
    la      t0, trap_entry
    csrw    mtvec, t0
    bnez    a0, secondary
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:  call    main
    .globl _exit
_exit:
    slli    a0, a0, 1
    ori     a0, a0, 1
    la      t0, tohost
3:  sw      a0, 0(t0)
    j       3b
secondary:
    la      t0, smp_go
4:  lw      t1, 0(t0)
    beqz    t1, 4b
    call    secondary_main
5:  wfi
    j       5b

    .balign 4
    .globl trap_entry
trap_entry:
    addi    sp, sp, -64
    sw      ra,  0(sp)
    sw      t0,  4(sp)
    sw      t1,  8(sp)
    sw      t2, 12(sp)
    sw      a0, 16(sp)
    sw      a1, 20(sp)
    sw      a2, 24(sp)
    sw      a3, 28(sp)
    sw      a4, 32(sp)
    sw      a5, 36(sp)
    sw      a6, 40(sp)
    sw      a7, 44(sp)
    sw      t3, 48(sp)
    sw      t4, 52(sp)
    sw      t5, 56(sp)
    sw      t6, 60(sp)
    csrr    a0, mcause
    csrr    a1, mepc
    csrr    a2, mtval
    call    trap_handler
    csrw    mepc, a0
    lw      ra,  0(sp)
    lw      t0,  4(sp)
    lw      t1,  8(sp)
    lw      t2, 12(sp)
    lw      a0, 16(sp)
    lw      a1, 20(sp)
    lw      a2, 24(sp)
    lw      a3, 28(sp)
    lw      a4, 32(sp)
    lw      a5, 36(sp)
    lw      a6, 40(sp)
    lw      a7, 44(sp)
    lw      t3, 48(sp)
    lw      t4, 52(sp)
    lw      t5, 56(sp)
    lw      t6, 60(sp)
    addi    sp, sp, 64
    mret

    .section .data
    .balign 4
    .globl smp_go
smp_go: .word 0

    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost
tohost: .word 0, 0
