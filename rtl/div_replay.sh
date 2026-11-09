#!/usr/bin/env bash
# Replay every recorded hart with the prescaler set: with prescaler D, each
# model tick must last D+1 clocks and the hart must otherwise match the model
# exactly. Usage: bash div_replay.sh [D ...] (default 1 2 3 7). WSL, from rtl/.
set -uo pipefail
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/div"
mkdir -p "$OUT"
rm -rf "$OUT/vec"
(cd .. && python3 rtl/gen_vectors.py "$OUT/vec") > "$OUT/index.txt" || exit 1
iverilog -g2012 -Wall -o "$OUT/tb.vvp" tb_replay.v janus_hart.v 2> "$OUT/iverilog.log" \
    || { tail -20 "$OUT/iverilog.log"; exit 1; }
divs="${*:-1 2 3 7}"
for d in $divs; do
    pass=0; fail=0
    for meta in "$OUT"/vec/*.meta; do
        base="${meta%.meta}"
        result=$(vvp "$OUT/tb.vvp" "+base=$base" "+div=$d" | grep -E "^(OK|MISMATCH)" | head -1)
        case "$result" in
            OK*) pass=$((pass + 1)) ;;
            *) fail=$((fail + 1))
               id=$(basename "$base")
               [ "$fail" -le 4 ] && echo "  div $d: $(grep "^$id " "$OUT/index.txt" | cut -c1-60): $result" ;;
        esac
    done
    echo "div $d: $pass passed, $fail failed"
done
# The replay sets the prescaler directly; this checks a program can set it.
iverilog -g2012 -o "$OUT/mode.vvp" tb_div_mode.v janus_hart.v && vvp "$OUT/mode.vvp" | grep -E "^(OK|MISMATCH)"
