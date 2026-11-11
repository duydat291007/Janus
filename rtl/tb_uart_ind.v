// Simulates the UART proof harness, uart_ind.sv built with UART_SIM, on random
// inputs. The proof shows its claims can never fail; this shows that frames
// really flow under the same assumptions, and checks every assertion and the
// wire monitor on long runs. A scoreboard here, separate from the harness,
// compares each byte the receiver stores with the byte the queue gave out.
//
// Run by sim_uart.sh. +bit=N is the bit time, +seed=N the random seed,
// +frames=N and +ticks=N end the run. A failed assertion prints "ERROR:",
// a scoreboard failure "MISMATCH".
`timescale 1ns/1ps
module tb_uart_ind;
    reg clk = 0;
    always #5 clk = ~clk;

    integer    seed, bit_time, want_frames, max_ticks;
    integer    ticks = 0, frames = 0, errors = 0, i;
    integer    quiet = 0, burst = 0, longest_wait = 0, back_to_back = 0, since_frame = 0;
    reg [10:0] BIT;
    reg [5:0]  start;
    reg [31:0] unwritten;
    reg [7:0]  addr_a, addr_b, data_b;
    reg        flt, valid_b, low_at_start;
    reg [2:0]  other;
    reg [1:0]  ctl_a, ctl_b;

    // The sender's queue as the chip presents it: the head stays until taken.
    reg [7:0]  queue [0:15];
    integer    count = 0;
    wire       valid_a = count != 0;
    wire [7:0] data_a = queue[0];

    // Bytes taken and not yet stored, oldest first.
    reg [7:0]  owed [0:3];
    integer    owed_n = 0;

    uart_ind dut (.clk(clk), .BIT(BIT), .start(start), .unwritten(unwritten),
        .addr_a(addr_a), .addr_b(addr_b), .flt(flt), .other(other),
        .valid_a(valid_a), .valid_b(valid_b), .data_a(data_a), .data_b(data_b),
        .ctl_a(ctl_a), .ctl_b(ctl_b));

    task noise;
        begin
            flt = $random(seed);
            other = $random(seed);
            valid_b = $random(seed);
            data_b = $random(seed);
            ctl_a = $random(seed);
            ctl_b = $random(seed);
        end
    endtask

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("bit=%d", bit_time)) bit_time = 8;
        if (!$value$plusargs("frames=%d", want_frames)) want_frames = 40;
        if (!$value$plusargs("ticks=%d", max_ticks)) max_ticks = 400000;
        BIT = bit_time;
        start = {$random(seed)} % 56;
        unwritten = $random(seed);
        addr_a = $random(seed);
        addr_b = $random(seed);
        noise;
        low_at_start = !flt;
    end

    // Inputs change just after a clock, so the harness sees them settled when
    // it checks at the falling edge and the harts take them at the next clock.
    always @(posedge clk) begin
        #1;
        ticks = ticks + 1;
        since_frame = since_frame + 1;
        if (dut.pop_a) begin                     // the sender took the head on this clock
            if (count == 0 || owed_n == 4) begin
                errors = errors + 1;
                $display("MISMATCH take with %0d queued and %0d owed", count, owed_n);
            end else begin
                owed[owed_n] = queue[0];
                owed_n = owed_n + 1;
                for (i = 0; i < 15; i = i + 1) queue[i] = queue[i + 1];
                count = count - 1;
            end
        end
        if (dut.push_b) begin                    // the receiver stored a byte on this clock
            if (owed_n == 0 || dut.pdata_b !== owed[0]) begin
                errors = errors + 1;
                $display("MISMATCH stored %h, owed %0d, oldest %h", dut.pdata_b, owed_n, owed[0]);
            end
            for (i = 0; i < 3; i = i + 1) owed[i] = owed[i + 1];
            if (owed_n != 0) owed_n = owed_n - 1;
            frames = frames + 1;
            if (since_frame == 10 * bit_time) back_to_back = back_to_back + 1;
            since_frame = 0;
        end
        // Bytes arrive in bursts, with quiet gaps of up to several thousand
        // ticks between them: longer than the harts' 12-bit time base.
        if (quiet != 0) begin
            quiet = quiet - 1;
            if (count == 0 && quiet > longest_wait) longest_wait = quiet;
        end else if (burst == 0) begin
            burst = 1 + {$random(seed)} % 6;
            quiet = ({$random(seed)} % 4 == 0) ? {$random(seed)} % 9000 : {$random(seed)} % 40;
        end else if (count < 16 && {$random(seed)} % 3 == 0) begin
            queue[count] = $random(seed);
            count = count + 1;
            burst = burst - 1;
        end
        noise;
        if (frames >= want_frames || ticks >= max_ticks) begin
            if (errors == 0 && frames != 0 && owed_n <= 1)
                $display("OK bit %0d start %0d low_at_start %0d frames %0d back_to_back %0d longest_wait %0d ticks %0d",
                         bit_time, start, low_at_start, frames, back_to_back, longest_wait, ticks);
            else
                $display("MISMATCH bit %0d: %0d errors, %0d frames, %0d owed", bit_time, errors,
                         frames, owed_n);
            $finish;
        end
    end
endmodule
