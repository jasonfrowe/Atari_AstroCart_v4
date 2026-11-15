#!/bin/bash
# Build the PSRAM lab bitstream for one clock configuration.
#   ./build.sh [f81|f94|f101|f108] [ckmode 0|1]
#     ckmode 0: original CK scheme, clk_p = +90 deg  (PSDA 0100)
#     ckmode 1: relaxed CK scheme,  clk_p = +270 deg (PSDA 1100)
# Output: build/<cfg>_<psda>/psram_lab.fs, plus a timing summary.
set -euo pipefail

CFG="${1:-f81}"
CKM="${2:-1}"
if [ "$CKM" = "0" ]; then PSDA=0100; else PSDA=1100; fi
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GOWIN_BIN="/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin"

case "$CFG" in
  f81)  FREQ=81000000;  LAT=3; IDIV=0; FBDIV=2;  ODIV=8; PERIOD=12.346 ;;
  f94)  FREQ=94500000;  LAT=4; IDIV=1; FBDIV=6;  ODIV=8; PERIOD=10.582 ;;
  f101) FREQ=101250000; LAT=4; IDIV=3; FBDIV=14; ODIV=8; PERIOD=9.877  ;;
  f108) FREQ=108000000; LAT=5; IDIV=0; FBDIV=3;  ODIV=8; PERIOD=9.259  ;;
  *) echo "unknown config $CFG"; exit 1 ;;
esac

OUT="$HERE/build/${CFG}_ck${CKM}"
mkdir -p "$OUT"

# Wrapper that fixes the lab's parameters for this build
cat > "$OUT/psram_lab_build.v" <<EOF
module psram_lab_build (
    input  wire clk27, output wire uart_txd, output wire [5:0] led,
    output wire [1:0] O_psram_ck, output wire [1:0] O_psram_ck_n,
    output wire [1:0] O_psram_cs_n, output wire [1:0] O_psram_reset_n,
    inout  wire [1:0] IO_psram_rwds, inout wire [15:0] IO_psram_dq
);
    psram_lab_top #(.FREQ($FREQ), .LATENCY($LAT), .PLL_IDIV($IDIV), .PLL_FBDIV($FBDIV),
                    .PLL_ODIV($ODIV), .PLL_PSDA("$PSDA"), .CK_MODE($CKM)) u (
        .clk27(clk27), .uart_txd(uart_txd), .led(led),
        .O_psram_ck(O_psram_ck), .O_psram_ck_n(O_psram_ck_n), .O_psram_cs_n(O_psram_cs_n),
        .O_psram_reset_n(O_psram_reset_n), .IO_psram_rwds(IO_psram_rwds), .IO_psram_dq(IO_psram_dq));
endmodule
EOF

cat > "$OUT/timing.sdc" <<EOF
create_clock -name clk27 -period 37.037 [get_ports {clk27}]
EOF

cat > "$OUT/build.tcl" <<EOF
set_device GW1NR-LV9QN88PC6/I5 -name GW1NR-9C
add_file -type verilog "$OUT/psram_lab_build.v"
add_file -type verilog "$HERE/psram_lab_top.v"
add_file -type verilog "$ROOT/rtl/psram/psram_ll.v"
add_file -type verilog "$ROOT/rtl/common/uart_tx.v"
add_file -type verilog "$ROOT/rtl/common/pll_main.v"
add_file -type cst "$HERE/psram_lab.cst"
add_file -type sdc "$OUT/timing.sdc"
set_option -top_module psram_lab_build
set_option -verilog_std v2001
set_option -output_base_name psram_lab
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -place_option 1
set_option -route_option 2
run all
EOF

cd "$OUT"
DYLD_LIBRARY_PATH="$GOWIN_BIN/../lib" DYLD_FRAMEWORK_PATH="$GOWIN_BIN/../lib" "$GOWIN_BIN/gw_sh" build.tcl > gowin.log 2>&1 || { tail -30 gowin.log; exit 1; }
FS="$OUT/impl/pnr/psram_lab.fs"
[ -f "$FS" ] || FS=""
[ -n "$FS" ] || { echo "no bitstream"; tail -30 gowin.log; exit 1; }
echo "bitstream: $FS  (target clk period $PERIOD ns)"
python3 -I "$HERE/timing_summary.py" "$OUT/impl/pnr/psram_lab_tr_content.html"
