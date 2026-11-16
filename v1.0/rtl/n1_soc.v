// =============================================================================
// Gust N1 - multi-core system
//
//   NCORES x ( n1_core + instruction cache )  ->  shared memory bus  ->
//       CLINT (timers, inter-core interrupts)   0x0200_0000
//       PLIC  (external interrupts)             0x0C00_0000
//       UART  (the Gust UART, unchanged)        0x1000_0000   PLIC source 1
//       everything else: the external memory port (RAM at 0x8000_0000)
//
// ASYM = 1 builds an asymmetric pair in the spirit of big/little designs from
// one parameterised core: hart 0 is the "performance" core (single-cycle
// multiplier, branch prediction), the other harts are "efficiency" cores
// (sequential multiplier, about 16 % smaller).  All harts run the same ISA.
//
// The external memory port may answer after any number of cycles, so a real
// SDRAM / PSRAM controller can sit behind it.  The cores start at RESET_VECTOR.
// Debug (JTAG) is not connected in this multi-core system yet.
// =============================================================================
module n1_soc #(
    parameter        NCORES       = 2,
    parameter        ASYM         = 1,
    parameter        ICACHE       = 1,      // 0: no instruction cache (for comparison)
    parameter        ICACHE_LINES = 64,
    parameter        ICACHE_LW    = 6,
    parameter        TLB_ENTRIES  = 8,
    parameter [31:0] RESET_VECTOR = 32'h8000_0000
) (
    input  wire              clk,
    input  wire              rst_n,
    output wire              mem_req,
    output wire              mem_we,
    output wire [3:0]        mem_be,
    output wire [31:0]       mem_addr,
    output wire [31:0]       mem_wdata,
    input  wire              mem_gnt,
    input  wire              mem_rvalid,
    input  wire [31:0]       mem_rdata,
    input  wire              mem_err,
    input  wire              uart_rx,
    output wire              uart_tx,
    input  wire [7:2]        ext_irq,
    output wire [NCORES-1:0] sleeping
);
    localparam NM = 2 * NCORES;
    wire [NM-1:0]    m_req, m_we, m_lock, m_gnt, m_rvalid;
    wire [4*NM-1:0]  m_be;
    wire [32*NM-1:0] m_addr, m_wdata;
    wire [31:0]      m_rdata;
    wire             m_err, snoop_valid;
    wire [31:0]      snoop_addr;
    wire [NCORES-1:0]   msip, mtip;
    wire [2*NCORES-1:0] eip;

    genvar h;
    generate
        for (h = 0; h < NCORES; h = h + 1) begin : g_hart
            localparam FAST = (ASYM == 0) || (h == 0);
            wire        i_req, i_gnt, i_rvalid, i_err, ic_flush;
            wire [31:0] i_addr, i_rdata;
            n1_core #(
                .RESET_VECTOR(RESET_VECTOR), .HARTID(h), .TLB_ENTRIES(TLB_ENTRIES),
                .MUL_FAST(FAST ? 1 : 0), .BRANCH_PRED(1)
            ) u_core (
                .clk(clk), .rst_n(rst_n),
                .ibus_req(i_req), .ibus_addr(i_addr), .ibus_gnt(i_gnt),
                .ibus_rvalid(i_rvalid), .ibus_rdata(i_rdata), .ibus_err(i_err),
                .dbus_req(m_req[2*h]), .dbus_we(m_we[2*h]), .dbus_be(m_be[8*h +: 4]),
                .dbus_addr(m_addr[64*h +: 32]), .dbus_wdata(m_wdata[64*h +: 32]),
                .dbus_lock(m_lock[2*h]), .icache_flush(ic_flush),
                .snoop_valid(snoop_valid), .snoop_addr(snoop_addr),
                .irq_s_external(eip[2*h+1]),
                .dbus_gnt(m_gnt[2*h]), .dbus_rvalid(m_rvalid[2*h]),
                .dbus_rdata(m_rdata), .dbus_err(m_err),
                .irq_software(msip[h]), .irq_timer(mtip[h]), .irq_external(eip[2*h]),
                .irq_fast(16'b0),
                .dbg_halt_req(1'b0), .dbg_resume_req(1'b0), .dbg_halted(),
                .dbg_reg_req(1'b0), .dbg_reg_we(1'b0), .dbg_reg_no(16'b0),
                .dbg_reg_wdata(32'b0), .dbg_reg_rdata(), .dbg_reg_err(),
                .sleeping(sleeping[h])
            );
            if (ICACHE != 0) begin : g_ic
                n1_icache #(.LINES(ICACHE_LINES), .LW(ICACHE_LW)) u_icache (
                    .clk(clk), .rst_n(rst_n), .flush(ic_flush),
                    .c_req(i_req), .c_addr(i_addr), .c_gnt(i_gnt), .c_rvalid(i_rvalid),
                    .c_rdata(i_rdata), .c_err(i_err),
                    .b_req(m_req[2*h+1]), .b_addr(m_addr[64*h+32 +: 32]),
                    .b_gnt(m_gnt[2*h+1]), .b_rvalid(m_rvalid[2*h+1]),
                    .b_rdata(m_rdata), .b_err(m_err)
                );
            end else begin : g_noic
                // No cache: a one-entry registered bridge.  The register is
                // needed because a direct connection would close a
                // combinational loop (fetch address -> arbitration -> data
                // grant -> redirect -> fetch address).
                reg  [1:0]  nb_state;          // 0 idle, 1 request, 2 wait
                reg  [31:0] nb_addr;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        nb_state <= 2'd0;
                        nb_addr  <= 32'd0;
                    end else begin
                        case (nb_state)
                            2'd0: if (i_req) begin nb_addr <= i_addr; nb_state <= 2'd1; end
                            2'd1: if (m_gnt[2*h+1]) nb_state <= 2'd2;
                            default: if (m_rvalid[2*h+1]) nb_state <= 2'd0;
                        endcase
                    end
                end
                assign m_req[2*h+1]            = (nb_state == 2'd1);
                assign m_addr[64*h+32 +: 32]   = nb_addr;
                assign i_gnt                   = (nb_state == 2'd0);
                assign i_rvalid                = (nb_state == 2'd2) & m_rvalid[2*h+1];
                assign i_rdata                 = m_rdata;
                assign i_err                   = m_err;
            end
            assign m_we[2*h+1]              = 1'b0;
            assign m_lock[2*h+1]            = 1'b0;
            assign m_be[8*h+4 +: 4]         = 4'b1111;
            assign m_wdata[64*h+32 +: 32]   = 32'b0;
        end
    endgenerate

    wire        s_req, s_we, s_gnt, s_rvalid, s_err;
    wire [3:0]  s_be;
    wire [31:0] s_addr, s_wdata, s_rdata;
    n1_membus #(.N(NM)) u_bus (
        .clk(clk), .rst_n(rst_n),
        .m_req(m_req), .m_we(m_we), .m_lock(m_lock), .m_be(m_be), .m_addr(m_addr),
        .m_wdata(m_wdata), .m_gnt(m_gnt), .m_rvalid(m_rvalid), .m_rdata(m_rdata),
        .m_err(m_err),
        .s_req(s_req), .s_we(s_we), .s_be(s_be), .s_addr(s_addr), .s_wdata(s_wdata),
        .s_gnt(s_gnt), .s_rvalid(s_rvalid), .s_rdata(s_rdata), .s_err(s_err),
        .snoop_valid(snoop_valid), .snoop_addr(snoop_addr)
    );

    // ---- address decode: internal one-cycle devices, or the external port
    wire is_clint = (s_addr[31:16] == 16'h0200);
    wire is_plic  = (s_addr[31:22] == 10'h030);          // 0x0C00_0000 .. 0x0C3F_FFFF
    wire is_uart  = (s_addr[31:12] == 20'h10000);
    wire is_int   = is_clint | is_plic | is_uart;

    reg       int_pend_q;
    reg [1:0] int_sel_q;
    wire [31:0] clint_rdata, plic_rdata, uart_rdata;
    wire        uart_irq;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            int_pend_q <= 1'b0; int_sel_q <= 2'd0;
        end else begin
            int_pend_q <= s_req & is_int;
            if (s_req & is_int) int_sel_q <= is_clint ? 2'd0 : is_plic ? 2'd1 : 2'd2;
        end
    end
    assign mem_req   = s_req & ~is_int;
    assign mem_we    = s_we;
    assign mem_be    = s_be;
    assign mem_addr  = s_addr;
    assign mem_wdata = s_wdata;
    assign s_gnt     = is_int ? 1'b1 : mem_gnt;
    assign s_rvalid  = int_pend_q | mem_rvalid;
    assign s_rdata   = int_pend_q ? ((int_sel_q == 2'd0) ? clint_rdata :
                                     (int_sel_q == 2'd1) ? plic_rdata : uart_rdata)
                                  : mem_rdata;
    assign s_err     = int_pend_q ? 1'b0 : mem_err;

    n1_clint #(.NH(NCORES)) u_clint (
        .clk(clk), .rst_n(rst_n), .sel(s_req & is_clint), .we(s_we),
        .addr(s_addr[15:0]), .wdata(s_wdata), .rdata(clint_rdata),
        .msip(msip), .mtip(mtip)
    );
    n1_plic #(.NCTX(2*NCORES)) u_plic (
        .clk(clk), .rst_n(rst_n), .sel(s_req & is_plic), .we(s_we),
        .addr(s_addr[21:0]), .wdata(s_wdata), .rdata(plic_rdata),
        .src({ext_irq, uart_irq}), .eip(eip)
    );
    gust_uart u_uart (
        .clk(clk), .rst_n(rst_n), .sel(s_req & is_uart), .we(s_we),
        .addr(s_addr[11:2]), .wdata(s_wdata), .rdata(uart_rdata),
        .rx(uart_rx), .tx(uart_tx), .irq(uart_irq)
    );
endmodule
