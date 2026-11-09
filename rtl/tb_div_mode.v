// Directed test of mode field 12: a program sets prescaler 3, after which
// the hart's tick counter `now` must advance once every 4 clocks.
`timescale 1ns/1ns
module tb_div_mode;
    reg         clk = 0, rst = 1, por = 1;
    wire [7:0]  oe, ov, violations, push_data, push_data2;
    wire [5:0]  pc;
    wire [63:0] pc_sel;
    wire        tx_pop, tx_clear, rx_push, seen_push, seen_push2, arb_lost;
    // Word 0: mode field 12 = 3. Word 1: branch always to 1, a busy loop.
    wire [31:0] ins = (pc == 0) ? {4'd9, 5'd12, 7'd0, 16'd3} : {4'd5, 3'd0, 19'd0, 6'd1};
    integer     n0, n1, k;

    janus_hart dut (
        .clk(clk), .por(por), .rst(rst), .wire_in(8'hFF), .oe(oe), .ov(ov),
        .od_mask(8'h0F), .base_role(2'd0), .reset_pc(6'd0), .addr_reg(8'd0),
        .pc(pc), .pc_sel(pc_sel), .ins(ins), .tx_valid(1'b0), .tx_ctl(2'd0),
        .tx_data(8'd0), .tx_pop(tx_pop), .tx_clear(tx_clear),
        .rx_push(rx_push), .seen_push(seen_push), .seen_push2(seen_push2),
        .push_data(push_data), .push_data2(push_data2), .violations(violations),
        .arb_lost(arb_lost), .cfg_we(1'b0), .cfg_addr(3'd0), .cfg_data(16'd0));

    always #5 clk = ~clk;

    initial begin
        @(negedge clk); por = 0;
        @(negedge clk); rst = 0;
        for (k = 0; k < 8; k = k + 1) @(negedge clk);   // boot, then run the mode word
        if (dut.c_div !== 8'd3) begin
            $display("MISMATCH c_div=%0d, expected 3", dut.c_div);
            $finish;
        end
        n0 = dut.now;
        for (k = 0; k < 40; k = k + 1) @(negedge clk);
        n1 = dut.now;
        if (n1 - n0 !== 10) begin
            $display("MISMATCH now advanced %0d in 40 clocks, expected 10", n1 - n0);
            $finish;
        end
        $display("OK prescaler 3");
        $finish;
    end
endmodule
