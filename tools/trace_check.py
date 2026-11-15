#!/usr/bin/env python3
"""Compare a bus trace (devcart.py trace dump FILE) with the cart image.

  trace_check.py GAME.a78 TRACE.txt [--bank N] [-v]

The trace stores the bus data at the moment the address changes, i.e. the
data that was on the bus for the PREVIOUS address. Each read held >= 5 clocks
is checked against the ROM: fixed banks directly, the $8000 slot against bank
N (default: whichever bank fits best). CPU reads (HALT high) and MARIA DMA
reads (HALT low) are reported separately. sg9 layout only (Gamma Force).
"""
import argparse, re, collections

ap = argparse.ArgumentParser()
ap.add_argument("rom"); ap.add_argument("trace"); ap.add_argument("--bank", type=int)
ap.add_argument("-v", action="store_true", help="list every mismatch")
a = ap.parse_args()
rom = open(a.rom, "rb").read()[128:]
nb = len(rom) // 16384

def romb(addr, bank):
    if 0x4000 <= addr < 0x8000: return rom[addr - 0x4000]
    if addr >= 0xC000: return rom[(nb - 1) * 16384 + addr - 0xC000]
    if addr >= 0x8000: return rom[bank * 16384 + addr - 0x8000]
    return None

ent = []
for ln in open(a.trace):
    m = re.match(r"\s*(\d+)\s+\d+\s+\d+\s+(\S)\s+(\S)\s+(\S)\s+\$([0-9A-F]{4})\s+([0-9A-F]{2})", ln)
    if m: ent.append((int(m[1]), m[2] == "L", m[3] == "R", m[4] == "P", int(m[5], 16), int(m[6], 16)))
reads = []          # (dma, addr, data, hold)
for i in range(len(ent) - 1):
    t, low, rd, ours, ad, _ = ent[i]
    hold = ent[i + 1][0] - t
    if rd and not ours and hold >= 5 and ad >= 0x4000 and ent[i + 1][2]:
        reads.append((low, ad, ent[i + 1][5], hold))
def score(bank):
    return sum(1 for _, ad, d, _ in reads if 0x8000 <= ad < 0xC000 and romb(ad, bank) == d)
bank = a.bank if a.bank is not None else max(range(nb), key=score)
print(f"{len(ent)} entries, {len(reads)} cart reads held >= 5 clocks; $8000 slot checked against bank {bank}"
      + ("" if a.bank is not None else " (best fit)"))
for dma in (False, True):
    for name, lo, hi in (("$4000 fixed", 0x4000, 0x8000), ("$8000 slot", 0x8000, 0xC000), ("$C000 fixed", 0xC000, 0x10000)):
        sel = [(ad, d, h) for l, ad, d, h in reads if l == dma and lo <= ad < hi]
        bad = [(ad, d, romb(ad, bank), h) for ad, d, h in sel if romb(ad, bank) != d]
        print(f"  {'MARIA' if dma else 'CPU  '} {name:12s}: {len(sel) - len(bad):4d} ok, {len(bad):4d} wrong")
        if bad:
            bits = collections.Counter(b for _, d, r, _ in bad for b in range(8) if (d ^ r) >> b & 1)
            print("        wrong bits:", " ".join(f"D{b}:{n}" for b, n in sorted(bits.items())),
                  "| holds of wrong reads:", sorted(collections.Counter(h for *_, h in bad).items()))
            for ad, d, r, h in (bad if a.v else bad[:8]):
                print(f"        ${ad:04X} bus {d:02X} rom {r:02X} (held {h} clk)")
holds = collections.Counter(h for l, _, _, h in reads if l)
if holds: print("  MARIA hold times (clk:count):", sorted(holds.items()))
