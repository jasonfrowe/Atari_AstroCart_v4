#!/bin/bash
# Build the AstroCart V4 development cart (81 MHz, relaxed CK scheme).
# Output: build/impl/pnr/devcart.fs and a timing summary.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GOWIN_BIN="${GOWIN_BIN:-/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin}"
OUT="$HERE/build"
mkdir -p "$OUT"
cat > "$OUT/timing.sdc" <<SDC
create_clock -name clk27 -period 37.037 [get_ports {clk27}]
report_timing -setup -max_paths ${MAXPATHS:-25} -max_common_paths 1
SDC
# The menu ROM (32K) is the power-up content of the slot BRAMs. MENU_ROM
# defaults to the 7800basic menu; the simulation harness is the fallback.
MENU_ROM="${MENU_ROM:-$ROOT/menu/build/menu.bin}"
[ -f "$MENU_ROM" ] || MENU_ROM="$ROOT/sim/multicart/harness.bin"
[ -f "$MENU_ROM" ] || { echo "no menu ROM: build menu/ (or sim/multicart) first"; exit 1; }
echo "menu ROM: $MENU_ROM"
python3 "$ROOT/tools/rom2hex.py" "$MENU_ROM" "$OUT/menu"
sed -e "s|parameter MENU_HEX     = \"menu\"|parameter MENU_HEX     = \"$OUT/menu\"|" \
    -e "s|parameter SEED         = 0 |parameter SEED         = ${SEED:-0} |" \
    "$ROOT/rtl/dev/devcart_top.v" > "$OUT/devcart_top_build.v"
grep -q "parameter SEED         = ${SEED:-0} " "$OUT/devcart_top_build.v" || { echo "SEED not patched"; exit 1; }
echo "placement seed: ${SEED:-0}"
grep -q "$OUT/menu" "$OUT/devcart_top_build.v" || { echo "MENU_HEX not patched"; exit 1; }
cat > "$OUT/build.tcl" <<TCL
set_device GW1NR-LV9QN88PC6/I5 -name GW1NR-9C
add_file -type verilog "$OUT/devcart_top_build.v"
add_file -type verilog "$ROOT/rtl/cart/cart_bus.v"
add_file -type verilog "$ROOT/rtl/psram/psram_dual.v"
add_file -type verilog "$ROOT/rtl/psram/psram_ll.v"
add_file -type verilog "$ROOT/rtl/common/uart_tx.v"
add_file -type verilog "$ROOT/rtl/common/uart_rx.v"
add_file -type verilog "$ROOT/rtl/common/pll_main.v"
add_file -type verilog "$ROOT/rtl/audio/pokey.v"
add_file -type verilog "$ROOT/rtl/audio/audio_pwm.v"
add_file -type verilog "$ROOT/rtl/sd/sd_spi.v"
add_file -type verilog "$ROOT/rtl/math/astromath.v"
add_file -type cst "$HERE/devcart.cst"
add_file -type sdc "$OUT/timing.sdc"
set_option -top_module devcart_top
set_option -verilog_std v2001
set_option -output_base_name devcart
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1
set_option -place_option ${PLACE:-1}
set_option -route_option ${ROUTE:-2}
run all
TCL
cd "$OUT"
DYLD_LIBRARY_PATH="$GOWIN_BIN/../lib" DYLD_FRAMEWORK_PATH="$GOWIN_BIN/../lib" \
    "$GOWIN_BIN/gw_sh" build.tcl > gowin.log 2>&1 || { grep -E 'ERROR' gowin.log | head -20; tail -5 gowin.log; exit 1; }
echo "bitstream: $OUT/impl/pnr/devcart.fs"
python3 -I "$ROOT/lab/psram_lab/timing_summary.py" "$OUT/impl/pnr/devcart_tr_content.html"
grep -E 'ERROR|WARN' gowin.log | grep -v -E 'EX3780|EX3791' | head -15 || true
