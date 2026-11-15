#!/usr/bin/env python3
"""Check the orbit game's log from the emulator (run_emu.sh).

PATH lines: frame, x, y (1/32 line), vx, vy (1/8192 line per frame) of a probe. From the first
line the same motion is followed in floating point (v += a, then p += v, with a = GM / r^2
toward the star) and compared. COUNTS: a point for player 2 only. FPS: no frame dropped.
"""
import math
import sys

GM = 40.0
path, counts, fps = [], None, None
for line in open(sys.argv[1]):
    if line.startswith("PATH "):
        path.append([int(t) for t in line.split()[1:]])
    elif line.startswith("COUNTS "):
        counts = line.strip()
    elif line.startswith("FPS "):
        fps = line.strip()

ok = True
if len(path) < 100:
    print(f"only {len(path)} PATH lines"); sys.exit(1)
t0, x, y, vx, vy = path[0]
x, y, vx, vy = x / 32, y / 32, vx / 8192, vy / 8192
worst, rmin, rmax, k = 0.0, 1e9, 0.0, 1
for step in range(t0 + 1, path[-1][0] + 1):
    r = math.hypot(x, y)
    a = GM / (r * r)
    vx -= a * x / r
    vy -= a * y / r
    x += vx
    y += vy
    while k < len(path) and path[k][0] < step:
        k += 1
    if k < len(path) and path[k][0] == step:
        gx, gy = path[k][1] / 32, path[k][2] / 32
        worst = max(worst, math.hypot(gx - x, gy - y))
        rmin, rmax = min(rmin, math.hypot(gx, gy)), max(rmax, math.hypot(gx, gy))
print(f"probe followed for {path[-1][0] - t0} frames, {rmin:.1f} to {rmax:.1f} lines from the star; "
      f"furthest from the floating-point path: {worst:.2f} lines")
if worst > 3:
    ok = False
print(counts)
if not counts or "scores 00 01 flying 1 0 text 00 01" not in counts:
    ok = False
print(fps)
if fps != "FPS 600 steps in 600 frames":
    ok = False
print("ORBIT CHECK PASSED" if ok else "ORBIT CHECK FAILED")
sys.exit(0 if ok else 1)
