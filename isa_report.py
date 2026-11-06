"""Estimate instruction width and program size. Run: python isa_report.py [dir]

Opcode count can be gamed by moving work into wide fields, so this estimates
the bits each instruction really needs across all five programs. A numeric
field takes the bits of its largest value; any other field takes the bits to
tell its distinct values apart. An estimate, not an encoding.
"""
import importlib
import math
import sys
from collections import defaultdict


def bits_for(count):
    return math.ceil(math.log2(count)) if count > 1 else 0


def programs(protocols):
    made = [protocols.uart(50), protocols.i2c(20), protocols.onewire(),
            protocols.can(50)]
    made += [protocols.spi(10, cpol, cpha) for cpol in (0, 1) for cpha in (0, 1)]
    return made


def field_bits(values):
    if all(isinstance(v, int) and not isinstance(v, bool) for v in values):
        return bits_for(max(values) + 1)
    return bits_for(len({repr(v) for v in values}))


def main():
    if len(sys.argv) > 1:
        sys.path.insert(0, sys.argv[1])
    progs = programs(importlib.import_module("protocols"))
    fields = defaultdict(lambda: defaultdict(list))
    for prog in progs:
        for ins in prog.code:
            fields[ins.op].setdefault("_seen", [])
            for name, value in ins.args.items():
                fields[ins.op][name].append(value)
    opcode_bits = bits_for(len(fields))
    label_bits = bits_for(max(len(p.code) for p in progs))
    width = {}
    for op, args in fields.items():
        total = opcode_bits
        for name, values in args.items():
            if name == "_seen":
                continue
            total += label_bits if name == "label" else field_bits(values)
        width[op] = total
    word = max(width.values())
    print(f"distinct instructions: {len(fields)}")
    for op in sorted(width, key=width.get, reverse=True):
        print(f"  {op:12}{width[op]:4} bits")
    print(f"fixed word needed: {word} bits")
    print("program    instrs   bits at fixed word")
    seen = set()
    for prog in progs:
        if prog.name not in seen:
            seen.add(prog.name)
            print(f"{prog.name:12}{len(prog.code):4}   {len(prog.code) * word:6}")


if __name__ == "__main__":
    main()
