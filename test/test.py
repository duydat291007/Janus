# SPDX-License-Identifier: Apache-2.0
"""End-to-end tests through the chip's SPI host port. The Tiny Tapeout flow runs
these on the RTL and again on the gate-level netlist."""

import pathlib
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "host"))

import janus_host as jh  # noqa: E402
import protocols  # noqa: E402

HALF = 4  # SCK half period, in clock cycles
SCK, MOSI, CSN = 1, 2, 4


class Host:
    """A bit-banged SPI host on ui_in, with MISO on uo_out[0]. It only moves
    bytes; frame layouts and reply parsing come from host/janus_host.py, the
    same driver a microcontroller uses. `gap` is the pause after each byte, in
    clock cycles: 0 sends bytes back to back, as hardware SPI does."""

    def __init__(self, dut, gap=HALF):
        self.dut = dut
        self.pins = CSN
        self.gap = gap

    def drive(self):
        self.dut.ui_in.value = self.pins

    async def wait(self, cycles):
        if cycles:
            await ClockCycles(self.dut.clk, cycles)
        await FallingEdge(self.dut.clk)

    async def transfer_byte(self, byte):
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
        if self.gap:
            await self.wait(self.gap)
        return value

    async def transfer(self, data):
        """One frame: chip select low, the bytes, chip select high."""
        self.pins = 0
        self.drive()
        await self.wait(HALF)
        replies = [await self.transfer_byte(byte) for byte in data]
        await self.wait(HALF)
        self.pins = CSN
        self.drive()
        await self.wait(2 * HALF)
        return replies

    async def load(self, image):
        for i, word in enumerate(image["words"]):
            await self.transfer(jh.frame_program_word(image["base"] + i, word))

    async def configure(self, hart, image, role, addr=0):
        for i, word in enumerate(image["config"]):
            await self.transfer(jh.frame_register(hart, jh.REG_TRAPS + i, word))
        await self.transfer(jh.frame_register(hart, jh.REG_ROLE, jh.ROLE[role]))
        await self.transfer(jh.frame_register(hart, jh.REG_ADDR, addr))
        await self.transfer(jh.frame_register(hart, jh.REG_OD_MASK, image["od_mask"]))

    async def push(self, hart, data):
        for byte in data:
            await self.transfer(jh.frame_push(hart, byte))

    async def start_pair_in_loopback(self):
        await self.transfer(jh.frame_control(False, False, True))  # line first
        await self.wait(8)
        await self.transfer(jh.frame_control(True, True, True))

    async def read(self, hart, count):
        return jh.parse_read(await self.transfer(jh.frame_read(hart, count)))

    async def violations(self, hart):
        return jh.parse_status(await self.transfer(jh.frame_status(hart)))[0]


async def start(dut, gap=HALF):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = CSN
    dut.uio_in.value = 0xFF
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    host = Host(dut, gap)
    await host.wait(4)
    return host


@cocotb.test()
async def test_uart_in_loopback(dut):
    """One program, two roles: hart 0 sends and hart 1 receives."""
    host = await start(dut)
    image = jh.program_image(protocols.uart(50))
    data = [0x55, 0xA3, 0x00, 0xFF]
    await host.load(image)
    await host.configure(0, image, "A")
    await host.configure(1, image, "B")
    await host.push(0, data)
    await host.start_pair_in_loopback()
    await host.wait(50 * 50)
    assert await host.read(1, len(data)) == data
    assert await host.violations(1) == 0


@cocotb.test()
async def test_i2c_write_in_loopback(dut):
    """Open-drain, a clock, an address match, and the target's ACK."""
    host = await start(dut)
    image = jh.program_image(protocols.i2c(20))
    await host.load(image)
    await host.configure(0, image, "C")
    await host.configure(1, image, "T", addr=0x42)
    await host.push(0, [0x42 << 1, 0x11, 0x22])
    await host.start_pair_in_loopback()
    await host.wait(1600)
    assert await host.read(1, 3) == [0x84, 0x11, 0x22]
    assert await host.violations(0) == 0


@cocotb.test()
async def test_back_to_back_bytes_like_hardware_spi(dut):
    """Hardware SPI sends bytes with no gap. At the fastest legal SCK, 1/8 of
    the clock, frames must still work, including a multi-byte read stream."""
    host = await start(dut, gap=0)
    image = jh.program_image(protocols.uart(50))
    data = [0x4A, 0x61, 0x6E, 0x75, 0x73]
    await host.load(image)
    await host.configure(0, image, "A")
    await host.configure(1, image, "B")
    await host.push(0, data)
    await host.start_pair_in_loopback()
    await host.wait(50 * 62)
    assert await host.read(1, len(data) + 1) == data + [0]
    assert await host.violations(1) == 0


@cocotb.test()
async def test_driver_class_drives_the_chip(dut):
    """The Janus class a microcontroller uses: record the frames it sends for
    setup, play them into the chip, then check an I2C write gets through."""
    host = await start(dut)
    frames = []
    chip = jh.Janus(lambda data: frames.append(bytes(data)) or bytes(len(data)))
    image = jh.program_image(protocols.i2c(20))
    chip.load(image["words"], image["base"])
    chip.configure(0, image, "C")
    chip.configure(1, image, "T", addr=0x42)
    chip.push(0, [0x42 << 1, 0x5A])
    chip.run(True, True, loopback=True)
    assert frames[-2] == jh.frame_control(False, False, True)  # line before run
    for frame in frames:
        await host.transfer(frame)
    await host.wait(1200)
    assert await host.read(1, 2) == [0x84, 0x5A]
    assert await host.violations(0) == 0
