"""Decode a lockstep counterexample. Usage: python3 cex.py <trace.vcd>"""
import re
import sys

WANT = ["pc_a", "pc_b", "s_a", "s_b", "ins", "now_a", "edge_a", "edge_b", "oe_a", "oe_b", "ov_a", "ov_b", "pin_a", "s1_a", "armed_a", "armed_b", "low", "rx_a", "rx_b", "last_a", "last_b"]
COLS = WANT[:17] + ["rx_a", "rx_b", "last_a", "last_b"]
OPS = {0: "set", 1: "bits", 2: "claim", 3: "load", 4: "store", 5: "branch", 6: "choice",
       7: "match", 8: "counter", 9: "mode"}
CONDS = ["always", "last0", "last1", "count0", "loop", "crc_bad"]
SRC = ["tx", "crc", "0", "1"]


def show(word):
    op = word >> 28
    name = OPS.get(op, f"op{op}")
    if op == 1:
        return (f"bits owner={(word >> 23) & 3} src={SRC[(word >> 21) & 3]} "
                f"n={((word >> 17) & 15) + 1} sync={(word >> 16) & 1} dwell={word & 2047}")
    if op == 3:
        imm = (word >> 25) & 1
        return f"load party={(word >> 26) & 3} " + (f"imm={word & 255:#x}" if imm else "queue")
    if op == 4:
        return f"store party={(word >> 26) & 3}"
    if op == 5:
        return f"branch {CONDS[(word >> 25) & 7]} -> {word & 63}"
    if op == 8:
        if (word >> 27) & 1:
            return f"counter rx mask={(word >> 8) & 255:#x} cap={(word >> 16) & 255}"
        return f"counter n={word & 255}"
    return name


def parse(path):
    ids, values, rows, now, seen_time = {}, {}, [], 0, False
    scope = []
    for line in open(path):
        line = line.strip()
        if line.startswith("$scope"):
            scope.append(line.split()[2])
        elif line.startswith("$upscope"):
            scope.pop()
        elif line.startswith("$var"):
            parts = line.split()
            if len(scope) == 1 and parts[4] in WANT:
                ids.setdefault(parts[3], parts[4])
        elif line.startswith("#"):
            if seen_time:
                rows.append((now, dict(values)))
            now, seen_time = int(line[1:]), True
        elif seen_time and line:
            m = re.match(r"b([01xz]+) (\S+)", line)
            if m and m.group(2) in ids:
                values[ids[m.group(2)]] = int(m.group(1).replace("x", "0").replace("z", "0"), 2)
            elif line[0] in "01xz" and line[1:] in ids:
                values[ids[line[1:]]] = 1 if line[0] == "1" else 0
    rows.append((now, dict(values)))
    return rows


def main():
    rows = parse(sys.argv[1])

    print("time", *COLS)
    prev = None
    for t, v in rows:
        key = tuple(v.get(k, 0) for k in COLS)
        if key != prev:
            print(t, *[f"{v.get(k, 0):x}" for k in COLS])
        prev = key


if __name__ == "__main__":
    main()
