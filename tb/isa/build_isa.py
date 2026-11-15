#!/usr/bin/env python3
"""Build the official RISC-V ISA tests (riscv-software-src/riscv-tests) for Gust.

The tests themselves are not shipped with Gust; point --riscv-tests at a
checkout that includes the `env` submodule:

    git clone --recurse-submodules https://github.com/riscv-software-src/riscv-tests

Each test is linked with the stock `env/p/link.ld` (base 0x8000_0000) and
written to <out>/<name>.elf + <name>.bin, with a manifest.json that records
the `tohost` address the testbench must watch.

Usage:  build_isa.py --riscv-tests <dir> --out <dir> [--prefix riscv64-unknown-elf-]
"""
import argparse
import json
import pathlib
import subprocess
import sys

# suite -> -march string.  F/D/A are deliberately left out: Gust has none.
SUITES = {
    "rv32ui":   "rv32i_zicsr_zifencei",
    "rv32um":   "rv32im_zicsr_zifencei",
    "rv32uc":   "rv32imc_zicsr_zifencei",
    "rv32uzba": "rv32im_zicsr_zifencei_zba",
    "rv32uzbb": "rv32im_zicsr_zifencei_zbb",
    "rv32uzbs": "rv32im_zicsr_zifencei_zbs",
    "rv32mi":   "rv32im_zicsr_zifencei",
    "rv32si":   "rv32im_zicsr_zifencei",
}

# Suites that are also built in the "v" environment: the test body runs in
# user mode under Sv32 paging, with a small supervisor kernel that handles
# page faults on demand.  This is the main test of the MMU.
V_SUITES = ["rv32ui", "rv32um", "rv32uc"]

# Tests that exercise features Gust intentionally does not implement.
# Each exclusion is a documented design decision, not a hidden failure.
EXCLUDE = {
    # Misaligned loads/stores trap on Gust (allowed by the ISA); these tests
    # require them to succeed in hardware.
    "rv32ui-p-ma_data", "rv32mi-p-lw-misaligned", "rv32mi-p-lh-misaligned",
    "rv32mi-p-sh-misaligned", "rv32mi-p-sw-misaligned",
    # No PMP.
    "rv32mi-p-pmpaddr",
    "rv32ui-v-ma_data",
}


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(" ".join(str(c) for c in cmd) + "\n" + r.stderr)
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--riscv-tests", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--prefix", default="riscv64-unknown-elf-")
    ap.add_argument("--extra", action="append", default=[],
                    help="name=path.elf of an extra program to add to the manifest")
    ap.add_argument("--libc-include", default="/usr/lib/picolibc/riscv64-unknown-elf/include",
                    help="C library headers (string.h ...) for the v-environment kernel")
    args = ap.parse_args()

    rt = pathlib.Path(args.riscv_tests).resolve()
    out = pathlib.Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    gcc, objcopy, nm = (args.prefix + t for t in ("gcc", "objcopy", "nm"))

    manifest, failed = [], []

    def add(name, elf):
        run([objcopy, "-O", "binary", str(elf), str(out / f"{name}.bin")])
        syms = {l.split()[-1]: int(l.split()[0], 16)
                for l in run([nm, str(elf)]).stdout.split("\n") if len(l.split()) == 3}
        manifest.append({"name": name, "bin": f"{name}.bin", "base": 0x80000000,
                         "tohost": syms["tohost"], "end": syms.get("_end", 0)})
    for suite, march in SUITES.items():
        for src in sorted((rt / "isa" / suite).glob("*.S")):
            name = f"{suite}-p-{src.stem}"
            if name in EXCLUDE:
                continue
            elf = out / f"{name}.elf"
            r = run([gcc, f"-march={march}", "-mabi=ilp32", "-static",
                     "-mcmodel=medany", "-fvisibility=hidden", "-nostdlib",
                     "-nostartfiles", f"-I{rt / 'env' / 'p'}",
                     f"-I{rt / 'isa' / 'macros' / 'scalar'}",
                     f"-T{rt / 'env' / 'p' / 'link.ld'}", str(src), "-o", str(elf)])
            if r.returncode != 0:
                failed.append(name)
                continue
            add(name, elf)
    env_v = rt / "env" / "v"
    for suite in V_SUITES:
        for src in sorted((rt / "isa" / suite).glob("*.S")):
            name = f"{suite}-v-{src.stem}"
            if name in EXCLUDE:
                continue
            elf = out / f"{name}.elf"
            # "f" is enabled only so the assembler accepts one FP opcode that
            # the kernel uses as a constant; no FP instruction is ever executed.
            march = "rv32imfc_zicsr_zifencei" if suite == "rv32uc" else "rv32imf_zicsr_zifencei"
            r = run([gcc, f"-march={march}", "-mabi=ilp32", "-static",
                     "-mcmodel=medany", "-fvisibility=hidden", "-nostdlib",
                     "-nostartfiles", "-DENTROPY=0x1234567", "-std=gnu99", "-O2",
                     "-isystem", args.libc_include,
                     f"-I{env_v}", f"-I{rt / 'isa' / 'macros' / 'scalar'}",
                     f"-T{env_v / 'link.ld'}", str(env_v / "entry.S"),
                     str(env_v / "vm.c"), str(env_v / "string.c"), str(src),
                     "-o", str(elf)])
            if r.returncode != 0:
                failed.append(name)
                continue
            add(name, elf)

    for item in args.extra:
        name, elf = item.split("=", 1)
        add(name, pathlib.Path(elf).resolve())
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1))
    print(f"built {len(manifest)} tests into {out}")
    if failed:
        print("FAILED TO BUILD:", " ".join(failed))
        sys.exit(1)


if __name__ == "__main__":
    main()
