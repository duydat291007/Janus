// verilator lint_off BLKSEQ
// One Janus hart. Follows janus.py tick for tick, and is checked against it.
//
// The clocked block uses blocking assignments on purpose: within one clock it
// runs like the Python generator, so a state can fall through into the next
// one in the same tick. States are in order for that reason.
//
// Prescaling is not modelled in janus.py. With prescaler D (mode field 12)
// the hart acts on one clock in D+1 and holds still on the others, so it
// matches the model with every tick D+1 clocks long. div_replay.sh checks it.
module janus_hart (
    input             clk,
    input             por,         // power-on: clears traps; held off while loading
    input             rst,         // holds the hart while a host loads a program
    input      [7:0]  wire_in,
    output reg [7:0]  oe,
    output reg [7:0]  ov,
    input      [7:0]  od_mask,
    input      [1:0]  base_role,
    input      [5:0]  reset_pc,
    input      [7:0]  addr_reg,
    output reg [5:0]  pc,
    output reg [63:0] pc_sel,      // pc as one-hot, so a fetch is a narrow AND-OR
    input      [31:0] ins,
    input             tx_valid,
    input      [1:0]  tx_ctl,      // 0 data, 1 STOP, 2 RESTART
    input      [7:0]  tx_data,
    output reg        tx_pop,
    output reg        tx_clear,
    output reg        rx_push,
    output reg        seen_push,
    output reg        seen_push2,
    output reg [7:0]  push_data,
    output reg [7:0]  push_data2,
    output reg [7:0]  violations,
    output reg        arb_lost,
    input             cfg_we,
    input      [2:0]  cfg_addr,
    input      [15:0] cfg_data
`ifdef FORMAL
    ,
    output     [3:0]  dbg_s,
    output     [7:0]  dbg_count,
    output     [7:0]  dbg_rx,
    output            dbg_last,
    output     [11:0] dbg_now,
    output     [11:0] dbg_edge,
    output     [10:0] dbg_dwell,
    output     [3:0]  dbg_k,
    output     [4:0]  dbg_partial,
    output     [1:0]  dbg_role,
    output     [1:0]  dbg_src,
    output            dbg_mine,
    output            dbg_val,
    output     [7:0]  dbg_pin,
    output     [7:0]  dbg_s1,
    output     [7:0]  dbg_armed,
    output     [87:0] dbg_code,
    output            dbg_inserted,
    output            dbg_stuff_bit,
    output     [4:0]  dbg_width,
    output     [7:0]  dbg_viol,
    output            dbg_clean
`endif
);

    // Internal state uses blocking assignments. The ports below are ordinary
    // flops holding the same values, so neighbouring modules see them change
    // after the clock edge, as they will in silicon.
    reg [3:0]  oe_r, ov_r;             // a hart uses at most 4 pins
    reg [7:0]  push_data_r, push_data2_r, violations_r;
    reg [5:0]  pc_r;
    reg        tx_pop_r, tx_clear_r, rx_push_r, seen_push_r, seen_push2_r, arb_lost_r;
    localparam WITNESS = 2'd3, ALL = 2'd2, LOSE_NONE = 2'd2;
    localparam OP_SET = 0, OP_BITS = 1, OP_CLAIM = 2, OP_LOAD = 3, OP_STORE = 4,
               OP_BRANCH = 5, OP_CHOICE = 6, OP_MATCH = 7, OP_COUNTER = 8, OP_MODE = 9;
    localparam S_BOOT = 0, S_EXEC = 1, S_CLAIM = 2, S_SYNC = 3, S_EDGE = 4, S_MID = 5,
               S_SETTLE = 6, S_POST = 7, S_CK_ENTER = 8, S_CK_GAP = 9, S_CK_TOP = 10,
               S_CK_AW = 11, S_CK_AS = 12, S_CK_BW = 13, S_CK_BS = 14, S_FETCH = 15;

    // Instruction fields
    wire [3:0]  op      = ins[31:28];
    wire [1:0]  i_pin   = ins[26:25];
    wire [1:0]  i_owner = ins[24:23];
    wire [1:0]  i_src   = ins[22:21];
    wire [3:0]  i_n     = ins[20:17];
    wire        i_sync  = ins[16];
    wire        i_clkd  = ins[15];
    wire        i_strm  = ins[14];     // clocked: stream. timed: free, no check
    wire        i_brk   = ins[13];     // timed: a break, the pin and its pair low
    wire [10:0] i_dwell = ins[10:0];
    wire [1:0]  i_party = ins[27:26];

    // Configuration
    reg [15:0] cfg0, cfg1, cfg2, cfg3, cfg4, cfg5;   // traps 0-3, hold counts 4-5
    reg [15:0] cfg6;                   // adversary: bit 15 enable, 11:0 which owned bit
    reg        c_msb, c_rs_en, c_cpol, c_cpha, c_l2_en;
    reg [1:0]  c_rs_pin, c_clk, c_l2_pin;
    reg [3:0]  c_stuff;
    reg [15:0] c_poly;
    reg [4:0]  c_width;
    reg [5:0]  c_err;
    reg [1:0]  c_lose, c_clk_own, c_l2_own;
    reg [7:0]  c_div, div_cnt;
    reg        c_ones, c_init1, c_pair_en, c_nrzi, c_brk_en;
    reg [1:0]  c_pair;
    reg [15:0] c_resid;
    reg [5:0]  c_brk;
    reg [15:0] c_xor;                  // XORed onto CRC bits as sent: bit k onto bit k
    reg [11:0] f_cnt;                  // timed bits this hart has owned
    reg        f_armed, faulty;        // the fault is still to come; this bit is it

    // Hart state
    // Keep synthesis from re-encoding this as a state machine. The blocking
    // style lets one tick pass through several states, and FSM extraction
    // then builds an enormous transition table and never finishes.
    (* fsm_encoding = "none" *) reg [3:0] s;
    reg [3:0]  s1, pin, prev;
    reg [3:0]  armed;                  // pin levels when last sampled
    reg [1:0]  role;
    reg [7:0]  tx, rx0, rx1, count;
    reg        last, seen, val, cur_mine, inserted, stuff_bit, run_valid, run_val;
    reg [3:0]  k, run_len;
    reg        partial;                // inside a frame, past its first bit
    reg [11:0] now, edge_t, last_fall; // wide enough for the longest dwell
    reg [15:0] crc, held0, held1;
    reg        lf_valid;
    reg [10:0] cnt;

    // Temporaries
    reg        fired, taken, is_data, src_const, fb, level, lvl, raw, broke, coded;
    reg [5:0]  fire_to;
    reg [11:0] diff;
    reg [15:0] tw;
    reg [7:0]  masked;
    reg [1:0]  src_eff;
    integer    j;

`ifdef FORMAL
    assign dbg_s = s;
    assign dbg_count = count;
    assign dbg_rx = rx0;
    assign dbg_last = last;
    assign dbg_now = now;
    assign dbg_edge = edge_t;
    assign dbg_dwell = i_dwell;
    assign dbg_k = k;
    assign dbg_partial = {4'd0, partial};
    assign dbg_role = role;
    assign dbg_src = src_eff;
    assign dbg_mine = cur_mine;
    assign dbg_val = val;
    assign dbg_pin = {4'hF, pin};
    assign dbg_s1 = {4'hF, s1};
    assign dbg_armed = {4'hF, armed};
    assign dbg_code = {c_pair_en, c_pair, c_nrzi, c_xor, c_resid, c_init1, c_ones,
                       c_stuff, c_poly, c_width, c_msb, crc, run_len, run_valid,
                       run_valid & run_val, inserted, inserted & stuff_bit};
    assign dbg_inserted = inserted;
    assign dbg_stuff_bit = stuff_bit;
    assign dbg_width = c_width;
    assign dbg_viol = violations_r;
    // Everything the restricted program subset can never change from reset.
    assign dbg_clean = !c_rs_en && !lf_valid && c_lose == WITNESS
        && !c_l2_en && c_div == 0 && div_cnt == 0
        && !cfg0[15] && !cfg1[15] && !cfg2[15] && !cfg3[15]
        && !c_brk_en
        && !cfg6[15] && !f_armed && !faulty;
`endif

    function automatic is_mine(input [1:0] party, input [1:0] r);
        is_mine = (party == ALL) ? (r != WITNESS) : (r == party);
    endfunction

    function automatic is_before(input [11:0] a, input [11:0] b);
        reg [11:0] d;
        begin
            d = a - b;
            is_before = d[11];
        end
    endfunction

    task drive(input [1:0] p, input v);
        begin
            oe_r[p] = 1'b1;
            ov_r[p] = v;
        end
    endtask

    task release_pin(input [1:0] p);
        oe_r[p] = 1'b0;
    endtask

    // A timed bit's pin and, with a pair, its complement. A break drives both low.
    task put(input [1:0] p, input v, input brk);
        begin
            drive(p, v);
            if (c_pair_en) drive(c_pair, brk ? v : !v);
        end
    endtask

    task put_release(input [1:0] p);
        begin
            release_pin(p);
            if (c_pair_en) release_pin(c_pair);
        end
    endtask

    task restart_crc;
        crc = c_init1 ? ~(16'hFFFF << c_width) : 16'd0;
    endtask

    // The count stops at 255. Wrapping to 0 would read as a clean run.
    task violate;
        if (violations_r != 8'hFF) violations_r = violations_r + 1'b1;
    endtask

    task fire(input [5:0] target);
        begin
            if (partial) violate;
            partial = 0;
            role = base_role;
            edge_t = now;
            armed = pin;
            pc_r = target;
            s = S_EXEC;
            fired = 1'b1;
        end
    endtask

    task shift_in(input lane, input b);
        begin
            last = b;
            if (lane) rx1 = c_msb ? {rx1[6:0], b} : {b, rx1[7:1]};
            else      rx0 = c_msb ? {rx0[6:0], b} : {b, rx0[7:1]};
        end
    endtask

    task next_tx;
        begin
            if (c_msb) begin val = tx[7]; tx = {tx[6:0], 1'b0}; end
            else       begin val = tx[0]; tx = {1'b0, tx[7:1]}; end
        end
    endtask

    task resync(input none);
        begin
            diff = last_fall - edge_t;
            if (diff[11]) diff = -diff;
            if (none && lf_valid && diff <= {3'b0, i_dwell[10:2]}) edge_t = last_fall;
        end
    endtask

    task lose(input [1:0] p, input also, input [1:0] p2);
        begin
            role = c_lose;
            arb_lost_r = 1'b1;
            tx_clear_r = 1'b1;
            put_release(p);
            if (also) release_pin(p2);
        end
    endtask

    task finish;
        begin
            partial = 0;
            pc_r = pc_r + 1'b1;
            s = S_EXEC;
        end
    endtask

    task start_bit;
        begin
            partial = k != 0;
            cur_mine = is_mine(i_owner, role);
            src_eff = inserted ? {1'b1, stuff_bit} : i_brk ? 2'd2 : i_src;
            if (!inserted && i_sync && !cur_mine) begin
                // Under NRZI the awaited change is away from the level last sampled.
                val = (c_nrzi && !i_brk) ? !armed[i_pin] : src_eff[0];
                s = S_SYNC;
            end else begin
                if (cur_mine) begin
                    if (src_eff == 2'd0) next_tx;
                    else if (src_eff == 2'd1) val = crc[c_width - 1'b1] ^ c_xor[k];
                    else val = src_eff[0];
                end
                s = S_EDGE;
            end
        end
    endtask

    task bit_done;
        begin
            inserted = 1'b0;
            if (k == i_n) finish;
            else begin
                k = k + 1'b1;
                start_bit;
            end
        end
    endtask

    task lanes_out;
        begin
            if (is_mine(i_owner, role)) begin
                next_tx;
                drive(i_pin, val);
            end else release_pin(i_pin);
            if (c_l2_en) begin
                if (is_mine(c_l2_own, role)) begin
                    next_tx;
                    drive(c_l2_pin, val);
                end else release_pin(c_l2_pin);
            end
        end
    endtask

    task sample_lane(input lane, input [1:0] p, input [1:0] owner);
        begin
            seen = pin[p];
            shift_in(lane, seen);
            if (oe_r[p] && ov_r[p] && !seen && is_mine(owner, role) && od_mask[p])
                lose(p, 1'b1, c_clk);
        end
    endtask

    task sample_lanes;
        begin
            sample_lane(1'b0, i_pin, i_owner);
            if (c_l2_en) sample_lane(1'b1, c_l2_pin, c_l2_own);
        end
    endtask

    task store_incoming;
        begin
            if (!is_mine(i_owner, role)) begin
                push_data_r = rx0;
                if (role == WITNESS) seen_push_r = 1'b1;
                else rx_push_r = 1'b1;
            end
            if (c_l2_en && !is_mine(c_l2_own, role)) begin
                if (role == WITNESS) begin
                    push_data2_r = rx1;
                    seen_push2_r = 1'b1;
                end else begin
                    push_data_r = rx1;
                    rx_push_r = 1'b1;
                end
            end
        end
    endtask

    task refill;
        begin
            if (is_mine(i_owner, role) || (c_l2_en && is_mine(c_l2_own, role))) begin
                if (tx_valid) begin
                    tx = tx_data;
                    tx_pop_r = 1'b1;
                end else tx = 8'hFF;
            end
        end
    endtask

    task write_mode(input [4:0] field, input [15:0] v);
        begin
            case (field)
                0:  c_msb = v[0];
                1:  begin c_rs_en = v[3]; c_rs_pin = v[1:0]; end
                2:  begin
                        c_stuff = v[3:0];
                        c_ones = v[4];
                        if (v[4:0] != 0) begin
                            restart_crc;
                            run_len = 0;
                            run_valid = 1'b0;
                        end
                    end
                3:  c_poly = v;
                4:  begin c_width = v[4:0]; c_init1 = v[5]; restart_crc; end
                5:  c_err = v[5:0];
                6:  c_lose = v[1:0];
                7:  c_clk = v[1:0];
                8:  c_clk_own = v[1:0];
                9:  c_cpol = v[0];
                10: c_cpha = v[0];
                11: begin c_l2_en = v[5]; c_l2_pin = v[3:2]; c_l2_own = v[1:0]; end
                12: c_div = v[7:0];
                13: begin c_pair_en = v[3]; c_pair = v[1:0]; end
                14: c_nrzi = v[0];
                15: c_resid = v;
                16: begin c_brk_en = v[6]; c_brk = v[5:0]; end
                17: c_xor = v;
                default: ;
            endcase
        end
    endtask

    // Power-on reset goes to the flops' reset pins. A synchronous reset is
    // folded into each register's next-state logic, and gate-level simulation
    // cannot always resolve that from X: a counter bit could stay X after
    // reset. The synchronous rst branch then loads the real starting values.
    always @(posedge clk or posedge por) begin
      if (por) begin
        oe_r = 0; ov_r = 0; pc_r = 0;
        push_data_r = 0; push_data2_r = 0; violations_r = 0;
        tx_pop_r = 0; tx_clear_r = 0; rx_push_r = 0;
        seen_push_r = 0; seen_push2_r = 0; arb_lost_r = 0;
        s = S_BOOT; s1 = 0; pin = 0; prev = 0; armed = 0; role = 0;
        tx = 0; rx0 = 0; rx1 = 0; count = 0;
        last = 0; seen = 0; val = 0; cur_mine = 0;
        inserted = 0; stuff_bit = 0; run_valid = 0; run_val = 0;
        k = 0; run_len = 0; partial = 0; src_eff = 0;
        now = 0; edge_t = 0; last_fall = 0; lf_valid = 0;
        crc = 0; held0 = 0; held1 = 0; cnt = 0; div_cnt = 0;
        c_msb = 0; c_rs_en = 0; c_rs_pin = 0; c_stuff = 0; c_poly = 0;
        c_width = 0; c_err = 0; c_lose = WITNESS; c_clk = 0; c_clk_own = 0;
        c_cpol = 0; c_cpha = 0; c_l2_en = 0; c_l2_pin = 0; c_l2_own = 0; c_div = 0;
        c_ones = 0; c_init1 = 0; c_pair_en = 0; c_pair = 0; c_nrzi = 0;
        c_resid = 0; c_brk_en = 0; c_brk = 0; c_xor = 0;
        f_cnt = 0; f_armed = 0; faulty = 0;
        oe <= 0; ov <= 0; pc <= 0; pc_sel <= 64'd1;
        tx_pop <= 0; tx_clear <= 0; rx_push <= 0; seen_push <= 0; seen_push2 <= 0;
        push_data <= 0; push_data2 <= 0; violations <= 0; arb_lost <= 0;
      end else begin
        tx_pop_r = 1'b0;
        tx_clear_r = 1'b0;
        rx_push_r = 1'b0;
        seen_push_r = 1'b0;
        seen_push2_r = 1'b0;

        if (rst) begin
            s = S_BOOT;
            pc_r = reset_pc;
            oe_r = 0;
            ov_r = 0;
            s1 = wire_in[3:0];
            pin = wire_in[3:0];
            armed = wire_in[3:0];
            role = base_role;
            tx = 0; rx0 = 0; rx1 = 0; count = 0; last = 0; k = 0;
            partial = 0; violations_r = 0; arb_lost_r = 0;
            now = 0; edge_t = 0; lf_valid = 0; last_fall = 0;
            crc = 0; run_len = 0; run_valid = 0; run_val = 0;
            held0 = 0; held1 = 0; inserted = 0; div_cnt = 0;
            c_msb = 0; c_rs_en = 0; c_stuff = 0; c_poly = 0; c_width = 0; c_err = 0;
            c_lose = WITNESS; c_clk = 0; c_clk_own = 0; c_cpol = 0; c_cpha = 0;
            c_l2_en = 0; c_l2_pin = 0; c_l2_own = 0; c_div = 0;
            c_ones = 0; c_init1 = 0; c_pair_en = 0; c_pair = 0; c_nrzi = 0;
            c_resid = 0; c_brk_en = 0; c_brk = 0; c_xor = 0;
            f_cnt = 0; f_armed = cfg6[15]; faulty = 0;
        end else if (div_cnt != c_div) begin
            // Between prescaled ticks the hart holds still, so with prescaler
            // D it behaves as the model does with each tick D+1 clocks long.
            div_cnt = div_cnt + 1'b1;
        end else begin
            div_cnt = 0;
            prev = pin;
            pin = s1;
            s1 = wire_in[3:0];
            now = now + 1'b1;
            if (c_rs_en && prev[c_rs_pin] && !pin[c_rs_pin]) begin
                last_fall = now;
                lf_valid = 1'b1;
            end

            // Traps. Decide first and change no state, then either fire or run
            // the program. The program branch then reads the state from before
            // the traps, so synthesis can build the two side by side instead of
            // one after the other. The last trap to fire sets the target, as
            // when each fired in turn.
            fired = 1'b0;
            fire_to = 0;
            for (j = 0; j < 2; j = j + 1) begin
                tw = (j == 0) ? cfg0 : cfg1;
                if (!fired && tw[15] && prev[tw[7:6]] != tw[5] && pin[tw[7:6]] == tw[5]
                        && (!tw[4] || pin[tw[2:1]] == tw[0])) begin
                    fired = 1'b1;
                    fire_to = tw[14:9];
                end
            end
            tw = cfg2;
            if (tw[15]) begin
                if (pin[tw[7:6]] == tw[5]) begin
                    if (held0 != 16'hFFFF) held0 = held0 + 1'b1;
                end else held0 = 0;
                if (held0 == cfg4) begin
                    fired = 1'b1;
                    fire_to = tw[14:9];
                end
            end
            tw = cfg3;
            if (tw[15]) begin
                if (pin[tw[7:6]] == tw[5]) begin
                    if (held1 != 16'hFFFF) held1 = held1 + 1'b1;
                end else held1 = 0;
                if (held1 == cfg5) begin
                    fired = 1'b1;
                    fire_to = tw[14:9];
                end
            end

            if (fired) fire(fire_to);
            else begin
                // `now` wraps, so times are compared within half its range.
                // Keep the stored times close, or a long idle makes an old
                // edge look like a future one.
                if (s != S_MID && is_before(edge_t, now)) edge_t = now;
                diff = now - last_fall;
                if (diff[10]) lf_valid = 1'b0;

                if (s == S_BOOT || s == S_FETCH) begin
                    s = S_EXEC;
                end else begin
                    if (s == S_EXEC) begin
                        case (op)
                            OP_SET: begin
                                if (is_mine(i_owner, role)) begin
                                    if (i_src == 2'd2) release_pin(i_pin);
                                    else drive(i_pin, i_src[0]);
                                end
                                pc_r = pc_r + 1'b1;
                            end
                            OP_BITS: begin
                                k = 0;
                                inserted = 1'b0;
                                if (i_clkd) s = S_CK_ENTER;
                                else start_bit;
                            end
                            OP_CLAIM: s = S_CLAIM;
                            OP_LOAD: begin
                                if (is_mine(i_party, role)) begin
                                    if (ins[25]) tx = ins[7:0];
                                    else if (tx_valid) begin
                                        tx = tx_data;
                                        tx_pop_r = 1'b1;
                                    end else tx = 8'hFF;
                                end
                                pc_r = pc_r + 1'b1;
                            end
                            OP_STORE: begin
                                push_data_r = ins[25] ? rx1 : rx0;
                                if (is_mine(i_party, role)) rx_push_r = 1'b1;
                                else if (role == WITNESS) seen_push_r = 1'b1;
                                pc_r = pc_r + 1'b1;
                            end
                            OP_BRANCH: begin
                                case (ins[27:25])
                                    0: taken = 1'b1;
                                    1: taken = !last;
                                    2: taken = last;
                                    3: taken = count == 0;
                                    4: begin
                                        if (count != 0) count = count - 1'b1;
                                        taken = count != 0;
                                    end
                                    default: begin
                                        taken = crc != c_resid;
                                        if (taken) violate;
                                    end
                                endcase
                                pc_r = taken ? ins[5:0] : pc_r + 1'b1;
                            end
                            OP_CHOICE: begin
                                taken = 1'b0;
                                if (is_mine(i_party, role)) begin
                                    if (!tx_valid) taken = ins[25];
                                    else if (tx_ctl == 2'd1 && ins[24]) taken = 1'b1;
                                    else if (tx_ctl == 2'd2 && ins[23]) taken = 1'b1;
                                    if (taken && tx_valid) tx_pop_r = 1'b1;
                                end
                                pc_r = taken ? ins[5:0] : pc_r + 1'b1;
                            end
                            OP_MATCH: begin
                                if (is_mine(i_party, role) && (rx0 >> ins[25:23]) != addr_reg)
                                    role = WITNESS;
                                pc_r = pc_r + 1'b1;
                            end
                            OP_COUNTER: begin
                                masked = rx0 & ins[15:8];
                                if (ins[27]) count = masked < ins[23:16] ? masked : ins[23:16];
                                else count = ins[7:0];
                                pc_r = pc_r + 1'b1;
                            end
                            OP_MODE: begin
                                write_mode(ins[27:23], ins[15:0]);
                                pc_r = pc_r + 1'b1;
                            end
                            default: pc_r = pc_r + 1'b1;
                        endcase
                    end

                    // A tick runs either the clocked-bit states or the others, never
                    // both, so they are built side by side rather than in series.
                    if (s >= S_CK_ENTER && s <= S_CK_BS) begin
                      if (s == S_CK_ENTER) begin
                          if (!(is_mine(c_clk_own, role) && is_before(now, edge_t)))
                              s = S_CK_TOP;
                      end

                      if (s == S_CK_GAP) begin
                          if (k != i_n) begin
                              k = k + 1'b1;
                              s = S_CK_TOP;
                          end else begin
                              partial = 0;
                              if (!i_strm) finish;
                              else begin
                                  store_incoming;
                                  if (is_mine(c_clk_own, role) && !tx_valid) finish;
                                  else begin
                                      refill;
                                      k = 0;
                                      s = S_CK_TOP;
                                  end
                              end
                          end
                      end

                      if (s == S_CK_TOP) begin
                          partial = k != 0;
                          if (!c_cpha) lanes_out;
                          cnt = i_dwell - 1'b1;
                          s = S_CK_AW;
                      end

                      if (s == S_CK_AW) begin
                          level = !c_cpol;
                          if (is_mine(c_clk_own, role)) begin
                              if (cnt != 0) cnt = cnt - 1'b1;
                              else begin
                                  drive(c_clk, level);
                                  s = S_CK_AS;
                              end
                          end else begin
                              release_pin(c_clk);
                              s = S_CK_AS;
                          end
                      end

                      if (s == S_CK_AS) begin
                          level = !c_cpol;
                          if (pin[c_clk] == level
                                  || (is_mine(c_clk_own, role) && !od_mask[c_clk])) begin
                              if (!c_cpha) sample_lanes;
                              else lanes_out;
                              cnt = i_dwell - 1'b1;
                              s = S_CK_BW;
                          end
                      end

                      if (s == S_CK_BW) begin
                          level = c_cpol;
                          if (is_mine(c_clk_own, role)) begin
                              if (cnt != 0) cnt = cnt - 1'b1;
                              else begin
                                  drive(c_clk, level);
                                  s = S_CK_BS;
                              end
                          end else begin
                              release_pin(c_clk);
                              s = S_CK_BS;
                          end
                      end

                      if (s == S_CK_BS) begin
                          level = c_cpol;
                          if (pin[c_clk] == level
                                  || (is_mine(c_clk_own, role) && !od_mask[c_clk])) begin
                              if (c_cpha) sample_lanes;
                              armed = pin;
                              s = S_CK_GAP;
                          end
                      end
                    end else begin
                      if (s == S_CLAIM) begin
                          if ((base_role == i_owner && tx_valid) || !pin[i_pin]) begin
                              if (base_role == i_owner && ins[22])
                                  role = (tx_valid && pin[i_pin]) ? i_owner : ins[21:20];
                              pc_r = pc_r + 1'b1;
                              s = S_EXEC;
                          end
                      end

                      if (s == S_SYNC) begin
                          if (!is_before(now, edge_t)) put_release(i_pin);
                          if (pin[i_pin] == val && armed[i_pin] != val) begin
                              // A real change: set this bit's edge to the owner's.
                              edge_t = now - 12'd2;
                              s = S_MID;
                          end else if (pin[i_pin] != val) armed[i_pin] = pin[i_pin];
                      end

                      if (s == S_EDGE) begin
                          if (is_before(now, edge_t)) resync(!cur_mine);
                          else begin
                              if (is_before(edge_t, now)) edge_t = now;
                              if (cur_mine) begin
                                  // NRZI: a 1 keeps the line level, a 0 changes it.
                                  lvl = (c_nrzi && !i_brk) ? pin[i_pin] ^ !val : val;
                                  // An adversary drives one chosen bit wrong, once.
                                  faulty = f_armed && f_cnt == cfg6[11:0];
                                  if (faulty) begin
                                      lvl = !lvl;
                                      f_armed = 1'b0;
                                  end
                                  if (f_armed) f_cnt = f_cnt + 1'b1;
                                  put(i_pin, lvl, i_brk);
                              end
                              s = S_MID;
                          end
                      end

                      if (s == S_MID) begin
                          if (is_before(now, edge_t + (i_dwell >> 1))) begin
                              resync(!cur_mine);
                              if (!cur_mine) put_release(i_pin);
                          end else begin
                              if (!cur_mine) put_release(i_pin);
                              raw = pin[i_pin];
                              seen = (c_nrzi && !i_brk) ? raw == armed[i_pin] : raw;
                              broke = !raw && (!c_pair_en || !pin[c_pair]);
                              armed = pin;
                              edge_t = edge_t + i_dwell;
                              if (c_pair_en && broke && !cur_mine && !i_brk && c_brk_en) begin
                                  // A listener met a break in an ordinary bit.
                                  if (partial) violate;
                                  partial = 0;
                                  inserted = 1'b0;
                                  pc_r = c_brk;
                                  s = S_FETCH;
                              end else begin
                                  src_const = src_eff[1];
                                  if (!src_const) shift_in(1'b0, seen);
                                  is_data = inserted || !src_const;
                                  s = S_POST;
                                  if (!cur_mine) begin
                                      if (i_brk) begin
                                          if (!i_strm && !broke)
                                              violate;
                                      end else if (src_const && seen != src_eff[0] && (inserted || !i_strm))
                                          violate;
                                  end else if (is_data) begin
                                      if (c_lose != LOSE_NONE && val && !seen && !faulty)
                                          lose(i_pin, 1'b0, 2'd0);
                                  end else s = S_SETTLE;
                              end
                          end
                      end

                      if (s == S_SETTLE) begin
                          // Under NRZI the level driven is not the bit value.
                          if (!(od_mask[i_pin] && pin[i_pin] != ((c_nrzi || faulty) ? ov_r[i_pin] : val)))
                              s = S_POST;
                      end

                      if (s == S_POST) begin
                          // The coder follows the bit an owner meant to send, not
                          // its readback, so a corrupted bit cannot enter its CRC.
                          coded = (cur_mine && is_mine(i_owner, role)) ? val : seen;
                          if (inserted) begin
                              if (coded != stuff_bit) begin
                                  violate;
                                  partial = 0;
                                  inserted = 1'b0;
                                  pc_r = c_err;
                                  s = S_FETCH;
                              end else begin
                                  run_val = coded;
                                  run_valid = 1'b1;
                                  run_len = 1;
                                  bit_done;
                              end
                          end else if ({c_ones, c_stuff} == 0 || i_brk) begin
                              bit_done;
                          end else begin
                              fb = coded ^ crc[c_width - 1'b1];
                              crc = {crc[14:0], 1'b0} & ~(16'hFFFF << c_width);
                              if (fb) crc = crc ^ c_poly;
                              run_len = (run_valid && coded == run_val) ? run_len + 1'b1 : 4'd1;
                              run_val = coded;
                              run_valid = 1'b1;
                              if (run_len == c_stuff && (coded || !c_ones)) begin
                                  inserted = 1'b1;
                                  stuff_bit = !coded;
                                  start_bit;
                              end else bit_done;
                          end
                      end
                    end
                end
            end
        end
        oe <= {4'd0, oe_r};
        ov <= {4'd0, ov_r};
        pc <= pc_r;
        pc_sel <= 64'd1 << pc_r;
        tx_pop <= tx_pop_r;
        tx_clear <= tx_clear_r;
        rx_push <= rx_push_r;
        seen_push <= seen_push_r;
        seen_push2 <= seen_push2_r;
        push_data <= push_data_r;
        push_data2 <= push_data2_r;
        violations <= violations_r;
        arb_lost <= arb_lost_r;
      end
    end

    // Trap configuration. A write lands after this tick's traps have read the
    // old value, so the host port is not in front of the trap logic. A host
    // frame takes many ticks anyway, so the extra tick cannot be seen.
    always @(posedge clk or posedge por) begin
        if (por) begin
            cfg0 <= 0; cfg1 <= 0; cfg2 <= 0; cfg3 <= 0; cfg4 <= 0; cfg5 <= 0; cfg6 <= 0;
        end else if (cfg_we) begin
            case (cfg_addr)
                3'd0: cfg0 <= cfg_data;
                3'd1: cfg1 <= cfg_data;
                3'd2: cfg2 <= cfg_data;
                3'd3: cfg3 <= cfg_data;
                3'd4: cfg4 <= cfg_data;
                3'd5: cfg5 <= cfg_data;
                3'd6: cfg6 <= cfg_data;
                default: ;
            endcase
        end
    end
endmodule
