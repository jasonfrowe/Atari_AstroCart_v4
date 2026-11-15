// ============================================================================
// pll_main -- 27 MHz -> clk (PSRAM/bus clock) + clk_p (phase-shifted copy
// for the PSRAM CK pins). fout = 27 * (FBDIV+1) / (IDIV+1); the VCO
// (fout * ODIV) must stay within 400..1200 MHz.
//
//   67.50 MHz: IDIV 1, FBDIV  4, ODIV 8   (PSRAM LATENCY 3)  <- devcart
//   81.00 MHz: IDIV 0, FBDIV  2, ODIV 8   (PSRAM LATENCY 3)  <- psram_lab
//   94.50 MHz: IDIV 1, FBDIV  6, ODIV 8   (LATENCY 4)
//  101.25 MHz: IDIV 3, FBDIV 14, ODIV 8   (LATENCY 4)
//  108.00 MHz: IDIV 0, FBDIV  3, ODIV 8   (LATENCY 5)
//
// PSDA is the clk_p phase in 22.5 degree steps ("0100" = 90 degrees).
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

module pll_main #(
    parameter IDIV  = 0,
    parameter FBDIV = 2,
    parameter ODIV  = 8,
    parameter PSDA  = "0100"
) (
    input  wire clkin,
    output wire clkout,
    output wire clkoutp,
    output wire lock
);
`ifdef VERILATOR
    /* verilator lint_off UNUSEDPARAM */
    assign clkout  = clkin;
    assign clkoutp = clkin;
    assign lock    = 1'b1;
`else
    wire unused_d, unused_d3;
    rPLL #(
        .FCLKIN("27"),
        .DEVICE("GW1NR-9C"),
        .IDIV_SEL(IDIV),
        .FBDIV_SEL(FBDIV),
        .ODIV_SEL(ODIV),
        .DYN_SDIV_SEL(2),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"),
        .CLKOUTP_BYPASS("false"),
        .CLKOUTD_BYPASS("false"),
        .DYN_DA_EN("false"),
        .DUTYDA_SEL("1000"),
        .PSDA_SEL(PSDA),
        .CLKOUT_FT_DIR(1'b1),
        .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0),
        .CLKOUTP_DLY_STEP(0),
        .CLKOUTD_SRC("CLKOUT"),
        .CLKOUTD3_SRC("CLKOUT")
    ) pll_inst (
        .CLKIN(clkin), .CLKOUT(clkout), .CLKOUTP(clkoutp),
        .CLKOUTD(unused_d), .CLKOUTD3(unused_d3), .LOCK(lock),
        .RESET(1'b0), .RESET_P(1'b0), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );
`endif
endmodule

`default_nettype wire
