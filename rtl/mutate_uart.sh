#!/usr/bin/env bash
# Can the UART proof fail? Plant bugs in the program, the hart and the proof's
# own assumptions, and require each one to break it. Run in WSL from rtl/.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/uart_mut"
rm -rf "$OUT"; mkdir -p "$OUT"
(cd .. && python3 rtl/gen_uart_rom.py "$OUT/rom.vh") > /dev/null || exit 1
cp uart_ind.sby "$OUT/"

# mutant <name> <file to change: rom, hart or proof> <sed expression>
mutant() {
    name="$1"; target="$2"; expr="$3"
    cp "$OUT/rom.vh" "$OUT/uart_rom.vh"; cp janus_hart.v uart_ind.sv "$OUT/"
    case "$target" in
        rom)   file="$OUT/uart_rom.vh"; orig="$OUT/rom.vh" ;;
        hart)  file="$OUT/janus_hart.v"; orig=janus_hart.v ;;
        proof) file="$OUT/uart_ind.sv"; orig=uart_ind.sv ;;
    esac
    sed -i -e "$expr" "$file"
    if cmp -s "$orig" "$file"; then echo "NOT APPLIED $name"; return; fi
    result=$(cd "$OUT" && sby -f uart_ind.sby b8 2>&1 | grep -E "DONE" | sed 's/.*DONE (\([A-Z]*\).*/\1/')
    fail=$(cd "$OUT" && grep -hoE "Assert failed in uart_ind: uart_ind.sv:[0-9]+" uart_ind_b8/engine_0/logfile_*.txt 2>/dev/null | head -1 | sed 's/.*sv://')
    if [ "$result" = "ERROR" ] || [ -z "$result" ]; then echo "NO COMPILE  $name"
    elif [ "$result" = "PASS" ]; then echo "SURVIVED    $name"
    else echo "BROKE PROOF ($result line ${fail:-?}) $name"; fi
}

# The program
mutant "no idle bit before the first frame, as the program was" rom "s/6'd1: uart_word = .*/6'd1: uart_word = 32'h00200000;/"
mutant "start bit does not sync the receiver" rom "s/32'h10410000/32'h10400000/"
mutant "stop bit sent low" rom "s/32'h10600000/32'h10400000/"
mutant "seven data bits" rom "s/32'h100E0000/32'h100C0000/"
mutant "sender stores the byte, not the receiver" rom "s/32'h44000000/32'h40000000/"
mutant "loop jumps past the claim" rom "s/32'h50000002/32'h50000003/"
mutant "no claim: the sender does not wait for a byte" rom "s/32'h20000000/32'h00200000/"

# The hart
mutant "sample too early" hart 's/if (is_before(now, edge_t + (i_dwell >> 1))) begin/if (is_before(now, edge_t + (i_dwell >> 3))) begin/'
mutant "sync input lag wrong" hart 's/edge_t = now - 12'"'"'d2;/edge_t = now - 12'"'"'d1;/'
mutant "owner drives inverted bit" hart 's/put(i_pin, lvl, i_brk);/put(i_pin, !lvl, i_brk);/'
mutant "listener samples the wrong pin" hart 's/raw = pin\[i_pin\];/raw = role == 1 ? pin[1] : pin[i_pin];/'
mutant "pin seen one tick early" hart 's/^ *pin = s1;$/pin = wire_in[3:0];/'
mutant "claim ignores a falling line" hart 's/if ((base_role == i_owner \&\& tx_valid) || !pin\[i_pin\]) begin/if (base_role == i_owner \&\& tx_valid) begin/'
mutant "claim does not wait for a byte" hart 's/if ((base_role == i_owner \&\& tx_valid) || !pin\[i_pin\]) begin/if (base_role == i_owner || !pin[i_pin]) begin/'
mutant "claim leaves on a high line" hart 's/if ((base_role == i_owner \&\& tx_valid) || !pin\[i_pin\]) begin/if ((base_role == i_owner \&\& tx_valid) || pin[i_pin]) begin/'
mutant "load leaves the entry in the queue" hart '/OP_LOAD: begin/,/OP_STORE: begin/ s/tx_pop_r = 1'"'"'b1;//'
mutant "load takes a wrong byte" hart '/OP_LOAD: begin/,/OP_STORE: begin/ s/tx = tx_data;/tx = tx_data ^ 8'"'"'h01;/'
mutant "store pushes nothing" hart 's/if (is_mine(i_party, role)) rx_push_r = 1'"'"'b1;/if (is_mine(i_party, role)) rx_push_r = 1'"'"'b0;/'
mutant "store pushes the wrong lane" hart 's/push_data_r = ins\[25\] ? rx1 : rx0;/push_data_r = ins[25] ? rx0 : rx1;/'
mutant "sender shifts out MSB first" hart 's/else       begin val = tx\[0\]; tx = {1'"'"'b0, tx\[7:1\]}; end/else       begin val = tx[7]; tx = {tx[6:0], 1'"'"'b0}; end/'
mutant "receiver shifts in the other way" hart 's/else      rx0 = c_msb ? {rx0\[6:0\], b} : {b, rx0\[7:1\]};/else      rx0 = (c_msb || role == 1) ? {rx0[6:0], b} : {b, rx0[7:1]};/'
mutant "owner skips readback" hart 's/if (!src_const) shift_in(1'"'"'b0, seen);/if (!src_const \&\& !cur_mine) shift_in(1'"'"'b0, seen);/'
mutant "set does not drive" hart 's/else drive(i_pin, i_src\[0\]);/;/'
mutant "every hart thinks the bit is its own" hart 's/cur_mine = is_mine(i_owner, role);/cur_mine = 1'"'"'b1;/'
mutant "listener flags a good constant bit" hart 's/src_const \&\& seen != src_eff\[0\] \&\& (inserted/src_const \&\& seen == src_eff[0] \&\& (inserted/'
mutant "jump not taken" hart 's/0: taken = 1'"'"'b1;/0: taken = 1'"'"'b0;/'
mutant "listener timing drifts" hart 's/edge_t = edge_t + i_dwell;/edge_t = edge_t + i_dwell + (role == 1);/'
mutant "every bit one tick too long, on both sides" hart 's/edge_t = edge_t + i_dwell;/edge_t = edge_t + i_dwell + 1'"'"'b1;/'
mutant "no long-idle fix" hart 's/if (s != S_MID \&\& is_before(edge_t, now)) edge_t = now;//'
mutant "owner loses on any low bit" hart 's/if (c_lose != LOSE_NONE \&\& val \&\& !seen \&\& !faulty)/if (c_lose != LOSE_NONE \&\& !seen \&\& !faulty)/'
mutant "sync only checks the level (expected to survive)" hart 's/ \&\& armed\[i_pin\] != val//'

# The monitor: a wrong idea of the frame must not fit the wire.
mutant "monitor reads the data bits in the other order" proof 's/cur\[m_cell\[2:0\] - 3'"'"'d1\]/cur[3'"'"'d0 - m_cell[2:0]]/'
mutant "monitor counts cells one sample short" proof 's/end else if (m_q == BIT - 1'"'"'b1) begin/end else if (m_q == BIT - 2'"'"'d2) begin/'

# The proof's own assumptions: without each, it must fail.
mutant "a queue entry may vanish" proof 's/if (v_q \&\& !pop_a) assume (valid_a);//'
# Addresses wrap, so this placement works too; the assembler refuses it anyway.
mutant "program loaded past the end of memory (expected to survive)" proof 's/assume (start <= MAX_START);//'
mutant "bit times below 8 ticks allowed" proof 's/assume (BIT >= MINBIT);/assume (BIT >= 11'"'"'d4);/'
