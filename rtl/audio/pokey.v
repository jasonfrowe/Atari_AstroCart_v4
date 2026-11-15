// ============================================================================
// pokey -- the sound half of the Atari POKEY (C012294), for 7800 carts.
//
// Modelled (after the Altirra hardware reference):
//   * four 8-bit dividers; base clock 64 kHz (1.79 MHz / 28) or 15 kHz (/ 114)
//     (AUDCTL bit 0), channels 1 and 3 optionally on 1.79 MHz (bits 6, 5)
//   * the reload delay: a divider that counts out reloads 3 cycles of the
//     1.79 MHz clock later, so the period is N+1 base clocks, N+4 cycles at
//     1.79 MHz, and N+7 for a joined 16-bit pair at 1.79 MHz
//   * joined pairs 1+2 and 3+4 (bits 4, 3): the high channel is clocked by the
//     low one's count-out, both reload on the high one's; the pair's sound
//     comes out of the HIGH channel (2 or 4), the low one keeps pulsing every
//     256 counts
//   * AUDC distortion: bit 7 = 0 gates the pulse with the 5-bit poly; bit 5
//     = 1 toggles the output (pure tone), else it takes the 4-bit poly (bit 6
//     = 1) or the 17/9-bit poly (bit 6 = 0; AUDCTL bit 7 picks 9 bits)
//   * volume-only (AUDC bit 4), high-pass filters (AUDCTL bits 2, 1: channel
//     1 XOR its value latched at channel 3's pulse; 2 with 4)
//   * STIMER ($9) reloads all dividers; SKCTL bits 1:0 = 00 holds the polys
//     and the 64/15 kHz prescalers in reset (RANDOM reads $FF: 7800basic's
//     POKEY detection relies on it)
//   * RANDOM ($A): the top 8 bits of the 17-bit poly; other reads $FF
//   * two-tone mode (SKCTL bit 3), as far as sound goes: channel 2's pulse
//     also reloads channel 1's divider -- channel 1 is hard-synced to
//     channel 2. (With the serial output at 1, channel 1 would also reload
//     channel 2; games set force-break, SKCTL = $8B, which holds it at 0.)
//     ARTI's music uses it for its bass.
// Not modelled: serial port, keyboard, pots, IRQs, the per-channel poly tap
// offsets, the non-linear output mixing.
//
// `tick` is the 1.79 MHz clock enable (one clk wide).
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

module pokey (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tick,

    input  wire       we,           // register write strobe
    input  wire [3:0] waddr,
    input  wire [7:0] wdata,
    input  wire [3:0] raddr,
    output reg  [7:0] rdata,        // combinational

    output reg  [7:0] audio_out     // sum of the four channel levels * 4 (0..240)
);
    reg [7:0] audf [0:3];
    reg [7:0] audc [0:3];
    reg [7:0] audctl;
    reg [1:0] skinit;               // SKCTL bits 1:0
    reg       twotone;              // SKCTL bit 3
    wire      init   = (skinit == 2'b00);
    wire      stimer = we && (waddr == 4'h9);

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin audf[i] <= 8'h00; audc[i] <= 8'h00; end
            audctl <= 8'h00; skinit <= 2'b00; twotone <= 1'b0;
        end else if (we) begin
            case (waddr)
                4'h0: audf[0] <= wdata;
                4'h1: audc[0] <= wdata;
                4'h2: audf[1] <= wdata;
                4'h3: audc[1] <= wdata;
                4'h4: audf[2] <= wdata;
                4'h5: audc[2] <= wdata;
                4'h6: audf[3] <= wdata;
                4'h7: audc[3] <= wdata;
                4'h8: audctl  <= wdata;
                4'hF: begin skinit <= wdata[1:0]; twotone <= wdata[3]; end
                default: ;
            endcase
        end
    end

    // ---- 64 kHz / 15 kHz prescalers and the polys (all on 1.79 MHz) ----
    reg [4:0]  div28;
    reg [6:0]  div114;
    reg [3:0]  poly4;
    reg [4:0]  poly5;
    reg [16:0] poly17;
    wire       fb17 = poly17[0] ^ poly17[5];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div28 <= 5'd0; div114 <= 7'd0;
            poly4 <= 4'hF; poly5 <= 5'h1F; poly17 <= 17'h1FFFF;
        end else if (init) begin
            div28 <= 5'd0; div114 <= 7'd0;
            poly4 <= 4'hF; poly5 <= 5'h1F; poly17 <= 17'h1FFFF;
        end else if (tick) begin
            div28  <= (div28  == 5'd27)  ? 5'd0 : div28  + 5'd1;
            div114 <= (div114 == 7'd113) ? 7'd0 : div114 + 7'd1;
            poly4  <= {poly4[2:0], poly4[3] ^ poly4[2]};
            poly5  <= {poly5[3:0], poly5[4] ^ poly5[2]};
            // 9-bit mode: the feedback also enters at bit 8
            poly17 <= {fb17, poly17[16:10], (audctl[7] ? fb17 : poly17[9]), poly17[8:1]};
        end
    end
    wire base = audctl[0] ? (div114 == 7'd0) : (div28 == 5'd0);   // qualified by tick below
    wire noise17 = poly17[0];

    // ---- dividers ----
    reg [7:0] cnt [0:3];
    reg [2:0] dly [0:3];            // count-out -> pulse, 3 cycles of 1.79 MHz
    reg [3:0] out;                  // the channels' output flip-flops
    reg       hp1, hp2;             // high-pass latches

    wire link12 = audctl[4];
    wire link34 = audctl[3];
    wire [3:0] pulse = {dly[3][2], dly[2][2], dly[1][2], dly[0][2]};
    wire [3:0] ce;                  // count enables (valid with tick)
    assign ce[0] = audctl[6] ? 1'b1     : base;
    assign ce[1] = link12    ? pulse[0] : base;
    assign ce[2] = audctl[5] ? 1'b1     : base;
    assign ce[3] = link34    ? pulse[2] : base;
    wire [3:0] reload = {pulse[3], link34 ? pulse[3] : pulse[2], pulse[1],
                         (link12 ? pulse[1] : pulse[0]) || (twotone && pulse[1])};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin cnt[i] <= 8'h00; dly[i] <= 3'b000; end
            out <= 4'b0000; hp1 <= 1'b0; hp2 <= 1'b0;
        end else if (stimer) begin
            for (i = 0; i < 4; i = i + 1) begin cnt[i] <= audf[i]; dly[i] <= 3'b000; end
        end else if (tick) begin
            for (i = 0; i < 4; i = i + 1) begin
                dly[i] <= {dly[i][1:0], ce[i] && (cnt[i] == 8'h00)};
                if (reload[i])  cnt[i] <= audf[i];
                else if (ce[i]) cnt[i] <= cnt[i] - 8'd1;
                if (pulse[i] && (audc[i][7] || poly5[4])) begin
                    if (audc[i][5])      out[i] <= ~out[i];
                    else if (audc[i][6]) out[i] <= poly4[3];
                    else                 out[i] <= noise17;
                end
            end
            if (pulse[2]) hp1 <= out[0];
            if (pulse[3]) hp2 <= out[1];
        end
    end

    // ---- output ----
    wire [3:0] snd = {out[3], out[2],
                      audctl[1] ? (out[1] ^ hp2) : out[1],
                      audctl[2] ? (out[0] ^ hp1) : out[0]};
    reg [4:0] mix01, mix23;
    reg [5:0] mix;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mix01 <= 5'd0; mix23 <= 5'd0; mix <= 6'd0; audio_out <= 8'h00;
        end else begin
            mix01 <= ((audc[0][4] || snd[0]) ? {1'b0, audc[0][3:0]} : 5'd0) +
                     ((audc[1][4] || snd[1]) ? {1'b0, audc[1][3:0]} : 5'd0);
            mix23 <= ((audc[2][4] || snd[2]) ? {1'b0, audc[2][3:0]} : 5'd0) +
                     ((audc[3][4] || snd[3]) ? {1'b0, audc[3][3:0]} : 5'd0);
            mix       <= {1'b0, mix01} + {1'b0, mix23};
            audio_out <= {mix, 2'b00};
        end
    end

    always @(*) begin
        case (raddr)
            4'hA:    rdata = poly17[16:9];
            default: rdata = 8'hFF;
        endcase
    end
endmodule

`default_nettype wire
