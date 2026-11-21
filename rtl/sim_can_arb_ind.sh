#!/usr/bin/env bash
# Simulate the stage B CAN proof harness (can_arb_ind.sv) on random inputs: the
# same claims and assumptions as the proof, checked once a tick, with the
# testbench's own scoreboard. Rounds at every skew from 6 ticks either way,
# then busy runs where both queues refill as soon as they empty.
# WSL, from rtl/. With arguments it runs once: bash sim_can_arb_ind.sh BIT SKEW [SEED]
set -uo pipefail
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="${CAN_ARB_IND_OUT:-$HOME/janus-tools/build/arb_ind}"
mkdir -p "$OUT"
(cd .. && python3 rtl/gen_can_rom.py "$OUT/can_rom.vh") > /dev/null || exit 1
iverilog -g2012 -DFORMAL -DCAN_SIM -I "$OUT" -s tb_can_arb_ind -o "$OUT/sim.vvp" \
    tb_can_arb_ind.v can_arb_ind.sv janus_hart.v 2> "$OUT/iv.log" || { tail -20 "$OUT/iv.log"; exit 1; }
if [ "$#" -ge 2 ]; then
    vvp "$OUT/sim.vvp" +bit=$1 +skew=$2 +seed=${3:-1} +rounds=6 | cut -c1-170
    exit 0
fi
runs=0; bad=0; seed=0
# one BIT [plusargs]: one run; it fails on any failed claim or scoreboard line.
one() {
    local bit=$1 out
    shift
    seed=$((seed + 1))
    out=$(vvp "$OUT/sim.vvp" +bit=$bit +seed=$seed "$@" 2>&1)
    runs=$((runs + 1))
    if ! echo "$out" | grep -q "^OK" || echo "$out" | grep -qE "^(ERROR|BAD|STUCK|COUNT|FIELD|SEQ|ARB)"; then
        bad=$((bad + 1))
        [ "$bad" -le 4 ] && echo "FAIL bit $bit seed $seed $*: $(echo "$out" | grep -E "^(ERROR|BAD|STUCK|COUNT|FIELD|SEQ|ARB)" | head -3 | tr '\n' ';' | cut -c1-150)"
    fi
}
for bit in 12 13 16 25 50; do
    for sk in -6 -5 -4 -3 -2 -1 0 1 2 3 4 5 6; do one $bit +skew=$sk +rounds=6; done
done
for bit in 12 16 25 50 217; do
    for rep in 1 2; do one $bit +busy +ticks=400000; done
done
echo "can arb harness sim: $runs runs, $bad failed"
[ "$bad" -eq 0 ] || exit 1
