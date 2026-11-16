"""Shared helpers for the Gust cocotb testbenches."""
import pathlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILD = ROOT / "build"

CLK_NS = 10


def u(sig):
    """Unsigned integer value of a signal (raises if it contains X/Z)."""
    return int(sig.value)


def start_clock(dut, period_ns=CLK_NS):
    cocotb.start_soon(Clock(dut.clk, period_ns, unit="ns").start())


async def reset(dut, cycles=3):
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, cycles)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def words_from_bin(data: bytes):
    data = data + b"\0" * (-len(data) % 4)
    return [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]


class MemLoader:
    """Writes program images into a Verilog memory array, remembering how much
    was written last time so stale words from the previous program are cleared."""

    def __init__(self, mem_handle):
        self.mem = mem_handle
        self.prev = 0

    def load(self, words, offset_words=0, clear_to=None):
        end = offset_words + len(words)
        for i, w in enumerate(words):
            self.mem[offset_words + i].value = w
        for i in range(end, max(self.prev, clear_to or 0)):
            self.mem[i].value = 0
        self.prev = max(end, clear_to or 0)


# ---------------------------------------------------------------------------
# Peripheral ("slave") register interface driver
# ---------------------------------------------------------------------------
from cocotb.triggers import FallingEdge  # noqa: E402


class Slave:
    """Drives the one-cycle register interface used by every Gust peripheral:
    sel/we/addr/wdata in the request cycle, rdata registered one cycle later.
    Both calls return just after the falling clock edge that follows the
    access, so every effect of the access is already visible to the caller."""

    def __init__(self, dut, sel=None):
        self.dut = dut
        self.sel = sel if sel is not None else dut.sel
        self.sel.value = 0
        dut.we.value = 0
        dut.addr.value = 0
        dut.wdata.value = 0

    async def write(self, reg, value):
        d = self.dut
        self.sel.value = 1
        d.we.value = 1
        d.addr.value = reg >> 2
        d.wdata.value = value & 0xFFFFFFFF
        await RisingEdge(d.clk)
        self.sel.value = 0
        d.we.value = 0
        await FallingEdge(d.clk)

    async def read(self, reg):
        d = self.dut
        self.sel.value = 1
        d.we.value = 0
        d.addr.value = reg >> 2
        await RisingEdge(d.clk)
        self.sel.value = 0
        await FallingEdge(d.clk)
        return u(d.rdata)


# ---------------------------------------------------------------------------
# UART line helpers (8N1, bit time given in clock cycles)
# ---------------------------------------------------------------------------
async def uart_recv(clk, line, bit_cycles):
    """Wait for one frame on `line` and return the byte (None on a bad stop bit)."""
    while u(line) == 1:
        await RisingEdge(clk)
    await ClockCycles(clk, bit_cycles // 2)
    if u(line) != 0:
        return None
    value = 0
    for i in range(8):
        await ClockCycles(clk, bit_cycles)
        value |= u(line) << i
    await ClockCycles(clk, bit_cycles)
    ok = u(line) == 1
    return value if ok else None


async def uart_monitor(clk, line, bit_cycles, sink):
    while True:
        b = await uart_recv(clk, line, bit_cycles)
        sink.append(b)


async def uart_send(clk, line, bit_cycles, byte, stop_ok=True):
    line.value = 0
    await ClockCycles(clk, bit_cycles)
    for i in range(8):
        line.value = (byte >> i) & 1
        await ClockCycles(clk, bit_cycles)
    line.value = 1 if stop_ok else 0
    await ClockCycles(clk, bit_cycles)
    line.value = 1


# ---------------------------------------------------------------------------
# JTAG / RISC-V debug driver (bit-banged from the test, like a debug probe)
# ---------------------------------------------------------------------------
class Jtag:
    IDCODE, DTMCS, DMI = 0x01, 0x10, 0x11

    def __init__(self, clk, tck, tms, tdi, tdo, half=5):
        self.clk, self.tck, self.tms, self.tdi, self.tdo = clk, tck, tms, tdi, tdo
        self.half = half                  # TCK half period in clk cycles
        tck.value = 0
        tms.value = 1
        tdi.value = 0

    async def clock(self, tms, tdi=0):
        """One TCK cycle.  Returns TDO sampled just before the rising edge."""
        self.tms.value = tms
        self.tdi.value = tdi
        await ClockCycles(self.clk, self.half)
        tdo = u(self.tdo)
        self.tck.value = 1
        await ClockCycles(self.clk, self.half)
        self.tck.value = 0
        return tdo

    async def reset(self):
        for _ in range(6):
            await self.clock(1)
        await self.clock(0)               # Run-Test/Idle

    async def _shift(self, value, nbits):
        out = 0
        for i in range(nbits):
            out |= (await self.clock(1 if i == nbits - 1 else 0, (value >> i) & 1)) << i
        await self.clock(1)               # Update
        await self.clock(0)               # Run-Test/Idle
        return out

    async def write_ir(self, ir):
        await self.clock(1); await self.clock(1); await self.clock(0); await self.clock(0)
        return await self._shift(ir, 5)

    async def shift_dr(self, value, nbits):
        await self.clock(1); await self.clock(0); await self.clock(0)
        return await self._shift(value, nbits)

    async def idle(self, n=2):
        for _ in range(n):
            await self.clock(0)

    # ---- DMI -------------------------------------------------------------
    async def dmi_select(self):
        await self.write_ir(self.DMI)

    async def dmi_write(self, addr, data):
        cocotb.log.debug("dmi_write %#x %#x", addr, data)
        await self.shift_dr((addr << 34) | ((data & 0xFFFFFFFF) << 2) | 2, 41)
        await self.idle()

    async def dmi_read(self, addr):
        cocotb.log.debug("dmi_read %#x", addr)
        await self.shift_dr((addr << 34) | 1, 41)
        await self.idle()
        out = await self.shift_dr(0, 41)
        assert out & 3 == 0, f"DMI status {out & 3}"
        return (out >> 2) & 0xFFFFFFFF


class Debugger:
    """The handful of debug-module operations a real debugger performs."""
    DATA0, DMCONTROL, DMSTATUS, ABSTRACTCS, COMMAND = 0x04, 0x10, 0x11, 0x16, 0x17
    SBCS, SBADDRESS0, SBDATA0 = 0x38, 0x39, 0x3C

    def __init__(self, jtag):
        self.j = jtag

    async def activate(self):
        await self.j.reset()
        await self.j.dmi_select()
        await self.j.dmi_write(self.DMCONTROL, 0)
        await self.j.dmi_write(self.DMCONTROL, 1)

    async def status(self):
        s = await self.j.dmi_read(self.DMSTATUS)
        return {"halted": (s >> 9) & 1, "running": (s >> 11) & 1,
                "resumeack": (s >> 17) & 1, "havereset": (s >> 19) & 1,
                "unavail": (s >> 13) & 1, "version": s & 15,
                "authenticated": (s >> 7) & 1}

    async def halt(self):
        await self.j.dmi_write(self.DMCONTROL, 0x80000001)
        for _ in range(20):
            if (await self.status())["halted"]:
                break
        else:
            raise AssertionError("hart did not halt")
        await self.j.dmi_write(self.DMCONTROL, 1)

    async def resume(self):
        await self.j.dmi_write(self.DMCONTROL, 0x40000001)
        for _ in range(20):
            if (await self.status())["resumeack"]:
                return
        raise AssertionError("no resume acknowledge")

    async def cmderr(self):
        return ((await self.j.dmi_read(self.ABSTRACTCS)) >> 8) & 7

    async def clear_cmderr(self):
        await self.j.dmi_write(self.ABSTRACTCS, 7 << 8)

    async def reg_read(self, regno):
        await self.j.dmi_write(self.COMMAND, (2 << 20) | (1 << 17) | regno)
        err = await self.cmderr()
        assert err == 0, f"abstract read of {regno:#x}: cmderr {err}"
        return await self.j.dmi_read(self.DATA0)

    async def reg_write(self, regno, value):
        await self.j.dmi_write(self.DATA0, value)
        await self.j.dmi_write(self.COMMAND, (2 << 20) | (1 << 17) | (1 << 16) | regno)
        err = await self.cmderr()
        assert err == 0, f"abstract write of {regno:#x}: cmderr {err}"

    async def gpr_read(self, n):
        return await self.reg_read(0x1000 + n)

    async def gpr_write(self, n, v):
        await self.reg_write(0x1000 + n, v)

    async def mem_write(self, addr, value, size=2):
        await self.j.dmi_write(self.SBCS, size << 17)
        await self.j.dmi_write(self.SBADDRESS0, addr)
        await self.j.dmi_write(self.SBDATA0, value)

    async def mem_read(self, addr, size=2):
        await self.j.dmi_write(self.SBCS, (size << 17) | (1 << 20))   # readonaddr
        await self.j.dmi_write(self.SBADDRESS0, addr)
        return await self.j.dmi_read(self.SBDATA0)

    async def mem_write_block(self, addr, words):
        await self.j.dmi_write(self.SBCS, (2 << 17) | (1 << 16))      # autoincrement
        await self.j.dmi_write(self.SBADDRESS0, addr)
        for w in words:
            await self.j.dmi_write(self.SBDATA0, w)

    async def sberror(self):
        return ((await self.j.dmi_read(self.SBCS)) >> 12) & 7
