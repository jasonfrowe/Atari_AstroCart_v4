#!/usr/bin/env python3
"""The spin demo's shapes and arithmetic (transform.asm), in floating point.

  model.py asm          the shape tables for the build (tab.asm)
  model.py              where the dots can go: screen range, most dots in one zone
  model.py check FILE   compare lines dumped from the emulator (run_emu.sh) with this model

The trig block is not exact (docs/MATHUNIT.md: within 1.45 of the true rotation, in
units of 1/256 here), so the check allows one pixel.
"""
import math
import sys

NP = 32
DIST64 = 280 * 64       # the eye is 280 units in front of the centre; D = z/4 + DIST64 (z in 1/256)
FX, FY = 35, 60         # screen = centre + coordinate(1/256) * F / D; a 160-wide pixel is 1.714 lines wide
CX, CY = 80, 106
LIM = 72                # every coordinate of every shape: a morph stays inside the cube of +-72,
                        # whose corner is 124.7 from the centre, and a rotated 8.8 number must fit 16 bits


def cube():
    c, pts = 48, []
    for x in (-c, c):
        for y in (-c, c):
            for z in (-c, c):
                pts.append((x, y, z))
    for a in (-c, c):
        for b in (-c, c):
            for t in (-16, 16):
                pts += [(t, a, b), (a, t, b), (a, b, t)]
    return pts


def sphere():
    pts, g = [], math.pi * (3 - math.sqrt(5))
    for i in range(NP):
        y = 1 - (2 * i + 1) / NP
        r = math.sqrt(1 - y * y)
        pts.append((72 * r * math.cos(g * i), 72 * y, 72 * r * math.sin(g * i)))
    return pts


def torus():
    pts = []
    for i in range(8):
        for j in range(4):
            u, v = 2 * math.pi * i / 8, 2 * math.pi * (j + i / 2) / 4
            r = 50 + 20 * math.cos(v)
            pts.append((r * math.cos(u), 20 * math.sin(v), r * math.sin(u)))
    return pts


def helix():
    pts = []
    for s in (0, 1):
        for i in range(16):
            u = 2 * math.pi * i / 10 + s * math.pi
            pts.append((40 * math.cos(u), -72 + 144 * i / 15, 40 * math.sin(u)))
    return pts


SHAPES = [("CUBE", cube()), ("SPHERE", sphere()), ("TORUS", torus()), ("HELIX", helix())]
SHAPES = [(n, [tuple(int(round(c)) for c in p) for p in pts]) for n, pts in SHAPES]
for n, pts in SHAPES:
    assert len(pts) == NP and all(abs(c) <= LIM for p in pts for c in p), n


def project(p, a, b):
    """p in units, a and b in 65536ths of a turn -> (sprite x, sprite y, level index) as transform.asm."""
    x, y, z = (c * 256 for c in p)
    ta, tb = 2 * math.pi * a / 65536, 2 * math.pi * b / 65536
    x1 = x * math.cos(ta) - z * math.sin(ta)
    z1 = x * math.sin(ta) + z * math.cos(ta)
    y2 = y * math.cos(tb) - z1 * math.sin(tb)
    z2 = y * math.sin(tb) + z1 * math.cos(tb)
    d = math.floor(z2 / 4) + DIST64
    qx = math.floor(x1 * FX / d)
    qy = max(-84, min(80, math.floor(y2 * FY / d)))
    return CX - 2 + qx, CY + qy, (int(math.floor(z2 / 256)) + 128) >> 4


SIZE = [0] * 6 + [1] * 4 + [2] * 6          # by level: big, middle, small
HEIGHT = [5, 3, 2]
ABOVE = [2, 1, 1]                           # lines of the dot above its centre line
FIRST = [0, 4, 10]                          # the first sprite of each size


def zones(cy, level):
    """the zones the dot gets a display list entry in"""
    top = cy - ABOVE[SIZE[level]]
    if (top & 7) + HEIGHT[SIZE[level]] <= 8:
        return [top >> 3]
    return [top >> 3, (top >> 3) + 1]


def asm():
    for k, axis in enumerate("xyz"):
        print(f"shp_{axis}")
        for n, pts in SHAPES:
            print("    .byte " + ",".join(str(p[k] + 128) for p in pts) + f"    ; {n}")


def survey():
    lo = [999, 999]
    hi = [-999, -999]
    most = entries = poses = 0
    for n, pts in SHAPES:
        zmax = 0
        for a in range(0, 65536, 1024):
            for b in range(0, 65536, 1024):
                zone = [0] * 24
                for p in pts:
                    sx, sy, lv = project(p, a, b)
                    lo = [min(lo[0], sx), min(lo[1], sy)]
                    hi = [max(hi[0], sx), max(hi[1], sy)]
                    for zn in zones(sy, lv):
                        zone[zn] += 1
                        entries += 1
                poses += 1
                zmax = max(zmax, max(zone))
        most = max(most, zmax)
        print(f"{n:7s} most dots in one zone {zmax}")
    print(f"sprite x {lo[0]}..{hi[0]}, centre line {lo[1]}..{hi[1]}; most in a zone {most}; "
          f"{entries / poses:.1f} display list entries a frame")


def check(path):
    ok = bad = 0
    for line in open(path):
        if not line.startswith("SPIN "):
            continue
        v = [int(t, 16) for t in line.split()[1:]]
        a, b = v[0], v[1]
        cur, got, pf = v[2:2 + 3 * NP], v[2 + 3 * NP:2 + 5 * NP], v[2 + 5 * NP:]
        worst = 0
        for i in range(NP):
            p = tuple(cur[k * NP + i] - 128 for k in range(3))
            sx, sy, lv = project(p, a, b)
            f = pf[i] & 31                      # which sprite: its size, and how far down the dot is in it
            size = 0 if f < 4 else 1 if f < 10 else 2
            centre = got[NP + i] + f - FIRST[size] + ABOVE[size]
            worst = max(worst, abs(sx - got[i]), abs(sy - centre))
        if worst <= 1:
            ok += 1
        else:
            bad += 1
        print(f"A={a:04X} B={b:04X}: worst difference {worst} pixel(s)")
    print(f"{ok} frames agree, {bad} do not")
    return 0 if ok and bad <= 1 else 1      # (one dump may land in the middle of a step)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "asm":
        asm()
    elif len(sys.argv) > 2 and sys.argv[1] == "check":
        sys.exit(check(sys.argv[2]))
    else:
        survey()
