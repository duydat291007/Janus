// Unbounded proof by k-induction of a fourth complete protocol: the I2C
// program from protocols.py, word for word as the assembler emits it, on two
// real harts. Hart c is the controller (role C) and hart t the target (role T).
//
// It covers what the other three proofs never reach: two traps that fire on
// a line's edge only while another line is high (START and STOP), an
// address match after which a target that was not addressed steps aside as a
// witness, branches on the bit just read (the R/W bit, ACK and NACK), a
// choice on the head of the controller's queue (data, STOP or RESTART), and
// clocked bits on open-drain lines, where a hart that lets a line go waits
// until the line really rises.
//
// Free, so the result holds for every choice:
//   HALF        the half period, any value from MINHALF to 2047 ticks
//   start       the address the program is loaded at, 0 to 21
//   addr_t      the target's own address: it may or may not be the one sent
//   valid, data, ctl  both queues: any bytes and any STOP or RESTART
//               entries, arriving at any time
//   other       the two unused pins, on every tick
//   unwritten   what the other 21 program words hold
//
// Assumed:
//   - both harts leave reset on the same tick, with the program's two traps
//     set, no prescaler and no adversary fault;
//   - an entry stays at the head of the controller's queue until it pops
//     it, as in janus_fifo. The target's queue needs no such rule: the
//     target reads it only on the tick it takes the byte;
//   - SCL and SDA are open drain with pull-ups: low exactly when a hart
//     drives them low.
//
// Claims:
//   DATA   the target stores the address byte and every byte written, each
//          the one the controller took from its queue; the controller stores
//          every byte read, the one the target took, or FF when it had none.
//          The controller takes an entry only to send it, or a STOP or
//          RESTART entry that ends a write; a transaction from `idle` starts
//          only with an entry to send. The target pops only to send a byte.
//   WIRE   a monitor that sees only SCL and SDA, and knows only the textbook
//          rules, reads those same bytes, most significant bit first, the
//          address first. The target acknowledges the address only when it
//          is its own, and then every byte written; the controller's
//          acknowledge is the top bit of its queue entry. A START or STOP
//          comes only between bytes and only from the controller. Timing,
//          with HALF the half period: SCL low and high for at least HALF;
//          SDA still for HALF - 1 before SCL rises and for two ticks after
//          it falls; SCL high for HALF before a START or STOP and after a
//          START; the bus free for HALF between a STOP and the next START.
//   CLEAN  neither hart counts a violation or loses arbitration, neither
//          touches another pin, and the target never pulls SCL.
//   LIVE   a hart rests only in the states listed below. The target is at the
//          controller's word except while the controller sends START from
//          `idle`, and at the end of a write that the controller's queue ends:
//          the target does not own that choice, so it goes on to the next
//          byte and waits there until the STOP or START brings it back.
//
// tb_i2c_ind.v simulates this same module with I2C_SIM defined: the free
// signals become inputs driven at random, and every assertion is checked once
// a tick.
`ifdef I2C_SIM
module i2c_ind (input clk, input [10:0] HALF, input [5:0] start, input [31:0] unwritten,
                input [7:0] addr_c, addr_t, input [1:0] other,
                input valid_c, valid_t, input [7:0] data_c, data_t,
                input [1:0] ctl_c, ctl_t);
    parameter MINHALF = 8;

    `include "i2c_rom.vh"
`else
module i2c_ind (input clk);
    parameter MINHALF = 8;

    `include "i2c_rom.vh"

    (* anyconst *) wire [10:0] HALF;
    (* anyconst *) wire [5:0]  start;
    (* anyconst *) wire [31:0] unwritten;
    (* anyconst *) wire [7:0]  addr_c, addr_t;
    (* anyseq *)   wire [1:0]  other;
    (* anyseq *)   wire        valid_c, valid_t;
    (* anyseq *)   wire [7:0]  data_c, data_t;
    (* anyseq *)   wire [1:0]  ctl_c, ctl_t;
`endif

    // Reset: one tick of power-on reset, then two in which the host writes
    // the two trap registers while the harts are held.
    reg [1:0] step = 0;
    wire por = step == 0;
    wire rst = step < 2'd3;
    always @(posedge clk) if (rst) step <= step + 1'b1;
    wire        cfg_we = step == 2'd1 || step == 2'd2;
    wire        cfg_i = step == 2'd2;
    wire [15:0] cfg_data = i2c_trap(cfg_i, start);

    wire [7:0]  oe_c, ov_c, oe_t, ov_t, count_c, count_t, rx_c, rx_t, pin_c, pin_t, s1_c, s1_t;
    wire [7:0]  armed_c, armed_t, tx_c, tx_t, viol_c, viol_t, vout_c, vout_t, pdata_c, pdata_t;
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
    wire        lost_c, lost_t, insd_c, insd_t;
    wire [3:0]  keep_c, keep_t;

    // SCL and SDA are open drain with pull-ups: low exactly when a hart
    // drives them low. The two other pins read whatever `other` says.
    wire [1:0]  low = (oe_c[1:0] & ~ov_c[1:0]) | (oe_t[1:0] & ~ov_t[1:0]);
    wire [7:0]  bus = {4'hF, other, ~low};

    // Where each hart is in the program, counted from its first word.
    wire [5:0]  at_c = pc_c - start, at_t = pc_t - start;
    wire [31:0] ins_c = i2c_word(at_c, HALF, start, unwritten);
    wire [31:0] ins_t = i2c_word(at_t, HALF, start, unwritten);

    janus_hart c (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_c), .ov(ov_c),
        .od_mask(8'h03), .base_role(2'd0), .reset_pc(start), .addr_reg(addr_c), .pc(pc_c),
        .pc_sel(), .ins(ins_c), .tx_valid(valid_c), .tx_ctl(ctl_c), .tx_data(data_c),
        .tx_pop(pop_c), .tx_clear(clear_c), .rx_push(push_c), .seen_push(seen_c),
        .seen_push2(seen2_c), .push_data(pdata_c), .push_data2(), .violations(vout_c),
        .arb_lost(lost_c), .cfg_we(cfg_we), .cfg_addr({2'd0, cfg_i}), .cfg_data(cfg_data),
        .dbg_s(s_c), .dbg_count(count_c), .dbg_rx(rx_c), .dbg_last(last_c),
        .dbg_now(now_c), .dbg_edge(edge_c), .dbg_dwell(), .dbg_k(k_c),
        .dbg_partial(partial_c), .dbg_role(role_c), .dbg_src(src_c), .dbg_mine(mine_c),
        .dbg_val(val_c), .dbg_pin(pin_c), .dbg_s1(s1_c), .dbg_armed(armed_c),
        .dbg_code(code_c), .dbg_inserted(insd_c), .dbg_stuff_bit(), .dbg_width(),
        .dbg_viol(viol_c), .dbg_tx(tx_c), .dbg_cfg(cfg_c), .dbg_cset(cset_c),
        .dbg_cnt(cnt_c), .dbg_rx1(), .dbg_prev(prev_c), .dbg_held(), .dbg_keep(keep_c),
        .dbg_clean());

    janus_hart t (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_t), .ov(ov_t),
        .od_mask(8'h03), .base_role(2'd1), .reset_pc(start), .addr_reg(addr_t), .pc(pc_t),
        .pc_sel(), .ins(ins_t), .tx_valid(valid_t), .tx_ctl(ctl_t), .tx_data(data_t),
        .tx_pop(pop_t), .tx_clear(clear_t), .rx_push(push_t), .seen_push(seen_t),
        .seen_push2(seen2_t), .push_data(pdata_t), .push_data2(), .violations(vout_t),
        .arb_lost(lost_t), .cfg_we(cfg_we), .cfg_addr({2'd0, cfg_i}), .cfg_data(cfg_data),
        .dbg_s(s_t), .dbg_count(count_t), .dbg_rx(rx_t), .dbg_last(last_t),
        .dbg_now(now_t), .dbg_edge(edge_t), .dbg_dwell(), .dbg_k(k_t),
        .dbg_partial(partial_t), .dbg_role(role_t), .dbg_src(src_t), .dbg_mine(mine_t),
        .dbg_val(val_t), .dbg_pin(pin_t), .dbg_s1(s1_t), .dbg_armed(armed_t),
        .dbg_code(code_t), .dbg_inserted(insd_t), .dbg_stuff_bit(), .dbg_width(),
        .dbg_viol(viol_t), .dbg_tx(tx_t), .dbg_cfg(cfg_t), .dbg_cset(cset_t),
        .dbg_cnt(cnt_t), .dbg_rx1(), .dbg_prev(prev_t), .dbg_held(), .dbg_keep(keep_t),
        .dbg_clean());

    localparam S_BOOT = 4'd0, S_EXEC = 4'd1, S_CLAIM = 4'd2, S_SYNC = 4'd3, S_EDGE = 4'd4,
               S_MID = 4'd5, S_SETTLE = 4'd6, S_POST = 4'd7, S_ENTER = 4'd8, S_GAP = 4'd9,
               S_TOP = 4'd10, S_AW = 4'd11, S_AS = 4'd12, S_BW = 4'd13, S_BS = 4'd14;

    wire        c_boot = s_c == S_BOOT, c_exec = s_c == S_EXEC, c_claim = s_c == S_CLAIM;
    wire        c_edge = s_c == S_EDGE, c_mid = s_c == S_MID, c_enter = s_c == S_ENTER;
    wire        c_gap = s_c == S_GAP, c_aw = s_c == S_AW, c_as = s_c == S_AS;
    wire        c_bw = s_c == S_BW, c_bs = s_c == S_BS;
    wire        t_boot = s_t == S_BOOT, t_exec = s_t == S_EXEC, t_claim = s_t == S_CLAIM;
    wire        t_sync = s_t == S_SYNC, t_mid = s_t == S_MID, t_gap = s_t == S_GAP;
    wire        t_as = s_t == S_AS, t_bs = s_t == S_BS;

    wire [11:0] d = {1'b0, HALF};
    wire [11:0] h = {2'b00, HALF[10:1]};         // where a timed bit is sampled
    wire [11:0] r = d - h;                       // from there to the next bit's edge
    wire [11:0] since_c = now_c - edge_c, ahead_c = edge_c - now_c;
    wire [11:0] since_t = now_t - edge_t, ahead_t = edge_t - now_t;
    wire [11:0] cnt = {1'b0, cnt_c};             // ticks the controller still waits for a clock edge

    // Who pulls each line low. The target never pulls SCL.
    wire        c_scl = oe_c[0] && !ov_c[0], c_sda = oe_c[1] && !ov_c[1];
    wire        t_sda = oe_t[1] && !ov_t[1];

    // The clocked words: the controller always drives the clock, and either
    // it (address, written bytes, its own acknowledge) or the target (its
    // acknowledges and the bytes read) drives the data.
    wire        ck_cc = at_c == PC_ABYTE || at_c == PC_WBYTE || at_c == PC_RACKBIT;
    wire        ck_ct = at_c == PC_WACK || at_c == PC_WACK2 || at_c == PC_RACK || at_c == PC_RBYTE;
    wire        ck_byte = at_c == PC_ABYTE || at_c == PC_WBYTE || at_c == PC_RBYTE;
    wire        c_clk = c_aw || c_as || c_bw || c_bs || c_gap;    // a clocked bit under way
    // Bits of this word the harts have read: one at each rise of the clock.
    wire [3:0]  in_c = k_c + (c_bw || c_bs || c_gap);
    // The timed words, all the controller's own.
    wire        timed = at_c == PC_FREE || at_c == PC_START || at_c == PC_ADDR || at_c == PC_SCLLOW
                        || at_c == PC_RS_SDA || at_c == PC_RS_SCL || at_c == PC_RS_FALL
                        || at_c == PC_SP_SDA || at_c == PC_SP_SCL || at_c == PC_SP_RISE;
    // Timed words that follow another timed word: they start a bit ahead.
    wire        follows = at_c == PC_SCLLOW || at_c == PC_RS_SCL || at_c == PC_RS_FALL
                          || at_c == PC_SP_SCL || at_c == PC_SP_RISE;

    // A START or STOP as both harts see it: the trap fires on the next tick.
    wire        trap = s1_c[0] && s1_c[1] != pin_c[1];

    // The bytes in flight, following the harts' own decisions, taken from the
    // state before each tick; the assertions below tie them to the outputs.
    reg [7:0]  cur_c = 0;        // the entry the controller loaded last
    reg [7:0]  cur_t = 0;        // the byte the target loaded last
    reg        vq_c = 0;
    reg [7:0]  dq_c = 0;         // the controller's queue head one tick ago
    reg [1:0]  kq_c = 0;
    reg        took_c = 0, took_t = 0, stored_c = 0, stored_t = 0;
    reg        fresh = 0;        // the controller left `idle` for a queued byte, not yet loaded
    reg        looped = 0;       // the read went round again: the controller acknowledged
    wire       matched = cur_c[7:1] == addr_t;   // the address sent is the target's
    wire       c_loads = !rst && !trap && c_exec
                         && (at_c == PC_LOADA || at_c == PC_WLOAD || at_c == PC_RLOADACK);
    wire       c_chose = !rst && !trap && c_exec && valid_c
                         && ((at_c == PC_WCHOOSE && ctl_c == 2'd1)
                             || (at_c == PC_WRESTART && ctl_c == 2'd2));
    wire       t_loads = !rst && !trap && t_exec && role_t == 2'd1
                         && (at_t == PC_LOADACK || at_t == PC_WLOADACK || at_t == PC_RLOAD);

    always @(posedge clk) begin
        vq_c <= valid_c;
        dq_c <= data_c;
        kq_c <= ctl_c;
        took_c <= (c_loads && valid_c) || c_chose;
        took_t <= t_loads && at_t == PC_RLOAD && valid_t;
        stored_t <= !rst && !trap && t_exec && role_t == 2'd1
                    && (at_t == PC_ASTORE || at_t == PC_WSTORE);
        stored_c <= !rst && !trap && c_exec && at_c == PC_RSTORE;
        if (rst) begin
            cur_c <= 0;
            cur_t <= 0;
            fresh <= 0;
            looped <= 0;
        end else begin
            if (c_loads) cur_c <= valid_c ? data_c : 8'hFF;
            if (t_loads) cur_t <= at_t == PC_RLOAD ? (valid_t ? data_t : 8'hFF) : 8'h00;
            if (!trap && (c_claim || (c_exec && at_c == PC_IDLE)) && valid_c) fresh <= 1'b1;
            else if (c_loads) fresh <= 1'b0;
            if (!trap && c_exec && at_c == PC_RJUMP) looped <= 1'b1;
            else if (trap || (at_c == PC_RBYTE && c_exec)) looped <= 1'b0;
        end
    end

    // The bit in hand in a clocked word, most significant first, and what is
    // on SDA for it: the controller's own bit, or the target's, which is a
    // released line when the target was not addressed.
    wire [2:0]  kb = 3'd7 - k_c[2:0];
    wire        bit_on = ck_cc ? cur_c[kb] : (role_t != 2'd1 || cur_t[kb]);
    wire [7:0]  byte_on = ck_cc ? cur_c : cur_t;     // the byte of an 8-bit word
    wire [7:0]  mask_in = ~(8'hFF << in_c);         // the bits of it read so far
    wire        lock = at_t == at_c;                 // the target is at the controller's word

    // Who pulls SDA low, at each point of the program. The controller holds
    // its last bit until its next one, and lets go when the target's turn
    // comes; the target holds its acknowledge until the next byte starts.
    wire        x_csda = at_c <= PC_IDLE ? 1'b0
                       : at_c == PC_START ? c_mid
                       : at_c <= PC_LOADA ? 1'b1
                       : at_c == PC_ABYTE ? ((c_exec || c_enter) ? 1'b1 : !cur_c[kb])
                       : at_c <= PC_RW ? !cur_c[0]
                       : (at_c == PC_WACK || at_c == PC_RACK || at_c == PC_WACK2)
                         ? (c_exec && !cur_c[0])
                       : at_c == PC_WBYTE ? (!c_exec && !cur_c[kb])
                       : (at_c == PC_WSTORE || at_c == PC_WLOADACK) ? !cur_c[0]
                       : at_c == PC_RLOAD ? (looped && !cur_c[7])
                       : at_c == PC_RBYTE ? (c_exec && looped && !cur_c[7])
                       : at_c == PC_RACKBIT ? (!c_exec && !cur_c[7])
                       : (at_c == PC_RACKB2 || at_c == PC_RJUMP) ? !cur_c[7]
                       : (at_c == PC_RS_FALL || at_c == PC_SP_SDA) ? c_mid
                       : at_c == PC_SP_SCL ? 1'b1
                       : at_c == PC_SP_RISE ? !c_mid
                       : 1'b0;
    wire        t_ck = t_as || t_bs || t_gap;
    wire        t_ckt = at_t == PC_WACK || at_t == PC_WACK2 || at_t == PC_RACK || at_t == PC_RBYTE;
    wire [2:0]  kt = 3'd7 - k_t[2:0];
    wire        x_tsda = t_ck ? (t_ckt && role_t == 2'd1 && !cur_t[kt])
                       : (at_t == PC_WACKB || at_t == PC_RACKB) ? role_t == 2'd1
                       : (at_t >= PC_WCHOOSE && at_t <= PC_WBYTE) ? 1'b1
                       : (at_t == PC_WACKB2 || at_t == PC_WJUMP) ? 1'b1
                       : (at_t == PC_RLOAD || at_t == PC_RBYTE) ? !looped
                       : (at_t >= PC_RSTORE && at_t <= PC_RACKBIT) ? !cur_t[0]
                       : 1'b0;
    // SDA has held still for the two ticks the harts take to see it.
    wire        sda_steady = !c_boot && !(at_c == PC_START && c_mid)
                             && !(c_aw && cnt > d - 12'd4)
                             && !(at_c == PC_RS_SDA && c_mid && since_c <= 12'd2)
                             && !((at_c == PC_RS_FALL || at_c == PC_SP_RISE) && c_mid)
                             && !(at_c == PC_SP_SDA && c_mid && since_c <= 12'd1);

    // Where the monitor stands, from where the controller stands: bits read
    // since the START or the last acknowledge.
    wire        risen = (c_as && s1_c[0]) || c_bw || c_bs || c_gap;  // this bit is read
    wire [3:0]  x_mn = (at_c <= PC_START || at_c == PC_ADDR || at_c == PC_SCLLOW
                        || at_c == PC_LOADA) ? 4'd0
                     : ck_byte && !c_exec ? k_c + risen
                     : (at_c >= PC_ASTORE && at_c <= PC_RW) ? 4'd8
                     : (at_c == PC_WACK || at_c == PC_WACK2 || at_c == PC_RACK
                        || at_c == PC_RACKBIT) ? (risen ? 4'd0 : 4'd8)
                     : (at_c == PC_WSTORE || at_c == PC_WLOADACK) ? 4'd8
                     : (at_c == PC_RSTORE || at_c == PC_RLOADACK) ? 4'd8
                     : (at_c == PC_RS_SCL || at_c == PC_SP_SCL) ? (c_mid && since_c >= 12'd1)
                     : at_c == PC_RS_FALL ? !(c_mid && since_c >= 12'd1)
                     : at_c == PC_SP_RISE ? !(c_mid && since_c >= 12'd1)
                     : 4'd0;

    // The monitor. It samples SCL and SDA once a tick, as any device on the
    // bus could, and knows only the textbook rules: SDA falling while SCL is
    // high is a START, SDA rising while SCL is high a STOP, and otherwise a
    // bit is read as SCL rises. After a START, bits come in groups of nine: a
    // byte, most significant bit first, then an acknowledge bit, 0 for ACK.
    // The first byte after a START is the address and the R/W bit: 1 means
    // the bytes after it come from the target, and their acknowledges from
    // the controller. SCL rises once more before a STOP or a repeated START,
    // and that rise cannot be told from a byte's first bit until SDA moves.
    reg [1:0]  m_prev = 2'b11;   // {SDA, SCL} one tick ago
    reg        m_in = 0;         // between a START and a STOP
    reg [3:0]  m_n = 0;          // bits read since the START or the last acknowledge
    reg [7:0]  m_b = 0;          // the byte read so far
    reg        m_first = 0;      // the byte in hand is the address
    reg        m_rd = 0;         // this transaction is a read
    wire       m_scl = bus[0], m_sda = bus[1];
    wire       m_start = m_prev[0] && m_scl && m_prev[1] && !m_sda;
    wire       m_stop = m_prev[0] && m_scl && !m_prev[1] && m_sda;
    wire       m_read = m_in && !m_prev[0] && m_scl;      // SCL rises: a bit is read
    wire [7:0] m_byte = {m_b[6:0], m_sda};              // the byte, as its last bit is read
    wire       m_rise = !m_prev[0] && m_scl, m_fall = m_prev[0] && !m_scl;
    // How long each line had held its level up to the last tick, and the
    // ticks since the last STOP and START. They stop counting at 4095.
    reg [11:0] m_lc = 12'hFFF, m_ld = 12'hFFF, m_sp = 12'hFFF, m_st = 0;
    function automatic [11:0] inc(input [11:0] x);
        inc = x == 12'hFFF ? x : x + 1'b1;
    endfunction

    always @(posedge clk) begin
        m_prev <= {m_sda, m_scl};
        if (rst) begin
            m_lc <= 12'hFFF;
            m_ld <= 12'hFFF;
            m_sp <= 12'hFFF;
            m_st <= 0;
        end else begin
            m_lc <= m_scl != m_prev[0] ? 12'd1 : inc(m_lc);
            m_ld <= m_sda != m_prev[1] ? 12'd1 : inc(m_ld);
            m_sp <= m_stop ? 12'd1 : inc(m_sp);
            m_st <= m_start ? 12'd1 : inc(m_st);
        end
        if (rst || m_stop) begin
            m_in <= 0;
            m_n <= 0;
        end else if (m_start) begin
            m_in <= 1;
            m_n <= 0;
            m_first <= 1;
        end else if (m_read) begin
            if (m_n == 4'd8) begin
                m_n <= 0;
                m_first <= 0;
            end else begin
                m_b <= m_byte;
                m_n <= m_n + 1'b1;
                if (m_first && m_n == 4'd7) m_rd <= m_sda;
            end
        end
    end

`ifdef I2C_SIM
    always @(negedge clk) begin                  // once a tick, with everything settled
`else
    always @* begin
`endif
        assume (HALF >= MINHALF);
        assume (start <= MAX_START);
        // The controller's queue: the entry at its head stays until it is popped.
        if (vq_c && !pop_c) assume (valid_c && data_c == dq_c && ctl_c == kq_c);

        assert (step <= 2'd3);
        if (!rst) begin
            // CLEAN
            assert (viol_c == 0 && viol_t == 0 && vout_c == 0 && vout_t == 0);
            assert (!lost_c && !lost_t && !clear_c && !clear_t);
            assert (!seen_c && !seen_t && !seen2_c && !seen2_t);
            assert (keep_c == 0 && keep_t == 0 && !insd_c && !insd_t);
            // Only SCL and SDA are ever pulled low, and only the controller
            // pulls SCL.
            assert (oe_c[7:2] == 0 && oe_t[7:2] == 0 && !(oe_t[0] && !ov_t[0]));

            // DATA: what each hart takes and stores.
            assert (pop_c == took_c && pop_t == took_t);
            assert (push_t == stored_t && push_c == stored_c);
            if (push_t) assert (pdata_t == cur_c);
            if (push_c) assert (pdata_c == cur_t);
            // A transaction from `idle` starts only with a byte to send.
            if (fresh) assert (vq_c && !pop_c && at_c >= PC_START && at_c <= PC_LOADA);
            if (at_c == PC_START || (at_c == PC_LOADA && c_exec && fresh)) assert (valid_c);

            // WIRE: what the monitor is about to read.
            if (m_read && m_n == 4'd7)
                assert (m_byte == ((!m_first && m_rd) ? cur_t : cur_c));
            if (m_read && m_n == 4'd8)
                assert (m_sda == (m_first ? !matched : m_rd ? cur_c[7] : 1'b0));
            // A START or a STOP comes only between bytes, and only from the
            // controller: the target has let SDA go.
            if (m_start || m_stop) assert ((!m_in || m_n <= 4'd1) && !t_sda);
            if (m_stop) assert (m_in);
            assert (m_prev == s1_c[1:0]);
            // The textbook timing rules, with HALF as the half period: SCL
            // low and high for at least HALF; SDA still for HALF - 1 before
            // SCL rises, and moving only once SCL has been low two ticks; a
            // START or STOP only after SCL has been high for HALF; SCL held
            // high for HALF after a START; and the bus free for HALF between
            // a STOP and the next START.
            if (m_rise) assert (m_lc >= d && m_sda == m_prev[1] && m_ld >= d - 12'd1);
            if (m_fall) assert (m_lc >= d && m_sda == m_prev[1]);
            if (m_sda != m_prev[1] && !m_scl) assert (!m_prev[0] && m_lc >= 12'd2);
            if (m_start || m_stop) assert (m_lc >= d);
            if (m_fall && m_in && m_first && m_n == 0) assert (m_st >= d);
            if (m_start && !m_in) assert (m_sp >= d);

            // Fixed for the whole run.
            assert (role_c == 2'd0 && count_c == 0 && count_t == 0);
            assert (role_t == 2'd1 || (role_t == 2'd3 && !matched
                    && (at_t == PC_LOADACK || at_t == PC_RW || at_t == PC_WACK || at_t == PC_WACKB
                        || at_t == PC_RACK || at_t == PC_RACKB || at_t >= PC_SP_SDA)));
            assert (cfg_c == {80'd0, i2c_trap(1'b1, start), i2c_trap(1'b0, start)});
            assert (cfg_t == {80'd0, i2c_trap(1'b1, start), i2c_trap(1'b0, start)});
            assert (now_c == now_t && pin_c == pin_t && s1_c == s1_t);
            assert (at_c < PROG_LEN && at_t < PROG_LEN);
            assert (at_c != PC_HANG && at_c != PC_RS_JUMP && at_c != PC_SP_JUMP);
            assert (at_t != PC_HANG && at_t != PC_RS_JUMP && at_t != PC_SP_JUMP);

            // What the set-up has written so far, in each hart: only most
            // significant bit first. The clock pin and its owner keep their
            // reset values, SCL and the controller.
            assert (code_c == {63'd0, at_c > PC_MSB, 24'd0});
            assert (code_t == {63'd0, at_t > PC_MSB, 24'd0});
            assert (cset_c == {1'b0, 2'd0, 2'd3, 6'd0, 8'd0, 8'd0, 1'b0, 6'd0, 3'd0, 11'd0});
            assert (cset_t == {1'b0, 2'd0, 2'd3, 6'd0, 8'd0, 8'd0, 1'b0, 6'd0, 3'd0, 11'd0});

            // LIVE: the states a hart can rest in, and where.
            assert (c_boot || c_exec || c_claim || c_edge || c_mid || c_enter || c_clk);
            if (c_boot) assert (at_c == PC_MSB);
            if (c_claim) assert (at_c == PC_IDLE);
            if (c_edge || c_mid) assert (timed);
            if (c_enter) assert (at_c == PC_ABYTE);
            if (c_clk) assert (ck_cc || ck_ct);
            // The bit count: it stays at 7 after a byte, until the next bit
            // instruction starts.
            assert (k_c <= (ck_byte && c_clk ? 4'd7 : 4'd0) || (!c_clk && k_c == 4'd7));
            if (!c_clk) assert (k_c == (c_exec && ((at_c >= PC_ASTORE && at_c <= PC_RW)
                                                   || at_c == PC_WACK || at_c == PC_RACK
                                                   || (at_c >= PC_WSTORE && at_c <= PC_WACK2)
                                                   || (at_c >= PC_RSTORE && at_c <= PC_RACKBIT))
                                        ? 4'd7 : 4'd0));
            assert (partial_c[0] == (c_clk && k_c != 0));
            assert (partial_t[0] == ((t_as || t_bs || t_gap) && k_t != 0));

            // The controller's timing.
            if (c_aw || c_bw) assert (cnt <= d - 12'd2);
            if (c_enter) assert (ahead_c != 0 && ahead_c <= r - 12'd2);
            if (at_c == PC_ABYTE && c_exec) assert (ahead_c == r - 12'd1);
            if ((follows || at_c == PC_LOADA || at_c == PC_IDLE) && c_exec) assert (ahead_c == r);
            if (c_claim || (at_c == PC_START && c_exec)) assert (ahead_c < r);
            if (c_edge) assert ((follows || at_c == PC_START) && ahead_c != 0 && ahead_c < r);
            if (c_mid) assert (since_c < ((at_c == PC_START || at_c == PC_RS_FALL
                                           || at_c == PC_SP_RISE) ? 12'd2 : h));
            if (c_mid || c_edge) assert (mine_c && src_c == ins_c[22:21] && val_c == ins_c[21]);
            if (!(c_mid || c_edge || c_enter || c_claim
                  || (c_exec && (follows || at_c == PC_LOADA || at_c == PC_ABYTE
                                 || at_c == PC_IDLE || at_c == PC_START))))
                assert (edge_c == now_c);

            // SCL: the controller holds it low from the address on, except
            // while a bit is read and from the STOP's or RESTART's rise.
            assert (c_scl == ((at_c == PC_SCLLOW && c_mid)
                              || (at_c >= PC_LOADA && at_c <= PC_RS_SDA && !c_as && !c_bw)
                              || ((at_c == PC_RS_SCL || at_c == PC_SP_SCL) && !c_mid)
                              || at_c == PC_SP_SDA));
            if (!c_boot) begin
                if (at_c <= PC_ADDR || (at_c == PC_SCLLOW && !c_mid) || at_c == PC_RS_FALL
                        || at_c == PC_SP_RISE)
                    assert (s1_c[0] && pin_c[0]);
                if (at_c == PC_SCLLOW && c_mid)
                    assert (s1_c[0] == (since_c == 0) && pin_c[0] == (since_c <= 1));
                if ((at_c == PC_RS_SCL || at_c == PC_SP_SCL) && c_mid)
                    assert (s1_c[0] == (since_c >= 1) && pin_c[0] == (since_c >= 2));
                if ((at_c >= PC_LOADA && at_c <= PC_RS_SDA && !c_clk) || at_c == PC_SP_SDA
                        || ((at_c == PC_RS_SCL || at_c == PC_SP_SCL) && !c_mid)
                        || c_aw || c_gap)
                    assert (!s1_c[0] && !pin_c[0]);
                if (c_as) assert (!pin_c[0]);
                if (c_bw) assert (s1_c[0] && pin_c[0]);
                if (c_bs) assert (pin_c[0]);
            end

            // SDA: who pulls it low, and what the harts see of it.
            assert (c_sda == x_csda && t_sda == x_tsda);
            if (sda_steady) assert (s1_c[1] == bus[1] && pin_c[1] == bus[1]);
            if (at_c == PC_START && c_mid) assert (s1_c[1] == (since_c == 0) && pin_c[1]);
            if (at_c == PC_RS_SDA && c_mid && since_c <= 12'd2)
                assert (s1_c[1] == (since_c == 12'd2) && !pin_c[1]);
            if (at_c == PC_RS_FALL && c_mid) assert (s1_c[1] == (since_c == 0) && pin_c[1]);
            if (at_c == PC_SP_SDA && c_mid && since_c <= 12'd1)
                assert (lock ? (s1_c[1] == (since_c == 0) && pin_c[1]) : (!s1_c[1] && !pin_c[1]));
            if (at_c == PC_SP_RISE && c_mid) assert (s1_c[1] == (since_c == 12'd1) && !pin_c[1]);
            // In a clocked bit the line holds the bit from shortly after the
            // clock falls until it falls again.
            if (c_clk && !(c_aw && cnt > d - 12'd4)) assert (bus[1] == bit_on);

            // The target against the controller.
            if (at_c <= PC_IDLE || at_c == PC_ADDR || at_c == PC_LOADA
                    || (at_c >= PC_ASTORE && at_c <= PC_RW) || (at_c >= PC_WACKB && at_c <= PC_WLOAD)
                    || (at_c >= PC_WSTORE && at_c <= PC_WLOADACK) || at_c == PC_WACKB2
                    || at_c == PC_WJUMP || at_c == PC_RACKB || at_c == PC_RLOAD
                    || at_c == PC_RSTORE || at_c == PC_RLOADACK || at_c == PC_RACKB2
                    || at_c == PC_RJUMP)
                assert (lock && s_t == s_c && edge_t == edge_c);
            if (at_c == PC_START)
                assert (at_t == PC_IDLE && t_claim && edge_t == (c_mid ? now_t : edge_c));
            if (at_c == PC_SCLLOW || (lock && (at_c == PC_SP_SCL || at_c == PC_SP_RISE))) begin
                assert (lock);
                if (c_exec) assert (t_exec && edge_t == edge_c);
                if (c_edge) assert (t_sync && edge_t == edge_c);
                if (c_mid && since_c <= 12'd1) assert (t_sync && edge_t == now_t);
                if (c_mid && since_c >= 12'd2) assert (t_mid && edge_t == edge_c);
            end
            if (lock && at_c == PC_SP_SDA) assert (s_t == s_c && edge_t == edge_c);
            if (lock && at_c == PC_SP_RISE) assert (!t_mid);
            if (ck_cc || ck_ct) begin
                assert (lock && k_t == k_c && edge_t == edge_c);
                if (c_exec) assert (t_exec);
                if (c_enter || c_aw || c_as) assert (t_as);
                if (c_bw || c_bs) assert (t_bs);
                if (c_gap) assert (t_gap);
            end
            // A write ended by the controller's queue: the target does not own
            // that choice, so it goes on to the next byte and waits there for
            // the clock, until the STOP or the START brings it back.
            if (at_c >= PC_RS_SDA && at_c <= PC_RS_FALL) assert (!lock);
            if (!lock && at_c >= PC_RS_SDA) begin
                assert (role_t == 2'd1 && edge_t == now_t);
                if (at_c == PC_SP_SDA && c_exec) begin assert (at_t == PC_WRESTART && t_exec); end
                else if ((at_c == PC_SP_SDA && c_mid && since_c == 0)
                         || (at_c == PC_RS_SDA && c_exec)) begin assert (at_t == PC_WLOAD && t_exec); end
                else if ((at_c == PC_SP_SDA && c_mid && since_c == 12'd1)
                         || (at_c == PC_RS_SDA && c_mid && since_c == 0))
                    begin assert (at_t == PC_WBYTE && t_exec); end
                else assert (at_t == PC_WBYTE && k_t == 0
                             && (t_bs == ((at_c == PC_RS_SCL || at_c == PC_SP_SCL) ? c_mid && since_c >= 12'd2
                                          : (at_c == PC_RS_FALL || at_c == PC_SP_RISE)))
                             && (t_as || t_bs));
            end
            if (lock) assert (k_t == k_c);
            if (!lock) assert (k_t == 0);
            if (t_mid || t_sync) assert (!mine_t && src_t == ins_t[22:21]);
            if (t_sync) assert (val_t == ins_t[21] && armed_t[ins_t[26:25]] == !ins_t[21]);

            // The bits in flight. Both harts read every bit of a clocked
            // word, whoever sends it; the sender shifts it out of its byte.
            if (c_clk && in_c != 0) begin
                assert ((rx_c & mask_in) == ((ck_byte ? byte_on : {7'd0, bit_on}) >> (ck_byte ? 4'd8 - in_c : 4'd0)) || !ck_byte);
                assert ((rx_t & mask_in) == (rx_c & mask_in));
                if (c_bw || c_bs || c_gap) assert (last_c == bit_on && last_t == bit_on);
                if (ck_byte) assert ((rx_c & mask_in) == (byte_on >> (4'd8 - in_c)));
            end
            if (ck_cc && (c_exec || c_enter)) assert (tx_c == cur_c);
            if (ck_cc && c_clk) assert (tx_c == cur_c << (k_c + 1'b1));
            if (ck_ct && c_exec && role_t == 2'd1) assert (tx_t == cur_t);
            if (ck_ct && c_clk && role_t == 2'd1) assert (tx_t == cur_t << (k_c + 1'b1));
            if ((at_c >= PC_ASTORE && at_c <= PC_RW) || ((at_c == PC_WACK || at_c == PC_RACK) && c_exec))
                assert (rx_c == cur_c && rx_t == cur_c && last_c == cur_c[0] && last_t == cur_c[0]);
            if ((at_c >= PC_WSTORE && at_c <= PC_WLOADACK) || (at_c == PC_WACK2 && c_exec))
                assert (rx_c == cur_c && rx_t == cur_c && last_c == cur_c[0] && last_t == cur_c[0]);
            if ((at_c >= PC_RSTORE && at_c <= PC_RLOADACK) || (at_c == PC_RACKBIT && c_exec))
                assert (rx_c == cur_t && rx_t == cur_t && last_c == cur_t[0] && last_t == cur_t[0]);
            if (at_c == PC_WACKB || at_c == PC_RACKB)
                assert (last_c == (role_t != 2'd1) && last_t == last_c);
            if (at_c >= PC_WCHOOSE && at_c <= PC_WLOAD && lock) assert (role_t == 2'd1 && !last_c && !last_t);
            if (at_c == PC_WACKB2 || at_c == PC_WJUMP) assert (!last_c && !last_t);
            if (at_c == PC_RACKB2 || at_c == PC_RJUMP) assert (last_c == cur_c[7] && last_t == last_c);
            if (looped) assert (!cur_c[7] && (at_c == PC_RLOAD || (at_c == PC_RBYTE && c_exec)));
            if (at_c >= PC_WACKB && at_c <= PC_RJUMP && at_c != PC_WACK && at_c != PC_RACK
                    && !(at_c == PC_WACKB || at_c == PC_RACKB))
                assert (role_t == 2'd1);
            if (at_c >= PC_ASTORE && at_c <= PC_MATCH) assert (role_t == 2'd1 && (at_c == PC_ASTORE || c_exec));
            // After the match, the target stays addressed or steps aside, as
            // the address sent says; the address is still the controller's
            // last entry until the write loop loads the next.
            if ((at_c >= PC_LOADACK && at_c <= PC_WACKB) || at_c == PC_RACK || at_c == PC_RACKB)
                assert (role_t == (matched ? 2'd1 : 2'd3));
            // The R/W bit chose the path: 0 a write, 1 a read.
            if (at_c == PC_WACK || at_c == PC_WACKB) assert (!cur_c[0]);
            if (at_c == PC_RACK || at_c == PC_RACKB) assert (cur_c[0]);
            // An addressed target acknowledges with the 0 it loaded.
            if (((at_c >= PC_RW && at_c <= PC_WJUMP) || at_c == PC_RACK || at_c == PC_RACKB)
                    && role_t == 2'd1)
                assert (cur_t == 0);

            // The monitor against the controller.
            assert (m_in == !(at_c <= PC_IDLE || (at_c == PC_START && !(c_mid && since_c >= 12'd1))
                              || (at_c == PC_SP_RISE && c_mid && since_c >= 12'd1)));
            if (m_in) begin
                assert (m_n == x_mn);
                if (at_c <= PC_RW || (at_c == PC_RS_FALL && c_mid && since_c >= 12'd1))
                    begin assert (m_first); end
                else if (at_c == PC_WACK || at_c == PC_RACK) begin assert (m_first == !risen); end
                else assert (!m_first);
                if ((at_c >= PC_ASTORE && at_c <= PC_RW) || at_c == PC_WACK || at_c == PC_RACK
                        || (at_c == PC_ABYTE && m_n == 4'd8))
                    assert (m_rd == cur_c[0]);
                if (at_c >= PC_WACKB && at_c <= PC_WJUMP && at_c != PC_WACK) assert (!m_rd);
                if (at_c >= PC_RACKB && at_c <= PC_RJUMP) assert (m_rd);
                if (m_n != 0 && at_c >= PC_ABYTE && at_c <= PC_RJUMP)
                    assert ((m_b & ~(8'hFF << m_n))
                            == ((at_c >= PC_RBYTE && at_c <= PC_RACKBIT ? cur_t : cur_c) >> (4'd8 - m_n)));
            end

            // The monitor's clocks against where the controller stands.
            // SCL, how long it has held its level:
            if (at_c <= PC_ADDR || (at_c == PC_SCLLOW && !(c_mid && since_c != 0)))
                assert (m_lc >= d + 12'd2);
            if (at_c == PC_SCLLOW && c_mid && since_c != 0) assert (m_lc == since_c);
            if (at_c >= PC_LOADA && at_c <= PC_RJUMP && !c_clk) assert (m_lc >= 12'd3);
            if (c_aw) assert ({1'b0, m_lc} + {1'b0, cnt} >= {1'b0, d} + 13'd1);
            if (c_as) assert (s1_c[0] ? m_lc == 12'd1 : m_lc >= d + 12'd2);
            if (c_bw) assert (m_lc == d - cnt);
            if (c_bs) assert (m_lc == (s1_c[0] ? d + 12'd1 : 12'd1));
            if (c_gap) assert (m_lc == 12'd2);
            if (at_c == PC_RS_SDA || at_c == PC_SP_SDA)
                assert (c_exec ? m_lc >= 12'd3 : m_lc >= since_c + 12'd4);
            if ((at_c == PC_RS_SCL || at_c == PC_SP_SCL) && !c_mid)
                assert ({1'b0, m_lc} + {1'b0, ahead_c} >= {1'b0, d} + 13'd4);
            if ((at_c == PC_RS_SCL || at_c == PC_SP_SCL) && c_mid)
                assert (since_c == 0 ? m_lc >= d + 12'd4 : m_lc == since_c);
            if ((at_c == PC_RS_FALL || at_c == PC_SP_RISE) && !c_mid) assert (m_lc + ahead_c == d);
            if ((at_c == PC_RS_FALL || at_c == PC_SP_RISE) && c_mid) assert (m_lc == d + since_c);
            // SDA, how long it has held its level:
            if (c_aw) assert ({1'b0, m_ld} + {1'b0, cnt} + 13'd2 >= {1'b0, d});
            if (c_as && !s1_c[0]) assert (m_ld >= d - 12'd1);
            if (at_c == PC_RS_SDA && c_mid && since_c >= 12'd2) assert (m_ld >= since_c - 12'd1);
            if (at_c == PC_RS_SCL && !c_mid)
                assert ({1'b0, m_ld} + {1'b0, ahead_c} + 13'd1 >= {1'b0, d});
            if (at_c == PC_RS_SCL && c_mid && since_c == 0) assert (m_ld >= d - 12'd1);
            if (at_c == PC_SP_SDA && c_mid && since_c != 0) assert (m_ld >= since_c);
            if (at_c == PC_SP_SCL && !c_mid) assert ({1'b0, m_ld} + {1'b0, ahead_c} >= {1'b0, d});
            if (at_c == PC_SP_SCL && c_mid && since_c == 0) assert (m_ld >= d);
            // Since the last STOP, from the bus-free word to the START:
            if (at_c == PC_FREE) assert (c_exec ? m_sp >= 12'd2 : m_sp >= since_c + 12'd3);
            if (at_c == PC_IDLE || (at_c == PC_START && !c_mid))
                assert ({1'b0, m_sp} + {1'b0, ahead_c} >= {1'b0, d} + 13'd3);
            if (at_c == PC_START && c_mid) assert (m_sp >= d + 12'd3);
            // Since the last START, up to the clock's first fall:
            if ((at_c == PC_START || at_c == PC_RS_FALL) && c_mid && since_c == 12'd1)
                assert (m_st == 12'd1);
            if (at_c == PC_ADDR) assert (c_exec ? m_st == 12'd2 : m_st == since_c + 12'd3);
            if (at_c == PC_SCLLOW && !c_mid) assert (m_st + ahead_c == d + 12'd3);
            if (at_c == PC_SCLLOW && c_mid && since_c == 0) assert (m_st == d + 12'd3);
        end
    end
endmodule
