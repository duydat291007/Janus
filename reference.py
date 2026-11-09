"""Independent reference devices and wire decoders.

Written from the protocol definitions and sharing no logic with janus.py, so
they can catch a Janus program that is self-consistent but wrong. They read
wires directly, with no synchronizer delay, like an ideal device.
"""


def _wait(n):
    for _ in range(n):
        yield


class Agent:
    def __init__(self, bus):
        self.bus, self.out, self.gen = bus, {}, None

    def tick(self):
        if self.gen:
            next(self.gen, None)


class UartSender(Agent):
    def __init__(self, bus, data, bit):
        super().__init__(bus)
        self.gen = self._go(data, bit)

    def _go(self, data, bit):
        self.out["TX"] = 1
        yield from _wait(round(bit))
        total = 0.0  # fractional bit lengths, for baud-error tests
        done = 0

        def hold(level):
            nonlocal total, done
            self.out["TX"] = level
            total += bit
            ticks = round(total) - done
            done += ticks
            return _wait(ticks)

        for byte in data:
            yield from hold(0)
            for i in range(8):
                yield from hold((byte >> i) & 1)
            yield from hold(1)


class SpiController(Agent):
    def __init__(self, bus, data, half, cpol=0, cpha=0):
        super().__init__(bus)
        self.got = []
        self.gen = self._go(data, half, cpol, cpha)

    def _go(self, data, half, cpol, cpha):
        out = self.out
        out.update(CS=1, SCK=cpol, MOSI=0)
        yield from _wait(4 * half)
        out["CS"] = 0
        yield from _wait(half)
        for byte in data:
            value = 0
            for i in range(7, -1, -1):
                if cpha == 0:
                    out["MOSI"] = (byte >> i) & 1
                    yield from _wait(half)
                    value = value << 1 | self.bus.wire["MISO"]
                    out["SCK"] = 1 - cpol
                    yield from _wait(half)
                    out["SCK"] = cpol
                else:
                    out["SCK"] = 1 - cpol
                    out["MOSI"] = (byte >> i) & 1
                    yield from _wait(half)
                    value = value << 1 | self.bus.wire["MISO"]
                    out["SCK"] = cpol
                    yield from _wait(half)
            self.got.append(value)
        yield from _wait(half)
        out["CS"] = 1


class SpiTarget:
    def __init__(self, bus, data, cpol=0, cpha=0):
        self.bus, self.out = bus, {}
        self.data, self.cpol, self.cpha = list(data), cpol, cpha
        self.got, self.sr, self.count = [], 0, 0
        self.selected, self.prev_sck = False, cpol
        self.tx, self.out_bit = 0xFF, 0

    def _next_bit(self):
        if self.out_bit == 0:
            self.tx = self.data.pop(0) if self.data else 0xFF
        self.out["MISO"] = (self.tx >> (7 - self.out_bit)) & 1
        self.out_bit = (self.out_bit + 1) % 8

    def _capture(self):
        self.sr = (self.sr << 1 | self.bus.wire["MOSI"]) & 0xFF
        self.count += 1
        if self.count == 8:
            self.got.append(self.sr)
            self.count = 0

    def tick(self):
        wire = self.bus.wire
        if wire["CS"] == 1:
            self.selected = False
            self.out["MISO"] = None
            self.prev_sck = wire["SCK"]
            return
        if not self.selected:
            self.selected, self.count, self.out_bit = True, 0, 0
            if self.cpha == 0:
                self._next_bit()
        sck = wire["SCK"]
        if sck != self.prev_sck:
            leading = sck != self.cpol
            if leading == (self.cpha == 0):
                self._capture()
            else:
                self._next_bit()
        self.prev_sck = sck


class I2cController(Agent):
    """script items: ("write", addr, bytes), ("read", addr, n),
    ("restart_write", addr, bytes), ("restart_read", addr, n), ("stop",),
    ("bad_stop_after_bits", addr, n)"""

    def __init__(self, bus, script, half):
        super().__init__(bus)
        self.half, self.got, self.acks = half, [], []
        self.gen = self._go(script)

    def _sda(self, level):
        self.out["SDA"] = None if level else 0

    def _scl(self, level):
        self.out["SCL"] = None if level else 0

    def _start(self):
        self._sda(0)
        yield from _wait(self.half)
        self._scl(0)
        yield from _wait(self.half)

    def _restart(self):
        self._sda(1)
        yield from _wait(self.half)
        self._scl(1)
        yield from _wait(self.half)
        yield from self._start()

    def _bit(self, level):
        self._sda(level)
        yield from _wait(self.half)
        self._scl(1)
        while self.bus.wire["SCL"] == 0:  # honour clock stretching
            yield
        yield from _wait(self.half)
        self.sampled = self.bus.wire["SDA"]
        self._scl(0)
        yield

    def _write(self, byte):
        for i in range(7, -1, -1):
            yield from self._bit((byte >> i) & 1)
        yield from self._bit(1)
        self.acks.append(self.sampled == 0)

    def _read(self, ack):
        value = 0
        for _ in range(8):
            yield from self._bit(1)
            value = value << 1 | self.sampled
        self.got.append(value)
        yield from self._bit(0 if ack else 1)

    def _stop(self):
        self._sda(0)
        yield from _wait(self.half)
        self._scl(1)
        while self.bus.wire["SCL"] == 0:
            yield
        yield from _wait(self.half)
        self._sda(1)
        yield from _wait(self.half)

    def _go(self, script):
        yield from _wait(4 * self.half)
        for item in script:
            kind = item[0]
            if kind == "stop":
                yield from self._stop()
                continue
            if kind == "bad_stop_after_bits":
                yield from self._start()
                for i in range(item[2]):
                    yield from self._bit(1)
                yield from self._stop()
                continue
            yield from (self._restart() if kind.startswith("restart")
                        else self._start())
            read = kind.endswith("read")
            yield from self._write(item[1] << 1 | read)
            if read:
                for i in range(item[2]):
                    yield from self._read(i < item[2] - 1)
            else:
                for byte in item[2]:
                    yield from self._write(byte)


class I2cTarget:
    def __init__(self, bus, addr, data=(), stretch=0):
        self.bus, self.addr, self.out = bus, addr, {}
        self.data, self.got, self.stretch = list(data), [], stretch
        self.state, self.count, self.sr, self.read = "idle", 0, 0, False
        self.tx, self.hold = 0, 0
        self.prev = dict(bus.wire)

    def _sda(self, level):
        self.out["SDA"] = None if level else 0

    def _send_bit(self):
        self._sda((self.tx >> (7 - self.count)) & 1)

    def _falling(self):
        if self.state in ("addr", "wdata") and self.count == 8:
            if self.state == "addr":
                if self.sr >> 1 != self.addr:
                    self.state = "idle"
                    return
                self.read = bool(self.sr & 1)
            else:
                self.got.append(self.sr)
            self._sda(0)
            self.state = "ack"
        elif self.state == "ack":
            self.count, self.sr = 0, 0
            self.hold = self.stretch
            if self.hold:
                self.out["SCL"] = 0
            if self.read:
                self.tx = self.data.pop(0) if self.data else 0xFF
                self.state = "rdata"
                self._send_bit()
            else:
                self._sda(1)
                self.state = "wdata"
        elif self.state == "rdata":
            self.count += 1
            if self.count == 8:
                self._sda(1)
                self.state = "mack"
            else:
                self._send_bit()
        elif self.state == "mack":
            if self.master_ack:
                self.tx = self.data.pop(0) if self.data else 0xFF
                self.count, self.state = 0, "rdata"
                self._send_bit()
            else:
                self.state = "idle"

    def tick(self):
        wire, prev = self.bus.wire, self.prev
        if self.hold:
            self.hold -= 1
            if not self.hold:
                self.out["SCL"] = None
        if prev["SCL"] and wire["SCL"] and prev["SDA"] != wire["SDA"]:
            self._sda(1)
            self.count, self.sr = 0, 0
            self.state = "addr" if wire["SDA"] == 0 else "idle"
        elif wire["SCL"] and not prev["SCL"]:
            if self.state in ("addr", "wdata"):
                self.sr = (self.sr << 1 | wire["SDA"]) & 0xFF
                self.count += 1
            elif self.state == "mack":
                self.master_ack = wire["SDA"] == 0
        elif prev["SCL"] and not wire["SCL"]:
            self._falling()
        self.prev = dict(wire)


def decode_uart(trace, bit, pin="TX"):
    """Return (bytes, framing_errors)."""
    line = [t[pin] for t in trace]
    out, errors, i = [], 0, 1
    while i < len(line):
        if line[i - 1] == 1 and line[i] == 0:
            at = lambda n: line[min(i + int((n + 0.5) * bit), len(line) - 1)]
            out.append(sum(at(n + 1) << n for n in range(8)))
            errors += at(9) != 1
            i += int(9.5 * bit)
        i += 1
    return out, errors


def decode_spi(trace, cpol=0, cpha=0):
    """Return list of (mosi, miso) bytes, read on the sampling edge."""
    out, mosi, miso, count = [], 0, 0, 0
    for prev, now in zip(trace, trace[1:]):
        if now["CS"] == 1:
            count = 0
            continue
        if prev["SCK"] != now["SCK"]:
            leading = now["SCK"] != cpol
            if leading == (cpha == 0):
                mosi = (mosi << 1 | prev["MOSI"]) & 0xFF
                miso = (miso << 1 | prev["MISO"]) & 0xFF
                count += 1
                if count == 8:
                    out.append((mosi, miso))
                    count = 0
    return out


def decode_i2c(trace):
    """Return events: "S", "P", and (byte, acked) tuples."""
    events, bits = [], []
    for prev, now in zip(trace, trace[1:]):
        if prev["SCL"] and now["SCL"] and prev["SDA"] != now["SDA"]:
            events.append("S" if now["SDA"] == 0 else "P")
            bits = []
        elif now["SCL"] and not prev["SCL"]:
            bits.append(now["SDA"])
            if len(bits) == 9:
                value = sum(b << (7 - i) for i, b in enumerate(bits[:8]))
                events.append((value, bits[8] == 0))
                bits = []
    return events


class OneWireController(Agent):
    """Standard-speed timings. script items: ("reset",), ("write", byte),
    ("read", n), ("long_low", ticks)."""

    def __init__(self, bus, script):
        super().__init__(bus)
        self.presence, self.got = [], []
        self.gen = self._go(script)

    def _pulse(self, low, high):
        self.out["DQ"] = 0
        yield from _wait(low)
        self.out["DQ"] = None
        yield from _wait(high)

    def _go(self, script):
        yield from _wait(50)
        for item in script:
            if item[0] == "reset":
                self.out["DQ"] = 0
                yield from _wait(480)
                self.out["DQ"] = None
                yield from _wait(70)
                self.presence.append(self.bus.wire["DQ"] == 0)
                yield from _wait(410)
            elif item[0] == "write":
                for i in range(8):
                    bit = (item[1] >> i) & 1
                    yield from self._pulse(6, 64) if bit else self._pulse(60, 10)
            elif item[0] == "read":
                for _ in range(item[1]):
                    value = 0
                    for i in range(8):
                        self.out["DQ"] = 0
                        yield from _wait(6)
                        self.out["DQ"] = None
                        yield from _wait(9)
                        value |= self.bus.wire["DQ"] << i
                        yield from _wait(55)
                    self.got.append(value)
            elif item[0] == "long_low":
                yield from self._pulse(item[1], 80)


class OneWireTarget:
    """Target that sends rom after receiving one command byte."""

    def __init__(self, bus, rom):
        self.bus, self.out, self.rom = bus, {}, rom
        self.got, self.state, self.low = [], "idle", 0
        self.prev, self.since_rise, self.bit, self.sr = 1, 0, 0, 0
        self.hold = 0

    def _falling(self):
        if self.state == "read":
            byte = self.rom[self.bit // 8] if self.bit // 8 < len(self.rom) else 0xFF
            if not (byte >> (self.bit % 8)) & 1:
                self.out["DQ"], self.hold = 0, 30
            self.bit += 1

    def tick(self):
        dq = self.bus.wire["DQ"]
        if self.hold:
            self.hold -= 1
            if not self.hold:
                self.out["DQ"] = None
        if dq == 0 and self.prev == 1:
            self.low = 0
            self._falling()
        if dq == 0:
            self.low += 1
            if self.state == "cmd" and self.low == 30:
                self.sr = self.sr >> 1 | (0x80 if self.bus.wire["DQ"] else 0)
                self.bit += 1
        # A write-0 is still low at 30 and a write-1 has already risen.
        if dq == 1 and self.state == "cmd" and self.prev == 0 and self.low < 30:
            self.sr = self.sr >> 1 | 0x80
            self.bit += 1
        if self.state == "cmd" and self.bit == 8:
            self.got.append(self.sr)
            self.state, self.bit = "read", 0
        if dq == 1 and self.prev == 0 and self.low >= 300:
            self.state, self.since_rise = "presence", 0
        if self.state == "presence":
            self.since_rise += 1
            if self.since_rise == 30:
                self.out["DQ"], self.hold = 0, 120
            elif self.since_rise == 200:
                self.state, self.bit, self.sr = "cmd", 0, 0
        self.prev = dq


def decode_onewire(trace):
    """Return events: "R", "P", and bytes, from low-pulse widths alone."""
    pulses, start = [], None
    for i in range(1, len(trace)):
        if trace[i - 1]["DQ"] == 1 and trace[i]["DQ"] == 0:
            start = i
        elif trace[i - 1]["DQ"] == 0 and trace[i]["DQ"] == 1 and start is not None:
            pulses.append((start, i - start))
    events, bits, last_end, after_reset = [], [], 0, False
    for begin, width in pulses:
        if width >= 300:
            events.append("R")
            bits, after_reset = [], True
        elif after_reset:
            after_reset = False
            if begin - last_end < 80 and width >= 60:
                events.append("P")
        else:
            bits.append(0 if width >= 15 else 1)
            if len(bits) == 8:
                events.append(sum(b << n for n, b in enumerate(bits)))
                bits = []
        last_end = begin + width
    return events


def crc15(bits):
    crc = 0
    for bit in bits:
        feedback = bit ^ ((crc >> 14) & 1)
        crc = (crc << 1) & 0x7FFF
        if feedback:
            crc ^= 0x4599
    return crc


def can_body(can_id, data, crc_xor=0):
    """Unstuffed bits, SOF through the CRC sequence."""
    bits = [0]
    bits += [(can_id >> i) & 1 for i in range(10, -1, -1)]
    bits += [0, 0, 0]  # RTR, IDE, r0
    bits += [(len(data) >> i) & 1 for i in range(3, -1, -1)]
    for byte in data:
        bits += [(byte >> i) & 1 for i in range(7, -1, -1)]
    crc = crc15(bits) ^ crc_xor
    return bits + [(crc >> i) & 1 for i in range(14, -1, -1)]


def can_stuff(bits):
    out, run, prev = [], 0, None
    for bit in bits:
        out.append(bit)
        run = run + 1 if bit == prev else 1
        prev = bit
        if run == 5:
            prev = 1 - bit
            out.append(prev)
            run = 1
    return out


def can_wire(can_id, data, crc_xor=0):
    """Whole frame as sent: stuffed body, then delimiter, ACK slot and tail."""
    return can_stuff(can_body(can_id, data, crc_xor)) + [1] * 13


class CanParser:
    """Feed sampled wire bits; recovers the frame and removes stuff bits."""

    def __init__(self):
        self.body, self.tail = [], []
        self.run, self.prev, self.stuff_error = 0, None, False

    def _length(self):
        if len(self.body) < 19:
            return None
        dlc = int("".join(map(str, self.body[15:19])), 2)
        return 19 + 8 * min(dlc, 8) + 15

    def feed(self, bit):
        if self.run == 5:
            self.stuff_error |= bit == self.prev
            self.prev, self.run = bit, 1
            return
        if self._length() == len(self.body):
            self.tail.append(bit)
            return
        self.body.append(bit)
        self.run = self.run + 1 if bit == self.prev else 1
        self.prev = bit

    def await_ack(self):
        return len(self.tail) == 1

    def done(self):
        return len(self.tail) >= 10

    def frame(self):
        bits, size = self.body, self._length()
        value = lambda a, b: int("".join(map(str, bits[a:b])), 2)
        data = [value(i, i + 8) for i in range(19, size - 15, 8)]
        return {"id": value(1, 12), "data": data,
                "crc_ok": crc15(bits) == 0, "acked": self.tail[1] == 0}


class CanSender(Agent):
    def __init__(self, bus, bits, bit, arb_end=0, start=0):
        super().__init__(bus)
        self.lost, self.acked = False, None
        self.gen = self._go(bits, bit, arb_end, start)

    def _go(self, bits, bit, arb_end, start):
        for _ in range(start):
            if self.bus.wire["BUS"] == 0:
                break
            yield
        total, done = 0.0, 0
        for i, level in enumerate(bits):
            self.out["BUS"] = None if level else 0
            total += bit
            ticks = round(total) - done
            done += ticks
            yield from _wait(ticks // 2)
            seen = self.bus.wire["BUS"]
            if i < arb_end and level == 1 and seen == 0:
                self.lost = True
                self.out["BUS"] = None
                return
            if i == len(bits) - 12:
                self.acked = seen == 0
            yield from _wait(ticks - ticks // 2)
        self.out["BUS"] = None


class CanReceiver:
    """Live receiver: hard sync, edge resync, destuffing, and the ACK slot."""

    def __init__(self, bus, bit):
        self.bus, self.bit, self.out = bus, bit, {}
        self.frames, self.parser, self.phase, self.prev = [], None, 0, 1
        self.ack_state = None

    def tick(self):
        level = self.bus.wire["BUS"]
        falling = self.prev == 1 and level == 0
        self.prev = level
        if self.parser is None:
            if falling:
                self.parser, self.phase, self.ack_state = CanParser(), 0, None
            return
        if falling and self.ack_state is None and (
                self.phase <= self.bit // 4 or self.phase >= self.bit * 3 // 4):
            self.phase = 0
        self.phase += 1
        if self.phase >= self.bit:
            self.phase = 0
            if self.ack_state == "armed":
                self.out["BUS"], self.ack_state = 0, "driving"
            elif self.ack_state == "driving":
                self.out["BUS"], self.ack_state = None, "sent"
        if self.phase == self.bit // 2:
            self.parser.feed(level)
            if self.parser.await_ack() and self.ack_state is None:
                frame_good = crc15(self.parser.body) == 0
                self.ack_state = "armed" if frame_good else "sent"
            if self.parser.done():
                self.frames.append(self.parser.frame())
                self.parser = None


def decode_can(trace, bit):
    """Offline decode with a fixed sample point after each start-of-frame."""
    frames, parser, i, recessive = [], None, 0, bit
    line = [t["BUS"] for t in trace]
    while i < len(line) - bit:
        if parser is None:
            if line[i] == 0 and recessive >= bit:
                parser, start, n = CanParser(), i, 0
            recessive = recessive + 1 if line[i] else 0
            i += 1
            continue
        i = start + n * bit + bit // 2
        if i >= len(line):
            break
        parser.feed(line[i])
        n += 1
        if parser.done():
            frames.append(parser.frame())
            parser, recessive = None, 0
            i += 1
    return frames


# Low-speed USB, packet layer. Written from USB 2.0 chapters 7 and 8: NRZI
# (a 0 is a transition, a 1 is none), a stuffed 0 after six 1s, LSB first,
# CRC5 and CRC16 sent inverted, and an SE0 end of packet. Low-speed J is D+ low
# and D- high; K is the reverse; SE0 is both low.

PID_OUT, PID_IN, PID_SETUP = 0x1, 0x9, 0xD
PID_DATA0, PID_DATA1, PID_ACK, PID_NAK = 0x3, 0xB, 0x2, 0xA
J, K, SE0 = (0, 1), (1, 0), (0, 0)


def usb_crc5(bits):
    crc = 0x1F
    for bit in bits:
        feedback = bit ^ (crc >> 4 & 1)
        crc = (crc << 1) & 0x1F
        if feedback:
            crc ^= 0x05
    return crc ^ 0x1F


def usb_crc16(data):
    crc = 0xFFFF
    for byte in data:
        for i in range(8):
            feedback = (byte >> i & 1) ^ (crc >> 15 & 1)
            crc = (crc << 1) & 0xFFFF
            if feedback:
                crc ^= 0x8005
    return crc ^ 0xFFFF


def _lsb(value, n):
    return [value >> i & 1 for i in range(n)]


def usb_packet_bits(pid, addr=None, endp=None, data=None, crc16_xor=0):
    """Unstuffed bits after SYNC: PID and its complement, then the fields."""
    bits = _lsb(pid | (~pid & 0xF) << 4, 8)
    if addr is not None:
        fields = _lsb(addr, 7) + _lsb(endp, 4)
        crc = usb_crc5(fields)
        bits += fields + [crc >> (4 - i) & 1 for i in range(5)]
    if data is not None:
        for byte in data:
            bits += _lsb(byte, 8)
        crc = usb_crc16(data) ^ crc16_xor
        bits += [crc >> (15 - i) & 1 for i in range(16)]
    return bits


def usb_stuff(bits):
    out, ones = [], 0
    for bit in bits:
        out.append(bit)
        ones = ones + 1 if bit else 0
        if ones == 6:
            out.append(0)
            ones = 0
    return out


def usb_line(bits, stuff=True, eop=True):
    """Line states for a packet: SYNC, NRZI-coded stuffed bits, then EOP."""
    sync = [0] * 7 + [1]
    body = sync + (usb_stuff(bits) if stuff else bits)
    states, level = [], J
    for bit in body:
        if bit == 0:
            level = K if level == J else J
        states.append(level)
    if eop:
        states += [SE0, SE0, J]
    return states


class UsbBus:
    """The two USB wires with pull resistors: undriven, D+ reads 0 and D- 1."""

    PULL = {"DP": 0, "DM": 1}

    def __init__(self):
        self.pins = {"DP": False, "DM": False}
        self.agents, self.trace = [], []
        self.wire = dict(self.PULL)
        self.contentions = 0

    def add(self, *agents):
        self.agents.extend(agents)

    def tick(self):
        for pin in self.pins:
            drives = [a.out[pin] for a in self.agents if a.out.get(pin) is not None]
            if len(set(drives)) > 1:
                self.contentions += 1
            self.wire[pin] = drives[0] if drives else self.PULL[pin]
        self.trace.append(dict(self.wire))
        for agent in self.agents:
            agent.tick()

    def run(self, ticks):
        for _ in range(ticks):
            self.tick()


class UsbSender(Agent):
    """Drives packets with fractional bit lengths, then releases the wires."""

    def __init__(self, bus, packets, bit, gap=20):
        super().__init__(bus)
        self.gen = self._go(packets, bit, gap)

    def _go(self, packets, bit, gap):
        total, done = 0.0, 0
        for states in packets:
            for dp, dm in states:
                self.out["DP"], self.out["DM"] = dp, dm
                total += bit
                ticks = round(total) - done
                done += ticks
                yield from _wait(ticks)
            self.out = {}
            yield from _wait(gap)
            done += gap
            total += gap


def usb_decode(trace, bit):
    """Offline decoder: finds SYNC, samples mid-bit, undoes NRZI and stuffing,
    and parses each packet. Flags stuffing errors, bad CRCs and a missing EOP."""
    packets, i, n = [], 0, len(trace)
    state = lambda t: (trace[t]["DP"], trace[t]["DM"])
    while i < n:
        if state(i) != K:          # SYNC starts with a J to K transition
            i += 1
            continue
        start, level, bits, ones = i, J, [], 0
        stuff_error, eop, k = False, False, 0
        while True:
            t = start + round(k * bit + bit / 2)
            if t >= n:
                break
            now = state(t)
            if now == SE0:
                eop = t + round(bit) < n and state(t + round(bit)) == SE0
                i = t + 2 * round(bit)
                break
            bit_value = 1 if now == level else 0
            level = now
            k += 1
            if ones == 6:
                if bit_value == 1:
                    stuff_error = True
                ones = 0
                continue
            bits.append(bit_value)
            ones = ones + 1 if bit_value else 0
        else:
            i = n
        if len(bits) < 16 or bits[:8] != [0] * 7 + [1]:
            i = max(i, start + 1)
            continue
        body = bits[8:]
        value = lambda a, w: sum(body[a + j] << j for j in range(w))
        pid, check = value(0, 4), value(4, 4)
        packet = {"pid": pid, "pid_ok": check == (~pid & 0xF), "eop": eop,
                  "stuff_error": stuff_error, "start": start}
        if pid in (PID_OUT, PID_IN, PID_SETUP) and len(body) >= 24:
            fields = body[8:19]
            crc = sum(body[19 + j] << (4 - j) for j in range(5))
            packet.update(addr=value(8, 7), endp=value(15, 4), crc_ok=usb_crc5(fields) == crc)
        elif pid in (PID_DATA0, PID_DATA1) and len(body) >= 24:
            nbytes = (len(body) - 24) // 8
            data = [value(8 + 8 * b, 8) for b in range(nbytes)]
            crc = sum(body[8 + 8 * nbytes + j] << (15 - j) for j in range(16))
            packet.update(data=data, crc_ok=usb_crc16(data) == crc)
        packets.append(packet)
    return packets
