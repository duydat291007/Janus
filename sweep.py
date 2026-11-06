"""Random-data stress and maximum-speed measurement for SPI and I2C.

Speeds assume a 50 MHz core clock, which is an assumption, not a measured limit.
"""
import random

import reference as ref
from janus import RESTART, Bus, Hart
from protocols import C, T, i2c, spi

MODES = [(0, 0), (0, 1), (1, 0), (1, 1)]
CLOCK_MHZ = 50
SEEDS = 40


def spi_ok(half, cpol, cpha, data, reply, kind):
    prog = spi(half, cpol, cpha)
    bus = Bus(prog.pins)
    if kind == "janus target":
        c = ref.SpiController(bus, data, half, cpol, cpha)
        t = Hart(prog, T, bus, tx=reply)
        bus.add(c, t)
        bus.run(half * 40 * (len(data) + 2))
        return c.got == reply and list(t.rx_q) == data
    if kind == "janus controller":
        c = Hart(prog, C, bus, tx=data)
        t = ref.SpiTarget(bus, reply, cpol, cpha)
        bus.add(c, t)
        bus.run(half * 40 * (len(data) + 2))
        return list(c.rx_q) == reply and t.got == data
    c = Hart(prog, C, bus, tx=data)
    t = Hart(prog, T, bus, tx=reply)
    bus.add(c, t)
    bus.run(half * 40 * (len(data) + 2))
    return list(c.rx_q) == reply and list(t.rx_q) == data


def i2c_ok(half, wdata, rdata):
    prog = i2c(half)
    bus = Bus(prog.pins)
    acks = [0x00] * (len(rdata) - 1) + [0xFF]
    tx = [0x42 << 1, *wdata, RESTART, 0x42 << 1 | 1, *acks]
    c = Hart(prog, C, bus, tx=tx)
    t = Hart(prog, T, bus, addr=0x42, tx=rdata)
    bus.add(c, t)
    bus.run(half * 40 * (len(wdata) + len(rdata) + 4))
    return list(c.rx_q) == rdata and list(t.rx_q)[1:1 + len(wdata)] == wdata


def spi_passes(half, kind):
    for seed in range(SEEDS):
        rng = random.Random(seed)
        data = [rng.randrange(256) for _ in range(6)]
        reply = [rng.randrange(256) for _ in range(6)]
        if not all(spi_ok(half, *m, data, reply, kind) for m in MODES):
            return False
    return True


def i2c_passes(half):
    for seed in range(SEEDS):
        rng = random.Random(seed)
        wdata = [rng.randrange(256) for _ in range(3)]
        rdata = [rng.randrange(256) for _ in range(3)]
        if not i2c_ok(half, wdata, rdata):
            return False
    return True


def scl_ticks(half):
    """Measured median SCL period: the controller's settle wait stretches it."""
    prog = i2c(half)
    bus = Bus(prog.pins)
    bus.add(Hart(prog, C, bus, tx=[0x42 << 1, 0xA5]),
            Hart(prog, T, bus, addr=0x42))
    bus.run(half * 200)
    line = [t["SCL"] for t in bus.trace]
    rises = [i for i in range(1, len(line)) if line[i] and not line[i - 1]]
    periods = sorted(b - a for a, b in zip(rises, rises[1:]))
    return periods[len(periods) // 2]


def fastest(passes):
    """Smallest half-period at which it and everything slower still pass."""
    best = None
    for half in range(40, 1, -1):
        if not passes(half):
            break
        best = half
    return best


if __name__ == "__main__":
    for kind in ("janus controller", "janus target", "janus pair"):
        h = fastest(lambda half: spi_passes(half, kind))
        print(f"SPI {kind}: min half={h} ticks, "
              f"{CLOCK_MHZ / (2 * h):.2f} MHz at {CLOCK_MHZ} MHz core")
    h = fastest(i2c_passes)
    period = scl_ticks(h)
    print(f"I2C pair: min half={h} ticks, measured SCL period {period} ticks, "
          f"{CLOCK_MHZ * 1000 / period:.0f} kHz at {CLOCK_MHZ} MHz core")
