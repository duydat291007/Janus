"""Generate host scripts that drive the whole chip through its SPI port.

Expected bytes come from running the same scenario on the Python model, which
is itself checked against independent reference devices by the test suites.

Run from the project root: python3 rtl/gen_chip.py <output-dir>
"""
import os
import sys

sys.path.insert(0, os.getcwd())

import encode  # noqa: E402
import protocols as p  # noqa: E402
from janus import PUSH_PULL, RESTART, STOP, WITNESS, Bus, Hart, Prog  # noqa: E402

CS_LOW, SEND, CS_HIGH, WAIT, EXPECT, PADS, PULL, WATCH = 1, 2, 3, 4, 5, 6, 7, 8
MARGIN = 400


class Script:
    def __init__(self):
        self.words = []

    def raw(self, kind, value=0):
        self.words.append(kind << 24 | value)

    def frame(self, *data):
        self.raw(CS_LOW)
        for byte in data:
            self.raw(SEND, byte)
        self.raw(CS_HIGH)

    def wait(self, ticks):
        self.raw(WAIT, ticks)

    def load(self, prog, base=0):
        for i, word in enumerate(encode.assemble(prog, base)):
            self.frame(0x10, base + i, *word.to_bytes(4, "big"))

    def reg(self, hart, reg, value):
        self.frame(0x20 | hart, reg, value >> 8, value & 0xFF)

    def setup(self, hart, prog, role, base=0, addr=0, rot=0):
        for i, word in enumerate(encode.config_words(prog, base)):
            self.reg(hart, i, word)
        self.reg(hart, 6, encode.ROLE[role])
        self.reg(hart, 7, addr or 0)
        self.reg(hart, 8, sum(1 << i for i, pin in enumerate(prog.pins) if prog.pins[pin]))
        self.reg(hart, 9, rot)
        self.reg(hart, 10, base)

    def push(self, hart, items):
        for item in items:
            ctl = 1 if item is STOP else 2 if item is RESTART else 0
            self.frame(0x40 | hart, ctl, 0 if ctl else item)

    def run(self, hart0, hart1, loopback):
        self.frame(0x30, loopback << 2)  # choose the line while harts are in reset
        self.wait(8)
        self.frame(0x30, hart0 | hart1 << 1 | loopback << 2)

    def expect_rx(self, hart, data):
        if not data:
            return
        self.raw(CS_LOW)
        self.raw(SEND, 0x50 | hart)
        for byte in data:
            self.raw(EXPECT, byte)
        self.raw(EXPECT, 0)  # one past the end: an empty FIFO reads as 0
        self.raw(CS_HIGH)

    def expect_status(self, hart, violations, flag_mask, flags):
        """Reads back the violation count, then checks all flags given."""
        self.raw(CS_LOW)
        self.raw(SEND, 0x60 | hart)
        self.raw(EXPECT, violations)
        self.raw(EXPECT, flags)
        self.raw(CS_HIGH)

    def write(self, path):
        self.raw(0)
        with open(path, "w") as f:
            f.writelines(f"{w:08x}\n" for w in self.words)


RX_EMPTY, TX_EMPTY = 1, 4


def decoy():
    prog = Prog("decoy", {"TX": PUSH_PULL})
    prog.label("here")
    prog.jump("here")
    return prog


def back_to_back_loads(bit):
    """Two queue reads on consecutive ticks: a stale head sends the wrong byte."""
    q = Prog("loads", {"TX": PUSH_PULL})
    q.set("TX", "A", 1)
    q.label("idle")
    q.claim("A", "TX")
    q.load("A")
    q.load("A")
    q.step("TX", "A", 0, bit, sync=True)
    q.bits("TX", "A", 8, dwell=bit)
    q.store("B")
    q.step("TX", "A", 1, bit)
    q.jump("idle")
    return q


def load_then_choice(bit):
    """A queue test on the tick after a load: a stale empty flag changes the path."""
    q = Prog("choice", {"TX": PUSH_PULL})
    q.set("TX", "A", 1)
    q.label("idle")
    q.claim("A", "TX")
    q.load("A")
    q.choice("A", [None], "send")
    q.load("A", imm=0x3C)
    q.label("send")
    q.step("TX", "A", 0, bit, sync=True)
    q.bits("TX", "A", 8, dwell=bit)
    q.store("B")
    q.step("TX", "A", 1, bit)
    q.jump("idle")
    return q


def model(prog, role0, role1, tx0=(), tx1=(), addr0=None, addr1=None, ticks=0):
    """Run the scenario on the model. Returns the two finished harts."""
    bus = Bus(prog.pins)
    h0 = Hart(prog, role0, bus, addr=addr0, tx=tx0)
    h1 = Hart(prog, role1, bus, addr=addr1, tx=tx1)
    bus.add(h0, h1)
    bus.run(ticks)
    return h0, h1


def scenario(out, name, prog, role0, role1, tx0=(), tx1=(), addr0=None, addr1=None,
             ticks=0, base=0, rot=0, loopback=1, undriven_pin=False, clocks_per_tick=1):
    h0, h1 = model(prog, role0, role1, tx0, tx1, addr0, addr1, ticks)
    assert not h0.tx_q and not h1.tx_q or role0 == "S", name
    s = Script()
    if loopback:
        s.raw(PADS, 1)  # hold the pads low: loopback must not depend on them
    elif all(prog.pins.values()):
        s.raw(WATCH, 0xFF)  # an open-drain pin must never drive high
    elif not undriven_pin:
        s.raw(PULL, 0)  # a pull-down: push-pull pins must really drive high
    if base:
        trap = decoy()
        for i in range(base):  # a hart that starts here never leaves
            s.frame(0x10, i, *encode.encode(trap, trap.code[0]).to_bytes(4, "big"))
    s.load(prog, base)
    s.setup(0, prog, role0, base, addr0, rot)
    s.setup(1, prog, role1, base, addr1, rot)
    s.push(0, tx0)
    s.push(1, tx1)
    s.run(1, 1, loopback)
    s.wait(ticks * clocks_per_tick + MARGIN)
    for hart, h in ((0, h0), (1, h1)):
        data = list(h.seen) if h.role == WITNESS and h.seen else list(h.rx_q)
        s.expect_rx(hart, data)
        flags = RX_EMPTY | (TX_EMPTY if not h.tx_q else 0)
        s.expect_status(hart, h.violations, 0xFF, flags)
    s.write(os.path.join(out, f"{name}.hex"))
    return len(h0.rx_q) + len(h1.rx_q) + len(h0.seen) + len(h1.seen)


def streaming(out):
    """Twenty bytes through 8-entry FIFOs, while the protocol runs."""
    prog = p.uart(50)
    data = [(i * 37 + 11) & 0xFF for i in range(20)]
    s = Script()
    s.load(prog)
    s.setup(0, prog, "A", 0, None, 0)
    s.setup(1, prog, "B", 0, None, 0)
    s.run(1, 1, 1)
    for chunk in range(0, 20, 4):
        part = data[chunk:chunk + 4]
        s.push(0, part)
        s.wait(50 * 11 * len(part) + MARGIN)
        s.expect_rx(1, part)
    s.expect_status(1, 0, 0xFF, RX_EMPTY | TX_EMPTY)
    s.write(os.path.join(out, "uart_streaming.hex"))


def stuck_pins(out):
    """External mode with the pads held high: the receiver must see nothing."""
    prog = p.uart(50)
    s = Script()
    s.raw(PADS, 3)
    s.load(prog)
    s.setup(0, prog, "A", 0, None, 0)
    s.setup(1, prog, "B", 0, None, 0)
    s.push(0, [0x55])
    s.run(1, 1, 0)
    s.wait(50 * 14)
    s.expect_status(1, 0, 0xFF, RX_EMPTY | TX_EMPTY)
    s.write(os.path.join(out, "uart_pads_stuck.hex"))


def can_tx(can_id, data):
    return [(can_id >> 8) << 5, can_id & 0xFF, len(data) << 1, *data]


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    counts = {}
    data = [0x55, 0xA3, 0x00, 0xFF, 0x7E]
    for loop in (1, 0):
        tag = "loop" if loop else "pins"

        def add(name, *args, **kwargs):
            name = f"{name}_{tag}"
            counts[name] = scenario(out, name, *args, loopback=loop, **kwargs)

        add("uart", p.uart(50), "A", "B", tx0=data, ticks=50 * 62)
        add("queue_back_to_back", back_to_back_loads(50), "A", "B", tx0=[1, 2, 3, 4],
            ticks=50 * 26)
        add("queue_choice_after_load", load_then_choice(50), "A", "B", tx0=[0x5A],
            ticks=50 * 13)
        add("uart_witness", p.uart(50), "A", WITNESS, tx0=data, ticks=50 * 62)
        add("uart_at_address_20", p.uart(50), "A", "B", tx0=data, ticks=50 * 62, base=20)
        # The top words of the 64-word memory: words 56 to 63.
        add("uart_at_address_56", p.uart(50), "A", "B", tx0=data, ticks=50 * 62, base=56)
        add("uart_rotated_pins", p.uart(50), "A", "B", tx0=data, ticks=50 * 62, rot=3)
        for mode, (cpol, cpha) in enumerate(((0, 0), (0, 1), (1, 0), (1, 1))):
            add(f"spi_mode{mode}", p.spi(10, cpol, cpha), "C", "T",
                tx0=[0x12, 0xA5, 0xFF, 0x00], tx1=[0xDE, 0xAD, 0xBE, 0xEF], ticks=1200)
        add("spi_witness", p.spi(10), "C", WITNESS, tx0=[0x12, 0xA5], ticks=800,
            undriven_pin=True)  # no target, so nothing drives MISO
        add("i2c_write", p.i2c(20), "C", "T", tx0=[0x84, 0x11, 0x22], addr1=0x42, ticks=1600)
        add("i2c_read", p.i2c(20), "C", "T", tx0=[0x85, 0x00, 0x00, 0xFF],
            tx1=[0xAA, 0x0F, 0x81], addr1=0x42, ticks=2000)
        add("i2c_restart", p.i2c(20), "C", "T", tx0=[0x84, 0x07, RESTART, 0x85, 0xFF],
            tx1=[0x5C], addr1=0x42, ticks=2200)
        add("i2c_no_target", p.i2c(20), "C", "T", tx0=[0x20], addr1=0x42, ticks=800)
        add("onewire", p.onewire(), "C", "T", tx0=[0x33, 0xFF, 0xFF],
            tx1=[0x28, 0xC3], ticks=3500)
        # Real 1-Wire timing at 25 MHz: the prescaler makes each tick 1 us.
        add("onewire_25mhz_real_timing", p.onewire(24), "C", "T", tx0=[0x33, 0xFF, 0xFF],
            tx1=[0x28, 0xC3], ticks=3500, clocks_per_tick=25)
        add("can_0_bytes", p.can(50), "S", "R", tx0=can_tx(0x123, []), ticks=50 * 70)
        add("can_5_bytes", p.can(50), "S", "R", tx0=can_tx(0x7F0, [1, 2, 3, 4, 5]),
            ticks=50 * 110)
        add("can_stuffing", p.can(50), "S", "R", tx0=can_tx(0x000, [0, 0, 0, 0, 0]),
            ticks=50 * 125)
    streaming(out)
    counts["uart_streaming"] = 20
    stuck_pins(out)
    counts["uart_pads_stuck"] = 0
    for name, n in counts.items():
        print(name, n)


if __name__ == "__main__":
    main()
