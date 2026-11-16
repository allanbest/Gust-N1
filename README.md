# Gust N1

**Gust N1 turns the Gust microcontroller core into a small computer chip.** It is the Gust v1.0 RISC-V core (the one on [Micro Gust](https://github.com/allanbest/Gust---RISC-V)), grown step by step into a multi-core processor with everything RV32 Linux needs from the hardware.

Designed by Fable 5.2 for Allan. Verified and laid out with Claude. MIT licensed.

## Versions

| Version | What it is | 3D chip | Folder |
|---|---|---|---|
| **v1.0** | **Two cores**, atomics, instruction caches, timer (CLINT) and interrupt controller (PLIC), UART, external RAM port | ⏳ layout running (link below) | [`v1.0/`](v1.0/) |
| v0.1 | One core plus user/supervisor modes and an Sv32 MMU (stage 1) | **[Open in 3D](https://gds-viewer.tinytapeout.com/?model=https://raw.githubusercontent.com/allanbest/Gust-N1/main/v0.1/layout/gust_n1.oas&pdk=sky130A)** | [`v0.1/`](v0.1/) |

**v1.0 in 3D:** [open viewer](https://gds-viewer.tinytapeout.com/?model=https://raw.githubusercontent.com/allanbest/Gust-N1/main/v1.0/layout/gust_n1_v1.0.oas&pdk=sky130A). This link works once the GitHub layout run has finished and added `v1.0/layout/gust_n1_v1.0.oas`.

## N1 v1.0 at a glance

```
     hart 0 (fast multiply)          hart 1 (small multiply)
        Gust core                       Gust core
        MMU (TLB + walker)              MMU (TLB + walker)
        I-cache 1 KiB                   I-cache 1 KiB
              \                              /
         shared memory bus: round-robin, bus lock, write snoop
            |           |            |              |
          CLINT        PLIC         UART      external RAM port
```

| | |
|---|---|
| Instruction set | RV32IMAC + Zicsr, Zifencei, Zba, Zbb, Zbs, Zcb |
| Privilege / memory | M, S and U modes; Sv32 paging; 8-entry TLB with a hardware page-table walker |
| Cores | 2 (set by the `NCORES` parameter); one fast-multiply core and one small-multiply core |
| Speed per MHz | 2.87 CoreMark/MHz with fast RAM; 2.02 with RAM that needs 2 wait cycles |
| Size per core | 0.173 mm² on 130 nm; 0.038 mm² on 45 nm |
| Estimated clock | ~50 MHz on 130 nm; 150–200 MHz on 40 nm (estimates) |
| Linux | Has all the processor features Linux needs, but **Linux has not been booted yet**. It still needs boot firmware, a device tree and a RAM controller. |

### Compared with Gust v1.0

| | Gust v1.0 (Micro Gust chip) | N1 v0.1 | **N1 v1.0** |
|---|---|---|---|
| Cores | 1 | 1 | **2** |
| OS support | no | privilege + MMU | **everything Linux needs** |
| Atomics, caches, interrupts | – | – | ✅ |
| CoreMark/MHz | 2.93 | ~2.93 | 2.87 (fast RAM) |
| Core logic, 130 nm | 0.122 mm² | 0.162 mm² | 0.173 mm² |

## Where to start

- **Specs:** [`v1.0/docs/gust_n1_v1.0_spec_v1.pdf`](v1.0/docs/gust_n1_v1.0_spec_v1.pdf) and [`v0.1/docs/gust_n1_v0.1_spec_v1.pdf`](v0.1/docs/gust_n1_v0.1_spec_v1.pdf)
- **Tests:** `cd v1.0/tb && make prepare RISCV_TESTS=… && make core_isa core_isa_cg soc_isa soc_isa_lat2`
- **v0.1 verification report:** [`v0.1/README.md`](v0.1/README.md)
