#!/usr/bin/env bash
# Lint the shipped sources the way the flow does. Run in WSL from the repo root.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tt_um_duydat291007_janus src/janus_chip.v src/janus_hart.v 2>&1 \
    | grep -E "^%(Warning|Error)" | sed -E 's/-([A-Z0-9_]+):.*/ \1/' | sort | uniq -c | sort -rn | head -14
verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tt_um_duydat291007_janus src/janus_chip.v src/janus_hart.v > /dev/null 2>&1
echo "verilator exit: $?"
which cocotb-config; cocotb-config --version 2>&1 | head -1
cd test && PYTHONPATH=.. timeout 240 make -s 2>&1 | grep -E "PASS|FAIL|TESTS=|rror" | cut -c1-100 | tail -8
