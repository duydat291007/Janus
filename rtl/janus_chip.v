// verilator lint_off LATCH
// Janus chip top: two harts, 48 words of shared program memory, FIFOs and an
// SPI host port.
//
// ui_in[0] SCK, ui_in[1] MOSI, ui_in[2] CSn (active low). SPI mode 0, MSB first.
// uo_out[0] MISO, [1] receive data waiting, [2] any violation, [3] arbitration
// lost, [4] hart 0 running, [5] hart 1 running.
// uio[7:0] are the 8 protocol pins.
//
// Host frames, chosen by the first byte (h is the hart number):
//   10 addr d3 d2 d1 d0   write one program word
//   2h reg hi lo          write a hart register: 0-5 traps, 6 role, 7 address,
//                         8 open-drain mask, 9 pin rotation, 10 start address
//   30 ctrl               bit 0 run hart 0, bit 1 run hart 1, bit 2 loopback
//                         Set loopback in an earlier frame than the run bits, so
//                         harts leave reset already watching the right line.
//   4h ctl data           push a transmit entry (ctl 0 data, 1 STOP, 2 RESTART)
//   5h xx xx ...          read received bytes; each dummy byte returns one
//   6h xx xx              read violation count, then status flags
//
// A host SCK must be at most 1/8 of clk. The status flags byte is
// {0, 0, rx overflow, arbitration lost, tx full, tx empty, rx full, rx empty}.

module janus_fifo #(parameter W = 8, parameter LOG = 3) (
    input              clk,
    input              rst,
    input              clear,
    input              push,
    input  [W-1:0]     din,
    input              pop,
    output [W-1:0]     dout,
    output             empty,
    output             full
);
    reg [W-1:0] mem [0:(1 << LOG) - 1];
    reg [LOG:0] wp, rp;
    // A pop or clear arrives a tick after the hart acted on it, so the outputs
    // look past it. The hart then never sees an entry it has already taken.
    wire        has_data = wp != rp;
    wire [LOG:0] rp_next = rp + ((pop && has_data) ? 1'b1 : 1'b0);
    assign empty = clear || wp == rp_next;
    assign full = (wp ^ rp) == {1'b1, {LOG{1'b0}}};
    assign dout = mem[rp_next[LOG-1:0]];
    always @(posedge clk) begin
        if (rst || clear) begin
            wp <= 0;
            rp <= 0;
        end else begin
            if (push && !full) begin
                mem[wp[LOG-1:0]] <= din;
                wp <= wp + 1'b1;
            end
            rp <= rp_next;
        end
    end
endmodule

// One hart with its FIFOs, registers and pin rotation.
module janus_unit (
    input         clk,
    input         por,
    input         run,
    input  [7:0]  line,          // pin levels, in chip pin order
    output [7:0]  low,           // pins this hart pulls low
    output [7:0]  high,          // pins this hart drives high, push-pull only
    output [47:0] sel,           // pc as one-hot, one bit per program word
    input  [31:0] ins,
    input         reg_we,
    input  [3:0]  reg_addr,
    input  [15:0] reg_data,
    input         tx_push,
    input  [9:0]  tx_din,
    input         rx_pop,
    output [7:0]  rx_head,
    output        rx_empty,
    output [7:0]  violations,
    output [7:0]  flags
);
    reg [1:0] role;
    reg [7:0] addr, od_mask;
    reg [2:0] rot;
    reg [5:0] start;
    reg       overflow;

    wire [7:0] oe, ov;
    wire [15:0] line2 = {line, line};
    wire [7:0] in = line2[rot +: 8];           // chip pin rot+i is hart pin i
    wire [15:0] oe2 = {oe, oe}, ov2 = {ov, ov}, od2 = {od_mask, od_mask};
    wire [3:0] back = 4'd8 - rot;
    wire [7:0] oe_c = oe2[back +: 8];
    wire [7:0] ov_c = ov2[back +: 8];
    wire [7:0] od_c = od2[back +: 8];
    assign low = oe_c & ~ov_c;
    assign high = oe_c & ov_c & ~od_c;

    wire [1:0] tx_ctl;
    wire [7:0] tx_data, push_data, push_data2;
    wire       tx_empty, tx_full, tx_pop, tx_clear, rx_full, arb_lost;
    wire       rx_push, seen_push, seen_push2;
    wire [63:0] pc_sel;
    assign sel = pc_sel[47:0];   // there are 48 words; a pc past them fetches 0

    reg  [7:0] pending;
    reg        pending_valid;
    wire       direct = rx_push || seen_push;
    wire       rx_in = direct || pending_valid;
    wire [7:0] rx_din = direct ? push_data : pending;

    janus_hart hart (
        .clk(clk), .por(por), .rst(!run), .wire_in(in), .oe(oe), .ov(ov),
        .od_mask(od_mask), .base_role(role), .reset_pc(start), .addr_reg(addr),
        .pc(), .pc_sel(pc_sel), .ins(ins), .tx_valid(!tx_empty), .tx_ctl(tx_ctl), .tx_data(tx_data),
        .tx_pop(tx_pop), .tx_clear(tx_clear), .rx_push(rx_push), .seen_push(seen_push),
        .seen_push2(seen_push2), .push_data(push_data), .push_data2(push_data2),
        .violations(violations), .arb_lost(arb_lost),
        .cfg_we(reg_we && reg_addr < 4'd6), .cfg_addr(reg_addr[2:0]), .cfg_data(reg_data));

    janus_fifo #(.W(10)) tx_fifo (
        .clk(clk), .rst(por), .clear(tx_clear), .push(tx_push), .din(tx_din),
        .pop(tx_pop), .dout({tx_ctl, tx_data}), .empty(tx_empty), .full(tx_full));

    janus_fifo #(.W(8)) rx_fifo (
        .clk(clk), .rst(por), .clear(1'b0), .push(rx_in), .din(rx_din),
        .pop(rx_pop), .dout(rx_head), .empty(rx_empty), .full(rx_full));

    assign flags = {2'b00, overflow, arb_lost, tx_full, tx_empty, rx_full, rx_empty};

    always @(posedge clk) begin
        if (por) begin
            role <= 0;
            addr <= 0;
            od_mask <= 0;
            rot <= 0;
            start <= 0;
            overflow <= 0;
            pending <= 0;
            pending_valid <= 0;
        end else begin
            if (reg_we) begin
                case (reg_addr)
                    4'd6:  role <= reg_data[1:0];
                    4'd7:  addr <= reg_data[7:0];
                    4'd8:  od_mask <= reg_data[7:0];
                    4'd9:  rot <= reg_data[2:0];
                    4'd10: start <= reg_data[5:0];
                    default: ;
                endcase
            end
            if (rx_in && rx_full && !rx_pop) overflow <= 1'b1;
            // A witness can see two lanes in one tick. The second waits a tick.
            if (seen_push2) begin
                pending <= push_data2;
                pending_valid <= 1'b1;
            end else if (!direct) pending_valid <= 1'b0;
        end
    end
endmodule

module tt_um_duydat291007_janus (
    input  [7:0] ui_in,
    output [7:0] uo_out,
    input  [7:0] uio_in,
    output [7:0] uio_out,
    output [7:0] uio_oe,
    input        ena,
    input        clk,
    input        rst_n
);
    wire por = !rst_n;

    // SPI host port
    reg [2:0] sck_s, cs_s;
    reg [1:0] mosi_s;
    wire sck_rise = sck_s[1] && !sck_s[2];
    wire sck_fall = !sck_s[1] && sck_s[2];
    wire selected = !cs_s[1];

    reg [7:0]  shift, miso_sr, cmd;
    reg [2:0]  bits;
    reg [2:0]  index;
    reg        miso, reload;
    reg [7:0]  a0, b0, b1, b2;
    reg        run0, run1, loopback;

    wire [7:0] in_byte = {shift[6:0], mosi_s[1]};
    wire       byte_done = selected && sck_rise && bits == 3'd7;
    wire [3:0] op = (index == 0) ? in_byte[7:4] : cmd[7:4];
    wire       h = (index == 0) ? in_byte[0] : cmd[0];

    wire prog_we = byte_done && index == 3'd5 && cmd[7:4] == 4'h1;
    wire reg_we = byte_done && index == 3'd3 && cmd[7:4] == 4'h2;
    wire tx_we = byte_done && index == 3'd2 && cmd[7:4] == 4'h4;
    wire rx_rd = byte_done && index != 0 && cmd[7:4] == 4'h5;

    wire [7:0] line, low0, low1, high0, high1, head0, head1, viol0, viol1, flags0, flags1;
    wire       empty0, empty1;
    // Reading an empty FIFO returns 0, not whatever is in its memory.
    wire [7:0] rd_head = h ? (empty1 ? 8'd0 : head1) : (empty0 ? 8'd0 : head0);
    wire [47:0] sel0, sel1;

    // Program memory: one latch per bit, at about half the area of a flop with
    // its write mux. Load programs only while the harts that run them are
    // stopped. The frame registers hold the address and data, stable for a full
    // tick before the write pulse, so the pulse cannot glitch onto another word.
    wire [31:0]  wdata = {b0, b1, b2, shift};
    wire [5:0]   waddr = a0[5:0];
    reg          we_d, wpulse;
    wire [1535:0] words;
    // Each fetch is an AND-OR over the words, steered by the hart's one-hot
    // pc. A binary pc would have each of its bits steer hundreds of muxes,
    // which was the slowest path on the chip.
    reg  [31:0]  ins0, ins1;
    integer      f;
    always @* begin
        ins0 = 32'd0;
        ins1 = 32'd0;
        for (f = 0; f < 48; f = f + 1) begin
            ins0 = ins0 | (words[32 * f +: 32] & {32{sel0[f]}});
            ins1 = ins1 | (words[32 * f +: 32] & {32{sel1[f]}});
        end
    end

    always @(posedge clk) begin
        we_d <= prog_we && !por;
        wpulse <= we_d && !por;
    end

    genvar w;
    generate
        for (w = 0; w < 48; w = w + 1) begin : word
            reg [31:0] bits;
            wire en = wpulse && waddr == w;
            always @* if (en) bits = wdata;
            assign words[32 * w +: 32] = bits;
        end
    endgenerate

    wire [7:0] low = low0 | low1;
    wire [7:0] high = high0 | high1;
    assign uio_oe = low | high;
    assign uio_out = ~low;
    assign line = loopback ? ~low : uio_in;

    janus_unit u0 (.clk(clk), .por(por), .run(run0), .line(line), .low(low0), .high(high0),
        .sel(sel0), .ins(ins0), .reg_we(reg_we && !cmd[0]), .reg_addr(a0[3:0]),
        .reg_data({b0, in_byte}), .tx_push(tx_we && !cmd[0]), .tx_din({a0[1:0], in_byte}),
        .rx_pop(rx_rd && !cmd[0]), .rx_head(head0), .rx_empty(empty0),
        .violations(viol0), .flags(flags0));

    janus_unit u1 (.clk(clk), .por(por), .run(run1), .line(line), .low(low1), .high(high1),
        .sel(sel1), .ins(ins1), .reg_we(reg_we && cmd[0]), .reg_addr(a0[3:0]),
        .reg_data({b0, in_byte}), .tx_push(tx_we && cmd[0]), .tx_din({a0[1:0], in_byte}),
        .rx_pop(rx_rd && cmd[0]), .rx_head(head1), .rx_empty(empty1),
        .violations(viol1), .flags(flags1));

    always @(posedge clk) begin
        sck_s <= {sck_s[1:0], ui_in[0]};
        mosi_s <= {mosi_s[0], ui_in[1]};
        cs_s <= {cs_s[1:0], ui_in[2]};
        if (por) begin
            sck_s <= 0;
            cs_s <= 3'b111;
            bits <= 0;
            index <= 0;
            miso <= 0;
            miso_sr <= 0;
            reload <= 0;
            run0 <= 0;
            run1 <= 0;
            loopback <= 0;
        end else if (!selected) begin
            bits <= 0;
            index <= 0;
            reload <= 0;
        end else begin
            reload <= 0;
            if (reload) miso_sr <= rd_head;
            if (sck_rise) begin
                shift <= in_byte;
                bits <= bits + 1'b1;
            end
            if (sck_fall) begin
                miso <= miso_sr[7];
                miso_sr <= {miso_sr[6:0], 1'b0};
            end
            if (byte_done) begin
                if (index != 3'd7) index <= index + 1'b1;
                if (index == 0) cmd <= in_byte;
                if (index == 1) a0 <= in_byte;
                if (index == 2) b0 <= in_byte;
                if (index == 3) b1 <= in_byte;
                if (index == 4) b2 <= in_byte;
                if (cmd[7:4] == 4'h3 && index == 1) begin
                    run0 <= in_byte[0];
                    run1 <= in_byte[1];
                    loopback <= in_byte[2];
                end
                // What the next byte reads back.
                miso_sr <= 8'd0;
                if (op == 4'h5) begin
                    if (index == 0) miso_sr <= rd_head;
                    else reload <= 1'b1;   // the FIFO moves on this tick
                end
                if (op == 4'h6) begin
                    if (index == 0) miso_sr <= h ? viol1 : viol0;
                    if (index == 1) miso_sr <= h ? flags1 : flags0;
                end
            end
        end
    end

    assign uo_out = {2'b00, run1, run0, flags0[4] | flags1[4],
                     viol0 != 0 || viol1 != 0, !empty0 || !empty1, miso};

    wire unused = &{ena, ui_in[7:3], 1'b0};
endmodule
