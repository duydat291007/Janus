// Simulates the 1-Wire proof harness, onewire_ind.sv built with OW_SIM, on
// random inputs: every assertion is checked once a tick, and a scoreboard
// here compares what each side stores with what the other side's queue gave.
//
// Run by sim_onewire.sh. +seed=N is the random seed, +bytes=N and +ticks=N
// end the run, +trace=N prints the first N ticks, and +changes=N prints the
// first N ticks on which a hart or the line moved. A failed assertion prints
// "ERROR:", a scoreboard failure "MISMATCH".
`timescale 1ns/1ps
module tb_onewire_ind;
    reg clk = 0;
    always #5 clk = ~clk;

    integer    seed, want_bytes, max_ticks, trace;
    integer    ticks = 0, written = 0, read = 0, resets = 0, errors = 0, i;
    integer    quiet_c = 0, burst_c = 0, quiet_t = 0, burst_t = 0;
    reg [5:0]  start;
    reg [31:0] unwritten;
    reg [7:0]  addr_c, addr_t;
    reg [2:0]  other;
    reg [1:0]  ctl_c, ctl_t;

    // Both queues as the chip presents them: the head stays until taken.
    reg [7:0]  qc [0:15], qt [0:15];
    integer    nc = 0, nt = 0;
    wire       valid_c = nc != 0, valid_t = nt != 0;
    wire [7:0] data_c = qc[0], data_t = qt[0];

    reg [7:0]  written_byte = 0, t_slot = 8'hFF;
    reg        owed = 0;

    reg        valid_w = 0;          // what the witness finds queued
    reg [7:0]  data_w = 0;
    reg [1:0]  ctl_w = 0;
    integer    logged = 0, presences = 0;
    onewire_ind dut (.addr_w(addr_c ^ 8'h5A), .valid_w(valid_w), .data_w(data_w), .ctl_w(ctl_w), .clk(clk), .start(start), .unwritten(unwritten), .addr_c(addr_c),
        .addr_t(addr_t), .other(other), .valid_c(valid_c), .valid_t(valid_t),
        .data_c(data_c), .data_t(data_t), .ctl_c(ctl_c), .ctl_t(ctl_t));

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("bytes=%d", want_bytes)) want_bytes = 30;
        if (!$value$plusargs("ticks=%d", max_ticks)) max_ticks = 400000;
        if (!$value$plusargs("trace=%d", trace)) trace = 0;
        start = {$random(seed)} % 36;
        unwritten = $random(seed);
        addr_c = $random(seed);
        addr_t = $random(seed);
        other = $random(seed);
        ctl_c = 0;
        ctl_t = 0;
    end

    always @(negedge clk) if (ticks < trace)
        $display("%6d C@%0d s%0d k%0d e%0d n%0d | T@%0d s%0d k%0d e%0d | DQ%b oe%b%b | held %0d %0d | pop%b%b push%b%b %h %h",
                 ticks, dut.at_c, dut.s_c, dut.k_c, $signed(dut.edge_c - dut.now_c), dut.count_c,
                 dut.at_t, dut.s_t, dut.k_t, $signed(dut.edge_t - dut.now_t), dut.bus[0],
                 dut.oe_c[0], dut.oe_t[0], dut.held_c[15:0], dut.held_c[31:16],
                 dut.pop_c, dut.pop_t, dut.push_c, dut.push_t, dut.pdata_c, dut.pdata_t);

    // +changes=N prints the first N ticks on which either hart or the line moved.
    integer    changes = 0;
    reg [63:0] shown = 0;
    wire [63:0] show = {dut.at_c, dut.s_c, dut.at_t, dut.s_t, dut.bus[0], dut.oe_c[0], dut.ov_c[0],
                        dut.oe_t[0], dut.ov_t[0], dut.pin_c[0], dut.s1_c[0], dut.k_c, dut.k_t,
                        dut.armed_c[0], dut.armed_t[0]};
    initial if (!$value$plusargs("changes=%d", changes)) changes = 0;
    always @(negedge clk) if (changes != 0 && show !== shown) begin
        shown = show;
        changes = changes - 1;
        $display("%6d C@%0d s%0d k%0d e%0d n%0d a%b | T@%0d s%0d k%0d e%0d n%0d a%b | DQ%b c%b%b t%b%b s1 %b pin %b | held %0d %0d | rx %h %h tx %h %h",
                 ticks, dut.at_c, dut.s_c, dut.k_c, $signed(dut.edge_c - dut.now_c), dut.count_c,
                 dut.armed_c[0], dut.at_t, dut.s_t, dut.k_t, $signed(dut.edge_t - dut.now_t),
                 dut.count_t, dut.armed_t[0], dut.bus[0], dut.oe_c[0], dut.ov_c[0], dut.oe_t[0],
                 dut.ov_t[0], dut.s1_c[0], dut.pin_c[0], dut.held_c[15:0], dut.held_c[31:16],
                 dut.rx_c, dut.rx_t, dut.tx_c, dut.tx_t);
    end

    always @(posedge clk) begin
        #1;
        ticks = ticks + 1;
        if (dut.pop_c) begin                     // the controller took its head
            if (nc == 0) begin
                errors = errors + 1;
                $display("MISMATCH controller took from an empty queue");
            end else begin
                if (dut.at_c == 14) begin        // the byte to write
                    written_byte = qc[0];
                    owed = 1;
                    resets = resets + 1;
                end
                for (i = 0; i < 15; i = i + 1) qc[i] = qc[i + 1];
                nc = nc - 1;
            end
        end
        if (dut.pop_t) begin
            t_slot = qt[0];
            for (i = 0; i < 15; i = i + 1) qt[i] = qt[i + 1];
            nt = nt - 1;
        end
        // The witness logs what the harts store, and the presence byte.
        if (dut.push_c && dut.at_c != 29) presences = presences + 1;
        if (dut.seen_w) begin
            logged = logged + 1;
            if (dut.push_t ? dut.pdata_w !== dut.pdata_t
                : !dut.push_c || (dut.at_c == 29 ? dut.pdata_w !== dut.pdata_c : dut.pdata_w[7] !== dut.pdata_c[7])) begin
                errors = errors + 1;
                $display("MISMATCH witness logged %h, target %b %h, controller %b %h", dut.pdata_w,
                         dut.push_t, dut.pdata_t, dut.push_c, dut.pdata_c);
            end
        end
        {valid_w, data_w, ctl_w} = $random(seed);
        if (dut.push_t) begin                    // the target stored the written byte
            if (!owed || dut.pdata_t !== written_byte) begin
                errors = errors + 1;
                $display("MISMATCH target stored %h, written %h, owed %b", dut.pdata_t, written_byte, owed);
            end
            owed = 0;
            written = written + 1;
        end
        if (dut.push_c && dut.at_c == 29) begin  // the controller stored a byte it read
            if (dut.pdata_c !== t_slot) begin
                errors = errors + 1;
                $display("MISMATCH controller read %h, target sent %h", dut.pdata_c, t_slot);
            end
            t_slot = 8'hFF;
            read = read + 1;
        end
        if (quiet_c != 0) quiet_c = quiet_c - 1;
        else if (burst_c == 0) begin
            burst_c = 1 + {$random(seed)} % 4;
            quiet_c = ({$random(seed)} % 3 == 0) ? {$random(seed)} % 9000 : {$random(seed)} % 200;
        end else if (nc < 16 && {$random(seed)} % 3 == 0) begin
            qc[nc] = $random(seed);
            nc = nc + 1;
            burst_c = burst_c - 1;
        end
        if (quiet_t != 0) quiet_t = quiet_t - 1;
        else if (burst_t == 0) begin
            burst_t = 1 + {$random(seed)} % 4;
            quiet_t = ({$random(seed)} % 3 == 0) ? {$random(seed)} % 9000 : {$random(seed)} % 200;
        end else if (nt < 16 && {$random(seed)} % 3 == 0) begin
            qt[nt] = $random(seed);
            nt = nt + 1;
            burst_t = burst_t - 1;
        end
        other = $random(seed);
        ctl_c = $random(seed);
        ctl_t = $random(seed);
        if (written + read >= want_bytes || ticks >= max_ticks) begin
            if (errors == 0 && written != 0 && logged == written + read + presences)
                $display("OK start %0d resets %0d written %0d read %0d ticks %0d", start, resets,
                         written, read, ticks);
            else
                $display("MISMATCH %0d errors, %0d written, %0d read", errors, written, read);
            $finish;
        end
    end
endmodule
