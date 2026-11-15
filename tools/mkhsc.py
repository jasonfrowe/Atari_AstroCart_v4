#!/usr/bin/env python3
"""Make the High Score Cart's two files for the SD card.

  mkhsc.py "High Score Cartridge (9BE408D3).a78" OUTDIR

writes OUTDIR/ASTROCART/HSC.A78 (the HSC's 4K ROM, as the .a78 file given) and
OUTDIR/ASTROCART/HSC.SAV (its 2K of battery RAM, empty: all $FF). Copy the
ASTROCART folder to the root of the card. An existing HSC.SAV is left alone
(it holds your scores) unless --new is given.
"""
import os
import sys

args = [a for a in sys.argv[1:] if a != "--new"]
if len(args) != 2:
    sys.exit(__doc__)
src, out = args
d = open(src, "rb").read()
if d[1:10] != b"ATARI7800" or len(d) != 128 + 4096:
    sys.exit(f"{src}: not the High Score Cartridge ROM (an .a78 file of 128 + 4096 bytes)")
out = os.path.join(out, "ASTROCART")
os.makedirs(out, exist_ok=True)
open(os.path.join(out, "HSC.A78"), "wb").write(d)
sav = os.path.join(out, "HSC.SAV")
if os.path.exists(sav) and "--new" not in sys.argv:
    print(f"{sav} exists: kept")
else:
    open(sav, "wb").write(b"\xFF" * 2048)
print(f"{out}: HSC.A78 ({len(d)} bytes), HSC.SAV (2048 bytes)")
