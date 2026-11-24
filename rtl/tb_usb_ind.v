// Simulates the USB proof harness, usb_ind.sv built with USB_SIM, on random
// inputs. The proof shows its claims can never fail; this shows that
// transactions really go through under the same assumptions, and checks
// every assertion on long runs. A scoreboard here, separate from the
// harness, follows the bytes hart a takes and compares every byte hart b
// stores with them.
//
// Hart a's queue gets transactions: a first packet (a PID and 0 to 3 bytes)
// and a second (a PID and 0 to 10 bytes), each ended by STOP, by RESTART for
// the chip's CRC16, or by the queue running dry. The second's PID is mostly a
// data PID (its two lowest bits set), the first's mostly not, and one in
// eight is random. A data packet ended by RESTART is answered; one ended by
// STOP after two bytes of the host's own only when those bytes happen to be
// its CRC16. Sometimes the second packet is queued late, up to 60 bit times
// after the first.
//
// Run by sim_usb.sh. +bit=N is the bit time, +seed=N the random seed,
// +trans=N and +ticks=N end the run, +trace=N prints the first N ticks.
// +noise drives the queue at random every tick instead. +race holds each
// packet back so that it starts on the tick the device's hold trap fires.
// A failed assertion prints "ERROR:", a scoreboard failure "MISMATCH".
`timescale 1ns/1ps
module tb_usb_ind;
    reg clk = 0;
    always #5 clk = ~clk;

    integer    seed, bit_t, want_trans, max_ticks, trace;
    integer    ticks = 0, trans = 0, errors = 0, i, n, late = 0, quiet = 0;
    integer    acks = 0, bytes = 0, bad = 0, packets = 0, noise, race, races = 0;
    reg [10:0] BIT;
    reg [5:0]  start;
    reg [31:0] unwritten;
    reg [1:0]  other;
    reg [1:0]  pend_m;               // what the noise mode drives

    // Hart a's queue as the chip presents it: the head stays until taken.
    reg [7:0]  q [0:63];
    reg [1:0]  qk [0:63];
    integer    nq = 0;
    reg        stall = 0;            // hold the queue back for this tick
    reg        n_valid = 0;
    reg [7:0]  n_data = 0;
    reg [1:0]  n_ctl = 0;
    wire       valid_a = noise ? n_valid : (nq != 0 && !stall);
    wire [7:0] data_a = noise ? n_data : q[0];
    wire [1:0] ctl_a = noise ? n_ctl : qk[0];

    usb_ind dut (.clk(clk), .BIT(BIT), .start(start), .unwritten(unwritten),
        .other(other), .valid_a(valid_a), .data_a(data_a), .ctl_a(ctl_a));

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("bit=%d", bit_t)) bit_t = 16;
        if (!$value$plusargs("trans=%d", want_trans)) want_trans = 20;
        if (!$value$plusargs("ticks=%d", max_ticks)) max_ticks = 2000000;
        if (!$value$plusargs("trace=%d", trace)) trace = 0;
        noise = $test$plusargs("noise");
        race = $test$plusargs("race");
        BIT = bit_t;
        start = {$random(seed)} % 17;
        unwritten = $random(seed);
        other = $random(seed);
    end

    always @(negedge clk) if (ticks < trace)
        $display("%5d A@%0d s%0d k%0d e%0d i%0d run%0d crc%h cnt%0d v%0d | B@%0d s%0d k%0d e%0d i%0d run%0d crc%h cnt%0d v%0d | DP%b DM%b | m%0d t%0d ph%0d bi%0d run%0d jr%0d np%0d due%0d | held%0d/%0d | q%0d%b pop%b push%b%b",
                 ticks, dut.at_a, dut.s_a, dut.k_a, $signed(dut.edge_a - dut.now_a), dut.insd_a,
                 dut.code_a[7:4], dut.code_a[23:8], dut.count_a, dut.viol_a,
                 dut.at_b, dut.s_b, dut.k_b, $signed(dut.edge_b - dut.now_b), dut.insd_b,
                 dut.code_b[7:4], dut.code_b[23:8], dut.count_b, dut.viol_b,
                 dut.dp, dut.dm, dut.m_st, dut.m_t, dut.m_ph, dut.m_bi, dut.m_run, dut.m_jr,
                 dut.m_data, dut.m_due, dut.held_a[15:0], dut.held_b[15:0], nq, valid_a,
                 dut.pop_a, dut.push_a, dut.push_b);

    // +vtrace: each hart's view, what it expects and what the hart holds.
    always @(negedge clk) if (ticks < trace && $test$plusargs("vtrace")) begin
        $display("%5d VA xm%b pre%b tq%0d ah%0d en%b snd%b st%0d t%0d ph%0d bi%0d run%0d nb%0d pl%0d/%0d @%0d k%0d s%0d sin%0d crc%h/%h|%h rl%0d/%0d%0d%0d code%h line%b",
                 ticks, dut.va.x_mid, dut.va.pre, dut.va.tq, dut.va.ahead, dut.va.en, dut.va.snd, dut.va.st, dut.va.t, dut.va.ph, dut.va.bi, dut.va.run, dut.va.nb,
                 dut.va.pl_cur[9:4], dut.va.pl_cur[3:0], dut.va.at, dut.va.k, dut.va.s, dut.va.since,
                 dut.va.code[23:8], dut.va.v_scrc, dut.va.v_crc, dut.va.code[7:4], dut.va.v_rl, dut.va.v_rval, dut.va.v_rv,
                 dut.va.code[7:0], dut.va.line);
        $display("%5d VB tc%0d tok%b aok%b p%0d en%b snd%b st%0d t%0d ph%0d bi%0d run%0d nb%0d pl%0d/%0d @%0d k%0d s%0d sin%0d crc%h/%h|%h rl%0d/%0d%0d%0d code%h line%b f%h/%0d%0d%0d",
                 ticks, dut.vb.tc, dut.vb.tail_ok, dut.vb.aft_ok, dut.vb.p, dut.vb.en, dut.vb.snd, dut.vb.st, dut.vb.t, dut.vb.ph, dut.vb.bi, dut.vb.run, dut.vb.nb,
                 dut.vb.pl_cur[9:4], dut.vb.pl_cur[3:0], dut.vb.at, dut.vb.k, dut.vb.s, dut.vb.since,
                 dut.vb.code[23:8], dut.vb.v_scrc, dut.vb.v_crc, dut.vb.code[7:4], dut.vb.v_rl, dut.vb.v_rval, dut.vb.v_rv,
                 dut.vb.code[7:0], dut.vb.line, dut.f_code[23:8], dut.f_code[7:4], dut.f_code[3], dut.f_code[2]);
    end

    // +gaps: the J before each host packet that follows the handshake.
    always @(negedge clk) if ($test$plusargs("gaps") && !dut.rst && dut.m_sop && !dut.low_b && dut.m_dev)
        $display("GAP %0d %0d", bit_t, dut.m_jr);

    // Every byte hart a took, and the next one hart b must store.
    reg [7:0]  took [0:4095];
    integer    ntook = 0, next_b = 0;
    reg        crc_next = 0;         // hart b's next two stores are the chip's CRC16
    integer    crc_left = 0;

    task fail(input [8*64-1:0] what);
        begin
            errors = errors + 1;
            if (errors <= 6) $display("MISMATCH at %0d: %0s", ticks, what);
        end
    endtask

    // A load runs on a tick hart a is at a load word; this samples just before it.
    always @(posedge clk)
        if (!dut.rst && dut.s_a == dut.S_EXEC && (dut.at_a == dut.PC_PLOAD || dut.at_a == dut.PC_BLOAD)) begin
            took[ntook % 4096] = valid_a ? data_a : 8'hFF;
            ntook = ntook + 1;
        end
    // A RESTART taken: hart b's next two stores are the CRC16, not taken bytes.
    always @(posedge clk)
        if (!dut.rst && dut.s_a == dut.S_EXEC && dut.at_a == dut.PC_CRST && valid_a && ctl_a == 2'd2)
            crc_left = 2;

    task put(input [7:0] v, input [1:0] k);
        begin
            if (nq < 64) begin
                q[nq] = v;
                qk[nq] = k;
                nq = nq + 1;
            end
        end
    endtask
    reg [7:0]  pid;
    // One packet: a PID, n bytes, then an ending: 0 STOP, 1 RESTART, 2 none.
    // A data PID has its two lowest bits set; other PIDs have them anything
    // else, and a few are random.
    task packet(input integer nb, input integer ending, input dat);
        begin
            pid = $random(seed);
            if ({$random(seed)} % 8 != 0) pid[1:0] = dat ? 2'b11 : ({$random(seed)} % 3);
            put(pid, 2'd0);
            for (i = 0; i < nb; i = i + 1)
                put(({$random(seed)} % 3 == 0) ? 8'hFF : ({$random(seed)} % 4 == 0) ? 8'h00 : $random(seed), 2'd0);
            if (ending == 0) put($random(seed), 2'd1);
            else if (ending == 1) put($random(seed), 2'd2);
        end
    endtask
    function integer ending_of(input integer r);
        ending_of = r < 55 ? 1 : r < 85 ? 0 : 2;
    endfunction

    integer second_at = -1, second_n, second_end;
    // Inputs change just after a clock, so the harness sees them settled when
    // it checks at the falling edge and the harts take them at the next clock.
    always @(posedge clk) begin
        #1;
        ticks = ticks + 1;
        other = $random(seed);
        if (dut.pop_a && !noise) begin
            if (nq == 0) fail("hart a took from an empty queue");
            else begin
                for (i = 0; i < 63; i = i + 1) begin
                    q[i] = q[i + 1];
                    qk[i] = qk[i + 1];
                end
                nq = nq - 1;
            end
        end
        if (dut.push_b) begin
            bytes = bytes + 1;
            if (crc_left != 0 && next_b == ntook) crc_left = crc_left - 1;
            else if (next_b >= ntook) fail("hart b stored a byte never sent");
            else begin
                if (dut.pdata_b !== took[next_b % 4096]) fail("hart b stored a wrong byte");
                next_b = next_b + 1;
            end
        end
        if (dut.push_a) begin
            acks = acks + 1;
            if (dut.pdata_a !== 8'hD2) fail("hart a stored something other than ACK");
        end
        if (dut.m_eop_end && !dut.m_dev) packets = packets + 1;
        if (!dut.rst && dut.m_sop && !dut.low_b && dut.held_nx == dut.tmo_t) races = races + 1;
        if (dut.m_eop_end && !dut.m_dev && dut.m_data) begin
            trans = trans + 1;
            if (dut.m_crc != 16'h800D) bad = bad + 1;
        end

        if (noise) begin
            // Anything at all, at any time.
            n_valid = {$random(seed)} % 4 != 0;
            n_data = ({$random(seed)} % 4 == 0) ? 8'hFF : $random(seed);
            n_ctl = ({$random(seed)} % 8 == 0) ? 2'd1 : ({$random(seed)} % 8 == 0) ? 2'd2 : 2'd0;
        end else begin
            // +race: hold the queue back so that the host's K comes on the
            // tick the device's hold trap fires (a claim puts K on the line 3
            // ticks later; the count runs a tick ahead until DM is first seen
            // low).
            stall = race && dut.s_a == dut.S_CLAIM && dut.m_jr + (dut.g_fell ? 3 : 4) < dut.tmo_t;
            if (quiet != 0) quiet = quiet - 1;
            else if (nq == 0 && second_at < 0 && dut.at_a == dut.PC_CLAIM && dut.s_a == dut.S_CLAIM
                     && dut.m_st == 0 && !dut.m_due) begin
                // A new transaction: a token, then a data packet.
                packet({$random(seed)} % 4, ending_of({$random(seed)} % 100), 1'b0);
                second_n = {$random(seed)} % 11;
                second_end = ending_of({$random(seed)} % 100);
                if (race || {$random(seed)} % 5 == 0) begin
                    second_at = ticks + 40 * bit_t + {$random(seed)} % (60 * bit_t);
                    late = late + 1;
                end else packet(second_n, second_end, 1'b1);
                quiet = {$random(seed)} % (25 * bit_t);
            end
            if (second_at >= 0 && ticks >= second_at) begin
                packet(second_n, second_end, 1'b1);
                second_at = -1;
            end
        end

        if (trans >= want_trans || ticks >= max_ticks) begin
            if (errors == 0)
                $display("OK bit %0d transactions %0d packets %0d answered %0d bad %0d late %0d stored %0d ticks %0d races %0d",
                         bit_t, trans, packets, acks, bad, late, bytes, ticks, races);
            $finish;
        end
    end
endmodule
