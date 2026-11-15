#!/usr/bin/env bash
# Prove the SPI program. Usage: bash prove_spi.sh. WSL, from rtl/.
# sim_spi.sh simulates the same harness, and mutate_spi.sh plants bugs in it.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/spi"
mkdir -p "$OUT"
(cd .. && python3 rtl/gen_spi_rom.py "$OUT/spi_rom.vh") || exit 1
cp spi_ind.sby spi_ind.sv janus_hart.v "$OUT/"
cd "$OUT" && sby -f spi_ind.sby h8 2>&1 | grep -E "Assert failed|ERROR|summary: engine|DONE|successful" | cut -c1-120 | tail -8
