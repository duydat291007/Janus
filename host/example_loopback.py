"""MicroPython example: hart 0 sends "Janus" over UART to hart 1 inside the
chip, through the internal loopback, and the host reads it back.

On a PC first: python host/make_image.py uart 50 > uart50.json
Then copy janus_host.py, pico_link.py, uart50.json and this file to the board
and run it. Change the pin numbers to the GPIOs wired to the chip.
"""
import json
import time

from janus_host import Janus
from pico_link import PicoLink

link = PicoLink(sck=2, mosi=3, miso=4, cs=5)        # set to your wiring
chip = Janus(link.transfer, wait=lambda: time.sleep_ms(1))

with open("uart50.json") as f:
    image = json.load(f)

chip.stop()
chip.load(image["words"], image["base"])
chip.configure(0, image, "A")     # hart 0 sends
chip.configure(1, image, "B")     # hart 1 receives
message = b"Janus"
chip.push(0, message)
chip.run(True, True, loopback=True)
time.sleep_ms(10)                 # 5 bytes at 50 clocks per bit take well under 1 ms

received = chip.read(1, len(message))
violations, flags = chip.status(1)
print("received:", bytes(received))
print("violations:", violations, "flags:", flags)
print("OK" if bytes(received) == message and violations == 0 else "MISMATCH")
