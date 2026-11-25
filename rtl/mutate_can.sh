#!/usr/bin/env bash
# Can the CAN proof fail? Plant bugs in the program, the hart and the proof's
# own monitor and assumptions, and require each one to break it. Run in WSL
# from rtl/. In the sed expressions a dot stands for a quote in a pattern, and
# \x27 puts one in a replacement. 9F800000 is a mode word that writes nothing.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/can_mut"
rm -rf "$OUT"; mkdir -p "$OUT"
(cd .. && python3 rtl/gen_can_rom.py "$OUT/rom.vh") > /dev/null || exit 1
cp can_ind.sby "$OUT/"

# mutant <name> <file to change: rom, hart or proof> <sed expression>
# Each runs in its own folder, eight at a time; the results print in order.
N=0
mutant() {
    N=$((N + 1))
    while [ "$(jobs -rp | wc -l)" -ge 8 ]; do wait -n; done
    one "$N" "$@" > "$OUT/r$N.txt" &
}
# Each bug is first simulated: the proof's harness with the bug in it, on
# random inputs that keep the proof's assumptions, as sim_can.sh runs it,
# including frames queued just before the hold trap fires. An assertion that
# fails on a real run means the claim is false, so the proof cannot pass. A
# failed assumption does not count. Bugs the simulation does not catch go to
# the solver; those that only weaken an assumption always do, since the
# simulation never breaks one.
SIMS="11:1: 12:2: 16:3: 50:4: 217:5: 2047:6: 11:7:+race=5 16:8:+race=5 11:9:+norx 16:10:+norx 50:11:+norx"
one() {
    D="$OUT/m$1"; name="$2"; target="$3"; expr="$4"
    mkdir -p "$D"; cp "$OUT/rom.vh" "$D/can_rom.vh"; cp janus_hart.v can_ind.sv can_ind.sby "$D/"
    case "$target" in
        rom)   file="$D/can_rom.vh"; orig="$OUT/rom.vh" ;;
        hart)  file="$D/janus_hart.v"; orig=janus_hart.v ;;
        proof) file="$D/can_ind.sv"; orig=can_ind.sv ;;
    esac
    sed -i -e "$expr" "$file"
    if cmp -s "$orig" "$file"; then echo "NOT APPLIED $name"; return; fi
    if ! iverilog -g2012 -DFORMAL -DCAN_SIM -I "$D" -s tb_can_ind -o "$D/sim.vvp" \
            tb_can_ind.v "$D/can_ind.sv" "$D/janus_hart.v" 2> "$D/iv.log"; then
        echo "NO COMPILE  $name"; rm -rf "$D"; return
    fi
    assumes=$(grep -n "assume (" "$D/can_ind.sv" | cut -d: -f1 | paste -sd'|')
    for bs in $SIMS; do
        bit=${bs%%:*}; rest=${bs#*:}; seed=${rest%%:*}; extra=${rest#*:}
        line=$(vvp "$D/sim.vvp" +bit=$bit +seed=$seed +frames=12 +ticks=600000 $extra 2>&1 \
               | grep -oE "^ERROR: [^ ]*can_ind.sv:[0-9]+" | sed 's/.*sv://' | grep -vxE "$assumes" | head -1)
        if [ -n "$line" ]; then echo "BROKE PROOF (simulation, bit $bit${extra:+ $extra}, line $line) $name"; rm -rf "$D"; return; fi
    done
    (cd "$D" && timeout -k 30 10800 sby -f can_ind.sby h8 > sby.txt 2>&1); code=$?
    for p in $(pgrep yices-smt2); do
        case "$(readlink /proc/$p/cwd)" in "$D"*) kill "$p" ;; esac
    done
    result=$(grep -E "DONE" "$D/sby.txt" | sed 's/.*DONE (\([A-Z]*\).*/\1/')
    fail=$(grep -hoE "Assert failed in can_ind: can_ind.sv:[0-9]+" "$D"/can_ind_h8/engine_0/logfile_*.txt 2>/dev/null | head -1 | sed 's/.*sv://')
    if [ "$code" = 124 ]; then echo "TIMEOUT     $name"
    elif [ "$result" = "ERROR" ] || [ -z "$result" ]; then echo "NO COMPILE  $name"
    elif [ "$result" = "PASS" ]; then echo "SURVIVED    $name"
    else echo "BROKE PROOF ($result line ${fail:-?}) $name"; fi
    rm -rf "$D"
}

# The program
mutant "no bit stuffing" rom '/6.d6:/ s/32.h91000005/32\x27h9F800000/'
mutant "a stuff bit after four equal bits" rom '/6.d6:/ s/32.h91000005/32\x27h91000004/'
mutant "wrong CRC polynomial" rom 's/32.h91804599/32\x27h91804598/'
mutant "14-bit CRC" rom 's/32.h9200000F/32\x27h9200000E/'
mutant "two bits for the top of the identifier" rom '/6.d10:/ s/32.h10040000/32\x27h10020000/'
mutant "seven-bit data bytes" rom '/6.d22:/ s/32.h100E0000/32\x27h100C0000/'
mutant "no zero-length branch: a data byte is always sent" rom '/6.d20:/ s/32.h56000019 + start/32\x27h9F800000/'
mutant "lengths above 8 not capped" rom 's/32.h88080F00/32\x27h880F0F00/'
mutant "the second identifier field is not stored" rom '/6.d14:/ s/32.h48000000/32\x27h9F800000/'
mutant "a dominant CRC delimiter" rom '/6.d27:/ s/32.h10600000/32\x27h10400000/'
mutant "the receiver acknowledges with a 1" rom '/6.d29:/ s/32.h10C00000/32\x27h10E00000/'
mutant "a tail two bits short" rom 's/32.h10740000/32\x27h10700000/'
mutant "the hold trap sends the harts to the wrong word" rom 's/16.h8A20/16\x27h8C20/'

# The hart
mutant "pin seen one tick early" hart 's/^ *pin = s1;$/pin = wire_in[3:0];/'
mutant "no stuff bits sent or expected" hart 's/if (run_len == c_stuff \&\& (coded || !c_ones)) begin/if (1\x27b0) begin/'
mutant "a stuff bit after six equal bits" hart 's/if (run_len == c_stuff \&\& (coded || !c_ones)) begin/if (run_len == c_stuff + 1\x27b1 \&\& (coded || !c_ones)) begin/'
mutant "a stuff bit of the same value" hart 's/stuff_bit = !coded;/stuff_bit = coded;/'
mutant "CRC ignores the bit" hart 's/fb = coded ^ crc\[c_width - 1.b1\];/fb = crc[c_width - 1\x27b1];/'
mutant "no resynchronisation" hart 's/if (none \&\& lf_valid \&\& diff <= {3.b0, i_dwell\[10:2\]}) edge_t = last_fall;/;/'
# The receiver's start of frame is a `sync` bit, and right after it the hart
# moves its edge to the fall it saw, which undoes a lag a tick or two off.
mutant "sync input lag wrong (expected to survive: the resync that follows corrects it)" hart 's/edge_t = now - 12.d2;/edge_t = now - 12\x27d1;/'
mutant "timed bits one tick short" hart 's/edge_t = edge_t + i_dwell;/edge_t = edge_t + i_dwell - 1\x27b1;/'
mutant "load takes a wrong byte" hart '/OP_LOAD: begin/,/OP_STORE: begin/ s/tx = tx_data;/tx = tx_data ^ 8\x27h01;/'
mutant "a store for both harts skips the sender" hart 's/is_mine = (party == ALL) ? (r != WITNESS) : (r == party);/is_mine = (party == ALL) ? (r == 2\x27d1) : (r == party);/'
mutant "claim ignores a falling line" hart 's/if ((base_role == i_owner \&\& tx_valid) || !pin\[i_pin\]) begin/if (base_role == i_owner \&\& tx_valid) begin/'
mutant "the hold count runs on while the hart pulls the line" hart 's/\&\& !(oe_r\[tw\[7:6\]\] \&\& ov_r/\&\& !(1\x27b0 \&\& ov_r/g'
# Every frame here is good, so a receiver that never finds a bad CRC still
# passes. The claims are about what is sent and stored, not error handling.
mutant "receiver ignores a bad CRC (expected to survive: every frame here is good)" hart 's/taken = crc != c_resid;/taken = 1\x27b0;/'

mutant "a listener checks no constant bit, so a missing ACK goes uncounted" hart 's/end else if (src_const \&\& seen != src_eff\[0\] \&\& (inserted || !i_strm))/end else if (1\x27b0)/'
mutant "a witness logs nothing" hart 's/else if (role == WITNESS) seen_push_r = 1.b1;/else if (1\x27b0) seen_push_r = 1\x27b1;/'
mutant "a witness stores as a receiver does" hart 's/if (is_mine(i_party, role)) rx_push_r = 1.b1;/if (is_mine(i_party, role) || role == WITNESS) rx_push_r = 1\x27b1;/'
mutant "a witness acknowledges" hart 's/(r != WITNESS) : (r == party);/(r != WITNESS) : (r == party || (r == WITNESS \&\& party == 2\x27d1));/'
mutant "a witness counts no violations" hart 's/if (violations_r != 8.hFF) violations_r/if (violations_r != 8\x27hFF \&\& role != WITNESS) violations_r/'
mutant "a hart with a queue claims whatever its role" hart 's/if ((base_role == i_owner \&\& tx_valid) || !pin\[i_pin\])/if (tx_valid || !pin[i_pin])/'
mutant "a witness codes every bit as 0" hart 's/(cur_mine \&\& is_mine(i_owner, role)) ? val : seen;/(cur_mine \&\& is_mine(i_owner, role)) ? val : (seen \&\& role != WITNESS);/'

# A bug both harts share. They still agree with each other, so only the
# textbook rule can tell.
mutant "both harts send the least significant bit first" hart 's/if (c_msb) begin val = tx\[7\]; tx = {tx\[6:0\], 1.b0}; end/if (!c_msb) begin val = tx[7]; tx = {tx[6:0], 1\x27b0}; end/; s/else      rx0 = c_msb ? {rx0\[6:0\], b} : {b, rx0\[7:1\]};/else      rx0 = !c_msb ? {rx0[6:0], b} : {b, rx0[7:1]};/'

# The monitor: a wrong idea of CAN must not fit the wire.
mutant "monitor wants a stuff bit after four" proof 's/wire       m_stuff = m_st == M_STUFFED \&\& m_run == 3.d5;/wire       m_stuff = m_st == M_STUFFED \&\& m_run == 3\x27d4;/'
mutant "monitor's CRC polynomial wrong" proof 's/? 15.h4599 : 15.h0);/? 15\x27h4598 : 15\x27h0);/'
mutant "monitor wants a recessive ACK slot" proof 's/assert (m_bus == (m_tail != 4.d1 || norx));/assert (m_bus);/'
mutant "monitor counts no missing ACK" proof 's/m_tail == 4.d1 \&\& m_bus \&\& m_nack != 8.hFF/1\x27b0 \&\& m_bus \&\& m_nack != 8\x27hFF/'
mutant "no receiver, though one is assumed there" proof 's/base_role(norx ? 2.d3 : 2.d0)/base_role(2\x27d3)/'
mutant "monitor's intermission one bit short" proof 's/if (m_tail == 4.d12) m_st <= M_IDLE;/if (m_tail == 4\x27d11) m_st <= M_IDLE;/'
mutant "monitor wants bits a tick longer" proof 's/wire       m_end = m_st != M_IDLE \&\& m_t == BIT - 1.b1;/wire       m_end = m_st != M_IDLE \&\& m_t == BIT;/'

# The proof's own assumptions: without each, it must fail.
mutant "the host may queue remote or extended frames" proof 's/if (a_load \&\& at_a == PC_LOAD3) assume (valid_a \&\& data_a\[7:6\] == 2.b00);/if (a_load \&\& at_a == PC_LOAD3) assume (valid_a);/'
mutant "bit times below 11 ticks allowed" proof 's/assume (BIT >= MINBIT);/assume (BIT >= 11\x27d8);/'
mutant "program loaded past the end of memory" proof 's/assume (start <= MAX_START);//'
mutant "another device may pull BUS low" proof 's/wire        low = (oe_a\[0\] \&\& !ov_a\[0\]) || (oe_b\[0\] \&\& !ov_b\[0\]);/wire        low = (oe_a[0] \&\& !ov_a[0]) || (oe_b[0] \&\& !ov_b[0]) || !other[0];/'

wait
for i in $(seq 1 "$N"); do cat "$OUT/r$i.txt"; done
