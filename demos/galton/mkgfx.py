#!/usr/bin/env python3
"""Write the Galton board's sprites as 1-bit PNGs (320A: one colour) into gfx/. Standard library only."""
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


png("ball", ["..####..", ".######.", "########", "########", "########", "########", ".######.", "..####.."])
png("peg", ["........", "........", "...##...", "..####..", "..####..", "...##...", "........", "........"])
for n in (2, 4, 6, 8):                       # a bin's bar: the bottom n lines of a 24 x 8 cell
    png(f"bar{n}", ["." * 24] * (8 - n) + ["#" * 23 + "."] * n)
