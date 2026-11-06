"""Binary encoding of the Janus ISA: 32-bit instruction words.

Traps are not instructions. A host writes them into six 16-bit configuration
registers when it loads a program (see `config_words`).
"""
from janus import ALL, RESTART, STOP, WITNESS

OPS = ["set", "bits", "claim", "load", "store", "branch", "choice", "match",
       "counter", "mode"]
CONDS = ["always", "last0", "last1", "count0", "loop", "crc_bad"]
MODE_FIELDS = ["msb", "resync", "stuff", "poly", "width", "on_error", "lose_to",
               "clk", "clk_owner", "cpol", "cpha", "lane2"]
ROLE = {"A": 0, "C": 0, "S": 0, "B": 1, "T": 1, "R": 1, ALL: 2, WITNESS: 3}
LOSE_NONE = 2


def pin_index(prog, pin):
    assert len(prog.pins) <= 4, prog.name  # a hart has 4 pins
    return list(prog.pins).index(pin)


def _mode_value(prog, name, value, base=0):
    if name == "resync":
        return 8 | pin_index(prog, value)
    if name == "on_error":
        return prog.labels[value] + base
    if name == "lose_to":
        return LOSE_NONE if value is None else ROLE[value]
    if name == "clk":
        return pin_index(prog, value)
    if name == "clk_owner":
        return ROLE[value]
    if name == "lane2":
        return 32 | pin_index(prog, value[0]) << 2 | ROLE[value[1]]
    return int(value)


def encode(prog, ins, base=0):
    a, op = ins.args, ins.op
    word = OPS.index(op) << 28
    if op == "set":
        val = 2 if a["val"] is None else a["val"]
        return word | pin_index(prog, a["pin"]) << 25 | ROLE[a["owner"]] << 23 | val << 21
    if op == "bits":
        src = {"tx": 0, "crc": 1, 0: 2, 1: 3}[a["src"]]
        assert 1 <= a["n"] <= 16 and a["dwell"] < 2048
        return (word | pin_index(prog, a["pin"]) << 25 | ROLE[a["owner"]] << 23
                | src << 21 | (a["n"] - 1) << 17 | a["sync"] << 16
                | a["clocked"] << 15 | (a["stream"] or a["free"]) << 14
                | a["dwell"])
    if op == "claim":
        other = a["otherwise"]
        return (word | pin_index(prog, a["pin"]) << 25 | ROLE[a["party"]] << 23
                | (other is not None) << 22 | ROLE.get(other, 0) << 20)
    if op == "load":
        imm = a["imm"]
        return word | ROLE[a["party"]] << 26 | (imm is not None) << 25 | (imm or 0)
    if op == "store":
        return word | ROLE[a["party"]] << 26 | a["lane"] << 25
    if op == "branch":
        return word | CONDS.index(a["cond"]) << 25 | (prog.labels[a["label"]] + base)
    if op == "choice":
        on = a["on"]
        return (word | ROLE[a["party"]] << 26 | (None in on) << 25 | (STOP in on) << 24
                | (RESTART in on) << 23 | (prog.labels[a["label"]] + base))
    if op == "match":
        return word | ROLE[a["party"]] << 26 | a["shift"] << 23
    if op == "counter":
        if a["n"] is not None:
            return word | a["n"]
        return word | 1 << 27 | a["cap"] << 16 | a["mask"] << 8
    name, value = next(iter(a.items()))
    return word | MODE_FIELDS.index(name) << 23 | _mode_value(prog, name, value, base)


def assemble(prog, base=0):
    """Words for a program placed at address base; jump targets are absolute."""
    assert base + len(prog.code) <= 48, prog.name  # program memory size
    return [encode(prog, ins, base) for ins in prog.code]


def config_words(prog, base=0):
    """trap0, trap1, hold0, hold1, hold0 ticks, hold1 ticks."""
    words = [0] * 6
    for i, ((pin, to), level, goto) in enumerate(prog.traps):
        words[i] = (1 << 15 | (prog.labels[goto] + base) << 9 | pin_index(prog, pin) << 6
                    | to << 5)
        if level:
            words[i] |= 1 << 4 | pin_index(prog, level[0]) << 1 | level[1]
    for i, (pin, val, ticks, goto) in enumerate(prog.holds):
        words[2 + i] = (1 << 15 | (prog.labels[goto] + base) << 9 | pin_index(prog, pin) << 6
                        | val << 5)
        words[4 + i] = ticks
    return words
