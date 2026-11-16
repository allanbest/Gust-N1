// =============================================================================
// Gust N1 - shared memory bus
//
// N masters (every core's data port and every core's cache-refill port) share
// one path to memory and peripherals.  One transaction at a time, round-robin.
//
//   lock : a master doing an atomic read-modify-write asserts lock with its
//          read; nobody else is granted until its write has been granted (or
//          it drops lock after a fault).  That makes amo*.w atomic across cores.
//   snoop: every granted write is announced to all cores so they can cancel a
//          load reservation on that word (lr.w / sc.w).
// The slave side may take any number of cycles to grant and to respond, which
// is what a real external RAM controller needs.
// =============================================================================
module n1_membus #(
    parameter N = 4
) (
    input  wire            clk,
    input  wire            rst_n,
    input  wire [N-1:0]    m_req,
    input  wire [N-1:0]    m_we,
    input  wire [N-1:0]    m_lock,
    input  wire [4*N-1:0]  m_be,
    input  wire [32*N-1:0] m_addr,
    input  wire [32*N-1:0] m_wdata,
    output wire [N-1:0]    m_gnt,
    output wire [N-1:0]    m_rvalid,
    output wire [31:0]     m_rdata,
    output wire            m_err,
    output wire            s_req,
    output wire            s_we,
    output wire [3:0]      s_be,
    output wire [31:0]     s_addr,
    output wire [31:0]     s_wdata,
    input  wire            s_gnt,
    input  wire            s_rvalid,
    input  wire [31:0]     s_rdata,
    input  wire            s_err,
    output wire            snoop_valid,
    output wire [31:0]     snoop_addr
);
    localparam W = (N > 1) ? $clog2(N) : 1;
    reg         busy_q, locked_q;
    reg [W-1:0] owner_q, lock_owner_q, rr_q, held_pick_q;
    reg         held_q;        // a request is waiting for its grant: do not re-arbitrate

    // round-robin pick, starting after the last master served
    reg [W-1:0] pick;
    reg         any;
    integer i;
    reg [W:0] idx;
    always @* begin
        pick = {W{1'b0}};
        any  = 1'b0;
        for (i = N; i >= 1; i = i - 1) begin
            idx = rr_q + i[W:0];
            if (idx >= N) idx = idx - N[W:0];
            if (m_req[idx[W-1:0]]) begin
                pick = idx[W-1:0];
                any  = 1'b1;
            end
        end
        if (locked_q) begin
            pick = lock_owner_q;
            any  = m_req[lock_owner_q];
        end
        if (held_q) begin
            pick = held_pick_q;
            any  = m_req[held_pick_q];
        end
    end

    wire can_issue = ~busy_q | s_rvalid;
    assign s_req   = can_issue & any;
    assign s_we    = m_we[pick];
    assign s_be    = m_be[4*pick +: 4];
    assign s_addr  = m_addr[32*pick +: 32];
    assign s_wdata = m_wdata[32*pick +: 32];
    wire   grant   = s_req & s_gnt;

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : g_m
            assign m_gnt[g]    = grant & (pick == g);
            assign m_rvalid[g] = s_rvalid & busy_q & (owner_q == g);
        end
    endgenerate
    assign m_rdata = s_rdata;
    assign m_err   = s_err;
    assign snoop_valid = grant & s_we;
    assign snoop_addr  = s_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_q <= 1'b0; locked_q <= 1'b0; owner_q <= {W{1'b0}};
            lock_owner_q <= {W{1'b0}}; rr_q <= {W{1'b0}};
            held_q <= 1'b0; held_pick_q <= {W{1'b0}};
        end else begin
            held_q      <= s_req & ~s_gnt;
            held_pick_q <= pick;
            if (grant)         busy_q <= 1'b1;
            else if (s_rvalid) busy_q <= 1'b0;
            if (grant) begin
                owner_q <= pick;
                rr_q    <= pick;
                if (m_lock[pick] & ~m_we[pick]) begin
                    locked_q     <= 1'b1;
                    lock_owner_q <= pick;
                end else if (m_we[pick]) begin
                    locked_q <= 1'b0;
                end
            end else if (locked_q & ~m_lock[lock_owner_q]) begin
                locked_q <= 1'b0;
            end
        end
    end
endmodule
