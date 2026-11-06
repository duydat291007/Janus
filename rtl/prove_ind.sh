#!/usr/bin/env bash
# Run an induction task. Usage: bash prove_ind.sh d8|d6|d5|d4|cover. WSL, from rtl/.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/ind"
mkdir -p "$OUT"
cp lockstep_ind.sby lockstep_ind.sv janus_hart.v "$OUT/"
cd "$OUT" && sby -f lockstep_ind.sby "$1" 2>&1 | grep -E "Assert failed|Reached cover|Unreached|ERROR|summary: engine|DONE|Trying induction|successful" | cut -c1-120 | tail -12
