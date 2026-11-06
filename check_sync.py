"""Static checker for the sync rule, run over every real program.

Rule: on every path into a sync bit, the line is known to be at the opposite
level, so a transition is guaranteed and a listener cannot wait forever.

This is a forward analysis over the control flow. Each pin is 0, 1 or unknown.
Pins start high (idle, pull-ups). Entry through a trap fixes the pin levels the
trap's condition implies. `claim` changes nothing, because a sync compares
against the level recorded at the last sample, not the current one.

Run: python check_sync.py
"""
import protocols as p


def merge(a, b):
    return {pin: a[pin] if a[pin] == b[pin] else None for pin in a}


def configuration(prog):
    cfg = {"clk": None, "cpol": 0, "lane2": None}
    for ins in prog.code:
        if ins.op == "mode":
            cfg.update({k: v for k, v in ins.args.items() if k in cfg})
    return cfg


def transfer(ins, state, cfg):
    state = dict(state)
    a = ins.args
    if ins.op == "set":
        state[a["pin"]] = a["val"]
    elif ins.op == "bits":
        if a["clocked"]:
            state[a["pin"]] = None
            if cfg["lane2"]:
                state[cfg["lane2"][0]] = None
            state[cfg["clk"]] = cfg["cpol"]
        else:
            state[a["pin"]] = a["src"] if a["src"] in (0, 1) else None
    return state


def successors(prog, at):
    ins = prog.code[at]
    following = [] if at + 1 >= len(prog.code) else [at + 1]
    if ins.op == "branch":
        target = prog.labels[ins.args["label"]]
        return [target] if ins.args["cond"] == "always" else following + [target]
    if ins.op == "choice":
        return following + [prog.labels[ins.args["label"]]]
    return following


def entries(prog):
    """Every way in: reset, and each trap with what its condition implies."""
    unknown = {pin: None for pin in prog.pins}
    points = [(0, {pin: 1 for pin in prog.pins})]
    for (edge_pin, to), level, goto in prog.traps:
        state = dict(unknown)
        state[edge_pin] = to
        if level:
            state[level[0]] = level[1]
        points.append((prog.labels[goto], state))
    for pin, val, _, goto in prog.holds:
        state = dict(unknown)
        state[pin] = val
        points.append((prog.labels[goto], state))
    return points


def analyse(prog):
    cfg = configuration(prog)
    states = {}
    work = []
    for at, state in entries(prog):
        states[at] = merge(states[at], state) if at in states else state
        work.append(at)
    while work:
        at = work.pop()
        after = transfer(prog.code[at], states[at], cfg)
        for nxt in successors(prog, at):
            new = merge(states[nxt], after) if nxt in states else after
            if states.get(nxt) != new:
                states[nxt] = new
                work.append(nxt)
    return states


def problems(prog):
    states = analyse(prog)
    found = []
    for at, ins in enumerate(prog.code):
        if ins.op != "bits" or not ins.args["sync"]:
            continue
        pin, val = ins.args["pin"], ins.args["src"]
        if at not in states:
            found.append((at, pin, val, "unreachable"))
        elif ins.args["n"] != 1:
            found.append((at, pin, val, "a sync bit must be a single bit"))
        elif states[at][pin] != 1 - val:
            found.append((at, pin, val, f"line is {states[at][pin]} on entry"))
    return found


def main():
    total, syncs = 0, 0
    for prog in (p.uart(50), p.spi(10), p.i2c(20), p.onewire(), p.can(50)):
        count = sum(i.op == "bits" and i.args["sync"] for i in prog.code)
        bad = problems(prog)
        total += len(bad)
        syncs += count
        print(f"{prog.name}: {count} sync bits, {len(bad)} outside the rule")
        for at, pin, val, why in bad:
            print(f"   word {at}: {pin} waits for {val}: {why}")
    print(f"total: {syncs} sync bits, {total} outside the rule")
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
