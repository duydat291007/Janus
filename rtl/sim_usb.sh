#!/usr/bin/env bash
# Simulate the USB proof harness on random inputs: the same assertions as the
# proof, over long runs at many bit times, with a separate scoreboard.
# WSL, from rtl/. With arguments it runs once and prints a trace:
#   bash sim_usb.sh BIT TICKS [SEED] [more plusargs]
set -uo pipefail
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="${USB_SIM_OUT:-$HOME/janus-tools/build/usb_sim}"
mkdir -p "$OUT"
[ -f "$OUT/usb_rom.vh" ] && [ -n "${USB_SIM_KEEP_ROM:-}" ] \
    || (cd .. && python3 rtl/gen_usb_rom.py "$OUT/usb_rom.vh") > /dev/null || exit 1
iverilog -g2012 -DFORMAL -DUSB_SIM -I "$OUT" -s tb_usb_ind -o "$OUT/sim.vvp" \
    tb_usb_ind.v usb_ind.sv "${USB_SIM_HART:-janus_hart.v}" 2> "$OUT/iv.log" \
    || { tail -20 "$OUT/iv.log"; exit 1; }
if [ "$#" -ge 2 ]; then
    bit=$1 n=$2 s=${3:-1}
    shift 2; [ "$#" -ge 1 ] && shift
    vvp "$OUT/sim.vvp" +bit=$bit +trace=$n +ticks=$n +seed=$s "$@" | cut -c1-260
    exit 0
fi
runs=0; bad=0; trans=0; acks=0; nbad=0; late=0; stored=0; ticks=0; races=0; missed=0; seed=0
# one BIT [plusargs]: one run, added to the totals.
one() {
    local bit=$1 out
    shift
    seed=$((seed + 1))
    out=$(vvp "$OUT/sim.vvp" +bit=$bit +seed=$seed "$@" | grep -E "^(OK|MISMATCH|ERROR)")
    runs=$((runs + 1))
    if [ "$(echo "$out" | grep -c "^OK")" = 1 ] && [ "$(echo "$out" | grep -cE "^(MISMATCH|ERROR)")" = 0 ]; then
        set -- $out
        trans=$((trans + $5)); acks=$((acks + $9)); nbad=$((nbad + ${11})); late=$((late + ${13}))
        stored=$((stored + ${15})); ticks=$((ticks + ${17})); races=$((races + ${19})); missed=$((missed + ${21}))
    else
        bad=$((bad + 1))
        [ "$bad" -le 4 ] && echo "FAIL bit $bit seed $seed $*: $(echo "$out" | head -3 | tr '\n' ';' | cut -c1-200)"
    fi
}
for bit in 11 11 12 13 14 15 16 16 17 24 33 50 100 217 1000 2047; do
    for rep in 1 2; do one $bit +trans=20 +ticks=4000000; done
done
for bit in 11 12 16 23 64; do one $bit +noise +trans=30 +ticks=3000000; done
# Each packet held back to start on the tick the device's hold trap fires.
for bit in 11 12 16 23 50; do one $bit +race +trans=6 +ticks=1500000; done
# No device: every hart counts each handshake that does not come.
for bit in 11 12 13 16 17 24 50 217 2047; do one $bit +nodev +trans=20 +ticks=4000000; done
for bit in 11 16 23; do one $bit +nodev +noise +trans=30 +ticks=3000000; done
for bit in 11 16 50; do one $bit +nodev +race +trans=6 +ticks=1500000; done
echo "usb sim: $runs runs, $bad failed, $trans data packets ($nbad with a bad CRC16, $late queued late), $acks answered, $missed never answered, $stored bytes stored, $races started on the device's trap tick, $ticks ticks"
[ "$bad" -eq 0 ] && [ "$trans" -gt 0 ] || exit 1
