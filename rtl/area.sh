#!/usr/bin/env bash
# Area of the chip under one synthesis setting. Usage: bash area.sh <delay|area> [file ...]
# WSL, from rtl/. Extra -D defines come from $DEFS.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/chip"
LIB="$HOME/janus-tools/sg13g2_stdcell_typ_1p20V_25C.lib"
TAG="${TAG:-run}"
if [ "$1" = "delay" ]; then
    SCRIPT="+strash;dch;map,-B,0.9;topo;stime,-p;buffer,-p;upsize;dnsize;stime,-p"
else
    SCRIPT="+strash;dch;map,-a,-B,0.9;topo;stime,-p"
fi
yosys -q -l "$OUT/$TAG.log" -p "
    read_liberty -lib $LIB
    read_verilog -sv ${DEFS:-} janus_chip.v janus_hart.v
    synth -top tt_um_duydat291007_janus -flatten -nofsm
    opt -full; share; opt
    techmap -map latch_map.v
    dfflibmap -liberty $LIB
    abc -liberty $LIB -D 20000 -showtmp -script $SCRIPT
    opt_clean
    stat -liberty $LIB" > /dev/null 2>&1
echo "$TAG: $(grep -E "Chip area" "$OUT/$TAG.log" | tail -1 | awk '{print $NF}') um2, $(grep -E " cells$" "$OUT/$TAG.log" | tail -1 | awk '{print $1}') cells, $(grep -E "Delay =" "$OUT/$TAG.log" | tail -1 | sed 's/.*Delay = *//' | cut -d' ' -f1) ps"
