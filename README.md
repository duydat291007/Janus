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
| `janus.py`, `protocols.py`, `encode.py` | The model, the five protocol programs, and the assembler |
| `test_*.py`, `reference.py` | Model tests against independent reference devices |
| `check_sync.py` | Static checker for the `sync` rule |
| `rtl/` | Working copy of the chip, plus replay, proof and planted-bug tools |
| `KILL_TEST.md` | The engineering record: rules, results and limits |

`rtl/janus_chip.v` and `rtl/janus_hart.v` are the working copies. Copy them to
`src/` after any change.

## Status

Everything below was checked in simulation or by formal proof. The design has
not yet been through placement and routing unless the GDS action shows it.

- UART, SPI, I2C, 1-Wire and CAN base frames run end to end through the host port.
- The Verilog matches the Python model tick for tick.
- An unbounded proof covers timed bits, `sync`, stuffing and CRC on the real
  Verilog, for every program in that subset. It does not yet cover clocked bits,
  traps, `claim`, `choice`, `match`, arbitration, resync or witnesses, so no
  complete protocol is fully proven.
- CAN has no error frames or automatic retransmission, so it must not be used on
  a shared CAN bus.

## Running the checks

The model tests need only Python:

```
python test_janus.py
python test_onewire.py
python test_can.py
python check_sync.py
```

The rest need the OSS CAD Suite. `rtl/setup_tools.sh` installs it under `$HOME`
and fetches the cell library. Then, from `rtl/`:

```
bash chip.sh test
bash run.sh replay
bash prove_ind.sh d4
bash chip.sh synth
```
