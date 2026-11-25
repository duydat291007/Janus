// Simulates the CAN proof harness, can_ind.sv built with CAN_SIM, on random
// inputs. The proof shows its claims can never fail; this shows that frames
// really go through under the same assumptions, and checks every assertion
// on long runs. A scoreboard here, separate from the harness, follows the
// bytes hart a takes and compares every byte either hart stores with them.
//
// Hart a's queue gets whole base data frames: an 11-bit identifier, a length
// from 0 to 15 (8 bytes at most follow), sometimes r0 set, and now and then
// fewer data bytes than the length asks for, so the sender sends FF.
//
// Run by sim_can.sh. +bit=N is the bit time, +seed=N the random seed,
// +frames=N and +ticks=N end the run, and +trace=N prints the first N ticks.
// +race=K queues each frame when hart a's hold count is K short of the trap
// (K from 1), so the frame starts just as the trap would fire.
// A failed assertion prints "ERROR:", a scoreboard failure "MISMATCH".
`timescale 1ns/1ps
module tb_can_ind;
    reg clk = 0;
    always #5 clk = ~clk;

    integer    seed, bit_t, want_frames, max_ticks, trace;
    integer    ticks = 0, frames = 0, sent = 0, errors = 0, i, n, dlc, kept, quiet = 0;
    integer    short = 0, bytes = 0;
    integer    race;                 // +race=K: queue each frame K ticks before the hold trap
    reg [10:0] BIT;
    reg [5:0]  start;
    reg [31:0] unwritten;
    reg [7:0]  addr_a, addr_b, addr_c = 0;
    reg        valid_c = 0;          // what the witness finds queued
    reg [7:0]  data_c = 0;
    reg [1:0]  ctl_c = 0;
    integer    logged = 0;
    reg        norx;                 // no receiver: hart b is a second witness
    reg [2:0]  other;
    reg [10:0] ident;
    reg        whole = 1;            // the last frame queued had all its data bytes

    // Hart a's queue as the chip presents it: the head stays until taken.
    reg [7:0]  q [0:63];
    reg [1:0]  qk [0:63];
    integer    nq = 0;
    wire       valid_a = nq != 0;
    wire [7:0] data_a = q[0];
    wire [1:0] ctl_a = qk[0];

    can_ind dut (.clk(clk), .BIT(BIT), .start(start), .unwritten(unwritten),
        .addr_a(addr_a), .addr_b(addr_b), .other(other),
        .valid_a(valid_a), .data_a(data_a), .ctl_a(ctl_a),
        .addr_c(addr_c), .valid_c(valid_c), .data_c(data_c), .ctl_c(ctl_c), .norx(norx));

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("bit=%d", bit_t)) bit_t = 11;
        if (!$value$plusargs("frames=%d", want_frames)) want_frames = 20;
        if (!$value$plusargs("ticks=%d", max_ticks)) max_ticks = 2000000;
        if (!$value$plusargs("trace=%d", trace)) trace = 0;
        if (!$value$plusargs("race=%d", race)) race = -1;
        norx = $test$plusargs("norx");
        BIT = bit_t;
        start = {$random(seed)} % 30;
        unwritten = $random(seed);
        addr_a = $random(seed);
        addr_b = $random(seed);
        other = $random(seed);
    end

    always @(negedge clk) if (ticks < 24 && $test$plusargs("boot"))
        $display("BOOT %0d rst%b fell%b fr%b st%0d held%0d rq%0d rq1%0d rq2%0d rqv%0d bus%b pin%b s1%b prev%b p2%b p3%b mprev%b", ticks, dut.rst, dut.g_fell, dut.m_fr, dut.m_st,
                 dut.held_a[15:0], dut.rq, dut.rq1, dut.rq2, dut.rqv, dut.bus[0], dut.pin_a[0], dut.s1_a[0], dut.prev_a[0], dut.m_p2, dut.m_p3, dut.m_prev);
    always @(negedge clk) if (ticks < trace)
        $display("%5d A@%0d s%0d k%0d e%0d r%0d i%0d run%0d/%0d%0d crc%h lf%0d/%0d cnt%0d | B@%0d s%0d k%0d e%0d r%0d i%0d run%0d crc%h lf%0d/%0d | BUS%b | m%0d t%0d i%0d run%0d crc%h | held%0d | pop%b push%b%b",
                 ticks, dut.at_a, dut.s_a, dut.k_a, $signed(dut.edge_a - dut.now_a), dut.role_a, dut.insd_a,
                 dut.code_a[7:4], dut.code_a[3], dut.code_a[2], dut.code_a[22:8], dut.cset_a[13], $signed(dut.lf_a - dut.now_a), dut.count_a,
                 dut.at_b, dut.s_b, dut.k_b, $signed(dut.edge_b - dut.now_b), dut.role_b, dut.insd_b,
                 dut.code_b[7:4], dut.code_b[22:8], dut.cset_b[13], $signed(dut.lf_b - dut.now_b),
                 dut.bus[0], dut.m_st, dut.m_t, dut.m_i, dut.m_run, dut.m_crc, dut.held_a[15:0],
                 dut.pop_a, dut.push_a, dut.push_b);

    // What hart a took, field by field, and what each hart must store next.
    // A frame's fields: 0 the top of the identifier, 1 the rest, 2 the
    // control field, then the data bytes.
    reg [7:0]  took [0:4095];
    reg [3:0]  kind [0:4095];        // 0, 1, 2 or 3 for a data byte
    integer    ntook = 0, next_a = 0, next_b = 0, field = 0, left = 0;
    reg [7:0]  mask;

    task fail(input [8*64-1:0] what);
        begin
            errors = errors + 1;
            if (errors <= 6) $display("MISMATCH at %0d: %0s", ticks, what);
        end
    endtask

    // A load runs on a tick hart a is at a load word, between instructions
    // and sending; this samples just before it.
    always @(posedge clk)
        if (!dut.rst && dut.s_a == dut.S_EXEC && dut.role_a == 0
                && (dut.at_a == dut.PC_LOAD1 || dut.at_a == dut.PC_LOAD2
                    || dut.at_a == dut.PC_LOAD3 || dut.at_a == dut.PC_DLOAD)) begin
            took[ntook % 4096] = valid_a ? data_a : 8'hFF;
            kind[ntook % 4096] = dut.at_a == dut.PC_LOAD1 ? 0 : dut.at_a == dut.PC_LOAD2 ? 1
                                 : dut.at_a == dut.PC_LOAD3 ? 2 : 3;
            ntook = ntook + 1;
        end

    function [7:0] want(input integer j);
        case (kind[j % 4096])
            0: want = {5'd0, took[j % 4096][7:5]};
            1, 3: want = took[j % 4096];
            default: want = {1'b0, took[j % 4096][7:1]};
        endcase
    endfunction
    function [7:0] fmask(input integer j);
        case (kind[j % 4096])
            0: fmask = 8'h07;
            1, 3: fmask = 8'hFF;
            default: fmask = 8'h7F;
        endcase
    endfunction

    // Inputs change just after a clock, so the harness sees them settled when
    // it checks at the falling edge and the harts take them at the next clock.
    always @(posedge clk) begin
        #1;
        ticks = ticks + 1;
        if (dut.pop_a) begin
            if (nq == 0) fail("hart a took from an empty queue");
            else begin
                for (i = 0; i < 63; i = i + 1) begin
                    q[i] = q[i + 1];
                    qk[i] = qk[i + 1];
                end
                nq = nq - 1;
            end
        end
        if (dut.push_a) begin
            if (next_a >= ntook) fail("hart a stored a field it never sent");
            else if ((dut.pdata_a & fmask(next_a)) !== want(next_a)) fail("hart a stored a wrong field");
            if (kind[next_a % 4096] == 2) frames = frames + 1;
            next_a = next_a + 1;
        end
        if (dut.tk_b) begin
            if (next_b >= ntook) fail("hart b stored a field never sent");
            else if ((dut.pdata_b & fmask(next_b)) !== want(next_b)) fail("hart b stored a wrong field");
            next_b = next_b + 1;
            bytes = bytes + 1;
        end

        // The witness's log, checked against what the receiver stores.
        if (dut.seen_c) begin
            logged = logged + 1;
            if (!dut.tk_b || dut.pdata_c !== dut.pdata_b) fail("the witness logged a wrong field");
        end
        valid_c = $random(seed);
        data_c = $random(seed);
        ctl_c = $random(seed);
        // A new frame when the queue has run dry, after a pause. After a
        // frame short of data bytes the sender reads FF from the empty queue
        // until the frame ends, so a host waits for it to go back to `idle`.
        if (quiet != 0) quiet = quiet - 1;
        else if (nq == 0 && (whole || dut.at_a == dut.PC_IDLE)
                 && (race < 0 || (dut.at_a == dut.PC_IDLE && dut.s_a == dut.S_CLAIM
                                  && dut.held_a[15:0] == 20 * bit_t - race))) begin
            ident = $random(seed);
            dlc = {$random(seed)} % 16;
            n = dlc > 8 ? 8 : dlc;
            kept = ({$random(seed)} % 6 == 0) ? {$random(seed)} % (n + 1) : n;
            if (kept < n) short = short + 1;
            whole = kept == n;
            q[0] = {ident[10:8], 5'd0};
            q[1] = ident[7:0];
            q[2] = {1'b0, 1'b0, ({$random(seed)} % 4 == 0), dlc[3:0], 1'b0};
            for (i = 0; i < kept; i = i + 1) q[3 + i] = $random(seed);
            for (i = 0; i < 3 + kept; i = i + 1) qk[i] = $random(seed);
            nq = 3 + kept;
            sent = sent + 1;
            quiet = ({$random(seed)} % 3 == 0) ? {$random(seed)} % (40 * bit_t) : {$random(seed)} % 8;
        end
        other = $random(seed);
        if (frames >= want_frames || ticks >= max_ticks) begin
            // A frame with no receiver is counted once by every hart, with one none.
            if (norx ? (dut.viol_a < (sent > 254 ? 254 : sent - 1) || dut.viol_a > sent) : dut.viol_a != 0) fail("violations");
            if (logged != bytes) fail("the witness's log is not what was stored");
            if (errors == 0 && frames != 0 && next_b >= next_a - 3)
                $display("OK bit %0d start %0d frames %0d short %0d fields %0d ticks %0d",
                         bit_t, start, frames, short, bytes, ticks);
            else
                $display("MISMATCH bit %0d: %0d errors, %0d frames", bit_t, errors, frames);
            $finish;
        end
    end
endmodule
