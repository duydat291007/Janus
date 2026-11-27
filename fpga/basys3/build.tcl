# Build the Basys 3 bitstream with Vivado, from the project root:
#   vivado -mode batch -source fpga/basys3/build.tcl
# It writes fpga/build/janus_basys3.bit and the utilisation and timing reports.
# Needs Python on the PATH, to write the FPGA copy of the chip's top level.
set root [file normalize [file dirname [info script]]/../..]
set out  $root/fpga/build
file mkdir $out
cd $root
exec python fpga/fpga_source.py $out/janus_chip_fpga.v

read_verilog $out/janus_chip_fpga.v $root/src/janus_hart.v \
    $root/fpga/basys3/uart_spi_bridge.v $root/fpga/basys3/janus_basys3.v
read_xdc $root/fpga/basys3/basys3.xdc

synth_design -top janus_basys3 -part xc7a35tcpg236-1
opt_design
place_design
route_design
report_utilization -file $out/utilization.txt
report_timing_summary -file $out/timing.txt
write_bitstream -force $out/janus_basys3.bit
puts "wrote $out/janus_basys3.bit"
