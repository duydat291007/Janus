#!/usr/bin/env bash
# Simulate the 1-Wire proof harness on random inputs. WSL, from rtl/.
# With arguments it prints a trace: bash sim_onewire.sh TICKS [SEED]
set -uo pipefail
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="${OW_SIM_OUT:-$HOME/janus-tools/build/onewire_sim}"
mkdir -p "$OUT"
(cd .. && python3 rtl/gen_onewire_rom.py "$OUT/onewire_rom.vh") > /dev/null || exit 1
iverilog -g2012 -DFORMAL -DOW_SIM -I "$OUT" -s tb_onewire_ind -o "$OUT/sim.vvp" \
    tb_onewire_ind.v onewire_ind.sv "${OW_SIM_HART:-janus_hart.v}" 2> "$OUT/iv.log" \
    || { tail -20 "$OUT/iv.log"; exit 1; }
if [ "$#" -ge 1 ]; then
    vvp "$OUT/sim.vvp" +trace=$1 +ticks=$1 +seed=${2:-1} | cut -c1-150
    exit 0
fi
runs=0; bad=0; written=0; read=0; resets=0; ticks=0
for seed in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    out=$(vvp "$OUT/sim.vvp" +seed=$seed +bytes=40 +ticks=900000 | grep -E "^(OK|MISMATCH|ERROR)")
    runs=$((runs + 1))
    if [ "$(echo "$out" | grep -c "^OK")" = 1 ] && [ "$(echo "$out" | grep -cE "^(MISMATCH|ERROR)")" = 0 ]; then
        set -- $out
        resets=$((resets + $5)); written=$((written + $7)); read=$((read + $9)); ticks=$((ticks + ${11}))
    else
        bad=$((bad + 1))
        [ "$bad" -le 4 ] && echo "FAIL seed $seed: $(echo "$out" | head -3 | tr '\n' ';' | cut -c1-150)"
    fi
done
echo "onewire sim: $runs runs, $bad failed, $resets resets, $written bytes written, $read bytes read, $ticks ticks"
[ "$bad" -eq 0 ] && [ "$written" -gt 0 ] || exit 1
