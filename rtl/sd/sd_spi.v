// ============================================================================
// sd_spi -- SD card in SPI mode: initialise, read and write single 512-byte blocks.
//
//   init : CMD0, CMD8, ACMD41 (HCS) until ready, CMD58 (CCS), CMD16 for
//          byte-addressed cards; at <= 400 kHz. Then the clock goes fast.
//   rd   : CMD17 at `lba` (a block number; scaled here for byte-addressed
//          cards), wait for the data token, hand over 512 bytes (bv/bd),
//          drop the CRC.
//   wr   : CMD24 at `lba`; the 512 bytes are asked for one at a time (wreq,
//          answered with wv/wd whenever the producer has the byte -- the
//          clock stops meanwhile); then the card's data response and its
//          busy time. Used for the High Score Cart's 2K of RAM only.
//
// SPI mode 0. SCK only runs while a byte is exchanged, so the consumer can
// hold the stream between data bytes with `stall` (sampled before each data
// byte; a byte already under way still arrives).
//
// err (sticky until the next init / rd):
//   0 ok            1 no answer to CMD0     2 CMD8 echo wrong
//   3 ACMD41 never became ready             4 CMD58 failed
//   5 CMD16 failed  6 CMD17 refused (R1)    7 no data token
//   8 not initialised    9 CMD24 refused (R1)
//   10 write: data not accepted            11 write: card stayed busy
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

module sd_spi #(
    parameter FREQ      = 67_500_000,
    parameter SLOW_HALF = FREQ / 700_000,     // half SCK period in clocks: ~350 kHz
    parameter FAST_HALF = 4,                  // 67.5 MHz / 8 = 8.4 MHz
    parameter BOOT_CLKS = FREQ / 20,          // 50 ms after reset / before an init
    parameter ACMD_TRIES = 8000,              // ~0.5 ms each when slow
    parameter TOKEN_BYTES = 400_000           // ~1 us each when fast
) (
    input  wire        clk,
    input  wire        rst_n,

    output reg         sd_cs,
    output reg         sd_sck,
    output reg         sd_mosi,
    input  wire        sd_miso,

    input  wire        init,         // 1-cycle: (re)initialise the card
    input  wire        rd,           // 1-cycle: read block `lba` (ignored while busy)
    input  wire [31:0] lba,
    input  wire        wr,           // 1-cycle: write block `lba` (ignored while busy)
    output reg         wreq,         // 1-cycle: the next byte to write, please
    input  wire        wv,           // 1-cycle: here it is
    input  wire [7:0]  wd,
    input  wire        stall,        // hold before the next data byte
    output reg         bv,           // 1-cycle: data byte
    output reg  [7:0]  bd,
    output reg         busy,
    output reg         ready,        // initialised
    output reg         hc,           // block-addressed card (SDHC/SDXC)
    output reg  [3:0]  err,
    output wire [7:0]  dbg_r1        // last R1 (diagnostics)
);
    // ------------------------------------------------------------------
    // Byte exchange
    // ------------------------------------------------------------------
    reg        fast;
    reg        x_go;
    reg  [7:0] x_tx;
    reg        x_busy, x_done, x_ph;
    reg  [7:0] sh_tx, sh_rx;
    reg  [2:0] bitc;
    reg  [15:0] divc;
    reg        miso_s;
    wire [15:0] half = fast ? FAST_HALF[15:0] - 16'd1 : SLOW_HALF[15:0] - 16'd1;

    always @(posedge clk) miso_s <= sd_miso;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sd_sck <= 1'b0; sd_mosi <= 1'b1; x_busy <= 1'b0; x_done <= 1'b0; x_ph <= 1'b0;
            sh_tx <= 8'hFF; sh_rx <= 8'hFF; bitc <= 3'd0; divc <= 16'd0;
        end else begin
            x_done <= 1'b0;
            if (x_go && !x_busy) begin
                sh_tx   <= x_tx;
                sd_mosi <= x_tx[7];
                bitc    <= 3'd0;
                x_ph    <= 1'b0;
                divc    <= half;
                x_busy  <= 1'b1;
            end else if (x_busy) begin
                if (divc != 16'd0) divc <= divc - 16'd1;
                else begin
                    divc <= half;
                    if (!x_ph) begin
                        sd_sck <= 1'b1;
                        sh_rx  <= {sh_rx[6:0], miso_s};
                        x_ph   <= 1'b1;
                    end else begin
                        sd_sck <= 1'b0;
                        x_ph   <= 1'b0;
                        bitc   <= bitc + 3'd1;
                        if (bitc == 3'd7) begin
                            x_busy  <= 1'b0;
                            x_done  <= 1'b1;
                            sd_mosi <= 1'b1;
                        end else begin
                            sh_tx   <= {sh_tx[6:0], 1'b1};
                            sd_mosi <= sh_tx[6];
                        end
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    localparam [5:0]
        S_C24  = 6'd32, S_R24  = 6'd33, S_WTOK = 6'd34, S_WTOKW = 6'd35, S_WASK = 6'd36, S_WGET = 6'd37,
        S_WDW  = 6'd38, S_WRSP = 6'd39, S_WRSPW = 6'd40, S_WBSY = 6'd41, S_WBSYW = 6'd42;
    localparam [5:0]
        S_IDLE = 6'd0,  S_BOOT = 6'd1,  S_WAKE = 6'd2,  S_CMD0 = 6'd3,  S_R0   = 6'd4,
        S_CMD8 = 6'd5,  S_R8   = 6'd6,  S_C55  = 6'd7,  S_C41  = 6'd8,  S_R41  = 6'd9,
        S_C58  = 6'd10, S_R58  = 6'd11, S_C16  = 6'd12, S_R16  = 6'd13, S_C17  = 6'd14,
        S_R17  = 6'd15, S_TOK  = 6'd16, S_TOKW = 6'd17, S_DATA = 6'd18, S_DATW = 6'd19,
        S_GAP  = 6'd20, S_END  = 6'd21, S_ENDW = 6'd22,
        // command subroutine
        K_PRE  = 6'd24, K_PREW = 6'd25, K_SEL = 6'd26, K_SELW = 6'd27, K_TX = 6'd28,
        K_TXW  = 6'd29, K_R1   = 6'd30, K_R1W = 6'd31;

    reg [5:0]  st, ret;
    reg [5:0]  k_cmd;
    reg [31:0] k_arg;
    reg [7:0]  k_crc;
    reg [2:0]  k_i;
    reg [2:0]  k_extra;          // response bytes after R1 (0 or 4)
    reg [4:0]  k_poll;
    reg [7:0]  r1;
    reg [31:0] resp;
    reg [25:0] cnt;
    reg [18:0] tok_cnt;
    reg [13:0] tries;
    reg [9:0]  nbytes;
    reg        v2;               // answered CMD8
    reg [1:0]  gap;
    reg [31:0] lba_l;
    reg [3:0]  cmd0_tries;
    assign dbg_r1 = r1;

    wire [7:0] k_byte = (k_i == 3'd0) ? {2'b01, k_cmd} :
                        (k_i == 3'd1) ? k_arg[31:24] :
                        (k_i == 3'd2) ? k_arg[23:16] :
                        (k_i == 3'd3) ? k_arg[15:8]  :
                        (k_i == 3'd4) ? k_arg[7:0]   : k_crc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; ret <= S_IDLE; sd_cs <= 1'b1; fast <= 1'b0; x_go <= 1'b0; x_tx <= 8'hFF;
            k_cmd <= 6'd0; k_arg <= 32'd0; k_crc <= 8'd1; k_i <= 3'd0; k_extra <= 3'd0; k_poll <= 5'd0;
            r1 <= 8'hFF; resp <= 32'd0; cnt <= 26'd0; tok_cnt <= 19'd0; tries <= 14'd0; nbytes <= 10'd0;
            v2 <= 1'b0; gap <= 2'd0; lba_l <= 32'd0; cmd0_tries <= 4'd0;
            bv <= 1'b0; bd <= 8'd0; busy <= 1'b0; ready <= 1'b0; hc <= 1'b0; err <= 4'd8;
            wreq <= 1'b0;
        end else begin
            x_go <= 1'b0;
            bv   <= 1'b0;
            wreq <= 1'b0;
            case (st)
            S_IDLE: begin
                busy <= 1'b0;
                if (init) begin
                    busy <= 1'b1; ready <= 1'b0; err <= 4'd0; fast <= 1'b0; sd_cs <= 1'b1;
                    cnt <= BOOT_CLKS[25:0]; cmd0_tries <= 4'd0;
                    st  <= S_BOOT;
                end else if (rd) begin
                    busy <= 1'b1;
                    if (!ready) err <= 4'd8;
                    else begin
                        err   <= 4'd0;
                        lba_l <= lba;
                        st    <= S_C17;
                    end
                end else if (wr) begin
                    busy <= 1'b1;
                    if (!ready) err <= 4'd8;
                    else begin
                        err   <= 4'd0;
                        lba_l <= lba;
                        st    <= S_C24;
                    end
                end
            end

            // ---- write block ----
            S_C24: begin
                k_cmd <= 6'd24; k_arg <= hc ? lba_l : {lba_l[22:0], 9'd0}; k_crc <= 8'h01; k_extra <= 3'd0;
                ret <= S_R24; st <= K_PRE;
            end
            S_R24: begin
                if (r1 != 8'h00) begin err <= 4'd9; st <= S_END; end
                else begin nbytes <= 10'd0; st <= S_WTOK; end
            end
            // one byte of clocks, then the data token
            S_WTOK: if (!x_busy && !x_go) begin x_tx <= 8'hFF; x_go <= 1'b1; st <= S_WTOKW; end
            S_WTOKW: if (x_done) begin x_tx <= 8'hFE; x_go <= 1'b1; st <= S_WDW; end
            S_WASK: begin wreq <= 1'b1; st <= S_WGET; end
            S_WGET: if (wv) begin x_tx <= wd; x_go <= 1'b1; st <= S_WDW; end
            S_WDW: if (x_done) begin
                // nbytes counts what follows the token: 512 data bytes, 2 CRC bytes (not checked in SPI mode)
                nbytes <= nbytes + 10'd1;
                if (nbytes < 10'd512) st <= S_WASK;
                else if (nbytes < 10'd514) begin x_tx <= 8'hFF; x_go <= 1'b1; end
                else begin tok_cnt <= 19'd0; st <= S_WRSP; end
            end
            // data response: xxx0_0101 = accepted
            S_WRSP: if (!x_busy && !x_go) begin x_tx <= 8'hFF; x_go <= 1'b1; st <= S_WRSPW; end
            S_WRSPW: if (x_done) begin
                if (sh_rx[4:0] == 5'b00101) begin tok_cnt <= 19'd0; st <= S_WBSY; end
                else if (sh_rx != 8'hFF || tok_cnt == 19'd15) begin err <= 4'd10; st <= S_END; end
                else begin tok_cnt <= tok_cnt + 19'd1; st <= S_WRSP; end
            end
            // the card holds MISO low while it programs
            S_WBSY: if (!x_busy && !x_go) begin x_tx <= 8'hFF; x_go <= 1'b1; st <= S_WBSYW; end
            S_WBSYW: if (x_done) begin
                if (sh_rx == 8'hFF) st <= S_END;
                else if (tok_cnt == TOKEN_BYTES[18:0]) begin err <= 4'd11; st <= S_END; end
                else begin tok_cnt <= tok_cnt + 19'd1; st <= S_WBSY; end
            end

            // ---- init ----
            S_BOOT: if (cnt != 26'd0) cnt <= cnt - 26'd1;
                    else begin nbytes <= 10'd12; st <= S_WAKE; end       // 96 clocks, CS high
            S_WAKE: if (!x_busy && !x_go) begin
                if (nbytes == 10'd0) st <= S_CMD0;
                else begin x_tx <= 8'hFF; x_go <= 1'b1; nbytes <= nbytes - 10'd1; end
            end
            S_CMD0: begin
                k_cmd <= 6'd0; k_arg <= 32'd0; k_crc <= 8'h95; k_extra <= 3'd0;
                ret <= S_R0; st <= K_PRE;
            end
            S_R0: begin
                if (r1 == 8'h01) st <= S_CMD8;
                else if (cmd0_tries == 4'd15) begin err <= 4'd1; st <= S_END; end
                else begin cmd0_tries <= cmd0_tries + 4'd1; sd_cs <= 1'b1; nbytes <= 10'd12; st <= S_WAKE; end
            end
            S_CMD8: begin
                k_cmd <= 6'd8; k_arg <= 32'h0000_01AA; k_crc <= 8'h87; k_extra <= 3'd4;
                ret <= S_R8; st <= K_PRE;
            end
            S_R8: begin
                tries <= 14'd0;
                if (r1[2]) begin v2 <= 1'b0; st <= S_C55; end            // illegal command: v1 card
                else if (resp[11:0] != 12'h1AA) begin err <= 4'd2; st <= S_END; end
                else begin v2 <= 1'b1; st <= S_C55; end
            end
            S_C55: begin
                k_cmd <= 6'd55; k_arg <= 32'd0; k_crc <= 8'h65; k_extra <= 3'd0;
                ret <= S_C41; st <= K_PRE;
            end
            S_C41: begin
                k_cmd <= 6'd41; k_arg <= {1'b0, v2, 30'd0}; k_crc <= v2 ? 8'h77 : 8'hE5; k_extra <= 3'd0;
                ret <= S_R41; st <= K_PRE;
            end
            S_R41: begin
                if (r1 == 8'h00) st <= S_C58;
                else if (tries == ACMD_TRIES[13:0]) begin err <= 4'd3; st <= S_END; end
                else begin tries <= tries + 14'd1; st <= S_C55; end
            end
            S_C58: begin
                k_cmd <= 6'd58; k_arg <= 32'd0; k_crc <= 8'hFD; k_extra <= 3'd4;
                ret <= S_R58; st <= K_PRE;
            end
            S_R58: begin
                if (r1 != 8'h00) begin err <= 4'd4; st <= S_END; end
                else begin
                    hc <= resp[30];
                    if (resp[30]) begin ready <= 1'b1; fast <= 1'b1; st <= S_END; end
                    else st <= S_C16;
                end
            end
            S_C16: begin
                k_cmd <= 6'd16; k_arg <= 32'd512; k_crc <= 8'h15; k_extra <= 3'd0;
                ret <= S_R16; st <= K_PRE;
            end
            S_R16: begin
                if (r1 != 8'h00) err <= 4'd5;
                else begin ready <= 1'b1; fast <= 1'b1; end
                st <= S_END;
            end

            // ---- read block ----
            S_C17: begin
                k_cmd <= 6'd17; k_arg <= hc ? lba_l : {lba_l[22:0], 9'd0}; k_crc <= 8'h01; k_extra <= 3'd0;
                ret <= S_R17; st <= K_PRE;
            end
            S_R17: begin
                if (r1 != 8'h00) begin err <= 4'd6; st <= S_END; end
                else begin tok_cnt <= 19'd0; st <= S_TOK; end
            end
            S_TOK: if (!x_busy && !x_go) begin x_tx <= 8'hFF; x_go <= 1'b1; st <= S_TOKW; end
            S_TOKW: if (x_done) begin
                if (sh_rx == 8'hFE) begin nbytes <= 10'd0; gap <= 2'd0; st <= S_GAP; end
                else if (sh_rx != 8'hFF || tok_cnt == TOKEN_BYTES[18:0]) begin err <= 4'd7; st <= S_END; end
                else begin tok_cnt <= tok_cnt + 19'd1; st <= S_TOK; end
            end
            // a few clocks for the consumer to raise `stall` after a byte (its
            // state changes one clock after bv, and stall is registered)
            S_GAP: begin
                gap <= gap + 2'd1;
                if (gap == 2'd3) st <= S_DATA;
            end
            S_DATA: if (!stall || nbytes >= 10'd512) begin
                x_tx <= 8'hFF; x_go <= 1'b1; st <= S_DATW;
            end
            S_DATW: if (x_done) begin
                nbytes <= nbytes + 10'd1;
                if (nbytes < 10'd512) begin bv <= 1'b1; bd <= sh_rx; end
                if (nbytes == 10'd513) st <= S_END;                       // 512 data + 2 CRC
                else begin gap <= 2'd0; st <= S_GAP; end
            end

            // ---- deselect, one more byte of clocks ----
            S_END: if (!x_busy && !x_go) begin
                sd_cs <= 1'b1; x_tx <= 8'hFF; x_go <= 1'b1; st <= S_ENDW;
            end
            S_ENDW: if (x_done) st <= S_IDLE;

            // ---- command: [FF, CS high] [FF, CS low] cmd arg crc, poll R1, extra bytes ----
            K_PRE:  if (!x_busy && !x_go) begin sd_cs <= 1'b1; x_tx <= 8'hFF; x_go <= 1'b1; st <= K_PREW; end
            K_PREW: if (x_done) st <= K_SEL;
            K_SEL:  begin sd_cs <= 1'b0; x_tx <= 8'hFF; x_go <= 1'b1; st <= K_SELW; end
            K_SELW: if (x_done) begin k_i <= 3'd0; st <= K_TX; end
            K_TX:   begin x_tx <= k_byte; x_go <= 1'b1; st <= K_TXW; end
            K_TXW:  if (x_done) begin
                if (k_i == 3'd5) begin k_poll <= 5'd0; r1 <= 8'hFF; st <= K_R1; end
                else begin k_i <= k_i + 3'd1; st <= K_TX; end
            end
            K_R1:   begin x_tx <= 8'hFF; x_go <= 1'b1; st <= K_R1W; end
            K_R1W:  if (x_done) begin
                if (r1[7]) begin                                   // still waiting for R1
                    if (!sh_rx[7]) begin
                        r1 <= sh_rx;
                        if (k_extra == 3'd0 || sh_rx[2]) st <= ret;
                        else st <= K_R1;
                    end else if (k_poll == 5'd31) st <= ret;       // r1 stays $FF
                    else begin k_poll <= k_poll + 5'd1; st <= K_R1; end
                end else begin                                     // extra response bytes
                    resp    <= {resp[23:0], sh_rx};
                    k_extra <= k_extra - 3'd1;
                    st      <= (k_extra == 3'd1) ? ret : K_R1;
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
