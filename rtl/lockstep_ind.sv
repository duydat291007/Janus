// Unbounded proof by k-induction: two real harts, opposite roles, one wire, and
// ANY program: the instruction is a free input that is only required to be
// well-formed and stable while pc stands, which allows more behaviour than any
// real memory. Induction does not unroll from reset, so if it closes, the claim
// holds at every tick of every run of every allowed program.
//
// Subset: timed bits including sync, on one pin, with run-length stuffing and
// CRC, plus load, store, branch, counter, and mode writes to bit order,
// stuffing, polynomial and CRC width. The pair, NRZI, ones-only stuffing, CRC
// start value and residual, and break bits are outside the subset. The assumption `sync_line_ok` is the sync rule that check_sync.py
// verifies statically: the line is at the opposite level when a sync bit starts.
//
// Claims:
//   DATA:  at every sample point the wire carries the owner's bit, so what the
//          listener reads is what the owner sent.
//   AGREE: both harts hold the same pc, last, counter, received bits, time and
//          pins at every tick, and the same control state and bit edge at every
//          tick outside the short window while a listener waits on a sync bit.
//          Coder state (CRC, run length, configuration) is identical too.
//   LIVE:  a hart is only in S_EDGE, S_MID or S_SYNC between instructions, so
//          a conforming pair never takes the false stuff-error exit. Edge
//          and mid end on a time comparison with the distance bounded, and a
//          listener leaves S_SYNC no later than 2 ticks after the owner drives.
module lockstep_ind (input clk);
    parameter D = 8;              // smallest bit time a program may use

    (* anyseq *) wire [31:0] ins;      // any well-formed word, stable while pc stands
    (* anyseq *) wire [7:0] data_a, data_b;

    function automatic wf(input [31:0] i);
        reg [3:0] op;
        begin
            op = i[31:28];
            case (op)
                4'd1: wf = i[27:25] == 0 && i[24:23] < 2
                        && (!i[16] || (i[22] && i[20:17] == 0))
                        && !i[15] && !i[13] && i[10:0] >= D;
                4'd3: wf = i[27:26] < 2;
                4'd4: wf = i[27:26] <= 2 && !i[25];
                4'd5: wf = i[27:25] <= 5;
                4'd8: wf = 1'b1;
                4'd9: wf = i[27:23] == 0 || i[27:23] == 3
                        || (i[27:23] == 2 && i[3:0] != 1 && !i[4])
                        || (i[27:23] == 4 && i[4:0] >= 1 && i[4:0] <= 16 && !i[5]);
                default: wf = 1'b0;
            endcase
        end
    endfunction

    reg [1:0] step = 0;
    wire por = step == 0;
    wire rst = step < 2;
    always @(posedge clk) if (rst) step <= step + 1'b1;

    wire [7:0]  oe_a, ov_a, oe_b, ov_b, count_a, count_b, rx_a, rx_b, pin_a, pin_b, s1_a, s1_b;
    wire [7:0]  armed_a, armed_b;
    wire [50:0] code_a, code_b;
    wire [4:0]  width_a, width_b;
    wire        stuffed_a, stuffed_b, stuff_bit_a, stuff_bit_b;
    wire [5:0]  pc_a, pc_b;
    wire [3:0]  s_a, s_b, k_a, k_b;
    wire [4:0]  partial_a, partial_b;
    wire [11:0] now_a, now_b, edge_a, edge_b;
    wire [10:0] dwell_a, dwell_b;
    wire [1:0]  role_a, role_b, src_a, src_b;
    wire        last_a, last_b, mine_a, mine_b, val_a, val_b, clean_a, clean_b;
    wire        low = (oe_a[0] && !ov_a[0]) || (oe_b[0] && !ov_b[0]);
    wire [7:0]  bus = {7'h7F, !low};

    janus_hart a (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_a), .ov(ov_a),
        .od_mask(8'h01), .base_role(2'd0), .reset_pc(6'd0), .addr_reg(8'd0), .pc(pc_a), .ins(ins),
        .tx_valid(1'b1), .tx_ctl(2'd0), .tx_data(data_a),
        .tx_pop(), .tx_clear(), .rx_push(), .seen_push(), .seen_push2(),
        .push_data(), .push_data2(), .violations(), .arb_lost(),
        .cfg_we(1'b0), .cfg_addr(3'd0), .cfg_data(16'd0),
        .dbg_s(s_a), .dbg_count(count_a), .dbg_rx(rx_a), .dbg_last(last_a),
        .dbg_now(now_a), .dbg_edge(edge_a), .dbg_dwell(dwell_a), .dbg_k(k_a),
        .dbg_partial(partial_a), .dbg_role(role_a), .dbg_src(src_a), .dbg_mine(mine_a),
        .dbg_val(val_a), .dbg_pin(pin_a), .dbg_s1(s1_a), .dbg_armed(armed_a),
        .dbg_code(code_a), .dbg_inserted(stuffed_a), .dbg_stuff_bit(stuff_bit_a),
        .dbg_width(width_a),
        .dbg_clean(clean_a));

    janus_hart b (.clk(clk), .por(por), .rst(rst), .wire_in(bus), .oe(oe_b), .ov(ov_b),
        .od_mask(8'h01), .base_role(2'd1), .reset_pc(6'd0), .addr_reg(8'd0), .pc(pc_b), .ins(ins),
        .tx_valid(1'b1), .tx_ctl(2'd0), .tx_data(data_b),
        .tx_pop(), .tx_clear(), .rx_push(), .seen_push(), .seen_push2(),
        .push_data(), .push_data2(), .violations(), .arb_lost(),
        .cfg_we(1'b0), .cfg_addr(3'd0), .cfg_data(16'd0),
        .dbg_s(s_b), .dbg_count(count_b), .dbg_rx(rx_b), .dbg_last(last_b),
        .dbg_now(now_b), .dbg_edge(edge_b), .dbg_dwell(dwell_b), .dbg_k(k_b),
        .dbg_partial(partial_b), .dbg_role(role_b), .dbg_src(src_b), .dbg_mine(mine_b),
        .dbg_val(val_b), .dbg_pin(pin_b), .dbg_s1(s1_b), .dbg_armed(armed_b),
        .dbg_code(code_b), .dbg_inserted(stuffed_b), .dbg_stuff_bit(stuff_bit_b),
        .dbg_width(width_b),
        .dbg_clean(clean_b));

    localparam S_BOOT = 4'd0, S_EXEC = 4'd1, S_SYNC = 4'd3, S_EDGE = 4'd4, S_MID = 4'd5;

    // Decode the instruction by party, whichever hart plays which part.
    wire        is_bits = ins[31:28] == 4'd1;
    wire        is_sync = is_bits && ins[16];
    wire        want = ins[21];
    wire        owner_a = ins[24:23] == 2'd0;
    wire [3:0]  s_o = owner_a ? s_a : s_b;
    wire [3:0]  s_l = owner_a ? s_b : s_a;
    wire [11:0] edge_o = owner_a ? edge_a : edge_b;
    wire [11:0] edge_l = owner_a ? edge_b : edge_a;
    wire        val_o = owner_a ? val_a : val_b;
    wire        val_l = owner_a ? val_b : val_a;
    wire        oe_o = owner_a ? oe_a[0] : oe_b[0];
    wire        ov_o = owner_a ? ov_a[0] : ov_b[0];
    wire        oe_l = owner_a ? oe_b[0] : oe_a[0];
    wire [7:0]  armed_l = owner_a ? armed_b : armed_a;

    wire        waiting = s_a == S_SYNC || s_b == S_SYNC;
    wire        in_bit = waiting || s_a == S_EDGE || s_a == S_MID
                         || s_b == S_EDGE || s_b == S_MID;
    wire [1:0]  src_expected = stuffed_a ? {1'b1, stuff_bit_a} : ins[22:21];
    wire [11:0] next_now = now_a + 1'b1;
    wire [11:0] since = now_a - edge_o;
    wire [11:0] to_edge = edge_o - now_a;
    wire [11:0] back_a = now_a - edge_a;
    wire [11:0] ahead_a = edge_a - now_a;
    wire [11:0] back_b = now_a - edge_b;
    wire [11:0] ahead_b = edge_b - now_a;
    wire [11:0] past_mid = next_now - (edge_o + (dwell_a >> 1));
    // This tick's clock edge takes the sample: pin will then hold today's s1.
    wire        sampling = in_bit && s_o == S_MID && !past_mid[11];

    reg [31:0] ins_q;
    reg [5:0]  pc_q;
    reg        have = 0;
    always @(posedge clk) begin
        ins_q <= ins;
        pc_q <= pc_a;
        have <= !rst;
    end

    wire exec_sync = !rst && s_a == S_EXEC && s_b == S_EXEC && is_sync;
    wire sync_line_ok = bus[0] != want;
    // Coder rule: stuffing and CRC bits need a CRC width set beforehand.
    wire uses_coder = (is_bits && ins[22:21] == 2'd1)
                      || (ins[31:28] == 4'd9 && ins[27:23] == 5'd2 && ins[3:0] != 0);

    always @* begin
        assume (wf(ins));
        if (have && pc_a == pc_q) assume (ins == ins_q);
        if (exec_sync) assume (sync_line_ok);
`ifdef STUFF_COVER
        // Fix a tiny program so stuffed bits are reached quickly: set the CRC
        // width, set stuffing to 2, then six constant bits of either value.
        if (pc_a == 6'd0) assume (ins == 32'h9200_000F);
        if (pc_a == 6'd1) assume (ins == 32'h9100_0002);
        if (pc_a == 6'd2) assume ((ins & ~32'h0020_0000) == 32'h104A_0004);
        if (pc_a >= 6'd3) assume (ins == 32'h5000_0003);
`endif
        if (!rst && s_a == S_EXEC && uses_coder) assume (width_a != 0);

        assert (step <= 2'd2);
        if (!por) assert (clean_a && clean_b);
        if (!rst) begin
            // AGREE
            assert (pc_a == pc_b);
            assert (partial_a == partial_b);
            assert (last_a == last_b);
            assert (count_a == count_b);
            assert (rx_a == rx_b);
            assert (now_a == now_b);
            assert (dwell_a == dwell_b);
            assert (pin_a == pin_b);
            assert (s1_a == s1_b);
            assert (code_a == code_b);
            assert (stuffed_a == stuffed_b);
            if (!waiting) begin
                assert (s_a == s_b);
                assert (edge_a == edge_b);
            end

            // DATA
            if (sampling) assert (s1_a[0] == val_o);

            // LIVE: only these states exist
            assert (s_a == S_BOOT || s_a == S_EXEC || s_a == S_SYNC || s_a == S_EDGE || s_a == S_MID);
            assert (s_b == S_BOOT || s_b == S_EXEC || s_b == S_SYNC || s_b == S_EDGE || s_b == S_MID);

            // Supporting invariants
            assert (role_a == 2'd0 && role_b == 2'd1);
            assert (back_a[11] ? (ahead_a <= 12'd2047) : (back_a <= 12'd2047));
            assert (back_b[11] ? (ahead_b <= 12'd2047) : (back_b <= 12'd2047));

            if (s_a == S_EXEC || s_a == S_BOOT) begin
                assert (s1_a == pin_a);
                assert (armed_a == pin_a && armed_b == pin_a);
                assert (bus == pin_a);
            end

            if (in_bit) begin
                assert (is_bits);
                assert (k_a == k_b);
                assert (k_a <= ins[20:17]);
                assert (dwell_a == ins[10:0]);
                assert (src_a == src_expected && src_b == src_expected);
                assert (mine_a == owner_a && mine_b == !owner_a);
                if (src_expected[1]) assert (val_o == src_expected[0]);
                if (stuffed_a) assert (stuff_bit_a == stuff_bit_b && code_a[1] != code_a[0]);
                if (s_o == S_EDGE) begin
                    assert (s1_a == pin_a);
                    assert (bus == pin_a);
                    assert (armed_a == pin_a && armed_b == pin_a);
                end
                if (s_o == S_MID) begin
                    assert (oe_o && ov_o == val_o);
                    assert (!oe_l);
                    assert (!since[11] && since <= (dwell_a >> 1));
                    if (since >= 12'd1) assert (s1_a[0] == val_o);
                    if (since >= 12'd2) assert (pin_a[0] == val_o);
                end
            end

            // The window while a listener waits on a sync bit
            if (waiting) begin
                assert (is_sync);
                assert (s_l == S_SYNC);
                assert (s_o == S_EDGE || s_o == S_MID);
                assert (!stuffed_a);
                assert (val_l == want);
                assert (armed_l[0] != want);
                assert (!oe_l || edge_l == edge_o);
                if (s_o == S_EDGE) assert (pin_a[0] != want);
                if (s_o == S_MID) assert (!since[11] && since <= 12'd1);
            end

            // Vacuity
            cover (sampling && is_sync && want);
            cover (sampling && stuffed_a && val_o);
            cover (sampling && stuffed_a && !val_o);
            cover (sampling && ins[22:21] == 2'd1 && val_o);
            cover (sampling && is_sync && !want);
            cover (sampling && owner_a && !val_o && ins[22:21] == 2'd0);
            cover (sampling && !owner_a && val_o && ins[22:21] == 2'd0);
            cover (s_a == S_EXEC && ins[31:28] == 4'd5 && ins[27:25] == 3'd2 && last_a);
        end
    end
endmodule
