#!/usr/bin/env bash
# Prove the CAN program with both queues free (stage B). Usage: bash prove_can_arb.sh. WSL, from rtl/.
# sim_can_arb_ind.sh simulates the same harness.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/can_arb_ind_prove"
mkdir -p "$OUT"
(cd .. && python3 rtl/gen_can_rom.py "$OUT/can_rom.vh") || exit 1
cp can_arb_ind.sby can_arb_ind.sv janus_hart.v "$OUT/"
cd "$OUT" && sby -f can_arb_ind.sby h8 2>&1 | grep -E "Assert failed|ERROR|summary: engine|DONE|successful" | cut -c1-120 | tail -8
