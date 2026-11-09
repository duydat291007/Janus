#!/usr/bin/env bash
# Is the replay able to fail? Plant bugs in the Verilog and count what it catches.
# Run in WSL from rtl/, after run.sh has recorded the vectors.
set -uo pipefail
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build"

ticks=0; zero=0
for meta in "$OUT"/vec/*.meta; do
    r=$(vvp "$OUT/tb.vvp" "+base=${meta%.meta}" | grep -E "^OK" | cut -d' ' -f2)
    ticks=$((ticks + ${r:-0}))
    [ "${r:-0}" -gt 0 ] || zero=$((zero + 1))
done
echo "baseline: $ticks ticks replayed, $zero harts with zero ticks"

mutant() {
    name="$1"; expr="$2"
    sed -e "$expr" janus_hart.v > "$OUT/mut.v"
    if cmp -s janus_hart.v "$OUT/mut.v"; then echo "NOT APPLIED $name"; return; fi
    iverilog -g2012 -o "$OUT/mut.vvp" tb_replay.v "$OUT/mut.v" 2> /dev/null \
        || { echo "NO COMPILE  $name"; return; }
    caught=0
    for meta in "$OUT"/vec/*.meta; do
        if vvp "$OUT/mut.vvp" "+base=${meta%.meta}" | grep -q "^MISMATCH"; then
            caught=$((caught + 1))
        fi
    done
    [ "$caught" -gt 0 ] && echo "CAUGHT($caught) $name" || echo "SURVIVED    $name"
}

mutant "bit order of receive" 's/else      rx0 = c_msb ? {rx0\[6:0\], b} : {b, rx0\[7:1\]};/else      rx0 = c_msb ? {b, rx0[7:1]} : {rx0[6:0], b};/'
mutant "no edge resync" 's/if (none \&\& lf_valid \&\&/if (1'"'"'b0 \&\&/'
mutant "CRC never xors" 's/if (fb) crc = crc ^ c_poly;//'
mutant "second width trap dead" 's/if (held1 == cfg5) begin/if (1'"'"'b0) begin/'
mutant "no timed arbitration" 's/lose(i_pin, 1'"'"'b0, 3'"'"'d0);/;/'
mutant "free bits still checked" 's/seen != src_eff\[0\] \&\& (inserted || !i_strm)/seen != src_eff[0]/'
mutant "sync input lag wrong" 's/edge_t = now - 12'"'"'d2;/edge_t = now - 12'"'"'d1;/'
mutant "sync only checks the level" 's/ \&\& armed\[i_pin\] != val//'
mutant "armed never updated at sample" 's/^ *armed = pin;$//'
mutant "mid-frame not flagged" 's/if (partial) violations_r = violations_r + 1'"'"'b1;//'
mutant "stream never refills" 's/^ *refill;$/;/'
mutant "stuff bit wrong polarity" 's/stuff_bit = !seen;/stuff_bit = seen;/'
mutant "settle skipped" 's/if (!(od_mask\[i_pin\] \&\& pin\[i_pin\] != val)) s = S_POST;/s = S_POST;/'
mutant "address never mismatches" 's/(rx0 >> ins\[25:23\]) != addr_reg/1'"'"'b0/'
mutant "claim ignores falling pin" 's/if ((base_role == i_owner \&\& tx_valid) || !pin\[i_pin\]) begin/if (base_role == i_owner \&\& tx_valid) begin/'
mutant "cpha ignored at top" 's/if (!c_cpha) lanes_out;/lanes_out;/'
mutant "crc_bad not flagged" 's/if (taken) violations_r = violations_r + 1'"'"'b1;//'
mutant "lane 2 store dropped" 's/push_data_r = rx1;//'
