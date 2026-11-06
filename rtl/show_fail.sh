#!/usr/bin/env bash
# Summarize an induction task. Usage: bash show_fail.sh d4. Run in WSL from rtl/.
L="$HOME/janus-tools/build/ind/lockstep_ind_$1/engine_0"
for f in basecase induction; do
    echo "$f: $(grep -hE "Assert failed|Temporal induction successful|Status" "$L/logfile_$f.txt" 2>/dev/null | sed 's/^## *[0-9:]* *//' | cut -c1-70 | head -2 | tr '\n' ';')"
done
for n in $(grep -hoE "lockstep_ind.sv:[0-9]+" "$L"/logfile_*.txt 2>/dev/null | cut -d: -f2 | sort -un | head -4); do sed -n "${n}p" lockstep_ind.sv | cut -c1-80; done
exit 0
