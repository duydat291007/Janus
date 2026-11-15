#!/usr/bin/env bash
# Simulate the SPI proof harness on random inputs: the same assertions as the
# proof, over long runs in all four modes at many half periods. WSL, from rtl/.
# With arguments it runs once and prints a trace: bash sim_spi.sh HALF CPOL CPHA TICKS
set -uo pipefail
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="${SPI_SIM_OUT:-$HOME/janus-tools/build/spi_sim}"
mkdir -p "$OUT"
[ -f "$OUT/spi_rom.vh" ] && [ -n "${SPI_SIM_KEEP_ROM:-}" ] \
    || (cd .. && python3 rtl/gen_spi_rom.py "$OUT/spi_rom.vh") > /dev/null || exit 1
iverilog -g2012 -DFORMAL -DSPI_SIM -I "$OUT" -s tb_spi_ind -o "$OUT/sim.vvp" \
    tb_spi_ind.v spi_ind.sv "${SPI_SIM_HART:-janus_hart.v}" 2> "$OUT/iv.log" \
    || { tail -20 "$OUT/iv.log"; exit 1; }
if [ "$#" -ge 4 ]; then
    vvp "$OUT/sim.vvp" +half=$1 +cpol=$2 +cpha=$3 +trace=$4 +ticks=$4 +seed=${5:-1} | cut -c1-150
    exit 0
fi
runs=0; bad=0; bytes=0; frames=0; ff=0; dropped=0; ticks=0; seed=0
for half in 8 8 9 10 11 13 16 25 50 100 217 1000 2047; do
    for mode in 00 01 10 11; do
        seed=$((seed + 1))
        out=$(vvp "$OUT/sim.vvp" +half=$half +cpol=${mode:0:1} +cpha=${mode:1:1} +seed=$seed \
              +bytes=60 +ticks=900000 | grep -E "^(OK|MISMATCH|ERROR)")
        runs=$((runs + 1))
        if [ "$(echo "$out" | grep -c "^OK")" = 1 ] && [ "$(echo "$out" | grep -cE "^(MISMATCH|ERROR)")" = 0 ]; then
            set -- $out
            bytes=$((bytes + $9)); frames=$((frames + ${11})); ff=$((ff + ${13}))
            dropped=$((dropped + ${15})); ticks=$((ticks + ${17}))
        else
            bad=$((bad + 1))
            [ "$bad" -le 4 ] && echo "FAIL half $half mode $mode seed $seed: $(echo "$out" | head -3 | tr '\n' ';' | cut -c1-150)"
        fi
    done
done
echo "spi sim: $runs runs, $bad failed, $bytes bytes each way in $frames transfers, $ff sent as FF by an empty target, $dropped taken ahead and dropped, $ticks ticks"
[ "$bad" -eq 0 ] && [ "$bytes" -gt 0 ] || exit 1
