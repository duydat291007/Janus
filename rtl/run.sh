#!/usr/bin/env bash
# Replay all recorded harts on the RTL, then synthesize. Run in WSL from rtl/.
set -uo pipefail
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build"
mkdir -p "$OUT"

if [ "${1:-all}" != "synth" ]; then
    rm -rf "$OUT/vec"
    (cd .. && python3 rtl/gen_vectors.py "$OUT/vec") > "$OUT/index.txt" || exit 1
    iverilog -g2012 -Wall -o "$OUT/tb.vvp" tb_replay.v janus_hart.v 2> "$OUT/iverilog.log" \
        || { tail -20 "$OUT/iverilog.log"; exit 1; }
    pass=0; fail=0
    for meta in "$OUT"/vec/*.meta; do
        base="${meta%.meta}"
        result=$(vvp "$OUT/tb.vvp" "+base=$base" | grep -E "^(OK|MISMATCH)" | head -1)
        case "$result" in
            OK*) pass=$((pass + 1)) ;;
            *) fail=$((fail + 1))
               id=$(basename "$base")
               [ "$fail" -le 8 ] && echo "$(grep "^$id " "$OUT/index.txt"): $result" ;;
        esac
    done
    echo "replay: $pass passed, $fail failed"
fi

if [ "${1:-all}" != "replay" ]; then
    LIB="$HOME/janus-tools/sg13g2_stdcell_typ_1p20V_25C.lib"
    yosys -q -l "$OUT/synth.log" -p "
        read_verilog -sv janus_hart.v
        synth -top janus_hart -flatten -nofsm
        opt -full; share; opt
        dfflibmap -liberty $LIB
        abc -liberty $LIB
        opt_clean
        stat -liberty $LIB" > /dev/null
    grep -E "Number of cells|Chip area|sg13g2_df" "$OUT/synth.log" | tail -8
fi
