#!/usr/bin/env bash
# Can the 1-Wire proof fail? Plant bugs in the program, the hart and the
# proof's own assumptions, and require each one to break it. Run in WSL from
# rtl/. In the sed expressions a dot stands for a quote in a pattern, and \x27
# puts one in a replacement.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/onewire_mut"
rm -rf "$OUT"; mkdir -p "$OUT"
(cd .. && python3 rtl/gen_onewire_rom.py "$OUT/rom.vh") > /dev/null || exit 1

# mutant <name> <file to change: rom, hart or proof> <sed expression>
# Each runs in its own folder, eight at a time; the results print in order.
N=0
mutant() {
    N=$((N + 1))
    while [ "$(jobs -rp | wc -l)" -ge 8 ]; do wait -n; done
    one "$N" "$@" > "$OUT/r$N.txt" &
}
# Each bug is first simulated: the proof's harness with the bug in it, on
# random inputs that keep the proof's assumptions, as sim_onewire.sh runs it. An
# assertion that fails on a real run means the claim is false, so the proof
# cannot pass. A failed assumption does not count. Bugs the simulation does
# not catch go to the solver; those that only weaken an assumption always
# do, since the simulation never breaks one.
SIMS="+seed=1 +seed=2 +seed=3 +seed=4"
one() {
    D="$OUT/m$1"; name="$2"; target="$3"; expr="$4"
    mkdir -p "$D"; cp "$OUT/rom.vh" "$D/onewire_rom.vh"; cp janus_hart.v onewire_ind.sv onewire_ind.sby "$D/"
    case "$target" in
        rom)   file="$D/onewire_rom.vh"; orig="$OUT/rom.vh" ;;
        hart)  file="$D/janus_hart.v"; orig=janus_hart.v ;;
        proof) file="$D/onewire_ind.sv"; orig=onewire_ind.sv ;;
    esac
    sed -i -e "$expr" "$file"
    if cmp -s "$orig" "$file"; then echo "NOT APPLIED $name"; return; fi
    if ! iverilog -g2012 -DFORMAL -DOW_SIM -I "$D" -s tb_onewire_ind -o "$D/sim.vvp" \
            tb_onewire_ind.v "$D/onewire_ind.sv" "$D/janus_hart.v" 2> "$D/iv.log"; then
        echo "NO COMPILE  $name"; rm -rf "$D"; return
    fi
    assumes=$(grep -n "assume (" "$D/onewire_ind.sv" | cut -d: -f1 | paste -sd'|')
    for args in $SIMS; do
        line=$(vvp "$D/sim.vvp" $(echo "$args" | tr ',' ' ') +bytes=40 +ticks=300000 2>&1 \
               | grep -oE "^ERROR: [^ ]*onewire_ind.sv:[0-9]+" | sed 's/.*sv://' | grep -vxE "$assumes" | head -1)
        if [ -n "$line" ]; then echo "BROKE PROOF (simulation, $args, line $line) $name"; rm -rf "$D"; return; fi
    done
    (cd "$D" && timeout -k 30 5400 sby -f onewire_ind.sby h8 > sby.txt 2>&1); code=$?
    for p in $(pgrep bitwuzla); do
        case "$(readlink /proc/$p/cwd)" in "$D"*) kill "$p" ;; esac
    done
    result=$(grep -E "DONE" "$D/sby.txt" | sed 's/.*DONE (\([A-Z]*\).*/\1/')
    fail=$(grep -hoE "Assert failed in onewire_ind: onewire_ind.sv:[0-9]+" "$D"/onewire_ind_h8/engine_0/logfile_*.txt 2>/dev/null | head -1 | sed 's/.*sv://')
    if [ "$code" = 124 ]; then echo "TIMEOUT     $name"
    elif [ "$result" = "ERROR" ] || [ -z "$result" ]; then echo "NO COMPILE  $name"
    elif [ "$result" = "PASS" ]; then echo "SURVIVED    $name"
    else echo "BROKE PROOF ($result line ${fail:-?}) $name"; fi
    rm -rf "$D"
}

# The program. 9F800000 is a mode word that writes nothing.
mutant "arbitration loss left on" rom 's/32.h93000002/32\x27h9F800000/'
mutant "no claim: a reset with no byte to write" rom 's/32.h20000000/32\x27h9F800000/'
mutant "suspect trap one tick late" rom 's/3.d4: ow_config = 16.d130/3\x27d4: ow_config = 16\x27d131/'
mutant "reset trap one tick late" rom 's/3.d5: ow_config = 16.d300/3\x27d5: ow_config = 16\x27d301/'
mutant "no suspect trap" rom 's/16.h8800/16\x27h0800/'
mutant "reset trap sends the harts to the wrong word" rom 's/16.h8E00/16\x27h9000/'
mutant "presence pulse as long as an illegal pulse" rom 's/32.h10800050/32\x27h10800082/'
mutant "target sends no presence pulse" rom 's/32.h36000000/32\x27h360000FF/'
mutant "seven write slots a byte" rom '/6.d14:/ s/32.h80000008/32\x27h80000007/'
mutant "seven read slots a byte" rom '/6.d23:/ s/32.h80000008/32\x27h80000007/'
mutant "write slot four ticks short" rom 's/32.h10000036/32\x27h10000032/'
mutant "read bit held past the next slot" rom 's/32.h10800012/32\x27h10800040/'
mutant "controller sends the read bits itself" rom 's/32.h10800012/32\x27h10000012/'
mutant "controller stores the written byte" rom 's/32.h44000000/32\x27h40000000/'
mutant "target stores the byte read" rom '/6.d28:/ s/32.h40000000/32\x27h44000000/'
mutant "reads go on with no token" rom 's/32.h62000001/32\x27h60000001/'
mutant "read token never taken" rom '/6.d21:/ s/32.h30000000/32\x27h9F800000/'
mutant "target never loads the byte to read" rom 's/32.h35000000/32\x27h9F800000/'

# Timings changed in the program itself, word and step length together, so
# the proof's own formulas follow them. Only the textbook rules can object.
mutant "reset of 479 ticks on the wire" rom 's/32.h104000DC/32\x27h104000B1/; s/D_RESET = 12.d220/D_RESET = 12\x27d177/'
mutant "first slot 479 ticks after the reset" rom 's/32.h1060019A/32\x27h10600171/; s/D_WAIT = 12.d410/D_WAIT = 12\x27d369/'
mutant "presence pulse 14 ticks after the reset" rom 's/32.h1061001E/32\x27h1061000E/; s/D_RELEASE = 12.d30/D_RELEASE = 12\x27d14/'
mutant "read slots 60 ticks apart" rom 's/32.h1060402E/32\x27h10604024/; s/D_RREST = 12.d46/D_RREST = 12\x27d36/'

# The hart
mutant "pin seen one tick early" hart 's/^ *pin = s1;$/pin = wire_in[3:0];/'
mutant "claim ignores a falling line" hart 's/if ((base_role == i_owner \&\& tx_valid) || !pin\[i_pin\]) begin/if (base_role == i_owner \&\& tx_valid) begin/'
mutant "claim does not wait for a byte" hart 's/if ((base_role == i_owner \&\& tx_valid) || !pin\[i_pin\]) begin/if (base_role == i_owner || !pin[i_pin]) begin/'
mutant "sync input lag wrong" hart 's/edge_t = now - 12.d2;/edge_t = now - 12\x27d1;/'
mutant "load takes a wrong byte" hart '/OP_LOAD: begin/,/OP_STORE: begin/ s/tx = tx_data;/tx = tx_data ^ 8\x27h01;/'

# Keep: a byte taken with keep leaves the queue only with its last bit.
mutant "a kept load is popped at once" hart 's/if (ins\[24\]) keep_n = 4.d8;/if (ins[24]) tx_pop_r = 1\x27b1;/'
mutant "a kept byte is popped one bit early" hart 's/if (keep_n == 0 \&\& tx_valid) tx_pop_r = 1.b1;/if (keep_n == 1 \&\& tx_valid) tx_pop_r = 1\x27b1;/'
mutant "a trap does not drop a kept byte" hart '/task fire/,/endtask/ s/keep_n = 0; .*$//'
mutant "the target loads without keep" rom 's/32.h35000000/32\x27h34000000/'
mutant "every hart thinks the bit is its own" hart 's/cur_mine = is_mine(i_owner, role);/cur_mine = 1;/'
mutant "hold counter never restarts" hart 's/end else held0 = 0;/end/'
mutant "hold trap fires one tick late" hart 's/if (held0 == cfg4) begin/if (held0 == cfg4 + 1\x27b1) begin/'
mutant "arbitration cannot be switched off" hart 's/if (c_lose != LOSE_NONE \&\& val \&\& !seen \&\& !faulty)/if (val \&\& !seen \&\& !faulty)/'
mutant "bit read at its edge, not its middle" hart 's/if (is_before(now, edge_t + (i_dwell >> 1))) begin/if (is_before(now, edge_t)) begin/'
mutant "listener keeps driving after its bit" hart 's/if (!cur_mine) put_release(i_pin);//'
mutant "store pushes in every hart" hart 's/if (is_mine(i_party, role)) rx_push_r = 1.b1;/if (1) rx_push_r = 1\x27b1;/'
mutant "store sends the other lane" hart 's/push_data_r = ins\[25\] ? rx1 : rx0;/push_data_r = rx1;/'
mutant "loop ends one pass early" hart 's/taken = count != 0;/taken = count > 8\x27d1;/'
mutant "trap keeps the old bit edge" hart '/task fire/,/endtask/ s/edge_t = now;//'
mutant "timed bit one tick long" hart 's/edge_t = edge_t + i_dwell;/edge_t = edge_t + i_dwell + 1\x27b1;/'

# A bug both harts share. They still agree with each other, so only the
# textbook rule can tell.
mutant "both harts send the most significant bit first" hart 's/if (c_msb) begin val = tx\[7\]; tx = {tx\[6:0\], 1.b0}; end/if (!c_msb) begin val = tx[7]; tx = {tx[6:0], 1\x27b0}; end/; s/else      rx0 = c_msb ? {rx0\[6:0\], b} : {b, rx0\[7:1\]};/else      rx0 = !c_msb ? {rx0[6:0], b} : {b, rx0[7:1]};/'

# The witness
mutant "a witness logs nothing" hart 's/else if (role == WITNESS) seen_push_r = 1.b1;/else if (1\x27b0) seen_push_r = 1\x27b1;/'
mutant "a witness stores as a receiver does" hart 's/if (is_mine(i_party, role)) rx_push_r = 1.b1;/if (is_mine(i_party, role) || role == WITNESS) rx_push_r = 1\x27b1;/'
mutant "a witness sends the bits of the target" hart 's/(r != WITNESS) : (r == party);/(r != WITNESS) : (r == party || (r == WITNESS \&\& party == 2\x27d1));/'
mutant "a witness sends the bits of the controller" hart 's/(r != WITNESS) : (r == party);/(r != WITNESS) : (r == party || (r == WITNESS \&\& party == 2\x27d0));/'
mutant "a hart with a queue claims whatever its role" hart 's/if ((base_role == i_owner \&\& tx_valid) || !pin\[i_pin\])/if (tx_valid || !pin[i_pin])/'

# The monitor: a wrong idea of 1-Wire must not fit the wire.
mutant "monitor reads the bit in tick 31" proof 's/m_ph == 2.d3 \&\& m_t == 10.d14;/m_ph == 2\x27d3 \&\& m_t == 10\x27d30;/'
mutant "monitor takes the first bit as the top one" proof 's/{bus\[0\], m_b\[7:1\]}/{m_b[6:0], bus[0]}/g'
mutant "monitor takes the first byte as one read" proof 's/(m_first ? wr : rd)/(m_first ? rd : wr)/'
mutant "monitor wants 71 ticks between falls" proof 's/assert (m_t >= 10.d61);/assert (m_t >= 10\x27d71);/'
mutant "monitor wants a reset of 523 ticks" proof 's/assert (m_t <= 10.d120 || m_t >= 10.d480);/assert (m_t <= 10\x27d120 || m_t >= 10\x27d523);/'
mutant "monitor wants presence 31 ticks after the reset" proof 's/assert (m_h >= 7.d15 \&\& m_h <= 7.d60);/assert (m_h >= 7\x27d31 \&\& m_h <= 7\x27d60);/'
mutant "monitor wants a presence pulse under 80 ticks" proof 's/assert (m_t >= 10.d60 \&\& m_t <= 10.d240);/assert (m_t >= 10\x27d60 \&\& m_t <= 10\x27d79);/'

# The proof's own assumptions: without each, it must fail.
mutant "a controller queue entry may vanish" proof 's/if (vq_c \&\& !pop_c) assume (valid_c);//'
mutant "program loaded past the end of memory" proof 's/assume (start <= MAX_START);//'
mutant "the target cannot pull the line low" proof 's/wire        low = (oe_c\[0\] \&\& !ov_c\[0\]) || (oe_t\[0\] \&\& !ov_t\[0\]);/wire        low = (oe_c[0] \&\& !ov_c[0]);/'
mutant "the hold traps are never set" proof 's/wire        cfg_we = step >= 3.d1 \&\& step <= 3.d4;/wire        cfg_we = 1\x27b0;/'

wait
for i in $(seq 1 "$N"); do cat "$OUT/r$i.txt"; done
