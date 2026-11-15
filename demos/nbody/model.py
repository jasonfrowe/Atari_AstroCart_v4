#!/usr/bin/env python3
"""Fixed-point model of the N-body demo, operation for operation as physics.asm does it
on the math unit (docs/MATHUNIT.md). Used to choose the constants and the scenarios, and
by build.sh to write the scenario tables (scen.asm).

Positions and velocities: signed, 14 fractional bits, in 320A pixels (and per frame),
kept in 24 bits. For the unit, positions are cut to 6 fractional bits (16 bits).
"""
import math
import sys

EPS = 5 * 64            # softening length, 6 fractional bits


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def s32(v):
    v &= 0xFFFFFFFF
    return v - 0x100000000 if v & 0x80000000 else v


def tdiv(n, d):         # the unit's signed divide: toward zero
    q = abs(n) // abs(d)
    return -q if (n < 0) != (d < 0) else q


def rnd8(p):            # (product + 128) >> 8, as g_phi does
    return (p + 128) >> 8


def step(b):
    """b: list of [x, y, vx, vy, K] (x.. in 14 fractional bits; K = GM * 2^26, unsigned 32 bits). One frame."""
    n = len(b)
    for i in range(n):
        for j in range(i + 1, n):
            dx = s16((b[j][0] >> 8) - (b[i][0] >> 8))
            dy = s16((b[j][1] >> 8) - (b[i][1] >> 8))
            if abs(dx) > 16383 or abs(dy) > 16383:      # farther than 256 pixels: skip the pair
                continue
            acc = s32(dx * dx + dy * dy + EPS * EPS)
            r = math.isqrt(acc & 0xFFFFFFFF)
            nx = s16(tdiv(dx << 8, r))
            ny = s16(tdiv(dy << 8, r))
            gmj = s16((b[j][4] // r) // r)              # GM / r^2, 14 fractional bits (unsigned divides)
            gmi = s16((b[i][4] // r) // r)
            b[i][2] += rnd8(gmj * nx)
            b[i][3] += rnd8(gmj * ny)
            b[j][2] -= rnd8(gmi * nx)
            b[j][3] -= rnd8(gmi * ny)
    for p in b:
        p[0] += p[2]
        p[1] += p[3]


F = 1 << 14


def circ(GM, r):        # circular orbit speed round GM at r pixels, with the softened force
    e = EPS / 64
    return math.sqrt(GM * r * r / (r * r + e * e) ** 1.5)


def scenarios():
    S = []
    # 1: a star and three planets (GM in pixels^3 / frame^2). Four bodies is what one frame has time for.
    b = [[160, 96, 0, 0, 50]]
    for r, ph, m in ((24, 0.3, 0.05), (44, 2.0, 0.1), (72, 4.0, 0.2)):
        v = circ(50, r)
        b.append([160 + r * math.cos(ph), 96 + r * math.sin(ph), -v * math.sin(ph), v * math.cos(ph), m])
    S.append(("STAR AND PLANETS", b))
    # 2: a binary star and two planets round both
    a = 13
    d = 2 * a               # each star circles the middle at radius a, pulled by the other at d
    v = math.sqrt(25 * d * a / (d * d + (EPS / 64) ** 2) ** 1.5)
    b = [[160 - a, 96, 0, -v, 25], [160 + a, 96, 0, v, 25]]
    for r, ph in ((62, 1.0), (86, 3.6)):
        vp = circ(50, r)
        b.append([160 + r * math.cos(ph), 96 + r * math.sin(ph), -vp * math.sin(ph), vp * math.cos(ph), 0.05])
    S.append(("BINARY STAR", b))
    # 3: three equal masses on the figure-eight (Chenciner and Montgomery), scaled
    L, m = 60.0, 24
    vs = math.sqrt(m / L)
    x1, y1, vx3, vy3 = 0.97000436, -0.24308753, -0.93240737, -0.86473146
    b = [[160 + L * x1, 96 + L * y1, -vx3 / 2 * vs, -vy3 / 2 * vs, m],
         [160 - L * x1, 96 - L * y1, -vx3 / 2 * vs, -vy3 / 2 * vs, m],
         [160, 96, vx3 * vs, vy3 * vs, m]]
    S.append(("FIGURE EIGHT", b))
    # 4: a star, a planet with a moon, and an inner planet
    b = [[160, 96, 0, 0, 50]]
    r, mp, rm = 72, 2.5, 8
    v = circ(50, r)
    b.append([160 + r, 96, 0, v, mp])
    b.append([160 + r + rm, 96, 0, v + circ(mp, rm), 0.02])
    b.append([160 - 26, 96, 0, -circ(50, 26), 0.05])
    S.append(("PLANET AND MOON", b))
    out = []
    for name, bb in S:
        # no drift: take out the centre-of-mass velocity
        M = sum(p[4] for p in bb)
        cvx = sum(p[2] * p[4] for p in bb) / M
        cvy = sum(p[3] * p[4] for p in bb) / M
        out.append((name, [[round(p[0] * F), round(p[1] * F), round((p[2] - cvx) * F), round((p[3] - cvy) * F), round(p[4] * 2 ** 26)] for p in bb]))
    return out


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "asm":
        sc = scenarios()
        print(f"NSCEN = {len(sc)}")
        print("scen_tab\n" + "\n".join(f"    .word scen{k}" for k in range(len(sc))))
        print("scen_name\n" + "\n".join(f"    .word scen{k}n" for k in range(len(sc))))
        for k, (name, bb) in enumerate(sc):
            print(f"scen{k}n\n    .byte \"{name.ljust(16)}\"")
            print(f"scen{k}\n    .byte {len(bb)}")
            for p in bb:
                v = []
                for q in p[:4]:
                    q &= 0xFFFFFF
                    v += [q & 255, (q >> 8) & 255, q >> 16]
                v += [(p[4] >> (8 * t)) & 255 for t in range(4)]
                print("    .byte " + ",".join(f"${x:02X}" for x in v))
        sys.exit()
    for name, bb in scenarios():
        b = [list(p) for p in bb]
        e = []
        lo = [1e9] * len(b); hi = [0] * len(b)
        off = 0
        for f in range(60 * 120):
            step(b)
            for i, p in enumerate(b):
                d = math.hypot(p[0] / F - 160, p[1] / F - 96)
                lo[i] = min(lo[i], d); hi[i] = max(hi[i], d)
                if not (0 <= p[0] / F < 320 and 0 <= p[1] / F < 192):
                    off += 1
        print(f"{name}: after 120 s, distance from centre min..max per body: " +
              ", ".join(f"{a:.0f}..{c:.0f}" for a, c in zip(lo, hi)) + f"; body-frames off screen {off}")
