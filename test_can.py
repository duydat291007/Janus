"""CAN hold-out. See KILL_TEST.md. Run: python test_can.py [mutants|stress]"""
import contextlib
import hashlib
import io
import random
import sys
import traceback

import protocols
import reference as ref
from janus import WITNESS, Bus, Hart, Prog
from protocols import R, S

BIT = 50
TESTS = []


def case(fn):
    TESTS.append(fn)
    return fn


def build():
    prog = protocols.can(BIT)
    return prog, Bus(prog.pins)


def queue(can_id, data):
    return [(can_id >> 8) << 5, can_id & 0xFF, len(data) << 1, *data]


def sender(prog, bus, can_id, data):
    return Hart(prog, S, bus, tx=queue(can_id, data))


def received(hart, source=None):
    """Frames seen by a hart, as (id, data)."""
    items = list(hart.rx_q if source is None else source)
    frames = []
    while len(items) >= 3:
        hi, lo, ctrl = items[:3]
        n = min(ctrl & 0xF, 8)
        frames.append((((hi & 7) << 8) | lo, items[3:3 + n]))
        items = items[3 + n:]
    return frames


def frame_ticks(*frames):
    return BIT * sum(len(ref.can_wire(i, d)) + 8 for i, d in frames) + BIT * 20


def simple(frame):
    return {k: frame[k] for k in ("id", "data")}


@case
def reference_crc_matches_published_check_value():
    bits = [(b >> i) & 1 for b in b"123456789" for i in range(7, -1, -1)]
    assert ref.crc15(bits) == 0x059E, hex(ref.crc15(bits))


@case
def limits():
    prog, _ = build()
    print(f"     {prog.name}: {len(prog.code)} instructions, "
          f"{prog.role_dependent_count()} role-dependent")
    assert prog.role_dependent_count() <= 3
    assert len(prog.code) <= 48


def pair(can_id, data):
    prog, bus = build()
    s = sender(prog, bus, can_id, data)
    r = Hart(prog, R, bus)
    w = Hart(prog, WITNESS, bus)
    bus.add(s, r, w)
    bus.run(frame_ticks((can_id, data)))
    assert received(r) == [(can_id, data)], received(r)
    assert received(w, w.seen) == [(can_id, data)], received(w, w.seen)
    assert (s.violations, r.violations, w.violations) == (0, 0, 0)
    frames = ref.decode_can(bus.trace, BIT)
    assert len(frames) == 1, frames
    assert frames[0]["crc_ok"] and frames[0]["acked"], frames
    assert simple(frames[0]) == {"id": can_id, "data": data}, frames


@case
def janus_pair_0_bytes():
    pair(0x123, [])


@case
def janus_pair_1_byte():
    pair(0x555, [0xA5])


@case
def janus_pair_8_bytes():
    pair(0x7F0, [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])


@case
def worst_case_stuffing_zeros():
    pair(0x000, [0x00] * 8)


@case
def worst_case_stuffing_ones():
    pair(0x7FF, [0xFF] * 8)


@case
def janus_sender_against_reference_receiver():
    prog, bus = build()
    s = sender(prog, bus, 0x2AB, [0xDE, 0xAD, 0xBE, 0xEF])
    r = ref.CanReceiver(bus, BIT)
    bus.add(s, r)
    bus.run(frame_ticks((0x2AB, [0, 0, 0, 0])))
    assert len(r.frames) == 1, r.frames
    assert simple(r.frames[0]) == {"id": 0x2AB, "data": [0xDE, 0xAD, 0xBE, 0xEF]}
    assert r.frames[0]["crc_ok"] and s.violations == 0


def from_reference(can_id, data, rate, crc_xor=0, bits=None):
    prog, bus = build()
    wire = bits or ref.can_wire(can_id, data, crc_xor)
    s = ref.CanSender(bus, [1] * 4 + wire, BIT * rate)
    r = Hart(prog, R, bus)
    w = Hart(prog, WITNESS, bus)
    bus.add(s, r, w)
    bus.run(BIT * (len(wire) + 40))
    return s, r, w


@case
def reference_sender_gets_ack_from_janus_receiver():
    s, r, w = from_reference(0x1C3, [1, 2, 3], 1.0)
    assert received(r) == [(0x1C3, [1, 2, 3])], received(r)
    assert s.acked is True, s.acked
    assert w.violations == 0


@case
def sender_half_percent_fast():
    data = [0xFF, 0x00, 0xAA, 0x55, 0xF0, 0x0F, 0xCC, 0x33]
    s, r, w = from_reference(0x3F1, data, 0.995)
    assert received(r) == [(0x3F1, data)], received(r)
    assert s.acked is True and w.violations == 0


@case
def sender_half_percent_slow():
    data = [0xFF, 0x00, 0xAA, 0x55, 0xF0, 0x0F, 0xCC, 0x33]
    s, r, w = from_reference(0x3F1, data, 1.005)
    assert received(r) == [(0x3F1, data)], received(r)
    assert s.acked is True and w.violations == 0


@case
def bad_crc_is_rejected_without_ack():
    s, r, w = from_reference(0x222, [9, 8, 7], 1.0, crc_xor=0x10)
    assert s.acked is False, s.acked
    assert r.violations >= 1 and w.violations >= 1, (r.violations, w.violations)


@case
def stuffing_violation_is_flagged():
    wire = [0] + [0] * 8 + [1] * 30  # six equal bits are illegal in a frame
    s, r, w = from_reference(0, [], 1.0, bits=wire)
    assert w.violations >= 1, w.violations


@case
def frame_with_no_ack_is_flagged_at_sender():
    prog, bus = build()
    s = sender(prog, bus, 0x111, [0x42])
    bus.add(s)
    bus.run(frame_ticks((0x111, [0x42])))
    assert s.violations >= 1, s.violations


@case
def arbitration_janus_pair():
    prog, bus = build()
    low = sender(prog, bus, 0x100, [0x5A])
    high = sender(prog, bus, 0x101, [0xA5])
    r = Hart(prog, R, bus)
    bus.add(low, high, r)
    bus.run(frame_ticks((0x100, [0x5A])))
    assert high.arb_lost and not low.arb_lost, (high.arb_lost, low.arb_lost)
    assert received(r) == [(0x100, [0x5A])], received(r)
    assert received(high) == [(0x100, [0x5A])], received(high)


@case
def arbitration_against_reference_sender():
    prog, bus = build()
    janus_low = sender(prog, bus, 0x0F0, [0x77])
    wire = ref.can_wire(0x0F1, [0x11])
    other = ref.CanSender(bus, wire, BIT, arb_end=12, start=40)
    r = ref.CanReceiver(bus, BIT)
    bus.add(janus_low, other, r)
    bus.run(frame_ticks((0x0F0, [0x77])))
    assert other.lost and not janus_low.arb_lost
    assert len(r.frames) == 1 and simple(r.frames[0]) == {"id": 0x0F0, "data": [0x77]}


def run_mutants():
    """Plant bugs and confirm these tests catch each one."""
    mode, resync, check, branch = Prog.mode, Hart._resync, Hart._check, Hart._branch

    def no_stuffing(self, **fields):
        if fields.get("stuff"):
            fields["stuff"] = 99
        mode(self, **fields)

    def wrong_poly(self, **fields):
        if "poly" in fields:
            fields["poly"] ^= 0x10
        mode(self, **fields)

    def no_arbitration(self, **fields):
        if fields.get("lose_to"):
            fields["lose_to"] = None
        mode(self, **fields)

    def crc_ignored(self, cond, label):
        return None if cond == "crc_bad" else branch(self, cond, label)

    plants = {"no stuffing, both sides": lambda: setattr(Prog, "mode", no_stuffing),
              "wrong CRC polynomial, both sides":
              lambda: setattr(Prog, "mode", wrong_poly),
              "no edge resync": lambda: setattr(Hart, "_resync", lambda s, v: None),
              "no arbitration": lambda: setattr(Prog, "mode", no_arbitration),
              "ACK and tail not checked":
              lambda: setattr(Hart, "_check", lambda s, src, seen: None),
              "CRC result ignored": lambda: setattr(Hart, "_branch", crc_ignored)}
    for name, plant in plants.items():
        plant()
        failed = []
        for fn in TESTS:
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    fn()
            except Exception:
                failed.append(fn.__name__)
        Prog.mode, Hart._resync, Hart._check, Hart._branch = mode, resync, check, branch
        print(f"{'CAUGHT' if failed else 'SURVIVED':8} {name}: {len(failed)} failed "
              f"{failed[:3]}")


def random_frame(rng):
    return rng.randrange(0x800), [rng.randrange(256) for _ in range(rng.randrange(9))]


def stress_once(rng):
    """One random scenario. Returns a failure description, or None."""
    a, b = random_frame(rng), random_frame(rng)
    prog, bus = build()
    kind = rng.randrange(4)
    if kind == 0:  # back-to-back frames between Janus nodes
        s = Hart(prog, S, bus, tx=[*queue(*a), *queue(*b)])
        r = Hart(prog, R, bus)
        bus.add(s, r)
        bus.run(frame_ticks(a, b))
        got = [(f["id"], f["data"]) for f in ref.decode_can(bus.trace, BIT)]
        return None if received(r) == [a, b] == got else f"pair {a} {b} {got}"
    if kind == 1:  # Janus sender, reference receiver
        s = sender(prog, bus, *a)
        r = ref.CanReceiver(bus, BIT)
        bus.add(s, r)
        bus.run(frame_ticks(a))
        ok = [(f["id"], f["data"], f["crc_ok"]) for f in r.frames] == [(*a, True)]
        return None if ok else f"to reference {a} {r.frames}"
    if kind == 2:  # offset reference sender, Janus receiver
        rate = 1 + rng.uniform(-0.005, 0.005)
        s = ref.CanSender(bus, [1] * 4 + ref.can_wire(*a), BIT * rate)
        r = Hart(prog, R, bus)
        bus.add(s, r)
        bus.run(BIT * (len(ref.can_wire(*a)) + 40))
        return None if received(r) == [a] and s.acked else f"offset {rate} {a}"
    if a[0] == b[0]:  # arbitration needs distinct IDs
        return None
    low, high = sorted((a, b))
    s1, s2 = sender(prog, bus, *low), sender(prog, bus, *high)
    r = Hart(prog, R, bus)
    bus.add(s1, s2, r)
    bus.run(frame_ticks(low))
    ok = s2.arb_lost and not s1.arb_lost and received(r) == [low]
    return None if ok else f"arbitration {low} {high}"


def run_stress():
    global BIT
    results = {}
    for bit in (50, 40, 30, 20, 16, 12, 10, 8):
        BIT = bit
        rng = random.Random(bit)
        problems = [p for p in (stress_once(rng) for _ in range(120)) if p]
        results[bit] = problems
        print(f"bit={bit:3} ticks ({25 / bit:.2f} Mbit/s at 25 MHz): "
              f"{120 - len(problems)}/120 clean", flush=True)
        if problems:
            print("    first:", str(problems[0])[:120])
    BIT = 50


def run_cases():
    failed = 0
    for fn in TESTS:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except Exception:
            failed += 1
            print(f"FAIL {fn.__name__}")
            print("    ", traceback.format_exc(limit=-1).strip().splitlines()[-1][:110])
    print(f"\n{len(TESTS) - failed}/{len(TESTS)} passed")
    return failed


if __name__ == "__main__":
    if "mutants" in sys.argv:
        run_mutants()
        sys.exit(0)
    if "stress" in sys.argv:
        run_stress()
        sys.exit(0)
    digest = hashlib.sha256(open("janus.py", "rb").read()).hexdigest()[:12]
    print(f"janus.py sha256 {digest}")
    sys.exit(1 if run_cases() else 0)
