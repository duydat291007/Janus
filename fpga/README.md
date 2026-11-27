# Janus on an FPGA: Digilent Basys 3

The chip does not fit the iCE40 UP5K that Tiny Tapeout's FPGA workflow
targets: it needs about 12,500 of its logic cells, and the UP5K has 5,280.
The Basys 3's Artix-7 (XC7A35T) holds it in about a third of its LUTs.

The FPGA runs the same Verilog as the chip, `src/janus_chip.v` and
`src/janus_hart.v`, with one change: the program memory's latches become
flip-flops (`fpga/fpga_source.py` writes that copy, and stops if the line it
changes is ever edited). Everything else is around the chip, in
`fpga/basys3/`.

## What is where

| | |
|---|---|
| Clock | 100 MHz divided to 25 MHz, the chip's Tiny Tapeout clock |
| Reset | at power-up, and the centre button |
| Protocol pins 0-7 | Pmod JA: JA1-JA4 and JA7-JA10, with the FPGA's weak pull-ups |
| Host port | the board's USB-UART at 1 Mbaud, through `uart_spi_bridge.v` |
| Host port, external | switch 15 up: Pmod JB, JB1 SCK, JB2 MOSI, JB3 CS, JB4 MISO |
| LEDs | 0 data received, 1 violation, 2 arbitration lost, 3-4 harts running, 5 bridge busy, 6-13 pins 0-7, 15 heartbeat |

The weak pull-ups are enough for the tests below. A real I2C or 1-Wire bus
needs its own pull-up resistors (4.7 kOhm), and every pin is 3.3 V.

## Build and load

Vivado (the free edition supports the XC7A35T), from the project root:

```
vivado -mode batch -source fpga/basys3/build.tcl
vivado -mode batch -source fpga/basys3/program.tcl
```

The first writes `fpga/build/janus_basys3.bit` with utilisation and timing
reports beside it; the second loads it over the board's USB cable.

## Bring-up

With switch 15 down and the board on USB (the COM port is the second of the
board's two):

```
pip install pyserial
python host/example_basys3.py COM5
```

It checks, in order: that the bridge answers, that a program written to the
chip reads back word for word, that hart 0 sends "Janus" over UART to hart 1
inside the chip, and the same across Pmod pin JA1 with nothing plugged in.

The same steps run in simulation, on the whole FPGA design with a simulated
PC on the UART: `cd fpga/basys3/test && make` (cocotb and Icarus Verilog).

## The bridge

The PC sends a frame's length (1 to 255), then its bytes; the bridge holds
chip select low, sends them on the host port and returns one byte for each,
then lets chip select go. A length of 0 is answered with A5. A frame the PC
stops sending halfway is ended after 10 ms. `host/serial_link.py` is the PC
side, and plugs into `host/janus_host.py` as the Pico link does.
