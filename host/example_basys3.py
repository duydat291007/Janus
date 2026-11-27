"""Bring-up on a Basys 3, from a PC: python host/example_basys3.py COM5

1. The bridge answers: the bitstream is loaded and the UART works.
2. A program written to the chip reads back word for word.
3. Hart 0 sends "Janus" over UART to hart 1 inside the chip (loopback).
4. The same over the Pmod pins: both harts on JA1, so the bytes cross the
   FPGA's pins, with nothing plugged in.
Needs pyserial (pip install pyserial). Run from the project root.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from janus_host import Janus, program_image  # noqa: E402
from serial_link import SerialLink  # noqa: E402
import protocols  # noqa: E402


def main(port):
    link = SerialLink(port)
    if not link.check():
        sys.exit("no answer from the bridge on %s: is the bitstream loaded, switch 15 down?" % port)
    print("1. bridge answers")

    chip = Janus(link.transfer, wait=lambda: time.sleep(0.001))
    image = program_image(protocols.uart(50))
    chip.stop()
    chip.load(image["words"], image["base"])
    back = chip.read_program(0, image["base"], len(image["words"]))
    ok = back == image["words"]
    print("2. program read back:", "OK" if ok else "MISMATCH")

    message = b"Janus"
    results = []
    for loopback in (True, False):
        chip.stop()
        chip.configure(0, image, "A")
        chip.configure(1, image, "B")
        chip.read(1, 16)                     # drop anything left over
        chip.push(0, message)
        chip.run(True, True, loopback=loopback)
        time.sleep(0.01)
        got = bytes(chip.read(1, len(message)))
        violations = chip.status(1)[0]
        good = got == message and violations == 0
        results.append(good)
        print("%d. %s: received %r, %d violations: %s"
              % (3 if loopback else 4, "inside the chip" if loopback else "over the Pmod pins",
                 got, violations, "OK" if good else "MISMATCH"))
    chip.stop()
    print("ALL OK" if ok and all(results) else "SOMETHING FAILED")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "COM5")
