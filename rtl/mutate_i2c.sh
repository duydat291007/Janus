#!/usr/bin/env bash
# Can the I2C proof fail? Plant bugs in the program, the hart and the proof's
# own monitor and assumptions, and require each one to break it. Run in WSL
# from rtl/. In the sed expressions a dot stands for a quote in a pattern, and
# \x27 puts one in a replacement. 9F800000 is a mode word that writes nothing.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/i2c_mut"
rm -rf "$OUT"; mkdir -p "$OUT"
(cd .. && python3 rtl/gen_i2c_rom.py "$OUT/rom.vh") > /dev/null || exit 1
cp i2c_ind.sby "$OUT/"

# mutant <name> <file to change: rom, hart or proof> <sed expression>
# Each runs in its own folder, eight at a time; the results print in order.
N=0
mutant() {
    N=$((N + 1))
    while [ "$(jobs -rp | wc -l)" -ge 8 ]; do wait -n; done
    one "$N" "$@" > "$OUT/r$N.txt" &
}
# Each bug is first simulated: the proof's harness with the bug in it, on
# random inputs that keep the proof's assumptions, as sim_i2c.sh runs it. An
# assertion that fails on a real run means the claim is false, so the proof
# cannot pass. A failed assumption does not count. Bugs the simulation does
# not catch go to the solver; those that only weaken an assumption always
# do, since the simulation never breaks one.
SIMS="8:1 9:2 13:3 50:4 217:5"
one() {
    D="$OUT/m$1"; name="$2"; target="$3"; expr="$4"
    mkdir -p "$D"; cp "$OUT/rom.vh" "$D/i2c_rom.vh"; cp janus_hart.v i2c_ind.sv i2c_ind.sby "$D/"
    case "$target" in
        rom)   file="$D/i2c_rom.vh"; orig="$OUT/rom.vh" ;;
        hart)  file="$D/janus_hart.v"; orig=janus_hart.v ;;
        proof) file="$D/i2c_ind.sv"; orig=i2c_ind.sv ;;
    esac
    sed -i -e "$expr" "$file"
    if cmp -s "$orig" "$file"; then echo "NOT APPLIED $name"; return; fi
    if ! iverilog -g2012 -DFORMAL -DI2C_SIM -I "$D" -s tb_i2c_ind -o "$D/sim.vvp" \
            tb_i2c_ind.v "$D/i2c_ind.sv" "$D/janus_hart.v" 2> "$D/iv.log"; then
        echo "NO COMPILE  $name"; rm -rf "$D"; return
    fi
    assumes=$(grep -n "assume (" "$D/i2c_ind.sv" | cut -d: -f1 | paste -sd'|')
    for hs in $SIMS; do
        line=$(vvp "$D/sim.vvp" +half=${hs%:*} +seed=${hs#*:} +bytes=60 +ticks=300000 2>&1 \
               | grep -oE "^ERROR: [^ ]*i2c_ind.sv:[0-9]+" | sed 's/.*sv://' | grep -vxE "$assumes" | head -1)
        if [ -n "$line" ]; then echo "BROKE PROOF (simulation, half ${hs%:*}, line $line) $name"; rm -rf "$D"; return; fi
    done
    (cd "$D" && timeout -k 30 5400 sby -f i2c_ind.sby h8 > sby.txt 2>&1); code=$?
    for p in $(pgrep yices-smt2); do
        case "$(readlink /proc/$p/cwd)" in "$D"*) kill "$p" ;; esac
    done
    result=$(grep -E "DONE" "$D/sby.txt" | sed 's/.*DONE (\([A-Z]*\).*/\1/')
    fail=$(grep -hoE "Assert failed in i2c_ind: i2c_ind.sv:[0-9]+" "$D"/i2c_ind_h8/engine_0/logfile_*.txt 2>/dev/null | head -1 | sed 's/.*sv://')
    if [ "$code" = 124 ]; then echo "TIMEOUT     $name"
    elif [ "$result" = "ERROR" ] || [ -z "$result" ]; then echo "NO COMPILE  $name"
    elif [ "$result" = "PASS" ]; then echo "SURVIVED    $name"
    else echo "BROKE PROOF ($result line ${fail:-?}) $name"; fi
    rm -rf "$D"
}

# The program
mutant "no bus-free wait after a STOP" rom '/6.d3:/ s/32.h12600000 | half/32\x27h9F800000/'
mutant "no claim: the controller does not wait for a byte" rom 's/32.h22000000/32\x27h9F800000/'
mutant "seven bits in the address" rom '/6.d10:/ s/32.h120E8000/32\x27h120C8000/'
mutant "seven bits in a written byte" rom '/6.d20:/ s/32.h120E8000/32\x27h120C8000/'
mutant "seven bits in a byte read" rom 's/32.h128E8000/32\x27h128C8000/'
mutant "target stores nothing of the address" rom '/6.d11:/ s/32.h44000000/32\x27h9F800000/'
mutant "no address match" rom 's/32.h74800000/32\x27h9F800000/'
mutant "target acknowledges with a 1" rom '/6.d13:/ s/32.h36000000/32\x27h360000FF/'
mutant "R/W bit ignored: every transaction a read" rom 's/32.h5400001A/32\x27h5000001A/'
mutant "a NACKed address does not end the write" rom '/6.d16:/ s/32.h54000027 + start/32\x27h9F800000/'
mutant "a STOP entry is not taken" rom 's/32.h63000027/32\x27h62000027/'
mutant "a RESTART entry is not taken" rom 's/32.h60800023/32\x27h60000023/'
mutant "the controller acknowledges as the target" rom 's/32.h12008000/32\x27h12808000/'
mutant "a NACK does not end the read" rom '/6.d33:/ s/32.h54000027 + start/32\x27h9F800000/'
mutant "repeated START without the clock rising" rom '/6.d36:/ s/32.h10600000 | half/32\x27h9F800000/'
mutant "STOP without the clock rising" rom '/6.d40:/ s/32.h10610000 | half/32\x27h9F800000/'
mutant "no STOP trap" rom 's/16.h8671/16\x27h0671/'
mutant "START trap sends the harts to the wrong word" rom 's/16.h8E51/16\x27h9051/'

# The hart
mutant "pin seen one tick early" hart 's/^ *pin = s1;$/pin = wire_in[3:0];/'
# The target leaves `idle` only through the START trap, which runs before the
# claim, so a claim that ignores the falling line changes nothing here.
mutant "claim ignores a falling line (expected to survive: the START trap runs first)" hart 's/if ((base_role == i_owner \&\& tx_valid) || !pin\[i_pin\]) begin/if (base_role == i_owner \&\& tx_valid) begin/'
mutant "claim does not wait for a byte" hart 's/if ((base_role == i_owner \&\& tx_valid) || !pin\[i_pin\]) begin/if (base_role == i_owner || !pin[i_pin]) begin/'
mutant "sync input lag wrong" hart 's/edge_t = now - 12.d2;/edge_t = now - 12\x27d1;/'
mutant "load takes a wrong byte" hart '/OP_LOAD: begin/,/OP_STORE: begin/ s/tx = tx_data;/tx = tx_data ^ 8\x27h01;/'
mutant "every hart thinks the bit is its own" hart 's/cur_mine = is_mine(i_owner, role);/cur_mine = 1;/'
mutant "trap fires on a level, not an edge" hart 's/prev\[tw\[7:6\]\] != tw\[5\] \&\& //'
mutant "data read as the clock falls" hart 's/if (!c_cpha) sample_lanes;/if (c_cpha) sample_lanes;/'
mutant "target does not wait for the clock" hart 's/if (pin\[c_clk\] == level$/if (1 || pin[c_clk] == level/'
mutant "controller does not wait for a released clock to rise" hart 's/\&\& !od_mask\[c_clk\])) begin/\&\& 1)) begin/'
mutant "match ignores the R/W shift" hart 's/(rx0 >> ins\[25:23\]) != addr_reg/rx0 != addr_reg/'
mutant "a choice takes RESTART for STOP" hart "s/else if (tx_ctl == 2'd1 \&\& ins\[24\]) taken = 1'b1;/else if (tx_ctl == 2'd2 \&\& ins[24]) taken = 1'b1;/"
mutant "timed bits one tick short" hart 's/edge_t = edge_t + i_dwell;/edge_t = edge_t + i_dwell - 1\x27b1;/'
mutant "clock halves one tick short" hart 's/cnt = i_dwell - 1.b1;/cnt = i_dwell - 2\x27d2;/'
mutant "store pushes in every hart" hart 's/if (is_mine(i_party, role)) rx_push_r = 1.b1;/if (1) rx_push_r = 1\x27b1;/'
mutant "match does not step aside" hart 's/role = WITNESS;$/;/'
# The owner of a released line waits for it to rise, but here nothing holds
# SDA or SCL low then, so the wait is never needed.
mutant "settle does not wait (expected to survive: nothing holds a released line)" hart 's/if (!(od_mask\[i_pin\] \&\& pin\[i_pin\] != ((c_nrzi || faulty) ? ov_r\[i_pin\] : val)))/if (1)/'

# A bug both harts share. They still agree with each other, so only the
# textbook rule can tell.
mutant "both harts send the least significant bit first" hart 's/if (c_msb) begin val = tx\[7\]; tx = {tx\[6:0\], 1.b0}; end/if (!c_msb) begin val = tx[7]; tx = {tx[6:0], 1\x27b0}; end/; s/else      rx0 = c_msb ? {rx0\[6:0\], b} : {b, rx0\[7:1\]};/else      rx0 = !c_msb ? {rx0[6:0], b} : {b, rx0[7:1]};/'

# The monitor: a wrong idea of I2C must not fit the wire.
mutant "monitor reads the least significant bit first" proof 's/wire \[7:0\] m_byte = {m_b\[6:0\], m_sda};/wire [7:0] m_byte = {m_sda, m_b[7:1]};/'
mutant "monitor wants SCL low HALF + 3" proof 's/if (m_rise) assert (m_lc >= d \&\&/if (m_rise) assert (m_lc >= d + 12\x27d3 \&\&/'
mutant "monitor wants SCL high HALF + 2" proof 's/if (m_fall) assert (m_lc >= d \&\&/if (m_fall) assert (m_lc >= d + 12\x27d2 \&\&/'
mutant "monitor wants a data setup of HALF" proof 's/m_ld >= d - 12.d1);/m_ld >= d);/'
mutant "monitor wants a data hold of 4 ticks" proof 's/assert (!m_prev\[0\] \&\& m_lc >= 12.d2);/assert (!m_prev[0] \&\& m_lc >= 12\x27d4);/'
mutant "monitor wants HALF + 1 before a START or STOP" proof 's/if (m_start || m_stop) assert (m_lc >= d);/if (m_start || m_stop) assert (m_lc >= d + 12\x27d1);/'
mutant "monitor wants a START hold of HALF + 4" proof 's/assert (m_st >= d);/assert (m_st >= d + 12\x27d4);/'
mutant "monitor wants the bus free for HALF + 4" proof 's/if (m_start \&\& !m_in) assert (m_sp >= d);/if (m_start \&\& !m_in) assert (m_sp >= d + 12\x27d4);/'

# The proof's own assumptions: without each, it must fail.
mutant "a controller queue entry may vanish" proof 's/if (vq_c \&\& !pop_c) assume (valid_c \&\& data_c == dq_c \&\& ctl_c == kq_c);//'
mutant "half periods below 8 ticks allowed" proof 's/assume (HALF >= MINHALF);/assume (HALF >= 11\x27d2);/'
mutant "another device may hold SCL low" proof 's/wire \[1:0\]  low = (oe_c\[1:0\] \& ~ov_c\[1:0\]) | (oe_t\[1:0\] \& ~ov_t\[1:0\]);/wire [1:0]  low = (oe_c[1:0] \& ~ov_c[1:0]) | (oe_t[1:0] \& ~ov_t[1:0]) | {1\x27b0, ~other[0]};/'
mutant "program loaded past the end of memory" proof 's/assume (start <= MAX_START);//'

wait
for i in $(seq 1 "$N"); do cat "$OUT/r$i.txt"; done
