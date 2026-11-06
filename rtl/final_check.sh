#!/usr/bin/env bash
# All planted-bug sets and proof tasks on the current design. WSL, from rtl/.
OUT="$HOME/janus-tools/build"
bash mutate_chip.sh > "$OUT/f_chip.txt" 2>&1 &
bash mutate_rtl.sh > "$OUT/f_rtl.txt" 2>&1 &
bash mutate_proof.sh > "$OUT/f_proof.txt" 2>&1 &
wait
echo "--- chip bugs"; echo "caught $(grep -c CAUGHT "$OUT/f_chip.txt")"; grep -vE "^CAUGHT" "$OUT/f_chip.txt" | cut -c1-80
echo "--- hart bugs"; head -1 "$OUT/f_rtl.txt"; echo "caught $(grep -c CAUGHT "$OUT/f_rtl.txt")"; grep -vE "^CAUGHT|^baseline" "$OUT/f_rtl.txt" | cut -c1-80
echo "--- proof bugs"; echo "broke $(grep -c BROKE "$OUT/f_proof.txt")"; grep -vE "^BROKE" "$OUT/f_proof.txt" | cut -c1-80
for t in d4 d3 stuffcover cover; do
    echo "--- $t"; timeout 300 bash prove_ind.sh $t 2>&1 | grep -E "DONE" | sed 's/.*\] *//' | cut -c1-40
done
L="$HOME/janus-tools/build/ind"
echo "free cover reached: $(grep -cE "Reached cover" $L/lockstep_ind_cover/engine_0/logfile.txt)"
echo "stuff cover reached: $(grep -cE "Reached cover" $L/lockstep_ind_stuffcover/engine_0/logfile.txt)"
