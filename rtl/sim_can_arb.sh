#!/usr/bin/env bash
# Two CAN harts that may both have a frame to send (tb_can_arb.v): every skew
# between their queuings from 6 ticks either way, then random skews with some
# rounds where only one sends, at bit times from 12 ticks. At 11 ticks two
# starts of frame 4 ticks apart give a violation; see KILL_TEST.md.
# WSL, from rtl/.
set -uo pipefail
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="${CAN_ARB_OUT:-$HOME/janus-tools/build/can_arb}"
mkdir -p "$OUT"
(cd .. && python3 rtl/gen_can_rom.py "$OUT/can_rom.vh") > /dev/null || exit 1
iverilog -g2012 -I "$OUT" -s tb_can_arb -o "$OUT/arb.vvp" tb_can_arb.v janus_hart.v 2> "$OUT/iv.log" \
    || { tail -20 "$OUT/iv.log"; exit 1; }
runs=0; bad=0; rounds=0; contested=0; after=0; seed=0
# one BIT [plusargs]: one run, added to the totals.
one() {
    local bit=$1 out
    shift
    seed=$((seed + 1))
    out=$(vvp "$OUT/arb.vvp" +bit=$bit +seed=$seed "$@" | grep -E "^(OK|BAD|STUCK|VIOLATION|COUNT|FIELD|SEQ|ARB)")
    runs=$((runs + 1))
    if [ "$(echo "$out" | grep -c "^OK")" = 1 ] && [ "$(echo "$out" | grep -vc "^OK")" = 0 ]; then
        set -- $out
        rounds=$((rounds + $5)); contested=$((contested + $7)); after=$((after + $9))
    else
        bad=$((bad + 1))
        [ "$bad" -le 4 ] && echo "FAIL bit $bit seed $seed $*: $(echo "$out" | head -3 | tr '\n' ';' | cut -c1-150)"
    fi
}
for bit in 12 13 16 25 50 217; do
    for sk in -6 -5 -4 -3 -2 -1 0 1 2 3 4 5 6; do one $bit +skew=$sk +rounds=12; done
    one $bit +rounds=60
done
echo "can arb sim: $runs runs, $bad failed, $rounds rounds ($contested arbitrated, $after sent one after the other)"
[ "$bad" -eq 0 ] && [ "$contested" -gt 0 ] || exit 1
