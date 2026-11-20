#!/usr/bin/env bash
# All planted-bug sets and proof tasks on the current design. WSL, from rtl/.
OUT="$HOME/janus-tools/build"
bash mutate_chip.sh > "$OUT/f_chip.txt" 2>&1 &
bash mutate_rtl.sh > "$OUT/f_rtl.txt" 2>&1 &
bash mutate_proof.sh > "$OUT/f_proof.txt" 2>&1 &
bash mutate_uart.sh > "$OUT/f_uart.txt" 2>&1 &
bash mutate_spi.sh > "$OUT/f_spi.txt" 2>&1 &
bash mutate_onewire.sh > "$OUT/f_onewire.txt" 2>&1 &
bash mutate_i2c.sh > "$OUT/f_i2c.txt" 2>&1 &
bash mutate_can.sh > "$OUT/f_can.txt" 2>&1 &
wait
echo "--- chip bugs"; echo "caught $(grep -c CAUGHT "$OUT/f_chip.txt")"; grep -vE "^CAUGHT" "$OUT/f_chip.txt" | cut -c1-80
echo "--- hart bugs"; head -1 "$OUT/f_rtl.txt"; echo "caught $(grep -c CAUGHT "$OUT/f_rtl.txt")"; grep -vE "^CAUGHT|^baseline" "$OUT/f_rtl.txt" | cut -c1-80
echo "--- proof bugs"; echo "broke $(grep -c BROKE "$OUT/f_proof.txt")"; grep -vE "^BROKE" "$OUT/f_proof.txt" | cut -c1-80
echo "--- UART proof bugs"; echo "broke $(grep -c BROKE "$OUT/f_uart.txt")"; grep -vE "^BROKE" "$OUT/f_uart.txt" | cut -c1-80
for t in d4 d3 stuffcover cover; do
    echo "--- $t"; timeout 300 bash prove_ind.sh $t 2>&1 | grep -E "DONE" | sed 's/.*\] *//' | cut -c1-40
done
echo "--- SPI proof bugs"; echo "broke $(grep -c BROKE "$OUT/f_spi.txt")"; grep -vE "^BROKE" "$OUT/f_spi.txt" | cut -c1-80
echo "--- SPI proof"; timeout 900 bash prove_spi.sh 2>&1 | grep -E "DONE" | sed 's/.*\] *//' | cut -c1-40
echo "--- SPI harness simulation"; bash sim_spi.sh 2>&1 | tail -3
echo "--- 1-Wire proof bugs"; echo "broke $(grep -c BROKE "$OUT/f_onewire.txt")"; grep -vE "^BROKE" "$OUT/f_onewire.txt" | cut -c1-80
echo "--- 1-Wire proof"; timeout 900 bash prove_onewire.sh 2>&1 | grep -E "DONE" | sed 's/.*\] *//' | cut -c1-40
echo "--- 1-Wire harness simulation"; bash sim_onewire.sh 2>&1 | tail -3
echo "--- I2C proof bugs"; echo "broke $(grep -c BROKE "$OUT/f_i2c.txt")"; grep -vE "^BROKE" "$OUT/f_i2c.txt" | cut -c1-80
echo "--- I2C proof"; timeout 3600 bash prove_i2c.sh 2>&1 | grep -E "DONE" | sed 's/.*\] *//' | cut -c1-40
echo "--- I2C harness simulation"; bash sim_i2c.sh 2>&1 | tail -3
echo "--- CAN proof bugs"; echo "broke $(grep -c BROKE "$OUT/f_can.txt")"; grep -vE "^BROKE" "$OUT/f_can.txt" | cut -c1-80
echo "--- CAN proof"; timeout 7200 bash prove_can.sh 2>&1 | grep -E "DONE" | sed 's/.*\] *//' | cut -c1-40
echo "--- CAN harness simulation"; bash sim_can.sh 2>&1 | tail -3
echo "--- CAN with two senders"; bash sim_can_arb.sh 2>&1 | tail -3
echo "--- UART proof"; timeout 2400 bash prove_uart.sh 2>&1 | grep -E "DONE" | sed 's/.*\] *//' | cut -c1-40
echo "--- UART harness simulation"; bash sim_uart.sh 2>&1 | tail -3
L="$HOME/janus-tools/build/ind"
echo "free cover reached: $(grep -cE "Reached cover" $L/lockstep_ind_cover/engine_0/logfile.txt)"
echo "stuff cover reached: $(grep -cE "Reached cover" $L/lockstep_ind_stuffcover/engine_0/logfile.txt)"
