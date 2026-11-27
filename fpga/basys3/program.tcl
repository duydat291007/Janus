# Load the bitstream into a Basys 3 over its USB cable, from the project root:
#   vivado -mode batch -source fpga/basys3/program.tcl
# The board loses it at power-off; it is not written to the flash.
set root [file normalize [file dirname [info script]]/../..]
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a35t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE $root/fpga/build/janus_basys3.bit $dev
program_hw_devices $dev
puts "programmed"
