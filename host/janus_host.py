"""Host driver for the Janus chip's SPI port.

Runs on a PC (CPython) and on a microcontroller (MicroPython). The chip is an
SPI mode 0 device, MSB first, with SCK at most 1/8 of the chip clock. Each
frame is one chip-select period, and its first byte chooses what it does.

The `Janus` class needs one function, `transfer(data) -> replies`, that sends
the bytes of one frame with chip select held low and returns the bytes read
back on MISO, one per byte sent. `pico_link.py` provides it for a Raspberry Pi
Pico. The cocotb tests drive the chip through the same frame builders.
"""

# Registers written with frame 2h. 0-5 are the trap configuration.
REG_TRAPS = 0          # 0..5
REG_ROLE = 6
REG_ADDR = 7
REG_OD_MASK = 8        # bit i set: hart pin i is open drain
REG_ROT = 9            # chip pin rot+i is hart pin i
REG_START = 10         # program address the hart starts at
REG_FAULT = 11         # adversary: bit 15 enable, bits 11:0 which owned bit to send wrong

# Roles. A program names its parties; A, C and S are role 0, B, T and R role 1.
ROLE = {"A": 0, "C": 0, "S": 0, "B": 1, "T": 1, "R": 1, "WITNESS": 3}

# Transmit queue entries: data, or a request to end or restart a transfer.
CTL_DATA, CTL_STOP, CTL_RESTART = 0, 1, 2

# Status flag bits, as returned by `status()`.
FLAG_NAMES = ("rx_empty", "rx_full", "tx_empty", "tx_full", "arb_lost", "rx_overflow")

# Where a hart stands, as returned by `where()`: one name per state number.
STATE_NAMES = ("boot", "exec", "claim", "sync", "edge", "mid", "settle", "post",
               "clock_enter", "clock_gap", "clock_top", "clock_a_wait", "clock_a",
               "clock_b_wait", "clock_b", "fetch")

PROGRAM_WORDS = 64


# Frame builders. Each returns the bytes of one frame.

def frame_program_word(address, word):
    if not 0 <= address < PROGRAM_WORDS:
        raise ValueError("program address out of range: %d" % address)
    return bytes((0x10, address, word >> 24 & 0xFF, word >> 16 & 0xFF,
                  word >> 8 & 0xFF, word & 0xFF))


def frame_register(hart, reg, value):
    return bytes((0x20 | hart, reg, value >> 8 & 0xFF, value & 0xFF))


def frame_control(run0, run1, loopback):
    return bytes((0x30, (1 if run0 else 0) | (2 if run1 else 0) | (4 if loopback else 0)))


def frame_push(hart, byte, ctl=CTL_DATA):
    return bytes((0x40 | hart, ctl, byte & 0xFF))


def frame_read(hart, count):
    return bytes((0x50 | hart,)) + bytes(count)


def frame_status(hart):
    return bytes((0x60 | hart, 0, 0))


def frame_where(hart):
    return bytes((0x70 | hart,)) + bytes(6)


# Reply parsers.

def parse_read(replies):
    """Received bytes. An empty receive queue reads as 0."""
    return list(replies[1:])


def parse_status(replies):
    """(violation count, {flag name: bool})."""
    flags = replies[2]
    return replies[1], {name: bool(flags >> i & 1) for i, name in enumerate(FLAG_NAMES)}


def parse_where(replies):
    """Where a hart stands, all from one tick: its program counter, the role
    it holds now, its state, and the instruction word it is at."""
    return {"pc": replies[1] & 0x3F, "role": replies[2] >> 6,
            "state": STATE_NAMES[replies[2] & 15],
            "word": replies[3] << 24 | replies[4] << 16 | replies[5] << 8 | replies[6]}


class Janus:
    """The chip, reached through `transfer(data) -> replies`."""

    def __init__(self, transfer, wait=None):
        self.transfer = transfer
        self.wait = wait or (lambda: None)   # optional pause between control frames
        self.loopback = False
        self.running = [False, False]

    def load(self, words, base=0):
        """Write program words. The harts that run them must be stopped."""
        for i, word in enumerate(words):
            self.transfer(frame_program_word(base + i, word))

    def write_register(self, hart, reg, value):
        self.transfer(frame_register(hart, reg, value))

    def configure(self, hart, image, role, addr=0, rot=0, fault=None):
        """Set up a hart to run a program image as one role. With fault=n the
        hart is an adversary: it sends the nth timed bit it owns wrong, once."""
        for i, word in enumerate(image["config"]):
            self.write_register(hart, REG_TRAPS + i, word)
        self.write_register(hart, REG_ROLE, ROLE[role] if isinstance(role, str) else role)
        self.write_register(hart, REG_ADDR, addr)
        self.write_register(hart, REG_OD_MASK, image["od_mask"])
        self.write_register(hart, REG_ROT, rot)
        self.write_register(hart, REG_START, image.get("base", 0))
        self.write_register(hart, REG_FAULT, 0 if fault is None else 0x8000 | fault)

    def run(self, hart0, hart1, loopback=False):
        """Start or stop the harts. Loopback is chosen in an earlier frame than
        the run bits, so harts leave reset already watching the right line."""
        if loopback != self.loopback or not (hart0 or hart1):
            self.transfer(frame_control(False, False, loopback))
            self.wait()
        self.transfer(frame_control(hart0, hart1, loopback))
        self.loopback, self.running = loopback, [hart0, hart1]

    def stop(self):
        self.run(False, False, self.loopback)

    def push(self, hart, data):
        """Queue bytes to transmit. STOP and RESTART are given as the strings
        "STOP" and "RESTART"."""
        for item in data:
            if item == "STOP":
                self.transfer(frame_push(hart, 0, CTL_STOP))
            elif item == "RESTART":
                self.transfer(frame_push(hart, 0, CTL_RESTART))
            else:
                self.transfer(frame_push(hart, item))

    def read(self, hart, count):
        """Read up to `count` received bytes. Past the end of the queue, 0."""
        return parse_read(self.transfer(frame_read(hart, count)))

    def status(self, hart):
        """(violation count, flags)."""
        return parse_status(self.transfer(frame_status(hart)))

    def where(self, hart):
        """Where a hart stands: {"pc", "role", "state", "word"}. Use it to see
        what a hart is waiting for when nothing arrives."""
        return parse_where(self.transfer(frame_where(hart)))

    def read_program(self, hart, base, count):
        """Read program words back from the chip. The hart must be stopped: a
        stopped hart stands at its start address, so this moves that address
        along the words and puts it back at `base`."""
        words = []
        for address in range(base, base + count):
            self.write_register(hart, REG_START, address)
            words.append(self.where(hart)["word"])
        self.write_register(hart, REG_START, base)
        return words


def program_image(prog, base=0):
    """Assemble a program into what `configure` and `load` need. PC only: it
    uses the assembler in this repository, which MicroPython does not have."""
    import encode   # noqa: PLC0415
    return {
        "base": base,
        "words": list(encode.assemble(prog, base)),
        "config": list(encode.config_words(prog, base)),
        "od_mask": sum(1 << i for i, pin in enumerate(prog.pins) if prog.pins[pin]),
    }
