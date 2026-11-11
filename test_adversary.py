"""Adversary tests: a hart flips one bit it sends. Run: python test_adversary.py [mutants]

A hart built with fault=N drives the wrong level for the Nth timed bit it
owns, once, and otherwise runs its program unchanged. Each test sweeps N over
every bit of a frame and states what the other harts must do about it.
"""
import contextlib
import io
import sys
import traceback

import protocols
import reference as ref
import test_can as tc
import test_usb as tu
from janus import Bus, Hart, WITNESS

TESTS = []
RECOVERY = True   # the RTL replay records the faulty run only ...
STEP = 1          # ... and every few positions, to stay short
BIT = tu.BIT


def case(fn):
    TESTS.append(fn)
    return fn


def run_until_idle(bus, pin, bits, bit, limit):
    """Run until the pin has stayed high for `bits` bit times."""
    for _ in range(limit):
        bus.run(bit)
        if all(t[pin] == 1 for t in bus.trace[-bits * bit:]):
            return True
    return False


# USB

USB_GOOD = tu.token_bytes() + tu.data_bytes(tu.DATA)
PAYLOAD = tu.data_bytes(tu.DATA)[1:]          # data and CRC16, after the PID


def usb(fault, who="A", queue=None):
    bus = ref.UsbBus()
    prog = protocols.usb(BIT)
    host = Hart(prog, "A", bus, tx=queue or tu.out_queue(tu.DATA),
                fault=fault if who == "A" else None)
    device = Hart(prog, "B", bus, fault=fault if who == "B" else None)
    witness = Hart(prog, WITNESS, bus)
    bus.add(host, device, witness)
    bus.run(BIT * 420)
    return bus, host, device, witness


def usb_recovers(bus, host, device, witness):
    """The bus is idle, nothing is left queued, and a new transaction is clean."""
    if not RECOVERY:
        return
    assert not host.tx_q and run_until_idle(bus, "DM", 20, BIT, 100), "the bus stays busy"
    before = witness.violations, len(device.rx_q), len(host.rx_q)
    host.tx_q.extend(tu.out_queue(tu.DATA))
    bus.run(BIT * 300)
    assert list(device.rx_q)[before[1]:] == USB_GOOD, "the next transaction was not received"
    assert list(host.rx_q)[before[2]:] == [tu.ACK_BYTE], "the next transaction got no ACK"
    assert witness.violations == before[0], "a violation in the next, good transaction"


@case
def usb_host_fault_anywhere(queue=None):
    _, clean, _, _ = usb(10 ** 9, queue=queue)
    total = clean.owned                      # bits the host sends in one transaction
    first_covered = 36 + 16                  # token packet, then the data SYNC and PID
    last_covered = total - 5                 # before SE0, SE0, J and the turnaround bit
    silent = []
    for n in range(0, total, STEP):
        bus, host, device, witness = usb(n, queue=queue)
        assert host.fault is None, n         # the fault happened
        acked = tu.ACK_BYTE in host.rx_q
        if acked:                            # an answered packet carried the right data
            assert list(device.rx_q)[-len(PAYLOAD):] == PAYLOAD, n
        if first_covered <= n <= last_covered:
            assert witness.violations and not acked, f"bit {n} of the data went unnoticed"
        if not witness.violations:
            silent.append(n)
        usb_recovers(bus, host, device, witness)
    print(f"     {total} positions; {len(silent)} unnoticed, all in the token or a PID: "
          f"{silent[0]}-{silent[-1]}")
    assert all(8 <= n < 32 or 44 <= n < 52 for n in silent), silent


@case
def usb_host_fault_anywhere_with_the_chip_sending_the_crc():
    """The same sweep when the chip computes the CRC16: a wrong data bit must
    not reach the CRC it sends, and a wrong CRC bit must be caught."""
    usb_host_fault_anywhere(tu.crc_queue(tu.DATA))


@case
def usb_device_fault_in_the_handshake():
    _, _, clean, _ = usb(10 ** 9, "B")
    total = clean.owned
    unnoticed = []
    for n in range(0, total, STEP):
        bus, host, device, witness = usb(n, "B")
        clean_ack = list(host.rx_q) == [tu.ACK_BYTE]
        if clean_ack and not witness.violations and not host.violations:
            unnoticed.append(n)
        usb_recovers(bus, host, device, witness)
    print(f"     {total} positions; unnoticed with a clean ACK byte: {unnoticed}")
    assert not unnoticed, unnoticed


@case
def usb_host_with_a_short_queue_stops():
    """The queue runs dry inside a packet, with no STOP entry: the host must
    end the packet and go quiet, not send 0xFF for ever."""
    for cut in (1, 3, 6):
        queue = tu.out_queue(tu.DATA)[:-cut]
        bus, host, device, witness = usb(None, queue=queue)
        assert run_until_idle(bus, "DM", 20, BIT, 200), f"{cut} entries short: the host never stops"
        assert len(states_se0(bus)) <= 3, "more packets than the queue held"


def states_se0(bus):
    """Start ticks of each SE0 on the wire."""
    line = [(t["DP"], t["DM"]) for t in bus.trace]
    return [t for t in range(1, len(line)) if line[t] == ref.SE0 and line[t - 1] != ref.SE0]


# CAN

FRAME, NEXT = (0x2A5, [0x11, 0xFF, 0x00, 0x7E]), (0x123, [0xA5, 0x5A])


def can(fault):
    prog, bus = tc.build()
    sender = Hart(prog, "S", bus, tx=tc.queue(*FRAME), fault=fault)
    receiver, witness = Hart(prog, "R", bus), Hart(prog, WITNESS, bus)
    bus.add(sender, receiver, witness)
    bus.run(tc.frame_ticks(FRAME) + tc.BIT * 20)
    return bus, sender, receiver, witness


@case
def can_sender_fault_anywhere():
    _, clean, receiver, witness = can(10 ** 9)
    assert tc.received(receiver) == [FRAME] and not witness.violations
    total = clean.owned
    for n in range(0, total, STEP):
        bus, sender, receiver, witness = can(n)
        assert sender.fault is None, n
        assert witness.violations, f"bit {n} went unnoticed"
        first = ref.decode_can(bus.trace, tc.BIT)[0]
        assert not (first["acked"] and first["crc_ok"] and tc.simple(first) !=
                    {"id": FRAME[0], "data": FRAME[1]}), f"bit {n}: wrong frame accepted"
        if not RECOVERY:
            continue
        assert run_until_idle(bus, "BUS", 30, tc.BIT, 600) and not sender.tx_q, n
        before = (witness.violations, receiver.violations, sender.violations, len(receiver.rx_q))
        sender.tx_q.extend(tc.queue(*NEXT))
        bus.run(tc.frame_ticks(NEXT) + tc.BIT * 20)
        assert tc.received(receiver, list(receiver.rx_q)[before[3]:]) == [NEXT], n
        assert (witness.violations, receiver.violations, sender.violations) == before[:3], n
    print(f"     {total} positions, every one flagged by the witness")


# UART: no redundancy, so only the framing is checked

@case
def uart_fault_in_each_bit():
    sent = 0x5A
    # Bit 0 is the idle bit before the first frame and bit 1 the start bit.
    for n in range(2, 11):                   # bits 2 to 9 are data, 10 is the stop bit
        prog = protocols.uart(50)
        bus = Bus(prog.pins)
        a = Hart(prog, "A", bus, tx=[sent, 0xC3], fault=n)
        b, w = Hart(prog, "B", bus), Hart(prog, WITNESS, bus)
        bus.add(a, b, w)
        bus.run(50 * 30)
        if n == 10:
            assert w.violations and b.violations, "a bad stop bit went unnoticed"
        else:                                # the wrong byte arrives, and nothing can tell
            assert list(b.rx_q) == [sent ^ 1 << (n - 2), 0xC3], (n, list(b.rx_q))
            assert not w.violations


def run_mutants():
    """Plant bugs and confirm these tests catch each one."""
    timed, usb_prog = Hart._timed_bit, protocols.usb

    def readback_coder(self, pin, *args, **kwargs):
        """The coder follows what the owner reads back, as it did before."""
        coded = yield from timed(self, pin, *args, **kwargs)
        return coded if self.cfg["nrzi"] else self.armed[pin]

    def babbling_usb(bit):
        prog = usb_prog(bit)
        for ins in prog.code:
            if ins.op == "choice":
                ins.args["on"] = [tu.STOP]
        return prog

    def no_fault(self, *args, **kwargs):
        self.fault = None
        return timed(self, *args, **kwargs)

    plants = {"coder follows the readback": lambda: setattr(Hart, "_timed_bit", readback_coder),
              "host sends for ever on an empty queue":
              lambda: setattr(protocols, "usb", babbling_usb),
              "the fault never happens": lambda: setattr(Hart, "_timed_bit", no_fault)}
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
        Hart._timed_bit, protocols.usb = timed, usb_prog
        survived += not failed
        print(f"{'CAUGHT' if failed else 'SURVIVED':8} {name}: {len(failed)} failed {failed[:3]}",
              flush=True)
    return survived


if __name__ == "__main__":
    if sys.argv[1:] == ["mutants"]:
        sys.exit(1 if run_mutants() else 0)
    failed = 0
    for fn in TESTS:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except Exception:
            failed += 1
            print(f"FAIL {fn.__name__}")
            print("    ", traceback.format_exc(limit=-1).strip().splitlines()[-1][:200])
    print(f"\n{len(TESTS) - failed}/{len(TESTS)} passed")
    sys.exit(1 if failed else 0)
