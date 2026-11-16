# Gust N1 v0.1 (stage 1)

The "computer" branch of Gust: the Gust v1.0 core extended with machine,
supervisor and user privilege modes and an Sv32 memory-management unit.
Read `docs/gust_n1_v0.1_spec_v1.pdf` first.

    rtl/   n1_core.v (top), gust_mmu.v (new), gust_csr.v (rewritten),
           gust_core/fetch/decode.v (modified), rvc/alu/muldiv/regfile/icg (unchanged)
    tb/    core test bench, test builder, directed test sw/n1_priv.c

Run:

    cd tb
    make prepare RISCV_TESTS=/path/to/riscv-tests   # needs picolibc headers
    make                                            # expect TESTS=294 PASS=294, twice

Status: simulated and synthesised only. Not yet Linux-capable (no atomics,
caches or external memory - stages 2 to 4 in the spec). Not run on an FPGA.
