// ============================================================================
// psram_dual -- both PSRAM dies of the GW1NR-9 behind one port.
//
// Writes go to both dies (they hold identical images). Reads go to the dies
// selected by `dies`; with both selected they race, the first answer is
// returned and the slower die's read is aborted. Measured on silicon
// (lab/psram_lab): a single die takes 13 cycles at 81 MHz, or 16 when it
// collides with an internal refresh (~0.012%); racing both gave 13 cycles on
// every one of millions of reads.
//
// Requests are levels (`want`): the decision to issue is taken here, next to
// the controllers, so the requester (the cart bus logic, at the other end of
// the chip) never needs the controllers' busy state in the same cycle.
//
// Writes that collide with a refresh are lost by psram_ll (the collision is
// only visible after the 1x data slot), so a writer must read back and
// retry -- see the loader in devcart_top.
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

module psram_dual #(
    parameter FREQ    = 81_000_000,
    parameter LATENCY = 3,
    parameter CK_MODE = 1,
    parameter CSHI    = 3
) (
    input  wire        clk,
    input  wire        clk_p,
    input  wire        resetn,

    input  wire        want,         // read request (level); issued when the dies are free
    input  wire        wr,           // write pulse, only while !busy_q (both dies)
    input  wire [1:0]  dies,         // read: which dies take part (2'b11 = race)
    input  wire        abort,        // abandon the read in flight
    input  wire [21:0] addr,         // byte address (word aligned)
    input  wire        bsel,         // which byte of the word the read wants
    input  wire [3:0]  burst_n,      // extra words (die-direct outputs dout0/valid0 carry them)
    input  wire [15:0] din,
    output wire        issued,       // the read was issued this cycle
    output reg  [15:0] dout,         // registered answer (first die to answer)
    output reg  [7:0]  dbyte,        // ... and the byte selected by bsel
    output reg  [20:0] dword,        // ... and its word address
    output reg         rd_valid,     // 1-cycle pulse with dout/dbyte/dword
    output wire [15:0] dout0,        // per-die results (for read-back verify)
    output wire [15:0] dout1,
    output wire        valid0,
    output wire        valid1,
    output wire        busy,
    output reg         busy_q,       // busy, registered (for logic far from here)

    // Die 1 on its own (x_mode): single-word reads for the 6502 while die 0
    // feeds a bank copy. The main port must then only use die 0.
    input  wire        x_mode,
    input  wire        x_read,       // 1-cycle, only while !busy1
    input  wire        x_abort,
    input  wire        x_write,      // 1-cycle, only while !busy1: write the byte x_wd at x_addr
    input  wire [7:0]  x_wd,
    input  wire [21:0] x_addr,
    output wire        busy1,

    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    output wire [1:0]  O_psram_cs_n,
    inout  wire [1:0]  IO_psram_rwds,
    inout  wire [15:0] IO_psram_dq
);
    wire [1:0] b;
    reg        pending;          // a read is outstanding (no answer yet)
    reg  [1:0] rd_dies;
    reg  [1:0] kill;             // abort the slower die after the race is won
    reg        p_bsel;
    reg  [20:0] p_word;

    assign busy   = b[0] | (b[1] && !x_mode);
    assign busy1  = b[1];
    assign issued = want && !busy && !pending && !abort;

    wire win0  = valid0 && rd_dies[0];
    wire first = pending && (win0 || (valid1 && rd_dies[1]));
    wire [15:0] win_word = win0 ? dout0 : dout1;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            pending <= 1'b0; rd_dies <= 2'b00; kill <= 2'b00; busy_q <= 1'b1;
            rd_valid <= 1'b0; dout <= 16'd0; dbyte <= 8'd0; dword <= 21'd0;
            p_bsel <= 1'b0; p_word <= 21'd0;
        end else begin
            kill     <= 2'b00;
            busy_q   <= busy;
            rd_valid <= first && !abort;
            dout     <= win_word;
            dbyte    <= p_bsel ? win_word[15:8] : win_word[7:0];
            dword    <= p_word;
            if (issued) begin
                pending <= 1'b1;
                rd_dies <= dies;
                p_bsel  <= bsel;
                p_word  <= addr[21:1];
            end else if (abort) begin
                pending <= 1'b0;
            end else if (first) begin
                pending <= 1'b0;
                kill    <= win0 ? 2'b10 : 2'b01;    // stop the loser
            end
        end
    end

    genvar g;
    generate
        for (g = 0; g < 2; g = g + 1) begin : g_die
            wire [15:0] dq_o;
            wire        v_o;
            wire        wd_unused, w2x_unused;
            wire [15:0] wtr_unused;
            psram_ll #(.FREQ(FREQ), .LATENCY(LATENCY), .CK_MODE(CK_MODE), .CSHI(CSHI),
                       .SIM_SEED(32'h1234_5678 ^ (g * 32'h9E37_79B9))) u_ctl (
                .clk(clk), .clk_p(clk_p), .resetn(resetn),
                .read((g == 1 && x_mode) ? x_read : (issued && dies[g])),
                .write((g == 1 && x_mode) ? x_write : wr),
                .abort((g == 1 && x_mode) ? x_abort : (abort || kill[g])),
                .burst_n((g == 1 && x_mode) ? 4'd0 : burst_n),
                .addr((g == 1 && x_mode) ? x_addr : addr),
                .din((g == 1 && x_mode) ? {x_wd, x_wd} : din), .byte_write(g == 1 && x_mode),
                .dout(dq_o), .rd_valid(v_o), .busy(b[g]),
                .wr_done(wd_unused), .wr_2x(w2x_unused), .wr_trace(wtr_unused),
                .O_psram_ck(O_psram_ck[g]), .O_psram_ck_n(O_psram_ck_n[g]),
                .IO_psram_rwds(IO_psram_rwds[g]), .IO_psram_dq(IO_psram_dq[8*g +: 8]),
                .O_psram_cs_n(O_psram_cs_n[g])
            );
            if (g == 0) begin : g0
                assign dout0 = dq_o; assign valid0 = v_o;
            end else begin : g1
                assign dout1 = dq_o; assign valid1 = v_o;
            end
        end
    endgenerate
endmodule

`default_nettype wire
