#!/usr/bin/env bash
# Synthesize with Yosys's default flow, FSM extraction included, as the real
# flow does. Proves the shipped sources do not depend on local workarounds.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
cd "$(dirname "$0")/../src"
start=$(date +%s)
timeout 600 yosys -q -l /tmp/default_synth.log -p "
    read_verilog -sv janus_chip.v janus_hart.v
    synth -top tt_um_duydat291007_janus -flatten
    stat" > /dev/null 2>&1
rc=$?
echo "exit $rc after $(( $(date +%s) - start ))s"
grep -E "Number of cells|Extracting FSM|fsm_encoding" /tmp/default_synth.log | tail -4
grep -cE "transition:" /tmp/default_synth.log
