"""Kill-test cases. See KILL_TEST.md for the rules. Run: python test_janus.py"""
import sys
import traceback

import reference as ref
from janus import RESTART, STOP, WITNESS, Bus, Hart
from protocols import A, B, C, T, i2c, spi, uart

BIT, SPI_HALF, I2C_HALF = 50, 10, 20
ACK, NACK = 0x00, 0xFF  # the controller's reply to each byte it reads
MODES = [(0, 0), (0, 1), (1, 0), (1, 1)]
TESTS = []


def case(*params):
    """Register a test, once per parameter value."""
    def register(fn):
        for p in params or [None]:
            args = () if p is None else (p if isinstance(p, tuple) else (p,))
            TESTS.append((f"{fn.__name__}{args if args else ''}", fn, args))
        return fn
    return register


def main():
    failed = 0
    for name, fn, args in TESTS:
        try:
            fn(*args)
            print(f"PASS {name}")
        except Exception:
            failed += 1
            print(f"FAIL {name}")
            print(traceback.format_exc(limit=-2))
    print(f"\n{len(TESTS) - failed}/{len(TESTS)} passed")
    return 1 if failed else 0


# --- Same program object for every role ---------------------------------

@case()
def test_every_role_shares_one_program():
    prog = i2c(I2C_HALF)
    bus = Bus(prog.pins)
    harts = [Hart(prog, r, bus) for r in (C, T, WITNESS)]
    assert all(h.prog is prog for h in harts)


@case()
def test_kill_limits():
    for prog in (uart(BIT), spi(SPI_HALF), i2c(I2C_HALF)):
        print(f"     {prog.name}: {len(prog.code)} instructions, "
              f"{prog.role_dependent_count()} role-dependent")
        assert prog.role_dependent_count() <= 3, prog.name
        assert len(prog.code) <= 48, prog.name


# --- UART ---------------------------------------------------------------

UART_DATA = [0x55, 0xA3, 0x00, 0xFF, 0x7E]


@case()
def test_uart_janus_pair_and_decoder():
    prog = uart(BIT)
    bus = Bus(prog.pins)
    tx = Hart(prog, A, bus, tx=UART_DATA)
    rx = Hart(prog, B, bus)
    w = Hart(prog, WITNESS, bus)
    bus.add(tx, rx, w)
    bus.run(BIT * 70)
    assert list(rx.rx_q) == UART_DATA, rx.rx_q
    assert list(w.seen) == UART_DATA, w.seen
    assert (rx.violations, w.violations) == (0, 0)
    assert ref.decode_uart(bus.trace, BIT) == (UART_DATA, 0)


@case(0.97, 1.0, 1.03)
def test_uart_receiver_against_reference_sender(error):
    prog = uart(BIT)
    bus = Bus(prog.pins)
    rx = Hart(prog, B, bus)
    w = Hart(prog, WITNESS, bus)
    bus.add(ref.UartSender(bus, UART_DATA, BIT * error), rx, w)
    bus.run(BIT * 70)
    assert list(rx.rx_q) == UART_DATA, rx.rx_q
    assert (rx.violations, w.violations) == (0, 0)


@case()
def test_uart_owner_and_listener_agree_on_last_bit():
    prog = uart(BIT)
    bus = Bus(prog.pins)
    tx = Hart(prog, A, bus, tx=[0x80])
    rx = Hart(prog, B, bus)
    bus.add(tx, rx)
    bus.run(BIT * 9 + BIT // 2)
    assert tx.last == rx.last == 1, (tx.last, rx.last)


@case()
def test_uart_witness_flags_bad_stop_bit():
    prog = uart(BIT)
    bus = Bus(prog.pins)
    w = Hart(prog, WITNESS, bus)
    # Sending at half the baud rate makes the expected stop bit read low.
    bus.add(ref.UartSender(bus, [0x00], BIT * 2), w)
    bus.run(BIT * 30)
    assert w.violations >= 1


@case()
def test_violation_count_stops_at_255():
    """The chip's counter is 8 bits. It must stop at 255: wrapping to 0 would
    make a very bad run read as a clean one."""
    prog = uart(8)
    bus = Bus(prog.pins)
    w = Hart(prog, WITNESS, bus)
    bus.add(ref.UartSender(bus, [0x00] * 300, 16), w)   # every stop bit reads low
    bus.run(16 * 10 * 300 + 100)
    assert len(w.seen) >= 290, len(w.seen)   # the witness followed about 300 frames
    assert w.violations == 255, w.violations


@case(40000, 66000)
def test_uart_send_after_long_idle(idle):
    """A hart must not stall after idling past half its 16-bit timebase."""
    prog = uart(BIT)
    bus = Bus(prog.pins)
    tx = Hart(prog, A, bus)
    rx = Hart(prog, B, bus)
    bus.add(tx, rx)
    bus.run(idle)
    tx.tx_q.extend([0xA5])
    bus.run(BIT * 12)
    assert list(rx.rx_q) == [0xA5], rx.rx_q
    assert ref.decode_uart(bus.trace, BIT) == ([0xA5], 0)


# --- SPI ----------------------------------------------------------------

MOSI_DATA, MISO_DATA = [0x12, 0xA5, 0xFF, 0x00], [0xDE, 0xAD, 0xBE, 0xEF]


@case(*MODES)
def test_spi_janus_pair_and_decoder(cpol, cpha):
    prog = spi(SPI_HALF, cpol, cpha)
    bus = Bus(prog.pins)
    c = Hart(prog, C, bus, tx=MOSI_DATA)
    t = Hart(prog, T, bus, tx=MISO_DATA)
    w = Hart(prog, WITNESS, bus)
    bus.add(c, t, w)
    bus.run(SPI_HALF * 100)
    assert list(c.rx_q) == MISO_DATA, c.rx_q
    assert list(t.rx_q) == MOSI_DATA, t.rx_q
    assert ref.decode_spi(bus.trace, cpol, cpha) == list(zip(MOSI_DATA, MISO_DATA))
    assert w.violations == 0 and bus.contentions == 0


@case(*MODES)
def test_spi_janus_controller_against_reference_target(cpol, cpha):
    prog = spi(SPI_HALF, cpol, cpha)
    bus = Bus(prog.pins)
    c = Hart(prog, C, bus, tx=MOSI_DATA)
    t = ref.SpiTarget(bus, MISO_DATA, cpol, cpha)
    bus.add(c, t)
    bus.run(SPI_HALF * 100)
    assert list(c.rx_q) == MISO_DATA, c.rx_q
    assert t.got == MOSI_DATA, t.got


@case(*MODES)
def test_spi_janus_target_against_reference_controller(cpol, cpha):
    prog = spi(SPI_HALF, cpol, cpha)
    bus = Bus(prog.pins)
    c = ref.SpiController(bus, MOSI_DATA, SPI_HALF, cpol, cpha)
    t = Hart(prog, T, bus, tx=MISO_DATA)
    bus.add(c, t)
    bus.run(SPI_HALF * 100)
    assert c.got == MISO_DATA, c.got
    assert list(t.rx_q) == MOSI_DATA, t.rx_q


@case()
def test_spi_witness_flags_cs_rising_mid_byte():
    prog = spi(SPI_HALF)
    bus = Bus(prog.pins)
    c = ref.SpiController(bus, [0xFF], SPI_HALF)
    w = Hart(prog, WITNESS, bus)
    bus.add(c, w)
    bus.run(SPI_HALF * 11)
    c.gen = None
    c.out["CS"] = 1
    bus.run(SPI_HALF * 4)
    assert w.violations == 1, w.violations


# --- I2C ----------------------------------------------------------------

def i2c_bus():
    prog = i2c(I2C_HALF)
    return prog, Bus(prog.pins)


@case()
def test_i2c_write_janus_pair_and_decoder():
    prog, bus = i2c_bus()
    c = Hart(prog, C, bus, tx=[0x42 << 1, 0x11, 0x22])
    t = Hart(prog, T, bus, addr=0x42)
    w = Hart(prog, WITNESS, bus)
    bus.add(c, t, w)
    bus.run(I2C_HALF * 200)
    assert list(t.rx_q) == [0x84, 0x11, 0x22], t.rx_q
    assert list(w.seen) == [0x84, 0x11, 0x22], w.seen
    assert ref.decode_i2c(bus.trace) == ["S", (0x84, True), (0x11, True),
                                         (0x22, True), "P"], ref.decode_i2c(bus.trace)
    assert w.violations == 0


@case()
def test_i2c_read_janus_pair_and_decoder():
    prog, bus = i2c_bus()
    c = Hart(prog, C, bus, tx=[0x42 << 1 | 1, ACK, ACK, NACK])
    t = Hart(prog, T, bus, addr=0x42, tx=[0xAA, 0x0F, 0x81])
    w = Hart(prog, WITNESS, bus)
    bus.add(c, t, w)
    bus.run(I2C_HALF * 200)
    assert list(c.rx_q) == [0xAA, 0x0F, 0x81], c.rx_q
    assert ref.decode_i2c(bus.trace) == ["S", (0x85, True), (0xAA, True),
                                         (0x0F, True), (0x81, False), "P"], ref.decode_i2c(bus.trace)
    assert w.violations == 0


@case()
def test_i2c_register_read_with_repeated_start():
    prog, bus = i2c_bus()
    c = Hart(prog, C, bus, tx=[0x42 << 1, 0x07, RESTART, 0x42 << 1 | 1, NACK])
    t = Hart(prog, T, bus, addr=0x42, tx=[0x5C])
    bus.add(c, t)
    bus.run(I2C_HALF * 200)
    assert list(c.rx_q) == [0x5C], c.rx_q
    assert ref.decode_i2c(bus.trace) == ["S", (0x84, True), (0x07, True), "S",
                                         (0x85, True), (0x5C, False), "P"], ref.decode_i2c(bus.trace)


@case()
def test_i2c_no_target_gives_nack_and_stop():
    prog, bus = i2c_bus()
    c = Hart(prog, C, bus, tx=[0x10 << 1, 0x99])
    t = Hart(prog, T, bus, addr=0x42)
    bus.add(c, t)
    bus.run(I2C_HALF * 80)
    assert ref.decode_i2c(bus.trace)[:3] == ["S", (0x20, False), "P"], ref.decode_i2c(bus.trace)


@case()
def test_i2c_two_targets_only_addressed_one_responds():
    prog, bus = i2c_bus()
    c = Hart(prog, C, bus, tx=[0x42 << 1, 0x33, STOP, 0x43 << 1 | 1, NACK])
    t1 = Hart(prog, T, bus, addr=0x42, tx=[0x01])
    t2 = Hart(prog, T, bus, addr=0x43, tx=[0x77])
    bus.add(c, t1, t2)
    bus.run(I2C_HALF * 200)
    assert list(t1.rx_q) == [0x84, 0x33, 0x87], t1.rx_q
    assert list(t2.rx_q) == [0x84, 0x87], t2.rx_q
    assert list(c.rx_q) == [0x77], c.rx_q


@case()
def test_i2c_janus_controller_against_reference_target_with_stretching():
    prog, bus = i2c_bus()
    c = Hart(prog, C, bus, tx=[0x42 << 1, 0x11, RESTART, 0x42 << 1 | 1, ACK, NACK])
    t = ref.I2cTarget(bus, 0x42, data=[0xC3, 0x3C], stretch=I2C_HALF * 3)
    bus.add(c, t)
    bus.run(I2C_HALF * 300)
    assert t.got == [0x11], t.got
    assert list(c.rx_q) == [0xC3, 0x3C], c.rx_q


@case()
def test_i2c_janus_target_against_reference_controller():
    prog, bus = i2c_bus()
    c = ref.I2cController(bus, [("write", 0x42, [0x07]),
                                ("restart_read", 0x42, 2), ("stop",)], I2C_HALF)
    t = Hart(prog, T, bus, addr=0x42, tx=[0xB1, 0xB2])
    w = Hart(prog, WITNESS, bus)
    bus.add(c, t, w)
    bus.run(I2C_HALF * 200)
    assert c.got == [0xB1, 0xB2], c.got
    assert all(c.acks), c.acks
    assert 0x07 in t.rx_q, t.rx_q
    assert w.violations == 0, w.violations


@case()
def test_i2c_witness_flags_stop_mid_byte():
    prog, bus = i2c_bus()
    c = ref.I2cController(bus, [("bad_stop_after_bits", 0x42, 3)], I2C_HALF)
    w = Hart(prog, WITNESS, bus)
    bus.add(c, w)
    bus.run(I2C_HALF * 60)
    assert w.violations == 1, w.violations


@case()
def test_i2c_arbitration_loser_backs_off():
    prog, bus = i2c_bus()
    winner = Hart(prog, C, bus, tx=[0x10 << 1, 0x5A])
    loser = Hart(prog, C, bus, tx=[0x50 << 1])
    t = Hart(prog, T, bus, addr=0x10)
    bus.add(winner, loser, t)
    bus.run(I2C_HALF * 100)
    assert loser.arb_lost and not winner.arb_lost
    assert list(t.rx_q) == [0x20, 0x5A], t.rx_q


if __name__ == "__main__":
    sys.exit(main())
