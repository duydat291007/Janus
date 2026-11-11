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
mutant "stuff bit wrong polarity" 's/stuff_bit = !coded;/stuff_bit = coded;/'
mutant "one role counts runs differently" 's/run_len = (run_valid \&\& coded == run_val) ? run_len + 1'"'"'b1 : 4'"'"'d1;/run_len = (run_valid \&\& coded == run_val) ? run_len + 1'"'"'b1 + (role == 1) : 4'"'"'d1;/'
mutant "stuff error check inverted" 's/if (coded != stuff_bit) begin/if (coded == stuff_bit) begin/'
mutant "listener flags a good constant bit" 's/src_const \&\& seen != src_eff\[0\] \&\& (inserted/src_const \&\& seen == src_eff[0] \&\& (inserted/'
mutant "sync input lag wrong" 's/edge_t = now - 12'"'"'d2;/edge_t = now - 12'"'"'d1;/'
mutant "sync leaves before mid-bit" 's/^ *edge_t = now - 12'"'"'d2;$/edge_t = now - 12'"'"'d2; seen = val; edge_t = edge_t + i_dwell;/; s/^ *s = S_MID;$/s = (i_sync \&\& !cur_mine) ? S_POST : S_MID;/'
mutant "sync only checks the level (expected to survive)" 's/ \&\& armed\[i_pin\] != val//'

mutant "one role stuffs zeros in ones-only mode" 's/if (run_len == c_stuff \&\& (coded || !c_ones)) begin/if (run_len == c_stuff \&\& (coded || !c_ones || role == 1)) begin/'
mutant "one role starts its CRC at zero" 's/crc = c_init1 ? /crc = (c_init1 \&\& role == 0) ? /'
mutant "one role accepts a different residual" 's/taken = crc != c_resid;/taken = crc != (role == 1 ? ~c_resid : c_resid);/'
mutant "coder misses the CRC send pattern" 's/coded = (cur_mine \&\& is_mine(i_owner, role)) ? val : seen;/coded = (cur_mine \&\& is_mine(i_owner, role)) ? (src_eff == 1 ? val ^ c_xor[k] : val) : seen;/'
mutant "one role decodes NRZI inverted" 's/seen = (c_nrzi \&\& !i_brk) ? raw == armed\[i_pin\] : raw;/seen = (c_nrzi \&\& !i_brk) ? raw == (role == 1 ? !armed[i_pin] : armed[i_pin]) : raw;/'
mutant "NRZI sends a 1 as a change" 's/lvl = (c_nrzi \&\& !i_brk) ? pin\[i_pin\] ^ !val : val;/lvl = (c_nrzi \&\& !i_brk) ? pin[i_pin] ^ val : val;/'
mutant "NRZI sync waits for the constant" 's/val = (c_nrzi \&\& !i_brk) ? !armed\[i_pin\] : src_eff\[0\];/val = src_eff[0];/'
mutant "pair driven at the same level" 's/drive(c_pair, brk ? v : !v);/drive(c_pair, v);/'
mutant "break leaves the pair high" 's/drive(c_pair, brk ? v : !v);/drive(c_pair, !v);/'
mutant "listener keeps driving the pair" 's/^ *if (c_pair_en) release_pin(c_pair);$//'
mutant "a break bit is NRZI coded" 's/lvl = (c_nrzi \&\& !i_brk) ? pin\[i_pin\] ^ !val : val;/lvl = c_nrzi ? pin[i_pin] ^ !val : val;/'

# The rule itself: with it removed, the proof must fail.
cp janus_hart.v "$OUT/janus_hart.v"
sed 's/if (exec_sync) assume (sync_line_ok);//' lockstep_ind.sv > "$OUT/lockstep_ind.sv"
result=$(cd "$OUT" && sby -f lockstep_ind.sby d4 2>&1 | grep -E "DONE" | sed 's/.*DONE (\([A-Z]*\).*/\1/')
fail=$(cd "$OUT" && grep -hoE "Assert failed in lockstep_ind: lockstep_ind.sv:[0-9]+" lockstep_ind_d4/engine_0/logfile_*.txt | head -1 | sed 's/.*sv://')
[ "$result" = "PASS" ] && echo "SURVIVED    sync rule removed" || echo "BROKE PROOF ($result line ${fail:-?}) sync rule removed"

# The NRZI form of the rule: a sync bit must be a 0.
sed 's/wire sync_line_ok = nrzi ? !want : bus\[0\] != want;/wire sync_line_ok = nrzi || bus[0] != want;/' lockstep_ind.sv > "$OUT/lockstep_ind.sv"
cmp -s lockstep_ind.sv "$OUT/lockstep_ind.sv" && echo "NOT APPLIED NRZI sync rule removed"
result=$(cd "$OUT" && sby -f lockstep_ind.sby d4 2>&1 | grep -E "DONE" | sed 's/.*DONE (\([A-Z]*\).*/\1/')
fail=$(cd "$OUT" && grep -hoE "Assert failed in lockstep_ind: lockstep_ind.sv:[0-9]+" lockstep_ind_d4/engine_0/logfile_*.txt | head -1 | sed 's/.*sv://')
[ "$result" = "PASS" ] && echo "SURVIVED    NRZI sync rule removed" || echo "BROKE PROOF ($result line ${fail:-?}) NRZI sync rule removed"
