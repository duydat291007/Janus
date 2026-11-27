// A PC drives the Janus host port through the Basys 3's USB-UART.
//
// The PC sends a length L, then L bytes. The bridge pulls chip select low,
// sends the L bytes on the host port (SPI mode 0, MSB first), sends each byte
// read back on MISO to the PC as it goes, then lets chip select go: one host
// frame. L = 0 is a link check: the bridge answers ID and does nothing else.
// If the PC stops in the middle of a frame for TIMEOUT clocks, the bridge
// ends the frame and waits for a new length.
//
// UART: 8 data bits, no parity, one stop bit, CLK_HZ / BAUD clocks a bit.
// SPI: SCK high and low for HALF clocks each. The chip asks for at most 1/8 of
// its clock, so HALF must be at least 4.
module uart_spi_bridge #(
    parameter CLK_HZ  = 25_000_000,
    parameter BAUD    = 1_000_000,
    parameter HALF    = 8,
    parameter TIMEOUT = 250_000,         // 10 ms at 25 MHz
    parameter [7:0] ID = 8'hA5
) (
    input            clk,
    input            rst,
    input            rx,                 // from the PC
    output           tx,                 // to the PC
    output reg       sck,
    output reg       mosi,
    output reg       cs_n,
    input            miso,
    output           busy                // a frame is under way
);
    localparam integer DIV = CLK_HZ / BAUD;

    // ---- UART receiver ----
    reg  [1:0]  rx_s;                    // the line, synchronised
    reg         rx_on;
    reg  [15:0] rx_cnt;
    reg  [3:0]  rx_bit;
    reg  [7:0]  rx_sh;
    reg         rx_got;
    reg  [7:0]  rx_byte;
    always @(posedge clk) begin
        rx_s <= {rx_s[0], rx};
        rx_got <= 1'b0;
        if (rst) begin
            rx_s <= 2'b11;
            rx_on <= 1'b0;
        end else if (!rx_on) begin
            if (!rx_s[1]) begin          // a start bit: wait to its middle
                rx_on <= 1'b1;
                rx_cnt <= DIV / 2;
                rx_bit <= 0;
            end
        end else if (rx_cnt != 0) rx_cnt <= rx_cnt - 1'b1;
        else begin
            rx_cnt <= DIV - 1;
            if (rx_bit == 0) begin
                if (rx_s[1]) rx_on <= 1'b0;   // not a start bit after all
                else rx_bit <= 1;
            end else if (rx_bit <= 8) begin
                rx_sh <= {rx_s[1], rx_sh[7:1]};
                rx_bit <= rx_bit + 1'b1;
            end else begin               // the stop bit
                rx_on <= 1'b0;
                if (rx_s[1]) begin
                    rx_got <= 1'b1;
                    rx_byte <= rx_sh;
                end
            end
        end
    end

    // ---- UART transmitter ----
    reg  [9:0]  tx_sh;
    reg  [15:0] tx_cnt;
    reg  [3:0]  tx_left;
    reg         tx_go;
    reg  [7:0]  tx_byte;
    wire        tx_idle = tx_left == 0;
    assign tx = tx_sh[0];
    always @(posedge clk) begin
        if (rst) begin
            tx_sh <= 10'h3FF;
            tx_left <= 0;
        end else if (tx_go && tx_idle) begin
            tx_sh <= {1'b1, tx_byte, 1'b0};
            tx_left <= 4'd10;
            tx_cnt <= DIV - 1;
        end else if (!tx_idle) begin
            if (tx_cnt != 0) tx_cnt <= tx_cnt - 1'b1;
            else begin
                tx_cnt <= DIV - 1;
                tx_sh <= {1'b1, tx_sh[9:1]};
                tx_left <= tx_left - 1'b1;
            end
        end
    end

    // ---- Frames ----
    localparam S_LEN = 3'd0, S_WAIT = 3'd1, S_LOW = 3'd2, S_HIGH = 3'd3, S_REPLY = 3'd4, S_END = 3'd5;
    reg  [2:0]  st;
    reg  [7:0]  left;                    // bytes of this frame still to come
    reg  [7:0]  out, in;
    reg  [2:0]  k;                       // bit of the byte in hand
    reg  [15:0] t;                       // clocks into this step
    reg  [31:0] quiet;                   // clocks since the last byte from the PC
    assign busy = st != S_LEN;
    always @(posedge clk) begin
        tx_go <= 1'b0;
        if (rst) begin
            st <= S_LEN;
            cs_n <= 1'b1;
            sck <= 1'b0;
            mosi <= 1'b0;
            quiet <= 0;
        end else begin
            quiet <= rx_got ? 32'd0 : quiet + 1'b1;
            case (st)
                S_LEN: if (rx_got) begin
                    if (rx_byte == 0) begin
                        tx_byte <= ID;
                        tx_go <= 1'b1;
                    end else begin
                        left <= rx_byte;
                        st <= S_WAIT;
                    end
                end
                S_WAIT: begin            // the next byte of the frame
                    if (rx_got) begin
                        out <= rx_byte;
                        k <= 3'd7;
                        t <= 0;
                        mosi <= rx_byte[7];
                        cs_n <= 1'b0;    // a half period before the first edge
                        st <= S_LOW;
                    end else if (quiet >= TIMEOUT) begin
                        st <= S_END;
                        t <= 0;
                    end
                end
                S_LOW: begin             // SCK low, the bit on MOSI
                    if (t == HALF - 1) begin
                        sck <= 1'b1;
                        in <= {in[6:0], miso};
                        t <= 0;
                        st <= S_HIGH;
                    end else t <= t + 1'b1;
                end
                S_HIGH: begin
                    if (t == HALF - 1) begin
                        sck <= 1'b0;
                        t <= 0;
                        if (k == 0) st <= S_REPLY;
                        else begin
                            k <= k - 1'b1;
                            mosi <= out[k - 1'b1];
                            st <= S_LOW;
                        end
                    end else t <= t + 1'b1;
                end
                S_REPLY: if (tx_idle && !tx_go) begin
                    tx_byte <= in;
                    tx_go <= 1'b1;
                    left <= left - 1'b1;
                    t <= 0;
                    st <= left == 8'd1 ? S_END : S_WAIT;
                end
                S_END: begin             // SCK low a half period, then chip select high for two
                    if (t == HALF - 1) cs_n <= 1'b1;
                    if (t == 3 * HALF - 1) st <= S_LEN;
                    t <= t + 1'b1;
                end
                default: st <= S_LEN;
            endcase
        end
    end
endmodule
