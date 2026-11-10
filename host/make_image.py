"""Write a program image for a microcontroller host, from a PC.

    python host/make_image.py uart 50 > uart50.json
    python host/make_image.py i2c 20 > i2c20.json
    python host/make_image.py onewire 24 > onewire.json   # 1 us ticks at 25 MHz

Copy the file to the board next to janus_host.py and pico_link.py.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import janus_host  # noqa: E402
import protocols  # noqa: E402

BUILDERS = {
    "uart": lambda n: protocols.uart(n),
    "spi": lambda n: protocols.spi(n),
    "i2c": lambda n: protocols.i2c(n),
    "onewire": lambda n: protocols.onewire(n),   # n is the prescaler
    "can": lambda n: protocols.can(n),
    "usb": lambda n: protocols.usb(n),           # n is ticks per bit: 16 at 24 MHz
}


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in BUILDERS:
        sys.exit(__doc__)
    name, n = sys.argv[1], int(sys.argv[2])
    image = janus_host.program_image(BUILDERS[name](n))
    image["name"] = f"{name} {n}"
    json.dump(image, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
