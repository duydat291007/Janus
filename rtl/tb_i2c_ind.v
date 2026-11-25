// Simulates the I2C proof harness, i2c_ind.sv built with I2C_SIM, on random
// inputs. The proof shows its claims can never fail; this shows that bytes
// really move both ways under the same assumptions, and checks every assertion
// on long runs. A scoreboard here, separate from the harness, decodes the two
// wires itself and compares every byte and acknowledge on them, and every
// byte either hart stores, with what the queues gave out.
//
// The controller's queue gets whole transactions most of the time: an
// address (usually the target's), then for a write some data bytes and a
// STOP, a RESTART or nothing, and for a read one acknowledge entry per byte,
// the last a NACK. Now and then it gets random entries instead.
//
// Run by sim_i2c.sh. +half=N is the half period, +seed=N the random seed,
// +bytes=N and +ticks=N end the run, +trace=N prints the first N ticks, and
// +census prints each new pairing of where the two harts stand. A failed
// assertion prints "ERROR:", a scoreboard failure "MISMATCH". At the end a
// TIMES line gives the shortest of each timing rule seen on the wire.
`timescale 1ns/1ps
module tb_i2c_ind;
    reg clk = 0;
    always #5 clk = ~clk;

    integer    seed, half, want_bytes, max_ticks, trace;
    integer    ticks = 0, bytes = 0, txns = 0, errors = 0, i, n, kind;
    integer    reads = 0, writes = 0, nacked = 0, restarts = 0, junk = 0;
    integer    quiet_c = 0, quiet_t = 0, burst_t = 0;
    reg [10:0] HALF;
    reg [5:0]  start;
    reg [31:0] unwritten;
    reg [7:0]  addr_c, addr_t;
    reg [1:0]  other;

    // Both queues as the chip presents them: the head stays until taken.
    reg [7:0]  qc [0:31], qt [0:15];
    reg [1:0]  qk [0:31];
    integer    nc = 0, nt = 0;
    wire       valid_c = nc != 0, valid_t = nt != 0;
    wire [7:0] data_c = qc[0], data_t = qt[0];
    wire [1:0] ctl_c = qk[0], ctl_t = 2'd0;

    reg        valid_w = 0;          // what the witness finds queued
    reg [7:0]  addr_w = 0;           // an address of its own, sent now and then
    reg [7:0]  data_w = 0;
    reg [1:0]  ctl_w = 0;
    i2c_ind dut (.addr_w(addr_w), .valid_w(valid_w), .data_w(data_w), .ctl_w(ctl_w), .clk(clk), .HALF(HALF), .start(start), .unwritten(unwritten),
        .addr_c(addr_c), .addr_t(addr_t), .other(other),
        .valid_c(valid_c), .valid_t(valid_t), .data_c(data_c), .data_t(data_t),
        .ctl_c(ctl_c), .ctl_t(ctl_t));

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("half=%d", half)) half = 8;
        if (!$value$plusargs("bytes=%d", want_bytes)) want_bytes = 60;
        if (!$value$plusargs("ticks=%d", max_ticks)) max_ticks = 400000;
        if (!$value$plusargs("trace=%d", trace)) trace = 0;
        HALF = half;
        start = {$random(seed)} % 22;
        unwritten = $random(seed);
        addr_c = $random(seed);
        addr_t = {$random(seed)} % 128;
        addr_w = {$random(seed)} % 128;
        other = $random(seed);
    end

    // Shortest times on the wire, in ticks, for the textbook timing rules:
    // SCL low and high, SDA still before SCL rises (setup) and after it falls
    // (hold), SCL high before a START (repeated) or a STOP, SCL high after a
    // START, and the bus free from a STOP to the next START.
    integer    t_scl = 0, t_sda = 0, t_stop = 99999, t_start = 99999;
    integer    lo_min = 99999, hi_min = 99999, su_min = 99999, hd_min = 99999;
    integer    sur_min = 99999, sus_min = 99999, hds_min = 99999, buf_min = 99999;
    reg        p_scl = 1, p_sda = 1, after_start = 0;
    always @(negedge clk) if (!dut.rst) begin
        if (p_scl != dut.bus[0]) begin
            if (dut.bus[0]) begin
                if (t_scl < lo_min) lo_min = t_scl;
                if (t_sda < su_min) su_min = t_sda;
            end else begin
                if (t_scl < hi_min) hi_min = t_scl;
                if (after_start && t_start < hds_min) hds_min = t_start;
                after_start = 0;
            end
            t_scl = 0;
        end
        if (p_sda != dut.bus[1]) begin
            if (!dut.bus[0] && t_scl < hd_min && p_scl == dut.bus[0]) hd_min = t_scl;
            if (dut.bus[0] && p_scl && !dut.bus[1]) begin          // START
                if (t_stop < buf_min && t_stop < t_start) buf_min = t_stop;
                if (t_scl < sur_min && t_stop > t_start) sur_min = t_scl;
                t_start = 0;
                after_start = 1;
            end
            if (dut.bus[0] && p_scl && dut.bus[1]) begin           // STOP
                if (t_scl < sus_min) sus_min = t_scl;
                t_stop = 0;
            end
            t_sda = 0;
        end
        p_scl = dut.bus[0];
        p_sda = dut.bus[1];
        t_scl = t_scl + 1;
        t_sda = t_sda + 1;
        t_stop = t_stop + 1;
        t_start = t_start + 1;
    end

    // +census prints each new pairing of where the two harts stand, for
    // writing the invariants: program words, states and the target's role.
    reg [23:0] census_was = 0;
    always @(negedge clk)
        if ($test$plusargs("census") && !dut.rst
                && {dut.at_c, dut.s_c, dut.at_t, dut.s_t, dut.role_t} != census_was) begin
            census_was = {dut.at_c, dut.s_c, dut.at_t, dut.s_t, dut.role_t};
            $display("CENSUS %0d %0d %0d %0d %0d", dut.at_c, dut.s_c, dut.at_t, dut.s_t, dut.role_t);
        end

    always @(negedge clk) if (ticks < trace)
        $display("%5d C@%0d s%0d k%0d cnt%0d e%0d | T@%0d s%0d k%0d cnt%0d e%0d r%0d | SCL%b SDA%b s1%b%b pin%b%b | lowC%b%b lowT%b%b | tx%h/%h rx%h/%h | pop%b%b push%b%b seen%b",
                 ticks, dut.at_c, dut.s_c, dut.k_c, dut.cnt_c, $signed(dut.edge_c - dut.now_c),
                 dut.at_t, dut.s_t, dut.k_t, dut.cnt_t, $signed(dut.edge_t - dut.now_t), dut.role_t,
                 dut.bus[0], dut.bus[1], dut.s1_c[0], dut.s1_c[1], dut.pin_c[0], dut.pin_c[1],
                 dut.oe_c[0] && !dut.ov_c[0], dut.oe_c[1] && !dut.ov_c[1],
                 dut.oe_t[0] && !dut.ov_t[0], dut.oe_t[1] && !dut.ov_t[1],
                 dut.tx_c, dut.tx_t, dut.rx_c, dut.rx_t,
                 dut.pop_c, dut.pop_t, dut.push_c, dut.push_t, dut.seen_t);

    // What the controller loaded to send, in order: its queue's head, or FF
    // when the queue was empty. A load runs on a tick the controller is at a
    // load word and between instructions; this samples just before it.
    reg [7:0]  sent_c [0:63];
    integer    sent_n = 0;
    reg [5:0]  at_was = 0;
    always @(posedge clk)
        if (!dut.rst && dut.s_c == dut.S_EXEC
                && (dut.at_c == dut.PC_LOADA || dut.at_c == dut.PC_WLOAD || dut.at_c == dut.PC_RLOADACK)) begin
            sent_c[sent_n % 64] = valid_c ? data_c : 8'hFF;
            sent_n = sent_n + 1;
        end
    reg [7:0]  t_byte = 8'hFF;   // the byte the target loaded for the slot in hand
    reg        t_took = 0;

    // The scoreboard's own reading of the wires.
    reg        w_scl = 1, w_sda = 1, w_in = 0, w_first = 0, w_read = 0, w_acked = 0;
    integer    w_n = 0;
    reg [7:0]  w_b = 0;
    reg [7:0]  owed_t [0:3];     // bytes on the wire the target is still to store
    integer    owed_tn = 0;
    reg [7:0]  owed_c [0:3];     // and the controller
    integer    owed_cn = 0;
    reg [7:0]  owed_w [0:3];     // and the witness: every byte, whoever it is for
    integer    owed_wn = 0, logged = 0;

    task fail(input [8*72-1:0] what);
        begin
            errors = errors + 1;
            if (errors <= 6) $display("MISMATCH at %0d: %0s", ticks, what);
        end
    endtask

    task push_c(input [1:0] k, input [7:0] b);
        if (nc < 32) begin
            qk[nc] = k;
            qc[nc] = b;
            nc = nc + 1;
        end
    endtask

    // One whole transaction for the controller.
    task transaction;
        begin
            kind = {$random(seed)} % 8;
            if (kind == 0) begin                 // random entries
                n = 1 + {$random(seed)} % 4;
                for (i = 0; i < n; i = i + 1) push_c($random(seed), $random(seed));
                junk = junk + 1;
            end else begin
                // The target's address three times in four.
                push_c(0, {({$random(seed)} % 4 != 0) ? addr_t[6:0] : ({$random(seed)} % 2) ? addr_w[6:0] : $random(seed),
                           kind >= 5});
                n = {$random(seed)} % 4;
                if (kind >= 5) begin             // a read: an acknowledge per byte
                    for (i = 0; i < n; i = i + 1)
                        push_c(0, i == n - 1 ? 8'h80 | $random(seed) : {1'b0, 7'h0} | ($random(seed) & 8'h7F));
                end else begin                   // a write
                    for (i = 0; i < n; i = i + 1) push_c(0, $random(seed));
                    case ({$random(seed)} % 3)
                        0: push_c(1, $random(seed));     // STOP
                        1: begin                         // RESTART, then more
                               push_c(2, $random(seed));
                               push_c(0, {({$random(seed)} % 4 != 0) ? addr_t[6:0] : ({$random(seed)} % 2) ? addr_w[6:0] : $random(seed), 1'b0});
                               push_c(0, $random(seed));
                           end
                        default: ;                       // nothing: the queue runs dry
                    endcase
                end
            end
        end
    endtask

    // Inputs change just after a clock, so the harness sees them settled when
    // it checks at the falling edge and the harts take them at the next clock.
    always @(posedge clk) begin
        #1;
        ticks = ticks + 1;
        if (dut.pop_c) begin
            if (nc == 0) fail("controller took from an empty queue");
            else begin
                // A pop shows the tick after it is decided: at a choice, it
                // takes a STOP or RESTART entry, never sent.
                if (at_was == dut.PC_WCHOOSE || at_was == dut.PC_WRESTART) begin
                    if (qk[0] == 0) fail("a choice took a data entry");
                    if (qk[0] == 2) restarts = restarts + 1;
                end
                for (i = 0; i < 31; i = i + 1) begin
                    qc[i] = qc[i + 1];
                    qk[i] = qk[i + 1];
                end
                nc = nc - 1;
            end
        end
        if (dut.pop_t) begin
            if (nt == 0) fail("target took from an empty queue");
            else begin
                t_byte = qt[0];
                t_took = 1;
                for (i = 0; i < 15; i = i + 1) qt[i] = qt[i + 1];
                nt = nt - 1;
            end
        end
        at_was = dut.at_c;

        // The wires, read as any device on the bus would. SCL rises once
        // more before a STOP or a repeated START, and that rise cannot be told
        // from a byte's first bit until SDA moves, so one bit may be pending.
        if (w_scl && dut.bus[0] && w_sda && !dut.bus[1]) begin          // START
            if (w_in && w_n > 1) fail("START in the middle of a byte");
            w_in = 1; w_n = 0; w_first = 1;
            txns = txns + 1;
        end else if (w_scl && dut.bus[0] && !w_sda && dut.bus[1]) begin // STOP
            if (w_in && w_n > 1) fail("STOP in the middle of a byte");
            w_in = 0;
        end else if (w_in && !w_scl && dut.bus[0]) begin                // a bit
            if (w_n < 8) begin
                w_b = {w_b[6:0], dut.bus[1]};
                w_n = w_n + 1;
                if (w_n == 8) begin
                    owed_w[owed_wn % 4] = w_b;
                    owed_wn = owed_wn + 1;
                    if (w_first || !w_read) begin
                        // The controller's byte: the next it loaded to send.
                        if (sent_n == 0) fail("a byte the controller never loaded");
                        else if (w_b !== sent_c[(sent_n - 1) % 64]) fail("controller byte differs");
                        if (w_first || w_acked) begin
                            owed_t[owed_tn % 4] = w_b;
                            owed_tn = owed_tn + 1;
                        end
                    end else begin
                        // The target's byte: the one it took, or FF.
                        if (w_b !== (t_took ? t_byte : 8'hFF)) fail("target byte differs");
                        t_took = 0;
                        t_byte = 8'hFF;
                        owed_c[owed_cn % 4] = w_b;
                        owed_cn = owed_cn + 1;
                    end
                end
            end else begin                       // the acknowledge bit
                if (w_first) begin
                    // Only the target that was addressed acknowledges.
                    if (dut.bus[1] !== !(w_b[7:1] == addr_t)) fail("wrong address acknowledge");
                    w_read = w_b[0];
                    w_acked = !dut.bus[1];
                    if (w_acked) begin
                        if (w_read) reads = reads + 1;
                        else writes = writes + 1;
                    end
                end else if (w_read) begin
                    // The controller's acknowledge: the top bit of its entry.
                    if (sent_n == 0 || dut.bus[1] !== sent_c[(sent_n - 1) % 64][7])
                        fail("controller acknowledge differs");
                end else if (dut.bus[1] !== 1'b0) fail("target did not acknowledge a byte");
                if (dut.bus[1]) nacked = nacked + 1;
                w_first = 0;
                w_n = 0;
                bytes = bytes + 1;
            end
        end
        w_scl = dut.bus[0];
        w_sda = dut.bus[1];

        // Stores: each the next byte on the wire for that hart.
        if (dut.push_t || dut.seen_t) begin
            if (owed_tn == 0 || dut.pdata_t !== owed_t[0]) fail("target stored a wrong byte");
            for (i = 0; i < 3; i = i + 1) owed_t[i] = owed_t[i + 1];
            if (owed_tn != 0) owed_tn = owed_tn - 1;
        end
        if (dut.push_c) begin
            if (owed_cn == 0 || dut.pdata_c !== owed_c[0]) fail("controller stored a wrong byte");
            for (i = 0; i < 3; i = i + 1) owed_c[i] = owed_c[i + 1];
            if (owed_cn != 0) owed_cn = owed_cn - 1;
        end
        if (dut.seen_c) fail("controller logged as a witness");
        if (dut.seen_w) begin
            logged = logged + 1;
            if (owed_wn == 0 || dut.pdata_w !== owed_w[0]) fail("witness logged a wrong byte");
            for (i = 0; i < 3; i = i + 1) owed_w[i] = owed_w[i + 1];
            if (owed_wn != 0) owed_wn = owed_wn - 1;
        end
        if (owed_wn > 1) fail("witness did not log a byte");
        {valid_w, data_w, ctl_w} = $random(seed);

        // A new transaction when the controller has run dry, after a pause.
        if (quiet_c != 0) quiet_c = quiet_c - 1;
        else if (nc == 0) begin
            transaction;
            quiet_c = ({$random(seed)} % 4 == 0) ? {$random(seed)} % 4000 : {$random(seed)} % 200;
        end
        if (quiet_t != 0) quiet_t = quiet_t - 1;
        else if (burst_t == 0) begin
            burst_t = 1 + {$random(seed)} % 5;
            quiet_t = ({$random(seed)} % 3 == 0) ? {$random(seed)} % 6000 : {$random(seed)} % 60;
        end else if (nt < 16 && {$random(seed)} % 3 == 0) begin
            qt[nt] = $random(seed);
            nt = nt + 1;
            burst_t = burst_t - 1;
        end
        other = $random(seed);
        if (bytes >= want_bytes || ticks >= max_ticks) begin
            $display("TIMES half %0d low %0d high %0d setup %0d hold %0d rs_setup %0d stop_setup %0d start_hold %0d bus_free %0d",
                     half, lo_min, hi_min, su_min, hd_min, sur_min, sus_min, hds_min, buf_min);
            if (logged < bytes) fail("the witness logged fewer bytes than were sent");
            if (errors == 0 && bytes != 0)
                $display("OK half %0d start %0d bytes %0d transactions %0d writes %0d reads %0d nacks %0d restarts %0d junk %0d ticks %0d",
                         half, start, bytes, txns, writes, reads, nacked, restarts, junk, ticks);
            else
                $display("MISMATCH half %0d: %0d errors, %0d bytes", half, errors, bytes);
            $finish;
        end
    end
endmodule
