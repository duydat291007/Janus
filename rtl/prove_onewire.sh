#!/usr/bin/env bash
# Prove the 1-Wire program. Usage: bash prove_onewire.sh. WSL, from rtl/.
# sim_onewire.sh simulates the same harness, and mutate_onewire.sh plants bugs in it.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/onewire"
mkdir -p "$OUT"
(cd .. && python3 rtl/gen_onewire_rom.py "$OUT/onewire_rom.vh") || exit 1
cp onewire_ind.sby onewire_ind.sv janus_hart.v "$OUT/"
cd "$OUT" && sby -f onewire_ind.sby h8 2>&1 | grep -E "Assert failed|ERROR|summary: engine|DONE|successful" | cut -c1-120 | tail -8
