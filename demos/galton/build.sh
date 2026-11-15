#!/bin/bash
# Build the Galton board demo: build/galton.a78 (header marked for the math unit)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export bas7800dir="${bas7800dir:-$HOME/Software/Atari7800/7800basic}"
export PATH="$bas7800dir:$PATH"
python3 "$HERE/mkgfx.py"
[ -f "$HERE/gfx/menufont.png" ] || cp "$HERE/../../menu/gfx/menufont.png" "$HERE/gfx/"
OUT="$HERE/build"; mkdir -p "$OUT/gfx"
cp "$HERE/galton.bas" "$HERE/physics.asm" "$OUT/"; cp "$HERE"/gfx/*.png "$OUT/gfx/"
cd "$OUT"
rm -f galton.bas.bin galton.bas.a78
"$bas7800dir/7800basic.sh" galton.bas > build.log 2>&1 || { tail -30 build.log; exit 1; }
if grep -q "Fatal assembly error" build.log; then grep -i -E "error" build.log | head; exit 1; fi
[ -f galton.bas.a78 ] || { tail -30 build.log; echo "no galton.bas.a78"; exit 1; }
cp galton.bas.a78 galton.a78
python3 "$HERE/../../tools/a78math.py" galton.a78
grep -i -E "error|unresolved|bytes of ROM" build.log | head -10 || true
