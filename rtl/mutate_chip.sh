#!/usr/bin/env bash
# Can the chip tests fail? Plant bugs in the chip top. WSL, from rtl/, after chip.sh test.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/chip"

# Usage: mutant name sed-expression [file]. The file is janus_chip.v unless named.
mutant() {
    name="$1"; expr="$2"; file="${3:-janus_chip.v}"
    sed -e "$expr" "$file" > "$OUT/mut.v"
    if cmp -s "$file" "$OUT/mut.v"; then echo "NOT APPLIED $name"; return; fi
    if [ "$file" = janus_chip.v ]; then srcs="$OUT/mut.v janus_hart.v"; else srcs="janus_chip.v $OUT/mut.v"; fi
    iverilog -g2012 -o "$OUT/mut.vvp" tb_chip.v $srcs 2> /dev/null \
        || { echo "NO COMPILE  $name"; return; }
    caught=0
    for script in "$OUT"/scripts/*.hex; do
        vvp "$OUT/mut.vvp" "+script=$script" | grep -q "^OK" || caught=$((caught + 1))
    done
    [ "$caught" -gt 0 ] && echo "CAUGHT($caught) $name" || echo "SURVIVED    $name"
}

mutant "FIFO shows popped entries" 's/assign dout = mem\[rp_next\[LOG-1:0\]\];/assign dout = mem[rp[LOG-1:0]];/'
mutant "FIFO empty ignores a pop" 's/assign empty = clear || wp == rp_next;/assign empty = wp == rp;/'
mutant "loopback does nothing" 's/assign line = loopback ? ~low : uio_in;/assign line = uio_in;/'
mutant "pins read loopback always" 's/assign line = loopback ? ~low : uio_in;/assign line = ~low;/'
mutant "drive rotation wrong" 's/wire \[3:0\] back = 4.d8 - rot;/wire [3:0] back = 4'"'"'d0;/'
mutant "input rotation wrong" 's/wire \[7:0\] in = line2\[rot +: 8\];/wire [7:0] in = line2[0 +: 8];/'
mutant "start address ignored" 's/\.reset_pc(start)/.reset_pc(6'"'"'d0)/'
mutant "push-pull high not driven" 's/assign uio_oe = low | high;/assign uio_oe = low;/'
mutant "second witness lane lost" 's/pending_valid <= 1.b1;/;/'
mutant "read stream not reloaded" 's/else reload <= 1.b1;.*/else reload <= 1'"'"'b0;/'
mutant "status reads flags wrongly" 's/if (index == 1) miso_sr <= h ? flags1 : flags0;/if (index == 1) miso_sr <= h ? flags0 : flags1;/'
mutant "hart 1 reads hart 0" 's/wire \[7:0\] rd_head = h ? (empty1 ? 8.d0 : head1) : /wire [7:0] rd_head = /'
mutant "empty FIFO returns memory" 's/(empty0 ? 8.d0 : head0)/head0/'
mutant "open-drain mask ignored" 's/assign high = oe_c \& ov_c \& ~od_c;/assign high = oe_c \& ov_c;/'
mutant "transmit control bits dropped" 's/\.tx_din({a0\[1:0\], in_byte})/.tx_din({2'"'"'b00, in_byte})/'
mutant "program word byte order" 's/wire \[31:0\]  wdata = {b0, b1, b2, shift};/wire [31:0]  wdata = {shift, b2, b1, b0};/'
mutant "write pulse hits every word" 's/wire en = wpulse \&\& waddr == w;/wire en = wpulse;/'
mutant "hart 1 fetches with hart 0 pc" 's/{32{sel1\[f\]}}/{32{sel0[f]}}/'
mutant "fetch also reads the next word" 's/{32{sel0\[f\]}}/{32{sel0[f] | sel0[(f + 1) % 64]}}/'
mutant "debug frame reads the other hart's counter" 's/miso_sr <= {2.b00, h ? pc1 : pc0};/miso_sr <= {2'"'"'b00, h ? pc0 : pc1};/'
mutant "debug frame captures the other hart" 's/snap <= h ? {role1, state1, ins1} : {role0, state0, ins0};/snap <= h ? {role0, state0, ins0} : {role1, state1, ins1};/'
mutant "debug frame drops the role" 's/3.d1: miso_sr <= {snap\[37:36\], 2.b00, snap\[35:32\]};/3'"'"'d1: miso_sr <= {4'"'"'b0000, snap[35:32]};/'
mutant "debug frame drops the state" 's/3.d1: miso_sr <= {snap\[37:36\], 2.b00, snap\[35:32\]};/3'"'"'d1: miso_sr <= {snap[37:36], 6'"'"'d0};/'
mutant "debug frame swaps two word bytes" 's/3.d2: miso_sr <= snap\[31:24\];/3'"'"'d2: miso_sr <= snap[23:16];/'
mutant "debug frame never captures" 's/snap <= h ? {role1, state1, ins1} : {role0, state0, ins0};/;/'
# The queue's own test, tb_fifo.v, must be able to fail too.
fifo_mutant() {
    name="$1"; expr="$2"
    sed -e "$expr" janus_chip.v > "$OUT/mut.v"
    if cmp -s janus_chip.v "$OUT/mut.v"; then echo "NOT APPLIED $name"; return; fi
    iverilog -g2012 -s tb_fifo -o "$OUT/mut.vvp" tb_fifo.v "$OUT/mut.v" janus_hart.v 2> /dev/null \
        || { echo "NO COMPILE  $name"; return; }
    vvp "$OUT/mut.vvp" | grep -q "^OK" && echo "SURVIVED    $name" || echo "CAUGHT(1) $name"
}
fifo_mutant "full queue refuses a push with a pop" 's/wire        take = push \&\& (!full || pop);/wire        take = push \&\& !full;/'
fifo_mutant "full queue takes a push with no pop" 's/wire        take = push \&\& (!full || pop);/wire        take = push;/'
fifo_mutant "queue full one entry early" 's/assign full = (wp ^ rp) == {1.b1, {LOG{1.b0}}};/assign full = wp - rp == {1'"'"'b0, {LOG{1'"'"'b1}}};/'

mutant "one-hot pc a tick late" 's/pc_sel <= 64.d1 << pc_r;/pc_sel <= 64'"'"'d1 << pc;/' janus_hart.v
