#!/usr/bin/env python3
"""Fixed-point model of the gas-in-a-box demo, operation for operation as physics.asm
does it on the math unit (docs/MATHUNIT.md). Chooses the constants, writes the tables
for the build (tab.asm), and is what the 6502 code is checked against.

Positions and velocities: 16 bits signed, 6 fractional bits, 320A pixels (per frame).
"""
import math
import sys

NB = 12
XMIN, XMAX = 6 * 64, 313 * 64           # where a ball's centre turns back
YMIN, YMAX = 22 * 64, 122 * 64
CONTACT = 8 * 64                        # two radii
V0 = 112                                # everyone's speed at the start: 1.75 pixels/frame
WINDOW = 128                            # frames per histogram
NBIN = 8                                # speed bins, 32 units (1/2 pixel/frame) wide


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def tdiv(n, d):
    q = abs(n) // abs(d)
    return -q if (n < 0) != (d < 0) else q


def rnd8(p):
    return (p + 128) >> 8


class Rng:                              # the unit's generator
    def __init__(self, seed):
        self.x = 1
        for b in seed:
            self.x = ((self.x << 8) | b) & 0xFFFFFFFF
            if self.x == 0:
                self.x = 1

    def read(self):
        x = self.x
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        self.x = x
        return x & 255


DIRS = [(round(V0 * math.cos(2 * math.pi * (k + 0.5) / 16)), round(V0 * math.sin(2 * math.pi * (k + 0.5) / 16))) for k in range(16)]


X0 = [(40 + 80 * (i % 4)) * 64 for i in range(NB)]
Y0 = [(38 + 34 * (i // 4)) * 64 for i in range(NB)]


def init(seed=(0x12, 0xA7, 0x4E, 0x31)):
    r = Rng(seed)
    b = []
    for i in range(NB):
        d = r.read() & 15
        b.append([X0[i], Y0[i], DIRS[d][0], DIRS[d][1]])
    return b


def step(b, hist):
    for p in b:
        p[0] = s16(p[0] + p[2])
        p[1] = s16(p[1] + p[3])
        if p[0] < XMIN:
            p[0] = 2 * XMIN - p[0]; p[2] = -p[2]
        elif p[0] >= XMAX:
            p[0] = 2 * XMAX - p[0]; p[2] = -p[2]
        if p[1] < YMIN:
            p[1] = 2 * YMIN - p[1]; p[3] = -p[3]
        elif p[1] >= YMAX:
            p[1] = 2 * YMAX - p[1]; p[3] = -p[3]
    hits = 0
    for i in range(NB - 1):
        for j in range(i + 1, NB):
            dx = s16(b[i][0] - b[j][0])
            dy = s16(b[i][1] - b[j][1])
            if not (-512 <= dx < 512 and -512 <= dy < 512):
                continue
            r2 = dx * dx + dy * dy                  # 12 fractional bits
            r = math.isqrt(r2)
            if r >= CONTACT or r == 0:
                continue
            # apart: each moves half the overlap along d.  d * (CONTACT - r) / 2r
            m = tdiv((CONTACT - r) << 8, 2 * r)
            px, py = rnd8(m * dx), rnd8(m * dy)
            b[i][0] += px; b[i][1] += py
            b[j][0] -= px; b[j][1] -= py
            # equal masses, elastic: exchange the velocity along d.
            #   v_i -= k d,  v_j += k d,   k = (dv . d) / (d . d)
            # No unit vector: normalising with a truncating divide made every
            # collision lose about 2% of its energy.
            dvx = b[i][2] - b[j][2]
            dvy = b[i][3] - b[j][3]
            dvd = dvx * dx + dvy * dy
            if dvd >= 0:
                continue                             # already separating
            k = tdiv(dvd << 8, r2 >> 4)              # 12 fractional bits
            tx = (rnd8(k * dx) + 8) >> 4
            ty = (rnd8(k * dy) + 8) >> 4
            b[i][2] -= tx; b[i][3] -= ty
            b[j][2] += tx; b[j][3] += ty
            hits += 1
    for p in b:
        s = math.isqrt(p[2] * p[2] + p[3] * p[3])
        hist[min(s >> 5, NBIN - 1)] += 1
    return hits


def expected():
    """Fraction of balls in each speed bin for a 2-D gas with <v^2> = V0^2 (Rayleigh)."""
    out = []
    for k in range(NBIN):
        a, c = 32 * k, 32 * (k + 1)
        hi = math.exp(-c * c / V0 ** 2) if k < NBIN - 1 else 0.0
        out.append(math.exp(-a * a / V0 ** 2) - hi)
    return out


SCALE = 8                               # bar lines = samples in a window / SCALE

if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "state":      # the state after n steps, for the emulator check
        b = init()
        hist = [0] * NBIN
        for f in range(int(sys.argv[2])):
            step(b, hist)
        print(" | ".join(" ".join(str(v) for v in p) for p in b))
        sys.exit()
    if len(sys.argv) > 1 and sys.argv[1] == "asm":
        for nm, v in (("g_x0l", [x & 255 for x in X0]), ("g_x0h", [x >> 8 for x in X0]), ("g_y0l", [y & 255 for y in Y0]), ("g_y0h", [y >> 8 for y in Y0])):
            print(nm + "\n    .byte " + ",".join(str(x) for x in v))
        print("g_dirx\n    .byte " + ",".join(str(d[0] & 255) for d in DIRS))
        print("g_diry\n    .byte " + ",".join(str(d[1] & 255) for d in DIRS))
        ex = [round(f * NB * WINDOW / SCALE) for f in expected()]
        print("g_expect                ; where the theory puts each bar's top (lines)\n    .byte " + ",".join(str(e) for e in ex))
        sys.exit()
    b = init()
    hist = [0] * NBIN
    tot = [0] * NBIN
    e0 = sum(p[2] ** 2 + p[3] ** 2 for p in b)
    hits = 0
    for f in range(1, 60 * 300 + 1):
        hits += step(b, hist)
        if f % 3600 == 0:
            e = sum(p[2] ** 2 + p[3] ** 2 for p in b)
            print(f"{f // 60:4d} s: energy {e / e0:.3f} of the start, {hits} collisions so far, momentum {sum(p[2] for p in b)},{sum(p[3] for p in b)}")
        if f >= 1800:
            for k in range(NBIN):
                tot[k] += hist[k]
        for k in range(NBIN):
            hist[k] = 0
    n = sum(tot)
    print("measured:", " ".join(f"{t / n:.3f}" for t in tot))
    print("theory:  ", " ".join(f"{x:.3f}" for x in expected()))
    print("largest bar (lines):", max(round(f * NB * WINDOW / SCALE) for f in expected()))
