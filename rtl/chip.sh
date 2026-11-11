#!/usr/bin/env bash
# Chip-level tests and synthesis. Usage: bash chip.sh test|synth. WSL, from rtl/.
set -uo pipefail
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/chip"
LIB="$HOME/janus-tools/sg13g2_stdcell_typ_1p20V_25C.lib"
mkdir -p "$OUT"

if [ "${1:-test}" = "test" ]; then
    rm -rf "$OUT/scripts"
    (cd .. && python3 rtl/gen_chip.py "$OUT/scripts") > "$OUT/index.txt" || exit 1
    iverilog -g2012 -o "$OUT/tb.vvp" tb_chip.v janus_chip.v janus_hart.v 2> "$OUT/iv.log" \
        || { tail -20 "$OUT/iv.log"; exit 1; }
    pass=0; fail=0; checks=0
    for script in "$OUT"/scripts/*.hex; do
        result=$(vvp "$OUT/tb.vvp" "+script=$script" | grep -E "^(OK|MISMATCH)")
        name=$(basename "$script" .hex)
        if echo "$result" | grep -q "^MISMATCH" || [ -z "$result" ]; then
            fail=$((fail + 1))
            [ "$fail" -le 8 ] && echo "FAIL $name: $(echo "$result" | head -2 | cut -c1-110 | sed 's#.*/scripts/##' | tr '\n' ';')"
        else
            pass=$((pass + 1))
            checks=$((checks + $(echo "$result" | awk '{print $2}')))
        fi
    done
    echo "chip: $pass passed, $fail failed, $checks byte checks"
    # The queue on its own: a push and a pop on the same tick of a full queue.
    iverilog -g2012 -s tb_fifo -o "$OUT/fifo.vvp" tb_fifo.v janus_chip.v janus_hart.v 2>> "$OUT/iv.log" \
        || { tail -20 "$OUT/iv.log"; exit 1; }
    queue=$(vvp "$OUT/fifo.vvp" | grep -E "^(OK|MISMATCH)" | cut -c1-90)
    echo "queue: $queue"
    [ "$fail" -eq 0 ] && [ "$pass" -gt 0 ] && [ "${queue:0:2}" = OK ] || exit 1
fi

if [ "${1:-test}" = "synth" ]; then
    PERIOD_PS="${2:-20000}"
    yosys -q -l "$OUT/synth.log" -p "
        read_liberty -lib $LIB
        read_verilog -sv janus_chip.v janus_hart.v
        synth -top tt_um_duydat291007_janus -flatten -nofsm
        opt -full; share; opt
        techmap -map latch_map.v
        dfflibmap -liberty $LIB
        abc -liberty $LIB -D $PERIOD_PS -showtmp -script +strash;dch;map,-B,0.9;topo;stime,-p;buffer,-p;upsize;dnsize;stime,-p
        opt_clean
        stat -liberty $LIB" > /dev/null 2>&1
    grep -E "Chip area| cells$" "$OUT/synth.log" | tail -2
    grep -E "sg13g2_(dfrbpq_1|dlhq_1)$" "$OUT/synth.log" | tail -2 | cut -c1-70
    grep -E "Delay =" "$OUT/synth.log" | tail -1 | sed 's/.*Delay = *//' | cut -c1-30
fi
