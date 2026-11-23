#!/usr/bin/env bash
# Can the CAN arbitration proof fail? Plant bugs in the program, the hart and
# the proof's own monitor and assumptions, and require each one to break it.
# Run in WSL from rtl/. In the sed expressions a dot stands for a quote in a
# pattern, and \x27 puts one in a replacement. 9F800000 is a mode word that
# writes nothing.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/can_arb_mut"
rm -rf "$OUT"; mkdir -p "$OUT"
(cd .. && python3 rtl/gen_can_rom.py "$OUT/rom.vh") > /dev/null || exit 1

# mutant <name> <file to change: rom, hart or proof> <sed expression>
# Each runs in its own folder, eight at a time; the results print in order.
N=0
mutant() {
    N=$((N + 1))
    while [ "$(jobs -rp | wc -l)" -ge 8 ]; do wait -n; done
    one "$N" "$@" > "$OUT/r$N.txt" &
}
# Each bug is first simulated: the proof's harness with the bug in it, on
# random inputs that keep the proof's assumptions, as sim_can_arb_ind.sh runs
# it: rounds at several start skews and back-to-back contests. An assertion
# that fails on a real run means the claim is false, so the proof cannot
# pass. A failed assumption does not count, nor does the one fact the
# simulation can break by breaking an assumption (RTR and IDE clear in the
# control bytes the harts took). Bugs the simulation does not catch go to the
# solver; those that only weaken an assumption always do, since the
# simulation never breaks one.
SIMS="12:1:+skew=0 12:2:+skew=-3 16:3:+skew=2 16:4:+busy 25:5:+skew=4 25:6:+busy 50:7:+skew=-1 217:8:+busy 12:9:+skew=6 16:10:+skew=-6"
one() {
    D="$OUT/m$1"; name="$2"; target="$3"; expr="$4"
    mkdir -p "$D"; cp "$OUT/rom.vh" "$D/can_rom.vh"; cp janus_hart.v can_arb_ind.sv can_arb_ind.sby "$D/"
    case "$target" in
        rom)   file="$D/can_rom.vh"; orig="$OUT/rom.vh" ;;
        hart)  file="$D/janus_hart.v"; orig=janus_hart.v ;;
        proof) file="$D/can_arb_ind.sv"; orig=can_arb_ind.sv ;;
    esac
    sed -i -e "$expr" "$file"
    if cmp -s "$orig" "$file"; then echo "NOT APPLIED $name"; return; fi
    if ! iverilog -g2012 -DFORMAL -DCAN_SIM -I "$D" -s tb_can_arb_ind -o "$D/sim.vvp" \
            tb_can_arb_ind.v "$D/can_arb_ind.sv" "$D/janus_hart.v" 2> "$D/iv.log"; then
        echo "NO COMPILE  $name"; rm -rf "$D"; return
    fi
    skip=$(grep -nE "assume \(|assert \(f3a\[7:6\] == 2.b00" "$D/can_arb_ind.sv" | cut -d: -f1 | paste -sd'|')
    for bs in $SIMS; do
        bit=${bs%%:*}; rest=${bs#*:}; seed=${rest%%:*}; extra=${rest#*:}
        case "$extra" in +busy) extra="+busy +ticks=200000" ;; *) extra="$extra +rounds=5" ;; esac
        line=$(vvp "$D/sim.vvp" +bit=$bit +seed=$seed $extra 2>&1 \
               | grep -oE "^ERROR: [^ ]*can_arb_ind.sv:[0-9]+" | sed 's/.*sv://' | grep -vxE "$skip" | head -1)
        if [ -n "$line" ]; then echo "BROKE PROOF (simulation, bit $bit $extra, line $line) $name"; rm -rf "$D"; return; fi
    done
    (cd "$D" && timeout -k 30 10800 sby -f can_arb_ind.sby h8 > sby.txt 2>&1); code=$?
    for p in $(pgrep bitwuzla); do
        case "$(readlink /proc/$p/cwd)" in "$D"*) kill "$p" ;; esac
    done
    result=$(grep -E "DONE" "$D/sby.txt" | sed 's/.*DONE (\([A-Z]*\).*/\1/')
    fail=$(grep -hoE "Assert failed in [a-zA-Z_.]+: can_arb_ind.sv:[0-9]+" "$D"/can_arb_ind_h8/engine_0/logfile_*.txt 2>/dev/null | head -1 | sed 's/.*sv://')
    if [ "$code" = 124 ]; then echo "TIMEOUT     $name"
    elif [ "$result" = "ERROR" ] || [ -z "$result" ]; then echo "NO COMPILE  $name"
    elif [ "$result" = "PASS" ]; then echo "SURVIVED    $name"
    else echo "BROKE PROOF ($result line ${fail:-?}) $name"; fi
    rm -rf "$D"
}

# The program
mutant "arbitration never switched on" rom '/6.d7:/ s/32.h93000001/32\x27h93000002/'
mutant "the loser becomes a witness, not the receiver" rom '/6.d7:/ s/32.h93000001/32\x27h93000003/'
# After the identifier the winner reads back every bit it sends, so it never
# loses; but the proof pins each hart's settings to the program's.
mutant "arbitration left on after the identifier" rom '/6.d18:/ s/32.h93000002/32\x27h9F800000/'
mutant "no bit stuffing" rom '/6.d6:/ s/32.h91000005/32\x27h9F800000/'
mutant "the receiver acknowledges with a 1" rom '/6.d29:/ s/32.h10C00000/32\x27h10E00000/'

# The hart
mutant "a sender that reads dominant over its recessive bit carries on" hart 's/^\( *\)lose(i_pin, 1.b0, 2.d0);/\1;/'
mutant "a sender loses when it reads recessive over its dominant bit" hart 's/if (c_lose != LOSE_NONE \&\& val \&\& !seen \&\& !faulty)/if (c_lose != LOSE_NONE \&\& !val \&\& seen \&\& !faulty)/'
mutant "a loser keeps sending" hart 's/^ *role = c_lose;$/            ;/'
mutant "a loser keeps its queue" hart 's/^ *tx_clear_r = 1.b1;$/            tx_clear_r = 1\x27b0;/'
mutant "no resynchronisation" hart 's/if (none \&\& lf_valid \&\& diff <= {3.b0, i_dwell\[10:2\]}) edge_t = last_fall;/;/'
mutant "claim ignores a falling line" hart 's/if ((base_role == i_owner \&\& tx_valid) || !pin\[i_pin\]) begin/if (base_role == i_owner \&\& tx_valid) begin/'
mutant "a claim with a frame queued is a sender even after a fall" hart 's/role = (tx_valid \&\& pin\[i_pin\]) ? i_owner : ins\[21:20\];/role = tx_valid ? i_owner : ins[21:20];/'

# The monitor: a wrong idea of arbitration must not fit the wire.
mutant "monitor's winner is the larger identifier" proof 's/f1b\[7:5\] < f1a\[7:5\] || (f1b\[7:5\] == f1a\[7:5\] \&\& f2b < f2a)/f1b[7:5] > f1a[7:5] || (f1b[7:5] == f1a[7:5] \&\& f2b > f2a)/'
mutant "monitor's winner sends at the earlier sender's edge" proof 's/wire        late_w = con \&\& (w_b != early_b);/wire        late_w = 1\x27b0;/'

# The proof's own assumptions: without each, it must fail.
mutant "contending frames may share an identifier" proof 's/assume (valid_a \&\& data_a != f2b);/assume (valid_a);/; s/assume (valid_b \&\& data_b != f2a);/assume (valid_b);/; s/assume (valid_a \&\& valid_b \&\& data_a != data_b);/assume (valid_a \&\& valid_b);/'
mutant "bit times of 11 ticks allowed" proof 's/assume (BIT >= MINBIT);/assume (BIT >= 11\x27d11);/'
mutant "another device may pull BUS low" proof 's/wire        low = (oe_a\[0\] \&\& !ov_a\[0\]) || (oe_b\[0\] \&\& !ov_b\[0\]);/wire        low = (oe_a[0] \&\& !ov_a[0]) || (oe_b[0] \&\& !ov_b[0]) || !other[0];/'

wait
for i in $(seq 1 "$N"); do cat "$OUT/r$i.txt"; done
