// =============================================================================
// Gust N1 - core-local interruptor (the standard "CLINT" register layout)
//   0x0000 + 4*h   msip[h]       bit 0 -> machine software interrupt of hart h
//                                 (this is how one core interrupts another)
//   0x4000 + 8*h   mtimecmp[h]   64 bit, resets to all ones
//   0xBFF8         mtime         64 bit, shared, counts clock cycles / (DIV+1)
// =============================================================================
module n1_clint #(
    parameter NH  = 2,
    parameter DIV = 0
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          sel,
    input  wire          we,
    input  wire [15:0]   addr,
    input  wire [31:0]   wdata,
    output reg  [31:0]   rdata,
    output wire [NH-1:0] msip,
    output reg  [NH-1:0] mtip
);
    reg [NH-1:0] msip_q;
    reg [63:0]   mtime;
    reg [63:0]   cmp [0:NH-1];
    reg [15:0]   div_q;
    wire wr = sel & we;
    wire [13:0] h4 = addr[15:2];                 // word index
    integer h;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msip_q <= {NH{1'b0}}; mtime <= 64'b0; div_q <= 16'b0; mtip <= {NH{1'b0}};
            for (h = 0; h < NH; h = h + 1) cmp[h] <= {64{1'b1}};
        end else begin
            if (div_q == 16'd0) begin
                mtime <= mtime + 64'd1;
                div_q <= DIV[15:0];
            end else begin
                div_q <= div_q - 16'd1;
            end
            for (h = 0; h < NH; h = h + 1) begin
                mtip[h] <= (mtime >= cmp[h]);
                if (wr && addr == (16'h0000 + 4*h)) msip_q[h]     <= wdata[0];
                if (wr && addr == (16'h4000 + 8*h)) cmp[h][31:0]  <= wdata;
                if (wr && addr == (16'h4004 + 8*h)) cmp[h][63:32] <= wdata;
            end
            if (wr && addr == 16'hBFF8) mtime[31:0]  <= wdata;
            if (wr && addr == 16'hBFFC) mtime[63:32] <= wdata;
        end
    end
    always @(posedge clk) begin
        if (sel & ~we) begin
            rdata <= 32'b0;
            for (h = 0; h < NH; h = h + 1) begin
                if (addr == (16'h0000 + 4*h)) rdata <= {31'b0, msip_q[h]};
                if (addr == (16'h4000 + 8*h)) rdata <= cmp[h][31:0];
                if (addr == (16'h4004 + 8*h)) rdata <= cmp[h][63:32];
            end
            if (addr == 16'hBFF8) rdata <= mtime[31:0];
            if (addr == 16'hBFFC) rdata <= mtime[63:32];
        end
    end
    assign msip = msip_q;
    wire unused = &{1'b0, h4};
endmodule
