// Unbounded proof by k-induction of a second complete protocol: the SPI
// program from protocols.py, word for word as the assembler emits it, on
// three real harts. Hart c is the controller (role C), hart t the target
// (role T) and hart w a witness, which drives nothing and logs.
//
// uart_ind.sv proves a program of timed bits. This one covers what that could
// not reach: clocked bits, two data lanes moving at once, a byte stream with
// no gap between bytes, and a trap. The target has no clock of its own. It
// follows the controller's clock edges, each seen two ticks after it is
// driven, so it is compared with the controller by where each stands in the
// clock cycle, not tick for tick.
//
// Free, so the result holds for every choice:
//   HALF        the half period, any value from MINHALF to 2047 ticks
//   cpol, cpha  the four SPI modes
//   start       the address the program is loaded at, 0 to 48
//   valid, data all three queues: any bytes, arriving at any time
//   flt         what SCK, MOSI and MISO read while undriven, on every tick
//   flt_cs      what CS reads while undriven
//   unwritten   what the other 48 program words hold
//
// Assumed:
//   - the harts leave reset on the same tick, with the program's one trap
//     set, no prescaler and no adversary fault;
//   - an entry stays at the head of the controller's and the target's queue
//     until the hart pops it, as in janus_fifo (the witness never uses its own);
//   - a pin is low if a hart drives it low, high if one drives it high, and
//     reads its `flt` level otherwise. An undriven CS holds one level, a
//     pull-up or a pull-down: the trap watches CS from the first tick, so a
//     CS that bounced before the controller drove it could cut the set-up
//     short.
//
// Claims:
//   DATA   every byte the target stores is the byte the controller took from
//          its queue for that slot, and every byte the controller stores is
//          the byte the target sent in it: its queue's next byte, or FF when
//          it had none. Stores alternate, one each way per byte, and the
//          controller never sends from an empty queue. A transfer ends only
//          when the controller's queue is empty.
//   WIRE   a monitor that sees only the four wires, and knows only the
//          textbook rules for the mode, reads those same bytes: most
//          significant bit first, eight bits a byte, each bit read on the
//          edge the mode names, with both data lines still across that edge.
//          The clock moves only while CS is low and rests at its idle level
//          when CS falls and when it rises, and a transfer is whole bytes.
//   WITNESS  the witness drives nothing, takes nothing from its queue, and
//          logs both bytes of each slot, the one on MOSI and the one on MISO,
//          on the tick the target stores the first.
//   CLEAN  no hart counts a violation or loses arbitration. The
//          controller alone drives CS, the clock and MOSI; the target alone
//          drives MISO, and only during a transfer.
//   LIVE   a hart rests only in the states listed below. The target follows
//          each clock edge two ticks after the controller drives it, and
//          both harts are back at `idle` together when CS has risen.
//
//   KEPT   no byte leaves either queue unsent. The target takes its next byte
//          as a byte ends, before it knows whether the controller goes on,
//          and so does the controller when it goes on; both keep it queued
//          (`keep`) and pop it as its last bit goes out. A byte cut off when
//          CS rises stays at the head of the queue for the next transfer.
//
// tb_spi_ind.v simulates this same module with SPI_SIM defined: the free
// signals become inputs driven at random, and every assertion is checked once
// a tick. That shows bytes do move under these assumptions.
`ifdef SPI_SIM
module spi_ind (input clk, input [10:0] HALF, input cpol, input cpha, input [5:0] start,
                input [31:0] unwritten, input [7:0] addr_c, addr_t, input flt_cs,
                input [2:0] flt, input valid_c, valid_t, input [7:0] data_c, data_t,
                input [1:0] ctl_c, ctl_t,
                input [7:0] addr_w, input valid_w, input [7:0] data_w, input [1:0] ctl_w);
    parameter MINHALF = 8;

    `include "spi_rom.vh"
`else
module spi_ind (input clk);
    parameter MINHALF = 8;

    `include "spi_rom.vh"

    (* anyconst *) wire [10:0] HALF;
    (* anyconst *) wire        cpol, cpha;
    (* anyconst *) wire [5:0]  start;
    (* anyconst *) wire [31:0] unwritten;
    (* anyconst *) wire [7:0]  addr_c, addr_t;
    (* anyconst *) wire        flt_cs;
    (* anyseq *)   wire [2:0]  flt;
    (* anyseq *)   wire        valid_c, valid_t;
    (* anyseq *)   wire [7:0]  data_c, data_t;
    (* anyseq *)   wire [1:0]  ctl_c, ctl_t;
    (* anyconst *) wire [7:0]  addr_w;
    (* anyseq *)   wire        valid_w;
    (* anyseq *)   wire [7:0]  data_w;
    (* anyseq *)   wire [1:0]  ctl_w;
`endif

    reg [1:0] step = 0;
    wire por = step == 0;
    wire rst = step < 2;
    always @(posedge clk) if (rst) step <= step + 1'b1;

    wire [7:0]  oe_c, ov_c, oe_t, ov_t, count_c, count_t, rx_c, rx_t, pin_c, pin_t, s1_c, s1_t;
    wire [7:0]  armed_c, armed_t, tx_c, tx_t, viol_c, viol_t, vout_c, vout_t, pdata_c, pdata_t;
    wire [7:0]  rx1_c, rx1_t;
    wire [87:0] code_c, code_t;
    wire [111:0] cfg_c, cfg_t;
    wire [47:0] cset_c, cset_t;
    wire [10:0] cnt_c, cnt_t;
    wire [5:0]  pc_c, pc_t;
    wire [3:0]  s_c, s_t, k_c, k_t, prev_c, prev_t;
    wire [4:0]  partial_c, partial_t;
    wire [11:0] now_c, now_t, edge_c, edge_t;
    wire [1:0]  role_c, role_t, src_c, src_t;
    wire        last_c, last_t, mine_c, mine_t, val_c, val_t;
    wire        pop_c, pop_t, clear_c, clear_t, push_c, push_t, seen_c, seen_t, seen2_c, seen2_t;
    wire        lost_c, lost_t;
    wire [3:0]  keep_c, keep_t;
    wire [7:0]  oe_w, ov_w, count_w, rx_w, rx1_w, pin_w, s1_w, armed_w, tx_w, viol_w, vout_w, pdata_w, pdata2_w;
    wire [87:0] code_w;
    wire [111:0] cfg_w;
    wire [47:0] cset_w;
    wire [10:0] cnt_w;
    wire [5:0]  pc_w;
    wire [3:0]  s_w, k_w, prev_w, keep_w;
    wire [4:0]  partial_w;
    wire [11:0] now_w, edge_w;
    wire [1:0]  role_w, src_w;
    wire        last_w, mine_w, val_w, pop_w, clear_w, push_w, seen_w, seen2_w, lost_w;

    // Every pin is push-pull: a hart driving it low wins, one driving it high
    // sets it otherwise, and with no driver it reads its `flt` level. (The
    // witness drives nothing, a claim below.)
    wire [3:0]  low = (oe_c[3:0] & ~ov_c[3:0]) | (oe_t[3:0] & ~ov_t[3:0]);
    wire [3:0]  high = (oe_c[3:0] & ov_c[3:0]) | (oe_t[3:0] & ov_t[3:0]);
    wire [7:0]  bus = {4'hF, ~low & (high | {flt, flt_cs})};

    // Where each hart is in the program, counted from its first word.
    wire [5:0]  at_c = pc_c - start, at_t = pc_t - start, at_w = pc_w - start;
    wire [31:0] ins_c = spi_word(at_c, HALF, cpol, cpha, start, unwritten);
    wire [31:0] ins_t = spi_word(at_t, HALF, cpol, cpha, start, unwritten);
    wire [31:0] ins_w = spi_word(at_w, HALF, cpol, cpha, start, unwritten);

    // The host writes the trap register while the harts are still in reset.
    wire        cfg_we = step == 2'd1;
    wire [15:0] trap0 = spi_trap(start);

    janus_hart c (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_c), .ov(ov_c),
        .od_mask(8'h00), .base_role(2'd0), .reset_pc(start), .addr_reg(addr_c), .pc(pc_c),
        .pc_sel(), .ins(ins_c), .tx_valid(valid_c), .tx_ctl(ctl_c), .tx_data(data_c),
        .tx_pop(pop_c), .tx_clear(clear_c), .rx_push(push_c), .seen_push(seen_c),
        .seen_push2(seen2_c), .push_data(pdata_c), .push_data2(), .violations(vout_c),
        .arb_lost(lost_c), .cfg_we(cfg_we), .cfg_addr(3'd0), .cfg_data(trap0),
        .dbg_s(s_c), .dbg_count(count_c), .dbg_rx(rx_c), .dbg_last(last_c),
        .dbg_now(now_c), .dbg_edge(edge_c), .dbg_dwell(), .dbg_k(k_c),
        .dbg_partial(partial_c), .dbg_role(role_c), .dbg_src(src_c), .dbg_mine(mine_c),
        .dbg_val(val_c), .dbg_pin(pin_c), .dbg_s1(s1_c), .dbg_armed(armed_c),
        .dbg_code(code_c), .dbg_inserted(), .dbg_stuff_bit(), .dbg_width(),
        .dbg_viol(viol_c), .dbg_tx(tx_c), .dbg_cfg(cfg_c), .dbg_cset(cset_c),
        .dbg_cnt(cnt_c), .dbg_rx1(rx1_c), .dbg_prev(prev_c), .dbg_keep(keep_c), .dbg_clean());

    janus_hart t (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_t), .ov(ov_t),
        .od_mask(8'h00), .base_role(2'd1), .reset_pc(start), .addr_reg(addr_t), .pc(pc_t),
        .pc_sel(), .ins(ins_t), .tx_valid(valid_t), .tx_ctl(ctl_t), .tx_data(data_t),
        .tx_pop(pop_t), .tx_clear(clear_t), .rx_push(push_t), .seen_push(seen_t),
        .seen_push2(seen2_t), .push_data(pdata_t), .push_data2(), .violations(vout_t),
        .arb_lost(lost_t), .cfg_we(cfg_we), .cfg_addr(3'd0), .cfg_data(trap0),
        .dbg_s(s_t), .dbg_count(count_t), .dbg_rx(rx_t), .dbg_last(last_t),
        .dbg_now(now_t), .dbg_edge(edge_t), .dbg_dwell(), .dbg_k(k_t),
        .dbg_partial(partial_t), .dbg_role(role_t), .dbg_src(src_t), .dbg_mine(mine_t),
        .dbg_val(val_t), .dbg_pin(pin_t), .dbg_s1(s1_t), .dbg_armed(armed_t),
        .dbg_code(code_t), .dbg_inserted(), .dbg_stuff_bit(), .dbg_width(),
        .dbg_viol(viol_t), .dbg_tx(tx_t), .dbg_cfg(cfg_t), .dbg_cset(cset_t),
        .dbg_cnt(cnt_t), .dbg_rx1(rx1_t), .dbg_prev(prev_t), .dbg_keep(keep_t), .dbg_clean());

    janus_hart w (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_w), .ov(ov_w),
        .od_mask(8'h00), .base_role(2'd3), .reset_pc(start), .addr_reg(addr_w), .pc(pc_w),
        .pc_sel(), .ins(ins_w), .tx_valid(valid_w), .tx_ctl(ctl_w), .tx_data(data_w),
        .tx_pop(pop_w), .tx_clear(clear_w), .rx_push(push_w), .seen_push(seen_w),
        .seen_push2(seen2_w), .push_data(pdata_w), .push_data2(pdata2_w), .violations(vout_w),
        .arb_lost(lost_w), .cfg_we(cfg_we), .cfg_addr(3'd0), .cfg_data(trap0),
        .dbg_s(s_w), .dbg_count(count_w), .dbg_rx(rx_w), .dbg_last(last_w),
        .dbg_now(now_w), .dbg_edge(edge_w), .dbg_dwell(), .dbg_k(k_w),
        .dbg_partial(partial_w), .dbg_role(role_w), .dbg_src(src_w), .dbg_mine(mine_w),
        .dbg_val(val_w), .dbg_pin(pin_w), .dbg_s1(s1_w), .dbg_armed(armed_w),
        .dbg_code(code_w), .dbg_inserted(), .dbg_stuff_bit(), .dbg_width(),
        .dbg_viol(viol_w), .dbg_tx(tx_w), .dbg_cfg(cfg_w), .dbg_cset(cset_w),
        .dbg_cnt(cnt_w), .dbg_rx1(rx1_w), .dbg_prev(prev_w), .dbg_keep(keep_w), .dbg_clean());

    localparam S_BOOT = 4'd0, S_EXEC = 4'd1, S_CLAIM = 4'd2, S_SYNC = 4'd3, S_EDGE = 4'd4,
               S_MID = 4'd5, S_ENTER = 4'd8, S_GAP = 4'd9, S_TOP = 4'd10, S_AW = 4'd11,
               S_AS = 4'd12, S_BW = 4'd13, S_BS = 4'd14;

    wire        c_boot = s_c == S_BOOT, c_exec = s_c == S_EXEC, c_claim = s_c == S_CLAIM;
    wire        c_mid = s_c == S_MID, c_enter = s_c == S_ENTER, c_gap = s_c == S_GAP;
    wire        c_aw = s_c == S_AW, c_bw = s_c == S_BW;
    wire        t_boot = s_t == S_BOOT, t_exec = s_t == S_EXEC, t_claim = s_t == S_CLAIM;
    wire        t_mid = s_t == S_MID, t_gap = s_t == S_GAP, t_as = s_t == S_AS, t_bs = s_t == S_BS;

    wire [11:0] d = {1'b0, HALF};
    wire [11:0] h = {2'b00, HALF[10:1]};         // where a timed bit is sampled
    wire [11:0] since_c = now_c - edge_c, ahead_c = edge_c - now_c;
    wire [11:0] since_t = now_t - edge_t, ahead_t = edge_t - now_t;
    wire [11:0] cnt = {1'b0, cnt_c};             // ticks the controller still waits for its next clock edge

    // Inside the clocked stream. The controller rests while it counts to its
    // leading edge (AW) and to its trailing edge (BW), and for one tick after
    // the trailing edge (GAP). The target rests while it waits to see the
    // leading edge (AS) and the trailing edge (BS), and for one tick after.
    wire        c_run = at_c == PC_DATA && (c_aw || c_bw || c_gap);
    wire        t_run = at_t == PC_DATA && (t_as || t_bs || t_gap);
    wire [3:0]  prev_k = k_c == 0 ? 4'd7 : k_c - 1'b1;
    // Bits of the byte in hand that each hart has put out and taken in. Mode
    // phase 0 puts a bit out before the leading edge and reads at it; phase 1
    // puts it out at the leading edge and reads at the trailing one.
    wire [3:0]  out_c = k_c + (cpha ? (c_bw || c_gap) : 1'b1);
    wire [3:0]  in_c = k_c + (cpha ? c_gap : (c_bw || c_gap));
    wire [3:0]  out_t = k_t + (cpha ? (t_bs || t_gap) : 1'b1);
    wire [3:0]  in_t = k_t + (cpha ? t_gap : (t_bs || t_gap));

    // A rising CS as both harts see it: on the next tick the trap fires.
    wire        trap = !pin_c[0] && s1_c[0];

    // The bytes in flight. The controller always sends a byte it took from
    // its queue. The target sends its queue's next byte, or FF when it has
    // none. These follow the harts' own decisions, taken from the state before
    // each tick, and the assertions below tie them to the harts' outputs.
    reg [7:0]  cur_c = 0, done_c = 0, cur_t = 0, done_t = 0;
    reg        owe = 0;          // the target has yet to store done_c
    reg        vq_c = 0, vq_t = 0;
    reg [7:0]  dq_c = 0, dq_t = 0;   // each queue's head one tick ago
    reg        took_c = 0, ended_c = 0, ended_t = 0;
    reg        kv_c = 0, kv_t = 0;   // the byte in hand is kept: it is still queued
    reg [3:0]  kq_c = 0, kq_t = 0;   // each hart's keep count one tick ago
    reg        trapped = 0;          // the CS trap fired on the last tick
    wire       c_loads = !rst && !trap && c_exec && at_c == PC_LOADC;
    wire       c_ends = !rst && !trap && c_gap && at_c == PC_DATA && k_c == 4'd7;
    wire       t_loads = !rst && !trap && t_exec && at_t == PC_LOADT;
    wire       t_ends = !rst && !trap && t_gap && at_t == PC_DATA && k_t == 4'd7;
    wire [7:0] mosi_byte = owe ? done_c : cur_c; // the byte the target is still reading

    // The monitor. It samples the four wires once a tick, as any device on
    // the bus could, and knows only the textbook rules: the clock idles at
    // cpol, a bit is read on the leading edge in phase 0 and on the trailing
    // edge in phase 1, the most significant bit comes first, and eight bits
    // make a byte. It starts one tick after the controller first drives CS
    // and the clock, when it has a driven level to compare with.
    reg [3:0]  m_prev = 4'hF;    // the wires one tick ago
    reg        m_was = 0;        // and whether they were driven then
    reg [2:0]  m_n = 0;          // bits read of the byte in hand
    reg [7:0]  m_o = 0, m_i = 0; // those bits, from MOSI and from MISO
    wire       m_on = oe_c[0] && oe_c[1] && m_was;
    wire       m_read = m_on && !bus[0] && !m_prev[0] && m_prev[1] != bus[1]
                        && bus[1] == (cpha ? cpol : !cpol);

    always @(posedge clk) begin
        m_prev <= bus[3:0];
        m_was <= !rst && oe_c[0] && oe_c[1];
        if (rst || !m_on || bus[0]) m_n <= 0;
        else if (m_read) begin
            m_o <= {m_o[6:0], bus[2]};
            m_i <= {m_i[6:0], bus[3]};
            m_n <= m_n + 1'b1;
        end
    end

    always @(posedge clk) begin
        vq_c <= valid_c;
        vq_t <= valid_t;
        dq_c <= data_c;
        dq_t <= data_t;
        took_c <= c_loads && valid_c;    // the controller's first byte is popped at once
        kq_c <= keep_c;
        kq_t <= keep_t;
        trapped <= !rst && trap;
        ended_c <= c_ends;
        ended_t <= t_ends;
        if (rst) begin
            cur_c <= 0;
            done_c <= 0;
            cur_t <= 0;
            owe <= 0;
            kv_c <= 0;
            kv_t <= 0;
        end else begin
            if (c_ends) done_c <= cur_c;
            if (c_loads || (c_ends && valid_c)) cur_c <= valid_c ? data_c : 8'hFF;
            if (t_ends) done_t <= cur_t;
            if (c_ends) owe <= 1'b1;
            else if (t_ends) owe <= 1'b0;
            if (t_loads || t_ends) cur_t <= valid_t ? data_t : 8'hFF;
            // Kept bytes: the target's every byte, the controller's refills.
            if (c_loads) kv_c <= 1'b0;
            else if (c_ends && valid_c) kv_c <= 1'b1;
            if (t_loads || t_ends) kv_t <= valid_t;
        end
    end

`ifdef SPI_SIM
    always @(negedge clk) begin                  // once a tick, with everything settled
`else
    always @* begin
`endif
        assume (HALF >= MINHALF);
        assume (start <= MAX_START);
        // Each queue: the entry at its head stays until the hart pops it.
        if (vq_c && !pop_c) assume (valid_c && data_c == dq_c);
        if (vq_t && !pop_t) assume (valid_t && data_t == dq_t);

        assert (step <= 2'd2);
        if (!rst) begin
            // CLEAN
            assert (viol_c == 0 && viol_t == 0 && vout_c == 0 && vout_t == 0);
            assert (!lost_c && !lost_t && !clear_c && !clear_t);
            assert (!seen_c && !seen_t && !seen2_c && !seen2_t);
            // The controller owns CS, SCK and MOSI; the target owns MISO.
            assert (oe_c[7:3] == 0 && oe_t[7:4] == 0 && oe_t[2:0] == 0);

            // WITNESS
            assert (viol_w == 0 && vout_w == 0 && oe_w == 0 && role_w == 2'd3);
            assert (!lost_w && !clear_w && !pop_w && !push_w && keep_w == 0);
            assert (seen_w == push_t && seen2_w == push_t);
            if (push_t) assert (pdata_w == done_c && pdata2_w == done_t);

            // DATA
            if (c_loads) assert (valid_c);
            // The byte that let the controller leave the claim is still there.
            if (at_c == PC_SELECT || at_c == PC_LOADC) assert (vq_c && !pop_c);
            if (c_ends) assert (!owe);           // the target stored the byte before
            // A transfer ends only when the controller has nothing left to send.
            if (at_c == PC_DESELECT && c_exec) assert (!vq_c);
            if (t_ends) assert (owe);            // and stores only a byte it is owed
            if (push_t) assert (pdata_t == done_c);
            if (push_c) assert (pdata_c == cur_t);
            // A kept byte is popped exactly when its last bit goes out: its
            // keep count runs from 1 to 0 on a tick with no trap.
            assert (pop_c == (took_c || (kq_c == 4'd1 && keep_c == 0 && vq_c && !trapped)));
            assert (pop_t == (kq_t == 4'd1 && keep_t == 0 && vq_t && !trapped));

            // KEPT: the keep count is the bits of the kept byte still to go.
            assert (keep_c == (c_run && kv_c ? 4'd8 - out_c : 4'd0));
            // The controller's first byte comes from an ordinary load, never kept.
            if (at_c == PC_LOADT || (at_c == PC_DATA && !c_run)) assert (!kv_c);
            assert (keep_t == ((t_run || (at_t == PC_DATA && t_exec)) && kv_t
                               ? 4'd8 - (t_run ? out_t : 4'd0) : 4'd0));
            // While a byte is kept, it is the head of its queue.
            if (keep_c != 0) assert (vq_c && dq_c == cur_c);
            if (keep_t != 0) assert (vq_t && dq_t == cur_t);
            assert (push_c == ended_c && push_t == ended_t);

            // WIRE: what the monitor is about to read.
            if (m_read) begin
                // Both data lines hold still across the edge that reads them.
                assert (m_prev[2] == bus[2] && m_prev[3] == bus[3]);
                if (m_n == 3'd7) assert ({m_o[6:0], bus[2]} == cur_c && {m_i[6:0], bus[3]} == cur_t);
            end
            if (m_on) begin
                // The clock moves only while CS is low, and rests at cpol
                // when CS falls and when it rises. A transfer is whole bytes.
                if (m_prev[1] != bus[1]) assert (!bus[0] && !m_prev[0]);
                if (m_prev[0] != bus[0]) assert (bus[1] == cpol && m_prev[1] == cpol && m_n == 0);
            end

            // The monitor against the controller.
            assert (m_prev == s1_c[3:0]);
            assert (at_c == PC_IDLE || m_was == (at_c > PC_IDLE));
            assert (m_n == (!c_run ? 3'd0 : cpha ? k_c[2:0]
                            : k_c[2:0] + ((c_bw && cnt <= d - 12'd3) || c_gap)));
            if (m_n != 0) begin
                assert ((m_o & ~(8'hFF << m_n)) == (cur_c >> (4'd8 - m_n)));
                assert ((m_i & ~(8'hFF << m_n)) == (cur_t >> (4'd8 - m_n)));
            end

            // Fixed for the whole run.
            assert (role_c == 2'd0 && role_t == 2'd1 && count_c == 0 && count_t == 0);
            assert (cfg_c == {96'd0, trap0} && cfg_t == {96'd0, trap0});
            assert (cset_c[47:11] == {1'b0, 2'd0, 2'd3, 6'd0, 8'd0, 8'd0, 1'b0, 6'd0, 3'd0});
            assert (cset_t[47:11] == {1'b0, 2'd0, 2'd3, 6'd0, 8'd0, 8'd0, 1'b0, 6'd0, 3'd0});
            assert (now_c == now_t && pin_c == pin_t && s1_c == s1_t);
            assert (at_c < PROG_LEN && at_t < PROG_LEN);

            // The witness is where the target is, in every state: neither owns
            // the clock or a choice.
            assert (at_w == at_t && s_w == s_t && k_w == k_t && edge_w == edge_t && now_w == now_t);
            assert (rx_w == rx_t && rx1_w == rx1_t && armed_w == armed_t && partial_w == partial_t);
            assert (pin_w == pin_t && s1_w == s1_t && count_w == 0 && cfg_w == cfg_t && code_w == code_t && cset_w == cset_t);
            if (t_mid) assert (!mine_w && src_w == src_t);

            // What the set-up has written so far, in each hart.
            assert (code_c == {63'd0, at_c > PC_MSB, 24'd0});
            assert (code_t == {63'd0, at_t > PC_MSB, 24'd0});
            assert (cset_c[10:0] == {at_c > PC_CLK ? PIN_SCK : 2'd0, 2'd0, at_c > PC_CPOL && cpol,
                                     at_c > PC_CPHA && cpha, at_c > PC_LANE,
                                     at_c > PC_LANE ? PIN_MISO : 2'd0, at_c > PC_LANE ? 2'd1 : 2'd0});
            assert (cset_t[10:0] == {at_t > PC_CLK ? PIN_SCK : 2'd0, 2'd0, at_t > PC_CPOL && cpol,
                                     at_t > PC_CPHA && cpha, at_t > PC_LANE,
                                     at_t > PC_LANE ? PIN_MISO : 2'd0, at_t > PC_LANE ? 2'd1 : 2'd0});

            // LIVE: the states a hart can rest in, and how long.
            assert (c_boot || c_exec || c_claim || c_mid || c_enter || c_gap || c_aw || c_bw);
            assert (t_boot || t_exec || t_claim || t_mid || t_gap || t_as || t_bs);
            if (c_boot) assert (at_c == PC_MSB);
            if (c_claim) assert (at_c == PC_CLAIM);
            if (c_mid) assert (at_c == PC_SELECT || at_c == PC_DESELECT);
            if (c_enter || c_gap || c_aw || c_bw) assert (at_c == PC_DATA);
            if (t_boot) assert (at_t == PC_MSB);
            if (t_claim) assert (at_t == PC_CLAIM);
            if (t_mid) assert (at_t == PC_SELECT);
            if (t_gap || t_as || t_bs) assert (at_t == PC_DATA);
            assert (at_c != PC_JUMP && at_t != PC_DESELECT && at_t != PC_JUMP);
            assert (partial_c[0] == (at_c == PC_DATA && k_c != 0));
            assert (partial_t[0] == (at_t == PC_DATA && k_t != 0));
            assert (k_c <= 4'd7 && k_t <= 4'd7);
            if (!c_run && !(at_c == PC_DESELECT && c_exec)) assert (k_c == 0);
            if (!t_run) assert (k_t == 0);
            if (c_aw || c_bw) assert (cnt <= d - 12'd2);
            assert (ahead_t <= d || t_mid);

            // The CS line. The controller drives it from its seventh word on.
            assert (oe_c[0] == (at_c > PC_SETCS) && oe_c[1] == (at_c > PC_SETCK));
            if (at_c <= PC_SETCK) assert (s1_c[0] == flt_cs && pin_c[0] == flt_cs);
            if (at_c == PC_SETCK || at_c == PC_IDLE || at_c == PC_CLAIM) assert (ov_c[0]);
            if (at_c == PC_IDLE) assert (s1_c[0] && (pin_c[0] || !flt_cs));
            if (at_c == PC_CLAIM) assert (s1_c[0] && pin_c[0]);
            if (at_c == PC_SELECT && c_exec) assert (ov_c[0] && s1_c[0] && pin_c[0]);
            if (at_c == PC_SELECT && c_mid)
                assert (!ov_c[0] && s1_c[0] == (since_c == 0) && pin_c[0] == (since_c <= 1));
            if (at_c == PC_LOADC || at_c == PC_LOADT || at_c == PC_DATA
                    || (at_c == PC_DESELECT && c_exec))
                assert (!ov_c[0] && !s1_c[0] && !pin_c[0]);
            if (at_c == PC_DESELECT && c_mid)
                assert (ov_c[0] && since_c <= 1 && !pin_c[0] && s1_c[0] == (since_c == 1));

            // The controller's timed bits, and its bit edge elsewhere.
            if (c_mid) assert (mine_c && src_c == ins_c[22:21] && val_c == ins_c[21] && since_c < h);
            if (at_c <= PC_SELECT && !c_mid) assert (edge_c == now_c);
            if (at_c == PC_LOADC) assert (c_exec && ahead_c == d - h);
            if (at_c == PC_LOADT) assert (c_exec && ahead_c == d - h - 12'd1);
            if (at_c == PC_DATA && c_exec) assert (ahead_c == d - h - 12'd2);
            if (c_enter) assert (ahead_c != 0 && ahead_c <= d - h - 12'd3);
            if (c_run || (at_c == PC_DESELECT && c_exec)) assert (edge_c == now_c);

            // The clock line. It idles at cpol; the leading edge takes it away.
            if (at_c > PC_SETCK && !c_run) assert (ov_c[1] == cpol);
            if (c_run) assert (ov_c[1] == (c_bw ? !cpol : cpol));
            if (at_c == PC_CLAIM) assert (s1_c[1] == cpol && (c_exec || pin_c[1] == cpol));
            if (at_c == PC_SELECT || at_c == PC_LOADC || at_c == PC_LOADT
                    || (at_c == PC_DATA && (c_exec || c_enter)))
                assert (s1_c[1] == cpol && pin_c[1] == cpol);
            if (c_run) assert (s1_c[1] == (((c_bw && cnt == d - 12'd2) || c_gap) ? !ov_c[1] : ov_c[1]));
            if (at_c == PC_DESELECT) assert (s1_c[1] == cpol && pin_c[1] == (c_exec ? !cpol : cpol));
            if (t_as || t_gap) assert (pin_c[1] == cpol);
            if (t_bs) assert (pin_c[1] == !cpol);

            // The target against the controller.
            if (at_c <= PC_IDLE || (at_c == PC_CLAIM && !(t_run || at_t == PC_IDLE))) begin
                // Set-up and idle: side by side.
                assert (at_t == at_c && s_t == s_c && edge_t == edge_c);
            end
            if (at_c == PC_CLAIM) assert (at_t == PC_CLAIM && s_t == s_c);
            if (at_c == PC_SELECT && c_exec) assert (t_claim);
            if (at_c == PC_SELECT && c_mid) begin
                // The target sees CS fall two ticks after it is driven.
                if (since_c <= 1) assert (t_claim);
                if (since_c == 2) assert (at_t == PC_SELECT && t_exec);
                if (since_c >= 3) assert (at_t == PC_SELECT && t_mid && since_t == since_c - 12'd1);
            end
            if (at_c == PC_LOADC) assert (at_t == PC_SELECT && t_mid && since_t == h - 12'd1);
            if (at_c == PC_LOADT) assert (at_t == PC_LOADC && t_exec);
            if (at_c == PC_DATA && c_exec) assert (at_t == PC_LOADT && t_exec);
            if (c_enter) assert (at_t == PC_DATA
                                 && (ahead_c == d - h - 12'd3 ? t_exec : (t_as && k_t == 0)));
            if (t_mid) assert (!mine_t && src_t == 2'd2);
            if (at_t == PC_CLAIM || (at_t == PC_SELECT && t_exec)) assert (armed_t[0]);
            if (c_aw) begin
                // Counting to the leading edge. The target is still on the
                // bit before for two ticks after a trailing edge.
                if (cnt == d - 12'd2)
                    begin assert ((t_bs && k_t == prev_k) || (k_c == 0 && t_as && k_t == 0)); end
                else if (cnt == d - 12'd3)
                    begin assert ((t_gap && k_t == prev_k) || (k_c == 0 && t_as && k_t == 0)); end
                else assert (t_as && k_t == k_c);
            end
            if (c_bw) assert (k_t == k_c && (cnt >= d - 12'd3 ? t_as : t_bs));
            if (c_gap) assert (t_bs && k_t == k_c);
            if (at_c == PC_DESELECT && c_exec) assert (t_bs && k_t == 4'd7 && k_c == 4'd7);
            if (at_c == PC_DESELECT && c_mid)
                assert (since_c == 0 ? (t_gap && k_t == 4'd7) : (t_as && k_t == 0));
            if (t_run) assert (at_c == PC_DATA || at_c == PC_DESELECT);

            // DATA, bit by bit. Each hart has put `out` bits of its byte on
            // its line and holds the next `in` bits of the other's byte.
            assert (owe == ((c_aw && k_c == 0 && cnt >= d - 12'd3 && !t_as)
                            || (at_c == PC_DESELECT && (c_exec || since_c == 0))));
            if (at_c == PC_LOADT || (at_c == PC_DATA && (c_exec || c_enter))) assert (tx_c == cur_c);
            if (c_run) begin
                assert (tx_c == (cur_c << out_c));
                if (out_c != 0) assert (oe_c[2] && ov_c[2] == cur_c[4'd8 - out_c]);
                if (in_c != 0) assert ((rx1_c & ~(8'hFF << in_c)) == (cur_t >> (4'd8 - in_c)));
            end
            if (owe && (c_run || at_c == PC_DESELECT) && (!c_run || out_c == 0))
                assert (oe_c[2] && ov_c[2] == done_c[0]);
            if (at_t == PC_DATA && t_exec) assert (tx_t == cur_t);
            if (t_run) begin
                assert (tx_t == (cur_t << out_t));
                if (out_t != 0) assert (oe_t[3] && ov_t[3] == cur_t[4'd8 - out_t]);
                if (in_t != 0) assert ((rx_t & ~(8'hFF << in_t)) == (mosi_byte >> (4'd8 - in_t)));
                // The byte on MISO, as the witness reads it beside the target.
                if (in_t != 0) assert ((rx1_t & ~(8'hFF << in_t)) == (cur_t >> (4'd8 - in_t)));
            end
            if (!t_run && at_t != PC_IDLE) assert (!oe_t[3]);

            // The data lines one tick later, where the other hart reads them.
            if (cpha ? (c_bw && cnt <= d - 12'd3) || c_gap || (c_aw && out_c != 0)
                        || (at_c == PC_DESELECT && c_exec)
                     : (c_aw && cnt <= d - 12'd3) || c_bw)
                assert (s1_c[2] == ov_c[2]);
            if (cpha ? (c_bw && cnt <= d - 12'd5) || c_gap
                     : (c_aw && cnt <= d - 12'd5) || c_bw || c_gap)
                assert (oe_t[3] && s1_c[3] == ov_t[3]);
            // In phase 1 the target's bit stays on until its next leading edge,
            // past the trailing edge the witness reads it on.
            if (cpha && ((c_aw && cnt >= d - 12'd3 && !t_as) || (at_c == PC_DESELECT && c_exec)))
                assert (oe_t[3] && s1_c[3] == ov_t[3]);
        end
    end
endmodule
