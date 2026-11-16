# Gust N1 v1.0

A two-core, Linux-capable processor system built around the Gust v1.0
microcontroller core. Read `docs/gust_n1_v1.0_spec_v1.pdf` first.

    rtl/           18 Verilog files; n1_soc.v is the top level
                   new: gust_mmu, n1_core, n1_icache, n1_membus, n1_clint, n1_plic, n1_soc
                   modified from Gust: gust_core, gust_fetch, gust_decode, gust_csr, gust_defs
                   unchanged from Gust: gust_rvc, gust_alu, gust_muldiv, gust_regfile, gust_icg, gust_uart
    tb/            cocotb test benches (core/ and soc/), test builder (isa/),
                   directed tests (sw/n1_priv.c, sw/n1_smp.c)
    tb/verilator/  fast build of the system test bench (used for CoreMark)
    syn/           Yosys script; 130 nm and 45 nm settings are in its header
    docs/          specification (LaTeX and PDF)

Run the tests (Icarus Verilog, cocotb 2, RISC-V GCC, picolibc headers):

    cd tb
    make prepare RISCV_TESTS=/path/to/riscv-tests
    make core_isa core_isa_cg soc_isa soc_isa_lat2

Run CoreMark on the system (Verilator 5), one core, RAM with 2 wait cycles:

    cd tb/verilator
    make TAG=c1l2 PARAMS="-GNCORES=1 -GLAT=2 -GICACHE=1"
    ./obj_c1l2/sim_soc +hex=<coremark.hex> +tohost=<hex address>

Synthesis:

    cd syn
    TOP=n1_core FLAT=1 LIB=<sky130 liberty file> PARAMS="CLOCK_GATE 1" yosys -c synth.tcl

Status: simulated and synthesized only. Linux has not been booted on it.
No data cache, no FPU, no PMP, debug module not connected. Not run on an
FPGA. See "Known limitations" in the specification.
