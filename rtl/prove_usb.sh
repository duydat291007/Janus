#!/usr/bin/env bash
# Prove the USB program. Usage: bash prove_usb.sh. WSL, from rtl/.
# sim_usb.sh simulates the same harness, and mutate_usb.sh plants bugs in it.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/usb"
mkdir -p "$OUT"
(cd .. && python3 rtl/gen_usb_rom.py "$OUT/usb_rom.vh") || exit 1
cp usb_ind.sby usb_ind.sv janus_hart.v "$OUT/"
cd "$OUT" && sby -f usb_ind.sby d4 2>&1 | grep -E "Assert failed|ERROR|summary: engine|DONE|successful" | cut -c1-120 | tail -8
