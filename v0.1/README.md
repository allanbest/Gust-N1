# Gust N1 v0.1

Gust N1 is the Gust v1.0 RV32IMC core scaled toward a computer chip. Version 0.1 is **stage 1 of 5**: it adds the privilege levels and virtual memory an operating system needs. Everything else in the core is reused from Gust v1.0 (the microcontroller chip on [Micro Gust](https://github.com/allanbest/Gust---RISC-V)).

**[Open the layout in the 3D viewer](https://gds-viewer.tinytapeout.com/?model=https://raw.githubusercontent.com/allanbest/Gust-N1/main/v0.1/layout/gust_n1.oas&pdk=sky130A)**

| | Gust v1.0 | **Gust N1 v0.1** |
|---|---|---|
| ISA | RV32IMC + Zba/Zbb/Zbs, M-mode | same **+ S-mode, U-mode, Sv32 MMU** |
| Core logic | 0.122 mm² | 0.162 mm² (+33%) |
| Die (sky130, LibreLane 3.0.14) | 640 × 640 µm | 760 × 760 µm |
| Typical clock | ~36 MHz | ~33 MHz |
| Worst-case clock (ss, 100 °C, 1.60 V) | 17.7 MHz | 16.6 MHz |
| CoreMark/MHz | 2.93 | ~2.93 in M-mode (estimate) |

## Can it run Linux?

**Not yet.** The roadmap in the spec:

1. ✅ **Privilege modes and Sv32 MMU.** This release.
2. Atomics (RV32A).
3. Caches and external DRAM. This also moves address translation off the critical path.
4. Boot firmware (OpenSBI) and a device tree.
5. Boot Linux.

## Verification status

- **Fable's regression: 294 / 294 pass**, with clock gating both off and on. That covers the riscv-tests suite for RV32 user and supervisor modes, plus a directed privilege and MMU test (`tb/sw/n1_priv.c`).
- **Wrapper test: passes.** N1 behind the byte-serial memory bridge (`chip_wrapper/`) runs a program and returns the correct result.
- **Reuse claims confirmed by diff.** Five files are byte-identical to Gust v1.0.
- **Verilator `-Wall` lint:** clean apart from a few unused-signal notes.
- **Mutation testing**, three hand-injected MMU bugs:
  - "Ignore MXR" was caught (2 tests fail).
  - "Ignore SUM" was caught (104 tests fail).
  - **"Allow S-mode to execute from U pages" was not caught.** The RTL is correct here, but no test checks it. **TODO:** add a test to `n1_priv.c` that maps a U page, jumps to it from S-mode, and expects cause 12.

## Layout

The layout uses the same flow as the Gust v1.0 full-chip layout: the core sits behind the byte-serial memory bridge on a square sky130 die, with a 50 ns clock target and 45% placement density.

| Metric | Value |
|---|---|
| Standard cells | 31,388 (113,435 instances including fill, tap and decap) |
| Utilization | 49% |
| Routing DRC / Magic DRC / LVS / antenna | 0 / 0 / 0 / 0 |
| Setup slack: typical / worst corner | +19.9 ns / −10.0 ns |
| Hold | met |
| Max-slew / max-cap warnings | 10,510 / 164 (these need fixing before tape-out) |

Files: `layout/gust_n1.oas` (OASIS), `layout/gust_n1_metrics.json`, `layout/librelane_config.json`.

## Running the tests

```sh
cd tb
make prepare RISCV_TESTS=/path/to/riscv-tests   # needs riscv64-unknown-elf-gcc
make                                             # cocotb + Icarus Verilog
```

## Layout of this repo

- `rtl/`: the N1 core (`n1_core.v` is the top; `gust_mmu.v` and `gust_csr.v` are new or rewritten).
- `tb/`: Fable's cocotb testbench and the directed privilege test.
- `docs/`: the spec, `gust_n1_v0.1_spec_v1` (PDF and LaTeX source).
- `chip_wrapper/`: the memory-bridge wrapper used for the layout.
- `layout/`: the layout files listed above.
- `README_fable.md`: Fable's original README.

Designed by Fable 5.2. Verified and laid out with Claude. MIT licensed.
