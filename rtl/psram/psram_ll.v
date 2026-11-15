// ============================================================================
// psram_ll -- low-latency, single-word PSRAM (HyperRAM) controller for ONE
// die of the GW1NR-9's embedded W955D8MBYA PSRAM.
//
// Derived from Feng Zhou's (nand2mario) PsramController (2022),
// https://github.com/zf3/psram-tang-nano-9k, Apache License 2.0, as used in
// Atari7800_AstroCart_V2/V3. Changes for V4:
//   * rd_valid: one-cycle pulse when dout holds fresh read data (the
//     original only signalled completion through busy falling).
//   * Single-die ports (scalar ck/cs/rwds, 8-bit dq) so the top level can
//     instantiate one controller per die and race them (see docs/DEVELOPMENT.md).
//   * A behavioural model under `VERILATOR` that reproduces the real
//     controller's cycle timing, including random 2x (refresh-collision)
//     latency, so harnesses can be simulated without Gowin primitives.
//
// Timing (from the original author, at LATENCY=3, 1:1 clocking): read
// request -> rd_valid is 12 cycles (1x latency) or 15 cycles (2x latency,
// when the die is refreshing as CS# falls). Variable latency mode is used,
// so the die only takes 2x when it actually collides with a refresh.
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

module psram_ll #(
    parameter FREQ    = 81_000_000, // clk frequency, for the 150 us power-up wait
    parameter LATENCY = 3,          // tACC: 3 (<=83 MHz), 4 (<=104), 5 (<=133), 6 (<=166)
    // CK_MODE selects how CK is generated; both put CK's rising edge 90 deg
    // after the DQ launch edge, one cycle after ck_e:
    //   0: original -- ck_e delayed a cycle (ck_e_p), ODDR on clk_p = clk+90.
    //      The ck_e_p -> ODDR path then only has 1/4 period (3 ns at 81 MHz).
    //   1: clk_p = clk+270 (PSDA "1100"), ODDR D0=0/D1=ck_e: same CK timing at
    //      the pin, but the fabric path gets 3/4 period.
    parameter CK_MODE = 0,
    // Minimum cycles CS# stays high between transactions (busy covers it).
    parameter CSHI = 3,
    parameter [31:0] SIM_SEED = 32'h1234_5678   // behavioural model only
) (
    input  wire        clk,
    input  wire        clk_p,       // phase-shifted clk, drives the PSRAM CK pins
    input  wire        resetn,
    input  wire        read,        // 1-cycle request (only while !busy)
    input  wire        write,       // 1-cycle request (only while !busy)
    input  wire        abort,       // end an in-progress READ now (CS# high); ignored otherwise
    input  wire [3:0]  burst_n,     // read: extra words after the first (0-15), one per cycle;
                                    // the die wraps at 32 bytes, so start 16-word bursts aligned
    input  wire [21:0] addr,        // byte address; reads are word (16-bit) based
    input  wire [15:0] din,
    input  wire        byte_write,  // write one byte: addr[0]=1 -> din[15:8], else din[7:0]
    output reg  [15:0] dout,
    output reg         rd_valid,    // 1-cycle pulse: dout updated by a read
    output wire        busy,        // high from the cycle after a request until done
    output reg         wr_done,     // 1-cycle pulse: write data issued
    output reg         wr_2x,       // with wr_done: the 2x (refresh collision) path was taken
    output reg  [15:0] wr_trace,    // with wr_done: RWDS {ris,fal} seen in cycles 1..8 of the write (debug)

    // One die's pins
    output wire        O_psram_ck,
    output wire        O_psram_ck_n,
    inout  wire        IO_psram_rwds,
    inout  wire [7:0]  IO_psram_dq,
    output wire        O_psram_cs_n
);

`ifdef VERILATOR
// ----------------------------------------------------------------------------
// Behavioural model: 4 MB per die (all the controller addresses).
// ----------------------------------------------------------------------------
reg [15:0] v_mem [0:(1<<21)-1];
reg [4:0]  v_cnt;
reg        v_rd;
reg [20:0] v_waddr;
reg [31:0] v_lfsr;
reg [15:0] v_init;               // short power-up wait
reg [3:0]  v_cool;
reg [3:0]  v_left;               // burst words still to deliver
reg        v_burst;
/* verilator lint_off UNUSEDPARAM */

assign busy = (v_init != 16'd0) || (v_cnt != 5'd0) || (v_cool != 4'd0) || v_burst;
assign O_psram_ck    = 1'b0;
assign O_psram_ck_n  = 1'b1;
assign O_psram_cs_n  = 1'b1;
assign IO_psram_rwds = 1'bz;
assign IO_psram_dq   = 8'hzz;

always @(posedge clk) begin
    rd_valid <= 1'b0;
    wr_done  <= 1'b0;
    v_lfsr   <= {v_lfsr[30:0], v_lfsr[31] ^ v_lfsr[21] ^ v_lfsr[1] ^ v_lfsr[0]};
    if (!resetn) begin
        v_lfsr <= SIM_SEED;
        v_init <= 16'd200;
        v_cnt  <= 5'd0;
        v_cool <= 4'd0;
        v_burst <= 1'b0;
    end else if (v_init != 16'd0) begin
        v_init <= v_init - 16'd1;
    end else if (v_burst) begin
        if (abort) begin
            v_burst <= 1'b0;
            v_cool  <= CSHI[3:0];
        end else begin
            dout     <= v_mem[v_waddr];
            rd_valid <= 1'b1;
            v_waddr  <= {v_waddr[20:4], v_waddr[3:0] + 4'd1};
            v_left   <= v_left - 4'd1;
            if (v_left == 4'd1) begin
                v_burst <= 1'b0;
                v_cool  <= CSHI[3:0];
            end
        end
    end else if (v_cnt != 5'd0) begin
        v_cnt <= v_cnt - 5'd1;
        if (v_cnt == 5'd1 && v_rd && v_left != 4'd0) begin
            v_burst <= 1'b1;
            v_waddr <= {v_waddr[20:4], v_waddr[3:0] + 4'd1};
        end else if (v_cnt == 5'd1) v_cool <= CSHI[3:0];
        if (v_cnt == 5'd1 && v_rd) begin
            dout     <= v_mem[v_waddr];
            rd_valid <= 1'b1;
        end else if (abort && v_rd) begin
            v_cnt  <= 5'd0;
            v_cool <= CSHI[3:0];
        end
    end else if (v_cool != 4'd0) begin
        v_cool <= v_cool - 4'd1;
    end else if (read) begin
        v_rd    <= 1'b1;
        v_left  <= burst_n;
        v_waddr <= addr[21:1];
        // 12 cycles normally; ~1/64 of reads take the 2x path (15 cycles).
        v_cnt   <= (v_lfsr[5:0] == 6'd0) ? 5'd15 : 5'd12;
    end else if (write) begin
        v_rd <= 1'b0;
        if (byte_write) begin
            if (addr[0]) v_mem[addr[21:1]][15:8] <= din[15:8];
            else         v_mem[addr[21:1]][7:0]  <= din[7:0];
        end else begin
            v_mem[addr[21:1]] <= din;
        end
        v_cnt   <= 5'd9;
        wr_done <= 1'b1;
        wr_2x   <= (v_lfsr[5:0] == 6'd1);
        wr_trace <= 16'd0;
    end
end

`else
// ----------------------------------------------------------------------------
// Hardware implementation (Gowin ODDR/IDDR primitives)
// ----------------------------------------------------------------------------
reg [2:0] state;
localparam [2:0] INIT_ST   = 3'd0;
localparam [2:0] CONFIG_ST = 3'd1;
localparam [2:0] IDLE_ST   = 3'd2;
localparam [2:0] READ_ST   = 3'd3;
localparam [2:0] WRITE_ST  = 3'd4;

reg cfg_now, dq_oen, ram_cs_n, ck_e, ck_e_p;
reg wait_for_rd_data;
reg [15:0] w_din;
reg [23:0] cycles_sr;       // one-hot cycle counter
reg [63:0] dq_sr;           // shifts left 16 bits (one DDR cycle) per clk

wire [7:0] dq_out_ris = dq_sr[63:56];
wire [7:0] dq_out_fal = dq_sr[55:48];
wire [7:0] dq_in_ris;
wire [7:0] dq_in_fal;
reg rwds_out_ris, rwds_out_fal, rwds_oen;
wire rwds_in_ris, rwds_in_fal;
reg additional_latency;
reg w_byte_write;
reg tr_on;
reg [3:0] cool;
reg [3:0] words_left;
reg w_addr0;

wire cs_n_tbuf, cs_n_tbuf_q1;
wire rwds_tbuf, rwds_oen_tbuf;
wire ck_tbuf, ck_tbuf_q1;
wire ck_n_tbuf, ck_n_tbuf_q1;

assign busy = (state != IDLE_ST) || (cool != 4'd0);

// CR0 latency code (W955D8MBYA datasheet)
localparam [3:0] CR_LATENCY = LATENCY == 3 ? 4'b1110 :
                              LATENCY == 4 ? 4'b1111 :
                              LATENCY == 5 ? 4'b0000 :
                              LATENCY == 6 ? 4'b0001 : 4'b1110;

always @(posedge clk) begin
    cycles_sr <= {cycles_sr[22:0], 1'b0};
    dq_sr     <= {dq_sr[47:0], 16'b0};
    ck_e_p    <= ck_e;
    rd_valid  <= 1'b0;
    wr_done   <= 1'b0;

    if (state == INIT_ST && cfg_now) begin
        cycles_sr <= 24'b1;
        ram_cs_n  <= 1'b0;
        state     <= CONFIG_ST;
    end
    if (state == CONFIG_ST) begin
        if (cycles_sr[0]) begin
            // CR0 write: drive strength default, latency code, variable
            // latency ('7' = bit3 clear), 32-byte wrapped burst (unused).
            dq_sr  <= {8'h60, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h9f, CR_LATENCY, 4'h7};
            dq_oen <= 1'b0;
            ck_e   <= 1'b1;
        end
        if (cycles_sr[4]) begin
            state     <= IDLE_ST;
            ck_e      <= 1'b0;
            cycles_sr <= 24'b1;
            dq_oen    <= 1'b1;
            ram_cs_n  <= 1'b1;
        end
    end
    if (cool != 4'd0)
        cool <= cool - 4'd1;

    if (state == IDLE_ST) begin
        rwds_oen <= 1'b1;
        ck_e     <= 1'b0;
        ram_cs_n <= 1'b1;
        if ((read || write) && cool == 4'd0) begin
            // 48-bit command/address + 16 bits of padding
            dq_sr <= {~write, 13'b010_0000_0000_00, addr[21:4], 13'b0, addr[3:1],
                      16'b0000_0100_1101_0100};
            ram_cs_n         <= 1'b0;
            ck_e             <= 1'b1;
            dq_oen           <= 1'b0;
            wait_for_rd_data <= 1'b0;
            w_din            <= din;
            w_byte_write     <= byte_write;
            w_addr0          <= addr[0];
            words_left       <= burst_n;
            cycles_sr        <= 24'b10;
            wr_trace         <= 16'd0;
            tr_on            <= write;
            state            <= write ? WRITE_ST : READ_ST;
        end
    end

    if (state == READ_ST) begin
        if (cycles_sr[3])
            dq_oen <= 1'b1;               // command sent, release DQ
        if (cycles_sr[9])
            wait_for_rd_data <= 1'b1;
        // RWDS toggles with the first data word (handles 1x and 2x latency)
        // (in a burst RWDS keeps toggling, one word per cycle)
        if (abort) begin
            ram_cs_n <= 1'b1;
            ck_e     <= 1'b0;
            dq_oen   <= 1'b1;
            cool     <= CSHI[3:0];
            state    <= IDLE_ST;
        end else if (wait_for_rd_data && (rwds_in_ris ^ rwds_in_fal)) begin
            dout     <= {dq_in_ris, dq_in_fal};
            rd_valid <= 1'b1;
            if (words_left == 4'd0) begin
                ram_cs_n <= 1'b1;
                ck_e     <= 1'b0;
                cool     <= CSHI[3:0];
                state    <= IDLE_ST;
            end else begin
                words_left <= words_left - 4'd1;
            end
        end
    end

    // RWDS trace: cycles 1..8 after a write request, whatever the state
    if (tr_on && |cycles_sr[8:1])
        wr_trace <= {wr_trace[13:0], rwds_in_ris, rwds_in_fal};
    if (cycles_sr[8])
        tr_on <= 1'b0;

    if (state == WRITE_ST) begin
        if (cycles_sr[5])
            additional_latency <= rwds_in_fal;  // RWDS high during CA = 2x latency
        if (cycles_sr[2+LATENCY] && (LATENCY == 3 ? ~rwds_in_fal : ~additional_latency)
            || cycles_sr[2+LATENCY*2])
        begin
            rwds_oen     <= 1'b0;
            rwds_out_ris <= w_byte_write ? ~w_addr0 : 1'b0;   // RWDS = write mask
            rwds_out_fal <= w_byte_write ?  w_addr0 : 1'b0;
            dq_sr[63:48] <= w_din;
            wr_done      <= 1'b1;
            wr_2x        <= !(cycles_sr[2+LATENCY] && (LATENCY == 3 ? ~rwds_in_fal : ~additional_latency));
            cool         <= CSHI[3:0] + 4'd1;   // + the data cycle itself
            state        <= IDLE_ST;
        end
    end

    if (~resetn) begin
        state    <= INIT_ST;
        ram_cs_n <= 1'b1;
        ck_e     <= 1'b0;
        cool     <= 4'd0;
    end
end

// 160 us power-up wait, then a one-cycle cfg_now pulse
localparam INIT_TIME = FREQ / 1000 * 160 / 1000;
localparam integer RST_CNT_W = $clog2(INIT_TIME+1) + 1;
reg [RST_CNT_W-1:0] rst_cnt;
reg rst_done, rst_done_p1;

always @(posedge clk) begin
    rst_done_p1 <= rst_done;
    cfg_now     <= rst_done & ~rst_done_p1;
    if (rst_cnt != INIT_TIME[RST_CNT_W-1:0]) begin
        rst_cnt  <= rst_cnt + 1'b1;
        rst_done <= 1'b0;
    end else begin
        rst_done <= 1'b1;
    end
    if (~resetn) begin
        rst_cnt  <= {RST_CNT_W{1'b0}};
        rst_done <= 1'b0;
    end
end

// DDR outputs
wire [7:0] dq_out_tbuf;
wire [7:0] dq_oen_tbuf;
ODDR oddr_cs_n (.CLK(clk), .D0(ram_cs_n), .D1(ram_cs_n), .TX(1'b0), .Q0(cs_n_tbuf), .Q1(cs_n_tbuf_q1));
assign O_psram_cs_n = cs_n_tbuf;

ODDR oddr_rwds (.CLK(clk), .D0(rwds_out_ris), .D1(rwds_out_fal), .TX(rwds_oen), .Q0(rwds_tbuf), .Q1(rwds_oen_tbuf));
assign IO_psram_rwds = rwds_oen_tbuf ? 1'bz : rwds_tbuf;

genvar i;
generate
    for (i = 0; i < 8; i = i + 1) begin : g_dq
        ODDR oddr_dq (.CLK(clk), .D0(dq_out_ris[i]), .D1(dq_out_fal[i]), .TX(dq_oen),
                      .Q0(dq_out_tbuf[i]), .Q1(dq_oen_tbuf[i]));
        assign IO_psram_dq[i] = dq_oen_tbuf[i] ? 1'bz : dq_out_tbuf[i];
        IDDR iddr_dq (.CLK(clk), .D(IO_psram_dq[i]), .Q0(dq_in_ris[i]), .Q1(dq_in_fal[i]));
    end
endgenerate

// CK from the phase-shifted clock (see CK_MODE)
generate
    if (CK_MODE == 0) begin : g_ck0
        ODDR oddr_ck   (.CLK(clk_p), .D0(ck_e_p),  .D1(1'b0), .TX(1'b0), .Q0(ck_tbuf),   .Q1(ck_tbuf_q1));
        ODDR oddr_ck_n (.CLK(clk_p), .D0(~ck_e_p), .D1(1'b1), .TX(1'b0), .Q0(ck_n_tbuf), .Q1(ck_n_tbuf_q1));
    end else begin : g_ck1
        ODDR oddr_ck   (.CLK(clk_p), .D0(1'b0), .D1(ck_e),  .TX(1'b0), .Q0(ck_tbuf),   .Q1(ck_tbuf_q1));
        ODDR oddr_ck_n (.CLK(clk_p), .D0(1'b1), .D1(~ck_e), .TX(1'b0), .Q0(ck_n_tbuf), .Q1(ck_n_tbuf_q1));
    end
endgenerate
assign O_psram_ck   = ck_tbuf;
assign O_psram_ck_n = ck_n_tbuf;

IDDR iddr_rwds (.CLK(clk), .D(IO_psram_rwds), .Q0(rwds_in_ris), .Q1(rwds_in_fal));

`endif

endmodule

`default_nettype wire
