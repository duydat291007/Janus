# Janus on a Digilent Basys 3. Pin names from Digilent's Basys-3-Master.xdc;
# check them against your board's reference manual before the first build.

set_property -dict {PACKAGE_PIN W5 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -name clk100 -period 10.00 [get_ports clk]
# The chip's 25 MHz clock: the 100 MHz one divided by 4 in janus_basys3.v.
create_generated_clock -name clk25 -source [get_ports clk] -divide_by 4 [get_pins div_reg[1]/Q]

set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports btnC]

# Switches: only 15 is used (up: the host port is on Pmod JB).
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {sw[0]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {sw[1]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports {sw[2]}]
set_property -dict {PACKAGE_PIN W17 IOSTANDARD LVCMOS33} [get_ports {sw[3]}]
set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVCMOS33} [get_ports {sw[4]}]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports {sw[5]}]
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports {sw[6]}]
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports {sw[7]}]
set_property -dict {PACKAGE_PIN V2  IOSTANDARD LVCMOS33} [get_ports {sw[8]}]
set_property -dict {PACKAGE_PIN T3  IOSTANDARD LVCMOS33} [get_ports {sw[9]}]
set_property -dict {PACKAGE_PIN T2  IOSTANDARD LVCMOS33} [get_ports {sw[10]}]
set_property -dict {PACKAGE_PIN R3  IOSTANDARD LVCMOS33} [get_ports {sw[11]}]
set_property -dict {PACKAGE_PIN W2  IOSTANDARD LVCMOS33} [get_ports {sw[12]}]
set_property -dict {PACKAGE_PIN U1  IOSTANDARD LVCMOS33} [get_ports {sw[13]}]
set_property -dict {PACKAGE_PIN T1  IOSTANDARD LVCMOS33} [get_ports {sw[14]}]
set_property -dict {PACKAGE_PIN R2  IOSTANDARD LVCMOS33} [get_ports {sw[15]}]

set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN V19 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN U15 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN V14 IOSTANDARD LVCMOS33} [get_ports {led[7]}]
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports {led[8]}]
set_property -dict {PACKAGE_PIN V3  IOSTANDARD LVCMOS33} [get_ports {led[9]}]
set_property -dict {PACKAGE_PIN W3  IOSTANDARD LVCMOS33} [get_ports {led[10]}]
set_property -dict {PACKAGE_PIN U3  IOSTANDARD LVCMOS33} [get_ports {led[11]}]
set_property -dict {PACKAGE_PIN P3  IOSTANDARD LVCMOS33} [get_ports {led[12]}]
set_property -dict {PACKAGE_PIN N3  IOSTANDARD LVCMOS33} [get_ports {led[13]}]
set_property -dict {PACKAGE_PIN P1  IOSTANDARD LVCMOS33} [get_ports {led[14]}]
set_property -dict {PACKAGE_PIN L1  IOSTANDARD LVCMOS33} [get_ports {led[15]}]

# The USB-UART: RsRx comes from the PC, RsTx goes to it.
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33} [get_ports RsRx]
set_property -dict {PACKAGE_PIN A18 IOSTANDARD LVCMOS33} [get_ports RsTx]

# Pmod JA: protocol pins 0-3 on JA1-JA4, 4-7 on JA7-JA10, pulled up.
set_property -dict {PACKAGE_PIN J1 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {JA[0]}]
set_property -dict {PACKAGE_PIN L2 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {JA[1]}]
set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {JA[2]}]
set_property -dict {PACKAGE_PIN G2 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {JA[3]}]
set_property -dict {PACKAGE_PIN H1 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {JA[4]}]
set_property -dict {PACKAGE_PIN K2 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {JA[5]}]
set_property -dict {PACKAGE_PIN H2 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {JA[6]}]
set_property -dict {PACKAGE_PIN G3 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {JA[7]}]

# Pmod JB: an external SPI host, used with switch 15 up. JB1 SCK, JB2 MOSI,
# JB3 CS (pulled up, so an unplugged host leaves the port deselected), JB4 MISO.
set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS33 PULLDOWN true} [get_ports {JB_in[0]}]
set_property -dict {PACKAGE_PIN A16 IOSTANDARD LVCMOS33 PULLDOWN true} [get_ports {JB_in[1]}]
set_property -dict {PACKAGE_PIN B15 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {JB_in[2]}]
set_property -dict {PACKAGE_PIN B16 IOSTANDARD LVCMOS33} [get_ports JB_miso]

# The inputs that are not clocks are synchronised inside, so their timing
# to the pins does not matter.
set_false_path -from [get_ports {btnC sw[*] RsRx JA[*] JB_in[*]}]
set_false_path -to [get_ports {led[*] RsTx JA[*] JB_miso}]

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
