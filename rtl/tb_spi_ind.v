// Simulates the SPI proof harness, spi_ind.sv built with SPI_SIM, on random
// inputs. The proof shows its claims can never fail; this shows that bytes
// really move both ways under the same assumptions, and checks every assertion
// on long runs. A scoreboard here, separate from the harness, compares what
// each side stores with what the other side's queue gave out.
//
// Run by sim_spi.sh. +half=N is the half period, +cpol and +cpha the mode,
// +seed=N the random seed, +bytes=N and +ticks=N end the run, and +trace=N
// prints the first N ticks. A failed assertion prints "ERROR:", a scoreboard
// failure "MISMATCH".
`timescale 1ns/1ps
module tb_spi_ind;
    reg clk = 0;
    always #5 clk = ~clk;

    integer    seed, half, want_bytes, max_ticks, trace;
    integer    ticks = 0, bytes = 0, frames = 0, errors = 0, i;
    integer    quiet_c = 0, burst_c = 0, quiet_t = 0, burst_t = 0, ff_bytes = 0, dropped = 0;
    reg [10:0] HALF;
    reg        cpol, cpha, flt_cs, cs_was = 1, took_since = 0;
    reg [5:0]  start;
    reg [31:0] unwritten;
    reg [7:0]  addr_c, addr_t;
    reg [2:0]  flt;
    reg [1:0]  ctl_c, ctl_t;

    // Both queues as the chip presents them: the head stays until taken.
    reg [7:0]  qc [0:15], qt [0:15];
    integer    nc = 0, nt = 0;
    wire       valid_c = nc != 0, valid_t = nt != 0;
    wire [7:0] data_c = qc[0], data_t = qt[0];

    // Bytes the controller took and the target has not stored yet.
    reg [7:0]  owed [0:3];
    integer    owed_n = 0;
    // The byte the target is sending in this slot: FF unless it took one.
    reg [7:0]  t_slot = 8'hFF;

    reg        valid_w = 0;          // what the witness finds queued
    reg [7:0]  data_w = 0, last_c = 0;   // last_c: the last byte the controller stored
    reg [1:0]  ctl_w = 0;
    integer    logged = 0;
    spi_ind dut (.addr_w(addr_c ^ 8'h5A), .valid_w(valid_w), .data_w(data_w), .ctl_w(ctl_w), .clk(clk), .HALF(HALF), .cpol(cpol), .cpha(cpha), .start(start),
        .unwritten(unwritten), .addr_c(addr_c), .addr_t(addr_t), .flt_cs(flt_cs), .flt(flt),
        .valid_c(valid_c), .valid_t(valid_t), .data_c(data_c), .data_t(data_t),
        .ctl_c(ctl_c), .ctl_t(ctl_t));

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("half=%d", half)) half = 8;
        if (!$value$plusargs("bytes=%d", want_bytes)) want_bytes = 60;
        if (!$value$plusargs("ticks=%d", max_ticks)) max_ticks = 400000;
        if (!$value$plusargs("trace=%d", trace)) trace = 0;
        if (!$value$plusargs("cpol=%d", i)) i = 0;
        cpol = i;
        if (!$value$plusargs("cpha=%d", i)) i = 0;
        cpha = i;
        HALF = half;
        start = {$random(seed)} % 49;
        unwritten = $random(seed);
        addr_c = $random(seed);
        addr_t = $random(seed);
        flt_cs = $random(seed);
        flt = $random(seed);
        ctl_c = 0;
        ctl_t = 0;
    end

    always @(negedge clk) if (ticks < trace)
        $display("%5d C@%0d s%0d k%0d cnt%0d e%0d | T@%0d s%0d k%0d | CS%b SCK%b MOSI%b MISO%b | oeC%b oeT%b | popC%b popT%b pushC%b pushT%b",
                 ticks, dut.at_c, dut.s_c, dut.k_c, dut.cnt_c, dut.edge_c - dut.now_c,
                 dut.at_t, dut.s_t, dut.k_t, dut.bus[0], dut.bus[1], dut.bus[2], dut.bus[3],
                 dut.oe_c[3:0], dut.oe_t[3:0], dut.pop_c, dut.pop_t, dut.push_c, dut.push_t);

    // Inputs change just after a clock, so the harness sees them settled when
    // it checks at the falling edge and the harts take them at the next clock.
    always @(posedge clk) begin
        #1;
        ticks = ticks + 1;
        if (cs_was && !dut.bus[0]) begin         // a transfer starts
            frames = frames + 1;
            if (took_since) dropped = dropped + 1;   // a byte taken ahead and never sent
            t_slot = 8'hFF;
            took_since = 0;
        end
        cs_was = dut.bus[0];
        if (dut.pop_c) begin                     // the controller took its head
            if (nc == 0 || owed_n == 4) begin
                errors = errors + 1;
                $display("MISMATCH controller took with %0d queued, %0d owed", nc, owed_n);
            end else begin
                owed[owed_n] = qc[0];
                owed_n = owed_n + 1;
                for (i = 0; i < 15; i = i + 1) qc[i] = qc[i + 1];
                nc = nc - 1;
            end
        end
        if (dut.pop_t) begin                     // the target took its head
            if (nt == 0) begin
                errors = errors + 1;
                $display("MISMATCH target took from an empty queue");
            end else begin
                t_slot = qt[0];
                took_since = 1;
                for (i = 0; i < 15; i = i + 1) qt[i] = qt[i + 1];
                nt = nt - 1;
            end
        end
        if (dut.seen_w || dut.seen2_w) begin     // the witness logged a slot's two bytes
            if (!dut.seen_w || !dut.seen2_w || owed_n == 0 || dut.pdata_w !== owed[0] || dut.pdata2_w !== last_c) begin
                errors = errors + 1;
                $display("MISMATCH witness logged %h %h, sent %h %h", dut.pdata_w, dut.pdata2_w, owed[0], last_c);
            end
            logged = logged + 1;
        end
        {valid_w, data_w, ctl_w} = $random(seed);
        if (dut.push_t) begin                    // the target stored a byte from MOSI
            if (owed_n == 0 || dut.pdata_t !== owed[0]) begin
                errors = errors + 1;
                $display("MISMATCH target stored %h, owed %0d, oldest %h", dut.pdata_t, owed_n, owed[0]);
            end
            for (i = 0; i < 3; i = i + 1) owed[i] = owed[i + 1];
            if (owed_n != 0) owed_n = owed_n - 1;
            bytes = bytes + 1;
        end
        if (dut.push_c) last_c = dut.pdata_c;
        if (dut.push_c) begin                    // the controller stored a byte from MISO
            if (dut.pdata_c !== t_slot) begin
                errors = errors + 1;
                $display("MISMATCH controller stored %h, target sent %h", dut.pdata_c, t_slot);
            end
            if (t_slot === 8'hFF && !took_since) ff_bytes = ff_bytes + 1;
            t_slot = 8'hFF;                      // unless the target takes another
            took_since = 0;
        end
        // Bytes arrive in bursts on each side, with quiet gaps between them.
        if (quiet_c != 0) quiet_c = quiet_c - 1;
        else if (burst_c == 0) begin
            burst_c = 1 + {$random(seed)} % 5;
            quiet_c = ({$random(seed)} % 4 == 0) ? {$random(seed)} % 9000 : {$random(seed)} % 60;
        end else if (nc < 16 && {$random(seed)} % 3 == 0) begin
            qc[nc] = $random(seed);
            nc = nc + 1;
            burst_c = burst_c - 1;
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
        flt = $random(seed);
        ctl_c = $random(seed);
        ctl_t = $random(seed);
        if (bytes >= want_bytes || ticks >= max_ticks) begin
            if (errors == 0 && logged == bytes && bytes != 0 && owed_n <= 1)
                $display("OK half %0d mode %0d%0d start %0d bytes %0d frames %0d target_ff %0d dropped %0d ticks %0d",
                         half, cpol, cpha, start, bytes, frames, ff_bytes, dropped, ticks);
            else
                $display("MISMATCH half %0d mode %0d%0d: %0d errors, %0d bytes, %0d owed", half,
                         cpol, cpha, errors, bytes, owed_n);
            $finish;
        end
    end
endmodule
