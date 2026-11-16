// =============================================================================
// Gust N1 - platform-level interrupt controller (standard PLIC register layout)
//   sources 1..7 (level, active high), priorities 0..7 (0 = never), NCTX
//   contexts: context 2*h is hart h in machine mode, 2*h+1 in supervisor mode.
//   0x000000 + 4*i        priority of source i
//   0x001000              pending bits
//   0x002000 + 0x80*c     enable bits of context c
//   0x200000 + 0x1000*c   priority threshold of context c
//   0x200004 + 0x1000*c   read = claim (highest-priority pending enabled source,
//                         0 if none), write = complete
// A claimed source stays masked until it is completed.
// =============================================================================
module n1_plic #(
    parameter NCTX = 4
) (
    input  wire            clk,
    input  wire            rst_n,
    input  wire            sel,
    input  wire            we,
    input  wire [21:0]     addr,
    input  wire [31:0]     wdata,
    output reg  [31:0]     rdata,
    input  wire [7:1]      src,
    output wire [NCTX-1:0] eip
);
    reg [2:0] prio   [1:7];
    reg [7:1] pending, inservice;
    reg [7:1] enable [0:NCTX-1];
    reg [2:0] thresh [0:NCTX-1];

    // best pending source for each context
    reg [2:0] best_id [0:NCTX-1];
    reg [2:0] best_pr [0:NCTX-1];
    integer c_0, i_0, c_1, i_1, c_2, i_2;   // one loop variable per always block (Yosys: no shared drivers)
    always @* begin
        for (c_0 = 0; c_0 < NCTX; c_0 = c_0 + 1) begin
            best_id[c_0] = 3'd0;
            best_pr[c_0] = 3'd0;
            for (i_0 = 7; i_0 >= 1; i_0 = i_0 - 1)
                if (pending[i_0] & enable[c_0][i_0] & (prio[i_0] != 3'd0) & (prio[i_0] >= best_pr[c_0])) begin
                    best_id[c_0] = i_0[2:0];
                    best_pr[c_0] = prio[i_0];
                end
        end
    end
    genvar g;
    generate
        for (g = 0; g < NCTX; g = g + 1) begin : g_eip
            assign eip[g] = (best_pr[g] > thresh[g]);
        end
    endgenerate

    wire        is_ctx  = addr[21];
    wire [8:0]  ctx_no  = addr[20:12];
    wire        claim   = sel & ~we & is_ctx & (addr[11:0] == 12'h004) & (ctx_no < NCTX);
    wire        complete= sel &  we & is_ctx & (addr[11:0] == 12'h004) & (ctx_no < NCTX);
    wire [2:0]  claim_id = best_id[ctx_no[$clog2(NCTX)-1:0]];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= 7'b0; inservice <= 7'b0;
            for (i_1 = 1; i_1 <= 7; i_1 = i_1 + 1) prio[i_1] <= 3'd0;
            for (c_1 = 0; c_1 < NCTX; c_1 = c_1 + 1) begin
                enable[c_1] <= 7'b0; thresh[c_1] <= 3'd0;
            end
        end else begin
            for (i_1 = 1; i_1 <= 7; i_1 = i_1 + 1) begin
                if (src[i_1] & ~inservice[i_1]) pending[i_1] <= 1'b1;
                if (claim && claim_id == i_1) begin
                    pending[i_1]   <= 1'b0;
                    inservice[i_1] <= 1'b1;
                end
                if (complete && wdata[2:0] == i_1) inservice[i_1] <= 1'b0;
                if (sel & we & ~is_ctx & (addr[20:0] == 4*i_1)) prio[i_1] <= wdata[2:0];
            end
            for (c_1 = 0; c_1 < NCTX; c_1 = c_1 + 1) begin
                if (sel & we & ~is_ctx & (addr[20:0] == 21'h002000 + 21'h80*c_1)) enable[c_1] <= wdata[7:1];
                if (sel & we & is_ctx & (ctx_no == c_1) & (addr[11:0] == 12'h000)) thresh[c_1] <= wdata[2:0];
            end
        end
    end
    always @(posedge clk) begin
        if (sel & ~we) begin
            rdata <= 32'b0;
            for (i_2 = 1; i_2 <= 7; i_2 = i_2 + 1)
                if (~is_ctx & (addr[20:0] == 4*i_2)) rdata <= {29'b0, prio[i_2]};
            if (~is_ctx & (addr[20:0] == 21'h001000)) rdata <= {24'b0, pending, 1'b0};
            for (c_2 = 0; c_2 < NCTX; c_2 = c_2 + 1) begin
                if (~is_ctx & (addr[20:0] == 21'h002000 + 21'h80*c_2)) rdata <= {24'b0, enable[c_2], 1'b0};
                if (is_ctx & (ctx_no == c_2) & (addr[11:0] == 12'h000)) rdata <= {29'b0, thresh[c_2]};
            end
            if (claim) rdata <= {29'b0, claim_id};
        end
    end
endmodule
