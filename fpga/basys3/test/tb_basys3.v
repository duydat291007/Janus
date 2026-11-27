`default_nettype none
`timescale 1ns / 1ps
// The Basys 3 top level, with the Pmod pins pulled up as the FPGA's PULLUP
// constraint does. Driven by test_basys3.py.
module tb_basys3 ();
    reg         clk = 0;
    reg         btnC = 0;
    reg  [15:0] sw = 0;
    reg         RsRx = 1;
    reg  [2:0]  JB_in = 3'b100;
    wire [15:0] led;
    wire        RsTx, JB_miso;
    tri1 [7:0]  JA;               // weak pull-ups

    janus_basys3 dut (.clk(clk), .btnC(btnC), .sw(sw), .led(led), .RsRx(RsRx), .RsTx(RsTx),
        .JA(JA), .JB_in(JB_in), .JB_miso(JB_miso));
endmodule
