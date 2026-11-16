// =============================================================================
// Core-level testbench harness: gust_core + a behavioural memory that speaks
// the Gust bus protocol.
//
//  * One flat memory at MEM_BASE shared by the instruction and data buses.
//  * stall_mode = 0 : ideal memory (grant always, response next cycle), i.e.
//                     exactly how on-chip synchronous RAM behaves.
//    stall_mode = 1 : grants are withheld and responses delayed at random,
//                     to exercise every handshake corner in the core.
//  * Accesses outside the memory return a bus error.
//  * A write to `tohost_addr` is captured for the riscv-tests pass/fail
//    protocol.
//  * A small test device lives at IO_BASE:
//      +0x00 PUTC       W  console character
//      +0x04 IRQ_ARM    W  raise these interrupt lines IRQ_DELAY cycles from now
//                          bit0 software, bit1 timer, bit2 external,
//                          bits 31:16 fast[15:0]
//      +0x08 IRQ_DELAY  W  delay used by the next IRQ_ARM
//      +0x0C IRQ_CLR    W  drop the given interrupt lines
//      +0x10 IRQ_STATE  R  lines currently raised
//      +0x14 CYCLE      R  free-running cycle counter
//    It lets a test program land an interrupt on an exact cycle.
// =============================================================================
`timescale 1ns/1ps

module tb_core #(
    parameter [31:0] MEM_BASE    = 32'h8000_0000,
    parameter        MEM_WORDS   = 131072,           // 512 KiB
    parameter [31:0] IO_BASE     = 32'hF000_0000,
    parameter        EXT_B       = 1,
    parameter        EXT_ZCB     = 1,
    parameter        MUL_FAST    = 1,
    parameter        BRANCH_PRED = 1,
    parameter        OPERAND_ISO = 1,
    parameter        CLOCK_GATE  = 0,
    parameter        SINGLE_PORT = 0     // 1: fetch loses the memory to data accesses
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        stall_mode,
    input  wire [31:0] tohost_addr,
    input  wire        irq_software,
    input  wire        irq_timer,
    input  wire        irq_external,
    input  wire [15:0] irq_fast,
    input  wire        dbg_halt_req,
    input  wire        dbg_resume_req,
    input  wire        dbg_reg_req,
    input  wire        dbg_reg_we,
    input  wire [15:0] dbg_reg_no,
    input  wire [31:0] dbg_reg_wdata,
    output wire [31:0] dbg_reg_rdata,
    output wire        dbg_reg_err,
    output wire        dbg_halted,
    output wire        sleeping,
    output reg         tohost_valid,
    output reg  [31:0] tohost_data,
    output reg         putc_strobe,     // toggles once per console character
    output reg  [7:0]  putc_data,
    output reg         proto_err
);
    reg [31:0] mem [0:MEM_WORDS-1];

    wire        ibus_req, ibus_gnt, dbus_req, dbus_gnt, dbus_we;
    wire [31:0] ibus_addr, dbus_addr, dbus_wdata;
    wire [3:0]  dbus_be;
    reg         ibus_rvalid, ibus_err, dbus_rvalid, dbus_err;
    reg  [31:0] ibus_rdata, dbus_rdata;

    // test device state
    reg  [31:0] io_irq, io_arm_mask, io_delay, io_arm_cnt, io_cycle;
    reg         io_armed;

    n1_core #(
        .RESET_VECTOR(MEM_BASE), .EXT_B(EXT_B), .EXT_ZCB(EXT_ZCB),
        .MUL_FAST(MUL_FAST), .BRANCH_PRED(BRANCH_PRED),
        .OPERAND_ISO(OPERAND_ISO), .CLOCK_GATE(CLOCK_GATE)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .ibus_req(ibus_req), .ibus_addr(ibus_addr), .ibus_gnt(ibus_gnt),
        .ibus_rvalid(ibus_rvalid), .ibus_rdata(ibus_rdata), .ibus_err(ibus_err),
        .dbus_req(dbus_req), .dbus_we(dbus_we), .dbus_be(dbus_be),
        .dbus_addr(dbus_addr), .dbus_wdata(dbus_wdata), .dbus_gnt(dbus_gnt),
        .dbus_rvalid(dbus_rvalid), .dbus_rdata(dbus_rdata), .dbus_err(dbus_err),
        .irq_software(irq_software | io_irq[0]), .irq_timer(irq_timer | io_irq[1]),
        .irq_external(irq_external | io_irq[2]), .irq_fast(irq_fast | io_irq[31:16]),
        .dbg_halt_req(dbg_halt_req), .dbg_resume_req(dbg_resume_req),
        .dbg_halted(dbg_halted), .dbg_reg_req(dbg_reg_req),
        .dbg_reg_we(dbg_reg_we), .dbg_reg_no(dbg_reg_no),
        .dbg_reg_wdata(dbg_reg_wdata), .dbg_reg_rdata(dbg_reg_rdata),
        .dbg_reg_err(dbg_reg_err), .sleeping(sleeping),
        .dbus_lock(), .icache_flush(), .snoop_valid(1'b0), .snoop_addr(32'b0), .irq_s_external(1'b0)
    );

    // ------------------------------------------------------- randomness
    reg [31:0] lfsr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 32'hACE1_2468;
        else        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    end

    function in_range;
        input [31:0] a;
        begin
            in_range = (a >= MEM_BASE) && (a < MEM_BASE + 4 * MEM_WORDS);
        end
    endfunction

    // ------------------------------------------------------ instruction bus
    // Ideal mode: grant always, response in the very next cycle - exactly a
    // synchronous RAM.  Stall mode: random grant, response 1..4 cycles later.
    reg        i_busy;
    reg [1:0]  i_wait;
    reg [31:0] i_data;
    reg        i_err;
    assign ibus_gnt = ~i_busy & (~stall_mode | lfsr[3] | lfsr[7]) &
                      ~((SINGLE_PORT != 0) & dbus_req & in_range(dbus_addr));

    wire [1:0]  i_delay = (stall_mode & lfsr[12]) ? lfsr[14:13] : 2'd0;
    wire        i_ok    = in_range(ibus_addr);
    wire [31:0] i_rd    = i_ok ? mem[(ibus_addr - MEM_BASE) >> 2] : 32'hDEAD_BEEF;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_busy <= 1'b0; i_wait <= 2'd0; ibus_rvalid <= 1'b0;
            ibus_err <= 1'b0; ibus_rdata <= 32'b0;
        end else begin
            ibus_rvalid <= 1'b0;
            if (i_busy) begin
                if (i_wait == 2'd0) begin
                    ibus_rvalid <= 1'b1;
                    ibus_rdata  <= i_data;
                    ibus_err    <= i_err;
                    i_busy      <= 1'b0;
                end else begin
                    i_wait <= i_wait - 2'd1;
                end
            end
            if (ibus_req & ibus_gnt) begin
                if (i_delay == 2'd0) begin
                    ibus_rvalid <= 1'b1;
                    ibus_rdata  <= i_rd;
                    ibus_err    <= ~i_ok;
                end else begin
                    i_busy <= 1'b1;
                    i_wait <= i_delay - 2'd1;
                    i_data <= i_rd;
                    i_err  <= ~i_ok;
                end
            end
        end
    end

    // ------------------------------------------------------------ data bus
    reg       d_busy;
    reg [1:0] d_wait;
    reg [31:0] d_data;
    reg       d_err;
    assign dbus_gnt = ~d_busy & (~stall_mode | lfsr[5] | lfsr[9]);
    wire [1:0]  d_delay = (stall_mode & lfsr[17]) ? lfsr[19:18] : 2'd0;

    wire [31:0] d_idx    = (dbus_addr - MEM_BASE) >> 2;
    wire        d_is_io  = (dbus_addr[31:8] == IO_BASE[31:8]);
    wire        d_accept = dbus_req & dbus_gnt;
    wire        d_bad    = ~in_range(dbus_addr) & ~d_is_io;
    wire [31:0] d_rd     = in_range(dbus_addr)       ? mem[d_idx] :
                           (dbus_addr[7:0] == 8'h10) ? io_irq :
                           (dbus_addr[7:0] == 8'h14) ? io_cycle : 32'b0;
    integer b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_busy <= 1'b0; d_wait <= 2'd0; dbus_rvalid <= 1'b0;
            dbus_err <= 1'b0; dbus_rdata <= 32'b0;
            tohost_valid <= 1'b0; tohost_data <= 32'b0;
            putc_strobe <= 1'b0; putc_data <= 8'b0;
            io_irq <= 32'b0; io_arm_mask <= 32'b0; io_delay <= 32'b0;
            io_arm_cnt <= 32'b0; io_armed <= 1'b0; io_cycle <= 32'b0;
        end else begin
            dbus_rvalid <= 1'b0;
            io_cycle    <= io_cycle + 32'd1;
            if (io_armed) begin
                if (io_arm_cnt == 32'd0) begin
                    io_irq   <= io_irq | io_arm_mask;
                    io_armed <= 1'b0;
                end else begin
                    io_arm_cnt <= io_arm_cnt - 32'd1;
                end
            end
            if (d_busy) begin
                if (d_wait == 2'd0) begin
                    dbus_rvalid <= 1'b1;
                    dbus_rdata  <= d_data;
                    dbus_err    <= d_err;
                    d_busy      <= 1'b0;
                end else begin
                    d_wait <= d_wait - 2'd1;
                end
            end
            if (d_accept) begin
                if (d_delay == 2'd0) begin
                    dbus_rvalid <= 1'b1;
                    dbus_rdata  <= d_rd;
                    dbus_err    <= d_bad;
                end else begin
                    d_busy <= 1'b1;
                    d_wait <= d_delay - 2'd1;
                    d_data <= d_rd;
                    d_err  <= d_bad;
                end
                if (dbus_we) begin
                    if (in_range(dbus_addr)) begin
                        for (b = 0; b < 4; b = b + 1)
                            if (dbus_be[b]) mem[d_idx][8*b +: 8] <= dbus_wdata[8*b +: 8];
                    end
                    if ({dbus_addr[31:2], 2'b00} == tohost_addr) begin
                        tohost_valid <= 1'b1;
                        tohost_data  <= dbus_wdata;
                    end
                    if (d_is_io) begin
                        case (dbus_addr[7:0])
                        8'h00: begin
                            putc_strobe <= ~putc_strobe;
                            putc_data  <= dbus_wdata[7:0];
                        end
                        8'h04: begin
                            io_arm_mask <= dbus_wdata;
                            io_arm_cnt  <= io_delay;
                            io_armed    <= 1'b1;
                        end
                        8'h08: io_delay <= dbus_wdata;
                        8'h0C: io_irq   <= io_irq & ~dbus_wdata;
                        default: ;
                        endcase
                    end
                end
            end
        end
    end

    // --------------------------------------------------- protocol checkers
    // The data bus must hold a request stable until it is granted, and may
    // never have two transactions outstanding.  Violations latch proto_err,
    // which the Python tests check - far easier to debug than a wrong result
    // thousands of cycles later.
    reg        chk_d_hold, chk_d_pend;
    reg [31:0] chk_d_addr;
    reg        chk_d_we;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            chk_d_hold <= 1'b0;
            chk_d_pend <= 1'b0;
            proto_err  <= 1'b0;
        end else begin
            if (chk_d_hold && !(dbus_req && dbus_addr == chk_d_addr && dbus_we == chk_d_we)) begin
                $display("PROTOCOL ERROR: dbus request changed before grant at %0t", $time);
                proto_err <= 1'b1;
            end
            if (dbus_req && chk_d_pend && !dbus_rvalid) begin
                $display("PROTOCOL ERROR: second dbus request while one is outstanding at %0t", $time);
                proto_err <= 1'b1;
            end
            if (d_accept)         chk_d_pend <= 1'b1;
            else if (dbus_rvalid) chk_d_pend <= 1'b0;
            chk_d_hold <= dbus_req & ~dbus_gnt;
            chk_d_addr <= dbus_addr;
            chk_d_we   <= dbus_we;
        end
    end

    // standalone (non-cocotb) runs: +hex=<file> preloads the memory
    reg [1023:0] hexfile;
    initial begin
        if ($value$plusargs("hex=%s", hexfile)) $readmemh(hexfile, mem);
    end

`ifdef GUST_TRACE
    // one line per executed instruction / trap, for debugging
    always @(posedge clk) begin
        if (rst_n && dut.u_core.x_fire)
            $display("TRACE %0d pc=%h instr=%h res=%h", io_cycle, dut.u_core.x_pc, dut.u_core.x_instr, dut.u_core.x_result);
        if (rst_n && dut.u_core.trap_en)
            $display("TRACE %0d TRAP cause=%0d irq=%b epc=%h tval=%h", io_cycle,
                     dut.u_core.trap_cause, dut.u_core.trap_is_irq, dut.u_core.trap_pc, dut.u_core.trap_tval);
    end
`endif

`ifdef GUST_DUMP
    initial begin
        $dumpfile("tb_core.vcd");
        $dumpvars(0, tb_core);
    end
`endif
endmodule
