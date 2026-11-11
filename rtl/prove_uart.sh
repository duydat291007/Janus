#!/usr/bin/env bash
# Prove the UART program. Usage: bash prove_uart.sh. WSL, from rtl/.
# sim_uart.sh simulates the same harness, and mutate_uart.sh plants bugs in it.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/uart"
mkdir -p "$OUT"
(cd .. && python3 rtl/gen_uart_rom.py "$OUT/uart_rom.vh") || exit 1
cp uart_ind.sby uart_ind.sv janus_hart.v "$OUT/"
cd "$OUT" && sby -f uart_ind.sby b8 2>&1 | grep -E "Assert failed|ERROR|summary: engine|DONE|successful" | cut -c1-120 | tail -8
