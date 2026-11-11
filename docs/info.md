## How it works

Janus is a programmable protocol emulator. A program describes a whole protocol
conversation, and a role register selects which participant the chip plays. The
same program runs as a controller, a peripheral, or a witness that checks the
traffic without driving anything.

The chip has two harts, a shared 64-word program memory, a transmit and a receive
FIFO for each hart, and an SPI host port. Each hart has its own role, start
address, trap configuration, open-drain mask and pin rotation, so the two can run
as a pair or as separate protocols. An internal loopback connects them with no
external wiring.

Programs for UART, SPI, I2C, 1-Wire and CAN base frames are in the project's
assembler. CAN here has no error frames or automatic retransmission, so do not
connect it to a shared CAN bus.

There is also a program for the packet layer of low-speed USB: one OUT
transaction of a token, a data packet and a handshake, with NRZI, bit stuffing,
the D+/D- pair, the CRC16 and the end of packet done on the chip. It needs
a 24 MHz clock, which gives 16 ticks per bit at 1.5 Mbit/s; at 25 MHz the bit
rate is 4% high, outside the USB tolerance. It has been checked in simulation
only. It does not filter by address, enumerate, or handle IN transfers, and the
electrical layer needs external parts.

## How to test

Drive the host port at an SCK of at most 1/8 of the clock, SPI mode 0, MSB first.
Each frame is selected by its first byte, and `h` is the hart number:

| Frame | Meaning |
|---|---|
| `10 addr d3 d2 d1 d0` | Write one program word, address 0 to 63. The harts using it must be stopped. |
| `2h reg hi lo` | Write a hart register: 0-5 traps, 6 role, 7 address, 8 open-drain mask, 9 pin rotation, 10 start address, 11 adversary fault |
| `30 ctrl` | Bit 0 runs hart 0, bit 1 runs hart 1, bit 2 selects loopback |
| `4h ctl data` | Push a transmit entry: ctl 0 data, 1 STOP, 2 RESTART |
| `5h xx xx ...` | Read received bytes; each dummy byte returns one |
| `6h xx xx` | Read the violation count (it stops at 255), then the status flags |

Status flags, from bit 5 down: receive overflow, arbitration lost, transmit full,
transmit empty, receive full, receive empty.

Set loopback in an earlier frame than the run bits, so harts leave reset watching
the right line.

To try it, load a UART program, give hart 0 role 0 and hart 1 role 1, select
loopback, run both, push a byte to hart 0, and read it back from hart 1.

The project repository has a host driver for MicroPython boards (`host/`), with
this exact example in `host/example_loopback.py`, and the full instruction set
in `docs/ISA.md`.

## External hardware

A host that can speak SPI, such as a microcontroller. Open-drain protocols need
pull-up resistors on the protocol pins in use.
