"""Low-speed USB hold-out. See KILL_TEST.md. Run: python test_usb.py

Stage 1, frozen ISA. The host pre-computes NRZI, stuffing and CRCs, as the
rules allow, and the program sends the result. A timed `bits` instruction
drives one pin, and `set` drives a constant, so no program can drive D- as
the complement of data on D+. This run shows the consequence.
"""
import sys
import traceback

import reference as ref
from janus import Hart, Prog, PUSH_PULL

BIT = 16                      # ticks per USB bit
TESTS = []


def case(fn):
    TESTS.append(fn)
    return fn


def frozen_program():
    """Best effort on the frozen ISA: send host-coded D+ levels, 8 per byte."""
    p = Prog("usb_stage1", {"DP": PUSH_PULL, "DM": PUSH_PULL})
    p.set("DP", "A", 0)        # idle J: D+ low ...
    p.set("DM", "A", 1)        # ... and D- high
    p.label("idle")
    p.claim("A", "DP")
    p.load("A")
    p.bits("DP", "A", 8, dwell=BIT)
    p.jump("idle")
    return p


def dp_bytes(states):
    """Host pre-coding: the D+ level of each line state, packed LSB first."""
    levels = [dp for dp, _ in states]
    levels += [levels[-1]] * (-len(levels) % 8)
    return [sum(levels[i + j] << j for j in range(8)) for i in range(0, len(levels), 8)]


@case
def janus_host_to_reference_decoder():
    token = ref.usb_line(ref.usb_packet_bits(ref.PID_OUT, addr=5, endp=1))
    data = ref.usb_line(ref.usb_packet_bits(ref.PID_DATA0, data=list(range(8))))
    bus = ref.UsbBus()
    host = Hart(frozen_program(), "A", bus, tx=dp_bytes(token) + dp_bytes(data))
    bus.add(host)
    bus.run(BIT * 400)
    packets = ref.usb_decode(bus.trace, BIT)
    k_states = sum(1 for t in bus.trace if (t["DP"], t["DM"]) == ref.K)
    print(f"     decoded packets: {len(packets)}; ticks in state K: {k_states}")
    assert [p["pid"] for p in packets] == [ref.PID_OUT, ref.PID_DATA0], packets


@case
def limits():
    prog = frozen_program()
    assert prog.role_dependent_count() <= 3
    assert len(prog.code) <= 48


if __name__ == "__main__":
    failed = 0
    for fn in TESTS:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except Exception:
            failed += 1
            print(f"FAIL {fn.__name__}")
            print("    ", traceback.format_exc(limit=-1).strip().splitlines()[-1][:160])
    print(f"\n{len(TESTS) - failed}/{len(TESTS)} passed")
    sys.exit(1 if failed else 0)
