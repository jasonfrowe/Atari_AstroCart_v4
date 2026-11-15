#!/bin/bash
# Build the menu ROM (32K, $8000-$FFFF) with 7800basic: build/menu.bin
#   build.sh        the real menu
#   build.sh emu    an emulator test build (build/emu/menu.bas.a78): fake game
#                   list, packaged as SuperGame + RAM so a7800 gives it RAM at $4000
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export bas7800dir="${bas7800dir:-$HOME/Software/Atari7800/7800basic}"
export PATH="$bas7800dir:$PATH"
OUT="$HERE/build"
[ "${1:-}" = emu ] && OUT="$HERE/build/emu"
mkdir -p "$OUT/gfx"
cp "$HERE/fat.asm" "$HERE/fat_emu.asm" "$OUT/"
cp "$HERE/gfx/menufont.png" "$OUT/gfx/"
if [ "${1:-}" = emu ]; then
    sed -e 's/jsr ac_init/jsr ac_fakeinit/' -e 's/jsr ac_info$/jsr ac_fakeinfo/' -e 's/include "fat.asm"/include "fat.asm"\
 include "fat_emu.asm"/' "$HERE/menu.bas" > "$OUT/menu.bas"
else
    cp "$HERE/menu.bas" "$OUT/"
fi
cd "$OUT"
rm -f menu.bas.bin menu.bas.a78 menu.bin 7800.asm
"$bas7800dir/7800basic.sh" menu.bas > build.log 2>&1 || { tail -30 build.log; exit 1; }
[ -f menu.bas.bin ] || { tail -30 build.log; echo "no menu.bas.bin"; exit 1; }
[ "$(wc -c < menu.bas.bin | tr -d ' ')" = 32768 ] || { echo "menu.bas.bin is not 32K"; exit 1; }
cp menu.bas.bin menu.bin
if [ "${1:-}" = emu ]; then
    # a7800 only gives a cart RAM at $4000 as "SuperGame + RAM": wrap the 32K
    # ROM as 8 banks (the $8000 half in banks 0-6, the $C000 half in bank 7)
    python3 - <<'PY'
d = bytearray(open("menu.bas.a78", "rb").read())
h, rom = d[:128], d[128:]
h[49:53] = (131072).to_bytes(4, "big")
h[53], h[54] = 0x00, 0x06
h[64], h[65] = 1, 1
open("menu.bas.a78", "wb").write(h + rom[:0x4000] * 7 + rom[0x4000:])
PY
fi
grep -i -E "error|bytes of ROM|unresolved" build.log | head -20 || true
ls -l "$OUT/menu.bin"
