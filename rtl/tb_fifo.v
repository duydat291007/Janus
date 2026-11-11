// The queue on its own, against a plain list: random pushes, pops and clears,
// with long stretches full and empty. Every tick compares the head, the empty
// flag and the full flag. Run by chip.sh test.
`timescale 1ns/1ns
module tb_fifo;
    localparam LOG = 2, N = 1 << LOG;
    reg        clk = 0, rst = 1, clear = 0, push = 0, pop = 0;
    reg  [7:0] din = 0;
    wire [7:0] dout;
    wire       empty, full;
    reg  [7:0] q [0:N-1];              // the list: q[0] is the head
    integer    len = 0, was, i, t, skip, full_and_both = 0, seed = 1;

    janus_fifo #(.W(8), .LOG(LOG)) dut (.clk(clk), .rst(rst), .clear(clear), .push(push),
        .din(din), .pop(pop), .dout(dout), .empty(empty), .full(full));

    always #5 clk = ~clk;

    initial begin
        @(negedge clk); rst = 0;
        for (t = 0; t < 20000; t = t + 1) begin
            // Phases lean towards filling, then draining, then both at once.
            push = ($random(seed) & 7) < ((t / 500) % 3 == 1 ? 2 : 6);
            pop = ($random(seed) & 7) < ((t / 500) % 3 == 0 ? 2 : 6);
            clear = ($random(seed) & 255) == 0;
            din = $random(seed);
            #1;
            // The outputs look past a pop or clear that lands on this tick.
            skip = (pop && len > 0) ? 1 : 0;
            if (full !== (len == N) || empty !== (clear || len - skip == 0)
                    || (len - skip > 0 && dout !== q[skip])) begin
                $display("MISMATCH tick %0d len=%0d full=%b empty=%b dout=%h", t, len, full,
                         empty, dout);
                $finish;
            end
            if (push && pop && len == N) full_and_both = full_and_both + 1;
            @(posedge clk);
            was = len;
            if (clear) len = 0;
            else begin
                if (skip) begin
                    for (i = 0; i < len - 1; i = i + 1) q[i] = q[i + 1];
                    len = len - 1;
                end
                // A full queue takes a push only when the same tick pops.
                if (push && (was < N || pop)) begin
                    q[len] = din;
                    len = len + 1;
                end
            end
            @(negedge clk);
        end
        if (full_and_both < 20) begin
            $display("MISMATCH only %0d pushes into a full queue with a pop", full_and_both);
            $finish;
        end
        $display("OK %0d ticks, %0d pushes into a full queue with a pop", t, full_and_both);
        $finish;
    end
endmodule
