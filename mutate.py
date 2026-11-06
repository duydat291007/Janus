"""Do the tests have teeth? Plant bugs and confirm the suite catches each one.

The first two mutants are self-consistent: both Janus sides change together,
so a Janus-only test would pass. Only the independent reference can catch them.
"""
import contextlib
import io

import janus
import test_janus as suite
from janus import Hart, Prog


def failing_tests():
    failed = []
    for name, fn, args in suite.TESTS:
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                fn(*args)
        except Exception:
            failed.append(name)
    return failed


def lsb_first_out(self, lanes):
    for pin, owner in lanes:
        if self._mine(owner):
            self._drive(pin, self.tx & 1)
            self.tx >>= 1
        else:
            self._drive(pin, None)


original_sample = Hart._sample


def lsb_first_in(self, clk, lanes):
    original_sample(self, clk, lanes)
    for i in range(len(lanes)):
        low = self.rx[i] & 1
        self.rx[i] = ((self.rx[i] >> 1) & 0x7F) | (low << 7)


def bit_reversed_on_both_sides():
    Hart._lanes_out, Hart._sample = lsb_first_out, lsb_first_in


original_branch, original_load = Hart._branch, Hart._load


def ack_polarity_inverted_on_both_sides():
    swap = {"last0": "last1", "last1": "last0"}
    Hart._branch = lambda self, cond, label: original_branch(
        self, swap.get(cond, cond), label)
    Hart._load = lambda self, party, imm: original_load(
        self, party, None if imm is None else imm ^ 0xFF)


def witness_never_flags_mid_byte_end():
    Hart.partial = property(lambda self: 0, lambda self, value: None)


def unaddressed_target_never_steps_aside():
    Hart._match = lambda self, party, shift: None


def receiver_samples_at_bit_start():
    original = Hart._timed_bit

    def early(self, pin, owner, src, dwell, sync, free=False, data=None):
        short = 2 if src == "tx" else dwell
        return (yield from original(self, pin, owner, src, short, sync, free, data))
    Hart._timed_bit = early


def spi_sampling_edge_swapped():
    original = Prog.mode

    def swapped(self, **fields):
        if "cpha" in fields:
            fields["cpha"] = 1 - fields["cpha"]
        original(self, **fields)
    Prog.mode = swapped


def no_clock_stretch_wait():
    Hart._settled = lambda self, pin, val: iter(())


MUTANTS = [bit_reversed_on_both_sides, ack_polarity_inverted_on_both_sides,
           witness_never_flags_mid_byte_end, unaddressed_target_never_steps_aside,
           receiver_samples_at_bit_start, spi_sampling_edge_swapped,
           no_clock_stretch_wait]

if __name__ == "__main__":
    saved_hart, saved_prog = dict(vars(Hart)), dict(vars(Prog))
    survivors = 0
    for mutant in MUTANTS:
        mutant()
        failed = failing_tests()
        for cls, saved in ((Hart, saved_hart), (Prog, saved_prog)):
            for key in set(vars(cls)) - set(saved):
                delattr(cls, key)
            for key, value in saved.items():
                if key not in ("__dict__", "__weakref__"):
                    setattr(cls, key, value)
        survivors += not failed
        verdict = "CAUGHT" if failed else "SURVIVED"
        print(f"{verdict:8} {mutant.__name__}: {len(failed)} tests failed")
        for name in failed[:3]:
            print(f"           {name}")
    baseline = failing_tests()
    print(f"\nsurvivors: {survivors}/{len(MUTANTS)}; "
          f"failures after restoring: {len(baseline)}")
