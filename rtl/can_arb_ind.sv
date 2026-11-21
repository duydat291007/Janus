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
//     the two bytes differ;
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
            if (at_a == PC_DLOAD) fda <= took_a;
        end
        if (b_load) begin
            if (at_b == PC_LOAD1) f1b <= took_b;
            if (at_b == PC_LOAD2) f2b <= took_b;
            if (at_b == PC_LOAD3) f3b <= took_b;
            if (at_b == PC_DLOAD) fdb <= took_b;
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

    // ---- The ACK, as the monitor sees it ----
    reg [10:0] ack_t = 0;                                    // where in the slot BUS fell
    always @(posedge clk)
        if (m_st == M_TAIL && m_tail == 4'd1 && m_prev && !m_bus) ack_t <= m_t;

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
        end
    end
endmodule
