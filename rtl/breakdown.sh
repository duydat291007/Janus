#!/usr/bin/env bash
# Area per block, keeping hierarchy. Run in WSL from rtl/.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/chip"
LIB="$HOME/janus-tools/sg13g2_stdcell_typ_1p20V_25C.lib"
yosys -q -l "$OUT/break.log" -p "
    read_verilog -sv janus_chip.v janus_hart.v
    synth -top tt_um_duydat291007_janus -nofsm
    opt -full
    dfflibmap -liberty $LIB
    abc -liberty $LIB
    opt_clean
    stat -liberty $LIB" > /dev/null 2>&1
grep -E "^=== |Chip area for module|sg13g2_dfrbpq_1$" "$OUT/break.log" | sed 's/ *sg13g2_dfrbpq_1/ flops/; s/Chip area for module//' | cut -c1-70 | tail -24
grep -E "area=" "$OUT/break.log" | head -0
grep -nE 'cell \("?sg13g2_(dlhq_1|dlhrq_1|lgcp_1|mux2_1|mux4_1|dfrbpq_1|dfrbp_1)"?\)' -A3 "$HOME/janus-tools/sg13g2_stdcell_typ_1p20V_25C.lib" | grep -E "cell \(|area" | sed 's/^[0-9]*[:-] *//' | paste - - | cut -c1-60
