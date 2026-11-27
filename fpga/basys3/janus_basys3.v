// Janus on a Digilent Basys 3 (Artix-7 XC7A35T).
//
// The chip runs at 25 MHz, its Tiny Tapeout clock, divided down from the
// board's 100 MHz. Its eight protocol pins are Pmod JA (JA1-JA4 are pins 0-3,
// JA7-JA10 pins 4-7), with the FPGA's weak pull-ups on, so an undriven
// open-drain line reads high; I2C and 1-Wire still want real pull-up
// resistors.
//
// The host port: with switch 15 down, the PC drives it through the board's
// USB-UART and uart_spi_bridge.v (1 Mbaud). With switch 15 up, an external
// SPI host drives it on Pmod JB: JB1 SCK, JB2 MOSI, JB3 CS, JB4 MISO, so a
// Raspberry Pi Pico runs host/example_loopback.py unchanged.
//
// The centre button resets the chip, and so does power-up.
//
// LEDs: 0 receive data waiting, 1 violation seen, 2 arbitration lost, 3 and 4
// harts 0 and 1 running, 5 a bridge frame under way, 6-13 the levels of
// protocol pins 0-7, 15 blinks while the clock runs.
module janus_basys3 (
    input         clk,           // 100 MHz
    input         btnC,
    input  [15:0] sw,
    output [15:0] led,
    input         RsRx,          // from the PC
    output        RsTx,          // to the PC
    inout  [7:0]  JA,            // protocol pins 0-7
    input  [2:0]  JB_in,         // external host: SCK, MOSI, CS
    output        JB_miso
);
    // ---- 25 MHz ----
    reg [1:0] div = 0;
    always @(posedge clk) div <= div + 1'b1;
    wire clk25;
`ifdef SYNTHESIS
    BUFG clk_buf (.I(div[1]), .O(clk25));
`else
    assign clk25 = div[1];
`endif

    // ---- Reset: power-up, and the centre button ----
    reg [1:0] btn_s = 0;
    reg [7:0] por_n = 0;         // counts up after power-up and after each press
    always @(posedge clk25) begin
        btn_s <= {btn_s[0], btnC};
        if (btn_s[1]) por_n <= 0;
        else if (!por_n[7]) por_n <= por_n + 1'b1;
    end
    wire rst_n = por_n[7];

    // ---- The host port ----
    wire br_sck, br_mosi, br_cs_n, br_busy, miso;
    uart_spi_bridge bridge (.clk(clk25), .rst(!rst_n), .rx(RsRx), .tx(RsTx),
        .sck(br_sck), .mosi(br_mosi), .cs_n(br_cs_n), .miso(miso), .busy(br_busy));
    wire ext = sw[15];
    wire [7:0] ui_in = {5'd0, ext ? JB_in : {br_cs_n, br_mosi, br_sck}};
    assign JB_miso = miso;

    // ---- The chip ----
    wire [7:0] uo_out, uio_in, uio_out, uio_oe;
    tt_um_duydat291007_janus chip (.ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in),
        .uio_out(uio_out), .uio_oe(uio_oe), .ena(1'b1), .clk(clk25), .rst_n(rst_n));
    assign miso = uo_out[0];

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : pin
            assign JA[i] = uio_oe[i] ? uio_out[i] : 1'bz;
        end
    endgenerate
    assign uio_in = JA;

    // ---- LEDs ----
    reg [23:0] beat = 0;
    always @(posedge clk25) beat <= beat + 1'b1;
    assign led = {beat[23], 1'b0, uio_in, br_busy, uo_out[5:1]};
endmodule
