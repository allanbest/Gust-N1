// =============================================================================
// Test bench for the Gust N1 multi-core system: n1_soc + an external RAM model.
//
//   RAM at 0x8000_0000, MEM_WORDS words, behind the SoC's external memory port.
//   LAT       fixed extra latency of every RAM access, in cycles (0 = like
//             on-chip RAM; 2-3 = like a simple external RAM controller)
//   stall_mode additionally withholds grants and delays responses at random
//   Test device at 0xF000_0000:
//       +0x00 W  console character      +0x04 RW external interrupt lines 7..2
//       +0x14 R  cycle counter
//   A write to `tohost_addr` ends the test (riscv-tests convention).
// =============================================================================
`timescale 1ns/1ps
module tb_n1_soc #(
    parameter NCORES    = 2,
    parameter ASYM      = 1,
    parameter MEM_WORDS = 131072,
    parameter LAT       = 0,
    parameter ICACHE    = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        stall_mode,
    input  wire [31:0] tohost_addr,
    output reg         tohost_valid,
    output reg  [31:0] tohost_data,
    output reg         putc_strobe,
    output reg  [7:0]  putc_data,
    output reg         proto_err,
    output wire [NCORES-1:0] sleeping
);
    localparam [31:0] MEM_BASE = 32'h8000_0000, IO_BASE = 32'hF000_0000;
    reg [31:0] mem [0:MEM_WORDS-1];

    wire        mem_req, mem_we, mem_gnt, uart_tx;
    wire [3:0]  mem_be;
    wire [31:0] mem_addr, mem_wdata;
    reg         mem_rvalid, mem_err;
    reg  [31:0] mem_rdata;
    reg  [7:2]  irq_lines;
    reg  [31:0] cycle;

    n1_soc #(.NCORES(NCORES), .ASYM(ASYM), .ICACHE(ICACHE)) dut (
        .clk(clk), .rst_n(rst_n),
        .mem_req(mem_req), .mem_we(mem_we), .mem_be(mem_be), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_gnt(mem_gnt), .mem_rvalid(mem_rvalid),
        .mem_rdata(mem_rdata), .mem_err(mem_err),
        .uart_rx(1'b1), .uart_tx(uart_tx), .ext_irq(irq_lines), .sleeping(sleeping)
    );

    reg [31:0] lfsr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 32'hACE1_2468;
        else        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    end

    wire        in_ram = (mem_addr >= MEM_BASE) && (mem_addr < MEM_BASE + 4 * MEM_WORDS);
    wire        in_io  = (mem_addr[31:8] == IO_BASE[31:8]);
    wire [31:0] idx    = (mem_addr - MEM_BASE) >> 2;
    wire [31:0] rd_now = in_ram ? mem[idx] :
                         (mem_addr[7:0] == 8'h04) ? {24'b0, irq_lines, 2'b0} :
                         (mem_addr[7:0] == 8'h14) ? cycle : 32'b0;
    reg         busy;
    reg  [3:0]  wait_q;
    reg  [31:0] d_q;
    reg         e_q;
    wire [3:0]  delay = LAT[3:0] + ((stall_mode & lfsr[17]) ? {2'b0, lfsr[19:18]} : 4'd0);
    assign mem_gnt = ~busy & (~stall_mode | lfsr[5] | lfsr[9]);
    wire   accept  = mem_req & mem_gnt;
    integer b;

    reg        hold_q;
    reg [31:0] hold_addr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0; wait_q <= 4'd0; mem_rvalid <= 1'b0; mem_err <= 1'b0;
            mem_rdata <= 32'b0; tohost_valid <= 1'b0; tohost_data <= 32'b0;
            putc_strobe <= 1'b0; putc_data <= 8'b0; irq_lines <= 6'b0; cycle <= 32'b0;
            proto_err <= 1'b0; hold_q <= 1'b0;
        end else begin
            cycle      <= cycle + 32'd1;
            mem_rvalid <= 1'b0;
            if (hold_q && !(mem_req && mem_addr == hold_addr)) begin
                $display("PROTOCOL ERROR: memory request changed before grant at %0t", $time);
                proto_err <= 1'b1;
            end
            hold_q    <= mem_req & ~mem_gnt;
            hold_addr <= mem_addr;
            if (busy) begin
                if (wait_q == 4'd0) begin
                    mem_rvalid <= 1'b1; mem_rdata <= d_q; mem_err <= e_q; busy <= 1'b0;
                end else begin
                    wait_q <= wait_q - 4'd1;
                end
            end
            if (accept) begin
                if (delay == 4'd0) begin
                    mem_rvalid <= 1'b1; mem_rdata <= rd_now; mem_err <= ~(in_ram | in_io);
                end else begin
                    busy <= 1'b1; wait_q <= delay - 4'd1; d_q <= rd_now; e_q <= ~(in_ram | in_io);
                end
                if (mem_we) begin
                    if (in_ram) begin
                        for (b = 0; b < 4; b = b + 1)
                            if (mem_be[b]) mem[idx][8*b +: 8] <= mem_wdata[8*b +: 8];
                    end
                    if ({mem_addr[31:2], 2'b00} == tohost_addr) begin
                        tohost_valid <= 1'b1; tohost_data <= mem_wdata;
                    end
                    if (in_io && mem_addr[7:0] == 8'h00) begin
                        putc_strobe <= ~putc_strobe; putc_data <= mem_wdata[7:0];
                    end
                    if (in_io && mem_addr[7:0] == 8'h04) irq_lines <= mem_wdata[7:2];
                end
            end
        end
    end
    reg [1023:0] hexfile;
    initial if ($value$plusargs("hex=%s", hexfile)) $readmemh(hexfile, mem);
endmodule
