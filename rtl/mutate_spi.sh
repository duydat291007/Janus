#!/usr/bin/env bash
# Can the SPI proof fail? Plant bugs in the program, the hart and the proof's
# own assumptions, and require each one to break it. Run in WSL from rtl/.
# In the sed expressions a dot stands for a quote in a pattern, and \x27 puts
# one in a replacement.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/spi_mut"
rm -rf "$OUT"; mkdir -p "$OUT"
(cd .. && python3 rtl/gen_spi_rom.py "$OUT/rom.vh") > /dev/null || exit 1

# mutant <name> <file to change: rom, hart or proof> <sed expression>
# Each runs in its own folder, eight at a time; the results print in order.
N=0
mutant() {
    N=$((N + 1))
    while [ "$(jobs -rp | wc -l)" -ge 8 ]; do wait -n; done
    one "$N" "$@" > "$OUT/r$N.txt" &
}
# Each bug is first simulated: the proof's harness with the bug in it, on
# random inputs that keep the proof's assumptions, as sim_spi.sh runs it. An
# assertion that fails on a real run means the claim is false, so the proof
# cannot pass. A failed assumption does not count. Bugs the simulation does
# not catch go to the solver; those that only weaken an assumption always
# do, since the simulation never breaks one.
SIMS="+half=8,+cpol=0,+cpha=0,+seed=1 +half=8,+cpol=0,+cpha=1,+seed=2 +half=9,+cpol=1,+cpha=0,+seed=3 +half=13,+cpol=1,+cpha=1,+seed=4 +half=50,+cpol=0,+cpha=0,+seed=5"
one() {
    D="$OUT/m$1"; name="$2"; target="$3"; expr="$4"
    mkdir -p "$D"; cp "$OUT/rom.vh" "$D/spi_rom.vh"; cp janus_hart.v spi_ind.sv spi_ind.sby "$D/"
    case "$target" in
        rom)   file="$D/spi_rom.vh"; orig="$OUT/rom.vh" ;;
        hart)  file="$D/janus_hart.v"; orig=janus_hart.v ;;
        proof) file="$D/spi_ind.sv"; orig=spi_ind.sv ;;
    esac
    sed -i -e "$expr" "$file"
    if cmp -s "$orig" "$file"; then echo "NOT APPLIED $name"; return; fi
    if ! iverilog -g2012 -DFORMAL -DSPI_SIM -I "$D" -s tb_spi_ind -o "$D/sim.vvp" \
            tb_spi_ind.v "$D/spi_ind.sv" "$D/janus_hart.v" 2> "$D/iv.log"; then
        echo "NO COMPILE  $name"; rm -rf "$D"; return
    fi
    assumes=$(grep -n "assume (" "$D/spi_ind.sv" | cut -d: -f1 | paste -sd'|')
    for args in $SIMS; do
        line=$(vvp "$D/sim.vvp" $(echo "$args" | tr ',' ' ') +bytes=60 +ticks=300000 2>&1 \
               | grep -oE "^ERROR: [^ ]*spi_ind.sv:[0-9]+" | sed 's/.*sv://' | grep -vxE "$assumes" | head -1)
        if [ -n "$line" ]; then echo "BROKE PROOF (simulation, $args, line $line) $name"; rm -rf "$D"; return; fi
    done
    (cd "$D" && timeout -k 30 5400 sby -f spi_ind.sby h8 > sby.txt 2>&1); code=$?
    for p in $(pgrep bitwuzla); do
        case "$(readlink /proc/$p/cwd)" in "$D"*) kill "$p" ;; esac
    done
    result=$(grep -E "DONE" "$D/sby.txt" | sed 's/.*DONE (\([A-Z]*\).*/\1/')
    fail=$(grep -hoE "Assert failed in spi_ind: spi_ind.sv:[0-9]+" "$D"/spi_ind_h8/engine_0/logfile_*.txt 2>/dev/null | head -1 | sed 's/.*sv://')
    if [ "$code" = 124 ]; then echo "TIMEOUT     $name"
    elif [ "$result" = "ERROR" ] || [ -z "$result" ]; then echo "NO COMPILE  $name"
    elif [ "$result" = "PASS" ]; then echo "SURVIVED    $name"
    else echo "BROKE PROOF ($result line ${fail:-?}) $name"; fi
    rm -rf "$D"
}

# The program
mutant "clock polarity never set" rom '/6.d3:/ s/ | cpol//'
mutant "clock phase never set" rom '/6.d4:/ s/ | cpha//'
mutant "clock idles at the wrong level" rom '/6.d7:/ s/{cpol, 21.d0}/{!cpol, 21\x27d0}/'
mutant "seven bits a byte" rom 's/32.h140ED000/32\x27h140CD000/'
mutant "no stream: the transfer ends after one byte" rom 's/32.h140ED000/32\x27h140E9000/'
mutant "target sends on the MOSI pin" rom 's/32.h9580002D/32\x27h95800029/'
mutant "MISO never released" rom 's/32.h07400000/32\x27h90000001/'
mutant "no claim: the controller does not wait for a byte" rom 's/32.h20000000/32\x27h90000001/'
mutant "select does not sync the target" rom 's/32.h10410000/32\x27h10400000/'
mutant "target never loads its byte" rom 's/32.h35000000/32\x27h90000001/'
mutant "trap sends the harts to the wrong word" rom 's/16.h9020/16\x27h9220/'
mutant "no trap on CS" rom 's/16.h9020/16\x27h1020/'

# The hart
mutant "data read at the wrong clock edge" hart 's/if (!c_cpha) sample_lanes;/if (c_cpha) sample_lanes;/'
mutant "clock half one tick long" hart 's/cnt = i_dwell - 1.b1;/cnt = i_dwell;/'
mutant "leading edge at the idle level" hart 's/level = !c_cpol;/level = c_cpol;/'
mutant "target does not wait for the clock" hart 's/if (pin\[c_clk\] == level$/if (1 || pin[c_clk] == level/'
mutant "target drives the clock" hart 's/release_pin(c_clk);/drive(c_clk, level);/'
mutant "second lane shifts the other way" hart 's/if (lane) rx1 = c_msb ? {rx1\[6:0\], b} : {b, rx1\[7:1\]};/if (lane) rx1 = c_msb ? {b, rx1[7:1]} : {rx1[6:0], b};/'
mutant "second lane read from the first lane pin" hart 's/sample_lane(1.b1, c_l2_pin, c_l2_own);/sample_lane(1\x27b1, i_pin, c_l2_own);/'
mutant "controller stores the wrong lane" hart 's/push_data_r = rx1;/push_data_r = rx0;/'
mutant "target stores nothing at a byte end" hart 's/else rx_push_r = 1.b1;/else rx_push_r = 0;/'
# The stream refills with keep, so the ordinary refill pop never runs here.
mutant "refill leaves the entry in the queue (expected to survive: SPI refills with keep)" hart '/task refill;/,/endtask/ s/tx_pop_r = 1.b1;/;/'
mutant "a kept byte is never popped" hart 's/if (keep_n == 0 \&\& tx_valid) tx_pop_r = 1.b1;/;/'
mutant "stream ends with a byte still queued" hart 's/if (is_mine(c_clk_own, role) \&\& !tx_valid) finish;/if (is_mine(c_clk_own, role)) finish;/'
mutant "trap fires on a level, not an edge" hart 's/prev\[tw\[7:6\]\] != tw\[5\] \&\& //'
mutant "trap does not rearm the sync" hart '/task fire/,/endtask/ s/armed = pin;//'
mutant "clocked data sent LSB first" hart 's/if (c_msb) begin val = tx\[7\]; tx = {tx\[6:0\], 1.b0}; end/if (c_msb) begin val = tx[0]; tx = {1\x27b0, tx[7:1]}; end/'
mutant "pin seen one tick early" hart 's/^ *pin = s1;$/pin = wire_in[3:0];/'
mutant "claim ignores a falling line" hart 's/if ((base_role == i_owner \&\& tx_valid) || !pin\[i_pin\]) begin/if (base_role == i_owner \&\& tx_valid) begin/'
mutant "claim does not wait for a byte" hart 's/if ((base_role == i_owner \&\& tx_valid) || !pin\[i_pin\]) begin/if (base_role == i_owner || !pin[i_pin]) begin/'
mutant "set does not drive" hart 's/else drive(i_pin, i_src\[0\]);/;/'
mutant "every hart thinks the bit is its own" hart 's/cur_mine = is_mine(i_owner, role);/cur_mine = 1;/'
mutant "sync input lag wrong" hart 's/edge_t = now - 12.d2;/edge_t = now - 12\x27d1;/'
mutant "load takes a wrong byte" hart '/OP_LOAD: begin/,/OP_STORE: begin/ s/tx = tx_data;/tx = tx_data ^ 8\x27h01;/'

# Keep: a byte taken with keep leaves the queue only with its last bit.
mutant "a kept load is popped at once" hart 's/if (ins\[24\]) keep_n = 4.d8;/if (ins[24]) tx_pop_r = 1\x27b1;/'
mutant "a stream refill ignores keep" hart 's/if (i_keep) keep_n = 4.d8;/if (1\x27b0) keep_n = 4\x27d8;/'
mutant "a kept byte is popped one bit early" hart 's/if (keep_n == 0 \&\& tx_valid) tx_pop_r = 1.b1;/if (keep_n == 1 \&\& tx_valid) tx_pop_r = 1\x27b1;/'
mutant "a trap does not drop a kept byte" hart '/task fire/,/endtask/ s/keep_n = 0; .*$//'
mutant "the target loads without keep" rom 's/32.h35000000/32\x27h34000000/'
mutant "the stream refills without keep" rom 's/32.h140ED000/32\x27h140EC000/'

# Bugs both harts share. They still agree with each other, so only the
# textbook rules can tell.
mutant "both harts swap the two clock phases" hart 's/if (c_cpha) sample_lanes;/if (X) sample_lanes;/; s/if (!c_cpha) sample_lanes;/if (c_cpha) sample_lanes;/; s/if (X) sample_lanes;/if (!c_cpha) sample_lanes;/; s/if (!c_cpha) lanes_out;/if (c_cpha) lanes_out;/'
mutant "both harts send the least significant bit first" hart 's/if (c_msb) begin val = tx\[7\]; tx = {tx\[6:0\], 1.b0}; end/if (c_msb) begin val = tx[0]; tx = {1\x27b0, tx[7:1]}; end/; s/rx1 = c_msb ? {rx1\[6:0\], b} : {b, rx1\[7:1\]};/rx1 = c_msb ? {b, rx1[7:1]} : {rx1[6:0], b};/; s/rx0 = c_msb ? {rx0\[6:0\], b} : {b, rx0\[7:1\]};/rx0 = c_msb ? {b, rx0[7:1]} : {rx0[6:0], b};/'

# The witness
mutant "a witness logs nothing" hart 's/if (role == WITNESS) seen_push_r = 1.b1;/if (role == WITNESS) seen_push_r = 1\x27b0;/'
mutant "a witness stores as a receiver does" hart 's/if (role == WITNESS) seen_push_r = 1.b1;/if (1\x27b0) seen_push_r = 1\x27b1;/'
mutant "a witness sends the bits of the target" hart 's/(r != WITNESS) : (r == party);/(r != WITNESS) : (r == party || (r == WITNESS \&\& party == 2\x27d1));/'
mutant "a witness sends the bits of the controller" hart 's/(r != WITNESS) : (r == party);/(r != WITNESS) : (r == party || (r == WITNESS \&\& party == 2\x27d0));/'
mutant "a hart with a queue claims whatever its role" hart 's/if ((base_role == i_owner \&\& tx_valid) || !pin\[i_pin\])/if (tx_valid || !pin[i_pin])/'
mutant "a witness logs the first lane only" hart 's/seen_push2_r = 1.b1;/seen_push2_r = 1\x27b0;/'
mutant "a witness logs the first lane twice" hart 's/push_data2_r = rx1;/push_data2_r = rx0;/'

# The monitor: a wrong idea of SPI must not fit the wire.
mutant "monitor reads on the other clock edge" proof 's/bus\[1\] == (cpha ? cpol : !cpol);/bus[1] == (cpha ? !cpol : cpol);/'
mutant "monitor counts seven bits a byte" proof 's/if (m_n == 3.d7) assert/if (m_n == 3\x27d6) assert/'

# The proof's own assumptions: without each, it must fail.
mutant "a controller queue entry may vanish" proof 's/if (vq_c \&\& !pop_c) assume (valid_c \&\& data_c == dq_c);//'
mutant "a target queue entry may vanish" proof 's/if (vq_t \&\& !pop_t) assume (valid_t \&\& data_t == dq_t);//'
mutant "half periods below 8 ticks allowed" proof 's/assume (HALF >= MINHALF);/assume (HALF >= 11\x27d4);/'
mutant "an undriven CS may bounce" proof 's/(\* anyconst \*) wire        flt_cs;/(* anyseq *) wire flt_cs;/'
mutant "program loaded past the end of memory" proof 's/assume (start <= MAX_START);//'

wait
for i in $(seq 1 "$N"); do cat "$OUT/r$i.txt"; done
