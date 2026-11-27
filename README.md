# Janus

A protocol emulator ASIC for the Jane Street competition, on IHP CMOS5L through
Tiny Tapeout.

Most programmable I/O engines run a program for one side of a bus. Janus runs a
program that describes the whole conversation, and a role register selects which
participant the chip plays. The same program can act as a controller, a
peripheral, or a witness that checks the traffic without driving anything.

## What is here

| Path | Contents |
|---|---|
| `src/` | The chip: `janus_chip.v` (top, FIFOs, host port) and `janus_hart.v` |
| `test/` | cocotb tests the Tiny Tapeout flow runs on RTL and gates |
| `docs/info.md` | Datasheet page, including the host port |
| `docs/ISA.md` | Instruction set reference: encodings, traps, timing rules, toolchain |
| `host/` | Host driver for a PC or a MicroPython board, with an example |
| `fpga/` | The chip on a Digilent Basys 3: top level, USB-UART bridge, build and bring-up |
| `demo/` | Interactive demo page built from model traces |
| `janus.py`, `protocols.py`, `encode.py` | The model, the six protocol programs, and the assembler |
| `test_*.py`, `reference.py` | Model tests against independent reference devices |
| `check_sync.py` | Static checker for the `sync` rule |
| `rtl/` | Working copy of the chip, plus replay, proof and planted-bug tools |
| `KILL_TEST.md` | The engineering record: rules, results and limits |

`rtl/janus_chip.v` and `rtl/janus_hart.v` are the working copies. Copy them to
`src/` after any change.

## Status

The chip as of commit f2488cb, with the `keep` flag and the host readback
frame, passed the full Tiny Tapeout flow: layout, precheck and gate-level
test. Since then the I2C and USB programs, which a host loads at run time, the
proofs and the documents have changed, and so has one thing in the chip: a hart no
longer counts a line as held while it pulls the line away itself, which the
CAN proof showed was needed. That chip was laid out locally with the same
flow, at a placement density of 40% instead of 45% so that it routes in
normal time, with clean checks and the gate-level test passing. On GitHub,
at fb666c7, it passed the full Tiny Tapeout flow: layout in 1 h 55 min,
precheck and gate-level test. The chip has not changed since, and the flow
passed again at 0e32b0b.
Everything below was checked in simulation or by formal proof.

- UART, SPI, I2C, 1-Wire and CAN base frames run end to end through the host port,
  and 1-Wire also at real 1 us timing using the prescaler.
- The Verilog matches the Python model tick for tick, and clock for clock with
  the prescaler set.
- All six protocol programs are proven whole, each in all three roles at once:
  a sender or controller, a receiver or target, and a witness. Each proof
  runs the program word for word on three real harts.
- UART was the first proven whole. An
  unbounded proof runs the program word for word on three real harts, a
  sender, a receiver and a witness, for any bit time from 8 ticks, any bytes
  arriving at any time, any load address, and a line that reads anything
  while undriven. Every byte the receiver stores is the byte the sender took,
  the witness logs the same byte on the same tick, none is lost or invented,
  nothing is flagged, and a monitor that sees only the wire reads exact 8N1
  frames. Writing it exposed a start-up bug in the
  program, now fixed: on a pin that read low before the first frame, the
  sender could emit a byte nobody queued.
- A second protocol is proven whole, in all three roles at once: SPI,
  controller, target and witness, in all four modes, for any half period from 8
  ticks. It covers what UART does not use: clocked bits, two data lines at
  once, gapless byte streams and a trap. Each side stores the byte the other
  sent, the witness logs both bytes of every slot, and a monitor that knows
  only the textbook rules for the mode reads the same bytes off the wires, and
  no byte leaves either queue unsent.
- A third protocol is proven whole, in all three roles at once: 1-Wire,
  controller, target and witness, at its real timing. It covers what the other
  two do not use: an open-drain line both sides pull low, traps on how long the
  line is held, a loop counter, and a stretch where the two harts are out of
  step and a trap brings them back. The target stores the byte written, the
  controller stores each byte read, the witness logs every byte, and a monitor
  that knows only the textbook rules sees a reset of at least 480 ticks, a
  presence pulse in its window and those same bytes. Building it exposed a bug,
  now fixed: a second transaction cleared the target's queue.
- A fourth protocol is proven whole, in all three roles at once: I2C,
  controller, target and witness, for any half period from 8 ticks and any
  target address. It covers what the others do not use: START and STOP traps
  that fire on one line's edge while the other is high, an address match after
  which a target that was not addressed steps aside, branches on the R/W bit
  and on ACK or NACK, a choice on the controller's queue between data, STOP and
  RESTART, and clocked bits on open-drain lines. The target stores the address
  and every byte written, the controller every byte read, the witness drives
  nothing and logs every byte of every transaction on the same ticks, and a
  monitor that knows only the textbook rules reads the same bytes and
  acknowledges and checks the timing: SCL low and high, data setup and hold,
  START setup and hold, STOP setup, and bus free time. Building it exposed a
  timing bug, now fixed: the next START could come 4 ticks after a STOP,
  whatever the clock rate.
- A fifth protocol is proven whole, in all three roles at once: CAN, a sender,
  a receiver or none, and a witness, for any bit time from 11 ticks. It covers
  what the others do not use: a claim that picks the role by whether a frame is
  queued, bit stuffing sent and checked, a CRC computed as the bits go and
  checked by the receiver, a loop counted by a received length,
  resynchronisation, the receiver's ACK inside the sender's frame, and a hold
  trap back to `idle`. Each hart stores every field the sender took, the
  witness drives nothing and logs the same fields on the same ticks, and a
  monitor that knows only the textbook rules for a base data frame reads the
  same fields, correct stuffing and CRC, and bits of exactly the bit time.
  Every hart counts each frame nobody acknowledged, and nothing else. Building
  it exposed a bug in the hart, now fixed: the hold trap could fire just after
  a start of frame went out, and both harts then received a phantom frame.
  Arbitration is proven too, with both queues free and for any bit time from 12
  ticks: whichever hart starts first, by up to 4 ticks, the frame with the
  smaller identifier wins, only the loser loses and drops its frame, both harts
  store the winner's fields, and the witness logs them. At 11 ticks the earlier
  sender can read the later one's start of frame as its first identifier bit.
- A sixth protocol is proven whole, in all three roles at once: low-speed USB,
  a host, a device or none, and a witness, for any bit time from 11 ticks. It
  covers what the others do not use: the complementary pin pair, NRZI, stuffing
  of ones only, a CRC16 the host computes and sends on RESTART, end-of-packet
  break bits and the listener's jump on one, a packet type read from its PID
  into the counter, and the turnaround in which the device answers. A monitor
  that knows only the textbook rules for a low-speed packet reads SYNC, the
  bytes the host took, correct stuffing and CRC16, two bit times of SE0, and at
  least two bit times between packets. No one drives the bus from two bit times
  after a packet until the next one. The device answers each data packet
  exactly when its CRC16 checks, stores every byte, and the host stores the
  ACK. The witness drives nothing and logs the same bytes on the same ticks.
  Every hart counts each bad CRC16 and, when no device is there, each handshake
  that has not come after 18 bit times, and nothing else. Nothing is assumed
  about what the host queues or when. Building it exposed three faults in the
  program, now fixed: the device counted packets to find the data packet, so on
  one tick a hold-trap timeout split host and device; after the ACK the host's
  next packet could follow after a little over one bit time, where the USB 2.0
  specification asks for two; and the host gave up on a handshake after 17 bit
  times, not 18. The device now tells a data packet by its PID, still within 48
  instructions.
- Another unbounded proof covers timed bits, `sync`, stuffing, CRC, NRZI,
  the pin pair and break bits for every program in that subset: the two harts
  stay in step, the listener reads what the owner sent, and neither counts a
  violation the other does not. It does not cover the jump on a break, `set`,
  clocked bits, traps, `claim`, `choice`, `match`, arbitration, resync or
  witnesses.
- For bring-up, the host can read where each hart stands: its program
  counter, role, state and current instruction, captured on one tick. Through
  a stopped hart it can also read the program memory back.
- CAN has no error frames or automatic retransmission, so it must not be used on
  a shared CAN bus.
- Low-speed USB was a hold-out test. It failed on the frozen instruction set and
  passes after four general additions: a complementary pin pair, NRZI, stuffing
  of ones only, and a CRC start value and residual. The program covers one OUT
  transaction at the packet layer and needs a 24 MHz clock. The chip computes,
  sends and checks the data packet's CRC16; the token's CRC5 comes from the
  host and is not checked. The program is at both limits set for it: 48
  instructions and 3 role-dependent ones. It has no address
  filter, no IN transfers and no enumeration, and it has run in simulation only.
  The record is in `KILL_TEST.md`.
- Any hart can be an adversary that sends one chosen bit wrong. Sweeping that
  over every bit of a CAN frame and a USB transaction found three bugs, now
  fixed, and shows what the other harts catch: every CAN fault, and every USB
  fault in the data and CRC16, but not faults in a USB token or PID.

## Running the checks

The model tests need only Python:

```
python test_janus.py
python test_onewire.py
python test_can.py
python test_usb.py
python test_adversary.py
python check_sync.py
```

The rest need the OSS CAD Suite. `rtl/setup_tools.sh` installs it under `$HOME`
and fetches the cell library. Then, from `rtl/`:

```
bash chip.sh test
bash run.sh replay
bash div_replay.sh
bash prove_ind.sh d4
bash prove_uart.sh
bash prove_spi.sh
bash prove_onewire.sh
bash prove_i2c.sh
bash prove_can.sh
bash prove_can_arb.sh
bash prove_usb.sh
bash sim_uart.sh        # the UART proof's harness, simulated on random inputs
bash final_check.sh     # every planted-bug set and proof task
bash chip.sh synth
```

The cocotb tests run from `test/` with `make`, and drive the chip through the
same host driver a microcontroller uses.

GitHub runs the model tests, the replay and the chip scenarios on every push
(`.github/workflows/verify.yaml`), next to the Tiny Tapeout build.
