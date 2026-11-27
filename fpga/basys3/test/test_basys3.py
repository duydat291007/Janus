"""The Basys 3 build in simulation: the PC's UART, the bridge, the chip and
the Pmod pins, driven with the host driver's frames as a PC would."""
import pathlib
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import FallingEdge, Timer, with_timeout

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "host"))

import janus_host as jh  # noqa: E402
import protocols  # noqa: E402

BIT_NS = 1000          # 1 Mbaud


class Pc:
    """The PC end of the USB-UART: frames out, replies in."""

    def __init__(self, dut):
        self.dut = dut
        self.rx = Queue()
        cocotb.start_soon(self.listen())

    async def send(self, byte):
        line = self.dut.RsRx
        for level in [0] + [(byte >> i) & 1 for i in range(8)] + [1]:
            line.value = level
            await Timer(BIT_NS, unit="ns")

    async def listen(self):
        tx = self.dut.RsTx
        while True:
            await FallingEdge(tx)
            await Timer(BIT_NS * 3 // 2, unit="ns")
            value = 0
            for i in range(8):
                value |= int(tx.value) << i
                await Timer(BIT_NS, unit="ns")
            assert int(tx.value) == 1, "the bridge sent a byte with no stop bit"
            await self.rx.put(value)

    async def reply(self):
        return await with_timeout(self.rx.get(), 200, "us")

    async def transfer(self, data):
        for byte in bytes((len(data),)) + bytes(data):
            await self.send(byte)
        return [await self.reply() for _ in data]


async def boot(dut):
    """The board as after power-up. The tests share one simulation, so each
    presses the centre button; cocotb stops each test's clock when it ends."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())   # 100 MHz
    dut.sw.value = 0
    dut.RsRx.value = 1
    dut.btnC.value = 1
    await Timer(1, unit="us")
    dut.btnC.value = 0
    await Timer(20, unit="us")            # the reset runs out
    return Pc(dut)


async def configure(pc, hart, image, role):
    """As Janus.configure in host/janus_host.py does it."""
    for i, word in enumerate(image["config"]):
        await pc.transfer(jh.frame_register(hart, jh.REG_TRAPS + i, word))
    for reg, value in ((jh.REG_ROLE, jh.ROLE[role]), (jh.REG_ADDR, 0), (jh.REG_OD_MASK, image["od_mask"]),
                       (jh.REG_ROT, 0), (jh.REG_START, image["base"]), (jh.REG_FAULT, 0)):
        await pc.transfer(jh.frame_register(hart, reg, value))


async def run_uart(pc, loopback, message=(0x4A, 0x61, 0x6E, 0x75, 0x73)):
    image = jh.program_image(protocols.uart(50))
    await pc.transfer(jh.frame_control(False, False, loopback))
    for i, word in enumerate(image["words"]):
        await pc.transfer(jh.frame_program_word(image["base"] + i, word))
    for hart, role in ((0, "A"), (1, "B")):
        await configure(pc, hart, image, role)
    for byte in message:
        await pc.transfer(jh.frame_push(0, byte))
    await pc.transfer(jh.frame_control(True, True, loopback))
    await Timer(len(message) * 10 * 50 * 40 + 20_000, unit="ns")   # 50 ticks of 40 ns a bit
    got = jh.parse_read(await pc.transfer(jh.frame_read(1, len(message))))
    violations = jh.parse_status(await pc.transfer(jh.frame_status(1)))[0]
    return image, got, violations


@cocotb.test()
async def test_link_check(dut):
    """A length of 0 is answered with the bridge's ID."""
    pc = await boot(dut)
    await pc.send(0)
    assert await pc.reply() == 0xA5


@cocotb.test()
async def test_program_reads_back(dut):
    """Every word written through the UART reads back through frame 7h."""
    pc = await boot(dut)
    image = jh.program_image(protocols.uart(50))
    for i, word in enumerate(image["words"]):
        await pc.transfer(jh.frame_program_word(image["base"] + i, word))
    for i, word in enumerate(image["words"]):
        await pc.transfer(jh.frame_register(0, jh.REG_START, image["base"] + i))
        assert jh.parse_where(await pc.transfer(jh.frame_where(0)))["word"] == word, i


@cocotb.test()
async def test_uart_inside_the_chip(dut):
    """Hart 0 sends to hart 1 through the chip's internal loopback."""
    pc = await boot(dut)
    _, got, violations = await run_uart(pc, loopback=True)
    assert bytes(got) == b"Janus" and violations == 0, (got, violations)


@cocotb.test()
async def test_uart_over_the_pmod_pins(dut):
    """The same over JA1: the bytes leave and re-enter the FPGA's pins, and
    the line idles high on its pull-up."""
    pc = await boot(dut)
    _, got, violations = await run_uart(pc, loopback=False)
    assert bytes(got) == b"Janus" and violations == 0, (got, violations)
    assert int(dut.led.value) >> 6 & 1 == 1, "JA1 does not idle high"


@cocotb.test()
async def test_a_stalled_frame_ends(dut):
    """A frame the PC stops halfway through is ended after the timeout, and the
    next frame works."""
    pc = await boot(dut)
    await pc.send(3)
    await pc.send(0x60)                   # a status frame, cut short
    await pc.reply()
    await Timer(11, unit="ms")
    await pc.send(0)
    assert await pc.reply() == 0xA5
