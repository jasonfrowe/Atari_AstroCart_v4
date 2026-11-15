#!/bin/bash
# Build the math unit self-test: build/mathtest.a78 (header with the "ACM" bytes) and build/mathtest.bin
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
B="${bas7800dir:-$HOME/Software/Atari7800/7800basic}"
mkdir -p "$HERE/build"; cd "$HERE/build"
c++ -std=c++11 -O2 -o gen ../gen.cpp
./gen "${NVEC:-400}" > script.asm
cp ../mathtest.asm .
"$B/dasm" mathtest.asm -f3 -omathtest.bin -lmathtest.lst -smathtest.sym > dasm.log || { tail -20 dasm.log; exit 1; }
[ "$(wc -c < mathtest.bin | tr -d ' ')" = 32768 ] || { echo "mathtest.bin is not 32K"; tail dasm.log; exit 1; }
"$B/7800sign" -w mathtest.bin > sign.log 2>&1 || { cat sign.log; exit 1; }
python3 "$HERE/../../tools/a78math.py" --new mathtest.bin mathtest.a78 --title "AstroCart math unit test"
ls -l "$HERE/build/mathtest.a78"
