// Runs one host script against the chip, acting as an SPI host. Script words:
//   0 end, 1 CS low, 2 send byte, 3 CS high, 4 wait N ticks, 5 send 0 and expect
//   the byte returned on MISO, 6 force the pads (bit 0 on, bit 1 level), 7 set
//   the external pull level, 8 fail if pins in this mask ever drive high.
//   Each word is kind << 24 | value.
`timescale 1ns/1ns
module tb_chip;
    parameter HALF = 4;           // SCK half period, in clk periods
    reg         clk = 0, rst_n = 0, sck = 0, mosi = 0, cs = 1;
    wire [7:0]  uo, uio_out, uio_oe;
    // External pins. An undriven pin goes to the pull level. Forcing the pads
    // shows whether the chip really reads them.
    reg  [7:0]  pull = 8'hFF, force_val = 0, watch = 0;
    reg         force_on = 0;
    wire [7:0]  uio_in = force_on ? force_val : (uio_out & uio_oe) | (pull & ~uio_oe);
    reg  [31:0] script [0:20000];
    reg  [8*256-1:0] base;
    integer     pc = 0, errors = 0, i, checks = 0;
    reg  [7:0]  got;

    tt_um_duydat291007_janus dut (.ui_in({5'd0, cs, mosi, sck}), .uo_out(uo), .uio_in(uio_in),
                     .uio_out(uio_out), .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(rst_n));

    always #5 clk = ~clk;

    always @(negedge clk) if (rst_n && |(uio_oe & uio_out & watch)) begin
        if (errors == 0) $display("MISMATCH open-drain pin drove high: %h", uio_oe & uio_out);
        errors = errors + 1;
    end

    task ticks(input integer n);
        repeat (n) @(negedge clk);
    endtask

    task xfer(input [7:0] out, output [7:0] in);
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                mosi = out[i];
                ticks(HALF);
                in[i] = uo[0];
                sck = 1;
                ticks(HALF);
                sck = 0;
            end
            ticks(HALF);
        end
    endtask

    initial begin
        if (!$value$plusargs("script=%s", base)) $finish;
        $readmemh(base, script);
        ticks(4);
        rst_n = 1;
        ticks(4);
        while (script[pc][31:24] != 0 && script[pc] !== 32'bx) begin
            case (script[pc][31:24])
                1: begin cs = 0; ticks(HALF); end
                2: xfer(script[pc][7:0], got);
                3: begin ticks(HALF); cs = 1; ticks(2 * HALF); end
                4: ticks(script[pc][23:0]);
                5: begin
                    xfer(8'd0, got);
                    checks = checks + 1;
                    if (got !== script[pc][7:0]) begin
                        errors = errors + 1;
                        $display("MISMATCH %0s word %0d got %h expected %h", base, pc, got,
                                 script[pc][7:0]);
                    end
                end
                6: begin
                    force_on = script[pc][0];
                    force_val = {8{script[pc][1]}};
                end
                7: pull = script[pc][7:0];
                8: watch = script[pc][7:0];
                default: begin
                    $display("MISMATCH bad script word %h", script[pc]);
                    errors = errors + 1;
                end
            endcase
            pc = pc + 1;
        end
        if (errors == 0 && checks > 0) $display("OK %0d checks", checks);
        else if (checks == 0) $display("MISMATCH %0s no checks ran", base);
        $finish;
    end
endmodule
