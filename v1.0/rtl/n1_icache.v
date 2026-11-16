// =============================================================================
// Gust N1 - instruction cache
//
// A "bus filter": it speaks the Gust bus protocol on both sides, so the core
// does not know it is there.  Direct mapped, LINES lines of 4 words.
//   hit  : response one cycle after the request, exactly like on-chip RAM
//   miss : the line is fetched with four reads on the system side, then the
//          response is given
// Read only, so several cores each with their own cache never disagree about
// data; code that is modified must be followed by fence.i (flush), as the ISA
// requires.  A bus error during a refill is passed on and the line is not kept.
// =============================================================================
module n1_icache #(
    parameter LINES = 64,
    parameter LW    = 6          // log2(LINES)
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        flush,
    input  wire        c_req,
    input  wire [31:0] c_addr,
    output wire        c_gnt,
    output wire        c_rvalid,
    output wire [31:0] c_rdata,
    output wire        c_err,
    output wire        b_req,
    output wire [31:0] b_addr,
    input  wire        b_gnt,
    input  wire        b_rvalid,
    input  wire [31:0] b_rdata,
    input  wire        b_err
);
    localparam TW = 28 - LW;
    localparam [1:0] S_IDLE = 2'd0, S_REQ = 2'd1, S_WAIT = 2'd2, S_RESP = 2'd3;

    reg [31:0]      data [0:LINES*4-1];
    reg [TW-1:0]    tag  [0:LINES-1];
    reg [LINES-1:0] valid;

    reg [1:0]    state;
    reg          pend, rd_valid, err_acc, kill;
    reg [31:0]   lat_addr, rd_data, hold;
    reg [TW-1:0] rd_tag;
    reg [1:0]    cnt;

    wire [LW-1:0] c_idx = c_addr[LW+3:4];
    wire [LW-1:0] l_idx = lat_addr[LW+3:4];
    wire          hit   = pend & rd_valid & (rd_tag == lat_addr[31:LW+4]);
    wire          miss  = pend & ~hit & (state == S_IDLE);

    assign c_gnt    = (state == S_IDLE) & (~pend | hit);
    assign c_rvalid = hit ? (state == S_IDLE) : (state == S_RESP);
    assign c_rdata  = (state == S_RESP) ? hold : rd_data;
    assign c_err    = (state == S_RESP) & err_acc;
    assign b_req    = (state == S_REQ);
    assign b_addr   = {lat_addr[31:4], cnt, 2'b00};

    wire accept = c_req & c_gnt;

    always @(posedge clk) begin
        if (accept) begin
            rd_data <= data[{c_idx, c_addr[3:2]}];
            rd_tag  <= tag[c_idx];
        end
        if ((state == S_WAIT) & b_rvalid) begin
            data[{l_idx, cnt}] <= b_rdata;
            if (cnt == lat_addr[3:2]) hold <= b_rdata;
            if (cnt == 2'd3) tag[l_idx] <= lat_addr[31:LW+4];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; pend <= 1'b0; rd_valid <= 1'b0; err_acc <= 1'b0;
            kill <= 1'b0; cnt <= 2'd0; valid <= {LINES{1'b0}}; lat_addr <= 32'b0;
        end else begin
            if (accept) begin
                pend     <= 1'b1;
                lat_addr <= c_addr;
                rd_valid <= valid[c_idx] & ~flush;
            end else if (hit | (state == S_RESP)) begin
                pend <= 1'b0;
            end
            case (state)
            S_IDLE: if (miss) begin
                state        <= S_REQ;
                cnt          <= 2'd0;
                err_acc      <= 1'b0;
                kill         <= 1'b0;
                valid[l_idx] <= 1'b0;
            end
            S_REQ:  if (b_gnt) state <= S_WAIT;
            S_WAIT: if (b_rvalid) begin
                err_acc <= err_acc | b_err;
                cnt     <= cnt + 2'd1;
                if (cnt == 2'd3) begin
                    state <= S_RESP;
                    if (!(err_acc | b_err | kill | flush)) valid[l_idx] <= 1'b1;
                end else begin
                    state <= S_REQ;
                end
            end
            default: state <= S_IDLE;                  // S_RESP
            endcase
            if (flush) begin
                valid <= {LINES{1'b0}};
                kill  <= 1'b1;
            end
        end
    end
endmodule
