"""Record a UART exchange for the demo page, from the real Janus model.

One program runs as sender (A), receiver (B) and witness. A second run adds a
glitch that pulls the line low during one stop bit, which a receiver and a
witness must both flag. Run from the repo root: python demo/gen_demo.py
Writes demo/demo_data.json.
"""
import json
import os
import sys

sys.path.insert(0, os.getcwd())

import protocols  # noqa: E402
from janus import WITNESS, Bus, Hart  # noqa: E402

BIT = 8                 # ticks per UART bit
DATA = [0x4A, 0x21]     # "J!"
TICKS = 230


class TracedHart(Hart):
    """A Hart that remembers which instruction it is executing."""

    def __init__(self, *args, **kwargs):
        self.cur = 0
        super().__init__(*args, **kwargs)

    def _run(self, pc):
        timed = {"bits", "claim"}
        code, labels = self.prog.code, self.prog.labels
        while True:
            yield
            ins = code[pc]
            self.cur = pc
            pc += 1
            if ins.op in timed:
                yield from getattr(self, "_" + ins.op)(**ins.args)
            else:
                target = getattr(self, "_" + ins.op)(**ins.args)
                if target is not None:
                    pc = labels[target]


class Glitch:
    """Pulls the line low during one tick window: noise, or a broken sender."""

    def __init__(self, pin, start, length):
        self.pin, self.start, self.length, self.t, self.out = pin, start, length, 0, {}

    def tick(self):
        self.t += 1
        on = self.start <= self.t < self.start + self.length
        self.out = {self.pin: 0} if on else {}


def describe(ins):
    a = ins.args
    if ins.op == "set":
        return f"set {a['pin']} to {a['val']}, driven by {a['owner']}"
    if ins.op == "claim":
        return f"claim {a['pin']}: wait until {a['party']} has a byte to send"
    if ins.op == "load":
        return f"load: {a['party']} takes its next byte"
    if ins.op == "store":
        return f"store: {a['party']} keeps the byte; a witness logs it"
    if ins.op == "bits" and a["src"] == "tx":
        return f"{a['n']} data bits: {a['owner']} drives, the others sample mid-bit"
    if ins.op == "bits":
        wait = "; the others wait for the edge" if a["sync"] else "; the others check it"
        return f"one bit: {a['owner']} drives {a['src']}{wait}"
    if ins.op == "branch":
        return f"jump to '{a['label']}'"
    return ins.op


def run(glitch):
    prog = protocols.uart(BIT)
    bus = Bus(prog.pins)
    a = TracedHart(prog, "A", bus, tx=list(DATA))
    b = TracedHart(prog, "B", bus)
    w = TracedHart(prog, WITNESS, bus)
    if glitch:
        bus.add(Glitch("TX", glitch[0], glitch[1]))
    bus.add(a, b, w)
    rows = []
    for _ in range(TICKS):
        bus.tick()
        row = {"wire": bus.wire["TX"]}
        for name, h in (("A", a), ("B", b), ("W", w)):
            row[name] = {"pc": h.cur, "drive": h.out.get("TX"), "rx": list(h.rx_q),
                         "seen": list(h.seen), "viol": h.violations}
        rows.append(row)
    return prog, rows


def main():
    prog, clean = run(None)
    stop_pc = next(i for i, ins in enumerate(prog.code)
                   if ins.op == "bits" and ins.args["src"] == 1)
    first_stop = next(t for t, r in enumerate(clean) if r["A"]["pc"] == stop_pc)
    # The stop bit reaches the wire a few ticks after the sender starts it.
    stop_on_wire = next(t for t in range(first_stop, len(clean)) if clean[t]["wire"] == 1)
    glitch = (stop_on_wire + 2, BIT // 2)   # low on wire ticks [start, start + length)
    _, faulty = run(glitch)
    labels = {pc: name for name, pc in prog.labels.items()}
    program = [{"pc": i, "label": labels.get(i), "op": ins.op, "text": describe(ins)}
               for i, ins in enumerate(prog.code)]
    out = {"bit": BIT, "data": DATA, "program": program,
           "runs": {"clean": clean, "fault": faulty},
           "glitch": {"start": glitch[0], "length": glitch[1]}}
    path = os.path.join("demo", "demo_data.json")
    with open(path, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    with open(os.path.join("demo", "demo_template.html"), encoding="utf-8") as f:
        page = f.read()
    assert page.count("/*DATA*/null") == 1
    page = page.replace("/*DATA*/null", json.dumps(out, separators=(",", ":")))
    with open(os.path.join("demo", "janus_demo.html"), "w", encoding="utf-8", newline="\n") as f:
        f.write(page)
    for name, rows in (("clean", clean), ("fault", faulty)):
        last = rows[-1]
        print(f"{name}: B received {last['B']['rx']}, witness saw {last['W']['seen']}, "
              f"violations B={last['B']['viol']} W={last['W']['viol']}")
    print("program:", [p["text"] for p in program])
    print("wrote", path, os.path.getsize(path), "bytes")


if __name__ == "__main__":
    main()
