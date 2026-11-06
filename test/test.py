# SPDX-License-Identifier: Apache-2.0
"""End-to-end tests through the chip's SPI host port. The Tiny Tapeout flow runs
these on the RTL and again on the gate-level netlist."""

import pathlib
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import encode  # noqa: E402
import protocols  # noqa: E402

HALF = 4  # SCK half period, in clock cycles
SCK, MOSI, CSN = 1, 2, 4


class Host:
    """A bit-banged SPI host on ui_in, with MISO on uo_out[0]."""

    def __init__(self, dut):
        self.dut = dut
        self.pins = CSN

    def drive(self):
        self.dut.ui_in.value = self.pins

    async def wait(self, cycles):
        await ClockCycles(self.dut.clk, cycles)
        await FallingEdge(self.dut.clk)

    async def transfer(self, byte):
        value = 0
        for i in range(7, -1, -1):
            self.pins = MOSI if (byte >> i) & 1 else 0
            self.drive()
            await self.wait(HALF)
            value = value << 1 | (int(self.dut.uo_out.value) & 1)
            self.pins |= SCK
            self.drive()
            await self.wait(HALF)
            self.pins &= ~SCK
            self.drive()
        await self.wait(HALF)
        return value

    async def frame(self, *data):
        self.pins = 0
        self.drive()
        await self.wait(HALF)
        replies = [await self.transfer(byte) for byte in data]
        await self.wait(HALF)
        self.pins = CSN
        self.drive()
        await self.wait(2 * HALF)
        return replies

    async def load(self, prog):
        for address, word in enumerate(encode.assemble(prog)):
            await self.frame(0x10, address, *word.to_bytes(4, "big"))

    async def write_reg(self, hart, reg, value):
        await self.frame(0x20 | hart, reg, value >> 8, value & 0xFF)

    async def setup(self, hart, prog, role, addr=0):
        for reg, word in enumerate(encode.config_words(prog)):
            await self.write_reg(hart, reg, word)
        await self.write_reg(hart, 6, encode.ROLE[role])
        await self.write_reg(hart, 7, addr)
        mask = sum(1 << i for i, pin in enumerate(prog.pins) if prog.pins[pin])
        await self.write_reg(hart, 8, mask)

    async def push(self, hart, data):
        for byte in data:
            await self.frame(0x40 | hart, 0, byte)

    async def start_pair_in_loopback(self):
        await self.frame(0x30, 0x04)  # select the line while the harts are in reset
        await self.wait(8)
        await self.frame(0x30, 0x07)

    async def read(self, hart, count):
        replies = await self.frame(0x50 | hart, *([0] * count))
        return replies[1:]

    async def violations(self, hart):
        return (await self.frame(0x60 | hart, 0, 0))[1]


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = CSN
    dut.uio_in.value = 0xFF
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    host = Host(dut)
    await host.wait(4)
    return host


@cocotb.test()
async def test_uart_in_loopback(dut):
    """One program, two roles: hart 0 sends and hart 1 receives."""
    host = await start(dut)
    prog = protocols.uart(50)
    data = [0x55, 0xA3, 0x00, 0xFF]
    await host.load(prog)
    await host.setup(0, prog, "A")
    await host.setup(1, prog, "B")
    await host.push(0, data)
    await host.start_pair_in_loopback()
    await host.wait(50 * 50)
    assert await host.read(1, len(data)) == data
    assert await host.violations(1) == 0


@cocotb.test()
async def test_i2c_write_in_loopback(dut):
    """Open-drain, a clock, an address match, and the target's ACK."""
    host = await start(dut)
    prog = protocols.i2c(20)
    await host.load(prog)
    await host.setup(0, prog, "C")
    await host.setup(1, prog, "T", addr=0x42)
    await host.push(0, [0x42 << 1, 0x11, 0x22])
    await host.start_pair_in_loopback()
    await host.wait(1600)
    assert await host.read(1, 3) == [0x84, 0x11, 0x22]
    assert await host.violations(0) == 0
