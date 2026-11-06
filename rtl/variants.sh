#!/usr/bin/env bash
# Measure area options on temporary copies. WSL, from rtl/.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
BASE="$(pwd)"
variant() {
    tag="$1"; shift
    dir=$(mktemp -d)
    cp janus_chip.v janus_hart.v latch_map.v area.sh "$dir/"
    (cd "$dir" && sed -i "$@" janus_chip.v && TAG="$tag" bash area.sh delay)
    rm -rf "$dir"
}
variant fifo_all_4 -e 's/parameter LOG = 3/parameter LOG = 2/' &
variant fifo_rx_4 -e 's/janus_fifo #(.W(8)) rx_fifo/janus_fifo #(.W(8), .LOG(2)) rx_fifo/' &
variant fifo_tx_4 -e 's/janus_fifo #(.W(10)) tx_fifo/janus_fifo #(.W(10), .LOG(2)) tx_fifo/' &
variant mem_48 -e 's/wire \[2047:0\] words;/wire [1535:0] words;/' -e 's/for (w = 0; w < 64; w = w + 1)/for (w = 0; w < 48; w = w + 1)/' &
variant mem_56 -e 's/wire \[2047:0\] words;/wire [1791:0] words;/' -e 's/for (w = 0; w < 64; w = w + 1)/for (w = 0; w < 56; w = w + 1)/' &
variant no_rotation -e 's/wire \[7:0\] in = line2\[rot +: 8\];/wire [7:0] in = line;/' -e 's/oe2\[back +: 8\]/oe/' -e 's/ov2\[back +: 8\]/ov/' -e 's/od2\[back +: 8\]/od_mask/' &
wait
