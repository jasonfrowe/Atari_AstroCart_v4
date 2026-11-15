// ============================================================================
// devcart_top -- AstroCart V4 development cartridge.
//
// No menu, no SD card: the host loads a ROM image into PSRAM over the Tang
// Nano's USB UART (tools/devcart.py), every word verified by reading both
// dies back. Configuring the mapper copies the visible banks from PSRAM into
// three 16K BRAM slots, which is all the Atari ever reads (MARIA needs data
// within ~120 ns; PSRAM takes 160 ns). A SuperGame bank switch makes the copy
// engine pull HALT (Q1 bodge) and refill the $8000 slot from PSRAM.
//
// UART protocol (230400 8N1). Replies are text lines.
//   'S'                      -> "AC78V4 <cart_en> <trace state> <slot1 bank>"
//   'L' len[3] bytes...      -> load PSRAM from address 0 (cart disabled):
//                               "OK <sum> <retries> <fails>" (hex; sum = die-0 read-back)
//   'C' cfg[9]               -> fill the slots, enable the cart: "OK"
//        cfg: win4000, bank4000, mapper (bit 0 SuperGame, bit 1 Absolute, bit 2
//             mirror RAM, bit 3 Activision, bit 4 Activision "AM" dump: the 8K
//             halves the other way round, bit 5 math unit at $0430), bank_mask, bank_add, bank8000_init,
//             bankC000, pokey_sel, flags (bit 0: pull HALT while copying)
//   'X'                      -> disable the cart: "OK"
//   'V' len[3]               -> (cart disabled) read both dies over len bytes:
//                               "OK <sum die0> <words where die0 != die1>"
//   'T'                      -> statistics: "@" + 8 hex words
//   'Z'                      -> clear statistics: "OK"
//   'A' mode                 -> arm the bus trace (0 now, 2 from the next bank-switch
//                               write): "OK"
//   'Y'                      -> trace dump: "@" + 512 entries of 9 hex digits
//   'W' reg val              -> write a menu register (see "SD card + the menu's registers"): "OK"
//   'R' reg                  -> read a menu register: 2 hex digits
//   'Q'                      -> load checksum / retries / failures so far: "OK <sum> <retries> <fails>"
//   'D' slot                 -> (cart off) dump a BRAM slot (1 = $4000, 2 = $8000, 3 = $C000;
//                               +$80: only its first 512 bytes, the SD block buffer)
//
// With MENU = 1 the cart powers up enabled, running the menu ROM that the
// bitstream put in the $8000 and $C000 slots, with RAM at $4000 and the menu's
// registers at $0460. The menu loads a game from the SD card into PSRAM and
// launches it; 'L', 'C' and 'X' from the host also leave the menu.
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

module devcart_top #(
    // 67.5 MHz = 27 * 5 / 2 (VCO 540 MHz). The Atari reads BRAM through a
    // fixed 4-clock pipeline, so a faster clock buys little; 81 MHz left the
    // 24-BRAM design with no timing margin.
    parameter FREQ         = 67_500_000,
    parameter LATENCY      = 3,
    parameter PLL_IDIV     = 1,
    parameter PLL_FBDIV    = 4,
    parameter PLL_ODIV     = 8,
    parameter PLL_PSDA     = "1100",
    parameter CK_MODE      = 1,
    parameter POKEY_ON_PHI2 = 0,
    parameter MENU         = 1,           // power up running the menu ROM (slots 1 and 2)
    parameter MENU_HEX     = "menu",      // <MENU_HEX>_8e/_8o/_ce/_co.hex
    parameter SD_SLOW_HALF = FREQ / 700_000,
    parameter SD_BOOT_CLKS = FREQ / 20,
    parameter BAUD_DIV     = FREQ / 230400,
    parameter HSC_IDLE     = FREQ,        // the HSC's RAM is saved this long after its last write
    parameter SEED         = 0            // placement seed: SEED inert flip-flops (hw/devcart/build.sh sweeps it)
) (
    input  wire        clk27,

    // Atari cartridge port (via level shifters, see docs/HARDWARE.md)
    input  wire [15:0] a,
    inout  wire [7:0]  d,
    input  wire        phi2,
    input  wire        rw,
    input  wire        halt,
    output wire        halt_pull,    // Q1 gate (bodge: pulls HALT low when 1)
    output wire        buf_dir,      // U3 DIR
    output wire        buf_oe,       // U3 /OE
    output wire        audio,        // EAUD (PWM)

    // microSD slot (SPI mode)
    output wire        sd_cs,
    output wire        sd_sck,
    output wire        sd_mosi,
    input  wire        sd_miso,

    input  wire        uart_rxd,
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
    // Clock / reset
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
    assign buf_oe = 1'b0;             // U3 always enabled; direction does the work

    // ------------------------------------------------------------------
    // PSRAM (both dies): the copy engine while copying, else the loader
    // ------------------------------------------------------------------
    reg         cp_active;
    reg         cp_want;
    reg  [21:0] cp_addr;
    reg         ld_rd, ld_wr;
    reg  [1:0]  ld_dies;
    reg  [21:0] ld_addr;
    reg  [15:0] ld_din;

    wire        m_want  = cp_active ? cp_want  : ld_rd;
    wire [21:0] m_addr  = cp_active ? cp_addr  : ld_addr;
    wire [1:0]  m_dies  = cp_active ? 2'b01    : ld_dies;
    wire [3:0]  m_burst = cp_active ? 4'd15 : 4'd0;
    wire [15:0] m_dout, m_dout0, m_dout1;
    wire [7:0]  m_dbyte;
    wire [20:0] m_dword;
    wire        m_valid, m_valid0, m_valid1, m_busy_now, m_busy, m_issued, m_busy1;
    wire        px_act;            // HALT-free bank switch in progress (see the copy engine)
    reg         x_read, x_abort;
    reg  [21:0] x_addr;
    reg         px_thsc;
    wire        px_hsc, hw_we, bg_ok;
    wire [10:0] hw_addr;
    wire [7:0]  hw_data;
    reg         cfg_hsc, hs_arm;
    reg  [31:0] hs_lba;
    // Die 1 on its own for the 6502's reads (HALT-free bank switch, High Score
    // Cart). Registered: it fans out into both PSRAM controllers. The first
    // x_read comes two clocks after px_act at the earliest.
    reg x_mode_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) x_mode_q <= 1'b0;
        else        x_mode_q <= px_act || (cfg_hsc && cart_en);
    end
    psram_dual #(.FREQ(FREQ), .LATENCY(LATENCY), .CK_MODE(CK_MODE)) u_psram (
        .clk(clk), .clk_p(clk_p), .resetn(rst_n),
        .want(m_want), .wr(ld_wr && !cp_active), .dies(m_dies), .abort(1'b0), .addr(m_addr),
        .bsel(1'b0), .burst_n(m_burst), .din(ld_din), .issued(m_issued),
        .dout(m_dout), .dbyte(m_dbyte), .dword(m_dword), .rd_valid(m_valid),
        .x_mode(x_mode_q), .x_read(x_read),
        .x_abort(x_abort), .x_addr(x_addr), .busy1(m_busy1),
        .x_write(x_write), .x_wd(x_wd),
        .dout0(m_dout0), .dout1(m_dout1),
        .valid0(m_valid0), .valid1(m_valid1), .busy(m_busy_now), .busy_q(m_busy),
        .O_psram_ck(O_psram_ck), .O_psram_ck_n(O_psram_ck_n), .O_psram_cs_n(O_psram_cs_n),
        .IO_psram_rwds(IO_psram_rwds), .IO_psram_dq(IO_psram_dq));

    // ------------------------------------------------------------------
    // Cart bus engine
    // ------------------------------------------------------------------
    reg        cart_en;
    reg  [1:0] cfg_win4000;
    reg  [7:0] cfg_bank4000, cfg_bank_mask, cfg_bank_add, cfg_bank8000, cfg_bankC000;
    reg        cfg_sg_en, cfg_halt_en, cfg_abs, cfg_mram, cfg_act, cfg_hflip;
    reg  [2:0] cfg_pokey;
    reg        cfg_math;         // the math unit answers at $0420-$043F (docs/MATHUNIT.md)
    wire       mt_we, mt_rd, mt_wa4, mt_ra4;
    wire [3:0] mt_ra;
    wire [7:0] mt_rdata;

    wire [7:0] d_out;
    wire [7:0] d_oe;
    genvar gd;
    generate
        for (gd = 0; gd < 8; gd = gd + 1) begin : g_dpad
            assign d[gd] = d_oe[gd] ? d_out[gd] : 1'bz;
        end
    endgenerate

    wire       pk_we;
    wire [3:0] pk_waddr, pk_raddr;
    wire [7:0] pk_wdata, pk_rdata, pk_rdata0, pk_rdata1;
    wire       pk_alt, pk_ralt;
    wire       phi2_rise;

    wire       bank_req;
    wire [7:0] bank_new;
    reg        sw_we;
    reg [14:0] sw_word;
    reg [15:0] sw_data;
    reg        our_halt;

    reg        st_clear;
    reg  [2:0] st_raddr;
    wire [23:0] st_rdata;
    reg  [15:0] dbg_addr;            // 'D': slot read-back address
    wire [7:0]  dbg_data;
    reg        tr_arm;
    reg  [1:0] tr_mode;
    reg  [8:0] tr_raddr;
    wire [35:0] tr_rdata;
    wire [1:0] tr_state;

    reg        menu_mode;
    wire        px_want;
    wire [13:0] px_addr;
    reg         px_valid;
    reg  [13:0] px_tag;
    reg  [15:0] px_data;
    reg        cur_alt;              // $8000 is served from slot 0 (see the copy engine)
    wire       rg_we;
    wire [7:0] rg_rdata;
    reg        xw_we;
    reg [13:0] xw_addr;
    reg [7:0]  xw_data;

    cart_bus #(.MENU(MENU), .MENU_HEX(MENU_HEX)) u_bus (
        .clk(clk), .rst_n(rst_n),
        .a_pin(a), .d_pin_in(d), .d_pin_out(d_out), .d_pin_oe(d_oe), .buf_dir(buf_dir),
        .phi2_pin(phi2), .rw_pin(rw), .halt_pin(halt),
        .cart_en(cart_en), .win4000(cfg_win4000), .sg_en(cfg_sg_en),
        .bank_mask(cfg_bank_mask), .bank_add(cfg_bank_add), .pokey_sel(cfg_pokey), .abs_en(cfg_abs), .mram(cfg_mram), .act_en(cfg_act), .hflip(cfg_hflip),
        .our_halt(our_halt), .menu_mode(menu_mode), .alt8000(cur_alt),
        .px_act(px_act), .px_want(px_want), .px_addr(px_addr), .px_hsc(px_hsc), .px_thsc(px_thsc),
        .hsc_en(cfg_hsc), .hw_we(hw_we), .hw_addr(hw_addr), .hw_data(hw_data), .bg_ok(bg_ok),
        .px_valid(px_valid), .px_tag(px_tag), .px_data(px_data),
        .math_en(cfg_math), .mt_we(mt_we), .mt_rd(mt_rd), .mt_ra(mt_ra), .mt_wa4(mt_wa4), .mt_ra4(mt_ra4), .mt_rdata(mt_rdata),
        .rg_we(rg_we), .rg_rdata(rg_rdata), .xw_we(xw_we), .xw_addr(xw_addr), .xw_data(xw_data),
        .bank_req(bank_req), .bank_new(bank_new),
        .sw_act(cp_active), .sw_we(sw_we), .sw_word(sw_word), .sw_data(sw_data),
        .pk_we(pk_we), .pk_addr(pk_waddr), .pk_wdata(pk_wdata), .pk_alt(pk_alt), .pk_raddr(pk_raddr), .pk_ralt(pk_ralt),
        .pk_rdata(pk_rdata), .phi2_rise(phi2_rise),
        .st_clear(st_clear), .st_raddr(st_raddr), .st_rdata(st_rdata),
        .dbg_sel(!cart_en), .dbg_addr(dbg_addr), .dbg_data(dbg_data),
        .tr_arm(tr_arm), .tr_mode(tr_mode), .tr_raddr(tr_raddr), .tr_rdata(tr_rdata),
        .tr_state(tr_state));

    // ------------------------------------------------------------------
    // POKEY + PWM
    // ------------------------------------------------------------------
    // POKEY's clock: 1.7897725 MHz (NTSC colour clock / 2) made from the
    // system clock by a phase accumulator, +-1 clk of jitter. A real POKEY
    // cart runs on PHI2, which the console stretches on every TIA/RIOT access
    // (flat by a few cents, wobbling); this is the steady clock the emulators
    // assume and the music was tuned against. POKEY_ON_PHI2 = 1 for the other.
    reg  [26:0] pk_acc;
    reg         pk_tick_r;
    localparam [27:0] PK_MOD = FREQ;
    wire [27:0] pk_nx  = {1'b0, pk_acc} + 28'd1_789_773;
    wire [27:0] pk_sub = pk_nx - PK_MOD;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pk_acc <= 27'd0; pk_tick_r <= 1'b0;
        end else if (pk_nx >= PK_MOD) begin
            pk_acc <= pk_sub[26:0]; pk_tick_r <= 1'b1;
        end else begin
            pk_acc <= pk_nx[26:0];  pk_tick_r <= 1'b0;
        end
    end
    wire pk_tick = POKEY_ON_PHI2 ? phi2_rise : pk_tick_r;
    reg  pk_we_q, pk_we2_q;       // (pk_waddr / pk_wdata hold until the next write)
    always @(posedge clk) begin
        pk_we_q  <= pk_we && !pk_alt && cart_en && !menu_mode;
        pk_we2_q <= pk_we &&  pk_alt && cart_en && !menu_mode;
    end
    // A second POKEY at $0440 beside the one at $0450 (cfg_pokey 5: the "dual
    // POKEY" music demos); its sound is mixed half and half with the first.
    wire [7:0] pcm0, pcm1;
    reg  [7:0] pcm;
    wire [8:0] pcm_sum = {1'b0, pcm0} + {1'b0, pcm1};
    always @(posedge clk) pcm <= (cfg_pokey == 3'd5) ? pcm_sum[8:1] : pcm0;
    assign pk_rdata = pk_ralt ? pk_rdata1 : pk_rdata0;
    pokey u_pokey2 (
        .clk(clk), .rst_n(rst_n), .tick(pk_tick),
        .we(pk_we2_q), .waddr(pk_waddr), .wdata(pk_wdata),
        .raddr(pk_raddr), .rdata(pk_rdata1), .audio_out(pcm1));
    pokey u_pokey (
        .clk(clk), .rst_n(rst_n), .tick(pk_tick),
        .we(pk_we_q), .waddr(pk_waddr), .wdata(pk_wdata),
        .raddr(pk_raddr), .rdata(pk_rdata0), .audio_out(pcm0));
    audio_pwm u_pwm (.clk(clk), .rst_n(rst_n), .level(cfg_pokey != 3'd0 ? pcm : 8'd0), .pwm_out(audio));

    // ------------------------------------------------------------------
    // Math unit: in reset (its power-on state) until a game that asks for it runs
    // ------------------------------------------------------------------
    reg mt_on;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) mt_on <= 1'b0;
        else        mt_on <= cfg_math && cart_en;
    end
    astromath u_math (
        .clk(clk), .rst_n(mt_on),
        .we(mt_we), .waddr({mt_wa4, pk_waddr}), .wdata(pk_wdata),
        .rd_evt(mt_rd), .raddr_evt(mt_ra), .raddr({mt_ra4, pk_raddr}), .rdata(mt_rdata));

    // ------------------------------------------------------------------
    // Copy engine: PSRAM bank (16K) -> BRAM slot, 16-word bursts from die 0.
    // Jobs: the config fill (slots 0..2) and runtime bank switches (slot 1).
    // ------------------------------------------------------------------
    reg  [1:0]  cp_slot;
    reg  [7:0]  cp_bank;
    reg  [1:0]  cp_st;             // 0 issue, 1 receive
    reg         cp_runtime;        // a bank-switch copy (pull HALT)
    reg  [7:0]  slot1_bank;
    // Second bank buffer. A cart whose $4000 window shows neither ROM nor RAM
    // (POKEY there: Commando) leaves slot 0 idle, so $8000 can be served from
    // slot 1 or slot 0. A switch to the bank in the other buffer is then
    // instant, as on a real cart: no HALT, no copy. Commando switches to its
    // sound bank and back every frame; at 243 us per copy it never got into
    // the game (console, build 3e). A bank in neither buffer is copied into
    // the one not on show, and the buffers swap when the copy is done.
    reg  [7:0]  slot0_bank;
    reg         slot0_ok;          // slot 0 holds slot0_bank
    wire        alt_ok   = cfg_sg_en && (cfg_pokey == 3'd1);
    // (Absolute: the switched window is $4000, slot 0, always)
    wire [7:0]  vis_bank = (cur_alt || cfg_abs) ? slot0_bank : slot1_bank;
    reg         breq_q;            // bank_req, one clock later, with the compares done
    reg  [7:0]  bnew_q;
    reg         hit_vis, hit_s0, hit_s1;
    reg         sw_pend;           // a bank switch arrived while copying
    reg  [7:0]  sw_pend_bank;
    reg  [13:0] cp_fw, cp_dw;      // words read from PSRAM / written to the slot (8192 per copy)
    wire [13:0] cp_back = cp_fw - cp_dw;
    reg  [15:0] cb [0:15];         // burst buffer
    reg         dr_ph;             // drain phase: 0 set up address + data, 1 write
    reg         cfg_go;            // from the command FSM: fill slots
    reg  [1:0]  cfg_slot;          // next slot of the config fill
    reg         cfg_busy;

    assign halt_pull = our_halt;

    // ------------------------------------------------------------------
    // HALT-free bank switch (cfg_halt_en = 0). Holding the 6502 for the 243 us
    // of a copy costs more than time: MARIA's display-list interrupt can fire
    // while the 6502 is frozen and is lost (ARTI counts three per frame and
    // never recovers: black screen after level 1, console, build 3g). So the
    // 6502 keeps running, and while the slot is refilled its reads of
    // $8000-$BFFF are answered from PSRAM die 1 (die 0 feeds the copy).
    // ------------------------------------------------------------------
    // PSRAM keeps answering for a few clocks after the copy: the last word is
    // still on its way into the slot, and after a buffer swap the slot read
    // pipeline shows the old buffer for another 3 clocks.
    reg  [3:0] px_tail;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                       px_tail <= 4'd0;
        else if (cp_active && cp_runtime) px_tail <= 4'd15;
        else if (px_tail != 4'd0)         px_tail <= px_tail - 4'd1;
    end
    assign px_act = !cfg_halt_en && cart_en && ((cp_active && cp_runtime) || sw_pend || px_tail != 4'd0);
    wire [7:0] px_bank = sw_pend ? sw_pend_bank : cp_bank;
    reg        px_busy;
    reg  [7:0] px_bank_r;
    // A die-1 read is never cut short in its first clocks. Bench, build
    // 4d-bench ('B' test): CS# raised 2 clocks after it fell -- in the middle
    // of the command/address phase -- damages the die's contents (10 such
    // aborts: ~500 words wrong); raised 3 or more clocks after, 60000 aborts
    // at each of 3..15 clocks left the die intact. That early abort is what
    // the 6502's address settling produced on the console: Tiger-Heli stuck
    // with 518 words of die 1 wrong (build 4c).
    reg  [2:0] px_rage;          // clocks since x_read (saturating)

    // ------------------------------------------------------------------
    // High Score Cart (cfg_hsc). Its 4K ROM and 2K RAM live in PSRAM, in the
    // last 16K (bank 255: ROM at 0, RAM at $1000), where the menu loaded
    // /ASTROCART/HSC.A78 and /ASTROCART/HSC.SAV. Every read -- 6502 or MARIA
    // -- goes through the die-1 path above. A write to the RAM waits in a
    // small queue (one entry per address; reads of a queued address are
    // answered from the queue) until cart_bus says the die is free for the
    // rest of a bus cycle (bg_ok). When the RAM has changed and nothing has
    // been written for HSC_IDLE clocks, its 2K are copied to the four blocks
    // of HSC.SAV on the card (hs_lba), words read from die 1 in the same
    // free moments.
    // ------------------------------------------------------------------
    wire        hs_on = cfg_hsc && cart_en;
    wire        px_on = px_act || hs_on;
    reg  [3:0]  hq_v;
    reg  [43:0] hq_a;            // 4 x 11 (plain registers)
    reg  [31:0] hq_d;            // 4 x 8
    wire [3:0]  hq_hw = {hq_v[3] && hq_a[43:33] == hw_addr, hq_v[2] && hq_a[32:22] == hw_addr,
                         hq_v[1] && hq_a[21:11] == hw_addr, hq_v[0] && hq_a[10:0] == hw_addr};
    wire [3:0]  hq_hr = {hq_v[3] && hq_a[43:33] == px_addr[10:0], hq_v[2] && hq_a[32:22] == px_addr[10:0],
                         hq_v[1] && hq_a[21:11] == px_addr[10:0], hq_v[0] && hq_a[10:0] == px_addr[10:0]};
    // (the compares are registered before they are used: hwq_* a clock after
    // hw_we, fw_* a clock after the read asks)
    reg         hwq_v;
    reg  [10:0] hwq_a;
    reg  [7:0]  hwq_d;
    reg  [3:0]  hwq_hit;
    reg         fw_pend, fw_hit;
    reg  [1:0]  fw_i;
    reg  [13:0] fw_tag;
    function [1:0] first1;
        input [3:0] v;
        first1 = v[0] ? 2'd0 : v[1] ? 2'd1 : v[2] ? 2'd2 : 2'd3;
    endfunction
    wire [1:0]  hq_wi = first1(hwq_hit);     // the entry a write replaces
    wire [1:0]  hq_fi = first1(~hq_v);       // a free entry
    wire [1:0]  hq_ri = first1(hq_hr);       // the entry a read is answered from
    wire [1:0]  hq_ci = first1(hq_v);        // the entry to commit
    wire        px_hram = px_hsc && px_addr[13:11] == 3'b010;
    reg         x_write;
    reg  [7:0]  x_wd;
    reg  [3:0]  bg_t;
    reg         hs_dirty;
    reg  [27:0] hs_idle;
    reg  [15:0] hs_saves, hs_errs, hq_ovf;
    reg  [1:0]  sv_st;           // 0 idle, 1 start a block, 2 feed it, 3 wait for the card
    reg  [1:0]  sv_blk;
    reg  [9:0]  sv_n;
    reg         sv_need, sv_fly, sv_have, sv_wr, sv_wv, sv_seen;
    reg  [15:0] sv_word;
    reg  [7:0]  sv_wd;
    wire        sv_active = (sv_st != 2'd0);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_read <= 1'b0; x_abort <= 1'b0; x_addr <= 22'd0; px_busy <= 1'b0;
            px_valid <= 1'b0; px_tag <= 14'd0; px_thsc <= 1'b0; px_data <= 16'd0; px_bank_r <= 8'd0; px_rage <= 3'd7;
            x_write <= 1'b0; x_wd <= 8'd0; bg_t <= 4'd0; hq_v <= 4'd0; hq_a <= 44'd0; hq_d <= 32'd0;
            hwq_v <= 1'b0; hwq_a <= 11'd0; hwq_d <= 8'd0; hwq_hit <= 4'd0;
            fw_pend <= 1'b0; fw_hit <= 1'b0; fw_i <= 2'd0; fw_tag <= 14'd0; hs_dirty <= 1'b0; hs_idle <= 28'd0;
            hs_saves <= 16'd0; hs_errs <= 16'd0; hq_ovf <= 16'd0;
            sv_st <= 2'd0; sv_blk <= 2'd0; sv_n <= 10'd0; sv_need <= 1'b0; sv_fly <= 1'b0; sv_have <= 1'b0;
            sv_wr <= 1'b0; sv_wv <= 1'b0; sv_seen <= 1'b0; sv_word <= 16'd0; sv_wd <= 8'd0;
        end else begin
            x_read <= 1'b0; x_abort <= 1'b0; x_write <= 1'b0; px_valid <= 1'b0; sv_wr <= 1'b0; sv_wv <= 1'b0;
            if (px_rage != 3'd7) px_rage <= px_rage + 3'd1;
            if (hs_idle != HSC_IDLE[27:0]) hs_idle <= hs_idle + 28'd1;
            if (!bg_ok)             bg_t <= 4'd0;        // clocks into the free part of this bus cycle
            else if (bg_t != 4'd15) bg_t <= bg_t + 4'd1;

            // ---- the bus's reads ----
            if (!px_on) px_busy <= 1'b0;
            else if (!px_busy) begin
                if (px_want && !x_read && !x_abort && !x_write) begin
                    if (px_hram && !(fw_pend && fw_tag == px_addr)) begin
                        fw_pend <= 1'b1;                         // HSC RAM: look in the queue first
                        fw_tag  <= px_addr;
                        fw_hit  <= |hq_hr;
                        fw_i    <= hq_ri;
                    end else if (px_hram && fw_hit) begin        // written a moment ago: not in PSRAM yet
                        px_valid <= 1'b1;
                        px_tag   <= px_addr;
                        px_thsc  <= 1'b1;
                        px_data  <= {hq_d[8*fw_i +: 8], hq_d[8*fw_i +: 8]};
                    end else if (!m_busy1 && !sv_fly) begin
                        x_read    <= 1'b1;
                        x_addr    <= px_hsc ? {8'hFF, px_addr[13:1], 1'b0} : {px_bank, px_addr[13:1], 1'b0};
                        px_tag    <= px_addr;
                        px_thsc   <= px_hsc;
                        px_bank_r <= px_bank;
                        px_busy   <= 1'b1;
                        px_rage   <= 3'd0;
                    end
                end else if (bg_ok && hs_on && !px_want && !m_busy1 && !sv_fly && !x_read && !x_abort && !x_write && !hw_we && !hwq_v) begin
                    // ---- the die is free for the rest of this bus cycle ----
                    if (|hq_v) begin
                        x_write <= 1'b1;
                        x_addr  <= {8'hFF, 3'b010, hq_a[11*hq_ci +: 11]};
                        x_wd    <= hq_d[8*hq_ci +: 8];
                        hq_v[hq_ci] <= 1'b0;
                    end else if (sv_need && bg_t <= 4'd5) begin   // (a read takes longer: only early in the cycle)
                        x_read  <= 1'b1;
                        x_addr  <= {8'hFF, 3'b010, sv_blk, sv_n[8:1], 1'b0};
                        sv_need <= 1'b0;
                        sv_fly  <= 1'b1;
                    end
                end
            end else if (m_valid1) begin
                px_valid <= px_thsc || (px_bank_r == px_bank);
                px_data  <= m_dout1;
                px_busy  <= 1'b0;
            end else if (px_rage >= 3'd5 && ((px_want && (px_tag != px_addr || px_thsc != px_hsc)) ||
                                              (!px_thsc && px_bank_r != px_bank))) begin
                x_abort <= 1'b1;                 // the 6502 has moved on: drop this read
                px_busy <= 1'b0;
            end
            if (sv_fly && m_valid1) begin
                sv_word <= m_dout1;
                sv_fly  <= 1'b0;
                sv_have <= 1'b1;
            end

            // ---- a write to the HSC's RAM ----
            hwq_v   <= hw_we && hs_on;
            hwq_a   <= hw_addr;
            hwq_d   <= hw_data;
            hwq_hit <= hq_hw;
            if (!px_want || hw_we || hwq_v) fw_pend <= 1'b0;
            if (hwq_v) begin
                hs_dirty <= 1'b1;
                hs_idle  <= 28'd0;
                if (|hwq_hit)      hq_d[8*hq_wi +: 8] <= hwq_d;
                else if (!(&hq_v)) begin hq_v[hq_fi] <= 1'b1; hq_a[11*hq_fi +: 11] <= hwq_a; hq_d[8*hq_fi +: 8] <= hwq_d; end
                else if (hq_ovf != 16'hFFFF) hq_ovf <= hq_ovf + 16'd1;
            end
            if (!hs_on) begin hq_v <= 4'd0; hs_dirty <= 1'b0; fw_pend <= 1'b0; end

            // ---- the save ----
            case (sv_st)
                2'd0: if (hs_on && hs_dirty && hs_idle == HSC_IDLE[27:0] && hq_v == 4'd0 && !sd_busy && !menu_mode) begin
                    hs_dirty <= 1'b0;
                    sv_blk   <= 2'd0;
                    sv_st    <= 2'd1;
                end
                2'd1: begin
                    sv_wr <= 1'b1; sv_n <= 10'd0; sv_need <= 1'b0; sv_have <= 1'b0; sv_seen <= 1'b0;
                    sv_st <= 2'd2;
                end
                2'd2: begin
                    if (sd_busy) sv_seen <= 1'b1;
                    if (sd_wreq) begin
                        if (!sv_n[0]) sv_need <= 1'b1;                  // a new word: read it first
                        else begin sv_wv <= 1'b1; sv_wd <= sv_word[15:8]; sv_n <= sv_n + 10'd1; end
                    end
                    if (sv_have) begin
                        sv_have <= 1'b0;
                        sv_wv <= 1'b1; sv_wd <= sv_word[7:0]; sv_n <= sv_n + 10'd1;
                    end
                    if (sv_seen && !sd_busy) sv_st <= 2'd3;
                end
                default: begin
                    if (sd_err != 4'd0) begin
                        if (hs_errs != 16'hFFFF) hs_errs <= hs_errs + 16'd1;
                        sv_st <= 2'd0;
                    end else if (sv_blk == 2'd3) begin
                        if (hs_saves != 16'hFFFF) hs_saves <= hs_saves + 16'd1;
                        sv_st <= 2'd0;
                    end else begin
                        sv_blk <= sv_blk + 2'd1;
                        sv_st  <= 2'd1;
                    end
                end
            endcase
            if (!hs_on) begin sv_st <= 2'd0; sv_need <= 1'b0; sv_fly <= 1'b0; sv_have <= 1'b0; end
        end
    end

    // which bank goes in which slot for the config fill
    wire [7:0] fill_bank = (cfg_slot == 2'd0) ? cfg_bank4000 :
                           (cfg_slot == 2'd1) ? cfg_bank8000 : cfg_bankC000;
    wire       fill_skip = (cfg_slot == 2'd0) && (cfg_win4000 != 2'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cp_active <= 1'b0; cp_want <= 1'b0; cp_addr <= 22'd0; cp_slot <= 2'd0; cp_bank <= 8'd0;
            cp_st <= 2'd0; cp_runtime <= 1'b0;
            slot1_bank <= 8'hFF; sw_pend <= 1'b0; sw_pend_bank <= 8'd0;
            slot0_bank <= 8'd0; slot0_ok <= 1'b0; cur_alt <= 1'b0;
            breq_q <= 1'b0; bnew_q <= 8'd0; hit_vis <= 1'b0; hit_s0 <= 1'b0; hit_s1 <= 1'b0;
            sw_we <= 1'b0; sw_word <= 15'd0; sw_data <= 16'd0; our_halt <= 1'b0;
            cfg_slot <= 2'd0; cfg_busy <= 1'b0;
            cp_fw <= 14'd0; cp_dw <= 14'd0; dr_ph <= 1'b0;
        end else begin
            sw_we <= 1'b0;

            // runtime bank switches (only while the cart runs)
            breq_q  <= bank_req && cart_en && !cfg_busy;
            bnew_q  <= bank_new;
            hit_vis <= (bank_new == vis_bank);
            hit_s0  <= alt_ok && slot0_ok && (bank_new == slot0_bank);
            hit_s1  <= alt_ok && (bank_new == slot1_bank);
            if (breq_q) begin
                if (!cp_active && hit_vis) ;                     // already there
                else if (!cp_active && hit_s0) cur_alt <= 1'b1;  // in the other buffer: instant
                else if (!cp_active && hit_s1) cur_alt <= 1'b0;
                else begin
                    sw_pend      <= 1'b1;
                    sw_pend_bank <= bnew_q;
                    our_halt     <= cfg_halt_en;     // stop the 6502 at once
                end
            end

            if (!cp_active) begin
                if (cfg_go && !cfg_busy) begin
                    cfg_busy <= 1'b1;
                    cfg_slot <= 2'd0;
                end else if (cfg_busy) begin
                    if (cfg_slot == 2'd3) begin
                        cfg_busy   <= 1'b0;
                        slot1_bank <= cfg_bank8000;
                        slot0_bank <= cfg_bank4000;
                        slot0_ok   <= (cfg_win4000 == 2'd1);
                        cur_alt    <= 1'b0;
                    end else if (fill_skip) begin
                        cfg_slot <= cfg_slot + 2'd1;
                    end else begin
                        cp_active  <= 1'b1;
                        cp_runtime <= 1'b0;
                        cp_slot    <= cfg_slot;
                        cp_bank    <= fill_bank;
                        cp_st      <= 2'd0;
                        cp_fw <= 14'd0; cp_dw <= 14'd0; dr_ph <= 1'b0;
                        cfg_slot   <= cfg_slot + 2'd1;
                    end
                end else if (sw_pend) begin
                    sw_pend    <= 1'b0;
                    cp_active  <= 1'b1;
                    cp_runtime <= 1'b1;
                    cp_bank    <= sw_pend_bank;
                    if (cfg_abs) begin                   // Absolute: the bank at $4000
                        cp_slot    <= 2'd0;
                        slot0_bank <= sw_pend_bank;
                    end else if (alt_ok && !cur_alt) begin   // slot 1 is on show: fill slot 0
                        cp_slot    <= 2'd0;
                        slot0_bank <= sw_pend_bank;
                        slot0_ok   <= 1'b0;
                    end else begin
                        cp_slot    <= 2'd1;
                        slot1_bank <= sw_pend_bank;
                    end
                    cp_st      <= 2'd0;
                    cp_fw <= 14'd0; cp_dw <= 14'd0; dr_ph <= 1'b0;
                    our_halt   <= cfg_halt_en;
                end else begin
                    our_halt <= 1'b0;
                end
            end else begin
                // ---- fill: 16-word bursts from die 0 into the 16-word buffer ----
                case (cp_st)
                    2'd0: begin
                        cp_addr <= {cp_bank, cp_fw[12:0], 1'b0};
                        if (cp_fw[13]) begin              // all 8192 words read: wait for the drain
                            if (cp_dw == cp_fw && !dr_ph) begin
                                cp_active <= 1'b0;
                                if (cp_runtime && alt_ok) begin      // the fresh buffer goes on show
                                    cur_alt  <= (cp_slot == 2'd0);
                                    if (cp_slot == 2'd0) slot0_ok <= 1'b1;
                                end
                                if (cp_runtime && !sw_pend) our_halt <= 1'b0;
                            end
                        end else begin
                            if (cp_back <= 14'd8)  cp_want <= 1'b1;   // room for 16 more by the time they come
                            if (cp_want && m_issued) begin
                                cp_want <= 1'b0;
                                cp_st   <= 2'd1;
                            end
                        end
                    end
                    default: begin
                        if (m_valid0) begin
                            cb[cp_fw[3:0]] <= m_dout0;
                            cp_fw <= cp_fw + 14'd1;
                            if (cp_fw[3:0] == 4'd15) cp_st <= 2'd0;
                        end
                    end
                endcase
                // ---- drain: one word every two clocks. The slot BRAMs (GW1NR-9
                // BSRAM) corrupt a word when the next clock writes its neighbour
                // (measured: the word written at ...1000 picks up bits of the word
                // written at ...1001 one clock later, ~5 words per 16K). So the
                // address and data are set up one clock before the write enable,
                // and no two clocks in a row write. ----
                if (!dr_ph) begin
                    if (cp_dw != cp_fw) begin
                        sw_word <= {cp_slot, cp_dw[12:0]};
                        sw_data <= cb[cp_dw[3:0]];
                        dr_ph   <= 1'b1;
                    end
                end else begin
                    sw_we <= 1'b1;
                    cp_dw <= cp_dw + 14'd1;
                    dr_ph <= 1'b0;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // SD card + the menu's registers ($0460-$046F while menu_mode; also
    // reachable over the UART with 'W' / 'R', for bench tests).
    //
    //   write $0  command: 1 initialise the card
    //                      2 read block LBA into the buffer ($4000-$41FF, slot 0)
    //                      3 read block LBA into PSRAM at LDPTR; LDPTR += 512
    //                      4 the same, without the block's first 128 bytes
    //                        (the .a78 header); LDPTR += 384
    //                      5 launch: configure the mapper from $8-$F, fill the
    //                        slots from PSRAM, leave menu mode
    //                      6 clear the load checksum and error counts
    //                      7 High Score Cart: the game about to be launched gets
    //                        one; LBA is the first of HSC.SAV's four blocks (its
    //                        ROM and RAM contents are in PSRAM at $3FC000 / $3FD000)
    //                    LBA += 1 after each good read.
    //         $1-$4  LBA (little endian)        $5-$7  LDPTR (PSRAM byte address, even)
    //         $8-$F  win4000, bank4000, sg_en, bank_mask, bank_add, bank8000, bankC000, pokey
    //   read  $0  status: 7 busy, 6 card ready, 5 block addressed, 4 PSRAM write failures,
    //                     3-0 SD error (sd_spi.v)
    //         $1  $A7   $2  version   $3  write failures   $4-$7  load checksum
    //         $8-$B  LBA   $C-$E  LDPTR   $F  write retries
    // ------------------------------------------------------------------
    localparam [7:0] MENU_VERSION = 8'h01;
    reg         sd_init, sd_rd, sd_psram;
    wire        sd_bv, sd_busy, sd_ready, sd_hc, sd_wreq;
    wire [7:0]  sd_bd, sd_r1;
    wire [3:0]  sd_err;
    reg  [31:0] rg_lba;
    reg  [21:0] rg_ldptr;
    reg  [7:0]  mcfg [0:7];
    reg  [3:0]  rq_cmd;
    reg         rq_pend, rq_run;
    reg         ld_sd;               // the loader's bytes come from the SD card
    reg  [7:0]  ld_skip;
    reg  [8:0]  bufptr;
    wire        sd_stall;
    reg  [15:0] ld_retries, ld_fails;
    reg  [31:0] ld_sum;

    sd_spi #(.FREQ(FREQ), .SLOW_HALF(SD_SLOW_HALF), .BOOT_CLKS(SD_BOOT_CLKS)) u_sd (
        .clk(clk), .rst_n(rst_n),
        .sd_cs(sd_cs), .sd_sck(sd_sck), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .init(sd_init), .rd(sd_rd), .lba(sv_active ? hs_lba + {30'd0, sv_blk} : rg_lba), .stall(sd_stall),
        .wr(sv_wr), .wreq(sd_wreq), .wv(sv_wv), .wd(sv_wd),
        .bv(sd_bv), .bd(sd_bd), .busy(sd_busy), .ready(sd_ready), .hc(sd_hc), .err(sd_err),
        .dbg_r1(sd_r1));

    // sector buffer: slot 0, $4000-$41FF
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xw_we <= 1'b0; xw_addr <= 14'd0; xw_data <= 8'd0; bufptr <= 9'd0;
        end else begin
            xw_we <= 1'b0;
            if (sd_rd) bufptr <= 9'd0;
            else if (sd_bv && !sd_psram) begin
                xw_we   <= 1'b1;
                xw_addr <= {5'd0, bufptr};
                xw_data <= sd_bd;
                bufptr  <= bufptr + 9'd1;
            end
        end
    end

    // registered here: the read mux below sits on the Atari's read path
    reg [7:0] rg_stat, rg_fails, rg_retr;
    always @(posedge clk) begin
        rg_stat  <= {rq_pend | rq_run, sd_ready, sd_hc, |ld_fails, sd_err};
        rg_fails <= (|ld_fails[15:8])   ? 8'hFF : ld_fails[7:0];
        rg_retr  <= (|ld_retries[15:8]) ? 8'hFF : ld_retries[7:0];
    end

    function [7:0] rg_read;
        input [3:0] ra;
        case (ra)
            4'h0: rg_read = rg_stat;
            4'h1: rg_read = 8'hA7;
            4'h2: rg_read = MENU_VERSION;
            4'h3: rg_read = rg_fails;
            4'h4: rg_read = ld_sum[7:0];
            4'h5: rg_read = ld_sum[15:8];
            4'h6: rg_read = ld_sum[23:16];
            4'h7: rg_read = ld_sum[31:24];
            4'h8: rg_read = rg_lba[7:0];
            4'h9: rg_read = rg_lba[15:8];
            4'hA: rg_read = rg_lba[23:16];
            4'hB: rg_read = rg_lba[31:24];
            4'hC: rg_read = rg_ldptr[7:0];
            4'hD: rg_read = rg_ldptr[15:8];
            4'hE: rg_read = {2'b00, rg_ldptr[21:16]};
            default: rg_read = rg_retr;
        endcase
    endfunction
    assign rg_rdata = rg_read(pk_raddr);

    // ------------------------------------------------------------------
    // UART
    // ------------------------------------------------------------------
    wire       rx_valid;
    wire [7:0] rx_data;
    uart_rx #(.CLKS_PER_BIT(BAUD_DIV)) u_rx (.clk(clk), .rst_n(rst_n), .rx(uart_rxd),
                                             .valid(rx_valid), .data(rx_data));
    reg        tx_start;
    reg  [7:0] tx_data;
    wire       tx_busy;
    uart_tx #(.CLKS_PER_BIT(BAUD_DIV)) u_tx (.clk(clk), .rst_n(rst_n), .start(tx_start),
                                             .data(tx_data), .busy(tx_busy), .tx(uart_txd));

    function [7:0] hexc;
        input [3:0] n;
        hexc = (n < 4'd10) ? (8'h30 + {4'h0, n}) : (8'h37 + {4'h0, n});
    endfunction

    // reply buffer: up to 32 bytes queued by the command FSM, then sent
    reg [7:0] rb [0:31];
    reg [5:0] rb_len, rb_pos;
    reg       rb_go;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rb_pos <= 6'd0; tx_start <= 1'b0; tx_data <= 8'h00;
        end else begin
            tx_start <= 1'b0;
            if (!rb_go) rb_pos <= 6'd0;
            else if (!tx_busy && !tx_start && rb_pos != rb_len) begin
                tx_start <= 1'b1;
                tx_data  <= rb[rb_pos[4:0]];
                rb_pos   <= rb_pos + 6'd1;
            end
        end
    end
    // registered: keeps the UART's state off the command FSM's paths
    reg rb_done;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rb_done <= 1'b0;
        else        rb_done <= rb_go && !rb_done && (rb_pos == rb_len) && !tx_busy && !tx_start;
    end

    // ------------------------------------------------------------------
    // Command FSM
    // ------------------------------------------------------------------
    localparam [4:0]
        C_IDLE    = 5'd0,  C_ARGS   = 5'd1,  C_EXEC   = 5'd2,  C_REPLY  = 5'd3,
        C_LD_BYTE = 5'd4,  C_LD_WR  = 5'd5,  C_LD_WW  = 5'd6,  C_LD_RD0 = 5'd7,
        C_LD_RW0  = 5'd8,  C_LD_RD1 = 5'd9,  C_LD_RW1 = 5'd10, C_LD_CHK = 5'd11,
        C_LD_DONE = 5'd12, C_ST_W   = 5'd13, C_ST_F1  = 5'd14, C_ST_F3  = 5'd15,
        C_CFG_W   = 5'd16,
        C_LD_CMP  = 5'd24, C_TR_W   = 5'd25, C_TR_F   = 5'd26, C_TR_OUT = 5'd27,
        
        C_DB_W    = 5'd18, C_DB_F   = 5'd19, C_DB_OUT = 5'd20, C_SD_W = 5'd21, C_RG = 5'd22;

    reg [4:0]  cs;
    reg [7:0]  cmd;
    reg        f_S, f_L, f_V, f_C, f_X, f_Z, f_A, f_T, f_Y, f_D, f_W, f_R, f_Q;   // decoded cmd
    reg [14:0] db_left;
    reg [7:0]  args [0:8];
    reg [3:0]  nargs, argi;
    reg [23:0] ld_left;
    reg [20:0] ld_waddr;
    reg        ld_hi, ld_end, ld_full, ld_bad0, ld_bad1, ld_verify;
    reg [7:0]  ld_lo;
    reg [15:0] ld_word;
    reg [15:0] rd0, rd1;
    reg [3:0]  ld_try;
    reg [7:0]  ld_wait;
    reg        uw_stb;           // 'W': 1-cycle register write from the UART
    reg        sd_stall_q;       // registered: the card engine is across the chip
    always @(posedge clk) sd_stall_q <= sd_psram && (cs != C_LD_BYTE);
    assign     sd_stall = sd_stall_q;
    wire       lb_valid = ld_sd ? sd_bv : rx_valid;
    wire [7:0] lb_data  = ld_sd ? sd_bd : rx_data;
    reg  [7:0] rg_uart;
    always @(posedge clk) rg_uart <= rg_read(args[0][3:0]);
    wire       rgw      = uw_stb || rg_we;
    wire [3:0] rgw_a    = uw_stb ? args[0][3:0] : pk_waddr;
    wire [7:0] rgw_d    = uw_stb ? args[1]      : pk_wdata;
    reg        wait_go;          // 1-cycle: start a 6-cycle wait (ld_wait, from the next cycle)
    wire       waited = (ld_wait == 8'd0) && !wait_go;
    reg [3:0]  st_idx;
    reg [31:0] st_val;
    reg [9:0]  tr_idx;

    function [3:0] nargs_of;
        input [7:0] c;
        nargs_of = (c == "L") ? 4'd3 : (c == "C") ? 4'd9 : (c == "V") ? 4'd3 :
                   (c == "A") ? 4'd1 : (c == "D") ? 4'd1 :
                   (c == "W") ? 4'd2 : (c == "R") ? 4'd1 : 4'd0;
    endfunction

    // Statistics, 8 words: 0-4 from cart_bus (bank writes, POKEY writes, writes
    // ignored under HALT, PSRAM-served reads, ... that never got their byte),
    // 5 flags + the bank on show, 6 HSC saves / failed saves, 7 HSC state.
    reg [31:0] st_misc;
    always @(posedge clk) begin
        case (st_idx[1:0])
            2'd1:    st_misc <= {19'd0, cfg_math, cfg_hsc, cfg_halt_en, our_halt, cp_active, vis_bank};
            2'd2:    st_misc <= {hs_errs, hs_saves};
            default: st_misc <= {13'd0, hs_dirty, sv_st, hq_ovf};
        endcase
    end

    // A copy is running or about to: cp_active only ever rises a clock after
    // sw_pend or cfg_busy, so this is never late in rising (and one clock late
    // in falling). The command FSM sits across the chip from the copy engine.
    reg cp_busy_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cp_busy_q <= 1'b0;
        else        cp_busy_q <= cp_active || sw_pend || cfg_busy;
    end

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cs <= C_IDLE; cmd <= 8'h00; nargs <= 4'd0; argi <= 4'd0;
            f_S <= 1'b0; f_L <= 1'b0; f_V <= 1'b0; f_C <= 1'b0; f_X <= 1'b0;
            f_Z <= 1'b0; f_A <= 1'b0; f_T <= 1'b0; f_Y <= 1'b0;
            for (k = 0; k < 9; k = k + 1) args[k] <= 8'h00;
            cart_en <= (MENU != 0); cfg_go <= 1'b0; menu_mode <= (MENU != 0);
            sd_init <= 1'b0; sd_rd <= 1'b0; sd_psram <= 1'b0; rg_lba <= 32'd0; rg_ldptr <= 22'd0;
            for (k = 0; k < 8; k = k + 1) mcfg[k] <= 8'h00;
            rq_cmd <= 4'd0; rq_pend <= 1'b0; rq_run <= 1'b0; ld_sd <= 1'b0; ld_skip <= 8'd0; uw_stb <= 1'b0;
            cfg_win4000 <= (MENU != 0) ? 2'd2 : 2'd0; cfg_bank4000 <= 8'd0; cfg_sg_en <= 1'b0; cfg_bank_mask <= 8'd0;
            cfg_bank_add <= 8'd0; cfg_bank8000 <= 8'd0; cfg_bankC000 <= 8'd0; cfg_pokey <= 3'd0;
            cfg_abs <= 1'b0; cfg_mram <= 1'b0; cfg_act <= 1'b0; cfg_hflip <= 1'b0;
            cfg_hsc <= 1'b0; hs_arm <= 1'b0; hs_lba <= 32'd0; cfg_math <= 1'b0;
            cfg_halt_en <= 1'b1;
            ld_rd <= 1'b0; ld_wr <= 1'b0; ld_dies <= 2'b01; ld_addr <= 22'd0; ld_din <= 16'd0;
            ld_left <= 24'd0; ld_waddr <= 21'd0; ld_hi <= 1'b0; ld_end <= 1'b0; ld_full <= 1'b0;
            ld_bad0 <= 1'b0; ld_bad1 <= 1'b0; ld_verify <= 1'b0; ld_lo <= 8'd0; ld_word <= 16'd0;
            rd0 <= 16'd0; rd1 <= 16'd0; ld_try <= 4'd0; ld_sum <= 32'd0;
            ld_retries <= 16'd0; ld_fails <= 16'd0; ld_wait <= 8'd0; wait_go <= 1'b0;
            st_clear <= 1'b0; st_raddr <= 3'd0; st_idx <= 4'd0;
            st_val <= 32'd0; tr_idx <= 10'd0; tr_raddr <= 9'd0; tr_arm <= 1'b0; tr_mode <= 2'd0;
            dbg_addr <= 16'd0; db_left <= 15'd0; f_D <= 1'b0;
            f_W <= 1'b0; f_R <= 1'b0; f_Q <= 1'b0;
            rb_go <= 1'b0; rb_len <= 6'd0;
            for (k = 0; k < 32; k = k + 1) rb[k] <= 8'h00;
        end else begin
            ld_rd    <= 1'b0;
            ld_wr    <= 1'b0;
            st_clear <= 1'b0;
            tr_arm   <= 1'b0;
            cfg_go   <= 1'b0;
            wait_go  <= 1'b0;
            sd_init  <= 1'b0;
            sd_rd    <= 1'b0;
            uw_stb   <= 1'b0;
            if (wait_go)              ld_wait <= 8'd7;
            else if (ld_wait != 8'd0) ld_wait <= ld_wait - 8'd1;

            case (cs)
            C_IDLE: begin
              rq_run <= 1'b0;
              if (!rx_valid && rq_pend) begin
                // a command from the menu's register $0
                rq_pend <= 1'b0;
                rq_run  <= 1'b1;
                wait_go <= 1'b1;
                case (rq_cmd)
                    4'd1: begin sd_init <= 1'b1; cs <= C_SD_W; end
                    4'd2: begin sd_rd <= 1'b1; sd_psram <= 1'b0; cs <= C_SD_W; end
                    4'd3, 4'd4: begin
                        sd_rd     <= 1'b1;
                        sd_psram  <= 1'b1;
                        ld_sd     <= 1'b1;
                        ld_verify <= 1'b0;
                        ld_skip   <= (rq_cmd == 4'd4) ? 8'd128 : 8'd0;
                        ld_left   <= (rq_cmd == 4'd4) ? 24'd384 : 24'd512;
                        ld_waddr  <= rg_ldptr[21:1];
                        ld_hi     <= 1'b0;
                        cs        <= C_LD_BYTE;
                    end
                    4'd5: begin
                        cart_en       <= 1'b0;
                        menu_mode     <= 1'b0;
                        cfg_win4000   <= mcfg[0][1:0];
                        cfg_bank4000  <= mcfg[1];
                        cfg_sg_en     <= mcfg[2][0];
                        cfg_abs       <= mcfg[2][1];
                        cfg_mram      <= mcfg[2][2];
                        cfg_act       <= mcfg[2][3];
                        cfg_hflip     <= mcfg[2][4];
                        cfg_math      <= mcfg[2][5];
                        cfg_bank_mask <= mcfg[3];
                        cfg_bank_add  <= mcfg[4];
                        cfg_bank8000  <= mcfg[5];
                        cfg_bankC000  <= mcfg[6];
                        cfg_pokey     <= mcfg[7][2:0];
                        cfg_halt_en   <= 1'b0;       // games from the menu: HALT-free bank switches
                        cfg_hsc       <= hs_arm;
                        cfg_go        <= 1'b1;
                        cs            <= C_CFG_W;
                    end
                    4'd6: begin ld_sum <= 32'd0; ld_retries <= 16'd0; ld_fails <= 16'd0; hs_arm <= 1'b0; end
                    // High Score Cart for the game about to be launched: LBA is the
                    // first of HSC.SAV's four blocks (ROM and RAM contents are in
                    // PSRAM at $3FC000 / $3FD000 by now)
                    4'd7: begin hs_lba <= rg_lba; hs_arm <= 1'b1; end
                    default: ;
                endcase
              end
              if (rx_valid) begin
                cmd   <= rx_data;
                f_S <= (rx_data == "S"); f_L <= (rx_data == "L"); f_V <= (rx_data == "V");
                f_C <= (rx_data == "C"); f_X <= (rx_data == "X"); f_Z <= (rx_data == "Z");
                f_A <= (rx_data == "A"); f_T <= (rx_data == "T"); f_Y <= (rx_data == "Y");
                f_D <= (rx_data == "D");
                f_W <= (rx_data == "W"); f_R <= (rx_data == "R"); f_Q <= (rx_data == "Q");
                nargs <= nargs_of(rx_data);
                argi  <= 4'd0;
                cs    <= (nargs_of(rx_data) == 4'd0) ? C_EXEC : C_ARGS;
              end
            end
            C_ARGS: if (rx_valid) begin
                args[argi] <= rx_data;
                argi <= argi + 4'd1;
                if (argi + 4'd1 == nargs) cs <= C_EXEC;
            end

            C_EXEC: if (!cp_busy_q) begin          // never touch PSRAM under a copy
                cs <= C_REPLY;
                rb[0] <= "O"; rb[1] <= "K"; rb[2] <= 8'h0A; rb_len <= 6'd3;
                if (f_S) begin
                        rb[0] <= "A"; rb[1] <= "C"; rb[2] <= "7"; rb[3] <= "8"; rb[4] <= "V";
                        rb[5] <= "4"; rb[6] <= " "; rb[7] <= cart_en ? "1" : "0"; rb[8] <= " ";
                        rb[9] <= "0" + {6'd0, tr_state}; rb[10] <= " ";
                        rb[11] <= hexc(vis_bank[7:4]); rb[12] <= hexc(vis_bank[3:0]);
                        rb[13] <= 8'h0A; rb_len <= 6'd14;
                end else if (f_W) begin
                        uw_stb <= 1'b1;
                end else if (f_R) begin
                        wait_go <= 1'b1;
                        cs      <= C_RG;
                end else if (f_Q) begin
                        cs <= C_LD_DONE;
                end else if (f_L || f_V) begin
                        cart_en    <= 1'b0;
                        menu_mode  <= 1'b0;
                        ld_sd      <= 1'b0;
                        ld_skip    <= 8'd0;
                        ld_verify  <= f_V;
                        ld_left    <= {args[2], args[1], args[0]};
                        ld_waddr   <= 21'd0;
                        ld_hi      <= 1'b0;
                        ld_sum     <= 32'd0;
                        ld_retries <= 16'd0;
                        ld_fails   <= 16'd0;
                        cs         <= ({args[2], args[1], args[0]} == 24'd0) ? C_LD_DONE :
                                      f_V ? C_LD_RD0 : C_LD_BYTE;
                end else if (f_C) begin
                        cart_en       <= 1'b0;
                        menu_mode     <= 1'b0;
                        cfg_win4000   <= args[0][1:0];
                        cfg_bank4000  <= args[1];
                        cfg_sg_en     <= args[2][0];
                        cfg_abs       <= args[2][1];
                        cfg_mram      <= args[2][2];
                        cfg_act       <= args[2][3];
                        cfg_hflip     <= args[2][4];
                        cfg_math      <= args[2][5];
                        cfg_bank_mask <= args[3];
                        cfg_bank_add  <= args[4];
                        cfg_bank8000  <= args[5];
                        cfg_bankC000  <= args[6];
                        cfg_pokey     <= args[7][2:0];
                        cfg_halt_en   <= args[8][0];
                        cfg_hsc       <= 1'b0;
                        cfg_go        <= 1'b1;
                        wait_go       <= 1'b1;
                        cs            <= C_CFG_W;
                end else if (f_X) begin
                    cart_en <= 1'b0; menu_mode <= 1'b0;
                end else if (f_Z) begin
                    st_clear <= 1'b1;
                end else if (f_A) begin
                    tr_mode <= args[0][1:0]; tr_arm <= 1'b1;
                end else if (f_T) begin
                        st_idx    <= 4'd0;
                        rb[0] <= 8'h0A; rb[1] <= "@"; rb_len <= 6'd2;
                        cs <= C_ST_W;
                end else if (f_D) begin
                    if (cart_en) begin
                        rb[0] <= "E"; rb[1] <= "N"; rb[2] <= 8'h0A; rb_len <= 6'd3;
                        cs <= C_REPLY;
                    end else begin
                        dbg_addr <= {args[0][1:0], 14'd0};      // 1 = $4000, 2 = $8000, 3 = $C000
                        db_left  <= args[0][7] ? 15'd512 : 15'd16384;   // bit 7: the first 512 bytes only
                        rb[0] <= 8'h0A; rb[1] <= "@"; rb_len <= 6'd2;
                        cs <= C_DB_W;
                    end
                end else if (f_Y) begin
                        tr_idx <= 10'd0;
                        rb[0] <= 8'h0A; rb[1] <= "@"; rb_len <= 6'd2;
                        cs <= C_TR_W;
                end else begin
                        rb[0] <= "?"; rb[1] <= 8'h0A; rb_len <= 6'd2;
                end
            end

            C_REPLY: begin
                if (!rb_go) rb_go <= 1'b1;
                else if (rb_done) begin
                    rb_go <= 1'b0;
                    cs    <= C_IDLE;
                end
            end

            // config: wait for the slot fill, then enable the cart
            C_CFG_W: if (waited && !cp_busy_q && !cfg_go) begin
                cart_en <= 1'b1;
                cs      <= rq_run ? C_IDLE : C_REPLY;
            end

            C_RG: if (waited) begin              // 'R': the register read is registered
                rb[0] <= hexc(rg_uart[7:4]);
                rb[1] <= hexc(rg_uart[3:0]);
                rb[2] <= 8'h0A; rb_len <= 6'd3;
                cs    <= C_REPLY;
            end

            // an SD operation started by the menu: wait for the card engine
            C_SD_W: if (waited && !sd_busy) begin
                if (sd_err == 4'd0 && rq_cmd != 4'd1) rg_lba <= rg_lba + 32'd1;
                cs <= C_IDLE;
            end

            // ---- load (and verify): assemble words, write both dies, read each back ----
            C_LD_BYTE: if (ld_sd && waited && !sd_busy) begin
                ld_sd <= 1'b0;                       // the card gave up (sd_err says why)
                cs    <= C_IDLE;
            end else if (lb_valid && ld_skip != 8'd0) begin
                ld_skip <= ld_skip - 8'd1;
            end else if (lb_valid) begin
                ld_left <= ld_left - 24'd1;
                ld_end  <= (ld_left == 24'd1);
                ld_try  <= 4'd0;
                if (!ld_hi) begin
                    ld_lo   <= lb_data;
                    ld_word <= {8'hFF, lb_data};
                    ld_full <= 1'b0;
                    ld_hi   <= 1'b1;
                    if (ld_left == 24'd1) cs <= C_LD_WR;
                end else begin
                    ld_word <= {lb_data, ld_lo};
                    ld_full <= 1'b1;
                    ld_hi   <= 1'b0;
                    cs      <= C_LD_WR;
                end
            end
            C_LD_WR: if (!m_busy) begin
                ld_addr <= {ld_waddr, 1'b0};
                ld_din  <= ld_word;
                ld_wr   <= 1'b1;
                wait_go <= 1'b1;
                cs      <= C_LD_WW;
            end
            C_LD_WW: if (waited && !m_busy) cs <= C_LD_RD0;
            C_LD_RD0: if (!m_busy) begin
                ld_addr <= {ld_waddr, 1'b0};
                ld_dies <= 2'b01; ld_rd <= 1'b1; wait_go <= 1'b1; cs <= C_LD_RW0;
            end
            C_LD_RW0: if (m_valid0) rd0 <= m_dout0;
                      else if (waited && !m_busy) cs <= C_LD_RD1;
            C_LD_RD1: begin
                ld_dies <= 2'b10; ld_rd <= 1'b1; wait_go <= 1'b1; cs <= C_LD_RW1;
            end
            C_LD_RW1: if (m_valid1) rd1 <= m_dout1;
                      else if (waited && !m_busy) cs <= C_LD_CMP;
            C_LD_CMP: begin
                if (ld_verify) begin
                    ld_bad0 <= (rd0 != rd1);
                    ld_bad1 <= 1'b0;
                    ld_full <= (ld_left != 24'd1);
                    ld_end  <= (ld_left <= 24'd2);
                end else begin
                    ld_bad0 <= (rd0 != ld_word);
                    ld_bad1 <= (rd1 != ld_word);
                end
                cs <= C_LD_CHK;
            end
            C_LD_CHK: begin
                if (!ld_verify && (ld_bad0 || ld_bad1) && ld_try != 4'd15) begin
                    ld_try     <= ld_try + 4'd1;
                    ld_retries <= ld_retries + 16'd1;
                    cs         <= C_LD_WR;
                end else begin
                    if (ld_bad0 || ld_bad1) ld_fails <= ld_fails + 16'd1;
                    ld_sum   <= ld_sum + {24'd0, rd0[7:0]} + (ld_full ? {24'd0, rd0[15:8]} : 32'd0);
                    ld_waddr <= ld_waddr + 21'd1;
                    if (ld_verify) ld_left <= ld_left - (ld_full ? 24'd2 : 24'd1);
                    cs       <= ld_end ? C_LD_DONE : (ld_verify ? C_LD_RD0 : C_LD_BYTE);
                end
            end
            C_LD_DONE: begin
                rb[0] <= "O"; rb[1] <= "K"; rb[2] <= " ";
                for (k = 0; k < 8; k = k + 1) rb[3 + k] <= hexc(ld_sum[31 - 4*k -: 4]);
                rb[11] <= " ";
                for (k = 0; k < 4; k = k + 1) rb[12 + k] <= hexc(ld_retries[15 - 4*k -: 4]);
                rb[16] <= " ";
                for (k = 0; k < 4; k = k + 1) rb[17 + k] <= hexc(ld_fails[15 - 4*k -: 4]);
                rb[21] <= 8'h0A;
                rb_len <= 6'd22;
                cs     <= C_REPLY;
                if (ld_sd) begin                     // a block from the SD card: no reply
                    ld_sd    <= 1'b0;
                    rg_ldptr <= {ld_waddr, 1'b0};
                    cs       <= C_SD_W;
                end
            end

            // ---- statistics dump: 8 words ----
            C_ST_W: begin
                if (!rb_go) rb_go <= 1'b1;
                else if (rb_done) begin
                    rb_go <= 1'b0;
                    if (st_idx == 4'd8) begin
                        rb[0] <= 8'h0A; rb_len <= 6'd1;
                        cs <= C_REPLY;
                    end else begin
                        st_raddr <= st_idx[2:0];
                        wait_go  <= 1'b1;
                        cs       <= C_ST_F1;
                    end
                end
            end
            C_ST_F1: if (waited) begin
                st_val <= (st_idx >= 4'd5) ? st_misc : {8'd0, st_rdata};
                cs <= C_ST_F3;
            end
            C_ST_F3: begin
                for (k = 0; k < 8; k = k + 1) rb[k] <= hexc(st_val[31 - 4*k -: 4]);
                rb[8]  <= (st_idx[2:0] == 3'd7) ? 8'h0A : " ";
                rb_len <= 6'd9;
                st_idx <= st_idx + 4'd1;
                cs     <= C_ST_W;
            end

            // ---- trace dump: 512 x 9 hex digits ----
            C_TR_W: begin
                if (!rb_go) rb_go <= 1'b1;
                else if (rb_done) begin
                    rb_go <= 1'b0;
                    if (tr_idx == 10'd512) begin
                        rb[0] <= 8'h0A; rb_len <= 6'd1;
                        cs <= C_REPLY;
                    end else begin
                        tr_raddr <= tr_idx[8:0];
                        wait_go  <= 1'b1;
                        cs       <= C_TR_F;
                    end
                end
            end
            C_TR_F: if (waited) cs <= C_TR_OUT;
            C_TR_OUT: begin
                for (k = 0; k < 9; k = k + 1) rb[k] <= hexc(tr_rdata[35 - 4*k -: 4]);
                rb[9]  <= (tr_idx[2:0] == 3'd7) ? 8'h0A : " ";
                rb_len <= 6'd10;
                tr_idx <= tr_idx + 10'd1;
                cs     <= C_TR_W;
            end

            // ---- 'D': slot read-back, 16384 x 2 hex digits ----
            C_DB_W: begin
                if (!rb_go) rb_go <= 1'b1;
                else if (rb_done) begin
                    rb_go <= 1'b0;
                    if (db_left == 15'd0) begin
                        rb[0] <= 8'h0A; rb_len <= 6'd1;
                        cs <= C_REPLY;
                    end else begin
                        wait_go <= 1'b1;
                        cs      <= C_DB_F;
                    end
                end
            end
            C_DB_F: if (waited) cs <= C_DB_OUT;
            C_DB_OUT: begin
                rb[0]  <= hexc(dbg_data[7:4]); rb[1] <= hexc(dbg_data[3:0]);
                rb[2]  <= (dbg_addr[4:0] == 5'd31) ? 8'h0A : " ";
                rb_len <= 6'd3;
                dbg_addr <= dbg_addr + 16'd1;
                db_left  <= db_left - 15'd1;
                cs       <= C_DB_W;
            end

            default: cs <= C_IDLE;
            endcase

            // the menu's registers (6502, or 'W' from the UART)
            if (rgw) begin
                case (rgw_a)
                    // (ignored while a command is pending or running: a repeated
                    // write must never run a command twice)
                    4'h0: if (!rq_pend && !rq_run) begin rq_cmd <= rgw_d[3:0]; rq_pend <= 1'b1; end
                    4'h1: rg_lba[7:0]     <= rgw_d;
                    4'h2: rg_lba[15:8]    <= rgw_d;
                    4'h3: rg_lba[23:16]   <= rgw_d;
                    4'h4: rg_lba[31:24]   <= rgw_d;
                    4'h5: rg_ldptr[7:0]   <= rgw_d;
                    4'h6: rg_ldptr[15:8]  <= rgw_d;
                    4'h7: rg_ldptr[21:16] <= rgw_d[5:0];
                    default: mcfg[rgw_a[2:0]] <= rgw_d;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // LEDs (active low)
    //   0 heartbeat   1 cart enabled   2 loading / copying   3 holding HALT
    //   4 PHI2 activity   5 HALT (DMA) activity
    // ------------------------------------------------------------------
    reg [25:0] hb;
    reg [21:0] phi2_ctr, halt_ctr;
    reg        halt_s;
    reg [22:0] halt_led_ctr;
    always @(posedge clk) begin
        hb <= hb + 26'd1;
        halt_s <= halt;
        if (phi2_rise) phi2_ctr <= phi2_ctr + 22'd1;
        if (!halt_s)   halt_ctr <= halt_ctr + 22'd1;
        if (our_halt)  halt_led_ctr <= 23'h7FFFFF;          // stretch so a 200 us halt is visible
        else if (halt_led_ctr != 0) halt_led_ctr <= halt_led_ctr - 23'd1;
    end
    // Placement seed. The design fills the chip far enough that Gowin's placer
    // (deterministic for a given netlist) meets 67.5 MHz for some netlists and
    // misses by up to a nanosecond for functionally identical ones. These
    // flip-flops do nothing; their number only gives the placer another start.
    generate if (SEED > 0) begin : g_seed
        reg [SEED-1:0] seed_sr /* synthesis syn_preserve = 1 */;
        always @(posedge clk) seed_sr <= {seed_sr, hb[25]};
    end endgenerate
    assign led[0] = ~hb[25];
    assign led[1] = ~cart_en;
    assign led[2] = ~((cs >= C_LD_BYTE && cs <= C_LD_DONE) || cs == C_LD_CMP || cp_active);
    assign led[3] = ~(halt_led_ctr != 0);
    assign led[4] = ~phi2_ctr[21];
    assign led[5] = ~halt_ctr[21];
endmodule

`default_nettype wire
