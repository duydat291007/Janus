// Unbounded proof by k-induction of a third complete protocol: the 1-Wire
// program from protocols.py, word for word as the assembler emits it, on two
// real harts. Hart c is the controller (role C) and hart t the target (role T).
//
// uart_ind.sv and spi_ind.sv prove the other two. This one covers what they
// could not reach: an open-drain line that both harts pull low, traps on how
// long the line is held, a loop counter, and a stretch where the two harts
// are out of step until a trap brings them back together.
//
// The program's timings are fixed numbers of ticks, one tick being one
// microsecond, so the invariants give every counter its exact value at every
// point of the program. Those values are written in terms of the step
// lengths gen_onewire_rom.py reads from the program, so a timing change
// needs no edit here.
//
// Free, so the result holds for every choice:
//   start       the address the program is loaded at, 0 to 34
//   valid, data both queues: any bytes, arriving at any time
//   other       the three unused pins, on every tick
//   unwritten   what the other 34 program words hold
//
// Assumed:
//   - both harts leave reset on the same tick, with the program's two hold
//     traps set, no prescaler and no adversary fault;
//   - an entry stays at the head of its queue until the hart pops it, as in
//     janus_fifo;
//   - DQ is open drain with a pull-up: low exactly when a hart drives it low.
//
// Claims:
//   DATA   the target stores the byte the controller took from its queue to
//          write, and the controller stores every byte the target sent: its
//          queue's next byte, or FF when it had none. The controller starts
//          a transaction only with a byte to write, reads one byte for each
//          token in its queue, and stores a presence byte whose top bit is 0.
//          Nothing else is stored or taken.
//   WIRE   a monitor that sees only the wire, and knows only the textbook
//          rules, reads those same bytes, least significant bit first. Every
//          low is a slot of at most 120 ticks or a reset of at least 480.
//          The presence pulse starts 15 to 60 ticks after the reset ends and
//          lasts 60 to 240. The first slot comes at least 480 ticks after
//          the reset ends. Falls are at least 61 ticks apart, and a reset
//          starts only between bytes.
//   CLEAN  neither hart counts a violation or loses arbitration, and neither
//          touches another pin.
//   LIVE   a hart rests only in the states listed below, and the target is
//          side by side with the controller everywhere but in `idle` and the
//          first 130 ticks of a reset pulse.
//
//   KEPT   no byte leaves the target's queue unsent. The target takes its
//          next byte when a read ends, before it knows another read slot is
//          coming; it keeps the byte queued (`keep`) and pops it as its last
//          bit goes out. When the controller resets instead, the byte stays
//          at the head of the queue for the next transaction.
//
// tb_onewire_ind.v simulates this same module with OW_SIM defined: the free
// signals become inputs driven at random, and every assertion is checked once
// a tick. That shows bytes do move under these assumptions.
`ifdef OW_SIM
module onewire_ind (input clk, input [5:0] start, input [31:0] unwritten,
                    input [7:0] addr_c, addr_t, input [2:0] other,
                    input valid_c, valid_t, input [7:0] data_c, data_t,
                    input [1:0] ctl_c, ctl_t);
    `include "onewire_rom.vh"
`else
module onewire_ind (input clk);
    `include "onewire_rom.vh"

    (* anyconst *) wire [5:0]  start;
    (* anyconst *) wire [31:0] unwritten;
    (* anyconst *) wire [7:0]  addr_c, addr_t;
    (* anyseq *)   wire [2:0]  other;
    (* anyseq *)   wire        valid_c, valid_t;
    (* anyseq *)   wire [7:0]  data_c, data_t;
    (* anyseq *)   wire [1:0]  ctl_c, ctl_t;
`endif

    // Reset: one tick of power-on reset, then four in which the host writes
    // the trap registers 2 to 5 while the harts are held.
    reg [2:0] step = 0;
    wire por = step == 0;
    wire rst = step < 3'd5;
    always @(posedge clk) if (rst) step <= step + 1'b1;
    wire        cfg_we = step >= 3'd1 && step <= 3'd4;
    wire [2:0]  cfg_addr = step + 3'd1;
    wire [15:0] cfg_data = ow_config(cfg_addr, start);

    wire [7:0]  oe_c, ov_c, oe_t, ov_t, count_c, count_t, rx_c, rx_t, pin_c, pin_t, s1_c, s1_t;
    wire [7:0]  armed_c, armed_t, tx_c, tx_t, viol_c, viol_t, vout_c, vout_t, pdata_c, pdata_t;
    wire [87:0] code_c, code_t;
    wire [111:0] cfg_c, cfg_t;
    wire [47:0] cset_c, cset_t;
    wire [31:0] held_c, held_t;
    wire [5:0]  pc_c, pc_t;
    wire [3:0]  s_c, s_t, k_c, k_t;
    wire [4:0]  partial_c, partial_t;
    wire [11:0] now_c, now_t, edge_c, edge_t;
    wire [1:0]  role_c, role_t, src_c, src_t;
    wire        last_c, last_t, mine_c, mine_t, val_c, val_t;
    wire        pop_c, pop_t, clear_c, clear_t, push_c, push_t, seen_c, seen_t, seen2_c, seen2_t;
    wire        lost_c, lost_t;
    wire [3:0]  keep_c, keep_t;

    // DQ is open drain with a pull-up: low exactly when a hart drives it low.
    wire        low = (oe_c[0] && !ov_c[0]) || (oe_t[0] && !ov_t[0]);
    wire [7:0]  bus = {4'hF, other, !low};

    wire [5:0]  at_c = pc_c - start, at_t = pc_t - start;
    wire [31:0] ins_c = ow_word(at_c, start, unwritten);
    wire [31:0] ins_t = ow_word(at_t, start, unwritten);

    janus_hart c (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_c), .ov(ov_c),
        .od_mask(8'h01), .base_role(2'd0), .reset_pc(start), .addr_reg(addr_c), .pc(pc_c),
        .pc_sel(), .ins(ins_c), .tx_valid(valid_c), .tx_ctl(ctl_c), .tx_data(data_c),
        .tx_pop(pop_c), .tx_clear(clear_c), .rx_push(push_c), .seen_push(seen_c),
        .seen_push2(seen2_c), .push_data(pdata_c), .push_data2(), .violations(vout_c),
        .arb_lost(lost_c), .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .dbg_s(s_c), .dbg_count(count_c), .dbg_rx(rx_c), .dbg_last(last_c),
        .dbg_now(now_c), .dbg_edge(edge_c), .dbg_dwell(), .dbg_k(k_c),
        .dbg_partial(partial_c), .dbg_role(role_c), .dbg_src(src_c), .dbg_mine(mine_c),
        .dbg_val(val_c), .dbg_pin(pin_c), .dbg_s1(s1_c), .dbg_armed(armed_c),
        .dbg_code(code_c), .dbg_inserted(), .dbg_stuff_bit(), .dbg_width(),
        .dbg_viol(viol_c), .dbg_tx(tx_c), .dbg_cfg(cfg_c), .dbg_cset(cset_c),
        .dbg_cnt(), .dbg_rx1(), .dbg_prev(), .dbg_held(held_c), .dbg_keep(keep_c), .dbg_clean());

    janus_hart t (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_t), .ov(ov_t),
        .od_mask(8'h01), .base_role(2'd1), .reset_pc(start), .addr_reg(addr_t), .pc(pc_t),
        .pc_sel(), .ins(ins_t), .tx_valid(valid_t), .tx_ctl(ctl_t), .tx_data(data_t),
        .tx_pop(pop_t), .tx_clear(clear_t), .rx_push(push_t), .seen_push(seen_t),
        .seen_push2(seen2_t), .push_data(pdata_t), .push_data2(), .violations(vout_t),
        .arb_lost(lost_t), .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .dbg_s(s_t), .dbg_count(count_t), .dbg_rx(rx_t), .dbg_last(last_t),
        .dbg_now(now_t), .dbg_edge(edge_t), .dbg_dwell(), .dbg_k(k_t),
        .dbg_partial(partial_t), .dbg_role(role_t), .dbg_src(src_t), .dbg_mine(mine_t),
        .dbg_val(val_t), .dbg_pin(pin_t), .dbg_s1(s1_t), .dbg_armed(armed_t),
        .dbg_code(code_t), .dbg_inserted(), .dbg_stuff_bit(), .dbg_width(),
        .dbg_viol(viol_t), .dbg_tx(tx_t), .dbg_cfg(cfg_t), .dbg_cset(cset_t),
        .dbg_cnt(), .dbg_rx1(), .dbg_prev(), .dbg_held(held_t), .dbg_keep(keep_t), .dbg_clean());

    localparam S_BOOT = 4'd0, S_EXEC = 4'd1, S_CLAIM = 4'd2, S_SYNC = 4'd3, S_EDGE = 4'd4,
               S_MID = 4'd5;

    wire        c_boot = s_c == S_BOOT, c_exec = s_c == S_EXEC, c_claim = s_c == S_CLAIM;
    wire        c_edge = s_c == S_EDGE, c_mid = s_c == S_MID;
    wire        t_boot = s_t == S_BOOT, t_exec = s_t == S_EXEC, t_claim = s_t == S_CLAIM;
    wire        t_sync = s_t == S_SYNC, t_edge = s_t == S_EDGE, t_mid = s_t == S_MID;
    wire [11:0] since_c = now_c - edge_c, ahead_c = edge_c - now_c;

    // The program's timings, from its own words (onewire_rom.vh). A timed
    // step moves on in its middle, H_ ticks after its edge, and the next
    // step's edge comes R_ ticks after that.
    localparam [11:0] HS = HOLD_SUSPECT[11:0], HR = HOLD_RESET[11:0];
    localparam [11:0] H_SUSP = D_SUSP >> 1, R_SUSP = D_SUSP - (D_SUSP >> 1);
    localparam [11:0] H_RESET = D_RESET >> 1, R_RESET = D_RESET - (D_RESET >> 1);
    localparam [11:0] H_RELEASE = D_RELEASE >> 1, R_RELEASE = D_RELEASE - (D_RELEASE >> 1);
    localparam [11:0] H_PRES = D_PRES >> 1, R_PRES = D_PRES - (D_PRES >> 1);
    localparam [11:0] H_WAIT = D_WAIT >> 1, R_WAIT = D_WAIT - (D_WAIT >> 1);
    localparam [11:0] H_START = D_START >> 1, R_START = D_START - (D_START >> 1);
    localparam [11:0] H_WBIT = D_WBIT >> 1, R_WBIT = D_WBIT - (D_WBIT >> 1);
    localparam [11:0] H_WREST = D_WREST >> 1, R_WREST = D_WREST - (D_WREST >> 1);
    localparam [11:0] H_RBIT = D_RBIT >> 1, R_RBIT = D_RBIT - (D_RBIT >> 1);
    localparam [11:0] H_RREST = D_RREST >> 1, R_RREST = D_RREST - (D_RREST >> 1);
    // Held-low counts: when the reset is let go, and at the start of a slot.
    localparam [15:0] LOW_RESET = HOLD_RESET + D_RESET + 16'd1;
    localparam [15:0] LOW_START = D_START - 16'd1;
    // On the wire: the reset pulse, and the time from one fall to the next.
    localparam [9:0]  W_RESET = HOLD_RESET + D_RESET + 10'd2;
    localparam [9:0]  SLOT_W = D_START + D_WBIT + D_WREST;
    localparam [9:0]  SLOT_R = D_START + D_RBIT + D_RREST;
    localparam [9:0]  SLOT_MIN = SLOT_W < SLOT_R ? SLOT_W : SLOT_R;
    localparam [9:0]  W_BIT_END = D_START + D_WBIT, R_BIT_END = D_START + D_RBIT;

    // The line as the harts see it: one tick ago, two ticks ago, and for how
    // many ticks in a row the two-tick-old level has been low.
    wire [17:0] line = {s1_c[0], pin_c[0], held_c[15:0]};
    wire        low_c = oe_c[0] && !ov_c[0], low_t = oe_t[0] && !ov_t[0];

    function automatic f_high(input [17:0] ln);
        f_high = ln == {2'b11, 16'd0};
    endfunction
    function automatic f_low(input [17:0] ln, input [15:0] h);
        f_low = ln == {2'b00, h};
    endfunction
    // Driven low `since` ticks ago, from high.
    function automatic f_fall(input [17:0] ln, input [11:0] since);
        f_fall = ln == {since == 0, since <= 12'd1,
                        since >= 12'd2 ? {4'd0, since} - 16'd1 : 16'd0};
    endfunction
    // Let go `since` ticks ago, after `h` ticks low.
    function automatic f_rise(input [17:0] ln, input [11:0] since, input [15:0] h);
        f_rise = ln == {since >= 12'd1, since >= 12'd2,
                        since == 0 ? h : since == 12'd1 ? h + 16'd1 : 16'd0};
    endfunction

    // A hold trap fires on the next tick: DQ has been low long enough.
    wire        trap = !s1_c[0] && (held_c[15:0] + 16'd1 == HOLD_SUSPECT
                                    || held_c[31:16] + 16'd1 == HOLD_RESET);

    // The bytes in flight, following the harts' own decisions.
    reg [7:0]  wr = 0, rd = 0;   // the byte being written, and the one being read
    reg        vq_c = 0;
    wire       c_loads = !rst && !trap && c_exec && at_c == PC_LOAD_WRITE;
    wire       c_token = !rst && !trap && c_exec && at_c == PC_LOAD_TOKEN;
    wire       t_loads = !rst && !trap && t_exec && at_t == PC_LOAD_READ;
    wire       t_stores = !rst && !trap && t_exec && at_t == PC_W_STORE;
    wire       c_stores = !rst && !trap && c_exec && at_c == PC_R_STORE;
    wire       p_stores = !rst && !trap && c_exec && at_c == PC_STORE_PRESENCE;
    reg        t_stored = 0, c_stored = 0, p_stored = 0, took_c = 0;
    reg        vq_t = 0, kv_t = 0, trapped = 0;
    reg [7:0]  dq_t = 0;         // the target's queue head one tick ago
    reg [3:0]  kq_t = 0;         // its keep count one tick ago

    // The bit of the byte in hand that the slot in progress carries. The
    // counter runs from 8 down to 1, and the least significant bit goes first.
    wire [3:0]  sent = 4'd8 - count_c[3:0];      // slots finished before this one
    wire        wbit = wr[sent[2:0]], rbit = rd[sent[2:0]];

    always @(posedge clk) begin
        vq_c <= valid_c;
        t_stored <= t_stores;
        c_stored <= c_stores;
        p_stored <= p_stores;
        took_c <= (c_loads || c_token) && valid_c;
        vq_t <= valid_t;
        dq_t <= data_t;
        kq_t <= keep_t;
        trapped <= !rst && trap;
        if (rst) kv_t <= 0;
        else if (t_loads) kv_t <= valid_t;   // a byte from the queue is kept
        if (rst) begin
            wr <= 0;
            rd <= 0;
        end else begin
            if (c_loads) wr <= valid_c ? data_c : 8'hFF;
            if (t_loads) rd <= valid_t ? data_t : 8'hFF;
        end
    end

    // The monitor. It samples the one wire once a tick, as any device on the
    // bus could, and knows only the textbook rules: a low of 480 ticks or
    // more is a reset, the next low after it is the presence pulse, and after
    // that every fall starts a slot whose bit is the level in the fifteenth
    // tick, least significant bit first, eight to a byte. The first byte
    // after a reset is the one written; the rest are read.
    reg        m_prev = 1;       // the wire one tick ago
    reg [9:0]  m_t = 10'd1023;   // ticks since it last fell, stopping at 1023
    reg [6:0]  m_h = 7'd127;     // ticks since it last rose, stopping at 127
    reg [1:0]  m_ph = 0;         // 0 no reset yet, 1 reset over, 2 presence pulse, 3 data
    reg [2:0]  m_n = 0;          // bits read of the byte in hand
    reg [7:0]  m_b = 0;          // those bits
    reg        m_first = 0;      // the byte in hand is the first after the reset
    reg [6:0]  m_p = 0;          // ticks from the end of the reset to the presence pulse
    wire       m_fall = m_prev && !bus[0], m_rise = !m_prev && bus[0];
    // A low too long for a slot: a reset is starting, not a bit.
    wire       m_long = m_ph == 2'd3 && !m_prev && !bus[0] && m_t == 10'd120;
    wire       m_read = m_ph == 2'd3 && m_t == 10'd14;

    always @(posedge clk) begin
        m_prev <= bus[0];
        m_t <= m_fall ? 10'd1 : m_t == 10'd1023 ? m_t : m_t + 10'd1;
        m_h <= m_rise ? 7'd1 : m_h == 7'd127 ? m_h : m_h + 7'd1;
        if (m_rise && m_t >= 10'd480) m_ph <= 2'd1;
        else if (m_rise && m_ph == 2'd2) begin
            m_ph <= 2'd3;
            m_n <= 0;
            m_first <= 1'b1;
        end else if (m_fall && m_ph == 2'd1) begin
            m_ph <= 2'd2;
            m_p <= m_h;
        end
        else if (m_long) begin
            m_ph <= 2'd0;
            m_n <= 0;
        end else if (m_read) begin
            m_b <= {bus[0], m_b[7:1]};
            m_n <= m_n + 3'd1;
            if (m_n == 3'd7) m_first <= 1'b0;
        end
    end

    // What the monitor's clocks read at each point of the program.
    wire [9:0]  sc = since_c[9:0], ac = ahead_c[9:0];
    wire        first_run = at_t <= PC_PULSE;    // while apart: before the first reset
    wire [3:0]  w_n = sent + ((at_c == PC_W_DATA && c_mid && since_c >= 12'd15 - D_START)
                              || at_c == PC_W_REST || at_c == PC_W_LOOP);
    wire [3:0]  r_n = sent + (at_c == PC_R_REST || at_c == PC_R_LOOP);

    // The controller is out of step with the target only in `idle` and in the
    // first 130 ticks of a reset pulse. Everywhere else they run side by side.
    wire        apart = at_c == PC_CLAIM || at_c == PC_PULSE;
    wire        waiting = (at_c == PC_CLAIM && c_claim) || (at_c == PC_PULSE && (c_exec || c_edge));
    wire        syncs = at_c == PC_RELEASE || at_c == PC_W_START || at_c == PC_R_START;

`ifdef OW_SIM
    always @(negedge clk) begin                  // once a tick, with everything settled
`else
    always @* begin
`endif
        assume (start <= MAX_START);
        if (vq_c && !pop_c) assume (valid_c);
        // The target's queue: the entry at its head stays until it is popped.
        if (vq_t && !pop_t) assume (valid_t && data_t == dq_t);

        assert (step <= 3'd5);
        if (!rst) begin
            // CLEAN
            assert (viol_c == 0 && viol_t == 0 && vout_c == 0 && vout_t == 0);
            assert (!lost_c && !lost_t && !clear_c && !clear_t);
            assert (!seen_c && !seen_t && !seen2_c && !seen2_t);
            assert (oe_c[7:1] == 0 && oe_t[7:1] == 0);

            // DATA
            if (c_loads || c_token) assert (valid_c);
            if (t_stored) assert (pdata_t == wr);
            if (c_stored) assert (pdata_c == rd);
            if (p_stored) assert (!pdata_c[7]);  // the presence pulse was seen
            assert (push_t == t_stored && push_c == (c_stored || p_stored));
            assert (pop_c == took_c && keep_c == 0);
            // KEPT. The target's byte is popped exactly when its last bit
            // goes out: the keep count runs from 1 to 0 on a tick with no trap.
            assert (pop_t == (kq_t == 4'd1 && keep_t == 0 && vq_t && !trapped));
            // The count is the bits of the kept byte still to go: 8 when it is
            // loaded, then one fewer for each read slot the target sends in.
            assert (keep_t == (!kv_t ? 4'd0
                               : at_t == PC_COUNT_READ ? 4'd8
                               : at_t == PC_R_START || (at_t == PC_R_DATA && t_exec) ? count_t[3:0]
                               : at_t == PC_R_DATA || at_t == PC_R_REST || at_t == PC_R_LOOP
                                 ? count_t[3:0] - 4'd1
                               : 4'd0));
            // While a byte is kept, it is the head of the queue.
            if (keep_t != 0) assert (vq_t && dq_t == rd);
            // The byte that let the controller leave `idle` stays queued until
            // it is written, and a read token stays until it is taken.
            if (at_c == PC_PULSE || (at_c >= PC_SUSPECT && at_c <= PC_LOAD_WRITE)
                    || at_c == PC_LOAD_TOKEN)
                assert (vq_c && !pop_c);

            // WIRE: the textbook rules, on what the monitor sees.
            if (m_rise) assert (m_t <= 10'd120 || m_t >= 10'd480);  // a slot or a full reset
            if (m_rise && m_ph == 2'd2) assert (m_t >= 10'd60 && m_t <= 10'd240);
            if (m_fall && m_ph == 2'd1) assert (m_h >= 7'd15 && m_h <= 7'd60);
            if (m_fall && m_ph == 2'd3) assert (m_t >= 10'd61);     // a slot and its recovery
            if (m_long) assert (m_n == 3'd1);                       // a reset starts between bytes
            // The line stays high at least 480 ticks after a reset before the first slot.
            if (m_fall && m_ph == 2'd3 && m_first && m_n == 0) assert ({3'd0, m_p} + m_t >= 10'd480);
            if (m_read && m_n == 3'd7) assert ({bus[0], m_b[7:1]} == (m_first ? wr : rd));

            // The monitor against the controller.
            assert (m_prev == s1_c[0]);
            case (at_c)
                PC_NOARB: begin assert (m_ph == 2'd0 && m_t == 10'd1023); end
                PC_CLAIM, PC_PULSE: begin
                    if (first_run) assert (m_ph == 2'd0);
                    if (!(at_c == PC_PULSE && c_mid)) begin
                        if (first_run) begin assert (m_t == 10'd1023); end
                        else assert (m_ph == 2'd3 && m_n == 0 && !m_first && ahead_c <= R_RREST - 12'd4
                                     && (m_t == 10'd1023 || {1'b0, m_t} + {1'b0, ac} >= {1'b0, SLOT_MIN}));
                    end else if (since_c == 0) begin
                        if (first_run) begin assert (m_t == 10'd1023); end
                        else assert (m_ph == 2'd3 && m_n == 0 && !m_first && m_t >= SLOT_MIN);
                    end else begin
                        assert (m_t == sc);
                        if (!first_run) assert (m_ph == (since_c <= 12'd120 ? 2'd3 : 2'd0) && !m_first
                                                && m_n == (since_c >= 12'd15 && since_c <= 12'd120));
                    end
                end
                PC_SUSPECT: begin assert (m_ph == 2'd0 && m_t == (c_exec ? HOLD_SUSPECT[9:0] + 10'd1 : HOLD_SUSPECT[9:0] + 10'd2 + sc)); end
                PC_SUSPECT_END: begin assert (m_ph == 2'd0 && m_t == HOLD_SUSPECT[9:0] + D_SUSP[9:0] + 10'd2 - ac); end
                PC_RESET: begin assert (m_ph == 2'd0 && m_t == (c_exec ? HOLD_RESET[9:0] + 10'd1 : HOLD_RESET[9:0] + 10'd2 + sc)); end
                PC_RELEASE: begin
                    if (!c_mid) begin assert (m_ph == 2'd0 && m_t == W_RESET - ac); end
                    else begin
                        assert (m_t == W_RESET + sc && m_ph == (since_c != 0));
                        if (since_c != 0) assert (m_h == sc[6:0]);
                    end
                end
                PC_LOAD_PRESENCE: begin assert (m_ph == 2'd1 && m_t == W_RESET + D_RELEASE[9:0] - ac && m_h == D_RELEASE[6:0] - ac[6:0]); end
                PC_PRESENCE: begin
                    if (!c_mid) begin assert (m_ph == 2'd1 && m_t == W_RESET + D_RELEASE[9:0] - ac && m_h == D_RELEASE[6:0] - ac[6:0]); end
                    else if (since_c == 0) begin assert (m_ph == 2'd1 && m_t == W_RESET + D_RELEASE[9:0] && m_h == D_RELEASE[6:0]); end
                    else assert (m_ph == 2'd2 && m_t == sc);
                end
                PC_STORE_PRESENCE: begin assert (m_ph == 2'd2 && m_t == D_PRES[9:0] - ac); end
                PC_WAIT: begin
                    if (!c_mid) begin assert (m_ph == 2'd2 && m_t == D_PRES[9:0] - ac); end
                    else begin
                        assert (m_t == D_PRES[9:0] + sc);
                        if (since_c == 0) begin assert (m_ph == 2'd2); end
                        else assert (m_ph == 2'd3 && m_n == 0 && m_first);
                    end
                end
                PC_LOAD_WRITE, PC_COUNT_WRITE: begin
                    assert (m_ph == 2'd3 && m_n == 0 && m_first && m_t == D_PRES[9:0] + D_WAIT[9:0] - ac);
                end
                PC_W_START: begin
                    if (!c_mid || since_c == 0) begin assert (m_t == (count_c == 8'd8 ? D_PRES[9:0] + D_WAIT[9:0] : SLOT_W) - (c_mid ? 10'd0 : ac)); end
                    else assert (m_t == sc);
                end
                PC_W_DATA, PC_R_DATA: begin assert (m_t == (c_mid ? D_START[9:0] + sc : D_START[9:0] - ac)); end
                PC_W_REST: begin assert (m_t == (c_mid ? W_BIT_END + sc : W_BIT_END - ac)); end
                PC_W_LOOP, PC_W_STORE: begin assert (m_t == SLOT_W - ac); end
                PC_CHOICE, PC_LOAD_TOKEN, PC_LOAD_READ, PC_COUNT_READ: begin
                    assert (m_t == (ahead_c <= R_WREST - 12'd2 ? SLOT_W : SLOT_R) - ac);
                end
                PC_R_START: begin
                    if (c_exec) assert (m_t == ((count_c == 8'd8 && ahead_c == 0) ? SLOT_W + 10'd1 : SLOT_R - ac));
                    if (c_edge) assert (m_t == SLOT_R - ac);
                    if (c_mid) assert (since_c != 0 ? m_t == sc
                                       : (m_t == SLOT_R || (m_t == SLOT_W + 10'd2 && count_c == 8'd8)));
                end
                PC_R_REST: begin assert (m_t == (c_mid ? R_BIT_END + sc : R_BIT_END - ac)); end
                PC_R_LOOP, PC_R_STORE, PC_R_JUMP: begin assert (m_t == SLOT_R - ac); end
                default: ;
            endcase
            if (at_c >= PC_LOAD_WRITE) assert (m_ph == 2'd3);
            if (m_ph >= 2'd2) assert (m_p == D_RELEASE[6:0]);
            // The bits the monitor has read are the low bits of the byte in flight.
            if (at_c >= PC_W_START && at_c <= PC_W_LOOP) begin
                assert (m_n == w_n[2:0] && m_first == !w_n[3]);
                if (w_n != 0) assert ((m_b >> (4'd8 - w_n)) == (wr & ~(8'hFF << w_n)));
            end
            if ((at_c >= PC_W_STORE && at_c <= PC_COUNT_READ) || at_c >= PC_R_STORE)
                assert (m_n == 0 && !m_first);
            if (at_c >= PC_R_START && at_c <= PC_R_LOOP) begin
                assert (m_n == r_n[2:0] && !m_first);
                if (r_n != 0) assert ((m_b >> (4'd8 - r_n)) == (rd & ~(8'hFF << r_n)));
            end

            // Fixed for the whole run.
            assert (role_c == 2'd0 && role_t == 2'd1 && k_c == 0 && k_t == 0);
            assert (partial_c == 0 && partial_t == 0);
            assert (cfg_c == {16'd0, HOLD_RESET, HOLD_SUSPECT, ow_config(3'd3, start),
                              ow_config(3'd2, start), 32'd0} && cfg_t == cfg_c);
            assert (cset_c == {3'd0, at_c == PC_NOARB ? 2'd3 : 2'd2, 43'd0});
            assert (cset_t == {3'd0, at_t == PC_NOARB ? 2'd3 : 2'd2, 43'd0});
            assert (code_c == 0 && code_t == 0);
            assert (now_c == now_t && pin_c == pin_t && s1_c == s1_t && held_c == held_t);
            assert (held_c[31:16] == held_c[15:0]);

            // LIVE: where a hart can be, and in which state.
            assert (at_c < PROG_LEN && at_c != PC_HANG && at_c != PC_SUSPECT_JUMP);
            assert (at_t < PROG_LEN && at_t != PC_HANG && at_t != PC_SUSPECT_JUMP);
            case (at_c)
                PC_NOARB:       begin assert (c_boot || c_exec); end
                PC_CLAIM:       begin assert (c_exec || c_claim); end
                PC_PULSE:       begin assert (c_exec || c_edge || c_mid); end
                PC_SUSPECT:     begin assert (c_exec || c_mid); end
                PC_SUSPECT_END: begin assert (c_exec || c_edge); end
                PC_RESET:       begin assert (c_exec || c_mid); end
                PC_RELEASE, PC_PRESENCE, PC_WAIT, PC_W_START, PC_W_DATA, PC_W_REST, PC_R_START,
                PC_R_DATA, PC_R_REST: begin assert (c_exec || c_edge || c_mid); end
                default:        begin assert (c_exec); end
            endcase
            assert (t_boot || t_exec || t_claim || t_sync || t_edge || t_mid);
            if (t_boot) assert (at_t == PC_NOARB);
            if (t_claim) assert (at_t == PC_CLAIM);
            if (t_sync) assert (at_t == PC_RELEASE || at_t == PC_W_START || at_t == PC_R_START);

            // A bit in progress, as its instruction describes it.
            if (c_edge || c_mid) begin
                assert (mine_c == (ins_c[24:23] == 2'd0) && src_c == ins_c[22:21]);
                if (mine_c) assert (val_c == (at_c == PC_W_DATA ? wbit : ins_c[21]));
            end
            if (t_sync || t_edge || t_mid)
                assert (mine_t == (ins_t[24:23] == 2'd1) && src_t == ins_t[22:21]);
            if (t_sync) assert (val_t == ins_t[21]);

            // Who holds the line low. The controller: its reset pulse, the
            // start of every slot, and a written 0.
            assert (low_c == ((at_c == PC_PULSE && c_mid) || at_c == PC_SUSPECT
                              || at_c == PC_SUSPECT_END || at_c == PC_RESET
                              || (at_c == PC_RELEASE && !c_mid)
                              || (at_c == PC_W_START && c_mid) || (at_c == PC_W_DATA && !c_mid)
                              || (at_c == PC_W_DATA && c_mid && !wbit)
                              || (at_c == PC_W_REST && !c_mid && !wbit)
                              || (at_c == PC_R_START && c_mid) || (at_c == PC_R_DATA && !c_mid)));
            // The target: its presence pulse and the bits it is read.
            assert (oe_t[0] == ((at_t == PC_PRESENCE && t_mid) || at_t == PC_STORE_PRESENCE
                                || (at_t == PC_WAIT && !t_mid) || (at_t == PC_R_DATA && t_mid)
                                || (at_t == PC_R_REST && !t_mid)));
            if (oe_t[0] && at_t <= PC_WAIT) assert (!ov_t[0]);
            if (oe_t[0] && at_t >= PC_R_DATA && !apart) assert (ov_t[0] == rbit);

            // The line, the hold counters, and the controller's bit edge.
            case (at_c)
                PC_NOARB, PC_CLAIM: begin assert (f_high(line) && armed_c[0]); end
                PC_PULSE: begin
                    assert (armed_c[0]);
                    if (c_mid) begin assert (since_c <= HS && f_fall(line, since_c)); end
                    else assert (f_high(line));
                end
                PC_SUSPECT: begin
                    assert (!armed_c[0]);
                    if (c_exec) begin assert (since_c == 0 && f_low(line, HOLD_SUSPECT)); end
                    else assert (since_c <= H_SUSP - 12'd1 && f_low(line, HOLD_SUSPECT + 16'd1 + since_c));
                end
                PC_SUSPECT_END: begin
                    assert (!armed_c[0] && f_low(line, HOLD_SUSPECT + D_SUSP + 16'd1 - ahead_c));
                    // Until the reset trap fires: held below HOLD_RESET.
                    assert (c_exec ? ahead_c == R_SUSP
                                   : (ahead_c >= HS + D_SUSP + 12'd2 - HR && ahead_c <= R_SUSP - 12'd1));
                end
                PC_RESET: begin
                    assert (!armed_c[0]);
                    if (c_exec) begin assert (since_c == 0 && f_low(line, HOLD_RESET)); end
                    else assert (since_c <= H_RESET - 12'd1 && f_low(line, HOLD_RESET + 16'd1 + since_c));
                end
                PC_RELEASE: begin
                    assert (!armed_c[0]);
                    if (c_mid) begin assert (since_c <= H_RELEASE - 12'd1 && f_rise(line, since_c, LOW_RESET)); end
                    else begin
                        assert (f_low(line, LOW_RESET - ahead_c));
                        assert (c_exec ? ahead_c == R_RESET : (ahead_c >= 12'd1 && ahead_c <= R_RESET - 12'd1));
                    end
                end
                PC_LOAD_PRESENCE: begin assert (armed_c[0] && f_high(line) && ahead_c == R_RELEASE); end
                PC_PRESENCE: begin
                    assert (armed_c[0]);
                    if (c_mid) begin assert (since_c <= H_PRES - 12'd1 && f_fall(line, since_c)); end
                    else begin
                        assert (f_high(line));
                        assert (c_exec ? ahead_c == R_RELEASE - 12'd1 : (ahead_c >= 12'd1 && ahead_c <= R_RELEASE - 12'd2));
                    end
                end
                PC_STORE_PRESENCE: begin assert (!armed_c[0] && f_low(line, D_PRES / 2 - 16'd1) && ahead_c == R_PRES); end
                PC_WAIT: begin
                    assert (!armed_c[0]);
                    if (c_mid) begin assert (since_c <= H_WAIT - 12'd1 && f_rise(line, since_c, D_PRES - 16'd1)); end
                    else begin
                        assert (f_low(line, D_PRES - 16'd1 - ahead_c));
                        assert (c_exec ? ahead_c == R_PRES - 12'd1 : (ahead_c >= 12'd1 && ahead_c <= R_PRES - 12'd2));
                    end
                end
                PC_LOAD_WRITE: begin assert (armed_c[0] && f_high(line) && ahead_c == R_WAIT); end
                PC_COUNT_WRITE: begin assert (armed_c[0] && f_high(line) && ahead_c == R_WAIT - 12'd1); end
                PC_W_START, PC_R_START: begin
                    assert (armed_c[0]);
                    if (c_mid) begin assert (since_c <= H_START - 12'd1 && f_fall(line, since_c)); end
                    else assert (f_high(line));
                end
                PC_W_DATA, PC_R_DATA: begin
                    assert (!armed_c[0]);
                    if (c_exec) assert (ahead_c == R_START && f_low(line, D_START / 2 - 16'd1));
                    if (c_edge) assert (ahead_c >= 12'd1 && ahead_c <= R_START - 12'd1 && f_low(line, LOW_START - ahead_c));
                end
                PC_W_LOOP: begin assert (armed_c[0] && f_high(line) && ahead_c == R_WREST); end
                PC_W_STORE: begin assert (armed_c[0] && f_high(line) && ahead_c == R_WREST - 12'd1); end
                // From here to the first read slot the edge is the end of the
                // recovery after a write slot or after a read slot.
                PC_CHOICE: begin assert (armed_c[0] && f_high(line) && (ahead_c == R_WREST - 12'd2 || ahead_c == R_RREST - 12'd3)); end
                PC_LOAD_TOKEN: begin assert (armed_c[0] && f_high(line) && (ahead_c == R_WREST - 12'd3 || ahead_c == R_RREST - 12'd4)); end
                PC_LOAD_READ: begin assert (armed_c[0] && f_high(line) && (ahead_c == R_WREST - 12'd4 || ahead_c == R_RREST - 12'd5)); end
                PC_COUNT_READ: begin assert (armed_c[0] && f_high(line) && (ahead_c == R_WREST - 12'd5 || ahead_c == R_RREST - 12'd6)); end
                PC_R_LOOP: begin assert (armed_c[0] && f_high(line) && ahead_c == R_RREST); end
                PC_R_STORE: begin assert (armed_c[0] && f_high(line) && ahead_c == R_RREST - 12'd1); end
                PC_R_JUMP: begin assert (armed_c[0] && f_high(line) && ahead_c == R_RREST - 12'd2); end
                default: ;
            endcase
            if (at_c == PC_W_START && c_exec) assert (ahead_c == (count_c == 8'd8 ? R_WAIT - 12'd2 : R_WREST - 12'd1));
            if (at_c == PC_W_START && c_edge)
                assert (ahead_c >= 12'd1 && ahead_c <= (count_c == 8'd8 ? R_WAIT - 12'd3 : R_WREST - 12'd2));
            if (at_c == PC_R_START && c_exec)
                assert (count_c == 8'd8 ? (ahead_c == 0 || ahead_c == R_RREST - 12'd7) : ahead_c == R_RREST - 12'd1);
            if (at_c == PC_R_START && c_edge) assert (ahead_c >= 12'd1 && ahead_c <= R_RREST - 12'd2);
            // A written bit: 54 ticks of the bit, then the line let go.
            if (at_c == PC_W_DATA && c_mid)
                assert (since_c <= H_WBIT - 12'd1 && (wbit ? f_rise(line, since_c, LOW_START)
                                                   : f_low(line, LOW_START + since_c)));
            if (at_c == PC_W_REST) begin
                assert (armed_c[0] == wbit);
                if (c_exec) assert (ahead_c == R_WBIT && (wbit ? f_high(line) : f_low(line, LOW_START + D_WBIT / 2)));
                if (c_edge) assert (ahead_c >= 12'd1 && ahead_c <= R_WBIT - 12'd1
                                    && (wbit ? f_high(line) : f_low(line, LOW_START + D_WBIT - ahead_c)));
                if (c_mid) assert (since_c <= H_WREST - 12'd1 && (wbit ? f_high(line)
                                                             : f_rise(line, since_c, LOW_START + D_WBIT)));
            end
            // A bit read: 18 ticks of the target's bit, then the line let go.
            if (at_c == PC_R_DATA && c_mid)
                assert (since_c <= H_RBIT - 12'd1 && (rbit ? f_rise(line, since_c, LOW_START)
                                                  : f_low(line, LOW_START + since_c)));
            if (at_c == PC_R_REST) begin
                assert (armed_c[0] == rbit);
                if (c_exec) assert (ahead_c == R_RBIT && (rbit ? f_high(line) : f_low(line, LOW_START + D_RBIT / 2)));
                if (c_edge) assert (ahead_c >= 12'd1 && ahead_c <= R_RBIT - 12'd1
                                    && (rbit ? f_high(line) : f_low(line, LOW_START + D_RBIT - ahead_c)));
                if (c_mid) assert (since_c <= H_RREST - 12'd1 && (rbit ? f_high(line)
                                                              : f_rise(line, since_c, LOW_START + D_RBIT)));
            end

            // The slot counter.
            if ((at_c >= PC_W_START && at_c <= PC_W_LOOP) || (at_c >= PC_R_START && at_c <= PC_R_LOOP))
                assert (count_c >= 8'd1 && count_c <= 8'd8);
            if ((at_c >= PC_W_STORE && at_c <= PC_COUNT_READ) || at_c >= PC_R_STORE)
                assert (count_c == 0);

            // The target beside the controller.
            if (!apart) begin
                assert (at_t == at_c && armed_t[0] == armed_c[0]);
                if (at_c >= PC_W_START) assert (count_t == count_c);
                // At a synchronised step the target waits for the edge and
                // sees it two ticks after the controller drives it.
                if (syncs && (c_edge || (c_mid && since_c <= 12'd1))) begin assert (t_sync); end
                else assert (s_t == s_c && edge_t == edge_c);
                if (syncs && c_edge) assert (edge_t == edge_c);
            end

            // Apart. At the very start both wait in `idle`, and the target
            // joins the reset pulse one tick late. After a transaction the
            // controller goes to `idle` while the target goes on to the next
            // read: it takes a byte, takes the reset pulse for a read slot,
            // sends one bit into it, and then waits for a second slot that
            // never comes. The width trap brings both back together.
            if (at_c == PC_CLAIM && c_exec)
                assert (t_exec && (at_t == PC_CLAIM || at_t == PC_LOAD_TOKEN));
            if (waiting)
                assert ((at_t == PC_CLAIM && t_claim)
                        || (at_t == PC_LOAD_READ && t_exec && !c_edge)
                        || (at_t == PC_COUNT_READ && t_exec)
                        || (at_t == PC_R_START && (t_exec || t_sync) && count_t == 8'd8));
            if (at_c == PC_PULSE && c_mid) begin
                if (at_t <= PC_PULSE) begin
                    if (since_c <= 12'd1) begin assert (at_t == PC_CLAIM && t_claim); end
                    else if (since_c == 12'd2) begin assert (at_t == PC_PULSE && t_exec); end
                    else assert (at_t == PC_PULSE && t_mid && edge_t == edge_c + 12'd1);
                end else if (since_c == 0)
                    begin assert ((at_t == PC_COUNT_READ && t_exec)
                            || (at_t == PC_R_START && (t_exec || t_sync) && count_t == 8'd8)); end
                else if (since_c == 12'd1)
                    begin assert (at_t == PC_R_START && (t_exec || t_sync) && count_t == 8'd8); end
                else if (since_c == 12'd2)
                    begin assert (at_t == PC_R_START && t_mid && edge_t == edge_c && count_t == 8'd8); end
                else if (since_c <= D_START + H_RBIT - 12'd1)
                    begin assert (at_t == PC_R_DATA && edge_t == edge_c + D_START && count_t == 8'd8
                            && (since_c == H_START ? t_exec : since_c <= D_START - 12'd1 ? t_edge : t_mid)); end
                else if (since_c <= D_START + D_RBIT + H_RREST - 12'd1)
                    begin assert (at_t == PC_R_REST && edge_t == edge_c + D_START + D_RBIT && count_t == 8'd8
                            && (since_c == D_START + H_RBIT ? t_exec
                                : since_c <= D_START + D_RBIT - 12'd1 ? t_edge : t_mid)); end
                else if (since_c == D_START + D_RBIT + H_RREST)
                    begin assert (at_t == PC_R_LOOP && t_exec && count_t == 8'd8 && !armed_t[0]); end
                else
                    assert (at_t == PC_R_START && count_t == 8'd7 && !armed_t[0]
                            && (since_c == D_START + D_RBIT + H_RREST + 12'd1 ? t_exec : t_sync));
            end
            // Until the target has seen the line fall it is armed for a fall.
            if (apart && (at_t == PC_CLAIM || (at_t == PC_PULSE && t_exec)
                          || (at_t >= PC_LOAD_TOKEN && at_t <= PC_COUNT_READ)
                          || (at_t == PC_R_START && !t_mid && count_t == 8'd8)))
                assert (armed_t[0]);

            // DATA, bit by bit. The byte being written leaves the controller
            // from its low end and fills the target from the top.
            if (at_c == PC_COUNT_WRITE) assert (tx_c == wr);
            if (at_c == PC_W_START || (at_c == PC_W_DATA && c_exec)) assert (tx_c == (wr >> sent));
            if ((at_c == PC_W_DATA && !c_exec) || at_c == PC_W_REST || at_c == PC_W_LOOP)
                assert (tx_c == (wr >> (sent + 4'd1)));
            if (at_c == PC_W_START || at_c == PC_W_DATA)
                assert ((rx_t >> count_c[3:0]) == (wr & ~(8'hFF << sent)));
            if (at_c == PC_W_REST || at_c == PC_W_LOOP)
                assert ((rx_t >> (count_c[3:0] - 4'd1)) == (wr & ~(8'hFF << (sent + 4'd1))));
            if (at_c == PC_W_STORE) assert (rx_t == wr);
            // The byte being read, the other way.
            if (at_c == PC_COUNT_READ) assert (tx_t == rd);
            if (at_c == PC_R_START || (at_c == PC_R_DATA && c_exec)) assert (tx_t == (rd >> sent));
            if ((at_c == PC_R_DATA && !c_exec) || at_c == PC_R_REST || at_c == PC_R_LOOP)
                assert (tx_t == (rd >> (sent + 4'd1)));
            if (at_c == PC_R_DATA && !c_exec) assert (val_t == rbit);
            if (at_c == PC_R_START || at_c == PC_R_DATA)
                assert ((rx_c >> count_c[3:0]) == (rd & ~(8'hFF << sent)));
            if (at_c == PC_R_REST || at_c == PC_R_LOOP)
                assert ((rx_c >> (count_c[3:0] - 4'd1)) == (rd & ~(8'hFF << (sent + 4'd1))));
            if (at_c == PC_R_STORE) assert (rx_c == rd);
            // The presence pulse: the target sends a 0 and the controller reads it.
            if (at_c == PC_PRESENCE && c_exec) assert (tx_t == 0);
            if (at_c == PC_PRESENCE && !c_exec) assert (val_t == 0);
            if (at_c == PC_STORE_PRESENCE) assert (!rx_c[7]);
        end
    end
endmodule
