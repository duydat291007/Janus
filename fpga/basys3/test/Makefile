# The Basys 3 build in simulation, with cocotb and Icarus Verilog.
# From this folder: make
SIM ?= icarus
TOPLEVEL_LANG ?= verilog
ROOT = $(abspath $(PWD)/../../..)
SIM_BUILD = sim_build

$(shell cd $(ROOT) && python3 fpga/fpga_source.py $(PWD)/sim_build/janus_chip_fpga.v > /dev/null)

VERILOG_SOURCES = $(PWD)/sim_build/janus_chip_fpga.v $(ROOT)/src/janus_hart.v \
                  $(PWD)/../uart_spi_bridge.v $(PWD)/../janus_basys3.v $(PWD)/tb_basys3.v
TOPLEVEL = tb_basys3
COCOTB_TEST_MODULES = test_basys3

include $(shell cocotb-config --makefiles)/Makefile.sim
