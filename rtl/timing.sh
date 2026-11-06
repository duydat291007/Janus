#!/usr/bin/env bash
# Synthesize for a target period, then report area and static timing.
# Pre-layout: no wire load or clock tree. Run in WSL from rtl/.
set -uo pipefail
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build"
LIB="$HOME/janus-tools/sg13g2_stdcell_typ_1p20V_25C.lib"
PERIOD_PS="${1:-20000}"
mkdir -p "$OUT"

yosys -q -l "$OUT/timing.log" -p "
    read_verilog -sv janus_hart.v
    synth -top janus_hart -flatten -nofsm
    opt -full; share; opt
    dfflibmap -liberty $LIB
    abc -liberty $LIB -D $PERIOD_PS -showtmp -script +strash;dch;map,-B,0.9;topo;stime,-p;buffer,-p;upsize;dnsize;stime,-p
    opt_clean
    stat -liberty $LIB
    tee -o $OUT/ltp.txt ltp -noff
    write_verilog -noattr -noexpr -nohex $OUT/hart_mapped.v" > /dev/null 2>&1

grep -E "Chip area|cells$" "$OUT/timing.log" | tail -2
grep -E "Delay =" "$OUT/timing.log" | tail -2 | cut -c1-130

if command -v sta > /dev/null; then
    cat > "$OUT/sta.tcl" <<EOF
read_liberty $LIB
read_verilog $OUT/hart_mapped.v
link_design janus_hart
create_clock -name clk -period $(awk "BEGIN{print $PERIOD_PS/1000}") [get_ports clk]
set_input_delay 0 -clock clk [all_inputs]
set_output_delay 0 -clock clk [all_outputs]
report_checks -path_delay max -format short
report_wns
report_tns
exit
EOF
    sta -no_init "$OUT/sta.tcl" 2>&1 | tail -12
else
    echo "sta not available"
fi
