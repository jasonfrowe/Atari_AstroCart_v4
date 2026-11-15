#!/usr/bin/env python3
"""Split a 32K ROM ($8000-$FFFF; .bin, or .a78 with its 128-byte header) into
the four slot-BRAM init files the cart's bitstream loads:
    PREFIX_8e.hex / _8o.hex   even / odd bytes of $8000-$BFFF (slot 1)
    PREFIX_ce.hex / _co.hex   even / odd bytes of $C000-$FFFF (slot 2)

  rom2hex.py ROM PREFIX
"""
import sys

rom = open(sys.argv[1], "rb").read()
if rom[1:10] == b"ATARI7800":
    rom = rom[128:]
if len(rom) != 0x8000:
    sys.exit(f"{sys.argv[1]}: {len(rom)} bytes; the menu ROM must be exactly 32K")
for tag, part in (("8", rom[:0x4000]), ("c", rom[0x4000:])):
    for eo, k in (("e", 0), ("o", 1)):
        with open(f"{sys.argv[2]}_{tag}{eo}.hex", "w") as f:
            f.write("\n".join(f"{b:02x}" for b in part[k::2]) + "\n")
