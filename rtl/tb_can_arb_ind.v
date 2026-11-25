// Simulates the stage B CAN proof harness, can_arb_ind.sv built with CAN_SIM,
// so every claim and assumption is checked once a tick on real runs.
//
// Rounds mode (default): each round waits for both harts at `idle`, queues a
// frame for each, the second +skew=K ticks after the first (random in -6..6
// when absent; now and then only one hart sends), and checks that both harts
// store the frames that went out: the winner's when they arbitrate, or both
// one after the other. Busy mode (+busy): every queue is refilled as soon as
// it empties, so the harts contest back to back at the end of each frame.
// Identifiers in the two queues always differ, and frames are base data frames.
// +bit=N +seed=N +rounds=N (+ticks=N in busy mode). A failed claim prints
// "ERROR:", a scoreboard failure a line starting COUNT, FIELD, SEQ or ARB.
`timescale 1ns/1ps
module tb_can_arb_ind;
    reg clk = 0;
    always #5 clk = ~clk;
    `include "can_rom.vh"

    integer seed, bit_t, rounds, skew_arg, max_ticks, ticks = 0, errors = 0, done = 0, both = 0, i;
    reg [10:0] BIT;
    reg [5:0]  start;
    reg [2:0]  other;
    reg        busy;

    // The two queues.
    reg [7:0] qa [0:15];
    reg [7:0] qb [0:15];
    integer   na = 0, nb = 0;
    wire      va = na != 0, vb = nb != 0;

    reg [7:0] wa_f [0:63], wc_f [0:63];  // fields hart a stored, and the witness logged
    integer   ta = 0, tc = 0;
    reg       valid_c = 0;           // what the witness finds queued
    reg [7:0] data_c = 0;
    reg [1:0] ctl_c = 0;
    can_arb_ind dut (.addr_c(8'd0), .valid_c(valid_c), .data_c(data_c), .ctl_c(ctl_c),
        .clk(clk), .BIT(BIT), .start(start), .unwritten(32'h9F800000),
        .addr_a(8'd0), .addr_b(8'd0), .other(other),
        .valid_a(va), .data_a(qa[0]), .ctl_a(2'd0), .valid_b(vb), .data_b(qb[0]), .ctl_b(2'd0));
    wire [7:0] pd_a = dut.pdata_a, pd_b = dut.pdata_b;
    wire       pop_a = dut.pop_a, pop_b = dut.pop_b, clr_a = dut.clear_a, clr_b = dut.clear_b;
    wire       push_a = dut.push_a, push_b = dut.push_b;
    wire [5:0] at_a = dut.at_a, at_b = dut.at_b;

    // The frames queued this round, and what each hart stored.
    reg [7:0] fa [0:10];
    reg [7:0] fb [0:10];
    integer   la = 0, lb = 0;            // bytes in each frame, 0 if none
    reg [7:0] sa [0:31];
    reg [7:0] sb [0:31];
    integer   ka = 0, kb = 0, clears_a = 0, clears_b = 0, frames = 0;

    function [7:0] field(input integer j, input [7:0] v);   // a stored field's bits
        case (j)
            0: field = v & 8'h07;
            2: field = v & 8'h7F;
            default: field = v;
        endcase
    endfunction
    function [7:0] want(input integer j, input integer f);  // the frame's field j
        reg [7:0] v;
        begin
            v = f ? fb[j] : fa[j];
            case (j)
                0: want = {5'd0, v[7:5]};
                2: want = {1'b0, v[7:1]};
                default: want = v;
            endcase
        end
    endfunction

    // A new frame for hart x (0 a, 1 b) with an identifier unlike the other's.
    task make(input integer x);
        integer id, len, other_id, j2;
        begin
            other_id = x ? {fa[0][7:5], fa[1]} : {fb[0][7:5], fb[1]};
            id = {$random(seed)} % 2048;
            if (id == other_id) id = (id + 1) % 2048;
            len = 3 + {$random(seed)} % 9;
            if (x == 0) begin
                fa[0] = {id[10:8], 5'd0}; fa[1] = id[7:0]; fa[2] = {3'd0, len[3:0] - 4'd3, 1'b0};
                for (j2 = 3; j2 < 11; j2 = j2 + 1) fa[j2] = $random(seed);
                la = len;
            end else begin
                fb[0] = {id[10:8], 5'd0}; fb[1] = id[7:0]; fb[2] = {3'd0, len[3:0] - 4'd3, 1'b0};
                for (j2 = 3; j2 < 11; j2 = j2 + 1) fb[j2] = $random(seed);
                lb = len;
            end
        end
    endtask

    integer phase = 0, wait_t = 0, gap = 0, sk = 0, n, j, ia, ib, quiet = 0, wb, seq = 0, fs, n1;
    integer gap_a = 0, gap_b = 0;
    reg one_only;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("bit=%d", bit_t)) bit_t = 12;
        if (!$value$plusargs("rounds=%d", rounds)) rounds = 40;
        if (!$value$plusargs("skew=%d", skew_arg)) skew_arg = 99;
        if (!$value$plusargs("ticks=%d", max_ticks)) max_ticks = 2000000;
        busy = $test$plusargs("busy");
        BIT = bit_t;
        start = {$random(seed)} % 30;
        fa[0] = 0; fa[1] = 0; fb[0] = 8'hE0; fb[1] = 8'hFF;
    end

    always @(posedge clk) begin
        #1;
        ticks = ticks + 1;
        other = $random(seed);
        {valid_c, data_c, ctl_c} = $random(seed);
        if (pop_a && na > 0) begin for (i = 0; i < 15; i = i + 1) qa[i] = qa[i + 1]; na = na - 1; end
        if (pop_b && nb > 0) begin for (i = 0; i < 15; i = i + 1) qb[i] = qb[i + 1]; nb = nb - 1; end
        if (clr_a) begin na = 0; clears_a = clears_a + 1; end
        if (clr_b) begin nb = 0; clears_b = clears_b + 1; end
        // The witness's log, field by field, against what hart a stores.
        if (push_a) begin
            if (tc > ta && wc_f[ta % 64] !== pd_a) begin errors = errors + 1; $display("ARB witness field differs at %0d", ticks); end
            wa_f[ta % 64] = pd_a;
            ta = ta + 1;
        end
        if (dut.seen_c) begin
            if (ta > tc && wa_f[tc % 64] !== dut.pdata_c) begin errors = errors + 1; $display("ARB witness field differs at %0d", ticks); end
            wc_f[tc % 64] = dut.pdata_c;
            tc = tc + 1;
        end
        if (ta > tc + 1 || tc > ta + 1) begin errors = errors + 1; $display("ARB witness log out of step at %0d", ticks); end
        if (push_a) begin if (ka < 32) sa[ka] = pd_a; ka = ka + 1; end
        if (push_b) begin if (kb < 32) sb[kb] = pd_b; kb = kb + 1; frames = frames + (kb % 64 == 0); end

        if (busy) begin
            // Refill each queue a random few ticks after it empties.
            if (!dut.rst && na == 0) begin
                if (gap_a == 0) gap_a = 1 + {$random(seed)} % 8;
                else if (gap_a == 1) begin make(0); for (j = 0; j < la; j = j + 1) qa[j] = fa[j]; na = la; gap_a = 0; end
                else gap_a = gap_a - 1;
            end
            if (!dut.rst && nb == 0) begin
                if (gap_b == 0) gap_b = 1 + {$random(seed)} % 8;
                else if (gap_b == 1) begin make(1); for (j = 0; j < lb; j = j + 1) qb[j] = fb[j]; nb = lb; gap_b = 0; end
                else gap_b = gap_b - 1;
            end
            if (ticks >= max_ticks) begin
                $display("OK busy bit %0d stores %0d %0d clears %0d %0d ticks %0d",
                         bit_t, ka, kb, clears_a, clears_b, ticks);
                $finish;
            end
        end else begin
            case (phase)
                0: if (!dut.rst && at_a == PC_IDLE && at_b == PC_IDLE && na == 0 && nb == 0) begin
                       gap = {$random(seed)} % (25 * bit_t);
                       sk = (skew_arg != 99) ? skew_arg : ($signed($random(seed)) % 7);
                       one_only = (skew_arg == 99) && ({$random(seed)} % 5 == 0);
                       make(0);
                       make(1);
                       if (one_only) lb = 0;
                       ka = 0; kb = 0; clears_a = 0; clears_b = 0;
                       wait_t = 0; phase = 1;
                   end
                1: begin   // queue a's frame after the gap, b's sk ticks later (or earlier)
                       wait_t = wait_t + 1;
                       if (wait_t == gap + 1 + (sk < 0 ? -sk : 0)) begin
                           for (j = 0; j < la; j = j + 1) qa[j] = fa[j]; na = la;
                       end
                       if (lb != 0 && wait_t == gap + 1 + (sk > 0 ? sk : 0)) begin
                           for (j = 0; j < lb; j = j + 1) qb[j] = fb[j]; nb = lb;
                       end
                       if (wait_t > gap + 8) begin phase = 2; quiet = 0; end
                   end
                2: begin   // the frame is done when both are back at idle for a while
                       quiet = (at_a == PC_IDLE && at_b == PC_IDLE && na == 0 && nb == 0) ? quiet + 1 : 0;
                       if (quiet == 3 * bit_t) phase = 3;
                   end
                3: begin
                       ia = {fa[0][7:5], fa[1]};
                       ib = {fb[0][7:5], fb[1]};
                       wb = (lb != 0 && ib < ia);
                       if (lb != 0 && clears_a == 0 && clears_b == 0) begin
                           // No contest: one after the other.
                           seq = seq + 1;
                           fs = (sk < 0);
                           n1 = fs ? lb : la;
                           if (sk == 0 || ka != la + lb || kb != la + lb) begin
                               errors = errors + 1;
                               if (errors < 6) $display("SEQ round %0d: a stored %0d, b %0d, want %0d (skew %0d)",
                                                        done, ka, kb, la + lb, sk);
                           end else
                               for (j = 0; j < la + lb; j = j + 1)
                                   if (field(j < n1 ? j : j - n1, sa[j]) !== want(j < n1 ? j : j - n1, j < n1 ? fs : !fs)
                                           || field(j < n1 ? j : j - n1, sb[j]) !== want(j < n1 ? j : j - n1, j < n1 ? fs : !fs)) begin
                                       errors = errors + 1;
                                       if (errors < 6) $display("SEQFIELD round %0d field %0d (skew %0d)", done, j, sk);
                                   end
                       end else begin
                           n = wb ? lb : la;
                           if (ka != n || kb != n) begin
                               errors = errors + 1;
                               if (errors < 6) $display("COUNT round %0d: a stored %0d, b %0d, want %0d (ids %0d %0d skew %0d)",
                                                        done, ka, kb, n, ia, ib, sk);
                           end else
                               for (j = 0; j < n; j = j + 1)
                                   if (field(j, sa[j]) !== want(j, wb) || field(j, sb[j]) !== want(j, wb)) begin
                                       errors = errors + 1;
                                       if (errors < 6) $display("FIELD round %0d field %0d: a %h b %h want %h (skew %0d)",
                                                                done, j, field(j, sa[j]), field(j, sb[j]), want(j, wb), sk);
                                   end
                           if (lb != 0) begin
                               both = both + 1;
                               if (wb ? (clears_a != 1 || clears_b != 0) : (clears_b != 1 || clears_a != 0)) begin
                                   errors = errors + 1;
                                   if (errors < 6) $display("ARB round %0d: clears %0d %0d ids %0d %0d skew %0d",
                                                            done, clears_a, clears_b, ia, ib, sk);
                               end
                           end
                       end
                       done = done + 1;
                       phase = 0;
                   end
            endcase
            if (done >= rounds) begin
                if (errors == 0) $display("OK bit %0d rounds %0d contested %0d one-after-the-other %0d ticks %0d",
                                          bit_t, done, both, seq, ticks);
                else $display("BAD bit %0d rounds %0d contested %0d errors %0d", bit_t, done, both, errors);
                $finish;
            end
        end
        if (ticks > 60000000) begin
            $display("STUCK bit %0d rounds %0d phase %0d errors %0d", bit_t, done, phase, errors);
            $finish;
        end
    end
endmodule
