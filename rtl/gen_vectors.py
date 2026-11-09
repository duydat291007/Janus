"""Record every Janus hart in every test, for tick-exact replay against the RTL.

Run from the project root: python3 rtl/gen_vectors.py <output-dir>
"""
import contextlib
import io
import os
import sys

sys.path.insert(0, os.getcwd())

import encode  # noqa: E402
import janus  # noqa: E402
import test_can  # noqa: E402
import test_janus  # noqa: E402
import test_onewire  # noqa: E402
from janus import RESTART, STOP, Hart  # noqa: E402


class RecHart(Hart):
    live = []

    def __init__(self, prog, role, bus, addr=None, tx=()):
        super().__init__(prog, role, bus, addr, tx)
        self.start_tx, self.rows, self.tx_hold = list(tx), [], 0
        self.rx_hash, self.seen_hash, self.rx_n, self.seen_n = 0, 0, 0, 0
        self.pin_list = list(prog.pins)
        self.rec_role, self.rec_addr = role, addr
        RecHart.live.append(self)

    def _bitmask(self, test):
        return sum(1 << i for i, p in enumerate(self.pin_list) if test(p))

    def tick(self):
        wires = self._bitmask(lambda p: self.bus.wire[p]) | (0xFF << len(self.pin_list)) & 0xFF
        if not self.start_tx and self.tx_q:  # data queued after the start
            self.start_tx, self.tx_hold = list(self.tx_q), len(self.rows)
        super().tick()
        rx, seen = list(self.rx_q), list(self.seen)
        for byte in rx[self.rx_n:]:
            self.rx_hash = (self.rx_hash * 31 + byte) & 0xFFFF
        for byte in seen[self.seen_n:]:
            self.seen_hash = (self.seen_hash * 31 + byte) & 0xFFFF
        self.rx_n, self.seen_n = len(rx), len(seen)
        oe = self._bitmask(lambda p: self.out.get(p) is not None)
        ov = self._bitmask(lambda p: self.out.get(p) == 1)
        self.rows.append(f"{wires:02x}{oe:02x}{ov:02x}{self.violations & 0xFF:02x}"
                         f"{self.rx_hash:04x}")


def tx_entry(item):
    if item is STOP:
        return 1 << 8
    if item is RESTART:
        return 2 << 8
    return item


def write_hart(hart, base):
    prog = hart.prog
    with open(base + ".prog", "w") as f:
        f.writelines(f"{w:08x}\n" for w in encode.assemble(prog))
    with open(base + ".tx", "w") as f:
        f.writelines(f"{tx_entry(i):03x}\n" for i in hart.start_tx or [0])
    with open(base + ".vec", "w") as f:
        f.write("\n".join(hart.rows) + "\n")
    od = sum(1 << i for i, p in enumerate(hart.pin_list) if prog.pins[p])
    used = (1 << len(hart.pin_list)) - 1
    ticks = len(hart.rows)
    meta = [encode.ROLE[hart.rec_role], hart.rec_addr or 0, used << 8 | od, ticks & 0xFFFF,
            len(hart.start_tx), *encode.config_words(prog), hart.seen_hash,
            hart.tx_hold & 0xFFFF, hart.tx_hold >> 16, ticks >> 16,
            hart.cfg["div"]]   # the prescaler the program leaves set
    with open(base + ".meta", "w") as f:
        f.writelines(f"{w:04x}\n" for w in meta)


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for module in (test_janus, test_onewire, test_can):
        module.Hart = RecHart
    cases = [(n, f, a) for n, f, a in test_janus.TESTS]
    cases += [(f.__name__, f, ()) for f in test_onewire.TESTS]
    cases += [(f.__name__, f, ()) for f in test_can.TESTS]
    written = 0
    for name, fn, args in cases:
        RecHart.live = []
        with contextlib.redirect_stdout(io.StringIO()):
            fn(*args)
        for i, hart in enumerate(RecHart.live):
            if hart.rows:
                write_hart(hart, os.path.join(out, f"{written:04d}"))
                written += 1
                print(f"{written - 1:04d} {hart.prog.name} {hart.rec_role} {name} "
                      f"{len(hart.rows)}")


if __name__ == "__main__":
    main()
