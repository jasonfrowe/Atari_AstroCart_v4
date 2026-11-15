#!/usr/bin/env python3
"""Soak test of the PSRAM -> BRAM slot copy (cart off, no Atari needed).

  slot_soak.py GAME.a78 [N]

Copies random banks into the $8000 slot N times (default 100) the way a bank
switch does, reads the slot back each time and compares it with the image.
"""
import sys, os, time, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import devcart as dc

c = dc.parse_a78(sys.argv[1])
n = int(sys.argv[2]) if len(sys.argv) > 2 else 100
p = dc.Port(dc.default_port()); dc.sync(p)
nb = len(c.image) // 16384
bad_total = 0
for i in range(n):
    b = random.randrange(nb)
    p.write(bytes([ord("K"), b])); p.readline(); time.sleep(0.03)
    p.write(bytes([ord("D"), 2]))
    r = p.readline() if False else None
    got = p.read_until(b"@", 16384, timeout=30)
    bad = [k for k in range(16384) if got[k] != c.image[b * 16384 + k]]
    bad_total += len(bad)
    if bad:
        print(f"  copy {i + 1}: bank {b}: {len(bad)} wrong bytes, first at ${0x8000 + bad[0]:04X}")
print(f"{n} copies, {n * 16384} bytes compared: {bad_total} wrong")
