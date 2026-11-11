// Unbounded proof by k-induction of one complete protocol: the UART program
// from protocols.py, word for word as the assembler emits it, on two real
// harts. Hart a is the sender (role A) and hart b the receiver (role B).
//
// lockstep_ind.sv proves a subset of the instruction set for any program, and
// compares the two harts tick for tick. That cannot follow `claim`: a receiver
// leaves it only when it sees the line fall, two ticks after the sender drove
// it, and from there on it runs exactly two ticks behind. So this proof fixes
// the program instead, and compares the receiver with the sender as it was
// two ticks earlier.
//
// Free, so the result holds for every choice:
//   BIT         the bit time, any value from MINBIT to 2047 ticks
//   start       the address the program is loaded at, 0 to 55
//   valid, data the sender's queue: any bytes, arriving at any time
//   flt         what the line reads while nothing drives it, on every tick
//   other       the three pins the program does not use, on every tick
//   unwritten   what the other 55 program words hold
//   the receiver's queue, and both address registers
//
// Assumed:
//   - both harts leave reset on the same tick, with no traps, no prescaler
//     and no adversary fault configured;
//   - a queue entry stays until the hart takes it, as in janus_fifo;
//   - the line is low if a hart drives it low, high if one drives it high,
//     and `flt` otherwise. That covers loopback, where an undriven line reads
//     high, and a shared pad with any pull or none.
//
// Claims:
//   DATA   every byte the receiver stores is the byte the sender last took
//          from its queue. Takes and stores alternate, so no byte is lost,
//          repeated or invented, and the sender never sends from an empty
//          queue.
//   WIRE   a monitor that sees only the wire, from the tick the sender first
//          drives it, reads standard frames: a start bit low, the eight bits
//          of the byte the sender took, least significant first, and a stop
//          bit high, each for exactly BIT ticks. Every start bit follows at
//          least BIT ticks of high line, and comes only after a byte was taken.
//   CLEAN  neither hart counts a violation, loses arbitration, clears its
//          queue or stores anything else, and the receiver never drives.
//   LIVE   a hart rests only in boot, between instructions, in the claim, or
//          in a bit's edge or mid state, and the last two end within one bit
//          time. The receiver leaves the claim two ticks after the start bit
//          begins. The program counter stays inside the program.
//
// tb_uart_ind.v simulates this same module with UART_SIM defined: the free
// signals become inputs driven at random, and every assertion is checked once
// a tick. That shows frames do flow under these assumptions, which a bounded
// search to the depth of a frame was too slow to do.
`ifdef UART_SIM
module uart_ind (input clk, input [10:0] BIT, input [5:0] start, input [31:0] unwritten,
                 input [7:0] addr_a, addr_b, input flt, input [2:0] other,
                 input valid_a, valid_b, input [7:0] data_a, data_b,
                 input [1:0] ctl_a, ctl_b);
    parameter MINBIT = 8;

    `include "uart_rom.vh"
`else
module uart_ind (input clk);
    parameter MINBIT = 8;

    `include "uart_rom.vh"

    (* anyconst *) wire [10:0] BIT;
    (* anyconst *) wire [5:0]  start;
    (* anyconst *) wire [31:0] unwritten;
    (* anyconst *) wire [7:0]  addr_a, addr_b;
    (* anyseq *)   wire        flt;
    (* anyseq *)   wire [2:0]  other;
    (* anyseq *)   wire        valid_a, valid_b;
    (* anyseq *)   wire [7:0]  data_a, data_b;
    (* anyseq *)   wire [1:0]  ctl_a, ctl_b;
`endif

    reg [1:0] step = 0;
    wire por = step == 0;
    wire rst = step < 2;
    always @(posedge clk) if (rst) step <= step + 1'b1;

    wire [7:0]  oe_a, ov_a, oe_b, ov_b, count_a, count_b, rx_a, rx_b, pin_a, pin_b, s1_a, s1_b;
    wire [7:0]  armed_a, armed_b, tx_a, tx_b, viol_a, viol_b, vout_a, vout_b, pdata_a, pdata_b;
    wire [87:0] code_a, code_b;
    wire [5:0]  pc_a, pc_b;
    wire [3:0]  s_a, s_b, k_a, k_b;
    wire [4:0]  partial_a, partial_b;
    wire [11:0] now_a, now_b, edge_a, edge_b;
    wire [1:0]  role_a, role_b, src_a, src_b;
    wire        last_a, last_b, mine_a, mine_b, val_a, val_b, clean_a, clean_b;
    wire        pop_a, pop_b, clear_a, clear_b, push_a, push_b, seen_a, seen_b, seen2_a, seen2_b;
    wire        lost_a, lost_b;

    // TX is push-pull: a hart driving it low wins, one driving it high sets
    // it otherwise, and with no driver it reads whatever `flt` says.
    wire        low = (oe_a[0] && !ov_a[0]) || (oe_b[0] && !ov_b[0]);
    wire        high = (oe_a[0] && ov_a[0]) || (oe_b[0] && ov_b[0]);
    wire [7:0]  bus = {4'hF, other, low ? 1'b0 : high ? 1'b1 : flt};
    wire        w = bus[0];

    // Where each hart is in the program, counted from its first word.
    wire [5:0]  at_a = pc_a - start, at_b = pc_b - start;
    wire [31:0] ins_a = uart_word(at_a, BIT, start, unwritten);
    wire [31:0] ins_b = uart_word(at_b, BIT, start, unwritten);

    janus_hart a (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_a), .ov(ov_a),
        .od_mask(8'h00), .base_role(2'd0), .reset_pc(start), .addr_reg(addr_a), .pc(pc_a),
        .pc_sel(), .ins(ins_a), .tx_valid(valid_a), .tx_ctl(ctl_a), .tx_data(data_a),
        .tx_pop(pop_a), .tx_clear(clear_a), .rx_push(push_a), .seen_push(seen_a),
        .seen_push2(seen2_a), .push_data(pdata_a), .push_data2(), .violations(vout_a),
        .arb_lost(lost_a), .cfg_we(1'b0), .cfg_addr(3'd0), .cfg_data(16'd0),
        .dbg_s(s_a), .dbg_count(count_a), .dbg_rx(rx_a), .dbg_last(last_a),
        .dbg_now(now_a), .dbg_edge(edge_a), .dbg_dwell(), .dbg_k(k_a),
        .dbg_partial(partial_a), .dbg_role(role_a), .dbg_src(src_a), .dbg_mine(mine_a),
        .dbg_val(val_a), .dbg_pin(pin_a), .dbg_s1(s1_a), .dbg_armed(armed_a),
        .dbg_code(code_a), .dbg_inserted(), .dbg_stuff_bit(), .dbg_width(),
        .dbg_viol(viol_a), .dbg_tx(tx_a), .dbg_clean(clean_a));

    janus_hart b (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_b), .ov(ov_b),
        .od_mask(8'h00), .base_role(2'd1), .reset_pc(start), .addr_reg(addr_b), .pc(pc_b),
        .pc_sel(), .ins(ins_b), .tx_valid(valid_b), .tx_ctl(ctl_b), .tx_data(data_b),
        .tx_pop(pop_b), .tx_clear(clear_b), .rx_push(push_b), .seen_push(seen_b),
        .seen_push2(seen2_b), .push_data(pdata_b), .push_data2(), .violations(vout_b),
        .arb_lost(lost_b), .cfg_we(1'b0), .cfg_addr(3'd0), .cfg_data(16'd0),
        .dbg_s(s_b), .dbg_count(count_b), .dbg_rx(rx_b), .dbg_last(last_b),
        .dbg_now(now_b), .dbg_edge(edge_b), .dbg_dwell(), .dbg_k(k_b),
        .dbg_partial(partial_b), .dbg_role(role_b), .dbg_src(src_b), .dbg_mine(mine_b),
        .dbg_val(val_b), .dbg_pin(pin_b), .dbg_s1(s1_b), .dbg_armed(armed_b),
        .dbg_code(code_b), .dbg_inserted(), .dbg_stuff_bit(), .dbg_width(),
        .dbg_viol(viol_b), .dbg_tx(tx_b), .dbg_clean(clean_b));

    localparam S_BOOT = 4'd0, S_EXEC = 4'd1, S_CLAIM = 4'd2, S_EDGE = 4'd4, S_MID = 4'd5;

    wire        a_boot = s_a == S_BOOT, a_exec = s_a == S_EXEC, a_claim = s_a == S_CLAIM;
    wire        a_edge = s_a == S_EDGE, a_mid = s_a == S_MID;
    wire        b_boot = s_b == S_BOOT, b_exec = s_b == S_EXEC, b_claim = s_b == S_CLAIM;
    wire        b_edge = s_b == S_EDGE, b_mid = s_b == S_MID;

    wire [11:0] d = {1'b0, BIT};
    wire [11:0] h = {2'b00, BIT[10:1]};          // where a bit is sampled
    wire [11:0] since_a = now_a - edge_a;        // ticks into the bit, in S_MID
    wire [11:0] ahead_a = edge_a - now_a;        // ticks until the next edge, elsewhere
    wire [11:0] since_b = now_b - edge_b;
    wire [11:0] ahead_b = edge_b - now_b;
    wire        lvl = ov_a[0];                   // the level the sender holds on the line
    wire        line1 = s1_a[0], line2 = pin_a[0];   // the line one and two ticks ago
    wire [4:0]  sent = {1'b0, k_a} + 5'd1;       // data bits the sender has started

    // The sender one and two ticks ago.
    reg [5:0]  at_1, at_2;
    reg [3:0]  s_1, s_2, k_1, k_2;
    reg        partial_1, partial_2, last_1, last_2;
    reg [7:0]  rx_1, rx_2;
    reg [11:0] edge_1, edge_2;

    // The byte the sender last took, and whether the receiver still owes it.
    reg [7:0]  cur = 0;
    reg        pend = 0;
    reg        v_q = 0;
    wire       a_load = !rst && a_exec && at_a == PC_LOAD;

    // The monitor. It samples the wire once a tick, as any receiver would, and
    // knows nothing of the harts. A falling edge while idle starts a frame of
    // ten cells, each BIT samples long.
    reg        m_frame = 0;      // inside a frame
    reg        m_seen = 0;       // a frame has started at some time
    reg [3:0]  m_cell = 0;       // 0 start, 1 to 8 data, 9 stop
    reg [10:0] m_q = 0;          // samples of this cell already taken
    reg        m_prev = 1;       // the sample before
    reg [10:0] m_high = 0;       // high samples in a row, counted up to BIT
    wire       m_bit = m_cell == 0 ? 1'b0 : m_cell == 4'd9 ? 1'b1 : cur[m_cell[2:0] - 3'd1];

    always @(posedge clk) begin
        {at_2, s_2, k_2, partial_2, last_2, rx_2, edge_2}
            <= {at_1, s_1, k_1, partial_1, last_1, rx_1, edge_1};
        {at_1, s_1, k_1, partial_1, last_1, rx_1, edge_1}
            <= {at_a, s_a, k_a, partial_a[0], last_a, rx_a, edge_a};
        v_q <= valid_a;
        if (rst) begin
            cur <= 0;
            pend <= 0;
        end else if (a_load) begin
            cur <= valid_a ? data_a : 8'hFF;     // what `load` puts in the shifter
            pend <= 1'b1;
        end else if (push_b) pend <= 1'b0;

        if (rst || !oe_a[0]) begin               // nothing to read until the line is driven
            m_frame <= 0;
            m_seen <= 0;
            m_cell <= 0;
            m_q <= 0;
            m_prev <= 1'b1;
            m_high <= 0;
        end else begin
            m_prev <= w;
            m_high <= !w ? 11'd0 : m_high == BIT ? BIT : m_high + 1'b1;
            if (!m_frame) begin
                if (m_prev && !w) begin
                    m_frame <= 1'b1;
                    m_seen <= 1'b1;
                    m_cell <= 0;
                    m_q <= 11'd1;
                end
            end else if (m_q == BIT - 1'b1) begin
                m_q <= 0;
                if (m_cell == 4'd9) m_frame <= 1'b0;
                else m_cell <= m_cell + 1'b1;
            end else m_q <= m_q + 1'b1;
        end
    end

    // Where the monitor's count puts the sender: q samples of cell c taken
    // means the sender drove that cell q ticks ago.
    wire [11:0] q = {1'b0, m_q};
    wire        a_mid_cell = a_mid && (m_cell == 0 ? at_a == PC_START
                                       : m_cell == 4'd9 ? at_a == PC_STOP
                                       : at_a == PC_DATA && k_a == m_cell - 1'b1);
    wire        a_past_cell = !a_mid && (m_cell == 0 ? at_a == PC_DATA && (a_exec || k_a == 0)
                                         : m_cell == 4'd8 ? at_a == PC_STORE || at_a == PC_STOP
                                         : m_cell == 4'd9 ? at_a == PC_JUMP || at_a == PC_CLAIM
                                                            || at_a == PC_LOAD || at_a == PC_START
                                         : at_a == PC_DATA && a_edge && k_a == m_cell);

`ifdef UART_SIM
    always @(negedge clk) begin                  // once a tick, with everything settled
`else
    always @* begin
`endif
        assume (BIT >= MINBIT);
        assume (start <= MAX_START);
        // The queue: an entry stays until the hart takes it.
        if (v_q && !pop_a) assume (valid_a);

        assert (step <= 2'd2);
        if (!por) assert (clean_a && clean_b);
        if (!rst) begin
            // CLEAN
            assert (viol_a == 0 && viol_b == 0 && vout_a == 0 && vout_b == 0);
            assert (!lost_a && !lost_b && !clear_a && !clear_b);
            assert (!push_a && !seen_a && !seen_b && !seen2_a && !seen2_b && !pop_b);
            assert (oe_b == 0 && oe_a[7:1] == 0);
            assert (role_a == 2'd0 && role_b == 2'd1);
            assert (code_a == 0 && code_b == 0 && count_a == 0 && count_b == 0);

            // LIVE
            assert (a_boot || a_exec || a_claim || a_edge || a_mid);
            assert (b_boot || b_exec || b_claim || b_edge || b_mid);
            assert (at_a < PROG_LEN && at_b < PROG_LEN);
            if (a_mid) assert (since_a < h);
            else assert (ahead_a <= d);
            if (b_mid) assert (since_b < h);
            else assert (ahead_b <= d);

            // DATA
            if (a_load) assert (valid_a && !pend);
            if (push_b) assert (pend && pdata_b == cur);
            assert (pop_a == (a_exec && at_a == PC_START));
            assert (push_b == (b_exec && at_b == PC_STOP));
            assert (pend == (at_a == PC_START || at_b == PC_LOAD || at_b == PC_START
                             || at_b == PC_DATA || at_b == PC_STORE
                             || (at_b == PC_STOP && b_exec)));

            // WIRE: what the monitor is about to sample.
            if (oe_a[0]) begin
                if (m_frame) assert (w == m_bit);
                // A low sample outside a frame can only be a new start bit.
                else if (!w) assert (m_prev && m_high == BIT && pend);
            end

            // Both harts see the same pins at the same time.
            assert (now_a == now_b && pin_a == pin_b && s1_a == s1_b);

            // The sender, instruction by instruction. `lvl` is what it drives;
            // the line shows a new level one tick later in s1 and two in pin.
            if (a_boot) assert (at_a == PC_SET);
            if (a_claim) assert (at_a == PC_CLAIM);
            if (a_edge || a_mid) begin
                assert (mine_a && src_a == ins_a[22:21]);
                assert (at_a == PC_IDLE || at_a == PC_START || at_a == PC_DATA || at_a == PC_STOP);
            end
            if (a_edge) assert (ahead_a != 0 && at_a != PC_IDLE);
            assert (partial_a[0] == (at_a == PC_DATA && !a_exec && k_a != 0));
            if (at_a != PC_START && at_a != PC_DATA) assert (rx_a == cur);
            if (at_a != PC_SET) assert (oe_a[0]);
            case (at_a)
                PC_SET: assert (!oe_a[0] && edge_a == now_a && k_a == 0);
                PC_IDLE: begin
                    assert (lvl && k_a == 0);
                    if (a_exec) assert (edge_a == now_a);
                    if (a_mid) assert (val_a && line1 && (since_a == 0 || line2));
                end
                PC_CLAIM: assert (lvl && line1 && line2 && k_a == 0);
                PC_LOAD: assert (a_exec && lvl && line1 && line2 && k_a == 0 && v_q && !pop_a);
                PC_START: begin
                    assert (tx_a == cur && k_a == 0);
                    if (!a_mid) assert (lvl && line1 && line2);
                    if (!a_exec) assert (!val_a);
                    // The start bit: the line follows one and two ticks later.
                    if (a_mid) assert (!lvl && line1 == (since_a == 0) && line2 == (since_a <= 1));
                end
                PC_DATA: begin
                    assert (k_a <= 4'd7);
                    if (a_exec) assert (!lvl && !line1 && !line2 && tx_a == cur && k_a == 0
                                        && ahead_a == d - h);
                    // Waiting for the next edge, the last bit is still on the line.
                    if (a_edge) assert (line1 == lvl && line2 == lvl
                                        && lvl == (k_a == 0 ? 1'b0 : cur[k_a[2:0] - 3'd1]));
                    if (a_mid) assert (lvl == val_a && (since_a == 0 || line1 == lvl)
                                       && (since_a <= 1 || line2 == lvl));
                    if (!a_exec) begin
                        // Bit k is on its way; the bits before it have been read back.
                        assert (val_a == cur[k_a[2:0]]);
                        assert (tx_a == (cur >> sent));
                        assert ((rx_a >> (4'd8 - k_a)) == (cur & ~(8'hFF << k_a)));
                    end
                end
                PC_STORE: assert (a_exec && line1 == lvl && line2 == lvl && lvl == cur[7]
                                  && k_a == 4'd7 && ahead_a == d - h);
                PC_STOP: begin
                    if (a_exec) assert (k_a == 4'd7);
                    if (!a_mid) assert (line1 == lvl && line2 == lvl && lvl == cur[7]);
                    if (!a_exec) assert (val_a && k_a == 0);
                    if (a_mid) assert (lvl && (since_a == 0 || line1) && (since_a <= 1 || line2));
                end
                PC_JUMP: assert (a_exec && lvl && line1 && line2 && k_a == 0 && ahead_a == d - h);
                default: assert (0);
            endcase

            // The receiver.
            if (b_boot) assert (at_b == PC_SET);
            if (b_claim) assert (at_b == PC_CLAIM);
            if (b_edge || b_mid) begin
                assert (!mine_b && src_b == ins_b[22:21] && k_b <= ins_b[20:17]);
                assert (at_b == PC_IDLE || at_b == PC_START || at_b == PC_DATA || at_b == PC_STOP);
            end
            if (b_edge) assert (at_b == PC_DATA || at_b == PC_STOP);
            if (at_b == PC_LOAD || at_b == PC_STORE || at_b == PC_JUMP) assert (b_exec);
            if (at_b == PC_STORE || at_b == PC_STOP || at_b == PC_JUMP) assert (rx_b == cur);
            if (at_b == PC_JUMP) assert (armed_b[0]);

            if (at_b == PC_SET || at_b == PC_IDLE) begin
                // Start-up: the two run side by side.
                assert (at_a == at_b && s_a == s_b && edge_a == edge_b);
                assert (k_b == 0 && !partial_b[0] && rx_b == rx_a && last_b == last_a);
            end else if (at_b == PC_CLAIM || (b_exec && (at_b == PC_LOAD || at_b == PC_START))) begin
                // Waiting for the start bit, and the two ticks after seeing it.
                assert (armed_b[0] && k_b == 0 && !partial_b[0]);
                assert (rx_b == rx_a && last_b == last_a);
                if (at_b == PC_CLAIM && b_exec)
                    assert (at_a == PC_CLAIM || at_a == PC_LOAD || (at_a == PC_START && a_exec));
                if (b_claim)
                    assert ((at_a == PC_CLAIM && a_claim) || at_a == PC_LOAD
                            || (at_a == PC_START && (!a_mid || since_a <= 1)));
                // The receiver sees the line fall two ticks after the sender drove it.
                if (at_b == PC_LOAD) assert (at_a == PC_START && a_mid && since_a == 2);
                if (at_b == PC_START) assert (at_a == PC_START && a_mid && since_a == 3);
            end else begin
                // From here to the end of the frame the receiver is the sender
                // of two ticks ago.
                assert (at_b == at_2 && s_b == s_2 && k_b == k_2 && partial_b[0] == partial_2);
                assert (last_b == last_2 && rx_b == rx_2 && edge_b == edge_2 + 12'd2);
                assert (b_exec || b_edge || b_mid);
            end

            // The monitor against the sender. Before the sender drives, the
            // monitor is held in reset.
            assert (m_high <= BIT);
            if (at_a == PC_SET) assert (!m_frame && !m_seen && m_prev && m_high == 0);
            else if (m_frame) begin
                assert (m_seen && m_cell <= 4'd9 && m_q < BIT && (m_cell != 0 || m_q != 0));
                if (q < h) assert (a_mid_cell && since_a == q);
                else assert (a_past_cell && ahead_a == d - q);
                if (m_cell == 4'd9) assert (m_high >= m_q);
            end else begin
                assert (m_prev);
                if (m_seen) begin
                    // Between frames: the stop bit has lasted BIT ticks or more.
                    assert (m_high == BIT);
                    assert (at_a == PC_START && a_mid ? since_a == 0
                            : ahead_a == 0 && (at_a == PC_CLAIM || at_a == PC_LOAD
                                               || at_a == PC_START));
                end else begin
                    // Before the first frame: the high samples so far.
                    assert (at_a == PC_IDLE || at_a == PC_CLAIM || at_a == PC_LOAD
                            || at_a == PC_START);
                    if (at_a == PC_IDLE) assert (m_high == (a_mid ? since_a + 1'b1 : 12'd0));
                    else if (a_mid) assert (since_a == 0 && m_high == BIT);
                    else assert ({1'b0, m_high} == (ahead_a == 0 ? d : d + 1'b1 - ahead_a));
                end
            end
        end
    end
endmodule
