#!/bin/bash
# AstroCart V4: build the menu ROM and the FPGA bitstream, and optionally load it.
#
#   ./build.sh                 build only
#   ./build.sh sram            build, then load into the FPGA's SRAM (lost at power-off)
#   ./build.sh flash           build, then write to the FPGA's flash (kept; loaded at power-on)
#   ./build.sh sram  --no-build    load the bitstream that is already built
#   ./build.sh flash --no-build
#
# Needs: 7800basic (bas7800dir, default ~/Software/Atari7800/7800basic), the Gowin
# IDE (GOWIN_BIN, default /Applications/GowinIDE.app/...), python3, and
# openFPGALoader for sram / flash. Timing closes by placement: the build tries
# placement seeds until one has no timing violations (SEEDS="3 4 5" to choose).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FS="$HERE/hw/devcart/build/impl/pnr/devcart.fs"
target=""; build=1
for a in "$@"; do
    case "$a" in
        sram|flash) target=$a ;;
        --no-build) build=0 ;;
        *) sed -n '2,13p' "$0"; exit 2 ;;
    esac
done

if [ $build = 1 ]; then
    echo "== menu ROM (7800basic)"
    "$HERE/menu/build.sh"
    echo "== FPGA bitstream (Gowin; a few minutes per seed)"
    "$HERE/hw/devcart/build_clean.sh"
fi
[ -f "$FS" ] || { echo "no bitstream at $FS (a build without a clean seed removes it)"; exit 1; }
echo "bitstream: $FS"

case "$target" in
    sram)  echo "== loading into SRAM";  openFPGALoader -b tangnano9k "$FS" ;;
    flash) echo "== writing to flash";   openFPGALoader -b tangnano9k -f "$FS" ;;
    "")    echo "not loaded (./build.sh sram | flash --no-build to load it)" ;;
esac
