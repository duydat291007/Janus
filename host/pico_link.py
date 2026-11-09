"""MicroPython link from a Raspberry Pi Pico (or any MicroPython board) to the
Janus host port. Software SPI works on any pins.

Wire: SCK -> ui_in[0], MOSI -> ui_in[1], CS -> ui_in[2], MISO <- uo_out[0].
SCK must be at most 1/8 of the chip clock: 3.1 MHz at 25 MHz. The default,
500 kHz, leaves room.
"""
from machine import Pin, SoftSPI


class PicoLink:
    def __init__(self, sck, mosi, miso, cs, baudrate=500_000):
        self.spi = SoftSPI(baudrate=baudrate, polarity=0, phase=0, bits=8,
                           firstbit=SoftSPI.MSB, sck=Pin(sck), mosi=Pin(mosi), miso=Pin(miso))
        self.cs = Pin(cs, Pin.OUT, value=1)

    def transfer(self, data):
        """One frame: chip select low, the bytes out and in, chip select high."""
        out = bytearray(len(data))
        self.cs(0)
        try:
            self.spi.write_readinto(data, out)
        finally:
            self.cs(1)
        return out
