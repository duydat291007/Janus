#!/usr/bin/env bash
# Prove the CAN program. Usage: bash prove_can.sh. WSL, from rtl/.
# sim_can.sh simulates the same harness, and mutate_can.sh plants bugs in it.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/can"
mkdir -p "$OUT"
(cd .. && python3 rtl/gen_can_rom.py "$OUT/can_rom.vh") || exit 1
cp can_ind.sby can_ind.sv janus_hart.v "$OUT/"
cd "$OUT" && sby -f can_ind.sby h8 2>&1 | grep -E "Assert failed|ERROR|summary: engine|DONE|successful" | cut -c1-120 | tail -8
