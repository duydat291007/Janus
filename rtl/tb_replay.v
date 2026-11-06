// Replays one recorded hart from the Python model and demands identical
// pins, violation count and received data on every tick.
`timescale 1ns/1ns
module tb_replay;
    parameter MAX_TICKS = 200000;
    reg         clk = 0, rst = 1, por = 1;
    reg  [7:0]  wire_in = 8'hFF;
    wire [7:0]  oe, ov, violations, push_data, push_data2;
    wire [5:0]  pc;
    wire        tx_pop, tx_clear, rx_push, seen_push, seen_push2, arb_lost;
    reg  [31:0] prog [0:63];
    reg  [15:0] meta [0:15];
    reg  [9:0]  txm  [0:255];
    reg  [47:0] vec  [0:MAX_TICKS-1];
    reg  [47:0] v;
    integer     rptr = 0, i, ntx, nticks;
    reg  [15:0] rx_h = 0, seen_h = 0;
    reg         cfg_we = 0;
    reg  [2:0]  cfg_addr = 0;
    reg  [15:0] cfg_data = 0;
    reg  [8*256-1:0] base, path;
    wire [7:0]  pinmask = meta[2][15:8];

    // Data can arrive late: meta[12] is the tick the queue first has data.
    wire        tx_valid = rptr < ntx && !rst && i >= {meta[13], meta[12]};
    wire [9:0]  head = txm[rptr];

    janus_hart dut (
        .clk(clk), .por(por), .rst(rst), .wire_in(wire_in), .oe(oe), .ov(ov),
        .od_mask(meta[2][7:0]), .base_role(meta[0][1:0]), .reset_pc(6'd0), .addr_reg(meta[1][7:0]),
        .pc(pc), .ins(prog[pc]), .tx_valid(tx_valid), .tx_ctl(head[9:8]),
        .tx_data(head[7:0]), .tx_pop(tx_pop), .tx_clear(tx_clear),
        .rx_push(rx_push), .seen_push(seen_push), .seen_push2(seen_push2),
        .push_data(push_data), .push_data2(push_data2), .violations(violations),
        .arb_lost(arb_lost), .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data));

    always #5 clk = ~clk;

    initial begin
        if (!$value$plusargs("base=%s", base)) $finish;
        $sformat(path, "%0s.prog", base); $readmemh(path, prog);
        $sformat(path, "%0s.meta", base); $readmemh(path, meta);
        $sformat(path, "%0s.tx", base);   $readmemh(path, txm);
        $sformat(path, "%0s.vec", base);  $readmemh(path, vec);
        nticks = {meta[14], meta[3]};
        ntx = meta[4];
        @(negedge clk);
        por = 0;
        for (i = 0; i < 6; i = i + 1) begin
            @(negedge clk);
            cfg_we = 1; cfg_addr = i; cfg_data = meta[5 + i];
        end
        @(negedge clk); cfg_we = 0;
        @(negedge clk); rst = 0;
        for (i = 0; i < nticks; i = i + 1) begin
            v = vec[i];
            wire_in = v[47:40];
            @(posedge clk);
            @(negedge clk);
            if (rx_push) rx_h = rx_h * 31 + push_data;
            if (seen_push) seen_h = seen_h * 31 + push_data;
            if (seen_push2) seen_h = seen_h * 31 + push_data2;
            if (tx_clear) rptr = ntx;
            else if (tx_pop) rptr = rptr + 1;
            if ((oe & pinmask) !== v[39:32] || (ov & oe & pinmask) !== v[31:24]
                    || violations !== v[23:16] || rx_h !== v[15:0]) begin
                $display("MISMATCH %0s tick %0d pc=%0d oe=%h/%h ov=%h/%h viol=%0d/%0d rx=%h/%h",
                         base, i, pc, oe & pinmask, v[39:32], ov & oe & pinmask, v[31:24],
                         violations, v[23:16], rx_h, v[15:0]);
                $finish;
            end
        end
        if (seen_h !== meta[11]) begin
            $display("MISMATCH %0s seen hash %h/%h", base, seen_h, meta[11]);
            $finish;
        end
        $display("OK %0d", nticks);
        $finish;
    end
endmodule
