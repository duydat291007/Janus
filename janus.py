"""Tick-level behavioural model of the consolidated Janus choreography ISA.

A program describes a whole protocol. Each hart runs the same program with a
role; a bit owned by another party becomes a wait, a sample, or a check.
There is deliberately no "if role == X" instruction.

There is one bit engine. A bit is timed either by the hart's timebase or by a
clock pin, and passes through one shifter, one stuffer and one CRC.
"""
from collections import deque
from dataclasses import dataclass, field

WITNESS = "witness"
ALL = "all"  # every participant except a witness
OPEN_DRAIN, PUSH_PULL = True, False
SYNC_LAG = 2  # ticks from a hart driving a pin to any hart seeing it change


class Token:
    def __init__(self, name):
        self.name = name

    def __repr__(self):
        return self.name


# Control entries in a transmit queue. Anything else is a data byte.
RESTART, STOP = Token("RESTART"), Token("STOP")


@dataclass
class Ins:
    op: str
    args: dict = field(default_factory=dict)


class Prog:
    """Assembler. Each _emit is a real instruction; step, clocked, jump and
    loop are assembler conveniences that emit bits or branch."""

    def __init__(self, name, pins):
        self.name, self.pins = name, pins
        self.code, self.labels, self.traps, self.holds = [], {}, [], []

    def _emit(self, op, **args):
        self.code.append(Ins(op, args))

    def label(self, name):
        self.labels[name] = len(self.code)

    def trap(self, edge, goto, level=None):
        """Always armed: on edge=(pin, to), with level=(pin, value), jump."""
        self.traps.append((edge, level, goto))

    def hold_trap(self, pin, val, ticks, goto):
        """Always armed: jump once pin has stayed at val for ticks."""
        self.holds.append((pin, val, ticks, goto))

    # The ten instructions

    def set(self, pin, owner, val):
        """Set a pin's drive directly; val None releases it."""
        self._emit("set", pin=pin, owner=owner, val=val)

    def bits(self, pin, owner, n=1, src="tx", dwell=1, sync=False,
             clocked=False, stream=False, free=False):
        """All wire activity. src is "tx", "crc" or a constant 0 or 1.

        Timebase bits: the owner drives at the bit edge, and everyone samples
        mid-bit and moves on, so instructions run between bits without
        stretching them. Non-owners flag a constant that doesn't match.
        sync: non-owners wait for the line to change to a constant. That sets
        their bit edge to the owner's, so all parties leave the bit on the same
        tick. The line must be at the opposite level beforehand, on every path
        (`check_sync.py` verifies this), or a listener waits forever.
        free: non-owners do not check a constant, for bits where another party
        may legally hold the line, such as a reset starting during recovery.
        clocked: timed by the clock in `mode`, with dwell as the half period.
        stream: refill and store between bytes with no gap. ROLE-DEPENDENT:
        only the clock owner decides to stop.
        """
        self._emit("bits", pin=pin, owner=owner, n=n, src=src, dwell=dwell,
                   sync=sync, clocked=clocked, stream=stream,
                   free=free)

    def claim(self, party, pin, otherwise=None):
        """Wait for data to send (only the base role party) or for pin to
        fall. ROLE-DEPENDENT with otherwise: a node that is not sending this
        time becomes otherwise."""
        self._emit("claim", party=party, pin=pin, otherwise=otherwise)

    def load(self, party, imm=None):
        """Fill the transmit shifter from the queue, or from imm."""
        self._emit("load", party=party, imm=imm)

    def store(self, party, lane=0):
        self._emit("store", party=party, lane=lane)

    def branch(self, cond, label):
        """Shared: last0, last1, count0, loop, crc_bad, or always.
        loop decrements the counter and jumps while it is nonzero."""
        self._emit("branch", cond=cond, label=label)

    def choice(self, party, on, label):
        """ROLE-DEPENDENT: only party jumps, when the queue head is in on
        (None means empty). The wire tells the others later."""
        self._emit("choice", party=party, on=on, label=label)

    def match(self, party, shift=0):
        """ROLE-DEPENDENT: party becomes a witness if received bits, shifted
        right, differ from its address register."""
        self._emit("match", party=party, shift=shift)

    def counter(self, n=None, mask=0, cap=0):
        """Load the counter from n, or from masked received bits, up to cap."""
        self._emit("counter", n=n, mask=mask, cap=cap)

    def mode(self, **fields):
        """Write configuration: msb, resync, stuff, poly, width, on_error,
        lose_to, clk, clk_owner, cpol, cpha, lane2. A lose_to other than the
        default is ROLE-DEPENDENT. Setting stuff above 0 restarts the coder.
        Hardware writes one field per instruction word, so this emits one
        instruction for each field."""
        for name, value in fields.items():
            self._emit("mode", **{name: value})

    # Assembler conveniences

    def step(self, pin, owner, val, dwell, sync=False, free=False):
        self.bits(pin, owner, src=val, dwell=dwell, sync=sync, free=free)

    def clocked(self, pin, owner, n, half, stream=False):
        self.bits(pin, owner, n=n, dwell=half, clocked=True, stream=stream)

    def jump(self, label):
        self.branch("always", label)

    def loop(self, label):
        self.branch("loop", label)

    def role_dependent_count(self):
        count = 0
        for ins in self.code:
            count += ins.op in ("choice", "match")
            count += ins.op == "claim" and ins.args["otherwise"] is not None
            count += ins.op == "bits" and ins.args["stream"]
            count += ins.op == "mode" and bool(ins.args.get("lose_to"))
        return count


class Bus:
    def __init__(self, pins):
        self.pins = pins
        self.agents, self.trace = [], []
        self.wire = {p: 1 for p in pins}
        self.contentions = 0

    def add(self, *agents):
        self.agents.extend(agents)

    def _resolve(self):
        for pin, open_drain in self.pins.items():
            drives = [a.out[pin] for a in self.agents if a.out.get(pin) is not None]
            if open_drain:
                self.wire[pin] = 0 if 0 in drives else 1
            else:
                if len(set(drives)) > 1:
                    self.contentions += 1
                self.wire[pin] = drives[0] if drives else 1  # pull-up

    def tick(self):
        self._resolve()
        self.trace.append(dict(self.wire))
        for agent in self.agents:
            agent.tick()

    def run(self, ticks):
        for _ in range(ticks):
            self.tick()


def _wait(n):
    for _ in range(n):
        yield


class Hart:
    def __init__(self, prog, role, bus, addr=None, tx=()):
        self.prog, self.base_role, self.role = prog, role, role
        self.bus, self.addr = bus, addr
        self.out = {}
        self.tx_q, self.rx_q, self.seen = deque(tx), deque(), deque()
        self.tx, self.rx, self.last, self.count = 0, [0, 0], 0, 0
        self.partial, self.violations, self.arb_lost = 0, 0, False
        self.held = {}
        self.now, self.edge, self.dwell = 0, 0, 1
        self.last_fall = -10**9
        self.crc, self.run_len, self.run_val = 0, 0, None
        self.cfg = dict(msb=False, resync=None, stuff=0, poly=0, width=0,
                        on_error=None, lose_to=WITNESS, clk=None, clk_owner=None,
                        cpol=0, cpha=0, lane2=None)
        self.s1 = dict(bus.wire)
        self.pin = dict(bus.wire)
        self.armed = dict(bus.wire)  # pin levels when last sampled
        self.gen = self._run(0)

    def tick(self):
        prev = self.pin
        self.pin, self.s1 = self.s1, dict(self.bus.wire)
        self.now += 1
        watched = self.cfg["resync"]
        if watched and prev[watched] == 1 and self.pin[watched] == 0:
            self.last_fall = self.now
        for (edge_pin, to), level, goto in self.prog.traps:
            fired = prev[edge_pin] != to and self.pin[edge_pin] == to
            if fired and (level is None or self.pin[level[0]] == level[1]):
                self._fire(goto)
                break
        for i, (pin, val, ticks, goto) in enumerate(self.prog.holds):
            held = self.held.get(i, 0) + 1 if self.pin[pin] == val else 0
            self.held[i] = held
            if held == ticks:
                self._fire(goto)
        next(self.gen)

    def _fire(self, goto):
        if self.partial:  # a frame ended mid-byte
            self.violations += 1
        self.partial, self.role, self.edge = 0, self.base_role, self.now
        self.armed = dict(self.pin)
        self.gen = self._run(self.prog.labels[goto])

    def _mine(self, party):
        if party == ALL:
            return self.role != WITNESS
        return self.role == party

    def _drive(self, pin, val):
        self.out[pin] = val

    def _settled(self, pin, val):
        """Open-drain: a released line may be held low by someone else."""
        if self.prog.pins[pin] == OPEN_DRAIN:
            while self.pin[pin] != val:
                yield

    def _run(self, pc):
        timed = {"bits", "claim"}
        code, labels = self.prog.code, self.prog.labels
        while True:
            yield  # instruction fetch
            ins = code[pc]
            pc += 1
            if ins.op in timed:
                yield from getattr(self, "_" + ins.op)(**ins.args)
            else:
                target = getattr(self, "_" + ins.op)(**ins.args)
                if target is not None:
                    pc = labels[target]

    # Instant instructions

    def _set(self, pin, owner, val):
        if self._mine(owner):
            self._drive(pin, val)

    def _load(self, party, imm):
        if self._mine(party):
            if imm is not None:
                self.tx = imm
            else:
                self.tx = self.tx_q.popleft() if self.tx_q else 0xFF

    def _store(self, party, lane):
        if self._mine(party):
            self.rx_q.append(self.rx[lane])
        elif self.role == WITNESS:
            self.seen.append(self.rx[lane])

    def _branch(self, cond, label):
        if cond == "loop":
            self.count -= 1
            taken = self.count > 0
        elif cond == "crc_bad":
            taken = self.crc != 0
            self.violations += taken
        else:
            taken = {"always": True, "last0": self.last == 0, "last1": self.last == 1,
                     "count0": self.count == 0}[cond]
        return label if taken else None

    def _choice(self, party, on, label):
        if not self._mine(party):
            return None
        head = self.tx_q[0] if self.tx_q else None
        if head in on:
            if isinstance(head, Token):
                self.tx_q.popleft()
            return label
        return None

    def _match(self, party, shift):
        if self._mine(party) and (self.rx[0] >> shift) != self.addr:
            self.role = WITNESS

    def _counter(self, n, mask, cap):
        self.count = n if n is not None else min(self.rx[0] & mask, cap)

    def _mode(self, **fields):
        self.cfg.update(fields)
        if fields.get("stuff"):
            self.crc, self.run_len, self.run_val = 0, 0, None

    # Timed instructions

    def _claim(self, party, pin, otherwise):
        eligible = self.base_role == party
        while not (eligible and self.tx_q) and self.pin[pin] == 1:
            yield
        if eligible and otherwise is not None:
            sending = self.tx_q and self.pin[pin] == 1
            self.role = party if sending else otherwise

    def _bits(self, pin, owner, n, src, dwell, sync, clocked, stream, free):
        if clocked:
            yield from self._clocked_bits(pin, owner, n, dwell, stream)
            return
        for k in range(n):
            self.partial = k
            yield from self._coded_bit(pin, owner, src, dwell, sync, free)
        self.partial = 0

    # One shifter

    def _next_bit(self, src):
        if src == "tx":
            if self.cfg["msb"]:
                val, self.tx = (self.tx >> 7) & 1, (self.tx << 1) & 0xFF
            else:
                val, self.tx = self.tx & 1, self.tx >> 1
            return val
        if src == "crc":
            return (self.crc >> (self.cfg["width"] - 1)) & 1
        return src

    def _shift_in(self, lane, seen):
        self.last = seen
        if self.cfg["msb"]:
            self.rx[lane] = ((self.rx[lane] << 1) | seen) & 0xFF
        else:
            self.rx[lane] = (self.rx[lane] >> 1) | (seen << 7)

    def _lose(self, pin, also=None):
        self.role, self.arb_lost = self.cfg["lose_to"], True
        self.tx_q.clear()
        self._drive(pin, None)
        if also:
            self._drive(also, None)

    # Timebase bits

    def _resync(self, val):
        """A listener re-aligns its bit timing on a nearby falling edge."""
        if val is None and abs(self.last_fall - self.edge) <= self.dwell // 4:
            self.edge = self.last_fall

    def _sync_bit(self, pin, val):
        """Wait for the line to change to val. Anything this hart still drives
        is held to the edge. The detected change sets the bit edge."""
        while True:
            if self.now >= self.edge:
                self._drive(pin, None)
            level = self.pin[pin]
            if level == val and self.armed[pin] != val:
                break
            if level != val:
                self.armed[pin] = level
            yield
        self.edge = self.now - SYNC_LAG

    def _check(self, src, seen):
        if src in (0, 1) and seen != src:
            self.violations += 1

    def _timed_bit(self, pin, owner, src, dwell, sync, free=False, data=None):
        mine = self._mine(owner)
        self.dwell = dwell
        val = self._next_bit(src) if mine else None
        if sync and not mine:
            yield from self._sync_bit(pin, src)
        else:
            while self.now < self.edge:
                self._resync(val)
                yield
            if self.now > self.edge:
                self.edge = self.now  # idle or late: this bit sets the timing
            if mine:
                self._drive(pin, val)
        while self.now < self.edge + dwell // 2:
            self._resync(val)
            if not mine:
                self._drive(pin, None)
            yield
        if not mine:
            self._drive(pin, None)
        seen = self.pin[pin]
        self.armed = dict(self.pin)
        self.edge += dwell
        if src in ("tx", "crc"):  # constants and stuff bits are framing, not data
            self._shift_in(0, seen)
        is_data = data if data is not None else src in ("tx", "crc")
        if not mine:
            if not free:
                self._check(src, seen)
        elif is_data:
            if self.cfg["lose_to"] and val == 1 and seen == 0:
                self._lose(pin)
        else:
            yield from self._settled(pin, val)
        return seen

    def _coded_bit(self, pin, owner, src, dwell, sync, free):
        seen = yield from self._timed_bit(pin, owner, src, dwell, sync, free)
        if not self.cfg["stuff"]:
            return
        width = self.cfg["width"]
        feedback = seen ^ ((self.crc >> (width - 1)) & 1)
        self.crc = (self.crc << 1) & ((1 << width) - 1)
        if feedback:
            self.crc ^= self.cfg["poly"]
        self.run_len = self.run_len + 1 if seen == self.run_val else 1
        self.run_val = seen
        if self.run_len == self.cfg["stuff"]:
            extra = yield from self._timed_bit(pin, owner, 1 - seen, dwell, False, False,
                                               data=True)
            if extra == seen:
                self.violations += 1
                self.partial = 0
                self.gen = self._run(self.prog.labels[self.cfg["on_error"]])
                yield  # this generator is abandoned here
            self.run_val, self.run_len = extra, 1

    # Clocked bits

    def _lanes_out(self, lanes):
        for pin, owner in lanes:
            if self._mine(owner):
                self._drive(pin, self._next_bit("tx"))
            else:
                self._drive(pin, None)

    def _sample(self, clk, lanes):
        for i, (pin, owner) in enumerate(lanes):
            seen = self.pin[pin]
            self._shift_in(i, seen)
            lost = self.out.get(pin) == 1 and seen == 0
            if lost and self._mine(owner) and self.prog.pins[pin] == OPEN_DRAIN:
                self._lose(pin, clk)

    def _clock(self, clk, owner, level, half):
        if self._mine(owner):
            yield from _wait(half - 1)
            self._drive(clk, level)
            yield from self._settled(clk, level)
        else:
            self._drive(clk, None)
            while self.pin[clk] != level:
                yield

    def _store_incoming(self, lanes):
        for i, (pin, owner) in enumerate(lanes):
            if not self._mine(owner):
                (self.seen if self.role == WITNESS else self.rx_q).append(self.rx[i])

    def _refill(self, lanes):
        if any(self._mine(owner) for pin, owner in lanes):
            self.tx = self.tx_q.popleft() if self.tx_q else 0xFF

    def _clocked_bits(self, pin, owner, n, half, stream):
        cfg = self.cfg
        clk, clk_owner, cpha = cfg["clk"], cfg["clk_owner"], cfg["cpha"]
        active, idle = 1 - cfg["cpol"], cfg["cpol"]
        lanes = [(pin, owner)] + ([cfg["lane2"]] if cfg["lane2"] else [])
        while self._mine(clk_owner) and self.now < self.edge:
            yield  # everyone else is timed by the clock itself
        while True:
            for k in range(n):
                self.partial = k
                if cpha == 0:
                    self._lanes_out(lanes)
                    yield from self._clock(clk, clk_owner, active, half)
                    self._sample(clk, lanes)
                    yield from self._clock(clk, clk_owner, idle, half)
                else:
                    yield from self._clock(clk, clk_owner, active, half)
                    self._lanes_out(lanes)
                    yield from self._clock(clk, clk_owner, idle, half)
                    self._sample(clk, lanes)
                self.armed = dict(self.pin)
                yield  # data never changes on the same tick as the clock edge
            self.partial = 0
            if not stream:
                return
            self._store_incoming(lanes)
            if self._mine(clk_owner) and not self.tx_q:
                return
            self._refill(lanes)
