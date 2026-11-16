"""Run the official RISC-V ISA tests (riscv-tests, `-p-` environment) on the
bare core.  Every test is run twice: once against ideal single-cycle memory and
once with randomly withheld grants and delayed responses on both buses.

Pass/fail follows the riscv-tests convention: the program writes 1 to `tohost`
on success, or (failing_test_number << 1) | 1 on failure.
"""
import json

import cocotb
from cocotb.triggers import RisingEdge, with_timeout

from gust_tb import BUILD, MemLoader, reset, start_clock, u, words_from_bin

ISA_DIR = BUILD / "isa"
MANIFEST = json.loads((ISA_DIR / "manifest.json").read_text()) if (ISA_DIR / "manifest.json").exists() else []
TESTS = [t["name"] for t in MANIFEST]
import os
if os.environ.get("GUST_ONLY"):          # e.g. GUST_ONLY=rv32si,directed
    TESTS = [n for n in TESTS if any(k in n for k in os.environ["GUST_ONLY"].split(","))]
BY_NAME = {t["name"]: t for t in MANIFEST}

_loader = None


def tie_off(dut):
    for s in ("irq_software", "irq_timer", "irq_external", "irq_fast",
              "dbg_halt_req", "dbg_resume_req", "dbg_reg_req", "dbg_reg_we",
              "dbg_reg_no", "dbg_reg_wdata"):
        getattr(dut, s).value = 0


@cocotb.test()
@cocotb.parametrize(name=TESTS, stall=[0, 1])
async def isa(dut, name, stall):
    global _loader
    if _loader is None:
        _loader = MemLoader(dut.mem)
    start_clock(dut)          # cocotb stops a test's tasks when it ends
    dut._log.info("ISA test %s (stall_mode=%d)", name, stall)
    t = BY_NAME[name]
    tie_off(dut)
    dut.stall_mode.value = stall
    dut.tohost_addr.value = t["tohost"]
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    # clear up to the end of .bss: the "v" tests keep page tables there
    end_words = max(0, (t.get("end", 0) - t["base"] + 3) // 4)
    _loader.load(words_from_bin((ISA_DIR / t["bin"]).read_bytes()), clear_to=end_words)
    await reset(dut)

    await with_timeout(RisingEdge(dut.tohost_valid), 6_000_000, "ns")
    await RisingEdge(dut.clk)
    code = u(dut.tohost_data)
    assert u(dut.proto_err) == 0, "bus protocol violation"
    assert code == 1, f"{name}: failed at TESTNUM {code >> 1} (tohost={code:#x})"
