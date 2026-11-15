// ============================================================================
// psram_lab_top -- PSRAM latency/correctness lab for a bare Tang Nano 9K.
//
// Answers, on real silicon, the question every earlier AstroCart version
// guessed at: how fast and how reliable is a single random PSRAM read?
//
//   1. Fill both dies with the same address-derived pattern (full 4 MB each).
//   2. Do 2^NREADS_LOG2 random word reads per test, in three modes:
//        mode 0: die 0 only      mode 1: die 1 only
//        mode 2: race -- same read to both dies, first answer wins
//      at three request spacings (cycles between read issues):
//        0 (back to back), P_FAST (279 ns, MARIA 2-cycle DMA),
//        P_ROM (419 ns, MARIA 3-cycle ROM DMA)
//   3. Print a latency histogram + error counters per test over UART
//      (pin 17 -> BL702 -> second usbserial port, 115200 8N1).
//   4. Change the pattern seed, refill, repeat forever.
//
// tools/psram_lab_read.py decodes the output.
//
// UART record: "\r\n@" then 105 hex words (8 digits, space separated):
//   word 0      : {8'hA5, mode, period, round}
//   words 1-32  : histogram, die 0 latency   (bin i = latency i+LAT_BASE cycles,
//   words 33-64 : histogram, die 1 latency    first/last bins are clamped)
//   words 65-96 : histogram, race (min) latency
//   97 : reads   98 : die0 data errors   99 : die1 data errors
//   100: timeouts 101: first bad word addr 102: first bad {got, expected}
//   103: die0 strictly first (race)        104: die1 strictly first (race)
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

module psram_lab_top #(
    parameter FREQ          = 81_000_000,
    parameter LATENCY       = 3,
    parameter PLL_IDIV      = 0,
    parameter PLL_FBDIV     = 2,
    parameter PLL_ODIV      = 8,
    parameter PLL_PSDA      = "0100",
    parameter CLKS_PER_BIT  = FREQ / 115200,
    parameter FILL_LOG2     = 21,          // words per die to fill/test (2^21 = 4 MB)
    parameter NREADS_LOG2   = 20,          // reads per test
    parameter LAT_BASE      = 6,           // histogram bin 0 = this many cycles
    parameter CK_MODE       = 0            // see psram_ll
) (
    input  wire        clk27,
    output wire        uart_txd,
    output wire [5:0]  led,

    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    output wire [1:0]  O_psram_cs_n,
    output wire [1:0]  O_psram_reset_n,
    inout  wire [1:0]  IO_psram_rwds,
    inout  wire [15:0] IO_psram_dq
);
    // ------------------------------------------------------------------
    // Clocks and reset
    // ------------------------------------------------------------------
    wire clk, clk_p, lock;
    pll_main #(.IDIV(PLL_IDIV), .FBDIV(PLL_FBDIV), .ODIV(PLL_ODIV), .PSDA(PLL_PSDA))
        u_pll (.clkin(clk27), .clkout(clk), .clkoutp(clk_p), .lock(lock));

    reg [7:0] rst_sh;
    always @(posedge clk or negedge lock) begin
        if (!lock) rst_sh <= 8'h00;
        else       rst_sh <= {rst_sh[6:0], 1'b1};
    end
    wire rst_n = rst_sh[7];

    assign O_psram_reset_n = 2'b11;

    // Cycle counts for the two MARIA DMA spacings
    localparam integer P_FAST_I = (FREQ / 1000 * 279 + 999_999) / 1_000_000;
    localparam integer P_ROM_I  = (FREQ / 1000 * 419 + 999_999) / 1_000_000;
    localparam [7:0] P_FAST = P_FAST_I[7:0];
    localparam [7:0] P_ROM  = P_ROM_I[7:0];

    // ------------------------------------------------------------------
    // Two controllers, one per die
    // ------------------------------------------------------------------
    reg         c_rd [0:1];
    reg         c_wr [0:1];
    reg  [21:0] c_addr;
    reg  [15:0] c_din;
    wire [15:0] c_dout [0:1];
    wire        c_valid[0:1];
    wire        c_busy [0:1];
    wire        c_wdone[0:1];
    wire        c_w2x  [0:1];
    wire [15:0] c_wtr  [0:1];

    genvar g;
    generate
        for (g = 0; g < 2; g = g + 1) begin : g_die
            psram_ll #(.FREQ(FREQ), .LATENCY(LATENCY), .CK_MODE(CK_MODE)) u_ctl (
                .clk(clk), .clk_p(clk_p), .resetn(rst_n),
                .read(c_rd[g]), .write(c_wr[g]), .abort(1'b0), .burst_n(4'd0), .addr(c_addr), .din(c_din),
                .byte_write(1'b0), .dout(c_dout[g]), .rd_valid(c_valid[g]), .busy(c_busy[g]),
                .wr_done(c_wdone[g]), .wr_2x(c_w2x[g]), .wr_trace(c_wtr[g]),
                .O_psram_ck(O_psram_ck[g]), .O_psram_ck_n(O_psram_ck_n[g]),
                .IO_psram_rwds(IO_psram_rwds[g]), .IO_psram_dq(IO_psram_dq[8*g +: 8]),
                .O_psram_cs_n(O_psram_cs_n[g])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // Pattern and random address
    // ------------------------------------------------------------------
    reg [15:0] seed;
    function [15:0] pat;
        input [20:0] a;
        input [15:0] s;
        pat = {a[7:0], a[15:8]} ^ {a[20:16], 3'b000, a[20:16], 3'b000} ^ s;
    endfunction

    reg [31:0] rnd;
    wire [31:0] rnd_x1 = rnd ^ (rnd << 13);
    wire [31:0] rnd_x2 = rnd_x1 ^ (rnd_x1 >> 17);
    wire [31:0] rnd_nx = rnd_x2 ^ (rnd_x2 << 5);

    localparam [21:0] FILL_MASK22 = (22'd1 << FILL_LOG2) - 22'd1;
    localparam [20:0] FILL_MASK = FILL_MASK22[20:0];

    // ------------------------------------------------------------------
    // Histogram memory: 3 banks x 32 bins (synchronous read)
    // ------------------------------------------------------------------
    reg  [31:0] hist [0:127];
    reg  [6:0]  h_raddr;
    reg  [31:0] h_q;
    reg         h_we;
    reg  [6:0]  h_waddr;
    reg  [31:0] h_wdata;
    always @(posedge clk) begin
        h_q <= hist[h_raddr];
        if (h_we) hist[h_waddr] <= h_wdata;
    end

    function [4:0] bin_of;
        input [6:0] lat;
        reg [6:0] d;
        begin
            d = lat - LAT_BASE[6:0];
            bin_of = (lat < LAT_BASE[6:0])        ? 5'd0  :
                     (lat > LAT_BASE[6:0] + 7'd31) ? 5'd31 : d[4:0];
        end
    endfunction

    // ------------------------------------------------------------------
    // Counters
    // ------------------------------------------------------------------
    reg [23:0] n_reads, n_err0, n_err1, n_tmo, n_win0, n_win1;   // 24 bits: short carry chains
    reg [31:0] bad_addr, bad_data;
    reg [23:0] f_wr, f_2x0, f_2x1, f_bad0, f_bad1, f_bad2x, f_dead;
    reg        w2x0, w2x1;        // last write's path, per die
    reg [15:0] wtr0, wtr1;        // last write's RWDS trace, per die
    reg [15:0] tr_bad_or, tr_ok_or, tr_ok_and;
    reg [1:0]  f_try;
    reg        fi_wr, fi_2x0, fi_2x1, fi_bad0, fi_bad1, fi_bad2x, fi_dead, fi_clr;  // increment strobes

    // Fill counters, one cycle behind the FSM's strobes (keeps the state
    // decode off the counters' enables)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || fi_clr) begin
            f_wr <= 0; f_2x0 <= 0; f_2x1 <= 0; f_bad0 <= 0; f_bad1 <= 0; f_bad2x <= 0; f_dead <= 0;
        end else begin
            if (fi_wr)    f_wr    <= f_wr + 1;
            if (fi_2x0)   f_2x0   <= f_2x0 + 1;
            if (fi_2x1)   f_2x1   <= f_2x1 + 1;
            if (fi_bad0)  f_bad0  <= f_bad0 + 1;
            if (fi_bad1)  f_bad1  <= f_bad1 + 1;
            if (fi_bad2x) f_bad2x <= f_bad2x + 1;
            if (fi_dead)  f_dead  <= f_dead + 1;
        end
    end
    reg        any_err;

    // ------------------------------------------------------------------
    // UART
    // ------------------------------------------------------------------
    reg        u_start;
    reg  [7:0] u_data;
    wire       u_busy;
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (
        .clk(clk), .rst_n(rst_n), .start(u_start), .data(u_data), .busy(u_busy), .tx(uart_txd));

    function [7:0] hexc;
        input [3:0] n;
        hexc = (n < 4'd10) ? (8'h30 + {4'h0, n}) : (8'h37 + {4'h0, n});
    endfunction

    // ------------------------------------------------------------------
    // Main FSM. Every compare/mux that feeds a wide register is given its
    // own cycle so the harness closes timing at the PSRAM clock with margin
    // (the controllers, not the harness, are what's being measured).
    // ------------------------------------------------------------------
    localparam [4:0]
        S_CLEAR     = 5'd0,
        S_BOOT      = 5'd1,
        S_FILL      = 5'd2,
        S_FILL_W    = 5'd3,
        S_FILL_INC  = 5'd4,
        S_RD        = 5'd5,
        S_RD_W      = 5'd6,
        S_CHK       = 5'd7,
        S_REC_A     = 5'd8,
        S_REC_A2    = 5'd9,
        S_REC_B     = 5'd10,
        S_REC_C     = 5'd11,
        S_NEXT      = 5'd12,
        S_PR_HDR    = 5'd13,
        S_PR_FETCH  = 5'd14,
        S_PR_FETCH2 = 5'd15,
        S_PR_FETCH3 = 5'd16,
        S_PR_NIB    = 5'd17,
        S_PR_SEP    = 5'd18,
        S_PR_ADV    = 5'd19,
        S_REC_D     = 5'd20,
        S_FILL_RD   = 5'd21,
        S_FILL_RW   = 5'd22,
        S_FILL_CHK  = 5'd23,
        S_FILL_CHK2 = 5'd24;

    reg [4:0]  st;
    reg [20:0] waddr;
    reg        waddr_last;
    reg [20:0] raddr;
    reg [NREADS_LOG2:0] nread;
    reg        nread_last;
    reg [1:0]  mode;          // 0 die0, 1 die1, 2 race
    reg [1:0]  pidx;          // 0, P_FAST, P_ROM
    reg [7:0]  period;
    reg        use0, use1;
    reg [7:0]  round;
    reg [7:0]  since;         // cycles since last issue (saturating)
    reg [6:0]  lat, lat0, lat1;
    reg        tmo_soon;
    reg        got0, got1;
    reg [15:0] d0_q, d1_q, exp_q;
    reg        bad0, bad1, first_bad_done;
    reg [1:0]  rec_bank;
    reg [6:0]  rec_lat;
    reg [4:0]  rec_bin;
    reg [6:0]  pr_word;
    reg [3:0]  pr_nib;
    reg [31:0] pr_val;
    reg [1:0]  pr_hdr;
    reg [1:0]  pr_sel;        // 0 histogram, 1 header, 2 counter
    reg [4:0]  pr_cidx;
    reg [31:0] pr_ctr;
    reg        pr_last, pr_eol;
    reg        need_fill;     // refill (new seed) before the next test
    reg        all_idle;
    reg        lt01, lt10;    // registered lat0 < lat1, lat1 < lat0
    reg        lat_gt3;

    always @(posedge clk) all_idle <= !c_busy[0] && !c_busy[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_CLEAR;
            lt01 <= 1'b0; lt10 <= 1'b0; lat_gt3 <= 1'b0;
            c_rd[0] <= 1'b0; c_rd[1] <= 1'b0; c_wr[0] <= 1'b0; c_wr[1] <= 1'b0;
            c_addr <= 22'd0; c_din <= 16'd0;
            h_we <= 1'b0; h_waddr <= 7'd0; h_wdata <= 32'd0; h_raddr <= 7'd0;
            u_start <= 1'b0; u_data <= 8'h00;
            seed <= 16'h5A3C; rnd <= 32'h2545_F491;
            mode <= 2'd0; pidx <= 2'd0; period <= 8'd0; use0 <= 1'b1; use1 <= 1'b0;
            round <= 8'd0;
            waddr <= 21'd0; waddr_last <= 1'b0; raddr <= 21'd0;
            nread <= 0; nread_last <= 1'b0;
            since <= 8'd0; lat <= 7'd0; lat0 <= 7'd0; lat1 <= 7'd0; tmo_soon <= 1'b0;
            got0 <= 1'b0; got1 <= 1'b0;
            d0_q <= 16'd0; d1_q <= 16'd0; exp_q <= 16'd0;
            bad0 <= 1'b0; bad1 <= 1'b0; first_bad_done <= 1'b0;
            rec_bank <= 2'd0; rec_lat <= 7'd0; rec_bin <= 5'd0;
            pr_word <= 7'd0; pr_nib <= 4'd0; pr_val <= 32'd0; pr_hdr <= 2'd0;
            pr_sel <= 2'd0; pr_cidx <= 5'd0; pr_ctr <= 32'd0; pr_last <= 1'b0; pr_eol <= 1'b0;
            n_reads <= 0; n_err0 <= 0; n_err1 <= 0; n_tmo <= 0;
            bad_addr <= 0; bad_data <= 0; n_win0 <= 0; n_win1 <= 0;
            need_fill <= 1'b1;
            fi_wr <= 1'b0; fi_2x0 <= 1'b0; fi_2x1 <= 1'b0; fi_bad0 <= 1'b0; fi_bad1 <= 1'b0;
            fi_bad2x <= 1'b0; fi_dead <= 1'b0; fi_clr <= 1'b0;
            w2x0 <= 1'b0; w2x1 <= 1'b0; f_try <= 2'd0;
            wtr0 <= 16'd0; wtr1 <= 16'd0;
            tr_bad_or <= 16'd0; tr_ok_or <= 16'd0; tr_ok_and <= 16'hFFFF;
        end else begin
            c_rd[0] <= 1'b0; c_rd[1] <= 1'b0; c_wr[0] <= 1'b0; c_wr[1] <= 1'b0;
            h_we    <= 1'b0;
            u_start <= 1'b0;
            fi_wr <= 1'b0; fi_2x0 <= 1'b0; fi_2x1 <= 1'b0; fi_bad0 <= 1'b0; fi_bad1 <= 1'b0;
            fi_bad2x <= 1'b0; fi_dead <= 1'b0; fi_clr <= 1'b0;
            if (since != 8'hFF) since <= since + 8'd1;

            case (st)
            // Zero the histogram and counters, then refill (first time and
            // after every round) or go straight on to the next test.
            S_CLEAR: begin
                h_we    <= 1'b1;
                h_waddr <= waddr[6:0];
                h_wdata <= 32'd0;
                n_reads <= 0; n_err0 <= 0; n_err1 <= 0; n_tmo <= 0;
                bad_addr <= 0; bad_data <= 0; n_win0 <= 0; n_win1 <= 0;
                first_bad_done <= 1'b0;
                period <= (pidx == 2'd0) ? 8'd0 : (pidx == 2'd1) ? P_FAST : P_ROM;
                use0   <= (mode != 2'd1);
                use1   <= (mode != 2'd0);
                if (waddr[6:0] == 7'd127) begin
                    waddr <= 21'd0; waddr_last <= 1'b0;
                    nread <= 0; nread_last <= 1'b0;
                    st    <= need_fill ? S_BOOT : S_RD;
                end else begin
                    waddr <= waddr + 21'd1;
                end
            end

            S_BOOT: if (all_idle) begin
                need_fill <= 1'b0;
                fi_clr    <= 1'b1;
                f_try     <= 2'd0;
                tr_bad_or <= 16'd0; tr_ok_or <= 16'd0; tr_ok_and <= 16'hFFFF;
                st        <= S_FILL;
            end

            // Fill both dies with the same pattern
            S_FILL: begin
                c_wr[0] <= 1'b1; c_wr[1] <= 1'b1;
                c_addr  <= {waddr, 1'b0};
                c_din   <= pat(waddr, seed);
                since   <= 8'd1;
                waddr_last <= (waddr == FILL_MASK);
                st      <= S_FILL_W;
            end
            // all_idle lags busy by a cycle, so give the request two cycles
            // to show up as busy before trusting it.
            S_FILL_W: begin
                if (c_wdone[0]) w2x0 <= c_w2x[0];
                if (c_wdone[1]) w2x1 <= c_w2x[1];
                // 12 cycles: the 8-cycle RWDS trace is complete by then
                if (since >= 8'd12 && all_idle) begin
                    wtr0 <= c_wtr[0];
                    wtr1 <= c_wtr[1];
                    st   <= S_FILL_RD;
                end
            end
            S_FILL_RD: begin
                fi_wr   <= 1'b1;
                fi_2x0  <= w2x0;
                fi_2x1  <= w2x1;
                c_rd[0] <= 1'b1; c_rd[1] <= 1'b1;   // c_addr still holds the word
                exp_q   <= c_din;
                got0    <= 1'b0; got1 <= 1'b0;
                since   <= 8'd1;
                st      <= S_FILL_RW;
            end
            S_FILL_RW: begin
                if (c_valid[0] && !got0) begin got0 <= 1'b1; d0_q <= c_dout[0]; end
                if (c_valid[1] && !got1) begin got1 <= 1'b1; d1_q <= c_dout[1]; end
                if (got0 && got1 && all_idle && since >= 8'd3) st <= S_FILL_CHK;
            end
            S_FILL_CHK: begin
                bad0 <= (d0_q != exp_q);
                bad1 <= (d1_q != exp_q);
                st   <= S_FILL_CHK2;
            end
            S_FILL_CHK2: begin
                fi_bad0  <= bad0;
                fi_bad1  <= bad1;
                tr_bad_or <= tr_bad_or | (bad0 ? wtr0 : 16'd0) | (bad1 ? wtr1 : 16'd0);
                tr_ok_or  <= tr_ok_or  | (bad0 ? 16'd0 : wtr0) | (bad1 ? 16'd0 : wtr1);
                tr_ok_and <= tr_ok_and & (bad0 ? 16'hFFFF : wtr0) & (bad1 ? 16'hFFFF : wtr1);
                fi_bad2x <= (bad0 && w2x0) || (bad1 && w2x1);
                if ((bad0 || bad1) && f_try != 2'd3) begin
                    f_try <= f_try + 2'd1;
                    st    <= S_FILL;                 // rewrite the same word
                end else begin
                    fi_dead <= bad0 || bad1;
                    f_try <= 2'd0;
                    st    <= S_FILL_INC;
                end
            end
            S_FILL_INC: begin
                if (waddr_last) begin
                    waddr <= 21'd0;
                    st    <= S_RD;
                end else begin
                    waddr <= waddr + 21'd1;
                    st    <= S_FILL;
                end
            end

            // Issue one random read once the spacing has elapsed
            S_RD: if (all_idle && since >= period) begin
                c_rd[0] <= use0;
                c_rd[1] <= use1;
                c_addr  <= {rnd[20:0] & FILL_MASK, 1'b0};
                raddr   <= rnd[20:0] & FILL_MASK;
                exp_q   <= pat(rnd[20:0] & FILL_MASK, seed);
                rnd     <= rnd_nx;
                since   <= 8'd1;
                lat     <= 7'd1;
                tmo_soon <= 1'b0;
                lat_gt3 <= 1'b0;
                got0    <= !use0;
                got1    <= !use1;
                lat0    <= 7'd127;
                lat1    <= 7'd127;
                st      <= S_RD_W;
            end

            S_RD_W: begin
                lat      <= lat + 7'd1;
                tmo_soon <= (lat == 7'd99);
                lat_gt3  <= (lat >= 7'd3);
                if (c_valid[0] && !got0) begin
                    got0 <= 1'b1;
                    lat0 <= lat;
                    d0_q <= c_dout[0];
                end
                if (c_valid[1] && !got1) begin
                    got1 <= 1'b1;
                    lat1 <= lat;
                    d1_q <= c_dout[1];
                end
                if (got0 && got1 && all_idle && lat_gt3) begin
                    bad0 <= use0 && (d0_q != exp_q);
                    bad1 <= use1 && (d1_q != exp_q);
                    lt01 <= (lat0 < lat1);
                    lt10 <= (lat1 < lat0);
                    st   <= S_CHK;
                end else if (tmo_soon) begin
                    n_tmo   <= n_tmo + 1;
                    n_reads <= n_reads + 1;
                    st      <= S_NEXT;
                end
            end

            S_CHK: begin
                n_reads <= n_reads + 1;
                if (bad0) n_err0 <= n_err0 + 1;
                if (bad1) n_err1 <= n_err1 + 1;
                if ((bad0 || bad1) && !first_bad_done) begin
                    first_bad_done <= 1'b1;
                    bad_addr <= {bad1 && !bad0, 10'd0, raddr};
                    bad_data <= {bad0 ? d0_q : d1_q, exp_q};
                end
                if (mode == 2'd2) begin
                    if (lt01) n_win0 <= n_win0 + 1;
                    if (lt10) n_win1 <= n_win1 + 1;
                end
                rec_bank <= (mode == 2'd1) ? 2'd1 : 2'd0;
                st       <= S_REC_A;
            end

            // Histogram read-modify-write, one bank at a time
            S_REC_A: begin
                rec_lat <= (rec_bank == 2'd0) ? lat0 :
                           (rec_bank == 2'd1) ? lat1 :
                           (lt01 ? lat0 : lat1);
                st <= S_REC_A2;
            end
            S_REC_A2: begin
                rec_bin <= bin_of(rec_lat);
                st      <= S_REC_B;
            end
            S_REC_B: begin
                h_raddr <= {rec_bank, rec_bin};
                st      <= S_REC_C;
            end
            S_REC_C: st <= S_REC_D;        // h_q valid next cycle
            S_REC_D: begin
                h_we    <= 1'b1;
                h_waddr <= h_raddr;
                h_wdata <= h_q + 32'd1;
                if (mode == 2'd2 && rec_bank != 2'd2) begin
                    rec_bank <= rec_bank + 2'd1;
                    st       <= S_REC_A;
                end else begin
                    st <= S_NEXT;
                end
            end

            S_NEXT: begin
                nread      <= nread + 1'b1;
                nread_last <= (nread == ((1 << NREADS_LOG2) - 2));
                if (nread_last) begin
                    pr_hdr  <= 2'd0;
                    pr_word <= 7'd0;
                    st      <= S_PR_HDR;
                end else begin
                    st <= S_RD;
                end
            end

            // ---- UART dump: "\r\n@" then 105 words ----
            S_PR_HDR: if (!u_busy && !u_start) begin
                u_start <= 1'b1;
                u_data  <= (pr_hdr == 2'd0) ? 8'h0D : (pr_hdr == 2'd1) ? 8'h0A : 8'h40;
                if (pr_hdr == 2'd2) st <= S_PR_FETCH;
                pr_hdr <= pr_hdr + 2'd1;
            end
            S_PR_FETCH: begin
                h_raddr <= pr_word - 7'd1;
                pr_sel  <= (pr_word == 7'd0) ? 2'd1 : (pr_word >= 7'd97) ? 2'd2 : 2'd0;
                pr_cidx <= pr_word[4:0] - 5'd1;     // 97 -> 0 ... 114 -> 17
                pr_last <= (pr_word == 7'd114);
                pr_eol  <= (pr_word[2:0] == 3'd7) || (pr_word == 7'd114);
                st      <= S_PR_FETCH2;
            end
            S_PR_FETCH2: begin
                case (pr_cidx)
                    5'd0:  pr_ctr <= {8'd0, n_reads};
                    5'd1: pr_ctr <= {8'd0, n_err0};
                    5'd2: pr_ctr <= {8'd0, n_err1};
                    5'd3: pr_ctr <= {8'd0, n_tmo};
                    5'd4: pr_ctr <= bad_addr;
                    5'd5: pr_ctr <= bad_data;
                    5'd6: pr_ctr <= {8'd0, n_win0};
                    5'd7: pr_ctr <= {8'd0, n_win1};
                    5'd8: pr_ctr <= {8'd0, f_wr};
                    5'd9: pr_ctr <= {8'd0, f_2x0};
                    5'd10: pr_ctr <= {8'd0, f_2x1};
                    5'd11: pr_ctr <= {8'd0, f_bad0};
                    5'd12: pr_ctr <= {8'd0, f_bad1};
                    5'd13: pr_ctr <= {8'd0, f_bad2x};
                    5'd14: pr_ctr <= {8'd0, f_dead};
                    5'd15: pr_ctr <= {16'd0, tr_bad_or};
                    5'd16: pr_ctr <= {16'd0, tr_ok_or};
                    default: pr_ctr <= {16'd0, tr_ok_and};
                endcase
                st <= S_PR_FETCH3;
            end
            S_PR_FETCH3: begin
                pr_val <= (pr_sel == 2'd0) ? h_q :
                          (pr_sel == 2'd1) ? {8'hA5, 6'd0, mode, period, round} : pr_ctr;
                pr_nib <= 4'd0;
                st     <= S_PR_NIB;
            end
            S_PR_NIB: if (!u_busy && !u_start) begin
                u_start <= 1'b1;
                u_data  <= hexc(pr_val[31:28]);
                pr_val  <= {pr_val[27:0], 4'h0};
                pr_nib  <= pr_nib + 4'd1;
                if (pr_nib == 4'd7) st <= S_PR_SEP;
            end
            S_PR_SEP: if (!u_busy && !u_start) begin
                u_start <= 1'b1;
                u_data  <= pr_eol ? 8'h0A : 8'h20;
                st      <= S_PR_ADV;
            end
            S_PR_ADV: begin
                if (pr_last) begin
                    // Next test: modes fastest-varying, then spacing, then refill
                    waddr <= 21'd0;
                    st    <= S_CLEAR;
                    if (mode == 2'd2) begin
                        mode <= 2'd0;
                        if (pidx == 2'd2) begin
                            pidx      <= 2'd0;
                            round     <= round + 8'd1;
                            seed      <= seed + 16'h9E37;
                            need_fill <= 1'b1;
                        end else begin
                            pidx <= pidx + 2'd1;
                        end
                    end else begin
                        mode <= mode + 2'd1;
                    end
                end else begin
                    pr_word <= pr_word + 7'd1;
                    st      <= S_PR_FETCH;
                end
            end

            default: st <= S_CLEAR;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // LEDs (active low): 0 heartbeat, 1 error seen, 2 filling, 3-4 mode
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) any_err <= 1'b0;
        else if (n_err0 != 24'd0 || n_err1 != 24'd0 || n_tmo != 24'd0) any_err <= 1'b1;
    end

    reg [26:0] hb;
    always @(posedge clk) hb <= hb + 27'd1;
    assign led[0] = ~hb[26];
    assign led[1] = ~any_err;
    assign led[2] = ~(st == S_FILL || st == S_FILL_W || st == S_FILL_INC);
    assign led[3] = ~mode[0];
    assign led[4] = ~mode[1];
    assign led[5] = 1'b1;

endmodule

`default_nettype wire
