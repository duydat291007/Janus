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
| `demo/` | Interactive demo page built from model traces |
| `janus.py`, `protocols.py`, `encode.py` | The model, the six protocol programs, and the assembler |
| `test_*.py`, `reference.py` | Model tests against independent reference devices |
| `check_sync.py` | Static checker for the `sync` rule |
| `rtl/` | Working copy of the chip, plus replay, proof and planted-bug tools |
| `KILL_TEST.md` | The engineering record: rules, results and limits |

`rtl/janus_chip.v` and `rtl/janus_hart.v` are the working copies. Copy them to
`src/` after any change.

## Status

The chip without the host readback frame passed the full Tiny Tapeout flow:
layout, precheck and gate-level test. The readback frame is newer. It passes
every local check and has not been through the flow yet. Everything below
was checked in simulation or by formal proof.

- UART, SPI, I2C, 1-Wire and CAN base frames run end to end through the host port,
  and 1-Wire also at real 1 us timing using the prescaler.
- The Verilog matches the Python model tick for tick, and clock for clock with
  the prescaler set.
- One protocol is proven whole: UART. An unbounded proof runs the program
  word for word on two real harts, for any bit time from 8 ticks, any bytes
  arriving at any time, any load address, and a line that reads anything
  while undriven. Every byte the receiver stores is the byte the sender took,
  none is lost or invented, nothing is flagged, and a monitor that sees only
  the wire reads exact 8N1 frames. Writing it exposed a start-up bug in the
  program, now fixed: on a pin that read low before the first frame, the
  sender could emit a byte nobody queued.
- A second unbounded proof covers timed bits, `sync`, stuffing, CRC, NRZI,
  the pin pair and break bits for every program in that subset: the two harts
  stay in step, the listener reads what the owner sent, and neither counts a
  violation the other does not. It does not cover the jump on a break, `set`,
  clocked bits, traps, `claim`, `choice`, `match`, arbitration, resync or
  witnesses, so the other five protocols are not proven whole.
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
bash sim_uart.sh        # the UART proof's harness, simulated on random inputs
bash final_check.sh     # every planted-bug set and proof task
bash chip.sh synth
```

The cocotb tests run from `test/` with `make`, and drive the chip through the
same host driver a microcontroller uses.

GitHub runs the model tests, the replay and the chip scenarios on every push
(`.github/workflows/verify.yaml`), next to the Tiny Tapeout build.
