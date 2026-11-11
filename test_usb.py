"""Low-speed USB hold-out. See KILL_TEST.md.

Run: python test_usb.py          stage 2, the extended ISA
     python test_usb.py frozen   stage 1, the recorded failure on the frozen ISA
     python test_usb.py mutants  plant bugs and confirm the stage 2 tests catch them

Stage 1, frozen ISA. The host pre-computes NRZI, stuffing and CRCs, as the
rules allow, and the program sends the result. A timed `bits` instruction
drives one pin, and `set` drives a constant, so no program can drive D- as
the complement of data on D+. This run shows the consequence.
"""
import contextlib
import io
import random
import sys
import traceback

import encode
import protocols
import reference as ref
from janus import Hart, INIT1, ONES, Prog, PUSH_PULL, RESTART, STOP, WITNESS

BIT = 16                      # ticks per USB bit
FROZEN, TESTS = [], []


def frozen(fn):
    FROZEN.append(fn)
    return fn


def case(fn):
    TESTS.append(fn)
    return fn


def frozen_program():
    """Best effort on the frozen ISA: send host-coded D+ levels, 8 per byte."""
    p = Prog("usb_stage1", {"DP": PUSH_PULL, "DM": PUSH_PULL})
    p.set("DP", "A", 0)        # idle J: D+ low ...
    p.set("DM", "A", 1)        # ... and D- high
    p.label("idle")
    p.claim("A", "DP")
    p.load("A")
    p.bits("DP", "A", 8, dwell=BIT)
    p.jump("idle")
    return p


def dp_bytes(states):
    """Host pre-coding: the D+ level of each line state, packed LSB first."""
    levels = [dp for dp, _ in states]
    levels += [levels[-1]] * (-len(levels) % 8)
    return [sum(levels[i + j] << j for j in range(8)) for i in range(0, len(levels), 8)]


@frozen
def janus_host_to_reference_decoder():
    token = ref.usb_line(ref.usb_packet_bits(ref.PID_OUT, addr=5, endp=1))
    data = ref.usb_line(ref.usb_packet_bits(ref.PID_DATA0, data=list(range(8))))
    bus = ref.UsbBus()
    host = Hart(frozen_program(), "A", bus, tx=dp_bytes(token) + dp_bytes(data))
    bus.add(host)
    bus.run(BIT * 400)
    packets = ref.usb_decode(bus.trace, BIT)
    k_states = sum(1 for t in bus.trace if (t["DP"], t["DM"]) == ref.K)
    print(f"     decoded packets: {len(packets)}; ticks in state K: {k_states}")
    assert [p["pid"] for p in packets] == [ref.PID_OUT, ref.PID_DATA0], packets


@frozen
def limits_frozen():
    prog = frozen_program()
    assert prog.role_dependent_count() <= 3
    assert len(prog.code) <= 48


# Stage 2: the extended ISA. The host queues each packet's bytes after SYNC,
# CRC included, then STOP. The chip does NRZI, stuffing, the pair and the EOP.

ADDR, ENDP = 5, 1
DATA = [0x00, 0x01, 0x7F, 0xFF, 0xFE, 0x80, 0xA5, 0x3C]  # needs stuffed bits
ACK_BYTE = 0xD2
TRIALS, RANDOM_PAYLOADS = 300, 40   # the RTL replay records fewer


def pack(bits):
    """Wire-order bits to bytes, least significant bit first."""
    assert len(bits) % 8 == 0
    return [sum(bits[i + j] << j for j in range(8)) for i in range(0, len(bits), 8)]


def token_bytes():
    return pack(ref.usb_packet_bits(ref.PID_OUT, addr=ADDR, endp=ENDP))


def data_bytes(data, crc16_xor=0):
    return pack(ref.usb_packet_bits(ref.PID_DATA0, data=data, crc16_xor=crc16_xor))


def out_queue(data, crc16_xor=0):
    """What the host's microcontroller queues for one OUT transaction."""
    return token_bytes() + [STOP] + data_bytes(data, crc16_xor) + [STOP]


def host_packets(data, crc16_xor=0, **faults):
    """Line states from a reference host. It idles for four bit times first:
    a Janus device needs a few ticks after reset to run its set-up."""
    token = [ref.J] * 4 + ref.usb_line(ref.usb_packet_bits(ref.PID_OUT, addr=ADDR, endp=ENDP))
    bits = ref.usb_packet_bits(ref.PID_DATA0, data=data, crc16_xor=crc16_xor)
    return [token, ref.usb_line(bits, **faults)]


def janus(bus, *roles, tx=()):
    prog = protocols.usb(BIT)
    harts = [Hart(prog, role, bus, tx=tx if role == "A" else ()) for role in roles]
    bus.add(*harts)
    return harts


def states(bus):
    return [(t["DP"], t["DM"]) for t in bus.trace]


def acks(bus):
    return [p for p in ref.usb_decode(bus.trace, BIT) if p["pid"] == ref.PID_ACK]


def check_transaction(packets, data):
    """Token, data and ACK, each well formed, as the independent decoder reads them."""
    assert [p["pid"] for p in packets] == [ref.PID_OUT, ref.PID_DATA0, ref.PID_ACK], packets
    for p in packets:
        assert p["pid_ok"] and p["eop"] and not p["stuff_error"], p
    assert (packets[0]["addr"], packets[0]["endp"], packets[0]["crc_ok"]) == (ADDR, ENDP, True)
    assert packets[1]["data"] == data and packets[1]["crc_ok"], packets[1]


def turnaround(bus, nth):
    """Bit times from the end of the nth SE0 to the next K."""
    line = states(bus)
    ends = [t for t in range(1, len(line)) if line[t - 1] == ref.SE0 and line[t] != ref.SE0]
    k = next(t for t in range(ends[nth], len(line)) if line[t] == ref.K)
    return (k - ends[nth]) / BIT


@case
def janus_host_to_reference_device():
    bus = ref.UsbBus()
    host, witness = janus(bus, "A", WITNESS, tx=out_queue(DATA))
    device = ref.UsbDevice(bus, BIT)
    bus.add(device)
    bus.run(BIT * 400)
    check_transaction(ref.usb_decode(bus.trace, BIT), DATA)
    assert device.acks == 1
    assert list(host.rx_q) == [ACK_BYTE], list(host.rx_q)
    assert list(witness.seen) == token_bytes() + data_bytes(DATA) + [ACK_BYTE]
    assert (host.violations, witness.violations, bus.contentions) == (0, 0, 0)


@case
def reference_host_to_janus_device():
    bus = ref.UsbBus()
    device, witness = janus(bus, "B", WITNESS)
    bus.add(ref.UsbSender(bus, host_packets(DATA), BIT, gap=2 * BIT))
    bus.run(BIT * 400)
    check_transaction(ref.usb_decode(bus.trace, BIT), DATA)
    assert list(device.rx_q) == token_bytes() + data_bytes(DATA), list(device.rx_q)
    assert list(witness.seen) == token_bytes() + data_bytes(DATA) + [ACK_BYTE]
    assert (device.violations, witness.violations, bus.contentions) == (0, 0, 0)


@case
def janus_both_ends():
    rng = random.Random(1)
    for trial in range(TRIALS):
        data = [rng.choice([0x00, 0xFF, 0xFE, 0x7F, rng.randrange(256)])
                for _ in range(rng.randrange(9))]
        bus = ref.UsbBus()
        host, device, witness = janus(bus, "A", "B", WITNESS, tx=out_queue(data))
        bus.run(BIT * 400)
        check_transaction(ref.usb_decode(bus.trace, BIT), data)
        assert list(host.rx_q) == [ACK_BYTE], (trial, data)
        assert list(device.rx_q) == token_bytes() + data_bytes(data), (trial, data)
        assert list(witness.seen) == token_bytes() + data_bytes(data) + [ACK_BYTE]
        assert host.violations + device.violations + witness.violations == 0, (trial, data)
        assert bus.contentions == 0


@case
def device_answers_inside_the_turnaround_window():
    for gap in (2 * BIT, 3 * BIT + 5, 6 * BIT):   # the host's gap before its data packet
        bus = ref.UsbBus()
        janus(bus, "B")
        bus.add(ref.UsbSender(bus, host_packets(DATA), BIT, gap=gap))
        bus.run(BIT * 400)
        check_transaction(ref.usb_decode(bus.trace, BIT), DATA)
        bits = turnaround(bus, 1)
        print(f"     host gap {gap} ticks: device answers {bits:.2f} bit times after the EOP")
        assert 2 <= bits <= 6.5, bits


@case
def host_reports_a_timeout_when_no_device_answers():
    bus = ref.UsbBus()
    host, witness = janus(bus, "A", WITNESS, tx=out_queue(DATA) + out_queue(DATA))
    line_end = flagged = None
    for t in range(BIT * 400):
        if host.violations:
            break
        bus.tick()
        if t and (bus.trace[-2]["DP"], bus.trace[-2]["DM"]) == ref.SE0 \
                and (bus.wire["DP"], bus.wire["DM"]) == ref.J:
            line_end = t
        if flagged is None and host.violations:
            flagged = t
    assert flagged is not None, "the host never flagged the missing handshake"
    waited = (flagged - line_end) / BIT
    print(f"     timeout flagged {waited:.2f} bit times after the EOP")
    assert 16 <= waited <= 18, waited
    assert (host.violations, witness.violations) == (1, 1)
    assert list(host.rx_q) == []
    # The host goes straight on to its next transaction. A device is there now.
    device = ref.UsbDevice(bus, BIT)
    bus.add(device)
    bus.run(BIT * 400)
    pids = [p["pid"] for p in ref.usb_decode(bus.trace, BIT)]
    assert pids == [ref.PID_OUT, ref.PID_DATA0, ref.PID_OUT, ref.PID_DATA0, ref.PID_ACK], pids
    assert device.acks == 1 and list(host.rx_q) == [ACK_BYTE]
    assert (host.violations, witness.violations, bus.contentions) == (1, 1, 0)


@case
def sender_clock_off_by_1_5_percent():
    rng = random.Random(2)
    payloads = [DATA, [0xFF] * 8, [0x00] * 8, [0xFE] * 8, [0x7F, 0xBF] * 4]
    payloads += [[rng.randrange(256) for _ in range(8)] for _ in range(RANDOM_PAYLOADS)]
    for scale in (0.985, 1.0, 1.015):
        for data in payloads:
            bus = ref.UsbBus()
            device, witness = janus(bus, "B", WITNESS)
            bus.add(ref.UsbSender(bus, host_packets(data), BIT * scale, gap=2 * BIT))
            bus.run(BIT * 420)
            packets = ref.usb_decode(bus.trace, BIT * scale)
            assert [p["pid"] for p in packets[:2]] == [ref.PID_OUT, ref.PID_DATA0]
            assert list(device.rx_q) == token_bytes() + data_bytes(data), (scale, data)
            assert list(witness.seen) == token_bytes() + data_bytes(data) + [ACK_BYTE]
            assert device.violations + witness.violations == 0, (scale, data)
            # The ACK runs on the device's clock: decode it at that rate.
            tail = [p for p in ref.usb_decode(bus.trace, BIT) if p["start"] > packets[1]["start"]]
            assert [p["pid"] for p in tail] == [ref.PID_ACK] and tail[0]["eop"], (scale, tail)
            assert 2 <= turnaround(bus, 1) <= 6.5
            assert bus.contentions == 0


def faulty(data, **faults):
    """A reference host sends a faulty data packet, then a good transaction."""
    bus = ref.UsbBus()
    device, witness = janus(bus, "B", WITNESS)
    good = host_packets(DATA)
    good[0] = [ref.J] * 24 + good[0]         # an idle bus before the good transaction
    bus.add(ref.UsbSender(bus, host_packets(data, **faults) + good, BIT, gap=2 * BIT))
    bus.run(BIT * 165)                       # past the end of the faulty packet
    first = (device.violations, witness.violations)
    assert first[1] >= 1, "the witness did not flag the fault"
    assert first[0] >= 1 and not acks(bus), "the device answered a faulty packet"
    bus.run(BIT * 400)
    assert len(acks(bus)) == 1, "no recovery: the good transaction was not answered"
    assert (device.violations, witness.violations) == first, "a violation in good traffic"
    assert list(device.rx_q)[-len(data_bytes(DATA)):] == data_bytes(DATA)
    return first


@case
def witness_flags_a_stuffing_violation():
    line = ref.usb_line(ref.usb_packet_bits(ref.PID_DATA0, data=[0xFF] * 8), stuff=False)
    trace = [{"DP": dp, "DM": dm} for dp, dm in line for _ in range(BIT)]
    assert ref.usb_decode(trace, BIT)[0]["stuff_error"]   # the fault is real
    print("     violations (device, witness):", faulty([0xFF] * 8, stuff=False))


@case
def witness_flags_a_bad_crc16():
    for flip in (0x0001, 0x8000, 0x0100, 0xFFFF):
        faulty(DATA, crc16_xor=flip)


@case
def witness_flags_a_missing_eop():
    for data in (DATA, [0x55] * 8, [0x00] * 3):
        faulty(data, eop=False)


@case
def witness_flags_an_eop_inside_a_byte():
    bits = ref.usb_packet_bits(ref.PID_DATA0, data=DATA)[:-3]
    bus = ref.UsbBus()
    device, witness = janus(bus, "B", WITNESS)
    bus.add(ref.UsbSender(bus, [host_packets(DATA)[0], ref.usb_line(bits)], BIT, gap=2 * BIT))
    bus.run(BIT * 420)
    assert witness.violations >= 1 and device.violations >= 1
    assert not acks(bus)


@case
def witness_flags_a_short_eop():
    """One bit time of SE0 where two are required."""
    packets = host_packets(DATA)
    assert packets[1][-3:] == [ref.SE0, ref.SE0, ref.J]
    packets[1] = packets[1][:-2] + [ref.J, ref.J]
    bus = ref.UsbBus()
    device, witness = janus(bus, "B", WITNESS)
    bus.add(ref.UsbSender(bus, packets, BIT, gap=2 * BIT))
    bus.run(BIT * 420)
    assert witness.violations >= 1 and device.violations >= 1


@case
def line_states_are_legal(queue=None):
    bus = ref.UsbBus()
    janus(bus, "A", "B", WITNESS, tx=queue or out_queue(DATA))
    bus.run(BIT * 400)
    line = states(bus)
    assert (1, 1) not in line, "SE1 on the bus"
    assert line[0] == ref.J and line[-1] == ref.J, "the bus does not idle in J"
    assert line.count(ref.SE0) == 3 * 2 * BIT, line.count(ref.SE0)  # three EOPs of two bits
    assert bus.contentions == 0


@case
def no_bit_edge_slips(queue=None):
    """Every change on the wire is a whole number of bit times after its
    packet's first edge: no run of instructions made a bit late."""
    bus = ref.UsbBus()
    janus(bus, "A", "B", WITNESS, tx=queue or out_queue(DATA))
    bus.run(BIT * 400)
    line = states(bus)
    changes = [t for t in range(1, len(line)) if line[t] != line[t - 1]]
    late, origin = [], None
    for t in changes:
        if origin is None:
            origin = t                       # a packet's first edge, J to K
        if (t - origin) % BIT:
            late.append(t)
        if line[t - 1] == ref.SE0:
            origin = None                    # the end of packet: the next edge starts one
    assert len(changes) > 60 and not late, (len(changes), late[:5])


# After stage 2: the chip sends the CRC16 it computed. The host queues the PID
# and the data, then RESTART where it used to queue two CRC bytes and STOP.

def crc_queue(data):
    return token_bytes() + [STOP] + data_bytes(data)[:-2] + [RESTART]


@case
def chip_sends_the_crc16():
    """The CRC16 on the wire is the chip's own, and an independent device and
    decoder accept it."""
    bus = ref.UsbBus()
    host, witness = janus(bus, "A", WITNESS, tx=crc_queue(DATA))
    device = ref.UsbDevice(bus, BIT)
    bus.add(device)
    bus.run(BIT * 400)
    check_transaction(ref.usb_decode(bus.trace, BIT), DATA)
    assert device.acks == 1 and list(host.rx_q) == [ACK_BYTE]
    assert list(witness.seen) == token_bytes() + data_bytes(DATA) + [ACK_BYTE]
    assert (host.violations, witness.violations, bus.contentions) == (0, 0, 0)


@case
def chip_crc16_over_random_payloads():
    rng = random.Random(3)
    for trial in range(TRIALS):
        data = [rng.choice([0x00, 0xFF, 0xFE, 0x7F, rng.randrange(256)])
                for _ in range(rng.randrange(9))]
        bus = ref.UsbBus()
        host, device, witness = janus(bus, "A", "B", WITNESS, tx=crc_queue(data))
        bus.run(BIT * 400)
        check_transaction(ref.usb_decode(bus.trace, BIT), data)
        # The device received the two CRC bytes the reference computes.
        assert list(device.rx_q) == token_bytes() + data_bytes(data), (trial, data)
        assert list(host.rx_q) == [ACK_BYTE], (trial, data)
        assert host.violations + device.violations + witness.violations == 0, (trial, data)
        assert bus.contentions == 0


@case
def chip_crc16_keeps_the_line_legal_and_on_time():
    line_states_are_legal(crc_queue(DATA))
    no_bit_edge_slips(crc_queue(DATA))


@case
def limits():
    prog = protocols.usb(BIT)
    print(f"     {len(prog.code)} instructions, {prog.role_dependent_count()} role-dependent")
    assert prog.role_dependent_count() <= 3
    assert len(prog.code) <= 48
    assert len(encode.assemble(prog)) == len(prog.code)


def run_mutants():
    """Plant bugs and confirm these tests catch each one."""
    mode, bits, hold = Prog.mode, Prog.bits, Prog.hold_trap
    resync, branch = Hart._resync, Hart._branch

    def without(name):
        def planted(self, **fields):
            fields.pop(name, None)
            mode(self, **fields)
        return planted

    def changed(name, change):
        def planted(self, **fields):
            if fields.get(name):
                fields[name] = change(fields[name])
            mode(self, **fields)
        return planted

    def no_break_bits(self, *args, **kwargs):
        kwargs["brk"] = False
        bits(self, *args, **kwargs)

    def crc_ignored(self, cond, label):
        return None if cond == "crc_bad" else branch(self, cond, label)

    def set_mode(fn):
        return lambda: setattr(Prog, "mode", fn)

    plants = {
        "no complementary pair": set_mode(without("pair")),
        "no NRZI": set_mode(without("nrzi")),
        "zeros stuffed too": set_mode(changed("stuff", lambda v: v & ~ONES)),
        "stuff after seven ones": set_mode(changed("stuff", lambda v: v + 1)),
        "CRC starts at zero": set_mode(changed("width", lambda v: v & ~INIT1)),
        "wrong CRC residual": set_mode(changed("resid", lambda v: v ^ 1)),
        "wrong CRC polynomial": set_mode(changed("poly", lambda v: v ^ 0x10)),
        "CRC sent as computed, not inverted": set_mode(without("xor")),
        "one bit of the CRC send pattern wrong": set_mode(changed("xor", lambda v: v ^ 0x8000)),
        "listeners do not see a break": set_mode(without("on_break")),
        "SE0 not driven": lambda: setattr(Prog, "bits", no_break_bits),
        "CRC result ignored": lambda: setattr(Hart, "_branch", crc_ignored),
        "no edge resync": lambda: setattr(Hart, "_resync", lambda s, v: None),
        "no idle trap": lambda: setattr(Prog, "hold_trap", lambda *a, **k: None),
    }
    survived = 0
    for name, plant in plants.items():
        plant()
        failed = []
        for fn in TESTS:
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    fn()
            except Exception:
                failed.append(fn.__name__)
        Prog.mode, Prog.bits, Prog.hold_trap = mode, bits, hold
        Hart._resync, Hart._branch = resync, branch
        survived += not failed
        print(f"{'CAUGHT' if failed else 'SURVIVED':8} {name}: {len(failed)} failed "
              f"{failed[:3]}", flush=True)
    return survived


def run(tests):
    failed = 0
    for fn in tests:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except Exception:
            failed += 1
            print(f"FAIL {fn.__name__}")
            print("    ", traceback.format_exc(limit=-1).strip().splitlines()[-1][:160])
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return failed


if __name__ == "__main__":
    if sys.argv[1:] == ["mutants"]:
        sys.exit(1 if run_mutants() else 0)
    sys.exit(1 if run(FROZEN if sys.argv[1:] == ["frozen"] else TESTS) else 0)
