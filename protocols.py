"""Six protocols, each written once as a whole-protocol program."""
from janus import ALL, INIT1, ONES, OPEN_DRAIN, PUSH_PULL, RESTART, STOP, WITNESS, Prog

A, B = "A", "B"  # UART sender and receiver
C, T = "C", "T"  # controller and target
S, R = "S", "R"  # CAN sender and receiver
H, D = "A", "B"  # USB host and device


def uart(bit):
    p = Prog("uart", {"TX": PUSH_PULL})
    p.set("TX", A, 1)
    p.label("idle")
    p.claim(A, "TX")
    p.load(A)
    p.step("TX", A, 0, bit, sync=True)  # start bit
    p.bits("TX", A, 8, dwell=bit)
    p.store(B)
    p.step("TX", A, 1, bit)  # stop bit
    p.jump("idle")
    return p


def spi(half, cpol=0, cpha=0):
    p = Prog("spi", {"CS": PUSH_PULL, "SCK": PUSH_PULL,
                     "MOSI": PUSH_PULL, "MISO": PUSH_PULL})
    p.trap(edge=("CS", 1), goto="idle")
    p.mode(msb=True, clk="SCK", clk_owner=C, cpol=cpol, cpha=cpha,
           lane2=("MISO", T))
    p.set("CS", C, 1)
    p.set("SCK", C, cpol)
    p.label("idle")
    p.set("MISO", ALL, None)
    p.claim(C, "CS")
    p.step("CS", C, 0, half, sync=True)
    p.load(C)
    p.load(T)
    p.clocked("MOSI", C, 8, half, stream=True)
    p.step("CS", C, 1, half)  # the CS trap returns everyone to idle
    p.jump("idle")
    return p


def i2c(half):
    p = Prog("i2c", {"SCL": OPEN_DRAIN, "SDA": OPEN_DRAIN})
    p.trap(edge=("SDA", 1), level=("SCL", 1), goto="idle")  # STOP
    p.trap(edge=("SDA", 0), level=("SCL", 1), goto="addr")  # (re)START

    def byte(owner, receiver):
        p.clocked("SDA", owner, 8, half)
        p.store(receiver)

    def ack(owner):
        p.clocked("SDA", owner, 1, half)
        p.branch("last1", "stop")  # NACK: everyone saw it, everyone stops

    p.mode(msb=True, clk="SCL", clk_owner=C)
    p.label("idle")
    p.claim(C, "SDA")
    p.step("SDA", C, 0, half, sync=True)  # the START trap fires for everyone

    p.label("hang")
    p.jump("hang")

    p.label("addr")
    p.step("SDA", C, 0, half)  # hold time; the START trap aligned everyone
    p.step("SCL", C, 0, half, sync=True)
    p.load(C)
    byte(C, T)
    p.match(T, shift=1)
    p.load(T, imm=0x00)
    p.branch("last1", "read_ack")  # R/W bit is the last bit everyone sampled

    ack(T)
    p.label("write_byte")
    p.choice(C, [None, STOP], "stop")
    p.choice(C, [RESTART], "restart")
    p.load(C)
    byte(C, T)
    p.load(T, imm=0x00)
    ack(T)
    p.jump("write_byte")

    p.label("read_ack")
    ack(T)
    p.label("read_byte")
    p.load(T)
    byte(T, C)
    p.load(C)  # the controller's queue holds its ACK or NACK for each byte
    ack(C)
    p.jump("read_byte")

    p.label("restart")
    p.step("SDA", C, 1, half)
    p.step("SCL", C, 1, half)
    p.step("SDA", C, 0, half)  # the START trap fires
    p.jump("hang")

    p.label("stop")
    p.step("SDA", C, 0, half)  # SDA may already be low, so nothing to sync on
    p.step("SCL", C, 1, half, sync=True)
    p.step("SDA", C, 1, half, sync=True)  # the STOP trap fires
    p.jump("hang")
    return p


def onewire(div=0):
    """One tick is one microsecond. With a 25 MHz clock, div=24 makes it so:
    the prescaler stretches each tick to div+1 clocks. The model counts in
    ticks, so div changes nothing here; it only sets the chip's clock rate."""
    p = Prog("onewire", {"DQ": OPEN_DRAIN})
    if div:
        p.mode(div=div)
    p.hold_trap("DQ", 0, 130, "suspect")  # longer than any legal slot
    p.hold_trap("DQ", 0, 300, "reset")

    p.label("idle")
    p.claim(C, "DQ")
    p.step("DQ", C, 0, 320, sync=True)  # the width traps take everyone onward

    p.label("hang")
    p.jump("hang")

    p.label("suspect")
    p.step("DQ", C, 0, 170)  # still low here unless the pulse was illegal
    p.step("DQ", C, 1, 2, free=True)  # reached only after an illegal pulse ended
    p.jump("idle")

    p.label("reset")
    p.step("DQ", C, 0, 180)  # rest of the reset; the width trap aligned everyone
    p.step("DQ", C, 1, 15, sync=True)
    p.load(T, imm=0x00)
    p.bits("DQ", T, dwell=120)  # presence pulse
    p.store(C)
    p.step("DQ", C, 1, 300)  # no device means the line never went low

    p.load(C)
    p.counter(8)
    p.label("write_slot")
    p.step("DQ", C, 0, 6, sync=True)
    p.bits("DQ", C, dwell=54)
    p.step("DQ", C, 1, 10, free=True)  # recovery; a reset may be starting
    p.loop("write_slot")
    p.store(T)

    p.label("read_byte")
    p.choice(C, [None], "idle")
    p.load(C)
    p.load(T)
    p.counter(8)
    p.label("read_slot")
    p.step("DQ", C, 0, 6, sync=True)
    p.bits("DQ", T, dwell=18)
    p.step("DQ", C, 1, 40, free=True)  # recovery; a reset may be starting
    p.loop("read_slot")
    p.store(C)
    p.jump("read_byte")
    return p


def can(bit):
    """Classic CAN base frames. Any node may send, so nodes start as S."""
    p = Prog("can", {"BUS": OPEN_DRAIN})
    p.hold_trap("BUS", 1, 20 * bit, "idle")  # bus integration after an error

    def field(n):
        p.load(S)
        p.bits("BUS", S, n, dwell=bit)
        p.store(ALL)

    p.mode(msb=True, resync="BUS", poly=0x4599, width=15, on_error="bad")
    p.label("idle")
    p.claim(S, "BUS", otherwise=R)
    p.mode(stuff=5, lose_to=R)
    p.step("BUS", S, 0, bit, sync=True)  # start of frame
    field(3)  # ID top bits
    field(8)  # ID low bits
    field(7)  # RTR, IDE, r0 and the length
    p.mode(lose_to=None)
    p.counter(mask=0xF, cap=8)
    p.branch("count0", "crc")
    p.label("data")
    field(8)
    p.loop("data")
    p.label("crc")
    p.bits("BUS", S, 15, src="crc", dwell=bit)
    p.mode(stuff=0)
    p.step("BUS", S, 1, bit)  # CRC delimiter
    p.branch("crc_bad", "crc_bad")
    p.step("BUS", R, 0, bit)  # ACK slot
    p.label("tail")
    p.bits("BUS", S, 11, src=1, dwell=bit)  # delimiter, EOF, intermission
    p.jump("idle")

    p.label("crc_bad")
    p.step("BUS", S, 1, bit)  # stay off the ACK slot
    p.jump("tail")

    p.label("bad")
    p.jump("bad")  # wait for the idle trap
    return p


def usb(bit):
    """Low-speed USB, one OUT transaction: a token and a data packet from the
    host, then a handshake from the device. The host queues each packet as
    its bytes after SYNC, CRC included, then STOP. The chip does the line
    code, the stuffing, the CRC16 check and the end of packet."""
    p = Prog("usb", {"DP": PUSH_PULL, "DM": PUSH_PULL})
    p.hold_trap("DM", 1, 17 * bit, "tmo")  # idle bus: no packet is coming

    def sync(owner):
        p.step("DM", owner, 0, bit, sync=True)  # SYNC: KJKJKJ, then KK
        p.bits("DM", owner, 6, src=0, dwell=bit)
        p.step("DM", owner, 1, bit)

    p.mode(nrzi=True, pair="DP", resync="DM", poly=0x8005, width=16 | INIT1,
           resid=0x800D, on_error="done", on_break="eop2")
    p.label("top")
    p.counter(2)  # two host packets: token, then data
    p.claim(H, "DM")
    p.label("packet")
    p.mode(stuff=6 | ONES)  # a 0 after six 1s, from SYNC to the end of packet
    sync(H)
    p.load(H)
    p.bits("DM", H, 8, dwell=bit)  # PID
    p.store(D)
    p.mode(width=16 | INIT1)  # the CRC starts after the PID
    p.label("byte")
    p.choice(H, [STOP], "eop")
    p.load(H)
    p.bits("DM", H, 8, dwell=bit)
    p.store(D)
    p.jump("byte")
    p.label("eop")
    p.bits("DM", H, 1, dwell=bit, brk=True)  # SE0; listeners see it and jump
    p.label("eop2")
    p.bits("DM", H, 1, dwell=bit, brk=True)
    p.mode(stuff=0)  # the coder stops, so the CRC keeps its value
    p.step("DM", H, 0, bit)  # J, as a change from SE0
    p.step("DM", H, 1, bit)  # bus turnaround
    p.loop("packet")
    p.branch("crc_bad", "done")  # the data packet: no handshake for a bad CRC16

    p.load(D, imm=0xD2)  # ACK
    sync(D)
    p.bits("DM", D, 8, dwell=bit)
    p.store(H)
    p.bits("DM", D, 2, dwell=bit, brk=True)
    p.step("DM", D, 0, bit)
    p.jump("done")

    p.label("lost")  # no handshake came: every hart counts a violation
    p.mode(width=16 | INIT1)
    p.branch("crc_bad", "done")
    p.label("done")
    p.set("DM", ALL, None)
    p.set("DP", ALL, None)
    p.jump("top")
    p.label("tmo")
    p.branch("count0", "lost")  # the counter is 0 only while a handshake is due
    p.jump("done")
    return p
