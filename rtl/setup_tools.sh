#!/usr/bin/env bash
# Fetch the RTL toolchain and IHP cell library into $HOME. Run inside WSL.
set -euo pipefail

SUITE=oss-cad-suite-linux-x64-20261105.tgz
SUITE_URL=https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-11-05/$SUITE
SUITE_SHA=c64d557848d57fad96a5bea7461e12b3ddfb49514658f7301f7e1a5476128a88
LIB=sg13g2_stdcell_typ_1p20V_25C.lib
LIB_URL=https://raw.githubusercontent.com/IHP-GmbH/IHP-Open-PDK/main/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/$LIB

mkdir -p "$HOME/janus-tools"
cd "$HOME/janus-tools"

if [ ! -x "$HOME/oss-cad-suite/bin/yosys" ]; then
    wget -q -c -O "$SUITE" "$SUITE_URL" || curl -sSL -C - -o "$SUITE" "$SUITE_URL"
    echo "$SUITE_SHA  $SUITE" | sha256sum -c -
    tar -xzf "$SUITE" -C "$HOME"
    rm -f "$SUITE"
fi

[ -f "$LIB" ] || wget -q -O "$LIB" "$LIB_URL" || curl -sSL -o "$LIB" "$LIB_URL"
[ "$(stat -c %s "$LIB")" -gt 1000000 ]

"$HOME/oss-cad-suite/bin/yosys" -V
"$HOME/oss-cad-suite/bin/iverilog" -V | head -1
echo "tools ready"
