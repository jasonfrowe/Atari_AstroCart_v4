#!/bin/bash
# Build the gas-in-a-box demo: build/gas.a78 (header marked for the math unit)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export bas7800dir="${bas7800dir:-$HOME/Software/Atari7800/7800basic}"
export PATH="$bas7800dir:$PATH"
python3 "$HERE/mkgfx.py"
[ -f "$HERE/gfx/menufont.png" ] || cp "$HERE/../../menu/gfx/menufont.png" "$HERE/gfx/"
OUT="$HERE/build"; mkdir -p "$OUT/gfx"
cp "$HERE/gas.bas" "$HERE/physics.asm" "$OUT/"
python3 "$HERE/model.py" asm > "$OUT/tab.asm"; cp "$HERE"/gfx/*.png "$OUT/gfx/"
cd "$OUT"
rm -f gas.bas.bin gas.bas.a78
"$bas7800dir/7800basic.sh" gas.bas > build.log 2>&1 || { tail -30 build.log; exit 1; }
if grep -q "Fatal assembly error" build.log; then grep -i -E "error" build.log | head; exit 1; fi
[ -f gas.bas.a78 ] || { tail -30 build.log; echo "no gas.bas.a78"; exit 1; }
cp gas.bas.a78 gas.a78
python3 "$HERE/../../tools/a78math.py" gas.a78
grep -i -E "error|unresolved|bytes of ROM" build.log | head -10 || true
