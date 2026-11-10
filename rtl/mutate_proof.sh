#!/usr/bin/env bash
# Can the induction proof fail? Plant bugs in the Verilog and require each one
# to break it. Run in WSL from rtl/.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/ind_mut"
rm -rf "$OUT"; mkdir -p "$OUT"
cp lockstep_ind.sby lockstep_ind.sv "$OUT/"

mutant() {
    name="$1"; expr="$2"
    sed -e "$expr" janus_hart.v > "$OUT/janus_hart.v"
    if cmp -s janus_hart.v "$OUT/janus_hart.v"; then echo "NOT APPLIED $name"; return; fi
    result=$(cd "$OUT" && sby -f lockstep_ind.sby d4 2>&1 | grep -E "DONE" | sed 's/.*DONE (\([A-Z]*\).*/\1/')
    fail=$(cd "$OUT" && grep -hoE "Assert failed in lockstep_ind: lockstep_ind.sv:[0-9]+" lockstep_ind_d4/engine_0/logfile_*.txt 2>/dev/null | head -1 | sed 's/.*sv://')
    if [ "$result" = "PASS" ]; then echo "SURVIVED    $name"
    else echo "BROKE PROOF ($result line ${fail:-?}) $name"; fi
}

mutant "listener releases at no point" 's/if (!cur_mine) put_release(i_pin);/;/'
mutant "owner drives inverted bit" 's/put(i_pin, lvl, i_brk);/put(i_pin, !lvl, i_brk);/'
mutant "one role branches wrongly" 's/1: taken = !last;/1: taken = role == 0 ? !last : last;/'
mutant "sample too early" 's/if (is_before(now, edge_t + (i_dwell >> 1))) begin/if (is_before(now, edge_t + (i_dwell >> 3))) begin/'
mutant "owner skips readback" 's/if (!src_const) shift_in(1'"'"'b0, seen);/if (!src_const \&\& !cur_mine) shift_in(1'"'"'b0, seen);/'
mutant "listener timing drifts" 's/edge_t = edge_t + i_dwell;/edge_t = edge_t + i_dwell + (role == 1);/'
mutant "no long-idle fix" 's/if (s != S_MID \&\& is_before(edge_t, now)) edge_t = now;//'
mutant "one role loads a different count" 's/else count = ins\[7:0\];/else count = ins[7:0] + (role == 1);/'
mutant "listener samples the wrong pin" 's/raw = pin\[i_pin\];/raw = role == 1 ? pin[1] : pin[i_pin];/'
mutant "one role uses a different CRC" 's/if (fb) crc = crc ^ c_poly;/if (fb) crc = crc ^ (role == 1 ? c_poly ^ 16'"'"'d1 : c_poly);/'
mutant "stuff bit wrong polarity" 's/stuff_bit = !seen;/stuff_bit = seen;/'
mutant "one role counts runs differently" 's/run_len = (run_valid \&\& seen == run_val) ? run_len + 1'"'"'b1 : 4'"'"'d1;/run_len = (run_valid \&\& seen == run_val) ? run_len + 1'"'"'b1 + (role == 1) : 4'"'"'d1;/'
mutant "stuff error check inverted" 's/if (seen == saved) begin/if (seen != saved) begin/'
mutant "sync input lag wrong" 's/edge_t = now - 12'"'"'d2;/edge_t = now - 12'"'"'d1;/'
mutant "sync leaves before mid-bit" 's/^ *edge_t = now - 12'"'"'d2;$/edge_t = now - 12'"'"'d2; seen = val; edge_t = edge_t + i_dwell;/; s/^ *s = S_MID;$/s = (i_sync \&\& !cur_mine) ? S_POST : S_MID;/'
mutant "sync only checks the level (expected to survive)" 's/ \&\& armed\[i_pin\] != val//'

# The rule itself: with it removed, the proof must fail.
cp janus_hart.v "$OUT/janus_hart.v"
sed 's/if (exec_sync) assume (sync_line_ok);//' lockstep_ind.sv > "$OUT/lockstep_ind.sv"
result=$(cd "$OUT" && sby -f lockstep_ind.sby d4 2>&1 | grep -E "DONE" | sed 's/.*DONE (\([A-Z]*\).*/\1/')
fail=$(cd "$OUT" && grep -hoE "Assert failed in lockstep_ind: lockstep_ind.sv:[0-9]+" lockstep_ind_d4/engine_0/logfile_*.txt | head -1 | sed 's/.*sv://')
[ "$result" = "PASS" ] && echo "SURVIVED    sync rule removed" || echo "BROKE PROOF ($result line ${fail:-?}) sync rule removed"
