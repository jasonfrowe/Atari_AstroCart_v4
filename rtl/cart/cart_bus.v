// ============================================================================
// cart_bus -- Atari 7800 cartridge bus engine (single clock, ~81 MHz).
//
// Measured on the console (first devcart test, 2026-11-12): during DMA, MARIA
// moves to a new address every ~10-12 clocks (123-148 ns), one MARIA cycle.
// The PSRAM's 160 ns random read can never meet that, so the Atari only ever
// reads BRAM:
//
//   * The visible 48K window lives in three 16K BRAM slots:
//       slot 0 = $4000-$7FFF, slot 1 = $8000-$BFFF, slot 2 = $C000-$FFFF.
//     Each slot is stored as even/odd byte halves so the copy engine can
//     write a whole 16-bit PSRAM word per cycle.
//   * Read path = a fixed pipeline: pins -> a_s1 -> a_s2 -> BRAM -> data_q.
//     The data simply follows the address, 4 clocks behind (~50 ns); a
//     transient (skewed) address just produces a few ns of wrong data.
//   * PSRAM is the backing store: on a SuperGame bank switch this module
//     reports the new bank (bank_req); the copy engine (devcart_top) refills
//     slot 1 from PSRAM through the write port while it holds the 6502 halted.
//
// Writes from the 6502 are taken at the falling edge of PHI2, from a pipeline
// stage aligned with the PHI2 synchronizer. Writes are ignored in a cycle
// before which HALT was already low (MARIA DMA, or our own halt: the bus
// floats then).
//
// Instrumentation: address hold-time histograms and a 512-entry bus trace
// (every address / HALT / R/W change, with timestamps), read out over UART.
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

module cart_bus #(
    parameter MENU     = 0,
    parameter MENU_HEX = "menu"
) (
    input  wire        clk,
    input  wire        rst_n,

    // Atari pins (through the level shifters)
    input  wire [15:0] a_pin,
    input  wire [7:0]  d_pin_in,
    output wire [7:0]  d_pin_out,
    output wire [7:0]  d_pin_oe,     // per pin (one output-enable register per I/O block)
    output wire        buf_dir,      // U3 DIR: 1 = FPGA drives the Atari bus
    input  wire        phi2_pin,
    input  wire        rw_pin,
    input  wire        halt_pin,

    // Configuration (static while cart_en)
    input  wire        cart_en,
    input  wire [1:0]  win4000,      // $4000-$7FFF: 0 open bus, 1 ROM (slot 0), 2 RAM (slot 0), 3 drive $00
    input  wire        sg_en,        // SuperGame: writes to $8000-$BFFF select the $8000 bank
    input  wire [7:0]  bank_mask,    // (8 bits: up to 256 banks of 16K = 4 MB)
    input  wire [7:0]  bank_add,     // bank = (data & mask) + add  (1 for 9/17/33-bank carts)
    input  wire [2:0]  pokey_sel,    // 0 none, 1 $4000-$7FFF, 2 $0450-$045F, 3 $0800-$080F, 4 $0440-$044F,
                                     // 5 two: $0450-$045F and a second one at $0440-$044F (pk_alt / pk_ralt)
    input  wire        abs_en,       // Absolute (F-18 Hornet): a write to $8000 selects the bank at
                                     // $4000-$7FFF (bit 0: bank 0, else bit 1: bank 1); the switched
                                     // window is slot 0
    input  wire        mram,         // mirror RAM: the RAM at $4000 has no A8 (odd pages mirror even ones)
    // Activision (Double Dragon, Rampage): 8K pieces. With the slots holding
    // bank 6, the selected bank and bank 7 in their natural order:
    //   $4000 slot 0   $6000 slot 0   $8000 slot 2   $A000 slot 1   $C000 slot 1   $E000 slot 2
    // each from the half of the slot that hflip picks (hflip = 1: the half
    // opposite to A13, the "AM" dumps; 0: the "OM" dumps, whose banks are
    // stored with their halves exchanged). A write to $FF80-$FF87 selects the
    // bank at $A000-$DFFF.
    input  wire        act_en,
    input  wire        hflip,
    input  wire        our_halt,     // we are holding HALT low (ignore the floating bus)
    input  wire        menu_mode,    // the menu's registers answer at $0460-$046F
    // HALT-free bank switch: while the $8000 slot is being refilled (px_act)
    // the 6502's own reads there are answered straight from PSRAM (the new
    // bank, die 1). A 6502 cycle has ~500 ns for that; MARIA, who does not,
    // keeps reading the slot.
    input  wire        px_act,
    output reg         px_want,      // the 6502 is reading px_addr and has no byte for it yet
    output reg  [13:0] px_addr,
    output reg         px_hsc,       // ... in the High Score Cart's memory, not the switched bank
    input  wire        px_valid,     // 1-cycle: px_data is the word at px_tag
    input  wire [13:0] px_tag,
    input  wire        px_thsc,
    input  wire [15:0] px_data,
    // High Score Cart: 4K ROM at $3000-$3FFF and 2K RAM at $1000-$17FF, both
    // kept in PSRAM and read through the same path -- by the 6502 and by MARIA
    // (the ROM holds the font of its screens). px_addr is then the offset into
    // the HSC's PSRAM area: ROM at 0, RAM at $1000. Writes to the RAM go out
    // on hw_*. bg_ok marks a moment when the PSRAM die is not needed by the
    // bus for the rest of the cycle (for the pending writes and the save).
    input  wire        hsc_en,
    output reg         hw_we,
    output reg  [10:0] hw_addr,
    output reg  [7:0]  hw_data,
    output reg         bg_ok,        // (a level)
    input  wire        alt8000,      // $8000-$BFFF is served from slot 0 instead of slot 1 (second
                                     // bank buffer, for carts whose $4000 window is not ROM/RAM)

    // Math unit (rtl/math/astromath.v) at $0420-$043F: written and read like
    // the menu registers; mt_rd pulses at the end of each 6502 read cycle
    // there (the random generator steps on a read), register on mt_ra
    input  wire        math_en,
    output reg         mt_we,        // 1-cycle; address / data on pk_addr / pk_wdata
    output reg         mt_rd,
    output reg  [3:0]  mt_ra,
    output reg         mt_wa4,       // address bit 4 of the write (0 = $042x, 1 = $043x)
    output wire        mt_ra4,       // address bit 4 beside pk_raddr
    input  wire [7:0]  mt_rdata,     // register {mt_ra4, pk_raddr}
    // Menu registers (devcart_top): written like POKEY, read through the POKEY path
    output reg         rg_we,        // 1-cycle; address / data on pk_addr / pk_wdata
    input  wire [7:0]  rg_rdata,     // register pk_raddr

    // Byte writes into slot 0 (the SD sector buffer at $4000); at most every second clock
    input  wire        xw_we,
    input  wire [13:0] xw_addr,
    input  wire [7:0]  xw_data,

    // Bank switching -> copy engine
    output reg         bank_req,     // 1-cycle: the 6502 selected bank_new
    output reg  [7:0]  bank_new,

    // Slot write port (copy engine, whole words)
    input  wire        sw_act,       // a copy is running: the slot write port belongs to it
    input  wire        sw_we,
    input  wire [14:0] sw_word,      // {slot[1:0], word[12:0]}
    input  wire [15:0] sw_data,      // {odd byte, even byte}

    // POKEY
    output reg         pk_we,
    output reg  [3:0]  pk_addr,
    output reg  [7:0]  pk_wdata,
    output reg         pk_alt,       // the write is for the second POKEY
    output wire [3:0]  pk_raddr,
    output wire        pk_ralt,      // the read is from the second POKEY
    input  wire [7:0]  pk_rdata,
    output wire        phi2_rise,

    // Statistics / trace
    input  wire        st_clear,
    input  wire [2:0]  st_raddr,     // 0 bank writes, 1 POKEY writes, 2 writes ignored (HALT),
    output reg  [23:0] st_rdata,     // 3 PSRAM-served reads, 4 ... that never got their byte
    input  wire        dbg_sel,      // slot read-back (cart off): the BRAMs are addressed by dbg_addr
    input  wire [15:0] dbg_addr,
    output reg  [7:0]  dbg_data,
    input  wire        tr_arm,       // 1-cycle: arm the trace with tr_mode
    input  wire [1:0]  tr_mode,      // 0 now, 2 from the next bank-switch write
    input  wire [8:0]  tr_raddr,
    output reg  [35:0] tr_rdata,
    output wire [1:0]  tr_state      // 0 idle, 1 armed, 2 recording, 3 full
);
    // ------------------------------------------------------------------
    // Synchronizers
    // ------------------------------------------------------------------
    reg [15:0] a_s1, a_s2, a_s3;
    reg [7:0]  d_s1, d_s2, d_s3;
    reg        rw_s1, rw_s2, rw_s3;
    reg        phi2_s1, phi2_s2, phi2_s3;
    reg        halt_s1, halt_s2, halt_s3;
    always @(posedge clk) begin
        a_s1 <= a_pin;       a_s2 <= a_s1;       a_s3 <= a_s2;
        d_s1 <= d_pin_in;    d_s2 <= d_s1;       d_s3 <= d_s2;
        rw_s1 <= rw_pin;     rw_s2 <= rw_s1;     rw_s3 <= rw_s2;
        phi2_s1 <= phi2_pin; phi2_s2 <= phi2_s1; phi2_s3 <= phi2_s2;
        halt_s1 <= halt_pin; halt_s2 <= halt_s1; halt_s3 <= halt_s2;
    end
    reg [4:0] halt_run;          // clocks HALT (the pin, or our pull) has kept its value (saturating)
    reg       halt_was;
    reg       phi2_f, phi2_fd, rw_f;         // deglitched (see Writes)
    wire      wp_rise  = phi2_f && !phi2_fd;
    wire      wp_fall  = !phi2_f && phi2_fd;
    wire      halt_now = !halt_s3 || our_halt;
    assign phi2_rise = phi2_s2 && !phi2_s3;
    wire   phi2_fall = phi2_s3 && !phi2_s2;

    // ------------------------------------------------------------------
    // Decode
    // ------------------------------------------------------------------
    function is_pokey;
        input [15:0] ad;
        input [2:0]  sel;
        is_pokey = (sel == 3'd1) ? (ad[15:14] == 2'b01) :
                   (sel == 3'd2) ? (ad[15:4] == 12'h045) :
                   (sel == 3'd3) ? (ad[15:4] == 12'h080) :
                   (sel == 3'd4) ? (ad[15:4] == 12'h044) :
                   (sel == 3'd5) ? (ad[15:5] == 11'h022) : 1'b0;
    endfunction

    function is_reg;
        input [15:0] ad;
        is_reg = menu_mode && (ad[15:4] == 12'h046);
    endfunction

    reg hsc_q, math_q;           // (registered here: the configuration lives across the chip)
    always @(posedge clk) begin hsc_q <= hsc_en; math_q <= math_en; end
    function is_math;
        input [15:0] ad;
        is_math = math_q && (ad[15:5] == 11'h021);
    endfunction
    function in_hsc;
        input [15:0] ad;
        in_hsc = hsc_q && (ad[15:12] == 4'h3 || ad[15:11] == 5'b00010);
    endfunction

    function drives;
        input [15:0] ad;
        drives = is_pokey(ad, pokey_sel) || is_reg(ad) || is_math(ad) || ad[15] || (ad[14] && win4000 != 2'd0) || in_hsc(ad);
    endfunction

    // read source: 0 slot BRAM, 1 POKEY / menu registers, 2 zero
    function [1:0] src_of;
        input [15:0] ad;
        src_of = (is_pokey(ad, pokey_sel) || is_reg(ad) || is_math(ad)) ? 2'd1 :
                 (ad[15:14] == 2'b01 && win4000 == 2'd3) ? 2'd2 : 2'd0;
    endfunction

    // ------------------------------------------------------------------
    // Slot BRAM: 3 slots x (even, odd) 8K x 8 arrays = 24 BSRAM blocks.
    // (Power-of-two arrays: a single 24K-deep array gets rounded up to 32K.)
    // ------------------------------------------------------------------
    reg  [7:0] m0e [0:8191];
    reg  [7:0] m0o [0:8191];
    reg  [7:0] m1e [0:8191];
    reg  [7:0] m1o [0:8191];
    reg  [7:0] m2e [0:8191];
    reg  [7:0] m2o [0:8191];
    reg  [7:0] q0e, q0o, q1e, q1o, q2e, q2o;
    // The menu ROM (32K at $8000-$FFFF) is the power-up content of slots 1 and 2.
    generate if (MENU) begin : g_menu
        initial begin
            $readmemh({MENU_HEX, "_8e.hex"}, m1e);
            $readmemh({MENU_HEX, "_8o.hex"}, m1o);
            $readmemh({MENU_HEX, "_ce.hex"}, m2e);
            $readmemh({MENU_HEX, "_co.hex"}, m2o);
        end
    end endgenerate
    // Addressed straight from the input register at the pin (a_s1): a
    // metastable sample only costs that clock's data.
    wire [15:0] a_rd    = dbg_sel ? dbg_addr : a_s1;
    wire        flip    = hflip && !dbg_sel;
    wire [12:0] rd_word = {a_rd[13] ^ flip, a_rd[12:1]};
    // slot 0 as mirror RAM: A8 is not connected
    wire [12:0] rd_word0 = {a_rd[13] ^ flip, a_rd[12:9], a_rd[8] && !(mram && !dbg_sel), a_rd[7:1]};
    // which slot answers: the address's 16K window, or Activision's 8K pieces
    function [1:0] win_of;
        input [15:0] ad;
        input        act;
        win_of = !act ? ad[15:14] :
                 (ad[15:13] == 3'b100 || ad[15:13] == 3'b111) ? 2'b11 :
                 (ad[15:13] == 3'b101 || ad[15:13] == 3'b110) ? 2'b10 : ad[15:14];
    endfunction
    wire [1:0]  rd_win = win_of(a_rd, act_en && !dbg_sel);
    // the window a bank switch refills (and PSRAM answers for meanwhile)
    wire [1:0]  sw_win = abs_en ? 2'b01 : 2'b10;

    // 6502 writes to cart RAM ($4000 window when win4000 == 2) share the port
    // (and so do the SD sector buffer's byte writes). Address and data are
    // on the port one clock before the write enable, as for the copy engine.
    // The two writers queue here (one entry each: 6502 writes are >= 37
    // clocks apart, SD bytes >= 60), so neither can lose a write to the other.
    reg        ram_we, ram_pre;
    reg [13:0] ram_wa;
    reg [7:0]  ram_wd;
    reg        cw_pend, xw_pend;
    reg [13:0] cw_a, xw_a;
    reg [7:0]  cw_d, xw_d;
    // the copy engine sits across the chip: its port gets a register stage
    // While a copy runs (sw_act) the write address/data stay on the copy's
    // word between its writes: the BSRAM address must not change in a write
    // cycle's neighbourhood (see the copy engine).
    reg         sw_we_q, sw_act_q;
    reg  [14:0] sw_word_q;
    reg  [15:0] sw_data_q;
    always @(posedge clk) begin
        sw_act_q  <= sw_act;
        sw_we_q   <= sw_we;
        sw_word_q <= sw_word;
        sw_data_q <= sw_data;
    end
    // Slot 0 has its own write address / data nets: it is the cart's RAM, and
    // with HALT-free bank switches the 6502 writes it while the copy engine
    // is refilling slot 1 (build 4a dropped those writes: the copy owned the
    // one shared port -- ARTI's and Impossible Mission's level data). The copy
    // only takes slot 0's port when slot 0 is its target.
    wire        s0_copy = sw_act_q && (sw_word_q[14:13] == 2'd0);
    wire [12:0] w0_word = s0_copy ? sw_word_q[12:0]  : ram_wa[13:1];
    wire        w0_we_e = s0_copy ? sw_we_q          : (ram_we && !ram_wa[0]);
    wire        w0_we_o = s0_copy ? sw_we_q          : (ram_we &&  ram_wa[0]);
    wire [7:0]  w0_d_e  = s0_copy ? sw_data_q[7:0]   : ram_wd;
    wire [7:0]  w0_d_o  = s0_copy ? sw_data_q[15:8]  : ram_wd;
    wire        w1_we   = sw_act_q && sw_we_q && (sw_word_q[14:13] == 2'd1);
    wire        w2_we   = sw_act_q && sw_we_q && (sw_word_q[14:13] == 2'd2);


    always @(posedge clk) begin
        q0e <= m0e[rd_word0]; q0o <= m0o[rd_word0];
        q1e <= m1e[rd_word]; q1o <= m1o[rd_word];
        q2e <= m2e[rd_word]; q2o <= m2o[rd_word];
        if (w0_we_e) m0e[w0_word] <= w0_d_e;
        if (w0_we_o) m0o[w0_word] <= w0_d_o;
        if (w1_we) m1e[sw_word_q[12:0]] <= sw_data_q[7:0];
        if (w1_we) m1o[sw_word_q[12:0]] <= sw_data_q[15:8];
        if (w2_we) m2e[sw_word_q[12:0]] <= sw_data_q[7:0];
        if (w2_we) m2o[sw_word_q[12:0]] <= sw_data_q[15:8];
    end

    // ------------------------------------------------------------------
    // Read pipeline and bus drive -- short and repeatable (MARIA holds ~10%
    // of its DMA addresses only 60-180 ns):
    //   edge 1  a_s1   <- pins          (input register in the I/O block)
    //   edge 2  BRAM   <- a_s1; sel/drive decode(a_s1)
    //   edge 3  fabric register after the BRAMs (they are spread over the chip)
    //   edge 4  data / output enable    (output registers in the I/O blocks)
    // Data follows the address 4 clocks (59 ns) behind, with no build-to-build
    // variation at the pins. The output enable only changes when the two
    // newest samples agree: a one-sample spike neither starts nor stops our
    // drive (no driving during a console-RAM read, no floating bus during
    // one of ours).
    // ------------------------------------------------------------------
    reg [7:0] data_q  /* synthesis syn_preserve = 1 */;   // feeds the pads only
    reg [7:0] oe_q    /* synthesis syn_preserve = 1 */;   // one per pad
    reg       dir_q   /* synthesis syn_preserve = 1 */;   // U3 DIR pin
    reg       drive_q;                                    // for internal use
    reg       drive_pre, drive_pre2;
    // Address glitch filter (crash recorder, build 2g: A0 flickering
    // $F02E/$F02F for ~40 clocks made the 6502 read a BPL operand from the
    // wrong address -> BRK -> 7800basic's yellow crash screen). The data
    // register only takes a value read for an address that the two newest
    // samples agreed on; a one-sample spike never reaches the pins.
    reg       st2, st3;          // a_s1 == a_s2 at edge 2, piped to edge 4
    reg [7:0] sel, sel_r;        // one-hot: {pokey, zero, s2o, s2e, s1o, s1e, s0o, s0e}
    reg [7:0] r0e, r0o, r1e, r1o, r2e, r2o, pk_r;
    wire [1:0] src1 = src_of(a_rd);
    reg        alt_q;            // (registered here; never set while the slots are dumped)
    always @(posedge clk) alt_q <= alt8000 && !dbg_sel;

    // ---- the 6502's reads of $8000-$BFFF during a refill ----
    // A cycle is the 6502's unless HALT has been low for a while: MARIA drops
    // HALT at the start of the 6502's last cycle, which still needs its data.
    // cpu_cyc is decided further down (it needs the filtered PHI2 edge).
    reg       cpu_cyc;
    reg       selp, selp_r;      // this address is answered from PSRAM (pipelined like sel)
    reg [7:0] px_byte;
    reg [14:0] px_cur;           // {HSC, offset}
    wire       h1 = in_hsc(a_s1);
    // {HSC, offset} of the address in a_s2, worked out a clock ahead (from a_s1)
    reg  [14:0] tag2;
    wire [13:0] hoff1 = a_s1[13] ? {2'b00, a_s1[11:0]} : {3'b010, a_s1[10:0]};
    always @(posedge clk) tag2 <= h1 ? {1'b1, hoff1} : {1'b0, a_s1[13] ^ hflip, a_s1[12:0]};
    wire       h2 = tag2[14];
    wire       sw2   = px_act && (win_of(a_s2, act_en) == sw_win);       // in the window being refilled
    reg [6:0]  bg_age;           // clocks since the cycle began
    reg [6:0]  bg_idle;
    reg       px_have, px_hit;
    reg [5:0] px_age;
    reg       px_seen;
    reg [23:0] c_px_reads, c_px_miss;    // PSRAM-served 6502 reads; ... that never got their byte
    reg        px_cnt, px_cntm;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            selp <= 1'b0; selp_r <= 1'b0; px_want <= 1'b0; px_addr <= 14'd0; px_hsc <= 1'b0;
            px_byte <= 8'd0; px_cur <= 15'd0; px_have <= 1'b0; px_hit <= 1'b0;
            bg_ok <= 1'b0; bg_age <= 7'd0; bg_idle <= 7'd0;
            px_age <= 6'd0; px_seen <= 1'b0; px_cnt <= 1'b0; px_cntm <= 1'b0;
            c_px_reads <= 24'd0; c_px_miss <= 24'd0;
        end else begin
            selp    <= cart_en && ((px_act && (win_of(a_s1, act_en) == sw_win) && cpu_cyc) || h1);
            selp_r  <= selp;
            px_hit  <= px_have && (px_cur == tag2);
            px_addr <= tag2[13:0];
            px_hsc  <= h2;
            px_want <= cart_en && rw_s2 && (a_s1 == a_s2) && ((sw2 && cpu_cyc) || h2) &&
                       !(px_have && px_cur == tag2);
            // Background PSRAM work may start early in a 6502 cycle that does
            // not read PSRAM itself (another address, or a write: R/W low for
            // three samples) -- it is done before the next cycle wants a byte
            // -- or when the bus has been idle for a while. A cycle starts at
            // PHI2's fall (seen here ~5 clocks late); the address may be the
            // same as in the cycle before (STA abs,X: a read, then the write).
            // That includes the 6502's last cycle before DMA (HALT already low):
            // MARIA starts with display-list bytes from the console's RAM.
            // Idle: no PHI2 edge for 100 clocks with HALT high all the while
            // (after DMA the 6502 is back 32 clocks after HALT rises).
            if (wp_fall)                 bg_age <= 7'd0;
            else if (bg_age != 7'd127)   bg_age <= bg_age + 7'd1;
            if (wp_fall || halt_now || bg_idle == 7'd100) bg_idle <= 7'd0;
            else                         bg_idle <= bg_idle + 7'd1;
            // (a level: from ~8 to ~24 clocks into such a cycle -- two queued
            // writes fit, one after the other)
            bg_ok <= cart_en && (a_s1 == a_s2) && (a_s2 == a_s3) &&
                     ((bg_age >= 7'd2 && bg_age <= 7'd18 && cpu_cyc && (!(sw2 || h2) || (!rw_s1 && !rw_s2 && !rw_s3))) ||
                      bg_idle == 7'd100);
            // ---- measurement: did the byte make it? ----
            // px_age: clocks this address has been on the bus. When it leaves
            // (after a full-length stay as a PSRAM-served read), count it, and
            // count a miss if no byte ever reached the bus for it.
            // (counted a clock later: the address compare is a long path)
            px_cnt  <= (a_s1 != a_s2) && selp_r && rw_s2 && (px_age >= 6'd28);
            px_cntm <= !px_seen;
            if (px_cnt) begin
                c_px_reads <= c_px_reads + 24'd1;
                if (px_cntm) c_px_miss <= c_px_miss + 24'd1;
            end
            if (a_s1 != a_s2) begin
                px_age <= 6'd0;
                px_seen <= 1'b0;
            end else begin
                if (px_age != 6'd63) px_age <= px_age + 6'd1;
                if (selp_r && px_hit) px_seen <= 1'b1;
            end
            if (st_clear) begin
                c_px_reads <= 24'd0; c_px_miss <= 24'd0;
            end
            if (bank_req || hw_we) px_have <= 1'b0;       // (a new bank, new RAM contents: forget the byte in hand)
            else if (px_valid && {px_thsc, px_tag} == tag2 && (px_thsc || px_act)) begin
                px_byte <= px_tag[0] ? px_data[15:8] : px_data[7:0];
                px_cur  <= {px_thsc, px_tag};
                px_have <= 1'b1;
            end else if (!px_act && !px_cur[14]) px_have <= 1'b0;
        end
    end
    wire      d1 = cart_en && rw_s1 && drives(a_s1);
    wire      d2 = cart_en && rw_s2 && drives(a_s2);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drive_q <= 1'b0; oe_q <= 8'h00; dir_q <= 1'b0; sel <= 8'd0; sel_r <= 8'd0;
            drive_pre <= 1'b0; drive_pre2 <= 1'b0; st2 <= 1'b0; st3 <= 1'b0;
        end else begin
            st2 <= (a_s1 == a_s2) && (rw_s1 == rw_s2);
            st3 <= st2;
            if (d1 == d2) drive_pre <= d1;        // edge 2
            drive_pre2 <= drive_pre;              // edge 3
            drive_q    <= drive_pre2;             // edge 4, with the data
            oe_q       <= {8{drive_pre2}};
            dir_q      <= drive_pre2;
            sel[7] <= (src1 == 2'd1);
            sel[6] <= (src1 == 2'd2);
            sel[5] <= (src1 == 2'd0) && (rd_win == 2'b11) && a_rd[0];
            sel[4] <= (src1 == 2'd0) && (rd_win == 2'b11) && !a_rd[0];
            sel[3] <= (src1 == 2'd0) && (rd_win == 2'b10) && !alt_q && a_rd[0];
            sel[2] <= (src1 == 2'd0) && (rd_win == 2'b10) && !alt_q && !a_rd[0];
            sel[1] <= (src1 == 2'd0) && ((rd_win == 2'b01) || (rd_win == 2'b10 && alt_q)) && a_rd[0];
            sel[0] <= (src1 == 2'd0) && ((rd_win == 2'b01) || (rd_win == 2'b10 && alt_q)) && !a_rd[0];
            sel_r  <= sel;
        end
    end
    always @(posedge clk) begin
        r0e <= q0e; r0o <= q0o; r1e <= q1e; r1o <= q1o; r2e <= q2e; r2o <= q2o;
        pk_r <= is_reg(a_s2) ? rg_rdata : is_math(a_s2) ? mt_rdata : pk_rdata;   // pk_raddr = a_s2: the address read at edge 2
        dbg_data <= ({8{sel_r[5]}} & r2o) | ({8{sel_r[4]}} & r2e) |
                    ({8{sel_r[3]}} & r1o) | ({8{sel_r[2]}} & r1e) |
                    ({8{sel_r[1]}} & r0o) | ({8{sel_r[0]}} & r0e);
        if (selp_r) begin
            if (px_hit) data_q <= px_byte;
        end else if (st3)
        data_q <= ({8{sel_r[7]}} & pk_r) |
                  ({8{sel_r[5]}} & r2o) | ({8{sel_r[4]}} & r2e) |
                  ({8{sel_r[3]}} & r1o) | ({8{sel_r[2]}} & r1e) |
                  ({8{sel_r[1]}} & r0o) | ({8{sel_r[0]}} & r0e);
    end
    assign pk_raddr  = a_s2[3:0];
    assign mt_ra4    = a_s2[4];
    assign pk_ralt   = (pokey_sel == 3'd5) && !a_s2[4];
    assign d_pin_out = data_q;
    assign d_pin_oe  = oe_q;
    assign buf_dir   = dir_q;

    // ------------------------------------------------------------------
    // Writes (falling edge of PHI2; not in a cycle where HALT was low)
    //
    // The write strobe is deglitched: the PHI2 and R/W used here only change
    // after 3 agreeing samples (~44 ns). The console's bus is noisy, and the
    // write log of build 2b caught read cycles taken as writes ($892B <- $26
    // switched to bank 7). The filtered PHI2 fall is seen 2 clocks after the
    // raw one, so address and data are taken 2 clocks back (a_s5/d_s5): the
    // same bus instant build 2 used.
    // ------------------------------------------------------------------
    //
    // Build 3d: address and data are taken 4 clocks (59 ns) earlier still
    // (a_w/d_w). The old point was the pin sample at the PHI2 fall itself, and
    // PHI2 comes through the slower 1.8 V shifter: on the console, bytes the
    // menu wrote to cart RAM arrived with flipped bits ($7E -> $5E, $00 -> $08)
    // -- sampled as the 6502 let go of the bus. Bank and POKEY writes had the
    // same sample point; nothing ever read those bytes back.
    reg [15:0] a_s4, a_s5, a_s6, a_s7, a_s8, a_w;
    reg [7:0]  d_s4, d_s5, d_s6, d_s7, d_s8, d_w;
    always @(posedge clk) begin
        a_s4 <= a_s3; a_s5 <= a_s4; a_s6 <= a_s5; a_s7 <= a_s6; a_s8 <= a_s7; a_w <= a_s8;
        d_s4 <= d_s3; d_s5 <= d_s4; d_s6 <= d_s5; d_s7 <= d_s6; d_s8 <= d_s7; d_w <= d_s8;
        if (phi2_s1 == phi2_s2 && phi2_s2 == phi2_s3) phi2_f <= phi2_s3;
        if (rw_s1 == rw_s2 && rw_s2 == rw_s3)         rw_f   <= rw_s3;
        phi2_fd <= phi2_f;
    end

    reg cart_en_d;
    reg halted_cycle;
    always @(posedge clk) cart_en_d <= cart_en;
    // Which cycles are the 6502's own? MARIA drops HALT at the START of the
    // 6502's last cycle, and the 6502 still completes that cycle (console
    // capture build2h_hsdll_03: the final write of an INC, HALT already low).
    // After it the bus is MARIA's, with R/W still low for a while if that last
    // cycle was a write. So a cycle counts as halted if HALT was low already
    // *before the cycle began*. That is judged when the cycle's PHI2 rises,
    // from the HALT state HALT_BACK clocks earlier: PHI2 rises about 19 clocks
    // into a cycle and the filtered rise is seen ~5 clocks late, so 30 clocks
    // back is ~6 clocks (90 ns) before the cycle boundary. (Not judged at the
    // PHI2 fall before the cycle: that needs PHI2 to keep running through DMA.)
    // After DMA the 6502's first cycle begins ~32 clocks after HALT rises.
    //   up to 3b: halted if HALT was low at any time in the cycle  -> lost the
    //             last write before every DMA (about 1% of the menu's writes
    //             to cart RAM; build 3d's RAM test: 36 of 4096 never written)
    //   3c / 3d:  halted if HALT was low at the PHI2 rise          -> the same
    // "HALT was low HALT_BACK clocks ago", from two saturating counters: if
    // HALT is low now, it was low then if it has been low that long; if it is
    // high now, it was low then unless it has been high that long. (Exact for
    // HALT pulses and gaps longer than HALT_BACK; DMA is never shorter.)
    localparam [4:0] HALT_BACK = 5'd27;          // + 3 clocks of synchronizer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            halted_cycle <= 1'b0; halt_run <= 5'd31; halt_was <= 1'b0;
        end else begin
            halt_was <= halt_now;
            if (halt_now != halt_was)   halt_run <= 5'd1;
            else if (halt_run != 5'd31) halt_run <= halt_run + 5'd1;
            if (wp_rise) halted_cycle <= (halt_run >= HALT_BACK) ? halt_was : !halt_was;
        end
    end
    // Whose cycle is it (for reads served from PSRAM during a refill)? The
    // bus stops being the 6502's at the first cycle boundary -- filtered PHI2
    // fall -- at which HALT has been low for 10 clocks: that is the end of the
    // 6502's last cycle (HALT fell at its start). It is the 6502's again when
    // an address appears after HALT has been high for 8 clocks (the 6502's
    // first address comes ~32 clocks after HALT rises; MARIA's last one just
    // sits there until then).
    // Build 4a/4b decided at every address change. One disturbed sample on an
    // address line during that last cycle -- HALT long low by then -- flipped
    // the decision, and the 6502 got the half-refilled slot's byte: Tiger-Heli
    // and ARTI on the console, with "byte never came" at 0.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cpu_cyc <= 1'b1;
        else if (wp_fall && halt_was && halt_run >= 5'd10)             cpu_cyc <= 1'b0;
        else if (!halt_was && halt_run >= 5'd8 && (a_s1 != a_s2))      cpu_cyc <= 1'b1;
    end
    wire wr_evt = wp_fall && !rw_f && cart_en && cart_en_d && !halted_cycle;

    reg  inc_bankwr, inc_pokeywr, inc_ignored;
    reg  [4:0] rnd_n;            // clocks of this cycle spent reading $043E (saturating)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ram_we <= 1'b0; ram_pre <= 1'b0; ram_wa <= 14'd0; ram_wd <= 8'd0; rg_we <= 1'b0;
            mt_we <= 1'b0; mt_rd <= 1'b0; mt_ra <= 4'd0; mt_wa4 <= 1'b0; rnd_n <= 5'd0;
            cw_pend <= 1'b0; xw_pend <= 1'b0; cw_a <= 14'd0; xw_a <= 14'd0; cw_d <= 8'd0; xw_d <= 8'd0;
            pk_we <= 1'b0; pk_addr <= 4'd0; pk_wdata <= 8'd0; pk_alt <= 1'b0;
            hw_we <= 1'b0; hw_addr <= 11'd0; hw_data <= 8'd0;
            bank_req <= 1'b0; bank_new <= 8'd0;
            inc_bankwr <= 1'b0; inc_pokeywr <= 1'b0; inc_ignored <= 1'b0;
        end else begin
            ram_pre <= 1'b0; pk_we <= 1'b0; bank_req <= 1'b0; rg_we <= 1'b0; hw_we <= 1'b0;
            mt_we <= 1'b0;
            // The end of a 6502 read cycle at the math unit's random register
            // ($043E: a read steps the generator). Not judged from one sample of
            // the address: a one-clock disturbance on A2 during a read of $043A
            // would step it. The address must have been $043E for 12 clocks of
            // the cycle (a cycle is 37 or more), with the bus the 6502's (cpu_cyc:
            // that includes its last cycle before DMA, HALT already low; it
            // excludes the wait after DMA, when the old address sits on the bus).
            if (wp_fall)                                                          rnd_n <= 5'd0;
            else if (rw_s2 && is_math(a_s2) && a_s2[4:0] == 5'h1E && cpu_cyc && rnd_n != 5'd31) rnd_n <= rnd_n + 5'd1;
            mt_rd <= wp_fall && rw_f && cart_en && cart_en_d && !halted_cycle && (rnd_n >= 5'd12);
            mt_ra <= 4'hE;
            ram_we  <= ram_pre;
            inc_bankwr <= 1'b0; inc_pokeywr <= 1'b0;
            inc_ignored <= wp_fall && !rw_f && cart_en && halted_cycle;
            if (!ram_pre) begin                 // (ram_pre: this clock is the write itself)
                if (cw_pend) begin
                    ram_pre <= 1'b1; ram_wa <= cw_a; ram_wd <= cw_d; cw_pend <= 1'b0;
                end else if (xw_pend) begin
                    ram_pre <= 1'b1; ram_wa <= xw_a; ram_wd <= xw_d; xw_pend <= 1'b0;
                end
            end
            if (xw_we) begin
                xw_pend <= 1'b1; xw_a <= xw_addr; xw_d <= xw_data;
            end
            if (wr_evt) begin
                if (is_reg(a_w)) begin
                    rg_we    <= 1'b1;
                    pk_addr  <= a_w[3:0];
                    pk_wdata <= d_w;
                end else if (is_math(a_w)) begin
                    mt_we    <= 1'b1;
                    mt_wa4   <= a_w[4];
                    pk_addr  <= a_w[3:0];
                    pk_wdata <= d_w;
                end else if (is_pokey(a_w, pokey_sel)) begin
                    pk_we       <= 1'b1;
                    pk_alt      <= (pokey_sel == 3'd5) && !a_w[4];
                    pk_addr     <= a_w[3:0];
                    pk_wdata    <= d_w;
                    inc_pokeywr <= 1'b1;
                end else if (sg_en && a_w[15:14] == 2'b10) begin
                    bank_req   <= 1'b1;
                    bank_new   <= (d_w & bank_mask) + bank_add;
                    inc_bankwr <= 1'b1;
                end else if (hsc_q && a_w[15:11] == 5'b00010) begin
                    hw_we   <= 1'b1;
                    hw_addr <= a_w[10:0];
                    hw_data <= d_w;
                end else if (act_en && a_w[15:4] == 12'hFF8) begin
                    bank_req   <= 1'b1;
                    bank_new   <= {5'b00000, a_w[2:0]};
                    inc_bankwr <= 1'b1;
                end else if (abs_en && a_w == 16'h8000) begin
                    if (d_w[1:0] != 2'b00) begin
                        bank_req   <= 1'b1;
                        bank_new   <= d_w[0] ? 8'd0 : 8'd1;
                        inc_bankwr <= 1'b1;
                    end
                end else if (win4000 == 2'd2 && a_w[15:14] == 2'b01) begin
                    cw_pend <= 1'b1;
                    cw_a    <= {a_w[13:9], a_w[8] && !mram, a_w[7:0]};
                    cw_d    <= d_w;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Counters (the hold-time histograms, the crash recorder and the write
    // log went after build 7a, for timing headroom: tag debug-full-7a)
    // ------------------------------------------------------------------
    reg [23:0] c_bankwr, c_pokeywr, c_ignored;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_bankwr <= 24'd0; c_pokeywr <= 24'd0; c_ignored <= 24'd0;
        end else if (st_clear) begin
            c_bankwr <= 24'd0; c_pokeywr <= 24'd0; c_ignored <= 24'd0;
        end else begin
            if (inc_bankwr)  c_bankwr  <= c_bankwr + 24'd1;
            if (inc_pokeywr) c_pokeywr <= c_pokeywr + 24'd1;
            if (inc_ignored) c_ignored <= c_ignored + 24'd1;
        end
    end
    reg [2:0] st_ra_q;           // the reader sits across the chip: register first
    always @(posedge clk) begin
        st_ra_q <= st_raddr;
        case (st_ra_q)
            3'd0:    st_rdata <= c_bankwr;
            3'd1:    st_rdata <= c_pokeywr;
            3'd2:    st_rdata <= c_ignored;
            3'd3:    st_rdata <= c_px_reads;
            default: st_rdata <= c_px_miss;
        endcase
    end

    // ------------------------------------------------------------------
    // Bus trace: 512 x 36 = {dt[8:0], halt, rw, our_halt, addr[15:0], bus data[7:0]}
    // One entry per change of a_s2, HALT or R/W (raw, unfiltered); dt is the
    // number of clocks since the previous entry (saturating at 511). It
    // records from the arming (mode 0) or from the next bank-switch write
    // (mode 2) until the buffer is full. Observation only.
    // ------------------------------------------------------------------
    reg [35:0] tr_mem [0:511];
    reg [8:0]  tr_wa, tr_wptr;
    reg [8:0]  tr_dt;
    reg [1:0]  tr_st;
    reg        tr_we;
    reg [35:0] tr_wd;
    assign tr_state = tr_st;
    reg  our_halt_d;
    always @(posedge clk) our_halt_d <= our_halt;
    // (a_s1 != a_s2) registered == (a_s2 != a_s3) now, without the compare on this path
    reg  a_chg_q, hr_chg_q;
    always @(posedge clk) begin
        a_chg_q  <= (a_s1 != a_s2);
        hr_chg_q <= (halt_s1 != halt_s2) || (rw_s1 != rw_s2);
    end
    wire tr_evt = a_chg_q || hr_chg_q || (our_halt != our_halt_d);
    always @(posedge clk) begin
        tr_rdata <= tr_mem[tr_raddr];
        if (tr_we) tr_mem[tr_wptr] <= tr_wd;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tr_st <= 2'd0; tr_wa <= 9'd0; tr_wptr <= 9'd0; tr_dt <= 9'd0;
            tr_we <= 1'b0; tr_wd <= 36'd0;
        end else begin
            tr_we <= 1'b0;
            if (tr_dt != 9'h1FF) tr_dt <= tr_dt + 9'd1;
            if (tr_arm) begin
                tr_st <= (tr_mode == 2'd2) ? 2'd1 : 2'd2;
                tr_wa <= 9'd0;
                tr_dt <= 9'd0;
            end else if (tr_st == 2'd1) begin
                if (inc_bankwr) tr_st <= 2'd2;
            end else if (tr_st == 2'd2 && tr_evt) begin
                tr_we   <= 1'b1;
                tr_wptr <= tr_wa;
                tr_wd   <= {tr_dt, halt_s2, rw_s2, our_halt, a_s2, d_s2};
                tr_dt   <= 9'd1;
                tr_wa   <= tr_wa + 9'd1;
                if (tr_wa == 9'd511) tr_st <= 2'd3;
            end
        end
    end
endmodule

`default_nettype wire
