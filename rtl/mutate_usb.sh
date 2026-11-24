#!/usr/bin/env bash
# Can the USB proof fail? Plant bugs in the program, the hart and the proof's
# own monitor and assumptions, and require each one to break it. Run in WSL
# from rtl/. In the sed expressions a dot stands for a quote in a pattern,
# and \x27 puts one in a replacement. 9F800000 is a mode word that writes
# nothing.
export PATH="$HOME/oss-cad-suite/bin:$PATH"
OUT="$HOME/janus-tools/build/usb_mut"
rm -rf "$OUT"; mkdir -p "$OUT"
(cd .. && python3 rtl/gen_usb_rom.py "$OUT/rom.vh") > /dev/null || exit 1

# mutant <name> <file to change: rom, hart or proof> <sed expression>
# Each runs in its own folder, eight at a time; the results print in order.
N=0
mutant() {
    N=$((N + 1))
    while [ "$(jobs -rp | wc -l)" -ge 8 ]; do wait -n; done
    one "$N" "$@" > "$OUT/r$N.txt" &
}
# Each bug is first simulated: the proof's harness with the bug in it, on
# random inputs that keep the proof's assumptions, as sim_usb.sh runs it.
# An assertion that fails on a real run means a claim is false, so the proof
# cannot pass. A failed assumption does not count. Bugs the simulation does
# not catch go to the solver.
SIMS="11:1: 12:2:+noise 16:3: 16:4:+noise 23:5: 13:6:+noise 50:7: 100:8: 16:9:+race"
one() {
    D="$OUT/m$1"; name="$2"; target="$3"; expr="$4"
    mkdir -p "$D"; cp "$OUT/rom.vh" "$D/usb_rom.vh"; cp janus_hart.v usb_ind.sv usb_ind.sby "$D/"
    case "$target" in
        rom)   file="$D/usb_rom.vh"; orig="$OUT/rom.vh" ;;
        hart)  file="$D/janus_hart.v"; orig=janus_hart.v ;;
        proof) file="$D/usb_ind.sv"; orig=usb_ind.sv ;;
    esac
    sed -i -e "$expr" "$file"
    if cmp -s "$orig" "$file"; then echo "NOT APPLIED $name"; return; fi
    if ! iverilog -g2012 -DFORMAL -DUSB_SIM -I "$D" -s tb_usb_ind -o "$D/sim.vvp" \
            tb_usb_ind.v "$D/usb_ind.sv" "$D/janus_hart.v" 2> "$D/iv.log"; then
        echo "NO COMPILE  $name"; rm -rf "$D"; return
    fi
    skip=$(grep -nE "assume \(" "$D/usb_ind.sv" | cut -d: -f1 | paste -sd'|')
    for bs in $SIMS; do
        bit=${bs%%:*}; rest=${bs#*:}; seed=${rest%%:*}; extra=${rest#*:}
        line=$(timeout 600 vvp "$D/sim.vvp" +bit=$bit +seed=$seed $extra +trans=12 +ticks=600000 2>&1 \
               | grep -oE "^ERROR: [^ ]*usb_ind.sv:[0-9]+" | sed 's/.*sv://' | grep -vxE "$skip" | head -1)
        if [ -n "$line" ]; then echo "BROKE PROOF (simulation, bit $bit $extra, line $line) $name"; rm -rf "$D"; return; fi
    done
    (cd "$D" && timeout -k 30 10800 sby -f usb_ind.sby d4 > sby.txt 2>&1); code=$?
    for p in $(pgrep bitwuzla); do
        case "$(readlink /proc/$p/cwd)" in "$D"*) kill "$p" ;; esac
    done
    result=$(grep -E "DONE" "$D/sby.txt" | sed 's/.*DONE (\([A-Z]*\).*/\1/')
    fail=$(grep -hoE "Assert failed in [a-zA-Z_.]+: usb_ind.sv:[0-9]+" "$D"/usb_ind_d4/engine_0/logfile*.txt 2>/dev/null | head -1 | sed 's/.*sv://')
    if [ "$code" = 124 ]; then echo "TIMEOUT     $name"
    elif [ "$result" = "ERROR" ] || [ -z "$result" ]; then echo "NO COMPILE  $name"
    elif [ "$result" = "PASS" ]; then echo "SURVIVED    $name"
    else echo "BROKE PROOF ($result line ${fail:-?}) $name"; fi
    rm -rf "$D"
}

# The program
mutant "no NRZI" rom '/6.d0:/ s/32.h97000001/32\x27h97000000/'
mutant "DP not driven as DM's complement" rom '/6.d1:/ s/32.h96800008/32\x27h9F800000/'
mutant "no bit stuffing" rom '/6.d10:/ s/32.h91000016/32\x27h9F800000/'
mutant "a 0 stuffed after seven 1s" rom '/6.d10:/ s/32.h91000016/32\x27h91000017/'
mutant "stuffing after six equal bits of either value" rom '/6.d10:/ s/32.h91000016/32\x27h91000006/'
mutant "the chip's CRC16 sent as it is, not inverted" rom '/6.d6:/ s/32.h98809555/32\x27h9F800000/'
mutant "the wrong residual" rom '/6.d5:/ s/32.h9780800D/32\x27h97808005/'
mutant "the CRC16 not restarted after the PID" rom '/6.d20:/ s/32.h92000030/32\x27h9F800000/'
mutant "a data PID read from its bit 0 alone" rom '/6.d16:/ s/32.h52000012 + start/32\x27h9F800000/'
mutant "a data PID read from its bit 1 alone" rom '/6.d17:/ s/32.h88014000/32\x27h88018000/'
mutant "the branch on the PID's bit 1 inverted" rom '/6.d16:/ s/32.h52000012/32\x27h54000012/'
mutant "every packet treated as a data packet" rom '/6.d33:/ s/32.h56000009 + start/32\x27h9F800000/'
mutant "a handshake other than ACK" rom '/6.d35:/ s/32.h360000D2/32\x27h360000D3/'
mutant "the handshake's end of packet one bit long" rom '/6.d41:/ s/32.h12822000/32\x27h12802000/'
mutant "no turnaround bit" rom '/6.d32:/ s/32.h12600000 | bit_t/32\x27h9F800000/'
mutant "no second J after the handshake" rom '/6.d43:/ s/32.h12600000 | bit_t/32\x27h9F800000/'
mutant "the counter left at 1 after the handshake" rom '/6.d44:/ s/32.h58000009 + start/32\x27h9F800000/'
mutant "the device answers a bad CRC16" rom '/6.d34:/ s/32.h5A00002C + start/32\x27h9F800000/'
mutant "a hold trap after 2 bit times" rom 's/usb_hold_ticks = 16.d18 \* bit_t;/usb_hold_ticks = 16\x27d2 * bit_t;/'
# With a device that always answers, the hold trap only ever finds nothing
# due, so no claim needs it; without it the hold counter's invariant fails.
mutant "no hold trap" rom 's/usb_hold = 16.hDA60/usb_hold = 16\x27h5A60/'

# The hart
mutant "the NRZI sender codes a 1 as a change" hart 's/lvl = (c_nrzi \&\& !i_brk) ? pin\[i_pin\] ^ !val : val;/lvl = (c_nrzi \&\& !i_brk) ? pin[i_pin] ^ val : val;/'
mutant "the NRZI listener decodes a change as a 1" hart 's/seen = (c_nrzi \&\& !i_brk) ? raw == armed\[i_pin\] : raw;/seen = (c_nrzi \&\& !i_brk) ? raw != armed[i_pin] : raw;/'
mutant "a listener never jumps on a break" hart 's/if (c_pair_en \&\& broke \&\& !cur_mine \&\& !i_brk \&\& c_brk_en) begin/if (1\x27b0) begin/'
mutant "ones-only stuffing stuffs after 0s too" hart 's/if (run_len == c_stuff \&\& (coded || !c_ones)) begin/if (run_len == c_stuff) begin/'
mutant "the pair pin driven equal, not complemented" hart 's/if (c_pair_en) drive(c_pair, brk ? v : !v);/if (c_pair_en) drive(c_pair, v);/'
mutant "an NRZI sync bit waits for the level it has" hart 's/val = (c_nrzi \&\& !i_brk) ? !armed\[i_pin\] : src_eff\[0\];/val = (c_nrzi \&\& !i_brk) ? armed[i_pin] : src_eff[0];/'
mutant "the CRC restarts at 0, not all ones" hart 's/crc = c_init1 ? ~(16.hFFFF << c_width) : 16.d0;/crc = 16\x27d0;/'
mutant "a counter from received bits ignores its mask" hart 's/masked = rx0 \& ins\[15:8\];/masked = rx0;/'
# With a correct sender a break bit is always SE0, so this one survives.
mutant "a listener does not check a break bit" hart 's/if (!i_strm \&\& !broke)/if (1\x27b0)/'

# The monitor: a wrong idea of USB must not fit the wire.
mutant "monitor's NRZI: a 1 is a change" proof 's/wire       m_b = m_s\[1\] == m_lvl;/wire       m_b = m_s[1] != m_lvl;/'
mutant "monitor's residual is 0x8005" proof 's/if (m_crc == 16.h800D) m_due <= 1.b1;/if (m_crc == 16\x27h8005) m_due <= 1\x27b1;/'
mutant "monitor expects the queue's byte even when it is empty" proof 's/if (a_ld) g_tk <= valid_a ? data_a : 8.hFF;/if (a_ld) g_tk <= data_a;/'
mutant "monitor takes a PID with bit 1 set as data" proof 's/m_data <= m_sh\[7\] \&\& m_b;/m_data <= m_b;/'

# The proof's own assumption: without it, it must fail.
mutant "bit times of 10 ticks allowed" proof 's/assume (BIT >= MINBIT);/assume (BIT >= 11\x27d10);/'

wait
for i in $(seq 1 "$N"); do cat "$OUT/r$i.txt"; done
