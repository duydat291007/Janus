// Stage B of the CAN proof: both harts may have frames to send. The CAN
// program from protocols.py, word for word as the assembler emits it, on two
// real harts that both start as possible senders and both have a queue.
//
// A hart with a frame claims the bus as soon as it is at `idle`; one that
// sees a start of frame first claims the receiver role. So two harts with
// frames can both claim and arbitrate: they send in lockstep until the first
// identifier bit where they differ, and the one sending recessive reads
// dominant and loses. Their starts of frame can be up to 4 ticks apart, as a
// hart sees the bus two ticks late and runs four instructions from the claim
// to its start of frame. That is the usual case: two harts with frames
// queued during a frame reach `idle` two to four ticks apart at its end.
//
// Free: BIT from MINBIT to 2047 ticks, the load address, both queues (any
// entries, arriving, changing or leaving at any time), the three unused pins,
// and the unwritten program words.
//
// Assumed:
//   - both harts leave reset on the same tick, with the program's hold trap
//     set, no prescaler and no adversary fault;
//   - the hosts queue base data frames: when a hart takes its control field,
//     the entry is there and its RTR and IDE bits are clear;
//   - two frames that arbitrate have different identifiers, as CAN requires:
//     when a hart takes its second identifier byte while the other, still a
//     sender in the same frame with the same top bits, already has its own,
//     or takes its own on the same tick, the two bytes differ;
//   - BUS is open drain with a pull-up: low exactly when a hart drives it low.
//
// tb_can_arb_ind.v simulates this module with CAN_SIM defined.
`ifdef CAN_SIM
module can_arb_ind (input clk, input [10:0] BIT, input [5:0] start, input [31:0] unwritten,
                    input [7:0] addr_a, addr_b, input [2:0] other,
                    input valid_a, input [7:0] data_a, input [1:0] ctl_a,
                    input valid_b, input [7:0] data_b, input [1:0] ctl_b);
    parameter MINBIT = 12;

    `include "can_rom.vh"
`else
module can_arb_ind (input clk);
    parameter MINBIT = 12;

    `include "can_rom.vh"

    (* anyconst *) wire [10:0] BIT;
    (* anyconst *) wire [5:0]  start;
    (* anyconst *) wire [31:0] unwritten;
    (* anyconst *) wire [7:0]  addr_a, addr_b;
    (* anyseq *)   wire [2:0]  other;
    (* anyseq *)   wire        valid_a, valid_b;
    (* anyseq *)   wire [7:0]  data_a, data_b;
    (* anyseq *)   wire [1:0]  ctl_a, ctl_b;
`endif

    // Reset: one tick of power-on reset, then two in which the host writes
    // the hold trap's two registers while the harts are held.
    reg [1:0] step = 0;
    wire por = step == 0;
    wire rst = step < 2'd3;
    always @(posedge clk) if (rst) step <= step + 1'b1;
    wire        cfg_we = step == 2'd1 || step == 2'd2;
    wire [2:0]  cfg_addr = step == 2'd1 ? 3'd2 : 3'd4;
    wire [15:0] cfg_data = step == 2'd1 ? can_hold(start) : can_hold_ticks(BIT);

    wire [7:0]  oe_a, ov_a, oe_b, ov_b, count_a, count_b, rx_a, rx_b, pin_a, pin_b, s1_a, s1_b;
    wire [7:0]  armed_a, armed_b, tx_a, tx_b, viol_a, viol_b, vout_a, vout_b, pdata_a, pdata_b;
    wire [87:0] code_a, code_b;
    wire [111:0] cfg_a, cfg_b;
    wire [47:0] cset_a, cset_b;
    wire [31:0] held_a, held_b;
    wire [5:0]  pc_a, pc_b;
    wire [3:0]  s_a, s_b, k_a, k_b, keep_a, keep_b, prev_a, prev_b;
    wire [4:0]  partial_a, partial_b;
    wire [11:0] now_a, now_b, edge_a, edge_b;
    wire [1:0]  role_a, role_b, src_a, src_b;
    wire        last_a, last_b, mine_a, mine_b, val_a, val_b, insd_a, insd_b, sbit_a, sbit_b;
    wire        pop_a, pop_b, clear_a, clear_b, push_a, push_b, seen_a, seen_b, seen2_a, seen2_b;
    wire        lost_a, lost_b;
    wire [4:0]  width_a, width_b;
    wire [11:0] lf_a, lf_b;

    // BUS is open drain with a pull-up: low exactly when a hart drives it low.
    wire        low = (oe_a[0] && !ov_a[0]) || (oe_b[0] && !ov_b[0]);
    wire [7:0]  bus = {4'hF, other, !low};

    wire [5:0]  at_a = pc_a - start, at_b = pc_b - start;
    wire [31:0] ins_a = can_word(at_a, BIT, start, unwritten);
    wire [31:0] ins_b = can_word(at_b, BIT, start, unwritten);

    janus_hart a (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_a), .ov(ov_a),
        .od_mask(8'h01), .base_role(2'd0), .reset_pc(start), .addr_reg(addr_a), .pc(pc_a),
        .pc_sel(), .ins(ins_a), .tx_valid(valid_a), .tx_ctl(ctl_a), .tx_data(data_a),
        .tx_pop(pop_a), .tx_clear(clear_a), .rx_push(push_a), .seen_push(seen_a),
        .seen_push2(seen2_a), .push_data(pdata_a), .push_data2(), .violations(vout_a),
        .arb_lost(lost_a), .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .dbg_s(s_a), .dbg_count(count_a), .dbg_rx(rx_a), .dbg_last(last_a),
        .dbg_now(now_a), .dbg_edge(edge_a), .dbg_dwell(), .dbg_k(k_a),
        .dbg_partial(partial_a), .dbg_role(role_a), .dbg_src(src_a), .dbg_mine(mine_a),
        .dbg_val(val_a), .dbg_pin(pin_a), .dbg_s1(s1_a), .dbg_armed(armed_a),
        .dbg_code(code_a), .dbg_inserted(insd_a), .dbg_stuff_bit(sbit_a), .dbg_width(width_a),
        .dbg_viol(viol_a), .dbg_tx(tx_a), .dbg_cfg(cfg_a), .dbg_cset(cset_a),
        .dbg_cnt(), .dbg_rx1(), .dbg_prev(prev_a), .dbg_held(held_a), .dbg_keep(keep_a), .dbg_last_fall(lf_a),
        .dbg_clean());

    janus_hart b (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_b), .ov(ov_b),
        .od_mask(8'h01), .base_role(2'd0), .reset_pc(start), .addr_reg(addr_b), .pc(pc_b),
        .pc_sel(), .ins(ins_b), .tx_valid(valid_b), .tx_ctl(ctl_b), .tx_data(data_b),
        .tx_pop(pop_b), .tx_clear(clear_b), .rx_push(push_b), .seen_push(seen_b),
        .seen_push2(seen2_b), .push_data(pdata_b), .push_data2(), .violations(vout_b),
        .arb_lost(lost_b), .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .dbg_s(s_b), .dbg_count(count_b), .dbg_rx(rx_b), .dbg_last(last_b),
        .dbg_now(now_b), .dbg_edge(edge_b), .dbg_dwell(), .dbg_k(k_b),
        .dbg_partial(partial_b), .dbg_role(role_b), .dbg_src(src_b), .dbg_mine(mine_b),
        .dbg_val(val_b), .dbg_pin(pin_b), .dbg_s1(s1_b), .dbg_armed(armed_b),
        .dbg_code(code_b), .dbg_inserted(insd_b), .dbg_stuff_bit(sbit_b), .dbg_width(width_b),
        .dbg_viol(viol_b), .dbg_tx(tx_b), .dbg_cfg(cfg_b), .dbg_cset(cset_b),
        .dbg_cnt(), .dbg_rx1(), .dbg_prev(prev_b), .dbg_held(held_b), .dbg_keep(keep_b), .dbg_last_fall(lf_b),
        .dbg_clean());

    localparam S_BOOT = 4'd0, S_EXEC = 4'd1, S_CLAIM = 4'd2, S_SYNC = 4'd3, S_EDGE = 4'd4,
               S_MID = 4'd5, S_SETTLE = 4'd6, S_POST = 4'd7;

    wire [11:0] d = {1'b0, BIT};
    wire [11:0] h = {2'b00, BIT[10:1]};          // where a bit is sampled
    wire        low_a = oe_a[0] && !ov_a[0], low_b = oe_b[0] && !ov_b[0];

    // The monitor. It samples BUS once a tick and knows only the textbook
    // rules for a base data frame: a falling edge on an idle bus is the start
    // of frame, and each bit is read in its middle, BIT ticks apart. From the
    // start of frame to the end of the CRC, after five equal bits comes a
    // stuff bit of the other value, which is not part of the frame. The frame
    // is: start of frame (0), an 11-bit identifier, RTR, IDE and r0, a 4-bit
    // length, that many data bytes (8 at most), a 15-bit CRC of everything
    // before it, then a recessive CRC delimiter, the ACK slot (dominant when
    // a receiver acknowledges), a recessive ACK delimiter, seven recessive
    // bits of end of frame and three of intermission.
    localparam M_IDLE = 2'd0, M_STUFFED = 2'd1, M_TAIL = 2'd2;
    reg        m_prev = 1'b1;    // BUS one tick ago
    reg        m_p2 = 1'b1, m_p3 = 1'b1;   // two and three ticks ago
    reg [1:0]  m_st = M_IDLE;
    reg [10:0] m_t = 0;          // ticks into this bit, from its first
    reg        m_cur = 0;        // this bit, as read in its middle
    reg [2:0]  m_run = 0;        // equal bits in a row before this one, stuff bits included
    reg        m_last = 0;       // the bit before this one
    reg [7:0]  m_i = 0;          // bits of the frame before this one, stuff bits not counted
    reg [14:0] m_crc = 0;        // the CRC of those bits
    reg [14:0] m_f = 0;          // the field in hand, as read so far
    reg [7:0]  m_sh = 0;         // the last eight frame bits read, start of frame not counted
    reg [3:0]  m_dlc = 0;        // the length field, once read
    reg [3:0]  m_tail = 0;       // bits of the tail before this one
    wire       m_bus = bus[0];
    wire       m_sample = m_st != M_IDLE && m_t == h[10:0];      // read this bit now
    wire       m_read = m_st != M_IDLE && m_t >= h[10:0];        // this bit has been read
    wire       m_end = m_st != M_IDLE && m_t == BIT - 1'b1;      // this bit's last tick
    wire       m_b = m_sample ? m_bus : m_cur;                   // this bit, once read
    wire       m_stuff = m_st == M_STUFFED && m_run == 3'd5;     // this bit is a stuff bit
    wire [3:0] m_n = m_dlc > 4'd8 ? 4'd8 : m_dlc;              // data bytes
    wire [7:0] m_crc_at = 8'd19 + {m_n, 3'd0};                 // index of the first CRC bit
    wire [14:0] m_fb = {m_f[13:0], m_b};                       // the field with this bit
    wire [14:0] m_crc_next = {m_crc[13:0], 1'b0} ^ ((m_b ^ m_crc[14]) ? 15'h4599 : 15'h0);
    wire [2:0] m_run_next = m_b == m_last ? m_run + 1'b1 : 3'd1;
    // A new field starts at bits 1, 4 and 12, at each data byte and at the CRC.
    wire       m_fstart = m_i == 8'd1 || m_i == 8'd4 || m_i == 8'd12
                          || (m_i > 8'd18 && m_i <= m_crc_at && m_i[2:0] == 3'd3);
    // The stuffed part ends after the last CRC bit, and after its stuff bit
    // if one is due.
    wire       m_to_tail = m_st == M_STUFFED
                           && ((!m_stuff && m_i == m_crc_at + 8'd14 && m_run_next != 3'd5)
                               || (m_stuff && m_i == m_crc_at + 8'd15));

    // The monitor reads each bit in its middle and takes it into the frame on
    // its last tick, so all through a bit its state describes the bits before.
    always @(posedge clk) begin
        m_prev <= m_bus;
        m_p2 <= m_prev;
        m_p3 <= m_p2;
        if (m_sample) m_cur <= m_bus;
        if (rst) begin
            m_st <= M_IDLE;
            m_t <= 0;
        end else if (m_st == M_IDLE) begin
            if (m_prev && !m_bus) begin              // start of frame
                m_st <= M_STUFFED;
                m_t <= 11'd1;
                m_run <= 0;
                m_last <= 1'b1;
                m_i <= 0;
                m_crc <= 0;
                m_f <= 0;
            end
        end else begin
            m_t <= m_end ? 11'd0 : m_t + 1'b1;
            if (m_end) begin
                if (m_st == M_STUFFED) begin
                    m_run <= m_run_next;
                    m_last <= m_b;
                    if (!m_stuff) begin
                        m_i <= m_i + 1'b1;
                        if (m_i < m_crc_at) m_crc <= m_crc_next;
                        if (m_i != 0) m_sh <= {m_sh[6:0], m_b};
                        m_f <= m_fstart ? {14'd0, m_b} : m_fb;
                        if (m_i == 8'd18) m_dlc <= m_fb[3:0];
                    end
                    if (m_to_tail) begin
                        m_st <= M_TAIL;
                        m_tail <= 0;
                    end
                end else begin
                    m_tail <= m_tail + 1'b1;
                    if (m_tail == 4'd12) m_st <= M_IDLE;
                end
            end
        end
    end

    // ---- The bytes each hart took for the frame in hand ----
    reg [7:0]  f1a = 0, f2a = 0, f3a = 0, fda = 0, f1b = 0, f2b = 0, f3b = 0, fdb = 0;
    reg [7:0]  fd0a = 0, fd0b = 0;               // the data byte before fd
    reg        ld2a = 0, ld2b = 0;               // took its second identifier byte this frame
    wire       a_load = !rst && s_a == S_EXEC && role_a == 2'd0
                        && (at_a == PC_LOAD1 || at_a == PC_LOAD2 || at_a == PC_LOAD3 || at_a == PC_DLOAD);
    wire       b_load = !rst && s_b == S_EXEC && role_b == 2'd0
                        && (at_b == PC_LOAD1 || at_b == PC_LOAD2 || at_b == PC_LOAD3 || at_b == PC_DLOAD);
    wire [7:0] took_a = valid_a ? data_a : 8'hFF, took_b = valid_b ? data_b : 8'hFF;
    always @(posedge clk) begin
        if (a_load) begin
            if (at_a == PC_LOAD1) f1a <= took_a;
            if (at_a == PC_LOAD2) f2a <= took_a;
            if (at_a == PC_LOAD3) f3a <= took_a;
            if (at_a == PC_DLOAD) begin
                fda <= took_a;
                fd0a <= fda;
            end
        end
        if (b_load) begin
            if (at_b == PC_LOAD1) f1b <= took_b;
            if (at_b == PC_LOAD2) f2b <= took_b;
            if (at_b == PC_LOAD3) f3b <= took_b;
            if (at_b == PC_DLOAD) begin
                fdb <= took_b;
                fd0b <= fdb;
            end
        end
        if (rst || (a_load && at_a == PC_LOAD1)) ld2a <= 1'b0;
        else if (a_load && at_a == PC_LOAD2) ld2a <= 1'b1;
        if (rst || (b_load && at_b == PC_LOAD1)) ld2b <= 1'b0;
        else if (b_load && at_b == PC_LOAD2) ld2b <= 1'b1;
    end

    // ---- The frame on the bus: who sends it, and who wins ----
    // A hart joins a frame as a sender when it runs `stuff` with the sender
    // role, after its claim; in_x stays set until it is back at `idle`.
    reg        in_a = 0, in_b = 0;
    always @(posedge clk) begin
        if (rst || at_a == PC_IDLE) in_a <= 1'b0;
        else if (s_a == S_EXEC && at_a == PC_STUFF && role_a == 2'd0) in_a <= 1'b1;
        if (rst || at_b == PC_IDLE) in_b <= 1'b0;
        else if (s_b == S_EXEC && at_b == PC_STUFF && role_b == 2'd0) in_b <= 1'b1;
    end
    wire        con = in_a && in_b;                          // two senders: arbitration
    // The winner sends the smaller identifier, most significant bit first. A
    // hart that lost in the top three bits never took its second byte, so
    // those bits decide first.
    wire        w_b = in_b && (!in_a || f1b[7:5] < f1a[7:5] || (f1b[7:5] == f1a[7:5] && f2b < f2a));
    wire [7:0]  wf1 = w_b ? f1b : f1a, wf2 = w_b ? f2b : f2a, wf3 = w_b ? f3b : f3a,
                wfd = w_b ? fdb : fda;

    // The skew: how many ticks after the first start of frame the second
    // sender pulls the bus low for its own, on the monitor's grid.
    reg [3:0]  k_sk = 0;
    reg        k_set = 0;
    reg        early_b = 0;                                  // hart b's start of frame came first
    always @(posedge clk) begin
        if (rst) begin
            k_sk <= 0;
            k_set <= 0;
        end else if (m_st == M_IDLE) begin
            if (m_prev && !m_bus) begin                      // the first start of frame
                early_b <= low_b && !low_a;
                k_sk <= 0;
                k_set <= low_a && low_b;
            end
        end else if (m_st == M_STUFFED && m_i == 0 && !k_set && low_a && low_b) begin
            k_sk <= m_t[3:0];
            k_set <= 1'b1;
        end
    end
    // The winner's edges sit on the grid unless the later sender won.
    wire        late_w = con && (w_b != early_b);
    wire [10:0] woff = late_w ? {7'd0, k_sk} : 11'd0;
    // Decided: the loser has dropped to the receiver role.
    wire        decided = !con || (w_b ? role_a != 2'd0 : role_b != 2'd0);

    // ---- Stores ----
    // A sender stores each field as it took it. Both harts log every store,
    // and whichever stores a field second must store what the first did.
    // The counts restart at each start of frame.
    reg [7:0]  log_a [0:15];
    reg [7:0]  log_b [0:15];
    reg [3:0]  na = 0, nb = 0;                               // fields stored this frame
    integer    li;
    reg [7:0]  xv_a = 0, xm_a = 0, xv_b = 0, xm_b = 0;
    reg        st_a = 0, st_b = 0, sr_a = 0, sr_b = 0;       // stored last tick; as a sender
    function automatic [15:0] field_of(input [5:0] at, input [7:0] g1, g2, g3, gd);
        case (at)
            PC_STORE1: field_of = {{5'd0, g1[7:5]}, 8'h07};
            PC_STORE2: field_of = {g2, 8'hFF};
            PC_STORE3: field_of = {{1'b0, g3[7:1]}, 8'h7F};
            default:   field_of = {gd, 8'hFF};
        endcase
    endfunction
    function automatic [7:0] mask_of(input [3:0] n);
        mask_of = n == 0 ? 8'h07 : n == 2 ? 8'h7F : 8'hFF;
    endfunction
    wire       a_store = !rst && s_a == S_EXEC && (at_a == PC_STORE1 || at_a == PC_STORE2
                                                    || at_a == PC_STORE3 || at_a == PC_DSTORE);
    wire       b_store = !rst && s_b == S_EXEC && (at_b == PC_STORE1 || at_b == PC_STORE2
                                                    || at_b == PC_STORE3 || at_b == PC_DSTORE);
    wire       sof = m_st == M_IDLE && m_prev && !m_bus;
    always @(posedge clk) begin
        st_a <= a_store;
        st_b <= b_store;
        sr_a <= a_store && role_a == 2'd0;
        sr_b <= b_store && role_b == 2'd0;
        if (a_store) {xv_a, xm_a} <= field_of(at_a, f1a, f2a, f3a, fda);
        if (b_store) {xv_b, xm_b} <= field_of(at_b, f1b, f2b, f3b, fdb);
        if (rst || sof) begin
            na <= 0;
            nb <= 0;
        end else begin
            if (push_a) begin
                log_a[na] <= pdata_a;
                na <= na + 1'b1;
            end
            if (push_b) begin
                log_b[nb] <= pdata_b;
                nb <= nb + 1'b1;
            end
        end
    end

    // ---- The frame as the monitor had it, up to 6 ticks ago ----
    // A hart on a grid o ticks after the monitor's is checked against the
    // monitor's state o ticks ago: {st, t, i, run, last, crc, f, sh, dlc,
    // tail, cur, bus}. Within a bit only the tick and the sample change, so
    // that state is the monitor's now with the tick o less, or, early in a
    // bit, the bit before's. A bit is at least 12 ticks, so 6 ticks back
    // from a bit's start is past the middle of the bit before: the sample
    // is then that bit's, and from o ticks into a bit it is now's (m_cur).
    wire [72:0] snap0 = {m_st, m_t, m_i, m_run, m_last, m_crc, m_f, m_sh, m_dlc, m_tail, m_cur, m_bus};
    // The bit before this one, latched as it ended; at the start of frame,
    // the idle bus.
    reg  [1:0]  p_st = M_IDLE;
    reg  [7:0]  p_i = 0, p_sh = 0;
    reg  [2:0]  p_run = 0;
    reg         p_last = 0, p_cur = 0;
    reg  [14:0] p_crc = 0, p_f = 0;
    reg  [3:0]  p_dlc = 0, p_tail = 0;
    always @(posedge clk)
        if (rst || sof) p_st <= M_IDLE;
        else if (m_end) {p_st, p_i, p_run, p_last, p_crc, p_f, p_sh, p_dlc, p_tail, p_cur}
                            <= {m_st, m_i, m_run, m_last, m_crc, m_f, m_sh, m_dlc, m_tail, m_b};
    wire [60:0] pbit = {p_st, p_i, p_run, p_last, p_crc, p_f, p_sh, p_dlc, p_tail, p_cur};
    function automatic [72:0] snap_at(input [2:0] o, input [72:0] s0, input [60:0] pb, input [10:0] bt);
        reg [10:0] t;
        begin
            t = s0[70:60];
            if (o == 3'd0) snap_at = s0;
            else if (s0[72:71] != M_IDLE && t >= {8'd0, o})
                snap_at = {s0[72:71], t - {8'd0, o}, s0[59:2], s0[1], s0[1]};
            else snap_at = {pb[60:59], t + bt - {8'd0, o}, pb[58:1], pb[0], pb[0]};
        end
    endfunction
`ifdef CAN_SIM
    // The real history, to check the rebuilt one against.
    reg  [72:0] snap1 = 0, snap2 = 0, snap3 = 0, snap4 = 0, snap5 = 0, snap6 = 0;
    always @(posedge clk) {snap6, snap5, snap4, snap3, snap2, snap1} <= {snap5, snap4, snap3, snap2, snap1, snap0};
    function automatic same_snap(input [72:0] x, input [72:0] y, input [10:0] hh);
        // y rebuilt, x real: equal where a view reads them.
        same_snap = x[72:71] != M_STUFFED ? (y[72:71] != M_STUFFED || (y[59:52] == 0 && y[70:60] == 0))
                    : x[72:2] == y[72:2] && (x[70:60] < hh || (x[70:60] == hh ? x[0] : x[1]) == y[1]);
    endfunction
    always @(negedge clk)
        if (!rst) begin
            assert (same_snap(snap1, snap_at(3'd1, snap0, pbit, BIT), BIT[10:1]));
            assert (same_snap(snap2, snap_at(3'd2, snap0, pbit, BIT), BIT[10:1]));
            assert (same_snap(snap3, snap_at(3'd3, snap0, pbit, BIT), BIT[10:1]));
            assert (same_snap(snap4, snap_at(3'd4, snap0, pbit, BIT), BIT[10:1]));
            assert (same_snap(snap5, snap_at(3'd5, snap0, pbit, BIT), BIT[10:1]));
            assert (same_snap(snap6, snap_at(3'd6, snap0, pbit, BIT), BIT[10:1]));
        end
`endif
    // The bit before, stepped as the monitor steps at a bit's end.
    wire        p_stuff = p_run == 3'd5;
    wire [3:0]  p_n = p_dlc > 4'd8 ? 4'd8 : p_dlc;
    wire [7:0]  p_crc_at = 8'd19 + {p_n, 3'd0};
    wire [14:0] p_fb = {p_f[13:0], p_cur};
    wire [14:0] p_crc_next = {p_crc[13:0], 1'b0} ^ ((p_cur ^ p_crc[14]) ? 15'h4599 : 15'h0);
    wire [2:0]  p_run_next = p_cur == p_last ? p_run + 1'b1 : 3'd1;
    wire        p_fstart = p_i == 8'd1 || p_i == 8'd4 || p_i == 8'd12
                           || (p_i > 8'd18 && p_i <= p_crc_at && p_i[2:0] == 3'd3);
    wire        p_to_tail = (!p_stuff && p_i == p_crc_at + 8'd14 && p_run_next != 3'd5)
                            || (p_stuff && p_i == p_crc_at + 8'd15);

    // Each hart's role a tick ago.
    reg  [1:0]  role_a1 = 0, role_b1 = 0;
    always @(posedge clk) {role_a1, role_b1} <= {role_a, role_b};
    // Each hart's drive one, two and three ticks ago: BUS's history is theirs.
    reg         low_a1 = 0, low_b1 = 0, low_a2 = 0, low_b2 = 0, low_a3 = 0, low_b3 = 0;
    always @(posedge clk)
        {low_a3, low_b3, low_a2, low_b2, low_a1, low_b1} <= {low_a2, low_b2, low_a1, low_b1, low_a, low_b};
    // Data bytes each hart has taken this frame.
    reg  [3:0]  dn_a = 0, dn_b = 0;
    always @(posedge clk) begin
        if (a_load && at_a == PC_LOAD1) dn_a <= 0;
        else if (a_load && at_a == PC_DLOAD) dn_a <= dn_a + 1'b1;
        if (b_load && at_b == PC_LOAD1) dn_b <= 0;
        else if (b_load && at_b == PC_DLOAD) dn_b <= dn_b + 1'b1;
    end

    // ---- Each hart in a frame, on its grid ----
    // A hart's offset: how many ticks its bits start after the monitor's. The
    // first start of frame sets 0; a second sender's, k; a receiver is 2. A
    // loser keeps its offset until it resynchronises to the winner's falls,
    // which puts it 2 ticks after the winner. Any change of its bit edge but
    // the step of a bit time is such a resynchronisation.
    wire        a_exec = s_a == S_EXEC, a_mid = s_a == S_MID, a_edge = s_a == S_EDGE;
    wire        b_exec = s_b == S_EXEC, b_mid = s_b == S_MID, b_edge = s_b == S_EDGE;
    wire [11:0] since_a = now_a - edge_a, since_b = now_b - edge_b;
    // In the frame: from the middle of its start of frame, after the tick it
    // pulled BUS low, to its ACK.
    wire        a_joined = (at_a == PC_SOF && a_mid && !(low_a && since_a == 0)) || (at_a > PC_SOF && at_a < PC_ACK)
                           || (at_a == PC_ACK && a_exec);
    wire        b_joined = (at_b == PC_SOF && b_mid && !(low_b && since_b == 0)) || (at_b > PC_SOF && at_b < PC_ACK)
                           || (at_b == PC_ACK && b_exec);
    // In the ACK slot the sender listens too, and moves to the receiver's
    // ACK, seen 2 ticks late, when it is close enough. So after a frame the
    // two harts are always 2 ticks apart.
    reg  [3:0]  o_a = 0, o_b = 0;
    reg  [11:0] pe_a = 0, pe_b = 0;                          // each hart's bit edge a tick ago
    wire        chg_a = edge_a != pe_a && edge_a != pe_a + {1'b0, BIT} && (a_mid || a_edge);
    wire        chg_b = edge_b != pe_b && edge_b != pe_b + {1'b0, BIT} && (b_mid || b_edge);
    wire        rs_a = chg_a && ((con && role_a != 2'd0) || (at_a == PC_ACK && role_a == 2'd0));
    wire        rs_b = chg_b && ((con && role_b != 2'd0) || (at_b == PC_ACK && role_b == 2'd0));
    wire [3:0]  rs_to_a = role_a != 2'd0 ? {1'b0, woff[2:0]} + 4'd2 : o_b + 4'd2;
    wire [3:0]  rs_to_b = role_b != 2'd0 ? {1'b0, woff[2:0]} + 4'd2 : o_a + 4'd2;
    always @(posedge clk) begin
        pe_a <= edge_a;
        pe_b <= edge_b;
        if (rst) begin
            o_a <= 0;
            o_b <= 0;
        end else if (sof) begin
            o_a <= low_a ? 4'd0 : 4'd2;
            o_b <= low_b ? 4'd0 : 4'd2;
        end else if (m_st == M_STUFFED && m_i == 0 && !k_set && low_a && low_b) begin
            if (early_b) o_a <= {1'b0, m_t[2:0]};
            else o_b <= {1'b0, m_t[2:0]};
        end else begin
            if (rs_a) o_a <= rs_to_a;
            if (rs_b) o_b <= rs_to_b;
        end
    end
    wire        fr = in_a || in_b;                           // a frame with a sender in it
    // The offset in force: a resynchronisation moves it on the tick it happens.
    wire [3:0]  oe_ga = rs_a ? rs_to_a : o_a, oe_gb = rs_b ? rs_to_b : o_b;
    can_view va (.clk_v(clk), .en(!rst && fr && a_joined), .snd(role_a == 2'd0), .BIT(BIT), .start(start),
        .snap(snap_at(oe_ga[2:0], snap0, pbit, BIT)),
        .at(at_a), .s(s_a), .k(k_a), .code(code_a[23:0]), .rx(rx_a), .count(count_a), .now(now_a),
        .edge_t(edge_a), .mine(mine_a), .val(val_a), .src(src_a), .tx(tx_a), .low(low_a), .role(role_a),
        .low1(low_a1), .low2(low_a2), .low3(low_a3),
        .ins(ins_a), .g1(f1a), .g2(f2a), .g3(f3a), .gd(fda), .gd0(fd0a), .dn(dn_a), .nst(na), .push(push_a));
    can_view vb (.clk_v(clk), .en(!rst && fr && b_joined), .snd(role_b == 2'd0), .BIT(BIT), .start(start),
        .snap(snap_at(oe_gb[2:0], snap0, pbit, BIT)),
        .at(at_b), .s(s_b), .k(k_b), .code(code_b[23:0]), .rx(rx_b), .count(count_b), .now(now_b),
        .edge_t(edge_b), .mine(mine_b), .val(val_b), .src(src_b), .tx(tx_b), .low(low_b), .role(role_b),
        .low1(low_b1), .low2(low_b2), .low3(low_b3),
        .ins(ins_b), .g1(f1b), .g2(f2b), .g3(f3b), .gd(fdb), .gd0(fd0b), .dn(dn_b), .nst(nb), .push(push_b));

    // ---- Each hart in the tail, on its grid ----
    // Its cell and the tick in it: the monitor's, o ticks later.
    wire [11:0] oa12 = {8'd0, oe_ga}, ob12 = {8'd0, oe_gb};
    wire        a_lt = {1'b0, m_t} < oa12, b_lt = {1'b0, m_t} < ob12;   // still in the cell before
    wire [3:0]  a_cell = a_lt ? m_tail - 4'd1 : m_tail, b_cell = b_lt ? m_tail - 4'd1 : m_tail;
    wire [11:0] a_t = a_lt ? {1'b0, m_t} + {1'b0, BIT} - oa12 : {1'b0, m_t} - oa12;
    wire [11:0] b_t = b_lt ? {1'b0, m_t} + {1'b0, BIT} - ob12 : {1'b0, m_t} - ob12;
    wire        a_tail = m_st == M_TAIL && !(m_tail == 0 && a_lt), b_tail = m_st == M_TAIL && !(m_tail == 0 && b_lt);
    can_tail ta (.clk_v(clk), .en(!rst && a_tail), .snd(role_a == 2'd0), .BIT(BIT), .c(a_cell), .t(a_t),
        .at(at_a), .s(s_a), .k(k_a), .now(now_a), .edge_t(edge_a), .mine(mine_a), .val(val_a), .low(low_a),
        .low1(low_a1), .low2(low_a2), .low3(low_a3), .m_last(m_last), .armed0(armed_a[0]));
    can_tail tb (.clk_v(clk), .en(!rst && b_tail), .snd(role_b == 2'd0), .BIT(BIT), .c(b_cell), .t(b_t),
        .at(at_b), .s(s_b), .k(k_b), .now(now_b), .edge_t(edge_b), .mine(mine_b), .val(val_b), .low(low_b),
        .low1(low_b1), .low2(low_b2), .low3(low_b3), .m_last(m_last), .armed0(armed_b[0]));

    // ---- The fields of the frame, as the monitor read them ----
    // Logged as each field's last bit is read, so before any hart stores it.
    reg [7:0]  m_log [0:15];
    reg [3:0]  m_nf = 0;                                     // fields read this frame
    wire       m_fe = m_i == 8'd3 || m_i == 8'd11 || m_i == 8'd18
                      || (m_i > 8'd18 && m_i < m_crc_at && m_i[2:0] == 3'd2);   // this bit ends a field
    wire       m_logs = m_sample && m_st == M_STUFFED && !m_stuff && m_fe;   // logs a field now
    always @(posedge clk)
        if (rst || sof) m_nf <= 0;
        else if (m_logs) begin
            m_log[m_nf] <= m_fb[7:0];
            m_nf <= m_nf + 1'b1;
        end
    // Fields in the first nb frame bits, of a frame with n data bytes.
    function automatic [3:0] fcnt(input [7:0] nb, input [3:0] n);
        reg [7:0] x;
        begin
            x = nb >= 8'd27 ? (nb - 8'd19) >> 3 : 8'd0;
            fcnt = (nb >= 8'd4 ? 4'd1 : 4'd0) + (nb >= 8'd12 ? 4'd1 : 4'd0) + (nb >= 8'd19 ? 4'd1 : 4'd0)
                   + (x > {4'd0, n} ? n : x[3:0]);
        end
    endfunction
    wire [7:0] m_vi = (m_read && !m_stuff) ? m_i + 1'b1 : m_i;   // frame bits read, this one included once read
    // The last eight frame bits read, this one included once read.
    wire [7:0] m_vsh = (m_read && !m_stuff && m_i != 0) ? {m_sh[6:0], m_b} : m_sh;
    // The last bit of field n.
    function automatic [7:0] fend_at(input [3:0] n);
        fend_at = n == 0 ? 8'd3 : n == 4'd1 ? 8'd11 : n == 4'd2 ? 8'd18 : 8'd18 + {1'b0, n - 4'd2, 3'd0};
    endfunction

    // ---- The ACK, as the monitor sees it ----
    reg [10:0] ack_t = 0;                                    // where in the slot BUS fell
    always @(posedge clk)
        if (m_st == M_TAIL && m_tail == 4'd1 && m_prev && !m_bus) ack_t <= m_t;

    // ---- The monitor's own state, and BUS's history ----
    wire        stuffed = m_st == M_STUFFED, tail = m_st == M_TAIL, idle = m_st == M_IDLE;
    wire        a_claim = s_a == S_CLAIM, a_sync = s_a == S_SYNC, b_claim = s_b == S_CLAIM, b_sync = s_b == S_SYNC;
    // Whether a hart of role r owns a bit of party p, as the hart decides it.
    function automatic mine_of(input [1:0] p, input [1:0] r);
        mine_of = p == 2'd2 ? r != 2'd3 : r == p;
    endfunction
    wire [11:0] tq = {1'b0, m_t};
    wire [7:0]  wfd0 = w_b ? fd0b : fd0a;
    wire [3:0]  dn_w = w_b ? dn_b : dn_a;
    // The monitor's field register once frame bits 0 to i-1 are in: the bits
    // read so far of the field that bit i-1 is in, the last of them at the
    // bottom, and how many there are. A data byte is the winner's byte in
    // hand, or the one before once it has taken the next.
    function automatic [18:0] mf_of(input [7:0] i, input [7:0] crc_at, input [7:0] g1, g2, g3, gd,
                                    input [14:0] crc);
        reg [7:0]  j, x;
        reg [3:0]  len, nb;
        reg [14:0] v;
        begin
            j = i - 8'd1;
            len = 4'd1; nb = 4'd0; v = 15'd0;
            if (i <= 8'd1) begin len = 4'd1; nb = 4'd0; v = 15'd0; end
            else if (j <= 8'd3) begin len = 4'd3; nb = j[3:0]; v = {12'd0, g1[7:5]}; end
            else if (j <= 8'd11) begin len = 4'd8; x = j - 8'd3; nb = x[3:0]; v = {7'd0, g2}; end
            else if (j <= 8'd18) begin len = 4'd7; x = j - 8'd11; nb = x[3:0]; v = {8'd0, g3[7:1]}; end
            else if (j < crc_at) begin
                len = 4'd8; x = j - 8'd19; nb = {1'b0, x[2:0]} + 4'd1; v = {7'd0, gd};
            end else begin len = 4'd15; x = j - crc_at + 8'd1; nb = x[3:0]; v = crc; end
            mf_of = {nb, v >> (len - nb)};
        end
    endfunction
    wire [7:0]  mf_j = m_i - 8'd1;
    wire [7:0]  mf_db = (mf_j - 8'd19) >> 3;                 // the data byte bit i-1 is in
    wire        mf_old = mf_j > 8'd18 && mf_j < m_crc_at && {4'd0, dn_w} != mf_db + 8'd1;
    wire [18:0] mf_x = mf_of(m_i, m_crc_at, wf1, wf2, wf3, mf_old ? wfd0 : wfd, m_crc);
    wire [7:0]  mf_mask = mf_x[18:15] >= 4'd8 ? 8'hFF : ~(8'hFF << mf_x[18:15]);
    // BUS in the tail, at tick t of cell c: the winner's edge into the CRC
    // delimiter, then the receiver's ACK, from ro ticks into the ACK slot to
    // ro ticks into the cell after.
    function automatic tb_at(input [3:0] c, input [11:0] t, input lst, input [11:0] wo, input [11:0] ro);
        tb_at = c == 4'd0 ? (t >= wo || lst) : c == 4'd1 ? t < ro : c == 4'd2 ? t >= ro : 1'b1;
    endfunction
    // The receiver's offset: until the ACK, the receiving hart's; from it on,
    // where the ACK fell, as the sender may then be back at `idle`.
    wire [11:0] r_off = (m_st == M_TAIL && m_tail >= 4'd2) ? {1'b0, ack_t} : {8'd0, w_b ? o_a : o_b};
    wire [11:0] wo12 = {1'b0, woff};
    wire        t_hist2 = tq >= 12'd2 ? tb_at(m_tail, tq - 12'd2, m_last, wo12, r_off)
                          : m_tail == 0 ? m_last : tb_at(m_tail - 4'd1, tq + d - 12'd2, m_last, wo12, r_off);
    wire        t_hist3 = tq >= 12'd3 ? tb_at(m_tail, tq - 12'd3, m_last, wo12, r_off)
                          : m_tail == 0 ? m_last : tb_at(m_tail - 4'd1, tq + d - 12'd3, m_last, wo12, r_off);

    // Ticks since the monitor went idle, and whether a frame has gone by.
    reg [15:0]  m_it = 0;
    reg         m_fr = 0;
    // BUS's run of recessive ticks up to this one, and as it was two ticks
    // ago, which is what each hart's hold counter has seen.
    reg [15:0]  rq = 0, rq1 = 0, rq2 = 0;
    wire [15:0] rqv = !m_bus ? 16'd0 : rq == 16'hFFFF ? rq : rq + 1'b1;
    wire [15:0] rq2_up = rq2 == 16'hFFFF ? rq2 : rq2 + 1'b1;
    // The last time BUS fell, and the time before.
    reg [11:0]  g_fall = 0, g_fall0 = 0;
    // Reset loads both of a hart's input stages from BUS, so until the harts
    // first see BUS low the hold counter runs a tick ahead of the two-tick-late
    // count: it counts the ticks since reset.
    reg         g_fell = 0;
    // BUS's recessive run as the harts see it, two ticks late, saturating.
    wire [15:0] held_seen = g_fell ? rq2 : idle ? rq1 : tq == 12'd1 ? rq2_up : 16'd0;
    wire [11:0] ahead_a = edge_a - now_a, ahead_b = edge_b - now_b;
    wire [11:0] cs = now_a - tq;                     // when this bit started
    // The recessive run in idle after a frame, unsaturated.
    wire [17:0] it_run = {2'd0, m_it} + 18'd11 * {6'd0, d} + 18'd1 - {7'd0, ack_t};
    // How long ago the harts saw the last fall they still count.
    wire [15:0] lf_age = {4'd0, now_a - lf_a};
    // The fall the harts have seen last: BUS's last fall, once two ticks old.
    wire [11:0] seen_fall = (now_a - g_fall >= 12'd2) ? g_fall + 12'd2 : g_fall0 + 12'd2;
    // Recessive ticks in a row before this bit, from the bits before it.
    wire [15:0] rec_before = m_last ? {13'd0, m_run} * {4'd0, d} : 16'd0;
    // Two frames agree in identifier bits 1 to n (none for n = 0).
    function automatic agree(input [7:0] n, input [7:0] a1, a2, b1, b2);
        if (n == 0 || n > 8'd200) agree = 1'b1;
        else if (n <= 8'd3) agree = ((a1 ^ b1) & ~(8'hFF >> n)) == 8'd0;
        else agree = a1[7:5] == b1[7:5] && ((a2 ^ b2) & ~(8'hFF >> (n - 8'd3))) == 8'd0;
    endfunction
    // Two edges more than a quarter bit apart: a listener does not move its
    // edge to a fall that far from it.
    function automatic far(input [3:0] x, input [3:0] y, input [10:0] bt);
        far = (x > y ? x - y : y - x) > {2'd0, bt[10:2]};
    endfunction
    // The offsets a frame leaves, the receiver's r and the sender's x. The
    // receiver is 2 after the winner (r = 2 or, when an earlier loser could
    // move to a later winner, k + 2, within a quarter bit), or an earlier
    // loser that could not move (r = 0), or a later loser that has not moved
    // yet (r = 1, 3 or 4, with the winner at 0). The sender sees the ACK 2
    // ticks after r and moves to it when that is within a quarter bit of its
    // own edge: always for r = 0, from BIT 16 for a receiver 2 after it.
    function automatic pair_ok(input [3:0] r, input [3:0] x, input [10:0] bt);
        reg [11:0] q;
        begin
            q = {3'd0, bt[10:2]};
            pair_ok = r <= 4'd6 && (r < 4'd5 || {8'd0, r} <= q)
                      && ((x == r + 4'd2 && (r == 0 || bt >= 11'd16 || {8'd0, r} + 12'd2 <= q))
                          || (x + 4'd2 == r && bt < 11'd16 && (r == 4'd2 || {8'd0, r} <= q))
                          || (x == 0 && (r == 4'd1 || r == 4'd3 || r == 4'd4) && {8'd0, r} + 12'd2 > q));
        end
    endfunction
    // Each sender's grid at its start of frame, and 2 after the winner's.
    wire [3:0]  st_oa = early_b ? k_sk : 4'd0, st_ob = early_b ? 4'd0 : k_sk;
    wire [3:0]  wo2 = {1'b0, woff[2:0]} + 4'd2;
    // The bit that decides a contest: the first in which the two frames differ.
    wire        dec_now = con && !decided && m_st == M_STUFFED && !m_stuff && m_i >= 8'd1 && m_i <= 8'd11
                          && !agree(m_i, f1a, f2a, f1b, f2b);
    // A hart that has claimed as a sender and not yet pulled BUS low: the
    // monitor's tick at which it will, from the instructions it has left
    // before `sof` and its bit edge.
    function automatic [11:0] pull_at(input [11:0] t, input [5:0] at, input [3:0] st, input [11:0] ahead);
        reg [11:0] n;
        begin
            n = at == PC_STUFF ? 12'd3 : at == PC_LOSE ? 12'd2 : 12'd1;
            pull_at = t + (ahead > n && !ahead[11] ? ahead : n);
        end
    endfunction
    wire [11:0] pull_a = pull_at(tq, at_a, s_a, ahead_a), pull_b = pull_at(tq, at_b, s_b, ahead_b);
    always @(posedge clk) begin
        if (rst) begin
            m_it <= 0;
            m_fr <= 0;
            g_fell <= 0;
            rq <= 0;
            rq1 <= 0;
            rq2 <= 0;
        end else begin
            m_it <= !idle ? 16'd0 : m_it == 16'hFFFF ? m_it : m_it + 1'b1;
            if (stuffed) m_fr <= 1'b1;
            if (!pin_a[0]) g_fell <= 1'b1;
            rq <= rqv;
            rq1 <= rqv;
            rq2 <= rq1;
            if (m_prev && !m_bus) begin
                g_fall <= now_a;
                g_fall0 <= g_fall;
            end
        end
    end

`ifdef CAN_SIM
    always @(negedge clk) begin                  // once a tick, with everything settled
`else
    always @* begin
`endif
        assume (BIT >= MINBIT);
        assume (start <= MAX_START);
        // The hosts queue base data frames: RTR and IDE clear.
        if (a_load && at_a == PC_LOAD3) assume (valid_a && data_a[7:6] == 2'b00);
        if (b_load && at_b == PC_LOAD3) assume (valid_b && data_b[7:6] == 2'b00);
        // Two frames that arbitrate have different identifiers.
        if (a_load && at_a == PC_LOAD2 && in_b && role_b == 2'd0 && ld2b && f1a[7:5] == f1b[7:5])
            assume (valid_a && data_a != f2b);
        if (b_load && at_b == PC_LOAD2 && in_a && role_a == 2'd0 && ld2a && f1a[7:5] == f1b[7:5])
            assume (valid_b && data_b != f2a);
        if (a_load && at_a == PC_LOAD2 && b_load && at_b == PC_LOAD2 && f1a[7:5] == f1b[7:5])
            assume (valid_a && valid_b && data_a != data_b);

        assert (step <= 2'd3);
        if (!rst) begin
            // CLEAN: no violations, no stray pins, and only the loser of an
            // arbitration loses and has its queue cleared.
            assert (viol_a == 0 && viol_b == 0 && vout_a == 0 && vout_b == 0);
            assert (!seen_a && !seen_b && !seen2_a && !seen2_b);
            assert (keep_a == 0 && keep_b == 0);
            assert (oe_a[7:1] == 0 && oe_b[7:1] == 0);
            if (clear_a) begin assert (con && w_b); end
            if (clear_b) begin assert (con && !w_b); end
            // A sender that loses has its queue cleared as it drops to the
            // receiver role.
            if (role_a1 == 2'd0 && role_a == 2'd1 && in_a) assert (clear_a);
            if (role_b1 == 2'd0 && role_b == 2'd1 && in_b) assert (clear_b);

            // WIRE: what the monitor is about to read is the winner's frame.
            if (m_sample && m_stuff) begin assert (m_bus != m_last); end           // no stuff error
            if (m_sample && m_st == M_STUFFED && !m_stuff) begin
                if (m_i == 8'd0) assert (!m_bus);                          // start of frame
                if (m_i == 8'd3) assert (m_fb[2:0] == wf1[7:5]);           // identifier, top
                if (m_i == 8'd11) assert (m_fb[7:0] == wf2);               // identifier, rest
                if (m_i == 8'd12 || m_i == 8'd13) assert (!m_bus);         // RTR, IDE: a base data frame
                if (m_i == 8'd18) assert (m_fb[6:0] == wf3[7:1]);          // RTR, IDE, r0, length
                if (m_i > 8'd18 && m_i < m_crc_at && (m_i - 8'd18) % 8 == 0)
                    assert (m_fb[7:0] == wfd);                             // a data byte
                if (m_i == m_crc_at + 8'd14) assert (m_fb == m_crc);       // the CRC
            end
            if (m_sample && m_st == M_TAIL) begin
                assert (m_bus == (m_tail != 4'd1));                        // ACK slot dominant
            end
            // By the end of the identifier the contest is decided.
            if (m_st == M_STUFFED && m_i > 8'd11) assert (decided);

            // Timing. In the stuffed part BUS changes only where a bit starts:
            // on the grid for one sender or an earlier winner, at the skew for
            // a later winner, and while two still send, a fall at the earlier
            // sender's edge or a change at the later one's.
            if (m_st == M_STUFFED && m_bus != m_prev)
                assert (m_t == woff || (!decided && (m_t == 0 || m_t == {7'd0, k_sk})));
            // In the tail: the winner's edge into the CRC delimiter, then the
            // receiver's ACK, which falls in the ACK slot at most 6 ticks in
            // and lasts exactly a bit.
            if (m_st == M_TAIL && m_bus != m_prev) begin
                if (m_tail == 4'd0) begin assert (m_t == woff && m_bus); end
                else if (m_tail == 4'd1) begin assert (!m_bus && m_t <= 11'd6); end
                else assert (m_tail == 4'd2 && m_bus && m_t == ack_t);
            end
            if (m_st == M_IDLE && m_bus != m_prev) assert (!m_bus);       // only a start of frame

            // DATA: a sender stores each field as it took it, and both harts
            // store the same fields.
            if (push_a && sr_a) assert ((pdata_a & xm_a) == (xv_a & xm_a));
            if (push_b && sr_b) assert ((pdata_b & xm_b) == (xv_b & xm_b));
            if (push_a && nb > na) assert ((pdata_a & mask_of(na)) == (log_b[na] & mask_of(na)));
            if (push_b && na > nb) assert ((pdata_b & mask_of(nb)) == (log_a[nb] & mask_of(nb)));
            if (push_a && push_b && na == nb) assert ((pdata_a & mask_of(na)) == (pdata_b & mask_of(na)));
            assert (push_a == st_a && push_b == st_b);

            // ---- The monitor's own state ----
            assert (m_st != 2'd3);
            if (idle) begin assert (m_prev && m_p2 && m_p3 && m_t == 0); end
            else assert (m_t < BIT);
            // A frame has gone by from the second tick of the first start of
            // frame on, and the idle count starts again with each frame.
            if (!idle && !(stuffed && m_i == 0 && tq == 12'd1)) assert (m_fr && m_it == 0);
            if (stuffed) begin
                assert (m_run <= 3'd5 && (m_i == 0) == (m_run == 0) && {5'd0, m_run} <= m_i);
                if (m_i == 0) assert (m_last && tq >= 12'd1 && m_crc == 0);
                assert (m_i < m_crc_at + 8'd15 || (m_i == m_crc_at + 8'd15 && m_stuff));
                if (m_i > 8'd18) assert (m_dlc == wf3[4:1]);
                if (m_t == 0) assert (m_prev == m_last);
                if (m_t > h[10:0]) assert (m_cur == m_bus);
                // The field in hand, as read so far, and the last bits read.
                assert (m_f == mf_x[14:0] && ((m_sh ^ m_f[7:0]) & mf_mask) == 8'd0);
            end
            if (tail) begin
                assert (m_tail <= 4'd12);
                if (m_t > h[10:0]) assert (m_cur == m_bus);
                if (m_t == 0) assert (m_prev == (m_tail == 0 ? m_last : m_tail != 4'd2));
                assert (m_bus == tb_at(m_tail, tq, m_last, wo12, r_off) && m_p2 == t_hist2 && m_p3 == t_hist3);
            end
            // The hosts' control bytes: RTR and IDE clear, as assumed.
            assert (f3a[7:6] == 2'b00 && f3b[7:6] == 2'b00);
            // BUS's history is the harts' drives.
            assert (m_prev == !(low_a1 || low_b1) && m_p2 == !(low_a2 || low_b2) && m_p3 == !(low_a3 || low_b3));

            // ---- Each hart's input stages: BUS one, two and three ticks ago ----
            // On the tick after reset (state BOOT) the oldest stage still holds
            // its power-on 0; the hart moves the next one in before reading it.
            assert (now_a == now_b && s1_a == s1_b && pin_a == pin_b && prev_a == prev_b);
            assert (s1_a[0] == m_prev && pin_a[0] == m_p2 && prev_a[0] == (s_a == S_BOOT ? 1'b0 : m_p3));
            if (s_a == S_BOOT || s_b == S_BOOT)
                assert (s_a == s_b && at_a == 0 && at_b == 0 && now_a == 0 && held_a == 0 && held_b == 0
                        && !cset_a[13] && !cset_b[13] && idle && !m_fr && m_it == 0 && !g_fell);

            // ---- Configuration, as each hart's mode words have set it ----
            assert (cfg_a == {16'd0, 16'd0, can_hold_ticks(BIT), 16'd0, can_hold(start), 32'd0});
            assert (cfg_b == cfg_a);
            assert (code_a[87:50] == {1'b0, 2'd0, 1'b0, 16'd0, 16'd0, 1'b0, 1'b0}
                    && code_b[87:50] == code_a[87:50]);
            // The CRC register's top bit: above the 15-bit width, so never set.
            assert (code_a[23] == 1'b0 && code_b[23] == 1'b0);
            // The hold trap can send a hart back to `idle` after `stuff` and
            // before its start of frame goes out; it then keeps that frame's
            // stuffing and arbitration settings until it claims again.
            assert (code_a[49:46] == ((at_a > PC_STUFF && at_a <= PC_UNSTUFF) ? 4'd5 : 4'd0)
                    || ((at_a == PC_IDLE || at_a == PC_STUFF) && code_a[49:46] == 4'd5));
            assert (code_b[49:46] == ((at_b > PC_STUFF && at_b <= PC_UNSTUFF) ? 4'd5 : 4'd0)
                    || ((at_b == PC_IDLE || at_b == PC_STUFF) && code_b[49:46] == 4'd5));
            assert (code_a[45:24] == {at_a > PC_POLY ? 16'h4599 : 16'h0, at_a > PC_WIDTH ? 5'd15 : 5'd0,
                                      at_a > PC_MSB});
            assert (code_b[45:24] == {at_b > PC_POLY ? 16'h4599 : 16'h0, at_b > PC_WIDTH ? 5'd15 : 5'd0,
                                      at_b > PC_MSB});
            assert (cset_a[47:45] == {at_a > PC_RESYNC, 2'd0} && cset_b[47:45] == {at_b > PC_RESYNC, 2'd0});
            if (at_a > PC_LOSE && at_a <= PC_NOLOSE) begin assert (cset_a[44:43] == 2'd1); end
            else if (at_a == PC_IDLE || at_a == PC_STUFF || at_a == PC_LOSE) begin assert (cset_a[44:43] != 2'd0); end
            else assert (cset_a[44:43] == 2'd2 || cset_a[44:43] == 2'd3);
            if (at_b > PC_LOSE && at_b <= PC_NOLOSE) begin assert (cset_b[44:43] == 2'd1); end
            else if (at_b == PC_IDLE || at_b == PC_STUFF || at_b == PC_LOSE) begin assert (cset_b[44:43] != 2'd0); end
            else assert (cset_b[44:43] == 2'd2 || cset_b[44:43] == 2'd3);
            assert (cset_a[42:37] == (at_a > PC_ONERR ? PC_BAD + start : 6'd0));
            assert (cset_b[42:37] == (at_b > PC_ONERR ? PC_BAD + start : 6'd0));
            assert (cset_a[36:14] == 0 && cset_a[12:0] == 0 && cset_b[36:14] == 0 && cset_b[12:0] == 0);
            assert ((role_a == 2'd0 || role_a == 2'd1) && (role_b == 2'd0 || role_b == 2'd1));
            // Only the states of timed bits, between ticks: settling and
            // finishing a bit take no tick of their own here.
            assert (s_a <= S_MID && s_b <= S_MID);
            // Only bit instructions wait on the bus, and only `idle` claims;
            // the rest take a tick each.
            if (ins_a[31:28] != 4'd1) begin assert (s_a == S_BOOT || a_exec || (ins_a[31:28] == 4'd2 && a_claim)); end
            else assert (a_exec || a_sync || a_edge || a_mid);
            if (ins_b[31:28] != 4'd1) begin assert (s_b == S_BOOT || b_exec || (ins_b[31:28] == 4'd2 && b_claim)); end
            else assert (b_exec || b_sync || b_edge || b_mid);
            assert (at_a < PROG_LEN && at_b < PROG_LEN && at_a < PC_BADDEL && at_b < PC_BADDEL);

            // ---- A bit in progress: its owner and source are its
            // instruction's, or a stuff bit's ----
            // A hart is inside an instruction past its first bit, the flag a
            // trap checks, exactly while it is on a later bit.
            assert (partial_a[0] == ((a_sync || a_edge || a_mid) && k_a != 0)
                    && partial_b[0] == ((b_sync || b_edge || b_mid) && k_b != 0));
            // Its index never passes the instruction's last bit.
            if (a_sync || a_edge || a_mid) assert (mine_a == mine_of(ins_a[24:23], role_a) && k_a <= ins_a[20:17]
                                         && src_a == (code_a[1] ? {1'b1, code_a[0]} : ins_a[22:21]));
            if (b_sync || b_edge || b_mid) assert (mine_b == mine_of(ins_b[24:23], role_b) && k_b <= ins_b[20:17]
                                         && src_b == (code_b[1] ? {1'b1, code_b[0]} : ins_b[22:21]));

            // ---- What each hart holds while it waits for a bit's edge ----
            // A sender drives the delimiters and the tail recessive, and the
            // start of frame dominant; the receiver drives the ACK.
            if (a_edge && (at_a == PC_CRCDEL || at_a == PC_TAIL))
                assert (mine_a == (role_a == 2'd0) && (!mine_a || val_a) && src_a == ins_a[22:21]);
            if (b_edge && (at_b == PC_CRCDEL || at_b == PC_TAIL))
                assert (mine_b == (role_b == 2'd0) && (!mine_b || val_b) && src_b == ins_b[22:21]);
            if (a_edge && at_a == PC_SOF) assert (role_a == 2'd0 && mine_a && !val_a && src_a == ins_a[22:21]);
            if (b_edge && at_b == PC_SOF) assert (role_b == 2'd0 && mine_b && !val_b && src_b == ins_b[22:21]);
            if (a_edge && at_a == PC_ACK) assert (mine_a == (role_a != 2'd0) && (!mine_a || !val_a) && src_a == ins_a[22:21]);
            if (b_edge && at_b == PC_ACK) assert (mine_b == (role_b != 2'd0) && (!mine_b || !val_b) && src_b == ins_b[22:21]);

            // ---- The hold counter and the last fall ----
            // Each hart counts BUS as it sees it, two ticks late, but starts
            // again at once when it pulls BUS low itself.
            assert (rq == rq1);
            assert (held_a == (low_a1 ? 32'd0 : {16'd0, held_seen})
                    && held_b == (low_b1 ? 32'd0 : {16'd0, held_seen}));
            if (!g_fell) assert ((idle && !m_fr) || (stuffed && m_i == 0 && !m_stuff
                                 && ((tq == 12'd1 && !m_fr) || (tq == 12'd2 && m_fr))));
            assert (cset_a[13] == cset_b[13] && lf_a == lf_b);
            // A hart forgets a fall 1024 ticks on, but not on a tick its hold
            // trap fires.
            if (cset_a[13]) assert (lf_a == seen_fall && (now_a - lf_a < 12'd1024
                                    || (now_a - lf_a == 12'd1024 && held_a[15:0] == can_hold_ticks(BIT)
                                        && held_b[15:0] == can_hold_ticks(BIT))));
            // The last fall the harts have seen, while they still count it: in
            // a frame, this bit's fall, two ticks on, or one in a bit before;
            // after the ACK slot, the ACK's fall. BUS falls where the winner's
            // bits start, and while two still send, where the earlier's do.
            // So a listener never moves its bit edge to a fall in the middle of
            // a bit. Ages are compared wide, as a bit can be longer than half
            // the range of the harts' 12-bit clock.
            // While two send, BUS falls at the earlier's edge, but in the bit
            // that decides, where a later winner's comes first.
            if (cset_a[13] && stuffed)
                assert ((tq >= 12'd2 && lf_a == cs + 12'd2 && m_last && (m_i == 0 || (!decided && !(dec_now && late_w))))
                        || (tq >= wo12 + 12'd2 && lf_a == cs + wo12 + 12'd2 && m_last && (decided || (dec_now && late_w)))
                        || lf_age + 16'd6 >= {4'd0, tq} + {4'd0, d});
            if (cset_a[13] && tail) begin
                if (m_tail == 0 || (m_tail == 4'd1 && tq < r_off + 12'd2)) begin assert (lf_age + 16'd6 >= {4'd0, tq} + {4'd0, d}); end
                else assert (lf_age + {4'd0, r_off} + 16'd2 == {4'd0, tq} + {12'd0, m_tail - 4'd1} * {4'd0, d});
                // From the ACK's fall on, the harts count it until it is 1024
                // ticks old; there the age is known wide.
            end
            if (tail && (m_tail >= 4'd2 || (m_tail == 4'd1 && tq >= r_off + 12'd2)))
                assert (cset_a[13] == ({4'd0, tq} + {12'd0, m_tail - 4'd1} * {4'd0, d} < {4'd0, r_off} + 16'd2 + 16'd1024));
            // BUS's recessive run: in the stuffed part at most the bits of its
            // run so far; from the ACK on, exactly.
            if (stuffed && m_i != 0) assert (rqv <= rec_before + {4'd0, tq} + 16'd1);
            if (stuffed && m_i == 0) assert (rqv == 0 && g_fall == cs);
            if (tail) begin
                if (m_tail == 0) begin assert (rqv <= rec_before + {4'd0, tq} + 16'd1); end
                else if (m_tail == 1) begin assert (rqv <= (tq < r_off ? rec_before + {4'd0, d} + {4'd0, tq} + 16'd1 : 16'd0)); end
                else if (m_tail == 2 && tq < r_off) begin assert (rqv == 0); end
                else assert (rqv == {4'd0, m_tail - 4'd2} * {4'd0, d} + {4'd0, tq} + 16'd1 - {4'd0, r_off});
                if (m_tail == 4'd1 && tq > r_off) assert (ack_t == r_off[10:0]);
                if (m_tail >= 4'd2 && m_tail < 4'd12) assert (ack_t == {7'd0, w_b ? o_a : o_b});
            end

            // ---- The tail and idle ----
            if (tail || idle) assert (!code_a[1] && !code_b[1] && rx_a == m_sh && rx_b == m_sh
                                      && count_a == 0 && count_b == 0);
            if (tail) assert (code_a[22:8] == 0 && code_b[22:8] == 0 && (fr || m_tail == 4'd12));
            // In the tail one hart sends and the other receives.
            if (tail && m_tail < 4'd12) assert (role_a != role_b && (role_a == 2'd0) == !w_b);
            // After `stuff` has restarted it, the coder is clear until the start
            // of frame is read.
            if (at_a == PC_LOSE || (at_a == PC_SOF && !(a_mid && since_a != 0))) assert (code_a[23:0] == 0);
            if (at_b == PC_LOSE || (at_b == PC_SOF && !(b_mid && since_b != 0))) assert (code_b[23:0] == 0);
            if (idle) begin
                // Neither hart is inside a frame, so the hold trap cuts none off.
                assert (!partial_a[0] && !partial_b[0]);
                assert ((!low_a || (at_a == PC_SOF && a_mid)) && (!low_b || (at_b == PC_SOF && b_mid)));
                assert (m_bus || low_a || low_b);
                assert (at_a <= PC_SOF && at_b <= PC_SOF);
                if (at_a == PC_SOF) begin assert (a_exec || (a_edge && ahead_a != 0)
                                            || (a_mid && since_a == 0 && !m_bus && m_prev && low_a)); end
                if (at_b == PC_SOF) begin assert (b_exec || (b_edge && ahead_b != 0)
                                            || (b_mid && since_b == 0 && !m_bus && m_prev && low_b)); end
                // Each hart's edge after a frame: its offset into idle.
                if (at_a >= PC_IDLE && !(at_a == PC_SOF && a_mid))
                    assert (ahead_a == ((m_fr && m_it < {12'd0, o_a}) ? {8'd0, o_a} - m_it[11:0] : 12'd0));
                if (at_b >= PC_IDLE && !(at_b == PC_SOF && b_mid))
                    assert (ahead_b == ((m_fr && m_it < {12'd0, o_b}) ? {8'd0, o_b} - m_it[11:0] : 12'd0));
                // A hart past `idle` has claimed as a sender.
                if (at_a > PC_IDLE) assert (role_a == 2'd0 && in_a == (at_a != PC_STUFF || !a_exec));
                if (at_b > PC_IDLE) assert (role_b == 2'd0 && in_b == (at_b != PC_STUFF || !b_exec));
                // The hold trap can send a hart that has just claimed back to
                // `idle`; it is still flagged as a sender for that tick.
                if (at_a <= PC_IDLE) assert (!in_a || (at_a == PC_IDLE && a_exec && held_a[15:0] == can_hold_ticks(BIT)));
                if (at_b <= PC_IDLE) assert (!in_b || (at_b == PC_IDLE && b_exec && held_b[15:0] == can_hold_ticks(BIT)));
                if (at_a == PC_IDLE) assert ((a_exec || a_claim) && armed_a[0]);
                if (at_b == PC_IDLE) assert ((b_exec || b_claim) && armed_b[0]);
                if (at_a > PC_IDLE) assert (armed_a[0]);
                if (at_b > PC_IDLE) assert (armed_b[0]);
                // The mode words run one a tick from reset, on both harts at
                // once, and nothing has been sampled since reset loaded the
                // inputs from BUS.
                if (at_a < PC_IDLE || at_b < PC_IDLE)
                    assert (at_a == at_b && s_a == s_b && !m_fr && edge_a == now_a && (s_a == S_BOOT || a_exec)
                            && now_a == (s_a == S_BOOT ? 12'd0 : {6'd0, at_a} + 12'd1) && m_it == {4'd0, now_a}
                            && armed_a[0] && armed_b[0] && role_a == 2'd0 && role_b == 2'd0 && edge_b == now_b);
                // Until the first frame, the idle count is the time since reset.
                if (!m_fr) assert (m_it == 16'hFFFF || m_it[11:0] == now_a);
                if (!m_fr && m_bus) assert (rqv == (m_it == 16'hFFFF ? m_it : m_it + 16'd1));
                // After a frame: the tail's 11 recessive bits from the end of
                // the ACK, and the idle time; added wide, as both counts stop at
                // FFFF.
                if (m_fr && m_bus) assert (rqv == (it_run > 18'h0FFFF ? 16'hFFFF : it_run[15:0]));
                // The last fall the harts still count is the ACK's, seen 2 ticks
                // after it fell, 12 bits less that before the idle count began.
                if (cset_a[13]) assert (m_fr && {6'd0, now_a - lf_a} == {2'd0, m_it} + 18'd12 * {6'd0, d}
                                                                        - 18'd2 - {7'd0, ack_t});
                if (m_fr && {2'd0, m_it} + 18'd12 * {6'd0, d} < 18'd1026 + {7'd0, ack_t}) assert (cset_a[13]);
            end

            // ---- The start of frame: each hart joins ----
            // A hart not yet in the frame has not claimed yet, as it sees BUS
            // low only two ticks on; or it has claimed as the receiver and runs
            // `stuff`, `lose` and `sof`; or it claimed as a sender before it
            // could see the fall and pulls BUS low for its own start of frame
            // at most 4 ticks after the first. Its hold trap can fire on the
            // first tick, as it sees BUS low only a tick later: it is then back
            // at `idle`.
            if (stuffed && m_i == 0) begin
                if (!a_joined) assert (armed_a[0] && count_a == 0 && rx_a == m_sh
                    && ((at_a == PC_IDLE && tq <= 12'd1 && (a_claim || (a_exec && held_a[15:0] == can_hold_ticks(BIT))))
                        || (role_a == 2'd1 && a_exec && ((tq == 12'd2 && at_a == PC_STUFF) || (tq == 12'd3 && at_a == PC_LOSE)
                                                         || (tq == 12'd4 && at_a == PC_SOF)))
                        || (role_a == 2'd0 && pull_a <= 12'd4 && ((a_exec && (at_a == PC_STUFF || at_a == PC_LOSE))
                                                                 || ((a_exec || a_edge) && at_a == PC_SOF)))
                        || (at_a == PC_SOF && a_mid && since_a == 0 && low_a && !k_set)));
                if (!b_joined) assert (armed_b[0] && count_b == 0 && rx_b == m_sh
                    && ((at_b == PC_IDLE && tq <= 12'd1 && (b_claim || (b_exec && held_b[15:0] == can_hold_ticks(BIT))))
                        || (role_b == 2'd1 && b_exec && ((tq == 12'd2 && at_b == PC_STUFF) || (tq == 12'd3 && at_b == PC_LOSE)
                                                         || (tq == 12'd4 && at_b == PC_SOF)))
                        || (role_b == 2'd0 && pull_b <= 12'd4 && ((b_exec && (at_b == PC_STUFF || at_b == PC_LOSE))
                                                                 || ((b_exec || b_edge) && at_b == PC_SOF)))
                        || (at_b == PC_SOF && b_mid && since_b == 0 && low_b && !k_set)));
            end
            // Until then it drives nothing, but on the tick it pulls BUS low;
            // once in the frame it is past its own start of frame.
            if (stuffed && m_i == 0) begin
                if (!a_joined) begin assert (low_a == (at_a == PC_SOF && a_mid) && !low_a1 && !low_a2 && !low_a3); end
                else assert (tq > oa12);
                if (!b_joined) begin assert (low_b == (at_b == PC_SOF && b_mid) && !low_b1 && !low_b2 && !low_b3); end
                else assert (tq > ob12);
            end
            // From then on both harts are in the frame.
            if (stuffed && !(m_i == 0 && tq <= 12'd4)) assert (a_joined && b_joined);

            // ---- Two senders: arbitration ----
            // A frame has a sender in it; a sender is in it, and so is a hart
            // that lost.
            if (stuffed) assert (fr && (in_a || role_a != 2'd0 || at_a <= PC_STUFF) && (in_b || role_b != 2'd0 || at_b <= PC_STUFF));
            // The winner never loses.
            if (stuffed) assert (w_b ? role_b == 2'd0 : role_a == 2'd0);
            // The skew is set once both have pulled BUS low, at most 4 ticks
            // apart, and each hart's grid follows: the winner's is woff; a
            // loser keeps its own until it moves to 2 ticks after the winner's.
            if (stuffed && k_set) assert (con && k_sk <= 4'd4);
            if (stuffed && con && !(m_i == 0 && tq <= 12'd4)) assert (k_set);
            if (stuffed && !con) assert (in_a ? (o_a == 0 && o_b == 4'd2) : (o_b == 0 && o_a == 4'd2));
            if (stuffed && con && !k_set) assert (early_b ? (o_b == 0 && o_a == 4'd2) : (o_a == 0 && o_b == 4'd2));
            if (stuffed && con && k_set) begin
                if (w_b) begin assert (o_b == {1'b0, woff[2:0]} && (o_a == st_oa
                                       || (decided && o_a == wo2 && !far(wo2, st_oa, BIT)))); end
                else assert (o_a == {1'b0, woff[2:0]} && (o_b == st_ob
                             || (decided && o_b == wo2 && !far(wo2, st_ob, BIT))));
            end
            assert (k_sk <= 4'd4 && o_a <= 4'd8 && o_b <= 4'd8);
            if (idle && !m_fr) assert (o_a == 0 && o_b == 0);
            // The mode words run only after reset, with BUS idle.
            if (at_a < PC_IDLE || at_b < PC_IDLE) assert (idle && !m_fr);
            // In the tail both harts are in the frame: on their own grid, the
            // first cell's start still to come, or in it. The receiver's grid
            // is as in the stuffed part; the sender's is the winner's until it
            // moves to the receiver's ACK.
            if (tail) assert ((a_tail || a_joined) && (b_tail || b_joined));
            if (tail && m_tail < 4'd12) begin
                if (!con) begin assert (in_a ? (o_b == 4'd2 && (o_a == 0 || o_a == 4'd4)) : (o_a == 4'd2 && (o_b == 0 || o_b == 4'd4))); end
                else if (w_b) begin assert ((o_b == {1'b0, woff[2:0]} || (m_tail != 0 && o_b == o_a + 4'd2))
                                            && (o_a == st_oa || (o_a == wo2 && !far(wo2, st_oa, BIT)))); end
                else assert ((o_a == {1'b0, woff[2:0]} || (m_tail != 0 && o_a == o_b + 4'd2))
                             && (o_b == st_ob || (o_b == wo2 && !far(wo2, st_ob, BIT))));
                // Until it has seen the ACK, the sender is on the winner's grid.
                if (m_tail == 0 || (m_tail == 4'd1 && tq <= r_off + 12'd2)) assert (w_b ? o_b == {1'b0, woff[2:0]} : o_a == {1'b0, woff[2:0]});
                if (con) assert (k_set && decided);
            end
            // From the ACK delimiter on, the receiver is the hart on the ACK's
            // grid, and the sender is 2 ticks after it, or 2 to 4 before when
            // it did not move to the ACK. Each keeps its role until it claims
            // again.
            if ((tail && m_tail >= 4'd2) || (idle && m_fr)) begin
                assert ((o_a == ack_t[3:0] && pair_ok(o_a, o_b, BIT)) || (o_b == ack_t[3:0] && pair_ok(o_b, o_a, BIT)));
                assert (ack_t <= 11'd6);
            end
            // In the ACK slot the sender moves its edge to the ACK as it sees
            // it, if that is within a quarter bit of its own.
            if (tail && m_tail < 4'd12 && (m_tail >= 4'd2 || (m_tail == 4'd1 && tq > r_off + 12'd2)))
                assert ((w_b ? o_b : o_a) == (far(r_off[3:0] + 4'd2, {1'b0, woff[2:0]}, BIT) ? {1'b0, woff[2:0]}
                                                                                            : r_off[3:0] + 4'd2));
            if (tail && m_tail >= 4'd2) begin
                assert ((at_a >= PC_STUFF && at_a <= PC_SOF) || role_a == (o_a == ack_t[3:0] ? 2'd1 : 2'd0));
                assert ((at_b >= PC_STUFF && at_b <= PC_SOF) || role_b == (o_b == ack_t[3:0] ? 2'd1 : 2'd0));
            end
            // A hart that claims in the tail, with BUS recessive, claims as a
            // sender.
            if (tail && at_a >= PC_STUFF && at_a <= PC_SOF) assert (role_a == 2'd0 && (at_a == PC_STUFF || in_a));
            if (tail && at_b >= PC_STUFF && at_b <= PC_SOF) assert (role_b == 2'd0 && (at_b == PC_STUFF || in_b));
            // While both still send, the bits before this one are the same in
            // both frames; so the first that differs decides, and the frame
            // with the smaller identifier wins.
            // Once decided, they differ in a bit read so far, or in this one.
            if (stuffed && !decided) assert (agree(m_i - 8'd1, f1a, f2a, f1b, f2b));
            if (stuffed && con && decided && m_i <= 8'd11) assert (!agree(m_i, f1a, f2a, f1b, f2b));
            // Two contending identifiers differ, as assumed.
            if (stuffed && con && role_a == 2'd0 && role_b == 2'd0 && at_a > PC_LOAD2 && at_b > PC_LOAD2
                    && f1a[7:5] == f1b[7:5]) assert (f2a != f2b);
            // A sender has taken its second identifier byte this frame once it
            // is past `load2`.
            if (role_a == 2'd0 && in_a && at_a > PC_LOAD1) assert (ld2a == (at_a > PC_LOAD2));
            if (role_b == 2'd0 && in_b && at_b > PC_LOAD1) assert (ld2b == (at_b > PC_LOAD2));

            // ---- Stores ----
            // The monitor's log: a field for each one read, the last fields
            // the winner's header. Each hart stores the fields as the monitor
            // read them, one at a time; outside the stuffed part it has stored
            // the frame's all.
            if (stuffed) assert (m_nf == fcnt(m_vi, m_n) - ((m_sample && !m_stuff && m_fe) ? 4'd1 : 4'd0));
            if (tail || (idle && m_fr)) assert (m_nf == 4'd3 + m_n && na == m_nf && nb == m_nf && !push_a && !push_b);
            if (idle && !m_fr) assert (m_nf == 0 && na == 0 && nb == 0 && !push_a && !push_b);
            if (stuffed && m_i == 0) assert (m_nf == 0 && na == 0 && nb == 0 && !push_a && !push_b);
            if (stuffed || (tail && m_tail < 4'd12)) begin
                if (m_nf > 4'd0) assert ((m_log[0] & 8'h07) == {5'd0, wf1[7:5]});
                if (m_nf > 4'd1) assert (m_log[1] == wf2);
                if (m_nf > 4'd2) assert ((m_log[2] & 8'h7F) == {1'b0, wf3[7:1]});
            end
            // Until the monitor reads another bit, its last field is the last
            // bits it read; a hart stores a field with those bits in hand.
            if (stuffed && m_nf != 0 && m_vi == fend_at(m_nf - 4'd1) + 8'd1)
                assert (((m_log[m_nf - 4'd1] ^ m_vsh) & mask_of(m_nf - 4'd1)) == 8'd0);
            // A hart on the monitor's grid stores on the tick the monitor logs.
            if (a_store) assert (((rx_a ^ (m_logs && na == m_nf ? m_fb[7:0] : m_log[na])) & mask_of(na)) == 8'd0
                                 && (na < m_nf || (m_logs && na == m_nf)));
            if (b_store) assert (((rx_b ^ (m_logs && nb == m_nf ? m_fb[7:0] : m_log[nb])) & mask_of(nb)) == 8'd0
                                 && (nb < m_nf || (m_logs && nb == m_nf)));
            if (push_a) assert (((pdata_a ^ m_log[na]) & mask_of(na)) == 8'd0 && na < m_nf);
            if (push_b) assert (((pdata_b ^ m_log[nb]) & mask_of(nb)) == 8'd0 && nb < m_nf);
            for (li = 0; li < 16; li = li + 1) begin
                if (li < na) assert (((log_a[li] ^ m_log[li]) & mask_of(li)) == 8'd0);
                if (li < nb) assert (((log_b[li] ^ m_log[li]) & mask_of(li)) == 8'd0);
            end

            // ---- The bit before this one ----
            // The monitor now is the bit before, stepped at its end.
            if (p_st == M_STUFFED) begin
                // It was the monitor's state, so the monitor's invariants held.
                assert (p_run <= 3'd5 && (p_i == 0) == (p_run == 0) && {5'd0, p_run} <= p_i
                        && (p_i != 0 || (p_last && p_crc == 0 && !p_cur)));
                assert (p_i < p_crc_at + 8'd15 || (p_i == p_crc_at + 8'd15 && p_stuff));
                assert (m_st == (p_to_tail ? M_TAIL : M_STUFFED) && m_run == p_run_next && m_last == p_cur);
                if (p_stuff) begin assert (m_i == p_i && m_crc == p_crc && m_sh == p_sh && m_f == p_f
                                           && m_dlc == p_dlc); end
                else assert (m_i == p_i + 8'd1 && m_crc == (p_i < p_crc_at ? p_crc_next : p_crc)
                             && m_sh == (p_i != 0 ? {p_sh[6:0], p_cur} : p_sh)
                             && m_f == (p_fstart ? {14'd0, p_cur} : p_fb)
                             && m_dlc == (p_i == 8'd18 ? p_fb[3:0] : p_dlc));
                if (p_to_tail) assert (m_tail == 0);
            end
            if (p_st == M_TAIL) assert ((m_st == M_TAIL && m_tail == p_tail + 4'd1) || (m_st == M_IDLE && p_tail == 4'd12));
            if (m_st == M_STUFFED) assert (p_st == (m_i == 0 ? M_IDLE : M_STUFFED));
            if (m_st == M_TAIL) assert (p_st == (m_tail == 0 ? M_STUFFED : M_TAIL));
            assert (p_st != 2'd3);
        end
    end
endmodule

// A hart in the stuffed part of a frame, checked against the frame as the
// monitor had it d ticks ago: snap is the monitor's state and BUS then. A
// hart on a grid d ticks after the monitor's holds what a sender on the
// monitor's grid held d ticks ago, in everything that follows from where it
// is in the frame. A sender also drives its bits and takes its bytes; a
// receiver drives nothing.
module can_view (
    input         clk_v,     // the simulation checks once a tick, at its falling edge
    input         en,        // check this hart now
    input         snd,       // it sends; else it receives
    input  [10:0] BIT,
    input  [5:0]  start,
    input  [72:0] snap,      // {st, t, i, run, last, crc, f, sh, dlc, tail, cur, bus}
    input  [5:0]  at,
    input  [3:0]  s,
    input  [3:0]  k,
    input  [23:0] code,      // the coder's low bits: crc, run, inserted
    input  [7:0]  rx,
    input  [7:0]  count,
    input  [11:0] now,
    input  [11:0] edge_t,
    input         mine,
    input         val,
    input  [1:0]  src,
    input  [7:0]  tx,
    input         low,
    input         low1, low2, low3,   // its drive one, two and three ticks ago
    input  [1:0]  role,
    input  [31:0] ins,
    input  [7:0]  g1, g2, g3, gd, gd0,  // the bytes this hart took, for a sender
    input  [3:0]  dn,                 // and how many data bytes
    input  [3:0]  nst,                // fields it has stored this frame
    input         push                // it stores one now
);
    `include "can_rom.vh"
    localparam S_EXEC = 4'd1, S_EDGE = 4'd4, S_MID = 4'd5;
    localparam M_IDLE = 2'd0, M_STUFFED = 2'd1, M_TAIL = 2'd2;

    wire [1:0]  m_st = snap[72:71];
    wire [10:0] m_t = snap[70:60];
    wire [7:0]  m_i = snap[59:52];
    wire [2:0]  m_run = snap[51:49];
    wire        m_last = snap[48];
    wire [14:0] m_crc = snap[47:33];
    wire [14:0] m_f = snap[32:18];
    wire [7:0]  m_sh = snap[17:10];
    wire [3:0]  m_dlc = snap[9:6];
    wire [3:0]  m_tail = snap[5:2];
    wire        m_cur = snap[1];
    wire        m_bus = snap[0];

    wire [11:0] d = {1'b0, BIT};
    wire [11:0] h = {2'b00, BIT[10:1]};
    wire [11:0] tq = {1'b0, m_t};
    wire        m_sample = m_st != M_IDLE && m_t == h[10:0];
    wire        m_read = m_st != M_IDLE && m_t >= h[10:0];
    wire        m_b = m_sample ? m_bus : m_cur;
    wire        m_stuff = m_st == M_STUFFED && m_run == 3'd5;
    wire [3:0]  m_n = m_dlc > 4'd8 ? 4'd8 : m_dlc;
    wire [7:0]  m_crc_at = 8'd19 + {m_n, 3'd0};
    wire [14:0] m_fb = {m_f[13:0], m_b};
    wire [14:0] m_crc_next = {m_crc[13:0], 1'b0} ^ ((m_b ^ m_crc[14]) ? 15'h4599 : 15'h0);
    wire [2:0]  m_run_next = m_b == m_last ? m_run + 1'b1 : 3'd1;

    wire        x_exec = s == S_EXEC, x_edge = s == S_EDGE, x_mid = s == S_MID;
    wire [11:0] since = now - edge_t, ahead = edge_t - now;
    wire        pre = m_t < h[10:0];
    wire [7:0]  v_i = (m_read && !m_stuff) ? m_i + 1'b1 : m_i;
    wire [2:0]  v_run = m_read ? m_run_next : m_run;
    wire        v_last = m_read ? m_b : m_last;
    wire [14:0] v_crc = (m_read && !m_stuff && m_i < m_crc_at) ? m_crc_next : m_crc;
    wire [7:0]  v_sh = (m_read && !m_stuff && m_i != 0) ? {m_sh[6:0], m_b} : m_sh;
    wire [3:0]  v_n = (m_read && !m_stuff && m_i == 8'd18) ? (m_fb[3:0] > 4'd8 ? 4'd8 : m_fb[3:0]) : m_n;
    wire [7:0]  v_crc_at = 8'd19 + {v_n, 3'd0};

    function automatic [9:0] place(input [7:0] i, input [7:0] crc_at);
        reg [7:0] x;
        begin
            if (i == 0) place = {PC_SOF, 4'd0};
            else if (i <= 8'd3) begin x = i - 8'd1; place = {PC_ID1, x[3:0]}; end
            else if (i <= 8'd11) begin x = i - 8'd4; place = {PC_ID2, x[3:0]}; end
            else if (i <= 8'd18) begin x = i - 8'd12; place = {PC_CTRL, x[3:0]}; end
            else if (i < crc_at) begin x = i - 8'd19; place = {PC_DATA, 1'b0, x[2:0]}; end
            else begin x = i - crc_at; place = {PC_CRC, x[3:0]}; end
        end
    endfunction
    function automatic fend(input [7:0] i, input [7:0] crc_at);
        fend = i == 0 || i == 8'd3 || i == 8'd11 || i == 8'd18
               || (i > 8'd18 && i < crc_at && i[2:0] == 3'd2) || i == crc_at + 8'd14;
    endfunction
    function automatic [6:0] after(input [7:0] j, input [3:0] n, input [7:0] crc_at, input [11:0] p);
        reg [5:0] w0, w1, w2, w3, w4, w5, w;
        reg [2:0] len;
        begin
            w0 = 0; w1 = 0; w2 = 0; w3 = 0; w4 = 0; w5 = 0;
            if (j == 0) begin w0 = PC_LOAD1; w1 = PC_ID1; len = 3'd2; end
            else if (j == 8'd3) begin w0 = PC_STORE1; w1 = PC_LOAD2; w2 = PC_ID2; len = 3'd3; end
            else if (j == 8'd11) begin w0 = PC_STORE2; w1 = PC_LOAD3; w2 = PC_CTRL; len = 3'd3; end
            else if (j == 8'd18) begin
                w0 = PC_STORE3; w1 = PC_NOLOSE; w2 = PC_COUNT; w3 = PC_NODATA;
                if (n != 0) begin w4 = PC_DLOAD; w5 = PC_DATA; len = 3'd6; end
                else begin w4 = PC_CRC; len = 3'd5; end
            end else if (j < crc_at) begin
                w0 = PC_DSTORE; w1 = PC_DLOOP;
                if (j == crc_at - 8'd1) begin w2 = PC_CRC; len = 3'd3; end
                else begin w2 = PC_DLOAD; w3 = PC_DATA; len = 3'd4; end
            end else begin w0 = PC_UNSTUFF; w1 = PC_CRCDEL; len = 3'd2; end
            case (p >= {9'd0, len} ? len - 3'd1 : p[2:0])
                3'd0: w = w0;
                3'd1: w = w1;
                3'd2: w = w2;
                3'd3: w = w3;
                3'd4: w = w4;
                default: w = w5;
            endcase
            after = {w, p >= {9'd0, len}};
        end
    endfunction
    function automatic fbit(input [7:0] i, input [7:0] crc_at, input [7:0] b1, b2, b3, bd,
                            input [14:0] crc);
        reg [7:0] x;
        begin
            if (i == 0) fbit = 1'b0;
            else if (i <= 8'd3) begin x = 8'd8 - i; fbit = b1[x[2:0]]; end
            else if (i <= 8'd11) begin x = 8'd11 - i; fbit = b2[x[2:0]]; end
            else if (i <= 8'd18) begin x = 8'd19 - i; fbit = b3[x[2:0]]; end
            else if (i < crc_at) begin x = 8'd2 - i; fbit = bd[x[2:0]]; end
            else begin x = crc_at + 8'd14 - i; fbit = crc[x[3:0]]; end
        end
    endfunction

    wire        next_stuff = v_run == 3'd5;
    wire        next_byte = !pre && !m_stuff && !next_stuff && v_i > 8'd19 && v_i < v_crc_at
                            && v_i[2:0] == 3'd3 && tq - h >= 12'd3;
    // The bit this hart sends now, from its own bytes.
    wire        own_bit = m_stuff ? !m_last : fbit(m_i, m_crc_at, g1, g2, g3, next_byte ? gd0 : gd, m_crc);
    wire [9:0]  pl_cur = place(m_stuff ? m_i - 8'd1 : m_i, m_crc_at);
    wire        nx_bit = next_stuff ? !v_last : v_i == v_crc_at + 8'd15 ? 1'b1
                         : fbit(v_i, v_crc_at, g1, g2, g3, gd, v_crc);
    wire [7:0]  v_j = v_i - 8'd1;
    wire [9:0]  pl_j = place(v_j, v_crc_at);
    wire        j_end = fend(v_j, v_crc_at);
    wire [6:0]  aft = after(v_j, v_n, v_crc_at, tq - h);
    wire [7:0]  v_dd = v_i > 8'd19 ? (v_i - 8'd19) >> 3 : 8'd0;
    wire [7:0]  v_past = v_i > v_crc_at ? v_i - v_crc_at : 8'd0;
    wire [14:0] x_crc = v_crc << v_past;

`ifdef CAN_SIM
    always @(negedge clk_v) begin
`else
    always @* begin
`endif
        if (en && m_st == M_STUFFED) begin
            assert (role == (snd ? 2'd0 : 2'd1));
            assert (code[22:8] == x_crc);
            assert (code[7:4] == {1'b0, v_run} && code[3] == (v_i != 0) && code[2] == (v_i != 0 && v_last));
            assert (rx == v_sh);
            if (snd) begin assert (low == !own_bit); end
            else assert (!low);
            // Its drive changes only as its bits start; once a bit is read it
            // is what the monitor read. Before, it was the bit before.
            if (!snd) begin assert (!low1 && !low2 && !low3); end
            else if (pre) begin assert (low1 == (tq < 12'd1 ? !m_last : low) && low2 == (tq < 12'd2 ? !m_last : low)
                                        && low3 == (tq < 12'd3 ? !m_last : low)); end
            else assert (low == !v_last && low1 == low && low2 == low && low3 == low);
            // The fields it has stored: one at each store, the one it stores now
            // counted.
            assert ({4'd0, nst} + (push ? 8'd1 : 8'd0)
                    == (at > PC_STORE1 ? 8'd1 : 8'd0) + (at > PC_STORE2 ? 8'd1 : 8'd0) + (at > PC_STORE3 ? 8'd1 : 8'd0)
                       + (at > PC_DLOOP ? {4'd0, v_n} : at > PC_STORE3 ? v_dd - ((at == PC_DSTORE
                          || (at == PC_DATA && code[1] && k == 4'd7 && v_i[2:0] == 3'd3)) ? 8'd1 : 8'd0) : 8'd0));
            // The data bytes it has taken.
            if (snd) begin
                if (at >= PC_NODATA && at <= PC_DLOOP)
                    begin assert ({4'd0, dn} + count == {4'd0, v_n}
                                  + ((at == PC_DATA || at == PC_DSTORE || at == PC_DLOOP) ? 8'd1 : 8'd0)); end
                else if (at > PC_LOAD1) assert (dn == (at > PC_DLOOP ? v_n : 4'd0));
            end
            if (pre) begin
                // Sending, or reading, this bit. A listener that moves its edge
                // to a fall while it waits for its edge is still waiting on
                // that tick, with its edge moved to the fall: this bit's start
                // on its new grid.
                assert ((x_mid && since == tq) || (!snd && x_edge && since == tq));
                assert (at == pl_cur[9:4] && k == pl_cur[3:0]);
                assert (code[1] == m_stuff && code[0] == (m_stuff && !m_last));
                assert (mine == snd && src == (m_stuff ? {1'b1, !m_last} : ins[22:21]));
                if (snd) assert (val == own_bit);
            end else begin
                assert (ahead == d - tq);
                assert (code[1] == next_stuff && code[0] == (next_stuff && !v_last));
                if (next_stuff || !j_end) begin
                    assert (x_edge && at == pl_j[9:4] && k == pl_j[3:0] + (next_stuff ? 4'd0 : 4'd1));
                    assert (mine == snd && src == (next_stuff ? {1'b1, !v_last} : ins[22:21]));
                    if (snd) assert (val == nx_bit);
                end else begin
                    assert (at == aft[6:1] && (aft[0] ? (x_edge && k == 0) : x_exec));
                    if (aft[0]) begin
                        assert (mine == snd && src == ins[22:21]);
                        if (snd) assert (val == nx_bit);
                    end
                end
            end
            // The count: data bytes still to send, the one in hand included.
            if (at == PC_NODATA || at == PC_DLOAD || at == PC_DATA || at == PC_DSTORE || at == PC_DLOOP)
                begin assert (count == {4'd0, v_n} - v_dd
                                   + ((at == PC_DSTORE || at == PC_DLOOP
                                       || (at == PC_DATA && code[1] && k == 4'd7 && v_i[2:0] == 3'd3)) ? 8'd1 : 8'd0)); end
            else assert (count == 0);
            // A sender's shift register: the field's byte, shifted once as each
            // of its bits starts.
            if (snd && (at == PC_ID1 || at == PC_ID2 || at == PC_CTRL || at == PC_DATA))
                assert (tx == ((at == PC_ID1 ? g1 : at == PC_ID2 ? g2 : at == PC_CTRL ? g3 : gd)
                               << (x_exec ? 4'd0 : k + 4'd1)));
        end
    end
endmodule

// A hart in the tail of a frame, at tick t of its own cell c: 0 the CRC
// delimiter, 1 the ACK slot, 2 the ACK delimiter, 3 to 12 the end of frame
// and intermission. The sender drives the tail recessive and only listens
// in the ACK slot, where it may move its edge to the receiver's ACK; the
// receiver drives the ACK.
module can_tail (
    input         clk_v,
    input         en,
    input         snd,       // the frame's sender
    input  [10:0] BIT,
    input  [3:0]  c,
    input  [11:0] t,
    input  [5:0]  at,
    input  [3:0]  s,
    input  [3:0]  k,
    input  [11:0] now,
    input  [11:0] edge_t,
    input         mine,
    input         val,
    input         low,
    input         low1, low2, low3,
    input         m_last,    // the frame's last stuffed bit
    input         armed0
);
    `include "can_rom.vh"
    localparam S_EXEC = 4'd1, S_CLAIM = 4'd2, S_EDGE = 4'd4, S_MID = 4'd5;
    wire [11:0] d = {1'b0, BIT};
    wire [11:0] h = {2'b00, BIT[10:1]};
    wire        x_exec = s == S_EXEC, x_claim = s == S_CLAIM, x_edge = s == S_EDGE, x_mid = s == S_MID;
    wire [11:0] since = now - edge_t, ahead = edge_t - now;
    wire [3:0]  kc = c - 4'd2;                   // its TAIL bit
`ifdef CAN_SIM
    always @(negedge clk_v) begin
`else
    always @* begin
`endif
        if (en) begin
            // Drives: the sender its last stuffed bit until its delimiter
            // starts, the receiver the ACK for its cell.
            if (snd) begin assert (!low && low1 == (c == 0 && t < 12'd1 && !m_last)
                                   && low2 == (c == 0 && t < 12'd2 && !m_last) && low3 == (c == 0 && t < 12'd3 && !m_last)); end
            else assert (low == (c == 4'd1) && low1 == (c == 4'd1 ? t >= 12'd1 : c == 4'd2 && t < 12'd1)
                         && low2 == (c == 4'd1 ? t >= 12'd2 : c == 4'd2 && t < 12'd2)
                         && low3 == (c == 4'd1 ? t >= 12'd3 : c == 4'd2 && t < 12'd3));
            if (c == 4'd0) begin
                if (t < h) begin assert (x_mid && at == PC_CRCDEL && since == t && mine == snd && (!snd || val)); end
                else begin
                    assert (ahead == d - t);
                    if (t == h) begin assert (x_exec && at == PC_CRCBAD); end
                    else if (t == h + 12'd1) begin assert (x_exec && at == PC_ACK); end
                    else assert (x_edge && at == PC_ACK && mine == !snd && (snd || !val));
                end
            end else if (c == 4'd1) begin
                // On the tick a sender's edge moves to a fall it sees while it
                // waits, it is still waiting, with its edge now.
                if (t < h) begin assert ((x_mid && at == PC_ACK && since == t && mine == !snd && (snd || !val))
                                         || (snd && t == 0 && x_edge && at == PC_ACK && ahead == 0)); end
                else begin
                    assert (ahead == d - t);
                    if (t == h) begin assert (x_exec && at == PC_TAIL); end
                    else assert (x_edge && at == PC_TAIL && k == 0);
                end
            end else begin
                if (t < h) begin assert (x_mid && at == PC_TAIL && k == kc && since == t && mine == snd && (!snd || val)); end
                else begin
                    assert (ahead == d - t);
                    if (kc != 4'd10) begin assert (x_edge && at == PC_TAIL && k == kc + 4'd1); end
                    else if (t == h) begin assert (x_exec && at == PC_TJUMP); end
                    else if (t == h + 12'd1) begin assert (x_exec && at == PC_IDLE); end
                    else assert ((at == PC_IDLE && x_claim) || (x_exec && (at == PC_STUFF || at == PC_LOSE || at == PC_SOF))
                                 || (x_edge && at == PC_SOF));
                end
                // From its read of the ACK delimiter on, it has last seen BUS
                // recessive, so it sees the next start of frame as a change.
                if (c > 4'd2 || t >= h) assert (armed0);
            end
        end
    end
endmodule
