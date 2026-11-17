#!/usr/bin/env bash
# Can the SPI proof fail? Plant bugs in the program, the hart and the proof's
# own assumptions, and require each one to break it. Run in WSL from rtl/.
# In the sed expressions a dot stands for a quote in a pattern, and \x27 puts
# one in a replacement.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/spi_mut"
rm -rf "$OUT"; mkdir -p "$OUT"
(cd .. && python3 rtl/gen_spi_rom.py "$OUT/rom.vh") > /dev/null || exit 1
cp spi_ind.sby "$OUT/"

# mutant <name> <file to change: rom, hart or proof> <sed expression>
mutant() {
    name="$1"; target="$2"; expr="$3"
    cp "$OUT/rom.vh" "$OUT/spi_rom.vh"; cp janus_hart.v spi_ind.sv "$OUT/"
    case "$target" in
        rom)   file="$OUT/spi_rom.vh"; orig="$OUT/rom.vh" ;;
        hart)  file="$OUT/janus_hart.v"; orig=janus_hart.v ;;
        proof) file="$OUT/spi_ind.sv"; orig=spi_ind.sv ;;
    esac
    sed -i -e "$expr" "$file"
    if cmp -s "$orig" "$file"; then echo "NOT APPLIED $name"; return; fi
    result=$(cd "$OUT" && sby -f spi_ind.sby h8 2>&1 | grep -E "DONE" | sed 's/.*DONE (\([A-Z]*\).*/\1/')
    fail=$(cd "$OUT" && grep -hoE "Assert failed in spi_ind: spi_ind.sv:[0-9]+" spi_ind_h8/engine_0/logfile_*.txt 2>/dev/null | head -1 | sed 's/.*sv://')
    if [ "$result" = "ERROR" ] || [ -z "$result" ]; then echo "NO COMPILE  $name"
    elif [ "$result" = "PASS" ]; then echo "SURVIVED    $name"
    else echo "BROKE PROOF ($result line ${fail:-?}) $name"; fi
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

# The monitor: a wrong idea of SPI must not fit the wire.
mutant "monitor reads on the other clock edge" proof 's/bus\[1\] == (cpha ? cpol : !cpol);/bus[1] == (cpha ? !cpol : cpol);/'
mutant "monitor counts seven bits a byte" proof 's/if (m_n == 3.d7) assert/if (m_n == 3\x27d6) assert/'

# The proof's own assumptions: without each, it must fail.
mutant "a controller queue entry may vanish" proof 's/if (vq_c \&\& !pop_c) assume (valid_c \&\& data_c == dq_c);//'
mutant "a target queue entry may vanish" proof 's/if (vq_t \&\& !pop_t) assume (valid_t \&\& data_t == dq_t);//'
mutant "half periods below 8 ticks allowed" proof 's/assume (HALF >= MINHALF);/assume (HALF >= 11\x27d4);/'
mutant "an undriven CS may bounce" proof 's/(\* anyconst \*) wire        flt_cs;/(* anyseq *) wire flt_cs;/'
mutant "program loaded past the end of memory" proof 's/assume (start <= MAX_START);//'
