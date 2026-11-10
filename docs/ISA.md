# Janus instruction set

A Janus program describes a whole protocol conversation. Every participant runs
the same program, and a role register decides what each instruction means to
that participant: drive the bit, check it, or only watch. This document is the
reference for the instruction words, the trap configuration and the toolchain.
The behaviour described here is what `janus.py` models and what the Verilog in
`src/` is checked against, tick for tick.

## Machine model

| Part | Description |
|---|---|
| Harts | Two independent harts. Each runs one program at a time. |
| Program memory | 64 words of 32 bits, shared by both harts. Jump targets are absolute addresses. |
| Pins | A hart uses up to 4 of the chip's 8 protocol pins, chosen by a pin rotation register. Each pin is open drain or push-pull, set by the host. |
| Queues | Per hart: an 8-entry transmit queue (data, STOP or RESTART) and an 8-entry receive queue. |
| Tick | The hart's unit of time. One clock, or `div + 1` clocks with the prescaler set. All dwell times are in ticks. |
| Role | 0 (A, C or S), 1 (B, T or R), or 3 (witness). Set by the host; some instructions may change it while a program runs. |

### Parties and roles

Instructions name a party. A hart acts on an instruction when the party is its
role ("mine"); otherwise it listens.

| Party value | Name in programs | Mine for |
|---|---|---|
| 0 | `A`, `C`, `S` | role 0 |
| 1 | `B`, `T`, `R` | role 1 |
| 2 | `ALL` | every role except the witness |
| 3 | `WITNESS` | the witness |

A witness never drives a pin. It samples every bit, checks constants, and logs
every byte the program stores, so a correct program is also a correct protocol
checker.

### Timing rules

- Input lag: a pin change is seen 2 ticks after it happens (a two-stage
  synchronizer). `sync` bits account for it.
- A timed bit starts at its bit edge. The owner drives at the edge; everyone
  samples at the middle (edge + dwell/2) and moves on.
- Instructions between bits do not stretch the bit: the next bit's edge is the
  previous edge plus dwell.
- The smallest dwell the formal proof covers is 4 ticks.
- The `sync` rule: on every path into a `sync` bit, the line must be at the
  opposite level of the bit's constant. `check_sync.py` checks this statically.
  It does not cover NRZI programs, where a `sync` bit waits for any change.
- Between two timed bits there is room for a few instructions: with 16 ticks
  per bit, at most 7. More than that makes the next bit late.

## Instruction words

Bits 31 to 28 hold the opcode. Unused bits must be 0.

| Opcode | Instruction | Role-dependent |
|---|---|---|
| 0 | `set` | no |
| 1 | `bits` | no |
| 2 | `claim` | can be |
| 3 | `load` | no |
| 4 | `store` | no |
| 5 | `branch` | no |
| 6 | `choice` | yes |
| 7 | `match` | yes |
| 8 | `counter` | no |
| 9 | `mode` | only for `lose_to` and `on_break` |

"Role-dependent" means the instruction can make control flow differ between
roles. A program should have few of them; the six reference programs have at
most 3.

### set: drive or release a pin

| Bits | Field |
|---|---|
| 26:25 | pin |
| 24:23 | owner party |
| 22:21 | 0 drive low, 1 drive high, 2 release |

If the owner is mine, apply it. Takes one tick.

### bits: move bits on the wire

| Bits | Field |
|---|---|
| 26:25 | pin |
| 24:23 | owner party |
| 22:21 | source: 0 transmit byte, 1 CRC, 2 constant 0, 3 constant 1 |
| 20:17 | bit count minus 1 (1 to 16 bits) |
| 16 | `sync`: listeners wait for the line to change to the constant |
| 15 | `clocked`: timed by the clock pin set in `mode`, dwell is the half period |
| 14 | timed: `free` (listeners do not check a constant). Clocked: `stream` |
| 13 | timed: `brk`, a break bit |
| 10:0 | dwell, in ticks (timed: bit time; clocked: half period) |

- **Owner:** drives each bit. From the transmit byte (shifted by `msb`), the
  CRC, or a constant.
- **Listener:** samples each bit at mid-bit into the receive shift register.
  A constant that does not match counts a violation, unless `free`.
- **Coder:** with stuffing enabled in `mode`, bits run through a run-length
  stuffer and the CRC. A missing stuff bit counts a violation and jumps to
  `on_error`. With the ones-only flag, only a run of 1s is counted and the
  stuffed bit is a 0, as USB needs.
- **Pair:** with `pair` set in `mode`, the owner drives a second pin as the
  complement of the bit, and releasing the bit releases both.
- **NRZI:** with `nrzi` set, a 0 is a change of level and a 1 is none. The
  owner codes against the level on the line; a listener decodes against the
  level it sampled one bit earlier. Constants, stuff bits, the CRC and the
  received byte all use the decoded bit. A `sync` bit waits for a change away
  from the last sampled level.
- **Break:** a `brk` bit drives the pin and its pair low (SE0 in USB). It
  bypasses NRZI and the coder. A listener counts a violation if either pin is
  high, unless `free`. A listener that samples both pins low in an ordinary
  bit, with `on_break` set, jumps there; a break in the middle of a byte
  counts a violation first.
- **Arbitration:** an owner that drives a 1 data bit and reads 0, with
  `lose_to` set to a role, becomes that role and stops driving. In clocked
  bits this applies to open-drain pins only.
- **Clocked bits:** the clock owner drives the clock pin; everyone shifts data
  on the clock edges selected by `cpol` and `cpha`. A second data lane is
  available through `lane2`. `stream` refills and stores between bytes without
  a gap, and only the clock owner decides to stop.

### claim: wait for the bus

| Bits | Field |
|---|---|
| 26:25 | pin |
| 24:23 | party |
| 22 | settle the role |
| 21:20 | role otherwise |

Waits until the party (by base role) has data to send, or the pin goes low.
With bit 22 set, the party keeps its role if it has data and the pin is high,
and otherwise takes the role in bits 21:20, as CAN arbitration needs.

### load: fill the transmit byte

| Bits | Field |
|---|---|
| 27:26 | party |
| 25 | from the instruction instead of the queue |
| 7:0 | immediate byte |

If the party is mine: take the next queue entry (0xFF if the queue is empty),
or the immediate byte.

### store: hand a byte to the host

| Bits | Field |
|---|---|
| 27:26 | party |
| 25 | lane: 0 main, 1 second lane |

If the party is mine, push the received byte to the receive queue. A witness
logs it instead.

### branch: jump

| Bits | Field |
|---|---|
| 27:25 | condition |
| 5:0 | target address |

| Condition | Name | Jumps when |
|---|---|---|
| 0 | `always` | always |
| 1 | `last0` | the last bit seen was 0 |
| 2 | `last1` | the last bit seen was 1 |
| 3 | `count0` | the counter is 0 |
| 4 | `loop` | after decrementing, the counter is not 0 |
| 5 | `crc_bad` | the CRC differs from `resid` (0 unless set); also counts a violation |

### choice: let the sender decide

| Bits | Field |
|---|---|
| 27:26 | party |
| 25 | jump if the transmit queue is empty |
| 24 | jump on STOP |
| 23 | jump on RESTART |
| 5:0 | target address |

Only the party evaluates it; a taken STOP or RESTART entry is popped. Other
parties learn the choice from the wire later.

### match: address filter

| Bits | Field |
|---|---|
| 27:26 | party |
| 25:23 | shift |

If the party is mine and the received byte, shifted right by `shift`, differs
from the address register, the hart becomes a witness until a trap restores
its base role, as at the next START.

### counter: set the loop count

| Bits | Field |
|---|---|
| 27 | from received data |
| 23:16 | cap |
| 15:8 | mask |
| 7:0 | count |

Counter = count, or (received byte AND mask) limited to cap, for a length
field.

### mode: write one setting

| Bits | Field |
|---|---|
| 27:23 | field number |
| 15:0 | value |

| Field | Name | Value |
|---|---|---|
| 0 | `msb` | bit 0: send and receive most significant bit first |
| 1 | `resync` | bit 3 enable, bits 1:0 pin: listeners realign to falling edges on it |
| 2 | `stuff` | bits 3:0: stuff after this many equal bits, 0 off; bit 4: count only 1s and stuff a 0; nonzero restarts the coder |
| 3 | `poly` | CRC polynomial |
| 4 | `width` | bits 4:0: CRC width; bit 5: the CRC restarts at all ones, not 0. Writing it restarts the CRC |
| 5 | `on_error` | bits 5:0: address to jump to on a stuffing error |
| 6 | `lose_to` | bits 1:0: role an owner takes on losing arbitration; 2 never loses |
| 7 | `clk` | bits 1:0: clock pin for clocked bits |
| 8 | `clk_owner` | bits 1:0: party that drives the clock |
| 9 | `cpol` | bit 0: clock idle level |
| 10 | `cpha` | bit 0: clock phase |
| 11 | `lane2` | bit 5 enable, bits 3:2 pin, bits 1:0 owner: a second data lane |
| 12 | `div` | bits 7:0: prescaler; a tick lasts `div + 1` clocks |
| 13 | `pair` | bit 3 enable, bits 1:0 pin: timed bits drive it as the complement |
| 14 | `nrzi` | bit 0: timed bits are NRZI coded |
| 15 | `resid` | the CRC value that `crc_bad` accepts |
| 16 | `on_break` | bit 6 enable, bits 5:0: address a listener jumps to on a break |

## Traps

Traps are not instructions. The host writes six 16-bit registers with a
program. A trap is always armed, and when it fires the hart restores its base
role, counts a violation if a frame was cut off mid-byte, and jumps.

| Register | Contents |
|---|---|
| 0, 1 | Edge traps |
| 2, 3 | Hold traps |
| 4, 5 | Tick counts for hold traps 2 and 3 |

Edge and hold trap words:

| Bits | Edge trap | Hold trap |
|---|---|---|
| 15 | enable | enable |
| 14:9 | target address | target address |
| 7:6 | pin | pin |
| 5 | fires on a change to this level | fires after the pin stays at this level |
| 4 | also require a level on another pin | unused |
| 2:1 | that pin | unused |
| 0 | that level | unused |

An edge trap catches events like an I2C START (SDA falls while SCL is high). A
hold trap catches a level held for a count of ticks, like a 1-Wire reset pulse.
If several traps fire in one tick, only the first edge trap counts, and a hold
trap overrides it; hold trap 3 overrides hold trap 2.

## Example: UART

```python
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
```

Assembled with `bit = 50`:

| Address | Word | Instruction | Meaning |
|---|---|---|---|
| 0 | `00200000` | `set` | A drives TX high |
| 1 | `20000000` | `claim` | wait until A has a byte, or the line falls |
| 2 | `30000000` | `load` | A takes the next byte |
| 3 | `10410032` | `bits` | start bit: A drives 0; others wait for the falling edge |
| 4 | `100E0032` | `bits` | 8 data bits from A's byte, 50 ticks each |
| 5 | `44000000` | `store` | B keeps the byte; a witness logs it |
| 6 | `10600032` | `bits` | stop bit: A drives 1; others check it |
| 7 | `50000001` | `branch` | back to `idle` |

Run as role A it is a UART transmitter, as role B a receiver, and as a witness
a checker that flags a bad start or stop bit.

## Toolchain

| Tool | Use |
|---|---|
| `janus.py` | Assembler (`Prog`) and the reference model the chip is checked against |
| `protocols.py` | UART, SPI, I2C, 1-Wire, CAN and low-speed USB programs |
| `encode.py` | Turns a `Prog` into 32-bit words (`assemble`) and trap registers (`config_words`) |
| `check_sync.py` | Static check of the `sync` rule |
| `host/janus_host.py` | Host driver for the chip's SPI port, for a PC or MicroPython |
| `host/make_image.py` | Writes a program image (words and trap registers) as JSON |
| `host/pico_link.py`, `host/example_loopback.py` | Microcontroller link and an end-to-end example |

Writing and running a program:

```python
from janus import Prog, PUSH_PULL, WITNESS
import encode

p = Prog("blink", {"OUT": PUSH_PULL})
p.label("top")
p.step("OUT", "A", 1, 500)
p.step("OUT", "A", 0, 500)
p.jump("top")

words = encode.assemble(p)        # load these with frame 10
traps = encode.config_words(p)    # write these to registers 0-5 with frame 2h
```

The model runs a program without the chip:

```python
from janus import Bus, Hart
bus = Bus(p.pins)
a = Hart(p, "A", bus)
w = Hart(p, WITNESS, bus)
bus.add(a, w)
bus.run(5000)
print(w.violations)
```

The host port's frames and registers are in `docs/info.md`.
