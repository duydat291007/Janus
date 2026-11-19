#!/usr/bin/env bash
# Prove the I2C program. Usage: bash prove_i2c.sh. WSL, from rtl/.
# sim_i2c.sh simulates the same harness, and mutate_i2c.sh plants bugs in it.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/i2c"
mkdir -p "$OUT"
(cd .. && python3 rtl/gen_i2c_rom.py "$OUT/i2c_rom.vh") || exit 1
cp i2c_ind.sby i2c_ind.sv janus_hart.v "$OUT/"
cd "$OUT" && sby -f i2c_ind.sby h8 2>&1 | grep -E "Assert failed|ERROR|summary: engine|DONE|successful" | cut -c1-120 | tail -8
