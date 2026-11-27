"""PC link to Janus on a Digilent Basys 3, through the board's USB-UART.

The FPGA build (fpga/basys3) puts a bridge in front of the chip's host port:
the PC sends a frame's length, then its bytes, and gets one byte back for
each, as the chip's MISO gave it. Needs pyserial: pip install pyserial.

    from janus_host import Janus
    from serial_link import SerialLink
    link = SerialLink("COM5")            # or "/dev/ttyUSB1" on Linux
    chip = Janus(link.transfer)
"""
ID = 0xA5          # what the bridge answers to a length of 0
BAUD = 1_000_000


class SerialLink:
    def __init__(self, port, baudrate=BAUD, timeout=1.0, port_object=None):
        if port_object is None:
            import serial   # noqa: PLC0415  pyserial, only when a real port is opened
            port_object = serial.Serial(port, baudrate=baudrate, timeout=timeout)
        self.port = port_object
        self.port.reset_input_buffer()

    def check(self):
        """True when the bridge answers: the bitstream is loaded and running."""
        self.port.write(b"\x00")
        return self.port.read(1) == bytes((ID,))

    def transfer(self, data):
        """One frame: chip select low, the bytes out and in, chip select high."""
        data = bytes(data)
        if not 1 <= len(data) <= 255:
            raise ValueError("a frame is 1 to 255 bytes, not %d" % len(data))
        self.port.write(bytes((len(data),)) + data)
        reply = self.port.read(len(data))
        if len(reply) != len(data):
            raise TimeoutError("the bridge sent %d of %d bytes back" % (len(reply), len(data)))
        return bytearray(reply)

    def close(self):
        self.port.close()
