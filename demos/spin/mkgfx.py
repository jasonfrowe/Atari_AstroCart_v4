#!/usr/bin/env python3
"""Write the spin demo's sprites as 1-bit PNGs (320A) into gfx/. Standard library only."""
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))


def png(name, rows):
    h, w = len(rows), len(rows[0])
    raw = b""
    for r in rows:
        bits = "".join("1" if c == "#" else "0" for c in r).ljust((w + 7) // 8 * 8, "0")
        raw += b"\0" + bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))

    data = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 1, 3, 0, 0, 0)) +
            chunk(b"PLTE", bytes([0, 0, 0, 255, 255, 255])) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    open(os.path.join(HERE, "gfx", name + ".png"), "wb").write(data)


# Three sizes of dot (near, middle, far), each drawn at every height at which it fits in an
# 8-line zone: 4 + 6 + 7 = 17 sprites, dot0..dot16. A dot that fits in one zone is plotted
# there with the sprite that has it at the right height, and costs one display list entry;
# only one that crosses a zone boundary is plotted the usual way (the first of its size, in
# two zones). Plotting is what has to fit in vertical blank.
SHAPES = [["..####..", ".######.", ".######.", ".######.", "..####.."],
          ["..####..", "..####..", "..####.."],
          ["...##...", "...##..."]]
n = 0
for rows in SHAPES:
    for top in range(8 - len(rows) + 1):
        png(f"dot{n}", ["........"] * top + rows + ["........"] * (8 - top - len(rows)))
        n += 1
