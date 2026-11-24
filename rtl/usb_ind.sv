// Unbounded proof by k-induction of the sixth complete protocol: the
// low-speed USB program from protocols.py, word for word as the assembler
// emits it, on two real harts. Hart a is the host (role 0) and has a queue;
// hart b is the device (role 1), whose only byte to send, the ACK, is in the
// program.
//
// It covers what no other proof reaches: a complementary pin pair, NRZI
// coding, stuffing of ones only, a CRC that restarts at all ones and is sent
// changed by `xor`, a CRC16 the host hart computes and sends on RESTART, break
// bits and a listener's jump on a break, a packet's type read from its PID
// into the counter, a turnaround in which the device takes the bus, and a
// hold trap that ends the host's wait for a handshake after 18 bit times.
//
// Free, so the result holds for every choice:
//   BIT         the bit time, any value from MINBIT to 2047 ticks
//   start       the address the program is loaded at, 0 to 16
//   valid, data, ctl  hart a's queue: any entries, arriving, changing or
//                     leaving at any time
//   unwritten   what the other 16 program words hold
//   other       the two pins the program does not use
//
// Assumed:
//   - both harts leave reset on the same tick, with the program's hold trap
//     set, no prescaler and no adversary fault;
//   - hart b's queue is empty;
//   - DP and DM are push-pull with the USB pull resistors: undriven, DP reads
//     0 and DM 1 (J).
//
// tb_usb_ind.v simulates this same module with USB_SIM defined: the free
// signals become inputs driven at random, and every assertion is checked once
// a tick.
`ifdef USB_SIM
module usb_ind (input clk, input [10:0] BIT, input [5:0] start, input [31:0] unwritten,
                input [1:0] other, input valid_a, input [7:0] data_a, input [1:0] ctl_a);
    parameter MINBIT = 11;

    `include "usb_rom.vh"
`else
module usb_ind (input clk);
    parameter MINBIT = 11;

    `include "usb_rom.vh"

    (* anyconst *) wire [10:0] BIT;
    (* anyconst *) wire [5:0]  start;
    (* anyconst *) wire [31:0] unwritten;
    (* anyseq *)   wire [1:0]  other;
    (* anyseq *)   wire        valid_a;
    (* anyseq *)   wire [7:0]  data_a;
    (* anyseq *)   wire [1:0]  ctl_a;
`endif

    // Reset: one tick of power-on reset, then two in which the host writes
    // the hold trap's two registers while the harts are held.
    reg [1:0] step = 0;
    wire por = step == 0;
    wire rst = step < 2'd3;
    always @(posedge clk) if (rst) step <= step + 1'b1;
    wire        cfg_we = step == 2'd1 || step == 2'd2;
    wire [2:0]  cfg_addr = step == 2'd1 ? 3'd2 : 3'd4;
    wire [15:0] cfg_data = step == 2'd1 ? usb_hold(start) : usb_hold_ticks(BIT);

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

    // DP (pin 0) and DM (pin 1) are push-pull. Undriven, the pull resistors
    // hold the line in J: DP 0, DM 1. Two drivers never meet (a claim below),
    // so which one wins does not matter.
    wire        dp = oe_a[0] ? ov_a[0] : oe_b[0] ? ov_b[0] : 1'b0;
    wire        dm = oe_a[1] ? ov_a[1] : oe_b[1] ? ov_b[1] : 1'b1;
    wire [7:0]  bus = {4'hF, other, dm, dp};

    wire [5:0]  at_a = pc_a - start, at_b = pc_b - start;
    wire [31:0] ins_a = usb_word(at_a, BIT, start, unwritten);
    wire [31:0] ins_b = usb_word(at_b, BIT, start, unwritten);

    janus_hart a (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_a), .ov(ov_a),
        .od_mask(8'h00), .base_role(2'd0), .reset_pc(start), .addr_reg(8'd0), .pc(pc_a),
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
        .od_mask(8'h00), .base_role(2'd1), .reset_pc(start), .addr_reg(8'd0), .pc(pc_b),
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

    localparam S_BOOT = 4'd0, S_EXEC = 4'd1, S_CLAIM = 4'd2, S_SYNC = 4'd3, S_EDGE = 4'd4,
               S_MID = 4'd5, S_SETTLE = 4'd6, S_POST = 4'd7;

    wire [11:0] d = {1'b0, BIT};
    wire [11:0] h = {2'b00, BIT[10:1]};          // where a bit is sampled

    // ---- What the host took ----
    // The byte hart a loaded last (0xFF from an empty queue), and whether it
    // ended the packet in hand with RESTART, so that the chip sends its CRC.
    reg [7:0]  g_tk = 0;
    reg        g_rst = 0;
    wire       a_ld = !rst && s_a == S_EXEC && (at_a == PC_PLOAD || at_a == PC_BLOAD);
    wire       a_crst = !rst && s_a == S_EXEC && at_a == PC_CRST && valid_a && ctl_a == 2'd2;

    // ---- The monitor ----
    // It samples DP and DM once a tick and knows only the textbook rules for
    // a low-speed packet: the idle line is J; a change to K starts a packet;
    // each bit lasts BIT ticks and is read in its middle; a bit is 0 when the
    // line changes between J and K and 1 when it stays; after six 1s comes a
    // stuffed 0, which is not part of the packet; the packet is SYNC
    // (00000001), a PID byte and any further bytes, least significant bit
    // first, and ends with SE0 for two bit times, then J. The CRC16 of the
    // bytes after the PID, CRC field included, leaves the residual 0x800D. A
    // PID whose two lowest bits are 1 marks a data packet, which a device
    // answers with ACK when its CRC16 checks.
    localparam [1:0] L_SE0 = 2'b00, L_K = 2'b01, L_J = 2'b10, L_SE1 = 2'b11;
    localparam [1:0] M_IDLE = 2'd0, M_PKT = 2'd1, M_SE0 = 2'd2;
    wire [1:0] ln = {dm, dp};
    reg  [1:0] m_prev = L_J;      // the line one tick ago
    reg  [1:0] m_st = M_IDLE;
    reg [10:0] m_t = 0;           // ticks into this bit, from its first
    reg  [1:0] m_cur = L_J;       // this bit's line state, as read in its middle
    reg        m_lvl = 1'b1;      // DM in the bit before: what NRZI compares with
    reg  [2:0] m_run = 0;         // 1s in a row before this bit, stuffing counted
    reg  [1:0] m_ph = 0;          // 0 SYNC, 1 PID, 2 the bytes after it
    reg  [2:0] m_bi = 0;          // bits of SYNC or of the byte in hand before this one
    reg  [7:0] m_sh = 0;          // the byte in hand, as read so far
    reg [15:0] m_crc = 0;         // the CRC16 of the bytes after the PID
    reg        m_dev = 0;         // this packet is the device's
    reg  [7:0] m_nb = 0;          // bytes after the PID, counted up to 255
    reg  [7:0] m_byte = 0;        // the last byte read
    // The host's packet is a data packet: its PID's first two bits, its two
    // lowest, are both 1 (DATA0, DATA1, DATA2, MDATA). After one, whether the
    // device's handshake is due; 'bad' counts data packets with a bad CRC16,
    // which every hart counts as a violation.
    reg        m_data = 0, m_due = 0, m_fr = 0;
    reg  [7:0] m_nbad = 0;
    reg [15:0] m_jr = 0;          // J ticks in a row up to the last, saturating
    reg [15:0] m_it = 0;          // ticks since the last packet ended, saturating
    reg  [1:0] m_nc = 0;          // bytes read since the host chose RESTART

    wire       m_sample = m_st != M_IDLE && m_t == h[10:0];   // read this bit now
    wire       m_end = m_st != M_IDLE && m_t == BIT - 1'b1;   // this bit's last tick
    wire [1:0] m_s = m_sample ? ln : m_cur;                   // this bit, once read
    wire       m_b = m_s[1] == m_lvl;                         // its NRZI value
    wire       m_stuff = m_run == 3'd6;                       // a stuffed bit
    wire [7:0] m_bytev = {m_b, m_sh[7:1]};                    // the byte, with this bit
    wire       m_bdone = m_st == M_PKT && m_s != L_SE0 && !m_stuff && m_ph != 0 && m_bi == 3'd7;
    wire [15:0] m_crc_next = {m_crc[14:0], 1'b0} ^ ((m_b ^ m_crc[15]) ? 16'h8005 : 16'h0);
    wire       m_sop = m_st == M_IDLE && ln == L_K;          // a packet starts
    wire       m_eop_end = m_st == M_SE0 && m_end;           // its last SE0 tick
    // The hold trap's length, 18 bit times.
    wire [15:0] tmo_t = 16'd18 * {5'd0, BIT};
    wire       low_a = oe_a[1] && !ov_a[1], low_b = oe_b[1] && !ov_b[1];

    reg  [1:0] m_p2 = L_J, m_p3 = L_J;   // the line two and three ticks ago
    always @(posedge clk) begin
        m_prev <= ln;
        m_p2 <= m_prev;
        m_p3 <= m_p2;
        if (m_sample) m_cur <= ln;
        if (rst) begin
            m_st <= M_IDLE;
            m_t <= 0;
            m_jr <= 0;
            m_it <= 0;
        end else begin
            m_jr <= ln != L_J ? 16'd0 : m_jr == 16'hFFFF ? m_jr : m_jr + 1'b1;
            m_it <= (m_st != M_IDLE || m_sop) ? 16'd0 : m_it == 16'hFFFF ? m_it : m_it + 1'b1;
            if (m_st == M_IDLE) begin
                if (m_sop) begin
                    m_st <= M_PKT;
                    m_t <= 11'd1;
                    m_lvl <= 1'b1;
                    m_run <= 0;
                    m_ph <= 0;
                    m_bi <= 0;
                    m_nb <= 0;
                    m_dev <= low_b;
                    m_fr <= 1'b1;
                    if (!low_b) m_data <= 1'b0;
                end
            end else begin
                m_t <= m_end ? 11'd0 : m_t + 1'b1;
                // The type, from the PID's first two bits: the first is at the
                // top of the byte in hand as the second is read.
                if (m_sample && m_st == M_PKT && !m_dev && m_ph == 2'd1 && m_bi == 3'd1 && !m_stuff)
                    m_data <= m_sh[7] && m_b;
                if (m_end && m_st == M_PKT) begin
                    if (m_s == L_SE0) m_st <= M_SE0;
                    else begin
                        m_lvl <= m_s[1];
                        if (m_stuff) m_run <= 0;
                        else begin
                            m_run <= m_b ? m_run + 1'b1 : 3'd0;
                            m_bi <= m_bi + 1'b1;
                            if (m_ph != 0) m_sh <= m_bytev;
                            if (m_ph == 2'd2) m_crc <= m_crc_next;
                            if (m_bi == 3'd7) begin
                                if (m_ph != 2'd2) m_ph <= m_ph + 1'b1;
                                if (m_ph == 2'd1) m_crc <= 16'hFFFF;
                                if (m_ph == 2'd2 && m_nb != 8'hFF) m_nb <= m_nb + 1'b1;
                            end
                        end
                    end
                end
                if (m_eop_end) begin
                    m_st <= M_IDLE;
                    if (m_dev) m_due <= 1'b0;
                    else if (m_data) begin
                        // A data packet: the device answers a good CRC16.
                        if (m_crc == 16'h800D) m_due <= 1'b1;
                        else if (m_nbad != 8'hFF) m_nbad <= m_nbad + 1'b1;
                    end
                end
            end
        end
    end

    // The host's byte and its RESTART, as it takes them; a packet's start
    // clears the RESTART.
    reg  [7:0] g_pid = 0;          // the PID byte of the host's packet in hand
    wire [1:0] pid_lo = g_pid[1:0];
    always @(posedge clk) begin
        if (a_ld && at_a == PC_PLOAD) g_pid <= valid_a ? data_a : 8'hFF;
        if (a_ld) g_tk <= valid_a ? data_a : 8'hFF;
        if ((a_ld && at_a == PC_PLOAD) || (!rst && m_st == M_IDLE && ln == L_K)) g_rst <= 1'b0;
        if (a_crst) g_rst <= 1'b1;
    end

    // Each byte as it is read, in its last bit's middle: the harts store it
    // and decide on it within a few ticks, well before the bit ends. The
    // device stores each byte it reads; the host stores the ACK.
    reg        m_pend = 0;        // a byte read and not yet stored
    always @(posedge clk) begin
        if (m_sample && m_bdone) m_byte <= m_bytev;
        if (rst) m_pend <= 0;
        else if (m_sample && m_bdone) m_pend <= 1'b1;
        else if (push_a || push_b) m_pend <= 1'b0;
        if (rst || m_eop_end) m_nc <= 0;
        else if (m_sample && m_bdone && m_ph == 2'd2 && g_rst && m_nc != 2'd3) m_nc <= m_nc + 1'b1;
    end

    // ---- Ghosts: what the harts keep, from the line ----
    // The coder as the harts run it: a CRC register restarted at all ones by
    // `stuff` before a host packet and by `width` after its PID, and a run of
    // equal bits of either value (four bits, so a long run of 0s wraps; only
    // a run of six 1s is stuffed). It runs on through the two bits of J after
    // the end of packet, and through the device's packet, which the same bits
    // always follow: these registers stay as the host's last data bit left
    // them, and the functions below take the rest.
    reg [15:0] g_scrc = 0;        // the CRC over SYNC and the PID
    reg  [3:0] g_rl = 0;
    reg        g_rval = 0, g_rv = 0;
    // What the harts' coders held between the last packet and this one.
    reg [23:0] f_code = {16'hFFFF, 8'h00};
    // Each hart has run `stuff`: its coder is on from then on.
    // (The hold trap can fire on the tick a host would run it: it has run once
    // the hart is past it.)
    reg        g_sta0 = 0, g_stb0 = 0;
    wire       g_sta = g_sta0 || (at_a > PC_STUFF && at_a < PC_END);
    wire       g_stb = g_stb0 || (at_b > PC_STUFF && at_b < PC_END);
    // The coder (CRC, run, run valid, run value) with one more bit.
    function automatic [21:0] cod_step(input [21:0] c, input x);
        cod_step = {{c[20:6], 1'b0} ^ ((x ^ c[21]) ? 16'h8005 : 16'h0),
                    (c[1] && c[0] == x) ? c[5:2] + 4'd1 : 4'd1, 1'b1, x};
    endfunction
    // After a data packet whose CRC16 checks, and its two bits of J, the CRC
    // holds 0x003E and the run is one 1. After n more bits: the device's SYNC
    // and ACK, then the two bits of J after its end of packet.
    function automatic [21:0] ack_code(input [4:0] n);
        reg [17:0] x;
        reg [21:0] c;
        integer i;
        begin
            x = 18'h2D280;                   // 0000000 1, D2, 0 1, first bit lowest
            c = {16'h003E, 4'd1, 2'b11};
            for (i = 0; i < 18; i = i + 1)
                if (i < n) c = cod_step(c, x[i]);
            ack_code = c;
        end
    endfunction
    // Between packets, once both bits of J have been read.
    wire [21:0] gap_cod = m_dev ? ack_code(5'd18)
                          : cod_step(cod_step({m_crc, g_rl, g_rval, g_rval && g_rv}, 1'b0), 1'b1);
    wire [23:0] gap_code = (!m_fr && at_a <= PC_WIDTH0) ? 24'd0 : !m_fr ? {16'hFFFF, 8'h00} : {gap_cod, 2'b00};
    wire       c_data = m_st == M_PKT && m_end && m_s != L_SE0 && !m_dev;   // the coder takes a bit
    always @(posedge clk) begin
        if (rst) begin
            g_rl <= 0;
            g_rval <= 0;
        end else if (m_sop && !low_b) begin
            g_scrc <= 16'hFFFF;
            g_rl <= 0;
            g_rval <= 0;
        end else if (c_data) begin
            g_rval <= 1'b1;
            if (m_stuff) begin
                g_rl <= 4'd1;
                g_rv <= 1'b0;
            end else begin
                g_rl <= (g_rval && g_rv == m_b) ? g_rl + 1'b1 : 4'd1;
                g_rv <= m_b;
                if (m_ph != 2'd2) g_scrc <= {g_scrc[14:0], 1'b0} ^ ((m_b ^ g_scrc[15]) ? 16'h8005 : 16'h0);
            end
        end
        if (!rst && m_sop) f_code <= gap_code;
        {g_sta0, g_stb0} <= rst ? 2'b00 : {g_sta, g_stb};
    end

    // Whether the byte in hand is the chip's CRC16: the host's choice is made
    // by the time the byte's first bit starts, after its last instruction.
    reg        m_crcb = 0;
    wire [2:0] n_bi = m_stuff ? m_bi : m_bi + 1'b1;
    wire [1:0] n_ph = (!m_stuff && m_bi == 3'd7 && m_ph != 2'd2) ? m_ph + 1'b1 : m_ph;
    wire [2:0] n_run = m_stuff ? 3'd0 : m_b ? m_run + 1'b1 : 3'd0;
    always @(posedge clk) begin
        if (rst || m_sop) m_crcb <= 1'b0;
        else if (m_st == M_PKT && m_end && m_s != L_SE0 && n_ph == 2'd2 && n_bi == 0 && n_run != 3'd6)
            m_crcb <= g_rst;
    end

    // The bits after a packet's end of packet: cell c from its tick 0, in
    // which the sender drives J (the host twice), until the next packet.
    reg  [1:0] m_tc = 2'd3;
    reg [10:0] m_tt = 0;
    always @(posedge clk) begin
        if (rst || m_sop) begin
            m_tc <= 2'd3;
            m_tt <= 0;
        end else if (m_eop_end) begin
            m_tc <= 0;
            m_tt <= 0;
        end else if (m_st == M_IDLE && m_tc != 2'd3) begin
            m_tt <= m_tt == BIT - 1'b1 ? 11'd0 : m_tt + 1'b1;
            if (m_tt == BIT - 1'b1) m_tc <= m_tc + 1'b1;
        end
    end

    // The J run one tick ago, which each hart's hold counter has seen, and
    // whether each hart pulled DM low a tick ago, which its counter sees.
    // Reset loads both of a hart's input stages from the line, so until the
    // harts first see DM low the counter runs a tick ahead of the J run it
    // has seen: it counts the ticks since reset.
    reg [15:0] m_jr1 = 0;
    reg        low_a1 = 0, low_b1 = 0, g_fell = 0;
    always @(posedge clk) begin
        m_jr1 <= m_jr;
        {low_a1, low_b1} <= {low_a, low_b};
        if (rst) g_fell <= 1'b0;
        else if (!pin_a[1]) g_fell <= 1'b1;
    end
    // The last fall of DM on the line and its age, counted wide (a bit can
    // be longer than half the range of the harts' 12-bit clock), the one
    // before it, and whether each happened since reset. The harts see a fall
    // two ticks late: one tick after g_fa restarts.
    reg [15:0] g_fa = 16'hFFFF, g_fb = 16'hFFFF;
    reg        g_fv = 0, g_fbv = 0;
    always @(posedge clk) begin
        if (rst) begin
            g_fa <= 16'hFFFF;
            g_fb <= 16'hFFFF;
            g_fv <= 1'b0;
            g_fbv <= 1'b0;
        end else if (m_prev[1] && !ln[1]) begin
            g_fa <= 0;
            g_fv <= 1'b1;
            g_fb <= g_fa == 16'hFFFF ? g_fa : g_fa + 1'b1;
            g_fbv <= g_fv;
        end else begin
            if (g_fa != 16'hFFFF) g_fa <= g_fa + 1'b1;
            if (g_fb != 16'hFFFF) g_fb <= g_fb + 1'b1;
        end
    end
    wire        f_new = g_fv && g_fa != 0;                    // the harts have seen the last fall
    wire        f_seen = f_new || g_fbv;                      // they have seen one
    wire [15:0] f_age = f_new ? g_fa - 1'b1 : g_fb - 1'b1;    // ticks since they saw it
    wire [15:0] held_v = g_fell ? m_jr1 : (s_a == S_BOOT || !pin_a[1]) ? 16'd0
                         : m_jr1 == 16'hFFFF ? m_jr1 : m_jr1 + 1'b1;
    // The device's hold trap fires on a host packet's second tick, before it
    // sees the K, when DM had then been high for 18 bit times as it counts.
    reg        m_late = 0;
    wire [15:0] held_nx = g_fell ? m_jr : (m_jr == 16'hFFFF ? m_jr : m_jr + 1'b1);
    always @(posedge clk) begin
        if (rst || m_eop_end) m_late <= 1'b0;
        else if (m_sop) m_late <= !low_b && held_nx == tmo_t;
    end


    // ---- The monitor two ticks ago, for the listener ----
    // A bit is at least 11 ticks, so two ticks back is this bit, or the end
    // of the bit before, which these registers keep.
    reg  [1:0] p_st = 0, p_ph = 0, p_line = 0, p_nc = 0;
    reg  [2:0] p_bi = 0, p_run = 0;
    reg  [7:0] p_sh = 0, p_nb = 0;
    reg [15:0] p_crc = 0, p_scrc = 0;
    reg        p_lvl = 0, p_rval = 0, p_rv = 0, p_crcb = 0;
    reg  [3:0] p_rl = 0;
    always @(posedge clk)
        if (m_end) begin
            {p_st, p_ph, p_line, p_nc, p_bi, p_run, p_sh, p_nb} <= {m_st, m_ph, ln, m_nc, m_bi, m_run, m_sh, m_nb};
            {p_crc, p_scrc, p_lvl, p_rval, p_rv, p_rl, p_crcb} <= {m_crc, g_scrc, m_lvl, g_rval, g_rv, g_rl, m_crcb};
        end
    wire        m_cell0 = m_st == M_PKT && m_ph == 0 && m_bi == 0;   // a packet's first bit
    // After a packet, its J bits (tail cells) count as bits too.
    wire        m_tail = m_st == M_IDLE && m_tc != 2'd3;
    wire [10:0] m_ct = m_st == M_IDLE ? m_tt : m_t;                  // ticks into this bit
    wire        o_now = (m_st != M_IDLE || m_tail) && m_ct >= 11'd2;  // two ticks back is in this bit
    wire        o_prev = ((m_st != M_IDLE && !m_cell0) || (m_tail && m_tc == 0)) && m_ct < 11'd2;
    wire        o_pt = m_tail && m_tc != 0 && m_ct < 11'd2;          // the tail bit before
    wire [1:0]  o_st = o_now ? m_st : o_prev ? p_st : M_IDLE;
    wire [10:0] o_t = o_now ? m_ct - 11'd2 : m_ct + BIT - 11'd2;
    wire [1:0]  o_tc = o_pt ? m_tc - 1'b1 : o_now ? m_tc : 2'd3;
    wire [1:0]  o_ph = o_now ? m_ph : p_ph, o_nc = o_now ? m_nc : p_nc;
    wire [2:0]  o_bi = o_now ? m_bi : p_bi, o_run = o_now ? m_run : p_run;
    wire [7:0]  o_sh = o_now ? m_sh : p_sh, o_nb = o_now ? m_nb : p_nb;
    wire [15:0] o_crc = o_now ? m_crc : p_crc, o_scrc = o_now ? g_scrc : p_scrc;
    wire        o_lvl = o_now ? m_lvl : p_lvl, o_rval = o_now ? g_rval : p_rval, o_rv = o_now ? g_rv : p_rv;
    wire [3:0]  o_rl = o_now ? g_rl : p_rl;
    wire        o_crcb = o_now ? m_crcb : p_crcb;
    wire        p_b = p_line[1] == p_lvl;                         // the bit before, its NRZI value
    function automatic [15:0] crc_step16(input [15:0] c, input x);
        crc_step16 = {c[14:0], 1'b0} ^ ((x ^ c[15]) ? 16'h8005 : 16'h0);
    endfunction

    // ---- Each hart against the monitor: the sender now, the listener two
    // ticks late ----
    wire        snd_a = !m_dev, snd_b = m_dev;
    // A view covers a packet's bits, its end of packet and its two J bits.
    wire        s_in = m_st != M_IDLE || (m_tail && m_tc <= 2'd1);
    wire        o_in = o_st != M_IDLE || o_tc <= 2'd1;
    wire        v_en_a = snd_a ? s_in : o_in;
    wire        v_en_b = snd_b ? s_in : o_in;
    usb_view va (.clk_v(clk), .en(!rst && v_en_a), .snd(snd_a), .dev(m_dev), .who(1'b0), .BIT(BIT),
        .st(snd_a ? m_st : o_st), .t(snd_a ? m_ct : o_t), .ph(snd_a ? m_ph : o_ph), .bi(snd_a ? m_bi : o_bi),
        .run(snd_a ? m_run : o_run), .sh(snd_a ? m_sh : o_sh), .crc(snd_a ? m_crc : o_crc),
        .scrc(snd_a ? g_scrc : o_scrc), .lvl(snd_a ? m_lvl : o_lvl), .line(snd_a ? ln : m_p2),
        .rl(snd_a ? g_rl : o_rl), .rval(snd_a ? g_rval : o_rval), .rv(snd_a ? g_rv : o_rv),
        .nc(snd_a ? m_nc : o_nc), .nb(snd_a ? m_nb : o_nb), .crcb(snd_a ? m_crcb : o_crcb), .tc(snd_a ? m_tc : o_tc), .data(m_data), .late(m_late),
        .fcode(f_code), .gtk(g_tk), .lfv(cset_a[13]), .lf_age(f_age),
        .at(at_a), .s(s_a), .k(k_a), .code(code_a[23:0]), .rx(rx_a), .now(now_a), .edge_t(edge_a),
        .mine(mine_a), .val(val_a), .src(src_a), .oe(oe_a[1:0]), .ov(ov_a[1:0]), .armed(armed_a[1:0]),
        .ins(ins_a));
    usb_view vb (.clk_v(clk), .en(!rst && v_en_b), .snd(snd_b), .dev(m_dev), .who(1'b1), .BIT(BIT),
        .st(snd_b ? m_st : o_st), .t(snd_b ? m_ct : o_t), .ph(snd_b ? m_ph : o_ph), .bi(snd_b ? m_bi : o_bi),
        .run(snd_b ? m_run : o_run), .sh(snd_b ? m_sh : o_sh), .crc(snd_b ? m_crc : o_crc),
        .scrc(snd_b ? g_scrc : o_scrc), .lvl(snd_b ? m_lvl : o_lvl), .line(snd_b ? ln : m_p2),
        .rl(snd_b ? g_rl : o_rl), .rval(snd_b ? g_rval : o_rval), .rv(snd_b ? g_rv : o_rv),
        .nc(snd_b ? m_nc : o_nc), .nb(snd_b ? m_nb : o_nb), .crcb(snd_b ? m_crcb : o_crcb), .tc(snd_b ? m_tc : o_tc), .data(m_data), .late(m_late),
        .fcode(f_code), .gtk(g_tk), .lfv(cset_b[13]), .lf_age(f_age),
        .at(at_b), .s(s_b), .k(k_b), .code(code_b[23:0]), .rx(rx_b), .now(now_b), .edge_t(edge_b),
        .mine(mine_b), .val(val_b), .src(src_b), .oe(oe_b[1:0]), .ov(ov_b[1:0]), .armed(armed_b[1:0]),
        .ins(ins_b));

    // ---- Where the harts stand ----
    localparam S_FETCH = 4'd15;
    wire [11:0] tq = {1'b0, m_t};
    wire [1:0]  m_pl = m_st == M_SE0 ? L_SE0 : {m_lvl, !m_lvl};    // the line in the bit before
    wire        a_exec = s_a == S_EXEC, a_claim = s_a == S_CLAIM, a_sync = s_a == S_SYNC;
    wire        a_edge = s_a == S_EDGE, a_mid = s_a == S_MID;
    wire        b_exec = s_b == S_EXEC, b_claim = s_b == S_CLAIM, b_sync = s_b == S_SYNC;
    wire        b_edge = s_b == S_EDGE, b_mid = s_b == S_MID;
    wire [11:0] since_a = now_a - edge_a, ahead_a = edge_a - now_a;
    wire [11:0] since_b = now_b - edge_b, ahead_b = edge_b - now_b;
    // Whether a hart of role r owns a bit of party p, as the hart decides it.
    function automatic mine_of(input [1:0] p, input [1:0] r);
        mine_of = p == 2'd2 ? r != 2'd3 : r == p;
    endfunction
    // The settings the mode words make, by how far a hart is into the
    // program: they all run once, from reset, before `top`.
    function automatic [36:0] cfg_of(input [5:0] at);
        cfg_of = {at > PC_PAIR ? 3'b100 : 3'b000, at > PC_NRZI, at > PC_XOR ? 16'h9555 : 16'h0,
                  at > PC_RESID ? 16'h003E : 16'h0, at > PC_WIDTH0};
    endfunction
    function automatic [21:0] cfg2_of(input [5:0] at);
        cfg2_of = {at > PC_POLY ? 16'h8005 : 16'h0, at > PC_WIDTH0 ? 5'd16 : 5'd0, 1'b0};
    endfunction
    function automatic [47:0] cset_of(input [5:0] at, input [5:0] st, input lfv);
        reg [5:0] err, brk;
        begin
            err = PC_END + st;
            brk = PC_EOP2 + st;
            cset_of = {at > PC_RESYNC ? 3'b101 : 3'b000, 2'd3, at > PC_ONERR ? err : 6'd0, 16'd0,
                       at > PC_ONBRK ? {1'b1, brk} : 7'd0, lfv, 13'd0};
        end
    endfunction
    // The CRC16 register's pattern after k bits of the chip's CRC16: each
    // bit sent feeds back `xor`'s bit k, whatever the register held.
    function automatic [15:0] crc_f(input [4:0] k);
        reg [15:0] f, x;
        integer i;
        begin
            f = 0;
            x = 16'h9555;
            for (i = 0; i < 16; i = i + 1)
                if (i < k) f = {f[14:0], 1'b0} ^ (x[i] ? 16'h8005 : 16'h0);
            crc_f = f;
        end
    endfunction
    // The run of 1s before bit i of the device's packet: SYNC ends with a 1,
    // and ACK (0xD2) is sent least significant bit first.
    function automatic [2:0] ack_run(input [1:0] f, input [2:0] i);
        reg [7:0] r;
        begin
            r = 8'b10100101;                 // 1 before bits 0, 2, 5, 7
            ack_run = f == 0 ? 3'd0 : f == 2'd2 ? 3'd2 : {2'b00, r[i]};
        end
    endfunction
    // The monitor counts a CRC byte as it reads its last bit; the bits of
    // the CRC16 taken so far.
    wire [1:0]  c_nc = (m_bi == 3'd7 && !m_stuff && tq > h) ? m_nc - 1'b1 : m_nc;
    wire [4:0]  kc = {c_nc, 3'b000} + {2'b00, m_bi};
    // ---- Between packets: what the last packet was ----
    wire        g0 = !m_fr;                                   // none since reset
    wire        gap = m_st == M_IDLE && m_fr;
    wire        g1 = gap && !m_dev && !m_data;                // a host packet, not a data packet
    wire        g2 = gap && !m_dev && m_data && m_due;        // a data packet with a good CRC16
    wire        g3 = gap && !m_dev && m_data && !m_due;       // one with a bad CRC16
    wire        g4 = gap && m_dev;                            // the handshake
    wire [15:0] it = m_it, hh = {4'd0, h}, dw = {4'd0, d};
    // Each hart reads the packet's last J bit, the second after its end of
    // packet, in its middle, the listener two ticks after the sender; after
    // the handshake that bit is the host's, and the host is the one two ticks
    // late.
    wire [15:0] base_a = g4 ? dw + hh + 16'd2 : dw + hh, base_b = g4 ? dw + hh : dw + hh + 16'd2;
    wire        rd_a = g0 || it >= base_a, rd_b = g0 || it >= base_b;
    wire [15:0] q_a = it - base_a, q_b = it - base_b;
    // The hold trap fires once DM has been high for 18 bit times; with no
    // handshake due, each hart claims again on the next tick.
    wire        fired = held_v >= tmo_t;
    wire [15:0] r_tr = held_v - tmo_t;
    // (A hart that pulls DM low itself does not count it as held: on a host
    // packet's second tick only the device's trap can fire.)
    wire        tr_a = fired && r_tr == 0 && !low_a1, tr_b = fired && r_tr == 0 && !low_b1;
    // The instructions each hart runs after that read, one a tick. All but a
    // good data packet end with `end`: both pins let go, the counter to 0.
    function automatic [5:0] rel_at(input [15:0] q);
        rel_at = q == 0 ? PC_END : q == 16'd1 ? PC_END2 : q == 16'd2 ? PC_LOOP : PC_TMO;
    endfunction
    function automatic [5:0] seq_at(input [2:0] g, input [15:0] q, input [5:0] at0);
        case (g)
            3'd1: seq_at = q == 0 ? PC_NODATA : rel_at(q - 16'd1);
            3'd2: seq_at = q == 0 ? PC_NODATA : q == 16'd1 ? PC_CRCBAD : q == 16'd2 ? PC_ALOAD : PC_ASYNC0;
            3'd3: seq_at = q == 0 ? PC_NODATA : q == 16'd1 ? PC_CRCBAD : rel_at(q - 16'd2);
            3'd4: seq_at = rel_at(q);
            default: seq_at = at0;      // from reset: the mode words, then the claim
        endcase
    endfunction
    wire [2:0]  gsel = g1 ? 3'd1 : g2 ? 3'd2 : g3 ? 3'd3 : g4 ? 3'd4 : 3'd0;
    wire [15:0] sq_len = g1 ? 16'd5 : g2 ? 16'hFFFF : g3 ? 16'd6 : g4 ? 16'd4 : 16'd0;
    wire        sq_a = g0 ? at_a < PC_CLAIM : q_a < sq_len;
    wire        sq_b = g0 ? at_b < PC_CLAIM : q_b < sq_len;
    // Each hart's next edge: a bit after the J it read, unless the hold trap
    // has fired since, or none has been read since reset.
    wire [15:0] e_a = g4 ? dw + dw + 16'd2 : dw + dw, e_b = g4 ? dw + dw : dw + dw + 16'd2;
    wire [11:0] ah_a = (g0 || fired || it >= e_a) ? 12'd0 : e_a[11:0] - it[11:0];
    wire [11:0] ah_b = (g0 || fired || it >= e_b) ? 12'd0 : e_b[11:0] - it[11:0];
    // In the run: the instruction due, executing, except while the handshake
    // waits: the host for the device's SYNC, the device for its edge.
    wire        hs_wait_a = g2 && q_a >= 16'd4, hs_wait_b = g2 && q_b >= 16'd4;
    // From reset both run the mode words in step, one a tick, with their
    // edges at `now`.
    wire        boot_ok_a = ((s_a == S_BOOT && at_a == 0 && now_a == 0) || (a_exec && now_a == {6'd0, at_a} + 12'd1))
                            && at_a == at_b && s_a == s_b && ahead_a == 0 && ahead_b == 0 && it == {4'd0, now_a};
    wire        boot_ok_b = boot_ok_a;
    wire        sq_ok_a = g0 ? boot_ok_a && at_a == at_b && s_a == s_b
                          : hs_wait_a ? (a_sync && at_a == PC_ASYNC0 && k_a == 0 && !mine_a && !val_a && src_a == 2'b10
                                         && ahead_a == ah_a)
                          : (a_exec && at_a == seq_at(gsel, q_a, at_a));
    wire        sq_ok_b = g0 ? boot_ok_b
                          : hs_wait_b ? (b_edge && at_b == PC_ASYNC0 && k_b == 0 && mine_b && !val_b && src_b == 2'b10
                                         && ahead_b == ah_b && ah_b != 0)
                          : (b_exec && at_b == seq_at(gsel, q_b, at_b));
    // Claiming: the host may pass its claim at any tick it has something
    // queued, run `stuff`, and wait at SYNC's first bit for its edge; the
    // device waits for the line to fall.
    wire        cf_a = (at_a == PC_CLAIM && (a_claim || a_exec)) || (at_a == PC_STUFF && a_exec)
                       || (at_a == PC_SYNC0 && (a_exec || (a_edge && ahead_a != 0 && k_a == 0 && mine_a
                                                           && !val_a && src_a == 2'b10)));
    wire        cf_b = at_b == PC_CLAIM && (b_claim || b_exec);
    // The host's drive after it reads the last J: J until `end` lets go, DM
    // and a tick later DP, or until its edge when a handshake is due; none
    // from reset until its first packet.
    wire [15:0] rel_a = g1 ? 16'd1 : g3 ? 16'd2 : 16'd0;        // when it runs `end`
    wire [1:0]  oe_ea = g0 ? 2'b00 : g2 ? (it < dw + dw ? 2'b11 : 2'b00)
                        : q_a <= rel_a ? 2'b11 : q_a == rel_a + 16'd1 ? 2'b01 : 2'b00;
    // The count: 1 from a data packet's PID until `end`, else 0.
    function automatic [7:0] cnt_of(input [2:0] g, input [15:0] q);
        case (g)
            3'd2: cnt_of = 8'd1;
            3'd3: cnt_of = q >= 16'd5 ? 8'd0 : 8'd1;
            3'd4: cnt_of = q >= 16'd3 ? 8'd0 : 8'd1;
            default: cnt_of = 8'd0;
        endcase
    endfunction
    wire [7:0]  cnt_ea = cnt_of(gsel, q_a), cnt_eb = cnt_of(gsel, q_b);
    // A byte's store is due: the monitor has read its last bit, and its
    // listener has yet to read that bit (or the stuffed bit after it), or is
    // about to store it, or stores it now.
    wire        mr7 = (m_bi == 3'd7 && !m_stuff && tq > h) || (m_bi == 0 && m_stuff && m_ph == 2'd2);
    wire        st_due_b = (((at_b == PC_PID6 && k_b == 4'd5) || (at_b == PC_BYTE && k_b == 4'd7)) && (b_mid || b_edge) && mr7)
                           || ((at_b == PC_WIDTH || at_b == PC_BJUMP || at_b == PC_STORE) && b_exec) || push_b;
    wire        st_due_a = (at_a == PC_APID && k_a == 4'd7 && (a_mid || a_edge) && mr7)
                           || (at_a == PC_ASTORE && a_exec) || push_a;

`ifdef USB_SIM
    always @(negedge clk) begin                  // once a tick, with everything settled
`else
    always @* begin
`endif
        assume (BIT >= MINBIT);
        assume (start <= MAX_START);

        assert (step <= 2'd3);
        if (!rst) begin
            // ---- CLAIMS ----
            // Neither hart ever loses a role, steps aside or takes as a witness,
            // and the device never takes from its queue.
            assert (role_a == 2'd0 && role_b == 2'd1);
            assert (!lost_a && !lost_b && !clear_a && !clear_b);
            assert (!seen_a && !seen_b && !seen2_a && !seen2_b && !pop_b);
            assert (oe_a[7:2] == 0 && oe_b[7:2] == 0);
            // Two drivers never meet on a pin, and the line is never SE1.
            assert (!(oe_a[0] && oe_b[0]) && !(oe_a[1] && oe_b[1]));
            assert (ln != L_SE1);

            // The line between packets is J; a packet starts with K, at least
            // two bit times after the last ended (7.1.18.1). Each line state
            // lasts whole bits: the line changes only where a bit starts.
            if (m_st == M_IDLE) assert (ln == L_J || (m_sop && m_prev == L_J));
            if (m_sop && m_fr) assert (m_jr >= {4'd0, d, 1'b0});
            // Between packets nobody drives the bus: the last packet's sender has
            // let go of it two bit times after the end of packet, and before the
            // first packet nobody has driven it.
            if (m_st == M_IDLE && !m_sop && (!m_fr || m_it >= {4'd0, d, 1'b0}))
                assert (oe_a[1:0] == 2'b00 && oe_b[1:0] == 2'b00);
            if (m_st != M_IDLE && ln != m_prev) assert (m_t == 0);
            // Only the sender drives the line in a packet.
            if (m_st != M_IDLE) assert (m_dev ? oe_a[1:0] == 0 : oe_b[1:0] == 0);

            // What the monitor reads, in each bit's middle.
            if (m_sample && m_st == M_PKT) begin
                if (m_s == L_SE0) begin
                    // An end of packet comes after a whole byte, the PID at
                    // least, and never where a stuffed bit is due.
                    assert (m_ph == 2'd2 && m_bi == 0 && !m_stuff);
                    // The device's packet is its PID alone.
                    if (m_dev) assert (m_nb == 0);
                    // After RESTART the host sends its CRC16 as two bytes,
                    // and the CRC16 then checks.
                    if (!m_dev && g_rst) assert (m_nc == 2'd2 && m_crc == 16'h800D);
                end else begin
                    if (m_stuff) assert (!m_b);                     // a stuffed 0
                    if (!m_stuff && m_ph == 0) assert (m_b == (m_bi == 3'd7));   // SYNC
                end
            end
            if (m_sample && m_st == M_SE0) assert (m_s == L_SE0);   // SE0 for two bits
            // Every byte the host sends is the one it took, and the device's
            // only byte is ACK.
            if (m_sample && m_bdone) begin
                if (m_dev) begin assert (m_ph == 2'd1 && m_bytev == 8'hD2); end
                else if (!(m_ph == 2'd2 && g_rst)) assert (m_bytev == g_tk);
            end

            // The device answers each data packet whose CRC16 checks, 2 bit
            // times and 2 ticks after its end of packet, however long after
            // the packet before it came, and at no other time.
            if (m_sop) assert (low_b == (m_due && m_it == {4'd0, d, 1'b0} + 16'd2));
            if (m_due && m_st == M_IDLE && m_it == {4'd0, d, 1'b0} + 16'd2) assert (m_sop && low_b);

            // DATA: the device stores each byte of the host's packets, the host
            // the ACK, as the monitor read them, once each.
            if (push_b) assert (m_pend && !m_dev && pdata_b == m_byte);
            if (push_a) assert (m_pend && m_dev && pdata_a == m_byte);
            if (m_sample && m_bdone) assert (!m_pend);
            if (m_sample && m_s == L_SE0) assert (!m_pend);

            // VIOLATIONS: every hart counts exactly the data packets whose
            // CRC16 fails, within two bit times of their end.
            assert (viol_a <= m_nbad && viol_b <= m_nbad && viol_a + 9'd1 >= {1'b0, m_nbad}
                    && viol_b + 9'd1 >= {1'b0, m_nbad});
            if (m_st != M_IDLE || m_it >= {4'd0, d, 1'b0}) assert (viol_a == m_nbad && viol_b == m_nbad);

            // ==== INVARIANTS ====

            // ---- The monitor's own state ----
            assert (m_st != 2'd3 && m_ph != 2'd3);
            if (m_st == M_IDLE) begin assert (m_t == 0 && m_jr == m_it); end
            else assert (m_t < BIT && m_it == 0);
            if (m_st == M_PKT) assert (m_run <= 3'd6 && (m_ph != 0 || m_run == 0));
            // A packet's first tick is the K seen while idle.
            if (m_cell0) assert (m_t != 0);
            // `stuff` restarted the coder before a host packet: nothing taken yet.
            if (m_cell0 && !m_dev) assert (g_scrc == 16'hFFFF && g_rl == 0 && !g_rval);
            // The second bit of the end of packet is SE0 throughout, after a whole
            // byte where no stuffed bit was due.
            if (m_st == M_SE0) assert (ln == L_SE0 && m_run < 3'd6 && m_ph == 2'd2 && m_bi == 0);
            if (m_st != M_IDLE && m_t > h[10:0]) assert (m_cur == ln);
            // The line two and three ticks ago: in a packet, the bit before
            // until this bit's change has passed through; between packets J,
            // after the end of packet's SE0.
            if (m_st != M_IDLE)
                assert (m_prev == (tq == 0 ? m_pl : ln) && m_p2 == (tq <= 12'd1 ? m_pl : ln)
                        && m_p3 == (tq <= 12'd2 ? m_pl : ln));
            if (m_st == M_IDLE)
                assert (m_prev == ((m_fr && m_it == 0) ? L_SE0 : L_J)
                        && m_p2 == ((m_fr && m_it <= 16'd1) ? L_SE0 : L_J)
                        && m_p3 == ((m_fr && m_it <= 16'd2) ? L_SE0 : L_J));
            if (m_st == M_SE0 || (m_st == M_PKT && ln == L_SE0 && tq != 0)) assert (m_jr == 0);
            // DM falls only where a bit starts: the last fall is this bit's
            // start, or a bit or more back, and the one before it too; between
            // packets, two bits before the gap or more; from reset, none yet.
            if (m_st == M_PKT) begin
                assert ((m_lvl && !ln[1] && tq != 0 && g_fa == tq - 1'b1)
                        || {1'b0, g_fa} + 17'd1 >= {5'd0, tq} + {5'd0, d});
                assert ({1'b0, g_fb} + 17'd1 >= {5'd0, tq} + {5'd0, d});
            end
            if (m_st == M_SE0) assert ({1'b0, g_fa} + 17'd1 >= {5'd0, tq} + {5'd0, d}
                                       && {1'b0, g_fb} + 17'd1 >= {5'd0, tq} + {5'd0, d});
            if (m_st == M_IDLE && m_fr) assert ((g_fa == 16'hFFFF || {1'b0, g_fa} + 17'd1 >= {1'b0, m_it} + {4'd0, d, 1'b0})
                                                && g_fb >= g_fa);
            // The harts have seen DM low from the third tick of the first packet on.
            if (m_fr && !(m_cell0 && tq <= 12'd2)) assert (g_fell);
            if (!m_fr) assert (!g_fell && !g_fv && !g_fbv && m_sh == 0
                               && !m_pend && m_tc == 2'd3);
            if (!g_fv) assert (!g_fbv && g_fa == 16'hFFFF);
            if (!g_fbv) assert (g_fb == 16'hFFFF);
            if (g_fv) assert (g_fb >= g_fa);
            // In a packet a level lasts from the 0 that changed to it through
            // the 1s after it, at most seven bits: so J has lasted this bit so
            // far, after the bits since the last 0 if this one is a 1 too.
            if (m_st == M_PKT) begin
                if (ln == L_J) begin assert (m_jr == {4'd0, tq} + (m_lvl ? ({13'd0, m_run} + 16'd1) * dw : 16'd0)); end
                else if (tq == 0) begin assert (m_jr == (m_lvl ? ({13'd0, m_run} + 16'd1) * dw : 16'd0)); end
                else assert (m_jr == 0);
            end
            if (!m_fr) assert (m_st == M_IDLE && !m_data && !m_due && m_nbad == 0 && (m_it == 16'hFFFF || m_it[11:0] == now_a));
            // The bits after a packet count the idle ticks; from the fourth on
            // they are not counted.
            if (m_st != M_IDLE) begin assert (m_tc == 2'd3 && m_tt == 0); end
            else if (m_tc != 2'd3) begin assert (m_fr && m_tt < BIT && m_it == {14'd0, m_tc} * dw + {5'd0, m_tt}); end
            else assert (!m_fr || m_it >= 16'd3 * dw);
            // CRC bytes: at most two, only in the host's packets.
            if (m_st == M_PKT && m_ph == 2'd2 && !m_crcb) assert (m_nc == 0);
            assert (m_nc <= 2'd2 && (m_st != M_IDLE || m_nc == 0) && (!m_dev || m_nc == 0));
            // A handshake is due only after a data packet, until it ends; the
            // handshake follows a data packet, whose type the monitor keeps.
            if (m_due) assert (m_data && (m_st != M_IDLE || !m_dev));
            if (m_dev) assert (m_data);
            // Between packets the monitor holds the end of the last, after a
            // whole byte.
            if (m_st == M_IDLE && m_fr) assert (m_ph == 2'd2 && m_bi == 0 && m_run < 3'd6);
            // A host packet's type follows its PID, once both bits are read.
            if (!m_dev && (m_st == M_SE0 || (m_st == M_IDLE && m_fr))) assert (m_data == (pid_lo == 2'b11));

            // ---- The bit before, as its registers keep it ----
            // In a packet, the monitor now is the bit before with that bit
            // taken in; after the end of packet nothing has changed since.
            if (m_st != M_IDLE && !m_cell0) begin
                assert (p_st == M_PKT && m_st == (p_line == L_SE0 ? M_SE0 : M_PKT)
                        && p_nc == ((m_ph == 2'd2 && m_crcb && m_bi == 3'd7 && !m_stuff && tq > h) ? m_nc - 1'b1 : m_nc));
                if (p_line == L_SE0) begin
                    assert ({p_ph, p_bi, p_run, p_sh, p_nb, p_crc, p_scrc, p_lvl, p_rl, p_rval, p_rv}
                            == {m_ph, m_bi, m_run, m_sh, m_nb, m_crc, g_scrc, m_lvl, g_rl, g_rval, g_rv});
                end else begin
                    assert (m_lvl == p_line[1]);
                    if (p_run == 3'd6) begin
                        assert ({m_ph, m_bi, m_run, m_sh, m_nb, m_crc, g_scrc} == {p_ph, p_bi, 3'd0, p_sh, p_nb, p_crc, p_scrc});
                    end else begin
                        assert (m_bi == p_bi + 1'b1 && m_run == (p_b ? p_run + 1'b1 : 3'd0)
                                && m_ph == ((p_bi == 3'd7 && p_ph != 2'd2) ? p_ph + 1'b1 : p_ph)
                                && m_sh == (p_ph != 0 ? {p_b, p_sh[7:1]} : p_sh)
                                && m_nb == ((p_ph == 2'd2 && p_bi == 3'd7 && p_nb != 8'hFF) ? p_nb + 1'b1 : p_nb)
                                && m_crc == (p_ph == 2'd2 ? crc_step16(p_crc, p_b) : (p_ph == 2'd1 && p_bi == 3'd7) ? 16'hFFFF : p_crc)
                                && g_scrc == ((p_ph != 2'd2 && !m_dev) ? crc_step16(p_scrc, p_b) : p_scrc));
                    end
                    if (m_dev) begin assert ({g_rl, g_rval, g_rv} == {p_rl, p_rval, p_rv}); end
                    else assert (g_rval && g_rl == (p_run == 3'd6 ? 4'd1 : (p_rval && p_rv == p_b) ? p_rl + 1'b1 : 4'd1)
                                 && g_rv == (p_run == 3'd6 ? 1'b0 : p_b));
                end
            end
            if (m_st == M_IDLE && m_fr)
                assert (p_st == M_SE0 && {p_ph, p_bi, p_run, p_sh, p_nb, p_crc, p_scrc, p_lvl, p_rl, p_rval, p_rv}
                        == {m_ph, m_bi, m_run, m_sh, m_nb, m_crc, g_scrc, m_lvl, g_rl, g_rval, g_rv});

            // ---- Each hart's input stages: the line one, two and three ticks
            // ago. On the tick after reset (state BOOT) the oldest stage still
            // holds its power-on 0; the hart moves the next one in before
            // reading it.
            assert (s1_a[1:0] == m_prev && pin_a[1:0] == m_p2 && s1_a == s1_b && pin_a == pin_b
                    && prev_a == prev_b && prev_a[1:0] == (s_a == S_BOOT ? 2'b00 : m_p3));
            assert (now_a == now_b);
            if (s_a == S_BOOT || s_b == S_BOOT)
                assert (s_a == s_b && at_a == 0 && at_b == 0 && now_a == 0 && held_a == 0 && held_b == 0
                        && !cset_a[13] && !cset_b[13] && m_st == M_IDLE && !m_fr && m_it == 0);

            // ---- Configuration, as each hart's mode words have set it ----
            assert (cfg_a == {16'd0, 16'd0, usb_hold_ticks(BIT), 16'd0, usb_hold(start), 32'd0}
                    && cfg_b == cfg_a);
            assert (code_a[87:51] == cfg_of(at_a) && code_b[87:51] == cfg_of(at_b));
            assert (code_a[45:24] == cfg2_of(at_a) && code_b[45:24] == cfg2_of(at_b));
            assert (cset_a == cset_of(at_a, start, cset_a[13]) && cset_b == cset_of(at_b, start, cset_b[13]));
            // Stuffing is off until a hart first runs `stuff`, then on for good.
            assert (code_a[50:46] == (g_sta ? 5'h16 : 5'h00) && code_b[50:46] == (g_stb ? 5'h16 : 5'h00));
            if (m_fr) assert (g_sta);
            if (m_fr && !(m_cell0 && tq <= 12'd4)) assert (g_stb);
            if (!m_fr) assert (!g_stb && (at_a >= PC_CLAIM || !g_sta));

            // ---- Where each hart can be ----
            // Only the states of timed bits and claims last past a tick;
            // after a break a listener takes a tick to fetch.
            assert (s_a <= S_MID && (s_b <= S_MID || (s_b == S_FETCH && at_b == PC_EOP2)));
            if (ins_a[31:28] != 4'd1) begin assert (s_a == S_BOOT || a_exec || (at_a == PC_CLAIM && a_claim)); end
            else assert (a_exec || a_sync || a_edge || a_mid);
            if (ins_b[31:28] != 4'd1) begin assert (s_b == S_BOOT || b_exec || (at_b == PC_CLAIM && b_claim)); end
            else assert (b_exec || b_sync || b_edge || b_mid || s_b == S_FETCH);
            assert (at_a < PROG_LEN && at_b < PROG_LEN && at_a != PC_LWIDTH && at_a != PC_LBAD
                    && at_b != PC_LWIDTH && at_b != PC_LBAD);
            // A hart is inside an instruction past its first bit, the flag a
            // trap checks, exactly while it is on a later bit.
            assert (partial_a[0] == ((a_sync || a_edge || a_mid) && k_a != 0)
                    && partial_b[0] == ((b_sync || b_edge || b_mid) && k_b != 0));
            if (a_sync || a_edge || a_mid) assert (mine_a == mine_of(ins_a[24:23], 2'd0) && k_a <= ins_a[20:17]
                                       && src_a == (code_a[1] ? {1'b1, code_a[0]} : ins_a[13] ? 2'd2 : ins_a[22:21]));
            if (b_sync || b_edge || b_mid) assert (mine_b == mine_of(ins_b[24:23], 2'd1) && k_b <= ins_b[20:17]
                                       && src_b == (code_b[1] ? {1'b1, code_b[0]} : ins_b[13] ? 2'd2 : ins_b[22:21]));
            assert (keep_a == 0 && keep_b == 0);

            // ---- What the monitor has read, from what was sent ----
            if (m_st == M_PKT) begin
                // SYNC: each 0 changes the line, so the level alternates; its
                // last bit, a 1, leaves K.
                if (m_ph == 0) assert (m_lvl == !m_bi[0]);
                if (m_ph == 2'd1 && m_bi == 0) assert (!m_lvl && m_run == 3'd1);
                // In the PID the run of 1s goes back at most to SYNC's last bit.
                if (m_ph == 2'd1) assert ({1'b0, m_run} <= {1'b0, m_bi} + 4'd1);
                // Before the bytes after the PID none is counted, none is the CRC16,
                // and RESTART can come only once the PID's last bit is read.
                if (m_ph != 2'd2) assert (m_nb == 0 && m_nc == 0 && !m_crcb && (!g_rst || (m_ph == 2'd1 && m_bi == 3'd7 && tq >= h)));
                // The CRC16 starts at all ones after the PID.
                if (m_ph == 2'd2 && m_nb == 0 && m_bi == 0) assert (m_crc == 16'hFFFF);
                if (!m_dev) begin
                    // The run of 1s is the harts' coder's run.
                    assert ((g_rval && g_rv) ? (g_rl <= 4'd6 && m_run == g_rl[2:0]) : m_run == 0);
                    // The bits read of the PID or a byte are the byte the host
                    // took, until it takes the next one, 5 ticks after the
                    // last bit is read.
                    if (m_ph != 0 && !(m_ph == 2'd2 && m_crcb) && !(m_bi == 3'd7 && !m_stuff && tq >= h + 12'd5))
                        assert ((m_sh >> (4'd8 - {1'b0, m_bi})) == (g_tk & ~(8'hFF << m_bi)));
                    // In the chip's CRC16 each bit sent is the register's top
                    // bit changed by `xor`, so the register's low bits follow a
                    // fixed pattern whatever it held before, and it ends at the
                    // residual.
                    if (m_ph == 2'd2 && m_crcb)
                        assert (c_nc <= ((m_stuff && m_bi == 0) || ln == L_SE0 ? 2'd2 : 2'd1) && ((m_crc ^ crc_f(kc)) & ~(16'hFFFF << kc)) == 0
                                && (kc != 5'd16 || ln == L_SE0 || m_stuff) && (ln != L_SE0 || kc == 5'd16) && g_rst
                                && (!(m_stuff && m_bi == 0) || m_nc != 0));
                    if (g_rst && !m_crcb) assert (at_a == PC_CRC && (a_exec || (a_edge && k_a == 0)) && tq >= h);
                    if (at_a == PC_CRC) assert (g_rst);
                    if (g_rst) assert (at_a == PC_CRC || at_a == PC_EOP || at_a == PC_EOP2);
                    // At its end of packet the host has sent both CRC bytes after
                    // RESTART, and none otherwise.
                    if (at_a == PC_EOP || at_a == PC_EOP2) assert (g_rst ? (m_crcb && (m_nc == 2'd2 || (m_nc == 2'd1 && m_bi == 3'd7 && !m_stuff && tq == h)))
                                                                  : (m_nc == 0 && !m_crcb));
                end else begin
                    // The device's packet is SYNC, ACK and its end of packet.
                    assert (m_run == ack_run(m_ph, m_bi) && m_nb == 0 && (m_ph != 2'd2 || (m_bi == 0 && ln == L_SE0)));
                    if (m_ph == 2'd1) assert ((m_sh >> (4'd8 - {1'b0, m_bi})) == (8'hD2 & ~(8'hFF << m_bi)));
                end
            end

            // ---- The hold counter ----
            // Each hart counts DM high as it sees it, two ticks late, but
            // starts again at once when it pulls DM low itself.
            assert (held_a == {16'd0, low_a1 ? 16'd0 : held_v} && held_b == {16'd0, low_b1 ? 16'd0 : held_v});

            // ---- Between packets ----
            if (m_st == M_IDLE && !m_sop) begin
                // Both have read the last bit before this gap: J, as they
                // still hold it; no instruction is cut off mid-bits.
                assert (rx_a == m_sh && rx_b == m_sh);
                if (rd_a) assert (armed_a[1:0] == L_J && !a_mid && !partial_a[0]);
                if (rd_b) assert (armed_b[1:0] == L_J && !b_mid && !partial_b[0]);
                // The hold trap fires once DM has been high for 18 bit times:
                // every hart then runs `tmo` and claims again.
                if (tr_a) begin assert (a_exec && at_a == PC_TMO && ahead_a == 0); end
                else if (rd_a && sq_a) assert (sq_ok_a);
                else if (rd_a) assert (cf_a && ahead_a == ah_a);
                if (tr_b) begin assert (b_exec && at_b == PC_TMO && ahead_b == 0); end
                else if (rd_b && sq_b) assert (sq_ok_b);
                else if (rd_b) assert (cf_b && ahead_b == ah_b);
                // Drives: the host lets go of J at `end`, or for the handshake at
                // its edge; the device has let go by then.
                if (rd_a) assert (oe_a[1:0] == oe_ea && (!oe_ea[1] || ov_a[1]) && (!oe_ea[0] || !ov_a[0]));
                if (rd_b) assert (oe_b[1:0] == 2'b00);
                // The count: 1 after a data packet's PID until `end`, else 0.
                if (rd_a) begin assert (count_a == cnt_ea); end
                else assert (count_a == {7'd0, m_data});
                if (rd_b) begin assert (count_b == cnt_eb); end
                else assert (count_b == {7'd0, m_data});
                // The coder keeps what the last bits left it until the host's
                // `stuff` restarts it. (The hold trap can send a host that has run
                // `stuff` back to its claim.)
                if (rd_a && sq_a) begin assert (code_a[23:0] == gap_code); end
                else if (rd_a && at_a == PC_SYNC0) begin assert (code_a[23:0] == {16'hFFFF, 8'h00}); end
                else if (rd_a) assert (code_a[23:0] == gap_code || (code_a[23:0] == {16'hFFFF, 8'h00} && fired));
                if (rd_b) assert (code_b[23:0] == gap_code);
            end

            // ---- A packet's first tick, and its listener before it joins ----
            if (m_sop) begin
                // The sender's K: SYNC's first bit, from its edge.
                if (low_b) begin
                    assert (at_b == PC_ASYNC0 && b_mid && since_b == 0 && k_b == 0 && mine_b && !val_b
                            && oe_b[1:0] == 2'b11 && ov_b[1:0] == L_K);
                end else begin
                    assert (at_a == PC_SYNC0 && a_mid && since_a == 0 && k_a == 0 && mine_a && !val_a
                            && oe_a[1:0] == 2'b11 && ov_a[1:0] == L_K && code_a[23:0] == {16'hFFFF, 8'h00});
                end
            end
            // The device sees the K two ticks after it starts. Its hold trap can
            // fire on the tick before, if DM had then been high for 18 bit
            // times as it counts: it runs `tmo` and claims, a tick late.
            if (m_cell0 && tq == 12'd1) begin
                if (!m_dev) begin
                    assert ((m_late ? (at_b == PC_TMO && b_exec && ahead_b == 0 && held_b[15:0] == tmo_t)
                                    : (at_b == PC_CLAIM && b_claim && ahead_b <= 12'd2))
                            && oe_b[1:0] == 0 && armed_b[1:0] == L_J
                            && rx_b == m_sh && code_b[23:0] == f_code && count_b == 0);
                end else begin
                    assert (at_a == PC_ASYNC0 && a_sync && k_a == 0 && !mine_a && !val_a && src_a == 2'b10
                            && ahead_a == 0 && oe_a[1:0] == 0 && armed_a[1:0] == L_J && rx_a == m_sh
                            && code_a[23:0] == f_code && count_a == 8'd1);
                end
            end
            if (m_late) assert (m_st != M_IDLE && !m_dev);

            // ---- The transaction ----
            // In the host's packets the count is 0 until a hart has read the
            // PID's second bit, then 1 for a data packet; in the device's it is
            // the data packet's 1. No handshake is due while the host sends; the
            // device's packet answers a data packet whose CRC16 checks.
            if (m_st != M_IDLE) begin
                if (m_dev) begin
                    assert (count_a == 8'd1 && count_b == 8'd1 && m_due && m_data && f_code == {16'h003E, 8'h1C});
                end else begin
                    assert (count_a == ((at_a > PC_PCNT) ? {7'd0, m_data} : 8'd0)
                            && count_b == ((at_b > PC_PCNT) ? {7'd0, m_data} : 8'd0) && !m_due);
                    // The PID's byte is the one the host took for it, until it
                    // takes the next.
                    if ((at_a >= PC_PID2 && at_a <= PC_WIDTH) || (at_a >= PC_CSTOP && at_a <= PC_BLOAD
                            && (m_ph == 2'd1 || (m_ph == 2'd2 && m_nb == 0 && m_bi == 0)))) assert (g_pid == g_tk);
                    // The type is known once the PID's second bit is read.
                    if (m_ph == 0 || (m_ph == 2'd1 && (m_bi == 0 || (m_bi == 3'd1 && tq <= h)))) assert (!m_data);
                    if (m_ph == 2'd2 || (m_ph == 2'd1 && m_bi > 3'd1) || (m_ph == 2'd1 && m_bi == 3'd1 && tq > h))
                        assert (m_data == (pid_lo == 2'b11));
                end
            end
            if (g2) assert (m_crc == 16'h800D && m_it <= dw + dw + 16'd2);
            if (g3) assert (m_crc != 16'h800D);
            // Violations: each hart counts a bad data packet as its `crc_bad`
            // runs, a bit and a half after the end of packet.
            if (g3 && !(rd_a && q_a >= 16'd2)) begin assert (viol_a + 8'd1 == m_nbad || (viol_a == 8'hFF && m_nbad == 8'hFF)); end
            else assert (viol_a == m_nbad);
            if (g3 && !(rd_b && q_b >= 16'd2)) begin assert (viol_b + 8'd1 == m_nbad || (viol_b == 8'hFF && m_nbad == 8'hFF)); end
            else assert (viol_b == m_nbad);
            assert (vout_a == viol_a || vout_a + 8'd1 == viol_a);
            assert (vout_b == viol_b || vout_b + 8'd1 == viol_b);

            // ---- Stores ----
            // A byte the monitor has read is pending until its listener has
            // stored it: the listener reads its last bit two ticks later,
            // then stores it, after the stuffed bit if one follows.
            assert (m_pend == ((m_dev ? st_due_a : st_due_b) && m_st == M_PKT));
            if (m_st != M_PKT) assert (!m_pend);
            // The byte pending is the last one read: in the monitor's register
            // from the end of its last bit on, with that bit until then.
            if (m_pend) assert (m_byte == ((m_bi == 3'd7 && !m_stuff && tq > h) ? m_bytev : m_sh));

            // ---- The last fall each hart has seen ----
            assert (lf_a == lf_b);
            // A hart forgets a fall 1024 ticks on, but not on a tick its hold
            // trap fires.
            assert (cset_a[13] == (f_seen && (f_age < 16'd1024 || (f_age == 16'd1024 && tr_a))));
            assert (cset_b[13] == (f_seen && (f_age < 16'd1024 || (f_age == 16'd1024 && tr_b))));
            if (cset_a[13] || cset_b[13]) assert (lf_a == now_a - f_age[11:0]);

            // ---- Each hart's shift register ----
            // The PID's first two bits, then its other six.
            if (at_a == PC_PID2 || at_a == PC_BYTE) begin assert (tx_a == g_tk >> (a_exec ? 4'd0 : k_a + 4'd1)); end
            else if (at_a == PC_PBR || at_a == PC_PCNT) begin assert (tx_a == g_tk >> 2); end
            else if (at_a == PC_PID6) begin assert (tx_a == g_tk >> (a_exec ? 4'd2 : k_a + 4'd3)); end
            else assert (tx_a == 0);
            if (at_b == PC_APID) begin assert (tx_b == 8'hD2 >> (b_exec ? 4'd0 : k_b + 4'd1)); end
            else if (at_b == PC_ASYNC0 || at_b == PC_ASYNC6 || at_b == PC_ASYNCK) begin assert (tx_b == 8'hD2); end
            else assert (tx_b == 0);
        end
    end
endmodule

// A hart in a packet, checked against the monitor as it was o ticks ago:
// o = 0 for the packet's sender, and 2 for the listener, which sees the line
// two ticks late. The cells are the packet's bits (st PKT), its second SE0
// bit (st SE0) and the J bits that follow it (st IDLE, tail cell tc 0 or 1).
module usb_view (
    input         clk_v,      // the simulation checks once a tick, at its falling edge
    input         en,         // check this hart now
    input         snd,        // it sends this packet
    input         dev,        // the packet is the device's
    input         who,        // this hart: 0 the host, 1 the device
    input  [10:0] BIT,
    input  [1:0]  st,
    input  [10:0] t,          // ticks into the cell
    input  [1:0]  ph,
    input  [2:0]  bi,
    input  [2:0]  run,
    input  [7:0]  sh,
    input  [15:0] crc, scrc,
    input         lvl,        // DM in the cell before
    input  [1:0]  line,       // the line in this cell
    input  [3:0]  rl,
    input         rval, rv,
    input  [1:0]  nc,
    input  [7:0]  nb,
    input         crcb,       // the byte in hand is the chip's CRC16
    input  [1:0]  tc,
    input         data,       // the host's packet is a data packet
    input         late,       // the device's hold trap fired as it started
    input  [23:0] fcode,      // the coder as it was between the last packet and this one
    input  [7:0]  gtk,        // the host's byte
    input         lfv,        // the hart counts its last fall,
    input  [15:0] lf_age,     // seen this many ticks ago
    // the hart
    input  [5:0]  at,
    input  [3:0]  s,
    input  [3:0]  k,
    input  [23:0] code,       // the coder's low bits: crc, run, inserted
    input  [7:0]  rx,
    input  [11:0] now, edge_t,
    input         mine, val,
    input  [1:0]  src,
    input  [1:0]  oe, ov, armed,
    input  [31:0] ins
);
    `include "usb_rom.vh"
    localparam S_EXEC = 4'd1, S_CLAIM = 4'd2, S_SYNC = 4'd3, S_EDGE = 4'd4, S_MID = 4'd5, S_FETCH = 4'd15;
    localparam [1:0] M_IDLE = 2'd0, M_PKT = 2'd1, M_SE0 = 2'd2;
    localparam [1:0] L_SE0 = 2'b00, L_K = 2'b01, L_J = 2'b10;

    wire [11:0] d = {1'b0, BIT};
    wire [11:0] h = {2'b00, BIT[10:1]};
    wire [11:0] tq = {1'b0, t};
    wire        x_exec = s == S_EXEC, x_claim = s == S_CLAIM, x_edge = s == S_EDGE, x_mid = s == S_MID;
    wire [11:0] since = now - edge_t, ahead = edge_t - now;
    wire        pre = tq < h, read = !pre;
    wire [11:0] p = tq - h;                      // ticks since this cell was read
    wire        pkt = st == M_PKT && line != L_SE0;
    wire        b = line[1] == lvl;              // this bit's NRZI value
    wire        stuff = run == 3'd6;
    wire [1:0]  pl = {lvl, !lvl};                // the line in the cell before
    function automatic [15:0] crc_step(input [15:0] c, input x);
        crc_step = {c[14:0], 1'b0} ^ ((x ^ c[15]) ? 16'h8005 : 16'h0);
    endfunction
    // The coder (CRC, run, run valid, run value) with one more bit.
    function automatic [21:0] cod_step(input [21:0] c, input x);
        cod_step = {{c[20:6], 1'b0} ^ ((x ^ c[21]) ? 16'h8005 : 16'h0),
                    (c[1] && c[0] == x) ? c[5:2] + 4'd1 : 4'd1, 1'b1, x};
    endfunction
    // After a data packet whose CRC16 checks, and its two bits of J, the CRC
    // holds 0x003E and the run is one 1. After n more bits: the device's SYNC
    // and ACK, then the two bits of J after its end of packet.
    function automatic [21:0] ack_code(input [4:0] n);
        reg [17:0] x;
        reg [21:0] c;
        integer i;
        begin
            x = 18'h2D280;                   // 0000000 1, D2, 0 1, first bit lowest
            c = {16'h003E, 4'd1, 2'b11};
            for (i = 0; i < 18; i = i + 1)
                if (i < n) c = cod_step(c, x[i]);
            ack_code = c;
        end
    endfunction
    function automatic xor_bit(input [3:0] i);
        reg [15:0] m;
        begin
            m = 16'h9555;
            xor_bit = m[i];
        end
    endfunction
    // Once read: the monitor's state with this bit taken in.
    wire        took = read && pkt && !stuff;   // a data bit, read
    wire [2:0]  v_run = !(read && pkt) ? run : stuff ? 3'd0 : b ? run + 1'b1 : 3'd0;
    wire [2:0]  v_bi = took ? bi + 1'b1 : bi;
    wire [1:0]  v_ph = (took && bi == 3'd7 && ph != 2'd2) ? ph + 1'b1 : ph;
    wire [7:0]  v_sh = (took && ph != 0) ? {b, sh[7:1]} : sh;
    wire [15:0] v_crc = !took ? crc : ph == 2'd2 ? crc_step(crc, b) : (ph == 2'd1 && bi == 3'd7) ? 16'hFFFF : crc;
    wire [15:0] v_scrc = (took && ph != 2'd2) ? crc_step(scrc, b) : scrc;
    wire [3:0]  v_rl = !(read && pkt) ? rl : stuff ? 4'd1 : (rval && rv == b) ? rl + 1'b1 : 4'd1;
    wire        v_rval = (read && pkt) ? 1'b1 : rval;
    wire        v_rv = !(read && pkt) ? rv : stuff ? 1'b0 : b;
    wire        next_stuff = v_run == 3'd6;
    wire        joining = !snd && who && st == M_PKT && ph == 0 && bi == 0 && tq < (late ? 12'd3 : 12'd2);
    // The instruction and bit index of a data bit at (ph, bi): in the host's
    // bytes after the PID a sender sends from BYTE or, after RESTART, CRC; a
    // listener reads every byte with BYTE.
    function automatic [9:0] place(input [1:0] f, input [2:0] i, input crcf, input [1:0] n, input dv);
        reg [5:0] w;
        reg [3:0] x;
        begin
            if (f == 0) begin
                if (i == 0) begin w = dv ? PC_ASYNC0 : PC_SYNC0; x = 0; end
                else if (i == 3'd7) begin w = dv ? PC_ASYNCK : PC_SYNCK; x = 0; end
                else begin w = dv ? PC_ASYNC6 : PC_SYNC6; x = {1'b0, i} - 4'd1; end
            end else if (f == 2'd1) begin
                // The host sends its PID as two bits, then six; the device its ACK in one.
                if (dv) begin w = PC_APID; x = {1'b0, i}; end
                else if (i < 3'd2) begin w = PC_PID2; x = {1'b0, i}; end
                else begin w = PC_PID6; x = {1'b0, i} - 4'd2; end
            end
            else if (crcf) begin w = PC_CRC; x = {n[0], i}; end
            else begin w = PC_BYTE; x = {1'b0, i}; end
            place = {w, x};
        end
    endfunction
    // Whether a bit at (ph, bi) is its instruction's last.
    function automatic last_of(input [1:0] f, input [2:0] i, input crcf, input [1:0] n, input dv);
        last_of = f == 0 ? (i == 0 || i == 3'd6 || i == 3'd7) : (f == 2'd1 && !dv && i == 3'd1)
                  || (i == 3'd7 && (!crcf || n[0]));
    endfunction
    wire        crcf = snd && crcb;                 // the sender is sending its CRC16
    // The data bit before a stuffed bit, whose instruction sends it: bit bi-1
    // of the same field, or when bi is 0 the last bit of the PID (no byte
    // after it yet) or of the byte before.
    wire [1:0]  j_ph = bi != 0 ? ph : (ph == 2'd2 && nb == 0) ? 2'd1 : 2'd2;
    wire [2:0]  j_bi = bi - 1'b1;
    wire [1:0]  j_nc = (crcf && bi == 0) ? nc - 1'b1 : nc;
    // The monitor counts a CRC byte as it reads its last bit.
    wire [1:0]  c_nc = (crcf && ph == 2'd2 && bi == 3'd7 && tq > h) ? nc - 1'b1 : nc;
    wire [9:0]  pl_cur = stuff ? place(j_ph, j_bi, crcf, j_nc, dev) : place(ph, bi, crcf, c_nc, dev);
    // After a stuffed bit, or this data bit: the instruction ends?
    wire        ends_now = stuff ? last_of(j_ph, j_bi, crcf, j_nc, dev) : last_of(ph, bi, crcf, c_nc, dev);
    // The bit this hart sends, for a sender.
    wire [7:0]  pid = dev ? 8'hD2 : gtk;
    wire        own_bit = stuff ? 1'b0 : ph == 0 ? bi == 3'd7 : ph == 2'd1 ? pid[bi]
                          : crcf ? crc[15] ^ xor_bit(pl_cur[3:0]) : gtk[bi];
    // Its next bit in the same instruction, once this one is read.
    wire [3:0]  k_nx = pl_cur[3:0] + 1'b1;
    wire        nx_bit = next_stuff ? 1'b0 : v_ph == 0 ? v_bi == 3'd7 : v_ph == 2'd1 ? pid[v_bi]
                         : crcf ? v_crc[15] ^ xor_bit(k_nx) : gtk[v_bi];
    // The first bit of the bit instruction a hart waits on: a constant, a
    // break (sent as 0), its byte's first bit or its CRC16's.
    wire        first_val = ins[13] ? 1'b0 : ins[22:21] == 2'd2 ? 1'b0 : ins[22:21] == 2'd3 ? 1'b1
                            : ins[22:21] == 2'd1 ? v_crc[15] ^ 1'b1 : at == PC_PID6 ? gtk[2] : pid[0];
    // After the last bit of an instruction: the instructions that follow, one
    // a tick (p from the bit's read), the last a bit instruction that then
    // waits at its edge. In a host packet the sender chooses after each byte:
    // on, the CRC16 (RESTART), or the end of packet (STOP or an empty queue).
    function automatic aft(input [5:0] i, input [11:0] q, input sn, input [5:0] a, input [3:0] x, input bv);
        reg e, wait1;
        begin
            e = x == S_EXEC;
            wait1 = x == S_EDGE;
            case (i)
                PC_SYNC0, PC_SYNC6, PC_ASYNC0, PC_ASYNC6, PC_ASYNCK, PC_CRC:
                    aft = a == (i == PC_CRC ? PC_EOP : i + 1'b1) && (q == 0 ? e : wait1);
                PC_SYNCK:
                    aft = q == 0 ? (e && a == PC_PLOAD) : q == 12'd1 ? (e && a == PC_PID2) : (wait1 && a == PC_PID2);
                // The PID's second bit, bv: a 0 skips the counter.
                PC_PID2:
                    aft = q == 0 ? (e && a == PC_PBR)
                          : q == 12'd1 ? (e && a == (bv ? PC_PCNT : PC_PID6))
                          : q == 12'd2 ? (bv ? (e && a == PC_PID6) : (wait1 && a == PC_PID6))
                          : (wait1 && a == PC_PID6);
                PC_APID:
                    aft = q == 0 ? (e && a == PC_ASTORE) : q == 12'd1 ? (e && a == PC_AEOP) : (wait1 && a == PC_AEOP);
                PC_PID6, PC_BYTE:
                    case (q)
                        12'd0: aft = e && a == (i == PC_PID6 ? PC_WIDTH : PC_BJUMP);
                        12'd1: aft = e && a == PC_STORE;
                        12'd2: aft = e && a == PC_CSTOP;
                        12'd3: aft = e && (a == PC_CRST || (sn && a == PC_EOP));
                        12'd4: aft = (e && (a == PC_BLOAD || (sn && a == PC_CRC))) || (sn && wait1 && a == PC_EOP);
                        12'd5: aft = (e && a == PC_BYTE) || (sn && wait1 && (a == PC_CRC || a == PC_EOP));
                        default: aft = wait1 && (a == PC_BYTE || (sn && (a == PC_CRC || a == PC_EOP)));
                    endcase
                default: aft = 1'b0;
            endcase
        end
    endfunction
    wire        aft_ok = aft(pl_cur[9:4], p, snd, at, s, b);
    // The end of packet and the J bits after it: which instruction sends
    // this cell, its index, its value, and whether another bit of it follows.
    wire        se0 = (st == M_PKT && line == L_SE0) || st == M_SE0;
    wire        tail = st == M_IDLE;
    wire [5:0]  c_ins = dev ? (tail ? (tc == 0 ? PC_AJ : PC_ATURN) : PC_AEOP) : tail ? (tc == 0 ? PC_J : PC_TURN)
                        : st == M_SE0 ? PC_EOP2 : PC_EOP;
    wire [3:0]  c_k = (dev && st == M_SE0) ? 4'd1 : 4'd0;
    wire        c_val = tail && tc != 0;
    wire        c_more = dev && se0 && st == M_PKT;
    // Who drives the cell: its sender, but the second J after the handshake is
    // the host's, two ticks late as the handshake's listener.
    wire        own = (dev && tail && tc == 2'd1) ? !snd : snd;
    wire        nxt_own = (dev && tail && tc == 0) ? !snd : snd;     // the owner of the next bit
    // (Every signal it reads is an argument: a simulator re-evaluates a
    // function call only when an argument changes.)
    function automatic tl(input [11:0] q, input [5:0] a, input [3:0] x, input dv, input sn,
                          input [1:0] stt, input [1:0] tcc, input dat);
        reg e, wait1;
        begin
            e = x == S_EXEC;
            wait1 = x == S_EDGE;
            if (dv && stt == M_SE0)
                tl = a == PC_AJ && (q == 0 ? e : wait1);
            else if (dv && tcc == 0)
                tl = a == PC_ATURN && (q == 0 ? e : wait1);
            else if (dv)
                tl = q == 0 ? (e && a == PC_END) : 1'b1;
            else if (stt == M_PKT)      // the first SE0: a listener jumps on the break
                tl = sn ? (a == PC_EOP2 && (q == 0 ? e : wait1))
                         : (a == PC_EOP2 && (q == 0 ? x == S_FETCH : q == 12'd1 ? e : wait1));
            else if (stt == M_SE0)
                tl = a == PC_J && (q == 0 ? e : wait1);
            else if (tcc == 0)
                tl = a == PC_TURN && (q == 0 ? e : wait1);
            else
                tl = q == 0 ? (e && a == PC_NODATA) : q == 12'd1 ? (e && a == (dat ? PC_CRCBAD : PC_END)) : 1'b1;
        end
    endfunction
    wire        tail_ok = tl(p, at, s, dev, snd, st, tc, data);
    // The coder in the device's packet and the J after it, and in the J after
    // the host's: with this cell's bit, once read.
    wire [4:0]  n_ack = tail ? 5'd16 + {3'd0, tc} : ph == 2'd2 ? 5'd16 : {1'b0, ph[0], bi};
    wire [21:0] v_ack = ack_code(n_ack + ((read && (pkt || tail)) ? 5'd1 : 5'd0));
    wire [1:0]  n_tail = tail ? tc + {1'b0, read} : 2'd0;
    wire [21:0] v_host = {crc, rl, rval, rval && rv};
    wire [21:0] v_tail = n_tail == 0 ? v_host : n_tail == 2'd1 ? cod_step(v_host, 1'b0)
                         : cod_step(cod_step(v_host, 1'b0), 1'b1);
    wire        seq_open = tail && read && tc == 2'd1 && p >= (dev ? 12'd1 : 12'd2);

`ifdef USB_SIM
    always @(negedge clk_v) begin
`else
    always @* begin
`endif
        if (en) begin
            // Drives: the cell's owner the whole cell, from its edge; the other
            // hart nothing.
            if (!own) begin assert (oe == 2'b00); end
            else if (seq_open) begin end
            else assert (oe == 2'b11 && ov == line);
            // The device joins a host packet from its claim, which sees the K
            // in the packet's first tick: it runs `stuff`, which restarts its
            // coder, then waits on SYNC's first bit, already past its edge. If
            // its hold trap fired a tick before, it is a tick later, via `tmo`.
            if (joining) begin
                assert (x_exec && at == (late ? (tq == 0 ? PC_CLAIM : tq == 12'd1 ? PC_STUFF : PC_SYNC0)
                                              : (tq == 0 ? PC_STUFF : PC_SYNC0)) && rx == sh && armed == pl);
                if (tq < (late ? 12'd2 : 12'd1)) begin assert (code[23:0] == fcode); end
                else assert (code[23:0] == {16'hFFFF, 8'h00});
            end else if (st == M_PKT) begin
                assert (rx == v_sh);
                // The coder.
                if (dev) begin
                    assert (code[23:0] == {v_ack, 2'b00});
                end else if (pkt) begin
                    assert (code[23:8] == (at <= PC_WIDTH ? v_scrc : v_crc));
                    assert (code[7:4] == v_rl && code[3] == v_rval && code[2] == (v_rval && v_rv) && code[0] == 1'b0);
                end
                // Its last sample: this cell once read, else the cell before.
                if (pkt) assert (armed == (read ? line : pl));
            end
            if (pkt && !joining) begin
                if (pre) begin
                    // Sending, or reading, this bit. A listener that moves its
                    // edge to a fall while it waits for its edge is still
                    // waiting on that tick, with its edge moved to the fall.
                    assert ((x_mid && since == tq) || (!snd && x_edge && since == tq));
                    assert (at == pl_cur[9:4] && k == pl_cur[3:0]);
                    if (!dev) assert (code[1] == stuff);
                    assert (mine == snd && src == (stuff ? 2'b10 : ins[22:21]));
                    if (snd) assert (val == own_bit && line[1] == (val ? lvl : !lvl));
                end else begin
                    assert (ahead == d - tq);
                    if (!dev) assert (code[1] == next_stuff);
                    // The bit on the line is still the one the sender sent, until
                    // the host loads its next byte, 5 ticks after the last bit.
                    if (snd && !(!dev && !stuff && ph != 0 && bi == 3'd7 && !crcf && p >= 12'd5))
                        assert (b == own_bit);
                    if (next_stuff || !ends_now) begin
                        // Waiting to send a stuffed bit, or the instruction's next bit.
                        assert (x_edge && at == pl_cur[9:4] && k == pl_cur[3:0] + (next_stuff ? 4'd0 : 4'd1));
                        assert (mine == snd && src == (next_stuff ? 2'b10 : ins[22:21]));
                        if (snd) assert (val == nx_bit);
                    end else begin
                        // The instruction is done: the next ones run one a
                        // tick, the last of them a bit instruction, which then
                        // waits for its edge.
                        assert (aft_ok);
                        if (x_edge) assert (k == 0 && mine == snd && src == (ins[13] ? 2'b10 : ins[22:21]));
                        if (x_edge && snd) assert (val == first_val);
                    end
                end
            end
            // A listener moves its edge to the last fall it saw only when that
            // is within a quarter bit: falls come only where bits start, so its
            // last one is this bit's start, or a bit or more before.
            if (!snd && !joining) assert (!lfv || lf_age == tq || lf_age >= {4'd0, tq} + {4'd0, d});
            // The end of packet, and the J after it. It comes after a whole
            // byte, where no stuffed bit is due; the device's after its PID.
            if (se0) assert (ph == 2'd2 && bi == 0 && !stuff && (!dev || nb == 0));
            if (se0 || tail) begin
                assert (rx == sh && code[1:0] == 2'b00);
                // From the turnaround on the host can claim its next packet,
                // and `stuff` restarts its coder.
                if (at == PC_SYNC0) begin
                    assert (code[23:0] == {16'hFFFF, 8'h00});
                end else assert (code[23:2] == (dev ? v_ack : v_tail));
                assert (armed == (read ? line : se0 && st == M_PKT ? pl : se0 ? L_SE0 : tc == 0 ? L_SE0 : L_J));
                if (pre) begin
                    // The listener of a host packet is still on its next byte
                    // when the end of packet comes.
                    if (!snd && !dev && se0 && st == M_PKT) begin
                        assert ((x_mid || x_edge) && since == tq && at == PC_BYTE && k == 0 && !mine && src == 2'b00);
                    end else begin
                        assert (x_mid && since == tq && at == c_ins && k == c_k && mine == own);
                        if (own) assert (val == c_val);
                    end
                end else begin
                    assert (ahead == d - tq);
                    if (c_more) begin assert (x_edge && at == c_ins && k == c_k + 1'b1 && mine == snd && (!snd || !val) && src == 2'b10); end
                    else begin
                        assert (tail_ok);
                        // Past the turnaround's LOOP and the device's claim,
                        // the harness's own invariants take over.
                        if (x_edge && !seq_open) assert (k == 0 && mine == nxt_own && src == (ins[13] ? 2'b10 : ins[22:21]));
                        if (x_edge && nxt_own && !seq_open) assert (val == first_val);
                    end
                end
            end
        end
    end
endmodule
