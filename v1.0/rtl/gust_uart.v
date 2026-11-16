// =============================================================================
// Gust v1.0 - UART (8N1)
//
//   0x00 TXDATA  W    [7:0] byte to send (ignored while TX is busy)
//                R    bit 31 = TX busy
//   0x04 RXDATA  R    [7:0] received byte, bit 31 = empty.  Reading pops it.
//   0x08 CTRL    RW   bit0 TXEN, bit1 RXEN, bit2 TXIE (irq while TX idle),
//                     bit3 RXIE (irq while a byte is waiting)
//   0x0C DIV     RW   [15:0] clock cycles per bit, minus one
//   0x10 STATUS  R    bit0 TX busy, bit1 RX valid, bit2 overrun, bit3 framing
//                W1C  bits 2 and 3
//
// No FIFOs: one shift register per direction plus a one-byte RX holding
// register.  With TXEN/RXEN clear nothing in the block toggles.
// The receiver samples each bit once, in the middle of the bit period.
// =============================================================================
module gust_uart (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sel,
    input  wire        we,
    input  wire [9:0]  addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    input  wire        rx,
    output wire        tx,
    output wire        irq
);
    reg        txen, rxen, txie, rxie;
    reg [15:0] div_q;

    wire wr = sel & we;
    wire rd = sel & ~we;

    // ---------------------------------------------------------- transmitter
    reg [8:0]  tx_sh;        // {data, start}; stop bit is the idle level
    reg [3:0]  tx_cnt;       // bit periods left (start + 8 data + stop), 0 = idle
    reg [15:0] tx_div;
    wire       tx_busy = (tx_cnt != 4'd0);
    wire       tx_tick = (tx_div == 16'd0);
    reg        tx_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_sh <= 9'h1FF; tx_cnt <= 4'd0; tx_div <= 16'd0; tx_q <= 1'b1;
        end else if (!tx_busy) begin
            tx_q <= 1'b1;
            if (wr && addr == 10'h000 && txen) begin
                tx_sh  <= {wdata[7:0], 1'b0};
                tx_cnt <= 4'd11;         // 11th tick ends the stop bit
                tx_div <= 16'd0;
            end
        end else if (tx_tick) begin
            tx_q   <= tx_sh[0];
            tx_sh  <= {1'b1, tx_sh[8:1]};
            tx_cnt <= tx_cnt - 4'd1;
            tx_div <= div_q;
        end else begin
            tx_div <= tx_div - 16'd1;
        end
    end
    assign tx = tx_q;

    // ------------------------------------------------------------- receiver
    reg        rx_s0, rx_s1;
    reg [7:0]  rx_sh, rx_data;
    reg [3:0]  rx_cnt;       // 0 idle, 1 start, 2..9 data, 10 stop
    reg [15:0] rx_div;
    reg        rx_valid, rx_ovr, rx_ferr;
    wire       rx_tick = (rx_div == 16'd0);
    wire       rx_pop  = rd && addr == 10'h001;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s0 <= 1'b1; rx_s1 <= 1'b1;
        end else if (rxen) begin
            rx_s0 <= rx; rx_s1 <= rx_s0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sh <= 8'd0; rx_data <= 8'd0; rx_cnt <= 4'd0; rx_div <= 16'd0;
            rx_valid <= 1'b0; rx_ovr <= 1'b0; rx_ferr <= 1'b0;
        end else begin
            if (rx_pop) rx_valid <= 1'b0;
            if (wr && addr == 10'h004) begin
                if (wdata[2]) rx_ovr  <= 1'b0;
                if (wdata[3]) rx_ferr <= 1'b0;
            end
            if (!rxen) begin
                rx_cnt <= 4'd0;
            end else if (rx_cnt == 4'd0) begin
                if (!rx_s1) begin                       // start edge
                    rx_cnt <= 4'd1;
                    rx_div <= {1'b0, div_q[15:1]};      // half a bit
                end
            end else if (rx_tick) begin
                rx_div <= div_q;
                if (rx_cnt == 4'd1) begin
                    rx_cnt <= rx_s1 ? 4'd0 : 4'd2;      // glitch: abandon
                end else if (rx_cnt == 4'd10) begin
                    rx_cnt <= 4'd0;
                    if (rx_s1) begin
                        rx_data  <= rx_sh;
                        rx_valid <= 1'b1;
                        if (rx_valid & ~rx_pop) rx_ovr <= 1'b1;
                    end else begin
                        rx_ferr <= 1'b1;
                    end
                end else begin
                    rx_sh  <= {rx_s1, rx_sh[7:1]};
                    rx_cnt <= rx_cnt + 4'd1;
                end
            end else begin
                rx_div <= rx_div - 16'd1;
            end
        end
    end

    // ------------------------------------------------------------ registers
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            txen <= 1'b0; rxen <= 1'b0; txie <= 1'b0; rxie <= 1'b0;
            div_q <= 16'd0;
        end else if (wr) begin
            case (addr)
            10'h002: {rxie, txie, rxen, txen} <= wdata[3:0];
            10'h003: div_q <= wdata[15:0];
            default: ;
            endcase
        end
    end

    always @(posedge clk) begin
        if (rd) begin
            case (addr)
            10'h000: rdata <= {tx_busy, 31'b0};
            10'h001: rdata <= {~rx_valid, 23'b0, rx_data};
            10'h002: rdata <= {28'b0, rxie, txie, rxen, txen};
            10'h003: rdata <= {16'b0, div_q};
            10'h004: rdata <= {28'b0, rx_ferr, rx_ovr, rx_valid, tx_busy};
            default: rdata <= 32'b0;
            endcase
        end
    end

    assign irq = (txie & txen & ~tx_busy) | (rxie & rx_valid);
endmodule
