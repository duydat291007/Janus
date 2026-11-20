#!/usr/bin/env bash
# Simulate the CAN proof harness on random inputs: the same assertions as the
# proof, over long runs at many bit times, with a separate scoreboard.
# WSL, from rtl/. With arguments it runs once and prints a trace:
#   bash sim_can.sh BIT TICKS [SEED]
set -uo pipefail
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="${CAN_SIM_OUT:-$HOME/janus-tools/build/can_sim}"
mkdir -p "$OUT"
[ -f "$OUT/can_rom.vh" ] && [ -n "${CAN_SIM_KEEP_ROM:-}" ] \
    || (cd .. && python3 rtl/gen_can_rom.py "$OUT/can_rom.vh") > /dev/null || exit 1
iverilog -g2012 -DFORMAL -DCAN_SIM -I "$OUT" -s tb_can_ind -o "$OUT/sim.vvp" \
    tb_can_ind.v can_ind.sv "${CAN_SIM_HART:-janus_hart.v}" 2> "$OUT/iv.log" \
    || { tail -20 "$OUT/iv.log"; exit 1; }
if [ "$#" -ge 2 ]; then
    vvp "$OUT/sim.vvp" +bit=$1 +trace=$2 +ticks=$2 +seed=${3:-1} | cut -c1-170
    exit 0
fi
runs=0; bad=0; frames=0; short=0; fields=0; ticks=0; seed=0
# one BIT [plusargs]: one run, added to the totals.
one() {
    local bit=$1 out
    shift
    seed=$((seed + 1))
    out=$(vvp "$OUT/sim.vvp" +bit=$bit +seed=$seed "$@" | grep -E "^(OK|MISMATCH|ERROR)")
    runs=$((runs + 1))
    if [ "$(echo "$out" | grep -c "^OK")" = 1 ] && [ "$(echo "$out" | grep -cE "^(MISMATCH|ERROR)")" = 0 ]; then
        set -- $out
        frames=$((frames + $7)); short=$((short + $9)); fields=$((fields + ${11})); ticks=$((ticks + ${13}))
    else
        bad=$((bad + 1))
        [ "$bad" -le 4 ] && echo "FAIL bit $bit seed $seed: $(echo "$out" | head -3 | tr '\n' ';' | cut -c1-170)"
    fi
}
for bit in 11 11 12 13 14 15 16 17 25 50 100 217 1000 2047 2047; do
    for rep in 1 2; do one $bit +frames=25 +ticks=3000000; done
done
# Each frame queued the given number of ticks before the hold trap would
# fire, where the trap once cut off a start of frame.
for bit in 11 16 49; do
    for k in 1 2 3 4 5 6 7 8; do one $bit +race=$k +frames=6 +ticks=400000; done
done
echo "can sim: $runs runs, $bad failed, $frames frames ($short with fewer bytes than their length), $fields fields received, $ticks ticks"
[ "$bad" -eq 0 ] && [ "$frames" -gt 0 ] || exit 1
