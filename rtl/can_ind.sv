// Unbounded proof by k-induction of a fifth complete protocol: the CAN program
// from protocols.py, word for word as the assembler emits it, on three real
// harts. Two start as possible senders (role S). Hart a has a queue of
// frames to send; hart b's queue stays empty, so it always ends up the
// receiver (role R). Hart c is a witness, which drives nothing and logs. Or
// no receiver is there, and hart b is a second witness.
//
// It covers what the other proofs never reach: a claim that decides the role
// by whether the hart has something to send, bit stuffing, a CRC computed as
// the bits go and checked by the receiver, a loop whose count comes from a
// received field, resynchronisation on falling edges, an ACK slot the
// receiver drives inside the sender's frame, and a hold trap that brings
// both back to `idle` after 20 recessive bits.
//
// Free, so the result holds for every choice:
//   BIT         the bit time, any value from MINBIT to 2047 ticks
//   start       the address the program is loaded at, 0 to 29
//   valid, data, ctl  hart a's queue: any entries, arriving, changing or
//                     leaving at any time (hart a reads it only to claim and
//                     on the tick it takes a byte)
//   norx        whether a receiver is there
//   valid_c, data_c, ctl_c  what the witness finds in its queue, on every tick
//   unwritten   what the other 29 program words hold
//
// Assumed:
//   - the harts leave reset on the same tick, with the program's hold trap
//     set, no prescaler and no adversary fault;
//   - hart b's queue is empty;
//   - the host queues base data frames: when hart a takes its control field,
//     the entry is there and its RTR and IDE bits are clear;
//   - BUS is open drain with a pull-up: low exactly when a hart drives it low.
//
// tb_can_ind.v simulates this same module with CAN_SIM defined: the free
// signals become inputs driven at random, and every assertion is checked once
// a tick.
`ifdef CAN_SIM
module can_ind (input clk, input [10:0] BIT, input [5:0] start, input [31:0] unwritten,
                input [7:0] addr_a, addr_b, input [2:0] other,
                input valid_a, input [7:0] data_a, input [1:0] ctl_a,
                input [7:0] addr_c, input valid_c, input [7:0] data_c, input [1:0] ctl_c, input norx);
    parameter MINBIT = 11;

    `include "can_rom.vh"
`else
module can_ind (input clk);
    parameter MINBIT = 11;

    `include "can_rom.vh"

    (* anyconst *) wire [10:0] BIT;
    (* anyconst *) wire [5:0]  start;
    (* anyconst *) wire [31:0] unwritten;
    (* anyconst *) wire [7:0]  addr_a, addr_b;
    (* anyseq *)   wire [2:0]  other;
    (* anyseq *)   wire        valid_a;
    (* anyseq *)   wire [7:0]  data_a;
    (* anyseq *)   wire [1:0]  ctl_a;
    (* anyconst *) wire [7:0]  addr_c;
    (* anyconst *) wire        norx;
    (* anyseq *)   wire        valid_c;
    (* anyseq *)   wire [7:0]  data_c;
    (* anyseq *)   wire [1:0]  ctl_c;
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
    wire [7:0]  oe_c, ov_c, count_c, rx_c, pin_c, s1_c, armed_c, tx_c, viol_c, vout_c, pdata_c;
    wire [87:0] code_c;
    wire [111:0] cfg_c;
    wire [47:0] cset_c;
    wire [31:0] held_c;
    wire [5:0]  pc_c;
    wire [3:0]  s_c, k_c, keep_c, prev_c;
    wire [4:0]  partial_c, width_c;
    wire [11:0] now_c, edge_c, lf_c;
    wire [1:0]  role_c, src_c;
    wire        last_c, mine_c, val_c, insd_c, sbit_c, pop_c, clear_c, push_c, seen_c, seen2_c, lost_c;

    // BUS is open drain with a pull-up: low exactly when a hart drives it low.
    // (The witness never drives, a claim below.)
    wire        low = (oe_a[0] && !ov_a[0]) || (oe_b[0] && !ov_b[0]);
    wire [7:0]  bus = {4'hF, other, !low};

    wire [5:0]  at_a = pc_a - start, at_b = pc_b - start, at_c = pc_c - start;
    wire [31:0] ins_a = can_word(at_a, BIT, start, unwritten);
    wire [31:0] ins_b = can_word(at_b, BIT, start, unwritten);
    wire [31:0] ins_c = can_word(at_c, BIT, start, unwritten);

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
        .od_mask(8'h01), .base_role(norx ? 2'd3 : 2'd0), .reset_pc(start), .addr_reg(addr_b), .pc(pc_b),
        .pc_sel(), .ins(ins_b), .tx_valid(1'b0), .tx_ctl(2'd0), .tx_data(8'd0),
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

    janus_hart c (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_c), .ov(ov_c),
        .od_mask(8'h01), .base_role(2'd3), .reset_pc(start), .addr_reg(addr_c), .pc(pc_c),
        .pc_sel(), .ins(ins_c), .tx_valid(valid_c), .tx_ctl(ctl_c), .tx_data(data_c),
        .tx_pop(pop_c), .tx_clear(clear_c), .rx_push(push_c), .seen_push(seen_c),
        .seen_push2(seen2_c), .push_data(pdata_c), .push_data2(), .violations(vout_c),
        .arb_lost(lost_c), .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .dbg_s(s_c), .dbg_count(count_c), .dbg_rx(rx_c), .dbg_last(last_c),
        .dbg_now(now_c), .dbg_edge(edge_c), .dbg_dwell(), .dbg_k(k_c),
        .dbg_partial(partial_c), .dbg_role(role_c), .dbg_src(src_c), .dbg_mine(mine_c),
        .dbg_val(val_c), .dbg_pin(pin_c), .dbg_s1(s1_c), .dbg_armed(armed_c),
        .dbg_code(code_c), .dbg_inserted(insd_c), .dbg_stuff_bit(sbit_c), .dbg_width(width_c),
        .dbg_viol(viol_c), .dbg_tx(tx_c), .dbg_cfg(cfg_c), .dbg_cset(cset_c),
        .dbg_cnt(), .dbg_rx1(), .dbg_prev(prev_c), .dbg_held(held_c), .dbg_keep(keep_c), .dbg_last_fall(lf_c),
        .dbg_clean());

    wire       tk_b = norx ? seen_b : push_b;        // hart b takes a field, storing or logging it
    wire [1:0] rl_b = norx ? 2'd3 : 2'd1;             // its role in a frame

    localparam S_BOOT = 4'd0, S_EXEC = 4'd1, S_CLAIM = 4'd2, S_SYNC = 4'd3, S_EDGE = 4'd4,
               S_MID = 4'd5, S_SETTLE = 4'd6, S_POST = 4'd7;

    wire [11:0] d = {1'b0, BIT};
    wire [11:0] h = {2'b00, BIT[10:1]};          // where a bit is sampled

    // The bytes hart a took for the frame in hand: the three header fields and
    // the data byte in flight.
    reg [7:0]  f1 = 0, f2 = 0, f3 = 0, fd = 0, fd0 = 0;   // fd0: the data byte before fd
    wire       a_load = !rst && s_a == S_EXEC && role_a == 2'd0
                        && (at_a == PC_LOAD1 || at_a == PC_LOAD2 || at_a == PC_LOAD3
                            || at_a == PC_DLOAD);
    wire [7:0] took = valid_a ? data_a : 8'hFF;

    always @(posedge clk) begin
        if (rst) begin
            f1 <= 0;
            f2 <= 0;
            f3 <= 0;
            fd <= 0;
        end else if (a_load) begin
            if (at_a == PC_LOAD1) f1 <= took;
            if (at_a == PC_LOAD2) f2 <= took;
            if (at_a == PC_LOAD3) f3 <= took;
            if (at_a == PC_DLOAD) begin
                fd <= took;
                fd0 <= fd;
            end
        end
    end

    // What each hart's next store must hold: the field's bits, which sit at
    // the bottom of the byte, and which bits those are.
    reg [7:0]  xv_a = 0, xm_a = 0, xv_b = 0, xm_b = 0, xv_c = 0, xm_c = 0;
    reg        st_a = 0, st_b = 0, st_c = 0;
    function automatic [15:0] field_of(input [5:0] at, input [7:0] g1, g2, g3, gd);
        case (at)
            PC_STORE1: field_of = {{5'd0, g1[7:5]}, 8'h07};
            PC_STORE2: field_of = {g2, 8'hFF};
            PC_STORE3: field_of = {{1'b0, g3[7:1]}, 8'h7F};
            default:   field_of = {gd, 8'hFF};
        endcase
    endfunction
    wire       a_store = !rst && s_a == S_EXEC && (at_a == PC_STORE1 || at_a == PC_STORE2
                                                    || at_a == PC_STORE3 || at_a == PC_DSTORE);
    wire       b_store = !rst && s_b == S_EXEC && (at_b == PC_STORE1 || at_b == PC_STORE2
                                                    || at_b == PC_STORE3 || at_b == PC_DSTORE);
    wire       c_store = !rst && s_c == S_EXEC && (at_c == PC_STORE1 || at_c == PC_STORE2
                                                    || at_c == PC_STORE3 || at_c == PC_DSTORE);
    always @(posedge clk) begin
        st_c <= c_store;
        if (c_store) {xv_c, xm_c} <= field_of(at_c, f1, f2, f3, fd);
        st_a <= a_store;
        st_b <= b_store;
        if (a_store) {xv_a, xm_a} <= field_of(at_a, f1, f2, f3, fd);
        if (b_store) {xv_b, xm_b} <= field_of(at_b, f1, f2, f3, fd);
    end

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
    reg [7:0]  m_nack = 0;       // frames whose ACK slot was recessive, saturating
    reg [2:0]  g_dom = 0;        // dominant bits in the last run of them
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
            if (m_sample && m_st == M_TAIL && m_tail == 4'd1 && m_bus && m_nack != 8'hFF) m_nack <= m_nack + 1'b1;
            if (m_end) begin
                if (m_st == M_STUFFED) begin
                    if (!m_b) g_dom <= m_run_next;
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

    // ---- Where the harts stand, from the monitor ----

    wire        stuffed = m_st == M_STUFFED;
    wire        a_exec = s_a == S_EXEC, a_claim = s_a == S_CLAIM, a_edge = s_a == S_EDGE;
    wire        a_mid = s_a == S_MID;
    wire        b_exec = s_b == S_EXEC, b_claim = s_b == S_CLAIM, b_edge = s_b == S_EDGE;
    wire        b_mid = s_b == S_MID, b_sync = s_b == S_SYNC;
    wire        c_exec = s_c == S_EXEC, c_claim = s_c == S_CLAIM, c_edge = s_c == S_EDGE;
    wire        c_mid = s_c == S_MID, c_sync = s_c == S_SYNC;
    // Whether a hart of role r owns a bit of party p, as the hart decides it.
    function automatic mine_of(input [1:0] p, input [1:0] r);
        mine_of = p == 2'd2 ? r != 2'd3 : r == p;
    endfunction
    wire [11:0] r = d - h;                       // from a bit's middle to its end
    wire [11:0] tq = {1'b0, m_t};
    wire [11:0] since_a = now_a - edge_a, ahead_a = edge_a - now_a;
    wire [11:0] since_b = now_b - edge_b, ahead_b = edge_b - now_b;
    wire [11:0] since_c = now_c - edge_c, ahead_c = edge_c - now_c;
    wire        low_a = oe_a[0] && !ov_a[0], low_b = oe_b[0] && !ov_b[0];

    // The frame as hart a has it: the monitor's, with this bit taken in once
    // hart a has read it, in the bit's middle.
    wire        a_pre = m_t < h[10:0];
    wire [7:0]  v_i = (m_read && !m_stuff) ? m_i + 1'b1 : m_i;
    wire [2:0]  v_run = m_read ? m_run_next : m_run;
    wire        v_last = m_read ? m_b : m_last;
    wire [14:0] v_crc = (m_read && !m_stuff && m_i < m_crc_at) ? m_crc_next : m_crc;
    wire [7:0]  v_sh = (m_read && !m_stuff && m_i != 0) ? {m_sh[6:0], m_b} : m_sh;
    wire [3:0]  v_n = (m_read && !m_stuff && m_i == 8'd18) ? (m_fb[3:0] > 4'd8 ? 4'd8 : m_fb[3:0])
                                                           : m_n;
    wire [7:0]  v_crc_at = 8'd19 + {v_n, 3'd0};

    // Where frame bit i is sent: its instruction and its index there.
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
    // Frame bit i ends its field.
    function automatic fend(input [7:0] i, input [7:0] crc_at);
        fend = i == 0 || i == 8'd3 || i == 8'd11 || i == 8'd18
               || (i > 8'd18 && i < crc_at && i[2:0] == 3'd2) || i == crc_at + 8'd14;
    endfunction
    // After the field that frame bit j ends: the instructions run one a tick,
    // the last of them the next bit instruction, which then waits for its
    // edge. Gives that instruction p ticks after the bit was read, and
    // whether it is waiting.
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
    // The value of frame bit i, from what hart a took and the CRC.
    function automatic fbit(input [7:0] i, input [7:0] crc_at, input [7:0] g1, g2, g3, gd,
                            input [14:0] crc);
        reg [7:0] x;
        begin
            if (i == 0) fbit = 1'b0;
            else if (i <= 8'd3) begin x = 8'd8 - i; fbit = g1[x[2:0]]; end
            else if (i <= 8'd11) begin x = 8'd11 - i; fbit = g2[x[2:0]]; end
            else if (i <= 8'd18) begin x = 8'd19 - i; fbit = g3[x[2:0]]; end
            else if (i < crc_at) begin x = 8'd2 - i; fbit = gd[x[2:0]]; end
            else begin x = crc_at + 8'd14 - i; fbit = crc[x[3:0]]; end
        end
    endfunction

    wire        next_stuff = v_run == 3'd5;            // a stuff bit comes next
    // This bit, in the stuffed part: a stuff bit, or frame bit m_i. Three
    // ticks after hart a reads the last bit of a data byte it has loaded the
    // next, while that bit is still on BUS.
    wire        next_byte = !a_pre && !m_stuff && !next_stuff && v_i > 8'd19 && v_i < v_crc_at
                            && v_i[2:0] == 3'd3 && tq - h >= 12'd3;
    wire        cur_bit = m_stuff ? !m_last
                          : fbit(m_i, m_crc_at, f1, f2, f3, next_byte ? fd0 : fd, m_crc);
    wire [9:0]  pl_cur = place(m_stuff ? m_i - 8'd1 : m_i, m_crc_at);
    // The monitor's field register once frame bits 0 to i-1 are in: the bits
    // read so far of the field that bit i-1 is in, the last of them at the
    // bottom, and how many there are.
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
    // Once a data byte is all in and another follows, hart a loads the next
    // three ticks after reading the bit after it, and fd0 then holds it.
    wire        mf_old = next_byte || (m_i > 8'd19 && m_i < m_crc_at && m_i[2:0] == 3'd3
                                       && (!m_stuff || (!a_pre && tq - h >= 12'd3)));
    wire [18:0] mf_x = mf_of(m_i, m_crc_at, f1, f2, f3, mf_old ? fd0 : fd, m_crc);
    wire [7:0]  mf_mask = mf_x[18:15] >= 4'd8 ? 8'hFF : ~(8'hFF << mf_x[18:15]);
    // The next bit hart a sends, once it has read this one: a stuff bit, the
    // next frame bit, or after the CRC its delimiter.
    wire        nx_bit = next_stuff ? !v_last : v_i == v_crc_at + 8'd15 ? 1'b1
                         : fbit(v_i, v_crc_at, f1, f2, f3, fd, v_crc);
    // Once read: the frame bit just read, j, and what comes next.
    wire [7:0]  v_j = v_i - 8'd1;
    wire [9:0]  pl_j = place(v_j, v_crc_at);
    wire        j_end = fend(v_j, v_crc_at);
    wire [6:0]  aft = after(v_j, v_n, v_crc_at, tq - h);
    wire [7:0]  v_dd = v_i > 8'd19 ? (v_i - 8'd19) >> 3 : 8'd0;     // data bytes read
    // Hart a's CRC register: the CRC so far, and in the CRC field, shifted
    // left once for each CRC bit sent.
    wire [7:0]  v_past = v_i > v_crc_at ? v_i - v_crc_at : 8'd0;
    wire [14:0] x_crc_a = v_crc << v_past;

    // Hart a two ticks ago, for hart b.
    reg [5:0]  h1_at = 0, h2_at = 0;
    reg [3:0]  h1_s = 0, h2_s = 0, h1_k = 0, h2_k = 0;
    reg [23:0] h1_code = 0, h2_code = 0;
    reg [7:0]  h1_rx = 0, h2_rx = 0, h1_cnt = 0, h2_cnt = 0;
    reg [11:0] h1_edge = 0, h2_edge = 0;
    reg [1:0]  h1_src = 0, h2_src = 0;
    reg        h1_p = 0, h2_p = 0;
    always @(posedge clk) begin
        {h2_at, h2_s, h2_k, h2_code, h2_rx, h2_cnt, h2_edge, h2_src, h2_p}
            <= {h1_at, h1_s, h1_k, h1_code, h1_rx, h1_cnt, h1_edge, h1_src, h1_p};
        {h1_at, h1_s, h1_k, h1_code, h1_rx, h1_cnt, h1_edge, h1_src, h1_p}
            <= {at_a, s_a, k_a, code_a[23:0], rx_a, count_a, edge_a, src_a, partial_a[0]};
    end
    // Hart b is hart a two ticks late, from the middle of its start of frame
    // until the ACK slot.
    wire        b_hist = (at_b == PC_SOF && b_mid) || (at_b > PC_SOF && at_b < PC_ACK)
                         || (at_b == PC_ACK && b_exec);
    // So is the witness, hart c.
    wire        c_hist = (at_c == PC_SOF && c_mid) || (at_c > PC_SOF && at_c < PC_ACK)
                         || (at_c == PC_ACK && c_exec);

    // ---- The tail, idle, the hold counter and the last fall ----

    // BUS in the tail, at tick t of cell c: the ACK slot is dominant, and the
    // receiver's ACK starts and ends two ticks into its cells.
    function automatic tb_at(input [3:0] c, input [11:0] t);
        tb_at = norx ? 1'b1 : c == 4'd1 ? t < 12'd2 : c == 4'd2 ? t >= 12'd2 : 1'b1;
    endfunction
    // BUS two and three ticks ago in the tail. A bit is at least 11 ticks, so
    // a tick in the cell before is past its own change.
    wire        t_hist2 = tq >= 12'd2 ? tb_at(m_tail, tq - 12'd2)
                          : m_tail == 0 ? m_last : tb_at(m_tail - 4'd1, 12'd8);
    wire        t_hist3 = tq >= 12'd3 ? tb_at(m_tail, tq - 12'd3)
                          : m_tail == 0 ? m_last : tb_at(m_tail - 4'd1, 12'd8);

    wire        tail = m_st == M_TAIL, idle = m_st == M_IDLE;
    wire        sh4 = BIT >= 11'd16 && !norx;       // the ACK pulls hart a 4 ticks later
    wire [11:0] sh = sh4 ? 12'd4 : 12'd0;
    wire [11:0] cs = now_a - tq;                     // when this bit started
    // Hart a in the tail: up to the ACK slot it keeps the monitor's time;
    // from the ACK delimiter on, sh ticks later.
    wire        a_late = tail && m_tail >= 4'd2 && tq < sh;
    wire [11:0] a_t = (tail && m_tail >= 4'd2) ? (a_late ? tq + d - sh : tq - sh) : tq;
    wire [3:0]  a_k = (a_late ? m_tail - 4'd1 : m_tail) - 4'd2;      // its TAIL bit
    // Hart b in the tail: from the ACK slot on, 2 ticks later.
    wire        b_late = tail && m_tail >= 4'd1 && tq < 12'd2;
    wire [3:0]  b_cell = b_late ? m_tail - 4'd1 : m_tail;
    wire [11:0] b_t = b_late ? tq + d - 12'd2 : tq - 12'd2;
    wire [3:0]  b_k = b_cell - 4'd2;
    // Hart c in the tail: it takes the ACK's fall, two ticks into its slot
    // as the receiver sends it and two more as hart c sees it, as the slot's
    // edge, and is 4 ticks later from then on. With no ACK it stays 2.
    wire [11:0] co = norx ? 12'd2 : 12'd4;
    wire        c_late = tail && m_tail >= 4'd2 && tq < co;
    wire [3:0]  c_cell = c_late ? m_tail - 4'd1 : m_tail;
    wire [11:0] c_t = c_late ? tq + d - co : tq - co;
    wire [3:0]  c_k = c_cell - 4'd2;

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
    // Whether each hart pulled BUS low a tick ago, which its hold counter sees.
    reg         low_a1 = 0, low_b1 = 0;
    always @(posedge clk) {low_a1, low_b1} <= {low_a, low_b};
    // BUS's recessive run as the harts see it, two ticks late, saturating.
    wire [15:0] held_seen = g_fell ? rq2 : idle ? rq1 : tq == 12'd1 ? rq2_up : 16'd0;
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
    // Recessive ticks in a row before this bit, from the bits before it.
    wire [15:0] rec_before = m_last ? {13'd0, m_run} * {4'd0, d} : 16'd0;
    // The recessive run in idle after a frame, unsaturated.
    wire [17:0] it_run = norx ? {2'd0, m_it} + 18'd13 * {6'd0, d} + {2'd0, rec_before} + 18'd1
                         : {2'd0, m_it} + 18'd11 * {6'd0, d} - 18'd1;
    // Bits from the last fall of BUS to this bit.
    wire [3:0]  lfb = m_last ? {1'b0, m_run} + {1'b0, g_dom} : {1'b0, m_run};
    // How long ago the harts saw the last fall they still count.
    wire [15:0] lf_age = {4'd0, now_a - lf_a};
    // The fall the harts have seen last: BUS's last fall, once two ticks old.
    wire [11:0] seen_fall = (now_a - g_fall >= 12'd2) ? g_fall + 12'd2 : g_fall0 + 12'd2;

`ifdef CAN_SIM
    always @(negedge clk) begin                  // once a tick, with everything settled
`else
    always @* begin
`endif
        assume (BIT >= MINBIT);
        assume (start <= MAX_START);
        // The host queues base data frames: RTR and IDE clear.
        if (a_load && at_a == PC_LOAD3) assume (valid_a && data_a[7:6] == 2'b00);

        assert (step <= 2'd3);
        if (!rst) begin
            // CLEAN
            // Every hart counts each frame nobody acknowledged, as it reads the
            // ACK slot, and nothing else; with a receiver there are none.
            if (!norx) assert (m_nack == 0);
            if (tail && m_tail == 4'd1 && norx && tq == h) begin
                assert ((viol_a == m_nack + 8'd1 || (viol_a == 8'hFF && m_nack == 8'hFF)) && viol_b == m_nack && viol_c == m_nack);
            end else if (tail && m_tail == 4'd1 && norx && tq == h + 12'd1) begin
                assert (viol_a == m_nack && viol_b == viol_c && (viol_b + 8'd1 == m_nack || (viol_b == 8'hFF && m_nack == 8'hFF)));
            end else assert (viol_a == m_nack && viol_b == m_nack && viol_c == m_nack);
            assert (vout_a == viol_a || vout_a + 8'd1 == viol_a);
            assert (vout_b == viol_b || vout_b + 8'd1 == viol_b);
            assert (vout_c == viol_c || vout_c + 8'd1 == viol_c);
            assert (!lost_a && !lost_b && !clear_a && !clear_b);
            assert (!seen_a && (norx ? !push_b && oe_b == 0 : !seen_b) && !seen2_a && !seen2_b && !pop_b);
            assert (keep_a == 0 && keep_b == 0);
            assert (oe_a[7:1] == 0 && oe_b[7:1] == 0);

            // WITNESS: it drives nothing, takes nothing from its queue, and logs
            // each field as hart a sent it, on the tick the receiver stores it.
            assert (oe_c == 0 && role_c == 2'd3);
            assert (!lost_c && !clear_c && !pop_c && !push_c && !seen2_c && keep_c == 0);
            assert (seen_c == st_c && seen_c == tk_b);
            if (seen_c) assert ((pdata_c & xm_c) == (xv_c & xm_c));

            // WIRE: what the monitor is about to read.
            if (m_sample && m_stuff) assert (m_bus != m_last);           // no stuff error
            if (m_sample && m_st == M_STUFFED && !m_stuff) begin
                if (m_i == 8'd0) assert (!m_bus);                          // start of frame
                if (m_i == 8'd3) assert (m_fb[2:0] == f1[7:5]);            // identifier, top
                if (m_i == 8'd11) assert (m_fb[7:0] == f2);                // identifier, rest
                if (m_i == 8'd12 || m_i == 8'd13) assert (!m_bus);         // RTR, IDE: a base data frame
                if (m_i == 8'd18) assert (m_fb[6:0] == f3[7:1]);           // RTR, IDE, r0, length
                if (m_i > 8'd18 && m_i < m_crc_at && (m_i - 8'd18) % 8 == 0)
                    assert (m_fb[7:0] == fd);                              // a data byte
                if (m_i == m_crc_at + 8'd14) assert (m_fb == m_crc);       // the CRC
            end
            if (m_sample && m_st == M_TAIL)
                assert (m_bus == (m_tail != 4'd1 || norx));                // ACK slot dominant
            // Every bit lasts exactly BIT ticks: BUS changes only where a bit
            // starts, except for the receiver's ACK, which starts and ends two
            // ticks late, as the receiver sees the bus two ticks late.
            if (m_st != M_IDLE && m_bus != m_prev)
                assert (m_t == 0 || (m_st == M_TAIL && (m_tail == 4'd1 || m_tail == 4'd2) && m_t == 11'd2));

            // ---- The monitor's own state ----
            assert (m_st != 2'd3);
            if (idle) begin assert (m_prev && m_p2 && m_p3 && m_t == 0); end
            else assert (m_t < BIT);
            // A frame has gone by from the second tick of the first start of
            // frame on, and the idle count starts again with each frame.
            if (!idle && !(stuffed && m_i == 0 && tq == 12'd1)) assert (m_fr && m_it == 0);
            if (stuffed) begin
                assert (m_run <= 3'd5 && (m_i == 0) == (m_run == 0));
                if (m_i == 0) assert (m_last && tq >= 12'd1 && m_crc == 0);
                assert (m_i < m_crc_at + 8'd15 || (m_i == m_crc_at + 8'd15 && m_stuff));
                if (m_i > 8'd18) assert (m_dlc == f3[4:1]);
                // The control byte, once hart a has loaded it two ticks after
                // reading bit 11, or after the stuff bit that follows it: RTR and
                // IDE clear, as the host queued it.
                if (m_i > 8'd12 || (m_i == 8'd12 && (!m_stuff || (!a_pre && tq - h >= 12'd2)))
                        || (m_i == 8'd11 && !m_stuff && !a_pre && !next_stuff && tq - h >= 12'd2))
                    assert (f3[7:6] == 2'b00);
                if (m_t == 0) assert (m_prev == m_last);
                // BUS two and three ticks ago: the bit before until the change
                // has passed through.
                assert (m_p2 == (tq <= 12'd1 ? m_last : m_bus) && m_p3 == (tq <= 12'd2 ? m_last : m_bus));
                if (m_t > h[10:0]) assert (m_cur == m_bus);
                // The field in hand, as read so far, and the last bits read.
                assert (m_f == mf_x[14:0] && ((m_sh ^ m_f[7:0]) & mf_mask) == 8'd0);
            end
            if (tail) begin
                assert (m_tail <= 4'd12);
                if (m_t > h[10:0]) assert (m_cur == m_bus);
                if (m_t == 0) assert (m_prev == (m_tail == 0 ? m_last : norx || m_tail != 4'd2));
                assert (m_bus == tb_at(m_tail, tq) && m_p2 == t_hist2 && m_p3 == t_hist3);
            end

            // ---- Each hart's input stages: BUS one, two and three ticks ago ----
            // On the tick after reset (state BOOT) the oldest stage still holds
            // its power-on 0; the hart moves the next one in before reading it.
            assert (s1_a[0] == m_prev && pin_a[0] == m_p2 && prev_a == prev_b
                    && prev_a[0] == (s_a == S_BOOT ? 1'b0 : m_p3));
            if (s_a == S_BOOT || s_b == S_BOOT)
                assert (s_a == s_b && at_a == 0 && at_b == 0 && now_a == 0 && held_a == 0
                        && !cset_a[13] && idle && !m_fr && m_it == 0 && !g_fell);
            assert (prev_c == prev_a && pin_c == pin_a && s1_c == s1_a && now_c == now_a);
            if (s_c == S_BOOT || s_a == S_BOOT) assert (s_c == s_a && at_c == 0 && held_c == 0 && !cset_c[13]);

            // ---- Hart a's shift register: the field's byte, shifted once as
            // each of its bits starts ----
            if (at_a == PC_ID1 || at_a == PC_ID2 || at_a == PC_CTRL || at_a == PC_DATA)
                assert (tx_a == ((at_a == PC_ID1 ? f1 : at_a == PC_ID2 ? f2 : at_a == PC_CTRL ? f3 : fd)
                                 << (a_exec ? 4'd0 : k_a + 4'd1)));

            // ---- A bit in progress: its owner and source are its
            // instruction's, or a stuff bit's ----
            // A hart is inside an instruction past its first bit, the flag a
            // trap checks, exactly while it is on a later bit.
            assert (partial_a[0] == ((a_edge || a_mid) && k_a != 0)
                    && partial_b[0] == ((b_sync || b_edge || b_mid) && k_b != 0));
            assert (partial_c[0] == ((c_sync || c_edge || c_mid) && k_c != 0));
            if (c_sync || c_edge || c_mid) assert (!mine_c && k_c <= ins_c[20:17]
                                         && src_c == (code_c[1] ? {1'b1, code_c[0]} : ins_c[22:21]));
            // Its index never passes the instruction's last bit.
            if (a_edge || a_mid) assert (mine_a == mine_of(ins_a[24:23], role_a) && k_a <= ins_a[20:17]
                                         && src_a == (code_a[1] ? {1'b1, code_a[0]} : ins_a[22:21]));
            if (b_sync || b_edge || b_mid) assert (mine_b == mine_of(ins_b[24:23], role_b) && k_b <= ins_b[20:17]
                                         && src_b == (code_b[1] ? {1'b1, code_b[0]} : ins_b[22:21]));

            // ---- What each hart holds while it waits for a bit's edge ----
            if (stuffed && !a_pre && a_edge)
                assert (mine_a && val_a == nx_bit
                        && src_a == (next_stuff ? {1'b1, !v_last} : ins_a[22:21]));
            if (a_edge && (at_a == PC_CRCDEL || at_a == PC_TAIL))
                assert (mine_a && val_a && src_a == ins_a[22:21]);
            if (a_edge && at_a == PC_SOF) assert (mine_a && !val_a && src_a == ins_a[22:21]);
            if (a_edge && at_a == PC_ACK) assert (!mine_a);
            if (b_edge && at_b == PC_ACK && !b_hist) assert (mine_b == !norx && (norx || !val_b) && src_b == ins_b[22:21]);
            if (b_edge && at_b == PC_TAIL) assert (!mine_b);
            // From hart b's read of the ACK delimiter on, it has last seen BUS
            // recessive, so it sees the next start of frame as a change.
            if (tail && !b_hist && (b_cell > 4'd2 || (b_cell == 4'd2 && b_t >= h))) assert (armed_b[0]);

            if (tail && !c_hist && (c_cell > 4'd2 || (c_cell == 4'd2 && c_t >= h))) assert (armed_c[0]);

            // ---- Hart a in the stuffed part of a frame ----
            if (stuffed) begin
                // BUS carries this bit for all of it.
                assert (m_bus == cur_bit && low_a == !cur_bit && !low_b);
                assert (role_a == 2'd0 && code_a[23] == 1'b0);
                assert (code_a[22:8] == x_crc_a);
                assert (code_a[7:4] == {1'b0, v_run} && code_a[3] == (v_i != 0)
                        && code_a[2] == (v_i != 0 && v_last));
                assert (rx_a == v_sh);
                if (a_pre) begin
                    // Sending this bit.
                    assert (a_mid && since_a == tq && at_a == pl_cur[9:4] && k_a == pl_cur[3:0]);
                    assert (code_a[1] == m_stuff && code_a[0] == (m_stuff && !m_last));
                    assert (mine_a && val_a == cur_bit
                            && src_a == (m_stuff ? {1'b1, !m_last} : ins_a[22:21]));
                end else begin
                    assert (ahead_a == d - tq);
                    assert (code_a[1] == next_stuff && code_a[0] == (next_stuff && !v_last));
                    if (next_stuff || !j_end) begin
                        // Waiting to send a stuff bit, or the field's next bit.
                        assert (a_edge && at_a == pl_j[9:4]
                                && k_a == pl_j[3:0] + (next_stuff ? 4'd0 : 4'd1));
                    end else begin
                        assert (at_a == aft[6:1] && (aft[0] ? (a_edge && k_a == 0) : a_exec));
                    end
                end
                // The count: data bytes still to send, the one in hand
                // included. A byte read is counted off at the loop, so from its
                // last bit (and its stuff bit) to the loop it still counts.
                if (at_a == PC_NODATA || at_a == PC_DLOAD || at_a == PC_DATA || at_a == PC_DSTORE
                        || at_a == PC_DLOOP)
                    begin assert (count_a == {4'd0, v_n} - v_dd
                                       + ((at_a == PC_DSTORE || at_a == PC_DLOOP
                                           || (at_a == PC_DATA && code_a[1] && k_a == 4'd7
                                               && v_i[2:0] == 3'd3)) ? 8'd1 : 8'd0)); end
                else assert (count_a == 0);
            end

            // ---- Hart b: hart a two ticks late ----
            assert (now_a == now_b && pin_a == pin_b && s1_a == s1_b);
            if (b_hist) begin
                assert (at_b == h2_at && s_b == h2_s && k_b == h2_k && code_b[23:0] == h2_code);
                assert (rx_b == h2_rx && count_b == h2_cnt && edge_b == h2_edge + 12'd2);
                assert (partial_b[0] == h2_p && role_b == rl_b);
                if (b_edge || b_mid) assert (!mine_b && src_b == h2_src);
            end
            if (c_hist) begin
                assert (at_c == h2_at && s_c == h2_s && k_c == h2_k && code_c[23:0] == h2_code);
                assert (rx_c == h2_rx && count_c == h2_cnt && edge_c == h2_edge + 12'd2);
                assert (partial_c[0] == h2_p);
                if (c_edge || c_mid) assert (src_c == h2_src);
            end

            // ---- Configuration, as each hart's mode words have set it ----
            assert (cfg_a == {16'd0, 16'd0, can_hold_ticks(BIT), 16'd0, can_hold(start), 32'd0});
            assert (cfg_b == cfg_a && cfg_c == cfg_a);
            assert (code_a[87:50] == {1'b0, 2'd0, 1'b0, 16'd0, 16'd0, 1'b0, 1'b0}
                    && code_b[87:50] == code_a[87:50] && code_c[87:50] == code_a[87:50]);
            // The CRC register's top bit: above the 15-bit width, so never set.
            assert (code_a[23] == 1'b0 && code_b[23] == 1'b0 && code_c[23] == 1'b0);
            // The hold trap can send hart a back to `idle` after `stuff` and
            // before its start of frame goes out; it then keeps that frame's
            // stuffing and arbitration settings until it claims again.
            assert (code_a[49:46] == ((at_a > PC_STUFF && at_a <= PC_UNSTUFF) ? 4'd5 : 4'd0)
                    || ((at_a == PC_IDLE || at_a == PC_STUFF) && code_a[49:46] == 4'd5));
            assert (code_b[49:46] == ((at_b > PC_STUFF && at_b <= PC_UNSTUFF) ? 4'd5 : 4'd0));
            assert (code_a[45:24] == {at_a > PC_POLY ? 16'h4599 : 16'h0, at_a > PC_WIDTH ? 5'd15 : 5'd0,
                                      at_a > PC_MSB});
            assert (code_c[49:46] == ((at_c > PC_STUFF && at_c <= PC_UNSTUFF) ? 4'd5 : 4'd0));
            assert (code_c[45:24] == {at_c > PC_POLY ? 16'h4599 : 16'h0, at_c > PC_WIDTH ? 5'd15 : 5'd0,
                                      at_c > PC_MSB});
            assert (cset_c[47:45] == {at_c > PC_RESYNC, 2'd0});
            if (at_c > PC_LOSE && at_c <= PC_NOLOSE) begin assert (cset_c[44:43] == 2'd1); end
            else assert (cset_c[44:43] == 2'd2 || cset_c[44:43] == 2'd3);
            assert (cset_c[42:37] == (at_c > PC_ONERR ? PC_BAD + start : 6'd0) && cset_c[36:14] == 0 && cset_c[12:0] == 0);
            assert (code_b[45:24] == {at_b > PC_POLY ? 16'h4599 : 16'h0, at_b > PC_WIDTH ? 5'd15 : 5'd0,
                                      at_b > PC_MSB});
            assert (cset_a[47:45] == {at_a > PC_RESYNC, 2'd0} && cset_b[47:45] == {at_b > PC_RESYNC, 2'd0});
            if (at_a > PC_LOSE && at_a <= PC_NOLOSE) begin assert (cset_a[44:43] == 2'd1); end
            else if (at_a == PC_IDLE || at_a == PC_STUFF || at_a == PC_LOSE) begin assert (cset_a[44:43] != 2'd0); end
            else assert (cset_a[44:43] == 2'd2 || cset_a[44:43] == 2'd3);
            if (at_b > PC_LOSE && at_b <= PC_NOLOSE) begin assert (cset_b[44:43] == 2'd1); end
            else assert (cset_b[44:43] == 2'd2 || cset_b[44:43] == 2'd3);
            assert (cset_a[42:37] == (at_a > PC_ONERR ? PC_BAD + start : 6'd0));
            assert (cset_b[42:37] == (at_b > PC_ONERR ? PC_BAD + start : 6'd0));
            assert (cset_a[36:14] == 0 && cset_a[12:0] == 0 && cset_b[36:14] == 0 && cset_b[12:0] == 0);
            assert (role_a == 2'd0 && (norx ? role_b == 2'd3 : role_b == 2'd0 || role_b == 2'd1));
            // Only the states of timed bits, between ticks: settling and
            // finishing a bit take no tick of their own here.
            assert (s_a <= S_MID && s_b <= S_MID && s_c <= S_MID);
            if (ins_c[31:28] != 4'd1) begin assert (s_c == S_BOOT || c_exec || (ins_c[31:28] == 4'd2 && c_claim)); end
            else assert (c_exec || c_sync || c_edge || c_mid);
            assert (at_c < PROG_LEN && at_c < PC_BADDEL);
            // Only bit instructions wait on the bus, and only `idle` claims;
            // the rest take a tick each.
            if (ins_a[31:28] != 4'd1) begin assert (s_a == S_BOOT || a_exec || (ins_a[31:28] == 4'd2 && a_claim)); end
            else assert (a_exec || a_edge || a_mid);
            if (ins_b[31:28] != 4'd1) begin assert (s_b == S_BOOT || b_exec || (ins_b[31:28] == 4'd2 && b_claim)); end
            else assert (b_exec || b_sync || b_edge || b_mid);
            assert (at_a < PROG_LEN && at_b < PROG_LEN && at_a < PC_BADDEL && at_b < PC_BADDEL);

            // ---- The hold counter and the last fall ----
            // Each hart counts BUS as it sees it, two ticks late, but starts
            // again at once when it pulls BUS low itself.
            assert (rq == rq1);
            assert (held_a == (low_a1 ? 32'd0 : {16'd0, held_seen})
                    && held_b == (low_b1 ? 32'd0 : {16'd0, held_seen}) && held_c == {16'd0, held_seen});
            if (!g_fell) assert ((idle && !m_fr) || (stuffed && m_i == 0 && !m_stuff
                                 && ((tq == 12'd1 && !m_fr) || (tq == 12'd2 && m_fr))));
            assert (lf_a == lf_b && lf_a == lf_c && cset_b[13] == cset_c[13]);
            // The sender can forget a fall a tick before the others: at a hold
            // trap that fires on them but not on it, as it pulls BUS low.
            assert (cset_a[13] == cset_b[13] || (cset_b[13] && norx && low_a1 && now_a - lf_a == 12'd1024
                                                 && held_b[15:0] == can_hold_ticks(BIT)));
            if (cset_b[13]) assert (lf_b == seen_fall && (now_b - lf_b < 12'd1024
                                    || (now_b - lf_b == 12'd1024 && held_b[15:0] == can_hold_ticks(BIT))));
            // A hart forgets a fall 1024 ticks on, but not on a tick its hold
            // trap fires.
            if (cset_a[13]) assert (lf_a == seen_fall && (now_a - lf_a < 12'd1024
                                    || (now_a - lf_a == 12'd1024 && held_a[15:0] == can_hold_ticks(BIT)
                                        && held_b[15:0] == can_hold_ticks(BIT))));
            // The last fall the harts have seen, while they still count it: in
            // a frame, this bit's start, two ticks on, or a bit time or more
            // before; after the ACK slot, the ACK's fall. So a listener never
            // moves its bit edge to a fall in the middle of a bit.
            // Ages are compared wide, as a bit can be longer than half the
            // range of the harts' 12-bit clock.
            if (cset_a[13] && stuffed)
                assert ((lf_a == cs + 12'd2 && tq >= 12'd2) || lf_age + 16'd2 >= {4'd0, tq} + {4'd0, d});
            // The age of the last fall, in whole bits: a dominant run and the
            // recessive bits after it.
            if (cset_a[13] && ((stuffed && m_i != 0) || (norx && (tail || (idle && m_fr)))))
                assert ({2'd0, lf_age} + 18'd2 == ((stuffed && m_last && !m_bus && tq >= 12'd2) ? 18'd0 : {14'd0, lfb} * {6'd0, d})
                        + (idle ? {2'd0, m_it} + 18'd13 * {6'd0, d} : {6'd0, tq} + (tail ? {14'd0, m_tail} * {6'd0, d} : 18'd0)));
            if (m_i != 0 || tail) assert (g_dom >= 3'd1 && g_dom <= 3'd5 && (m_last || g_dom == m_run));
            if (tail || (idle && m_fr)) assert (m_run >= 3'd1 && m_run <= 3'd4 && g_dom >= 3'd1 && g_dom <= 3'd5 && (m_last || g_dom == m_run));
            if (cset_a[13] && tail) begin
                if (norx) begin end
                else if (m_tail == 0 || (m_tail == 4'd1 && tq < 12'd4)) begin assert (lf_age + 16'd2 >= {4'd0, tq} + {4'd0, d}); end
                else assert (lf_age + 16'd4 == {4'd0, tq} + {12'd0, m_tail - 4'd1} * {4'd0, d});
            end
            if (stuffed && !(m_i == 0 && !m_stuff)) begin
                // BUS's recessive run, in exact bits.
                assert (rqv == (m_bus ? rec_before + tq + 16'd1 : 16'd0));
            end
            if (stuffed && m_i == 0 && !m_stuff) assert (rqv == 0 && g_fall == cs);
            if (tail) begin
                if (norx) begin assert (rqv == rec_before + {4'd0, m_tail} * {4'd0, d} + tq + 16'd1); end
                else if (m_tail == 0) begin assert (rqv == rec_before + tq + 16'd1); end
                else if (m_tail == 1) begin assert (rqv == (tq < 12'd2 ? rec_before + d + tq + 16'd1 : 16'd0)); end
                else if (m_tail == 2 && tq < 12'd2) begin assert (rqv == 0); end
                else assert (rqv == {4'd0, m_tail - 4'd2} * {4'd0, d} + tq - 16'd1);
            end

            // ---- The tail ----
            if (tail || idle) begin
                assert (!code_a[1] && !code_b[1] && rx_a == m_sh && rx_b == m_sh && count_a == 0 && count_b == 0);
                assert (!code_c[1] && rx_c == m_sh && count_c == 0);
            end
            if (tail) begin
                assert (!low_a && code_a[22:8] == 0 && code_b[22:8] == 0 && role_b == rl_b);
                // Hart a.
                if (m_tail == 4'd0) begin
                    if (a_pre) begin assert (a_mid && at_a == PC_CRCDEL && since_a == tq && mine_a && val_a); end
                    else begin
                        assert (ahead_a == d - tq);
                        if (tq == h) begin assert (a_exec && at_a == PC_CRCBAD); end
                        else if (tq == h + 12'd1) begin assert (a_exec && at_a == PC_ACK); end
                        else assert (a_edge && at_a == PC_ACK && !mine_a);
                    end
                end else if (m_tail == 4'd1) begin
                    // The ACK slot: hart a only listens. From BIT 16 up it
                    // takes the ACK's fall, seen 4 ticks in, as the bit's edge.
                    if (tq < h + sh)
                        begin assert (a_mid && at_a == PC_ACK && !mine_a
                                && since_a == ((sh4 && tq >= 12'd4) ? tq - 12'd4 : tq)); end
                    else begin
                        assert (ahead_a == d + sh - tq);
                        if (tq == h + sh) begin assert (a_exec && at_a == PC_TAIL); end
                        else assert (a_edge && at_a == PC_TAIL && k_a == 0);
                    end
                end else if (a_late) begin
                    assert (a_edge && at_a == PC_TAIL && k_a == a_k + 4'd1 && ahead_a == sh - tq);
                end else begin
                    if (a_t < h) begin assert (a_mid && at_a == PC_TAIL && k_a == a_k && since_a == a_t
                                         && mine_a && val_a); end
                    else begin
                        assert (ahead_a == d - a_t);
                        if (a_k != 4'd10) begin assert (a_edge && at_a == PC_TAIL && k_a == a_k + 4'd1); end
                        else if (a_t == h) begin assert (a_exec && at_a == PC_TJUMP); end
                        else if (a_t == h + 12'd1) begin assert (a_exec && at_a == PC_IDLE); end
                        else assert ((at_a == PC_IDLE && a_claim) || (a_exec && (at_a == PC_STUFF
                                     || at_a == PC_LOSE || at_a == PC_SOF)) || (a_edge && at_a == PC_SOF));
                    end
                end
                // Hart b.
                if (!b_hist) begin
                    if (m_tail == 4'd0 || (m_tail == 4'd1 && tq < 12'd2)) begin
                        assert (b_edge && at_b == PC_ACK && mine_b == !norx && !low_b
                                && ahead_b == (m_tail == 4'd0 ? d + 12'd2 - tq : 12'd2 - tq));
                    end else if (b_cell == 4'd1) begin
                        // Hart b's ACK: dominant from its edge to its next bit.
                        assert (low_b == !norx);
                        if (b_t < h) begin assert (b_mid && at_b == PC_ACK && since_b == b_t && mine_b == !norx && (norx || !val_b)); end
                        else begin
                            assert (ahead_b == d - b_t);
                            if (b_t == h) begin assert (b_exec && at_b == PC_TAIL); end
                            else assert (b_edge && at_b == PC_TAIL && k_b == 0);
                        end
                    end else begin
                        assert (!low_b);
                        if (b_t < h) begin assert (b_mid && at_b == PC_TAIL && k_b == b_k && since_b == b_t && !mine_b); end
                        else begin
                            assert (ahead_b == d - b_t);
                            if (b_k != 4'd10) begin assert (b_edge && at_b == PC_TAIL && k_b == b_k + 4'd1); end
                            else if (b_t == h) begin assert (b_exec && at_b == PC_TJUMP); end
                            else if (b_t == h + 12'd1) begin assert (b_exec && at_b == PC_IDLE); end
                            else assert (at_b == PC_IDLE && b_claim);
                        end
                    end
                end
            end

            // Hart c in the tail, up to its ACK slot two ticks behind hart a.
            if (tail) begin
                assert (code_c[22:8] == 0);
                if (!c_hist) begin
                    if (m_tail == 4'd0 || (m_tail == 4'd1 && tq < 12'd2)) begin
                        assert (c_edge && at_c == PC_ACK && ahead_c == (m_tail == 4'd0 ? d + 12'd2 - tq : 12'd2 - tq));
                    end else if (m_tail == 4'd1) begin
                        if (tq < h + co)
                            begin assert (c_mid && at_c == PC_ACK && since_c == (tq >= co ? tq - co : tq - 12'd2)); end
                        else begin
                            assert (ahead_c == d + co - tq);
                            if (tq == h + co) begin assert (c_exec && at_c == PC_TAIL); end
                            else assert (c_edge && at_c == PC_TAIL && k_c == 0);
                        end
                    end else if (c_late && c_cell == 4'd1) begin
                        assert (c_edge && at_c == PC_TAIL && k_c == 0 && ahead_c == co - tq);
                    end else begin
                        if (c_t < h) begin assert (c_mid && at_c == PC_TAIL && k_c == c_k && since_c == c_t); end
                        else begin
                            assert (ahead_c == d - c_t);
                            if (c_k != 4'd10) begin assert (c_edge && at_c == PC_TAIL && k_c == c_k + 4'd1); end
                            else if (c_t == h) begin assert (c_exec && at_c == PC_TJUMP); end
                            else if (c_t == h + 12'd1) begin assert (c_exec && at_c == PC_IDLE); end
                            else assert (at_c == PC_IDLE && c_claim);
                        end
                    end
                end
            end

            // After `stuff` has restarted it, the coder is clear until the start
            // of frame is read; hart a can get there in the last tail bit.
            if ((at_a == PC_LOSE || at_a == PC_SOF) && !stuffed) assert (code_a[23:2] == 0 && !code_a[3]);

            // ---- Idle: start-up, and between frames ----
            if (idle) begin
                // Neither hart is inside a frame, so the hold trap cuts none off.
                assert (!partial_a[0] && !partial_b[0]);
                assert (!low_b && (m_bus || (at_a == PC_SOF && a_mid)));
                assert (at_a <= PC_SOF && at_b <= PC_IDLE);
                if (at_a == PC_SOF) begin assert (a_exec || (a_edge && ahead_a != 0)
                                            || (a_mid && since_a == 0 && !m_bus && m_prev && low_a)); end
                else assert (!low_a);
                if (at_a >= PC_IDLE && !(at_a == PC_SOF && a_mid))
                    assert (ahead_a == ((m_fr && m_it < sh) ? sh - m_it : 12'd0));
                if (at_a < PC_IDLE) assert (!m_fr && edge_a == now_a && (s_a == S_BOOT || a_exec));
                // The mode words run one a tick from reset, and nothing has
                // been sampled since reset loaded the inputs from BUS.
                if (at_a < PC_IDLE) assert (now_a == (s_a == S_BOOT ? 12'd0 : {6'd0, at_a} + 12'd1)
                                            && m_it == {4'd0, now_a} && armed_a[0] && armed_b[0] && role_b == (norx ? 2'd3 : 2'd0));
                // Until the first frame, the idle count is the time since reset.
                if (!m_fr) assert (m_it == 16'hFFFF || m_it[11:0] == now_a);
                if (at_b == PC_IDLE) assert ((b_exec || b_claim) && armed_b[0]
                                             && ahead_b == ((m_fr && m_it < 12'd2) ? 12'd2 - m_it : 12'd0));
                if (at_b < PC_IDLE) assert (!m_fr && edge_b == now_b && (s_b == S_BOOT || b_exec)
                                            && at_b == at_a && s_b == s_a);
                assert (!partial_c[0] && at_c <= PC_IDLE);
                if (at_c == PC_IDLE) assert ((c_exec || c_claim) && armed_c[0]
                                             && ahead_c == ((m_fr && m_it < {4'd0, co}) ? co - m_it[11:0] : 12'd0));
                if (at_c < PC_IDLE) assert (!m_fr && edge_c == now_c && (s_c == S_BOOT || c_exec)
                                            && at_c == at_a && s_c == s_a && armed_c[0]);
                if (!m_fr && m_bus) assert (rqv == (m_it == 16'hFFFF ? m_it : m_it + 16'd1));
                // After a frame: the tail's 11 recessive bits, less the tick the
                // receiver's ACK ends late, and the idle time; added wide, as both
                // counts stop at FFFF.
                if (m_fr && m_bus) assert (rqv == (it_run > 18'h0FFFF ? 16'hFFFF : it_run[15:0]));
                // The last fall the harts still count is the ACK's, seen 4 ticks
                // into its slot, 12 bits less 4 ticks before the idle count began.
                // So at a hold trap it is 21 bits less a tick old, never just
                // 1024 ticks, when a hart that fires would keep it a tick longer.
                if (cset_a[13]) assert (m_fr);
                if (cset_a[13] && !norx) assert ({6'd0, now_a - lf_a} == {2'd0, m_it} + 18'd12 * {6'd0, d} - 18'd4);
            end

            // ---- Hart b joins a frame ----
            if (stuffed && m_i == 0 && !m_stuff && tq <= 12'd4) begin
                assert (armed_b[0] && count_b == 0 && rx_b == m_sh);
                // Hart b's hold trap can fire on this tick, as it sees BUS low
                // only a tick later: it is then back at `idle` and claims next.
                if (tq <= 12'd1) begin assert (at_b == PC_IDLE && (b_claim || (b_exec
                                               && held_b[15:0] == can_hold_ticks(BIT)))); end
                else if (tq == 12'd2) begin assert (at_b == PC_STUFF && b_exec && role_b == rl_b); end
                else if (tq == 12'd3) begin assert (at_b == PC_LOSE && b_exec && role_b == rl_b); end
                else assert (at_b == PC_SOF && b_exec && role_b == rl_b);
            end
            if (stuffed && !(m_i == 0 && !m_stuff && tq <= 12'd4)) assert (b_hist && c_hist);
            if (stuffed && m_i == 0 && !m_stuff && tq <= 12'd4) begin
                assert (armed_c[0] && count_c == 0 && rx_c == m_sh);
                if (tq <= 12'd1) begin assert (at_c == PC_IDLE && (c_claim || (c_exec
                                               && held_c[15:0] == can_hold_ticks(BIT)))); end
                else if (tq == 12'd2) begin assert (at_c == PC_STUFF && c_exec); end
                else if (tq == 12'd3) begin assert (at_c == PC_LOSE && c_exec); end
                else assert (at_c == PC_SOF && c_exec);
            end

            // DATA: each hart stores each field as hart a sent it.
            if (push_a) assert ((pdata_a & xm_a) == (xv_a & xm_a));
            if (tk_b) assert ((pdata_b & xm_b) == (xv_b & xm_b));
            assert (push_a == st_a && tk_b == st_b);
        end
    end
endmodule
