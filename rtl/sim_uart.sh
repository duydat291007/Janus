#!/usr/bin/env bash
# Simulate the UART proof harness on random inputs: the same assertions and
# wire monitor as the proof, over long runs at many bit times. WSL, from rtl/.
set -uo pipefail
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="${UART_SIM_OUT:-$HOME/janus-tools/build/uart_sim}"
mkdir -p "$OUT"
[ -f "$OUT/uart_rom.vh" ] && [ -n "${UART_SIM_KEEP_ROM:-}" ] \
    || (cd .. && python3 rtl/gen_uart_rom.py "$OUT/uart_rom.vh") > /dev/null || exit 1
iverilog -g2012 -DFORMAL -DUART_SIM -I "$OUT" -s tb_uart_ind -o "$OUT/sim.vvp" \
    tb_uart_ind.v uart_ind.sv "${UART_SIM_HART:-janus_hart.v}" 2> "$OUT/iv.log" \
    || { tail -20 "$OUT/iv.log"; exit 1; }
runs=0; bad=0; frames=0; ticks=0; low=0; b2b=0; seed=0
for bit in 8 8 8 9 9 10 11 12 13 15 16 17 25 50 64 100 217 500 1000 1023 1024 2046 2047 2047; do
    seed=$((seed + 1))
    out=$(vvp "$OUT/sim.vvp" +bit=$bit +seed=$seed +frames=80 +ticks=700000 | grep -E "^(OK|MISMATCH|ERROR)")
    runs=$((runs + 1))
    if [ "$(echo "$out" | grep -c "^OK")" = 1 ] && [ "$(echo "$out" | grep -cE "^(MISMATCH|ERROR)")" = 0 ]; then
        set -- $out
        low=$((low + $7)); frames=$((frames + $9)); b2b=$((b2b + ${11})); ticks=$((ticks + ${15}))
    else
        bad=$((bad + 1))
        [ "$bad" -le 4 ] && echo "FAIL bit $bit seed $seed: $(echo "$out" | head -3 | tr '\n' ';' | cut -c1-150)"
    fi
done
echo "uart sim: $runs runs, $bad failed, $frames frames ($b2b back to back), $low runs with the line low at start, $ticks ticks"
[ "$bad" -eq 0 ] && [ "$frames" -gt 0 ] || exit 1
