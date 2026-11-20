// Two CAN harts that may both have a frame to send, the real program on two
// real harts. Each round queues a frame for each, the second a chosen number
// of ticks after the first, so both may claim the bus before seeing the
// other's start of frame and arbitrate, with their starts skewed; or the later
// one sees the first start of frame in time and sends after it. Checks that
// both harts store exactly the frames that went out, the winner's when they
// arbitrate (the lower identifier), that the loser's queue is cleared, and
// that no hart counts a violation. Now and then only one hart sends.
// Run by sim_can_arb.sh: +bit=N +seed=N +rounds=N, and +skew=K for K ticks
// from a's queuing to b's (random in -4..4 when absent).
`timescale 1ns/1ps
module tb_can_arb;
    reg clk = 0;
    always #5 clk = ~clk;
    `include "can_rom.vh"

    integer seed, bit_t, rounds, skew_arg, ticks = 0, errors = 0, done = 0, both = 0, i;
    reg [10:0] BIT;
    reg [5:0]  start;
    reg [2:0]  other;

    reg [1:0] step = 0;
    wire por = step == 0;
    wire rst = step < 2'd3;
    always @(posedge clk) if (rst) step <= step + 1'b1;
    wire        cfg_we = step == 2'd1 || step == 2'd2;
    wire [2:0]  cfg_addr = step == 2'd1 ? 3'd2 : 3'd4;
    wire [15:0] cfg_data = step == 2'd1 ? can_hold(start) : can_hold_ticks(BIT);

    // The two queues.
    reg [7:0] qa [0:15];
    reg [7:0] qb [0:15];
    integer   na = 0, nb = 0;
    wire      va = na != 0, vb = nb != 0;

    wire [7:0] oe_a, ov_a, oe_b, ov_b, pd_a, pd_b, vio_a, vio_b;
    wire [5:0] pc_a, pc_b;
    wire       pop_a, pop_b, clr_a, clr_b, push_a, push_b, lost_a, lost_b;
    wire       low = (oe_a[0] && !ov_a[0]) || (oe_b[0] && !ov_b[0]);
    wire [7:0] bus = {4'hF, other, !low};
    wire [5:0] at_a = pc_a - start, at_b = pc_b - start;

    janus_hart a (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_a), .ov(ov_a),
        .od_mask(8'h01), .base_role(2'd0), .reset_pc(start), .addr_reg(8'd0), .pc(pc_a),
        .pc_sel(), .ins(can_word(at_a, BIT, start, 32'h9F800000)), .tx_valid(va), .tx_ctl(2'd0),
        .tx_data(qa[0]), .tx_pop(pop_a), .tx_clear(clr_a), .rx_push(push_a), .seen_push(),
        .seen_push2(), .push_data(pd_a), .push_data2(), .violations(vio_a), .arb_lost(lost_a),
        .state(), .cur_role(), .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data));
    janus_hart b (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_b), .ov(ov_b),
        .od_mask(8'h01), .base_role(2'd0), .reset_pc(start), .addr_reg(8'd0), .pc(pc_b),
        .pc_sel(), .ins(can_word(at_b, BIT, start, 32'h9F800000)), .tx_valid(vb), .tx_ctl(2'd0),
        .tx_data(qb[0]), .tx_pop(pop_b), .tx_clear(clr_b), .rx_push(push_b), .seen_push(),
        .seen_push2(), .push_data(pd_b), .push_data2(), .violations(vio_b), .arb_lost(lost_b),
        .state(), .cur_role(), .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data));

    // The frames queued this round, and what each hart stored.
    reg [7:0] fa [0:10];
    reg [7:0] fb [0:10];
    integer   la = 0, lb = 0;            // bytes in each frame, 0 if none
    reg [7:0] sa [0:31];
    reg [7:0] sb [0:31];
    integer   ka = 0, kb = 0, losses_a = 0, losses_b = 0, clears_a = 0, clears_b = 0;

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

    integer phase = 0, wait_t = 0, gap = 0, sk = 0, ida, idb, n, j, ia, ib, quiet = 0, wb, seq = 0, fs, n1;
    reg one_only;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("bit=%d", bit_t)) bit_t = 11;
        if (!$value$plusargs("rounds=%d", rounds)) rounds = 40;
        if (!$value$plusargs("skew=%d", skew_arg)) skew_arg = 99;
        BIT = bit_t;
        start = {$random(seed)} % 30;
    end

    always @(posedge clk) begin
        #1;
        ticks = ticks + 1;
        other = $random(seed);
        if (pop_a && na > 0) begin for (i = 0; i < 15; i = i + 1) qa[i] = qa[i + 1]; na = na - 1; end
        if (pop_b && nb > 0) begin for (i = 0; i < 15; i = i + 1) qb[i] = qb[i + 1]; nb = nb - 1; end
        if (clr_a) begin na = 0; clears_a = clears_a + 1; end
        if (clr_b) begin nb = 0; clears_b = clears_b + 1; end
        if (lost_a) losses_a = losses_a + 1;
        if (lost_b) losses_b = losses_b + 1;
        if (push_a) begin if (ka < 32) sa[ka] = pd_a; ka = ka + 1; end
        if (push_b) begin if (kb < 32) sb[kb] = pd_b; kb = kb + 1; end
        if (vio_a != 0 || vio_b != 0) begin
            errors = errors + 1;
            if (errors < 4) $display("VIOLATION at %0d: a %0d b %0d (skew %0d)", ticks, vio_a, vio_b, sk);
        end

        // Rounds: wait at idle, queue, let the frame go, check.
        case (phase)
            0: if (!rst && at_a == PC_IDLE && at_b == PC_IDLE && na == 0 && nb == 0) begin
                   gap = {$random(seed)} % (25 * bit_t);
                   sk = (skew_arg != 99) ? skew_arg : ($signed($random(seed)) % 5);
                   one_only = (skew_arg == 99) && ({$random(seed)} % 5 == 0);
                   ida = {$random(seed)} % 2048;
                   idb = {$random(seed)} % 2048;
                   if (idb == ida) idb = (ida + 1) % 2048;
                   la = 3 + {$random(seed)} % 9;
                   lb = one_only ? 0 : 3 + {$random(seed)} % 9;
                   fa[0] = {ida[10:8], 5'd0}; fa[1] = ida[7:0]; fa[2] = {3'd0, la[3:0] - 4'd3, 1'b0};
                   fb[0] = {idb[10:8], 5'd0}; fb[1] = idb[7:0]; fb[2] = {3'd0, lb[3:0] - 4'd3, 1'b0};
                   for (j = 3; j < 11; j = j + 1) begin fa[j] = $random(seed); fb[j] = $random(seed); end
                   ka = 0; kb = 0; losses_a = 0; losses_b = 0; clears_a = 0; clears_b = 0;
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
                   if (wait_t > gap + 6) begin phase = 2; quiet = 0; end
               end
            2: begin   // the frame is done when both are back at idle for a while
                   quiet = (at_a == PC_IDLE && at_b == PC_IDLE && na == 0 && nb == 0) ? quiet + 1 : 0;
                   if (quiet == 3 * bit_t) phase = 3;
               end
            3: begin
                   // The winner: the lower identifier, or the only sender.
                   ia = {fa[0][7:5], fa[1]};
                   ib = {fb[0][7:5], fb[1]};
                   wb = (lb != 0 && ib < ia);
                   if (lb != 0 && clears_a == 0 && clears_b == 0) begin
                       // No contest: the later hart saw the first start of frame
                       // in time, received that frame and sent its own after it.
                       seq = seq + 1;
                       fs = (sk < 0);                  // which frame went first
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
            else $display("BAD bit %0d rounds %0d contested %0d one-after-the-other %0d errors %0d",
                          bit_t, done, both, seq, errors);
            $finish;
        end
        if (ticks > 50000000) begin
            $display("STUCK bit %0d rounds %0d phase %0d errors %0d", bit_t, done, phase, errors);
            $finish;
        end
    end
endmodule
