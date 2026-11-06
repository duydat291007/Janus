"""1-Wire hold-out. See KILL_TEST.md. Run: python test_onewire.py"""
import contextlib
import hashlib
import io
import sys
import traceback

import janus
import protocols
import reference as ref
from janus import WITNESS, Bus, Hart, Prog
from protocols import C, T

ROM = [0x28, 0xFF, 0x4C, 0x01, 0xA5, 0x00, 0x5A, 0xE3]
CMD = 0x33
SLOT = 200  # generous ticks per slot
TESTS = []


def case(fn):
    TESTS.append(fn)
    return fn


def build():
    prog = protocols.onewire()
    return prog, Bus(prog.pins)


def controller_queue(n):
    return [CMD, *[0xFF] * n]


def expected_events(n):
    return ["R", "P", CMD, *ROM[:n]]


@case
def limits():
    prog, _ = build()
    print(f"     {prog.name}: {len(prog.code)} instructions, "
          f"{prog.role_dependent_count()} role-dependent")
    assert prog.role_dependent_count() <= 3
    assert len(prog.code) <= 48, f"{len(prog.code)} instructions"


@case
def janus_pair_and_decoder():
    prog, bus = build()
    c = Hart(prog, C, bus, tx=controller_queue(8))
    t = Hart(prog, T, bus, tx=ROM)
    w = Hart(prog, WITNESS, bus)
    bus.add(c, t, w)
    bus.run(1500 + SLOT * 80)
    assert c.rx_q[0] >> 7 == 0, "no presence seen"
    assert list(c.rx_q)[1:] == ROM, list(c.rx_q)
    assert t.rx_q[0] == CMD, t.rx_q
    assert list(w.seen)[1:] == [CMD, *ROM], list(w.seen)
    assert w.violations == 0, w.violations
    events = ref.decode_onewire(bus.trace)
    assert events == expected_events(8), events


@case
def janus_controller_against_reference_target():
    prog, bus = build()
    c = Hart(prog, C, bus, tx=controller_queue(8))
    t = ref.OneWireTarget(bus, ROM)
    bus.add(c, t)
    bus.run(1500 + SLOT * 80)
    assert c.rx_q and c.rx_q[0] >> 7 == 0, "no presence seen"
    assert t.got == [CMD], t.got
    assert list(c.rx_q)[1:] == ROM, list(c.rx_q)


@case
def janus_target_against_reference_controller():
    prog, bus = build()
    c = ref.OneWireController(bus, [("reset",), ("write", CMD), ("read", 8)])
    t = Hart(prog, T, bus, tx=ROM)
    w = Hart(prog, WITNESS, bus)
    bus.add(c, t, w)
    bus.run(1500 + SLOT * 80)
    assert c.presence == [True], c.presence
    assert list(t.rx_q) == [CMD], t.rx_q
    assert c.got == ROM, c.got
    assert w.violations == 0, w.violations


@case
def no_device_is_detected():
    prog, bus = build()
    c = Hart(prog, C, bus, tx=controller_queue(1))
    bus.add(c)
    bus.run(1500 + SLOT * 30)
    assert c.rx_q[0] >> 7 == 1, "presence reported with no device"
    assert ref.decode_onewire(bus.trace)[:2] != ["R", "P"]


@case
def reset_in_the_middle_of_a_read():
    prog, bus = build()
    c = ref.OneWireController(bus, [("reset",), ("write", CMD), ("read", 2),
                                    ("reset",), ("write", 0xCC), ("read", 1)])
    t = Hart(prog, T, bus, tx=ROM + [0x77])
    w = Hart(prog, WITNESS, bus)
    bus.add(c, t, w)
    bus.run(3000 + SLOT * 80)
    assert c.presence == [True, True], c.presence
    assert list(t.rx_q) == [CMD, 0xCC], t.rx_q
    assert w.violations == 0, w.violations


@case
def witness_flags_a_held_low_line():
    prog, bus = build()
    # 200 is illegal: past the 120 maximum for a slot, short of a reset.
    c = ref.OneWireController(bus, [("reset",), ("long_low", 200)])
    t = ref.OneWireTarget(bus, ROM)
    w = Hart(prog, WITNESS, bus)
    bus.add(c, t, w)
    bus.run(2000)
    assert w.violations >= 1, w.violations


def run_mutants():
    """Plant bugs and confirm these tests catch each one."""
    timed, branch = Hart._timed_bit, Hart._branch

    def inverted_on_both_sides(self, pin, owner, src, dwell, sync, free=False, data=None):
        if src != "tx":
            return (yield from timed(self, pin, owner, src, dwell, sync, free, data))
        self.tx ^= 0xFF
        seen = yield from timed(self, pin, owner, src, dwell, sync, free, data)
        self.tx ^= 0x7F
        self.rx[0] ^= 0x80
        return seen

    def one_slot_short(self, cond, label):
        if cond == "loop":
            self.count -= 1
        return branch(self, cond, label)

    def no_width_traps():
        Prog.hold_trap = lambda *args: None

    hold_trap = Prog.hold_trap
    mutants = {"bit polarity inverted on both sides":
               lambda: setattr(Hart, "_timed_bit", inverted_on_both_sides),
               "wrong input lag": lambda: setattr(janus, "SYNC_LAG", 1),
               "wrong slot count": lambda: setattr(Hart, "_branch", one_slot_short),
               "no pulse-width traps": no_width_traps}
    for name, plant in mutants.items():
        plant()
        failed = []
        for fn in TESTS:
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    fn()
            except Exception:
                failed.append(fn.__name__)
        Hart._timed_bit, Hart._branch, Prog.hold_trap = timed, branch, hold_trap
        janus.SYNC_LAG = 2
        print(f"{'CAUGHT' if failed else 'SURVIVED':8} {name}: {failed}")


if __name__ == "__main__":
    if "mutants" in sys.argv:
        run_mutants()
        sys.exit(0)
    digest = hashlib.sha256(open("janus.py", "rb").read()).hexdigest()[:12]
    print(f"janus.py sha256 {digest}")
    failed = 0
    for fn in TESTS:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except Exception:
            failed += 1
            print(f"FAIL {fn.__name__}")
            print("    ", traceback.format_exc(limit=-1).strip().splitlines()[-1])
    print(f"\n{len(TESTS) - failed}/{len(TESTS)} passed")
    sys.exit(1 if failed else 0)
