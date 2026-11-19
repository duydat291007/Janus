#!/usr/bin/env bash
# Simulate the I2C proof harness on random inputs: the same assertions as the
# proof, over long runs at many half periods, with a separate scoreboard.
# WSL, from rtl/. With arguments it runs once and prints a trace:
#   bash sim_i2c.sh HALF TICKS [SEED]
set -uo pipefail
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="${I2C_SIM_OUT:-$HOME/janus-tools/build/i2c_sim}"
mkdir -p "$OUT"
[ -f "$OUT/i2c_rom.vh" ] && [ -n "${I2C_SIM_KEEP_ROM:-}" ] \
    || (cd .. && python3 rtl/gen_i2c_rom.py "$OUT/i2c_rom.vh") > /dev/null || exit 1
iverilog -g2012 -DFORMAL -DI2C_SIM -I "$OUT" -s tb_i2c_ind -o "$OUT/sim.vvp" \
    tb_i2c_ind.v i2c_ind.sv "${I2C_SIM_HART:-janus_hart.v}" 2> "$OUT/iv.log" \
    || { tail -20 "$OUT/iv.log"; exit 1; }
if [ "$#" -ge 2 ]; then
    vvp "$OUT/sim.vvp" +half=$1 +trace=$2 +ticks=$2 +seed=${3:-1} | cut -c1-170
    exit 0
fi
runs=0; bad=0; bytes=0; txns=0; writes=0; reads=0; nacks=0; restarts=0; ticks=0; seed=0
for half in 8 8 9 10 11 13 16 25 50 100 217 1000 2047; do
    for rep in 1 2; do
        seed=$((seed + 1))
        out=$(vvp "$OUT/sim.vvp" +half=$half +seed=$seed +bytes=80 +ticks=2000000 \
              | grep -E "^(OK|MISMATCH|ERROR)")
        runs=$((runs + 1))
        if [ "$(echo "$out" | grep -c "^OK")" = 1 ] && [ "$(echo "$out" | grep -cE "^(MISMATCH|ERROR)")" = 0 ]; then
            set -- $out
            bytes=$((bytes + $7)); txns=$((txns + $9)); writes=$((writes + ${11}))
            reads=$((reads + ${13})); nacks=$((nacks + ${15})); restarts=$((restarts + ${17}))
            ticks=$((ticks + ${21}))
        else
            bad=$((bad + 1))
            [ "$bad" -le 4 ] && echo "FAIL half $half seed $seed: $(echo "$out" | head -3 | tr '\n' ';' | cut -c1-170)"
        fi
    done
done
echo "i2c sim: $runs runs, $bad failed, $bytes bytes in $txns transactions ($writes writes, $reads reads acknowledged), $nacks NACKs, $restarts restarts, $ticks ticks"
[ "$bad" -eq 0 ] && [ "$bytes" -gt 0 ] || exit 1
