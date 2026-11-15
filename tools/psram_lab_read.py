#!/usr/bin/env python3
"""Decode lab/psram_lab UART records (see psram_lab_top.v for the format).

  live:  python3 tools/psram_lab_read.py --port /dev/cu.usbserial-11201 --freq 81000000
  file:  python3 tools/psram_lab_read.py --file capture.txt --freq 81000000

Standard library only (no pyserial): the port is configured with termios.
"""
import argparse
import os
import sys
import termios
import time

NWORDS = 115
MODES = {0: "die0", 1: "die1", 2: "race"}
LAT_BASE = 6


def parse_records(text):
    recs = []
    for chunk in text.split("@")[1:]:
        toks = chunk.split()
        if len(toks) < NWORDS:
            continue  # incomplete (still arriving)
        try:
            w = [int(t, 16) for t in toks[:NWORDS]]
        except ValueError:
            continue
        if (w[0] >> 24) != 0xA5:
            continue
        recs.append(w)
    return recs


def summarize(w, freq, out=sys.stdout):
    mode = (w[0] >> 16) & 0x3
    period = (w[0] >> 8) & 0xFF
    rnd = w[0] & 0xFF
    ns = 1e9 / freq
    reads, e0, e1, tmo = w[97], w[98], w[99], w[100]
    banks = {"die0": w[1:33], "die1": w[33:65], "race": w[65:97]}
    show = {0: ["die0"], 1: ["die1"], 2: ["die0", "die1", "race"]}[mode]
    spacing = "back-to-back" if period == 0 else f"every {period} cyc ({period * ns:.0f} ns)"
    print(f"round {rnd:3d}  mode {MODES.get(mode, mode):4s}  {spacing:28s} reads {reads:8d}  "
          f"err0 {e0}  err1 {e1}  timeouts {tmo}", file=out)
    if e0 or e1:
        a = w[101]
        print(f"    first bad: die{a >> 31} word 0x{a & 0x1FFFFF:06X}  got 0x{w[102] >> 16:04X} "
              f"expected 0x{w[102] & 0xFFFF:04X}", file=out)
    for b in show:
        h = banks[b]
        tot = sum(h)
        if not tot:
            continue
        parts = []
        for i, c in enumerate(h):
            if c:
                cyc = i + LAT_BASE
                tag = ("<=" if i == 0 else ">=" if i == 31 else "")
                parts.append(f"{tag}{cyc}cyc/{cyc * ns:.0f}ns: {c} ({100.0 * c / tot:.4f}%)")
        print(f"    {b:4s} " + "  ".join(parts), file=out)
    if len(w) >= 112:
        print(f"    fill: writes {w[105]}  2x-path die0 {w[106]} die1 {w[107]}  verify-fail die0 {w[108]} "
              f"die1 {w[109]}  (of which 2x-path {w[110]})  still bad after retries {w[111]}", file=out)
    if len(w) >= 115:
        def tr(v):
            return " ".join(f"c{c + 1}:{(v >> (14 - 2 * c)) & 1}{(v >> (15 - 2 * c)) & 1}" for c in range(8))
        print(f"    write RWDS (fal,ris per cycle)  failed OR: {tr(w[112])}", file=out)
        print(f"                                    good  OR: {tr(w[113])}", file=out)
        print(f"                                    good AND: {tr(w[114])}", file=out)
    if mode == 2:
        print(f"    race: die0 first {w[103]}, die1 first {w[104]}, tie {reads - w[103] - w[104]}", file=out)


def check_sim(recs):
    assert len(recs) >= 10, f"expected >= 10 records, got {len(recs)}"
    for w in recs:
        assert w[97] == 512, f"reads {w[97]}"
        assert w[98] == 0 and w[99] == 0 and w[100] == 0, "errors/timeouts in sim"
        assert w[105] == 1024 and w[108] == 0 and w[109] == 0 and w[111] == 0, "fill stats"
        mode = (w[0] >> 16) & 3
        h = {0: w[1:33], 1: w[33:65], 2: w[65:97]}
        if mode in (0, 1):
            assert sum(h[mode]) == 512
        else:
            assert sum(h[0]) == sum(h[1]) == sum(h[2]) == 512
            # race latency never exceeds either die's
            race_max = max(i for i, c in enumerate(h[2]) if c)
            assert race_max <= max(i for i, c in enumerate(h[0]) if c)
    seen = {((w[0] >> 16) & 3, (w[0] >> 8) & 0xFF) for w in recs}
    assert len(seen) == 9, f"expected 9 mode/spacing combinations, saw {sorted(seen)}"
    print(f"SIM CHECK PASSED ({len(recs)} records)")


def open_port(path, baud=115200):
    fd = os.open(path, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0                                        # iflag
    attrs[1] = 0                                        # oflag
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0                                        # lflag (raw)
    speed = getattr(termios, f"B{baud}")
    attrs[4] = attrs[5] = speed
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIFLUSH)
    return fd


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port")
    ap.add_argument("--file")
    ap.add_argument("--freq", type=float, default=81e6)
    ap.add_argument("--records", type=int, default=18, help="stop after N records (live)")
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--log", help="also save raw text here")
    ap.add_argument("--check-sim", action="store_true")
    a = ap.parse_args()

    if a.file:
        text = open(a.file, errors="replace").read()
        recs = parse_records(text)
        for w in recs:
            summarize(w, a.freq)
        if a.check_sim:
            check_sim(recs)
        return

    fd = open_port(a.port)
    buf = ""
    shown = 0
    t0 = time.time()
    try:
        while time.time() - t0 < a.timeout:
            try:
                data = os.read(fd, 4096)
            except BlockingIOError:
                data = b""
            if data:
                buf += data.decode("ascii", errors="replace")
                recs = parse_records(buf)
                for w in recs[shown:]:
                    summarize(w, a.freq)
                    sys.stdout.flush()
                shown = len(recs)
                if shown >= a.records:
                    break
            else:
                time.sleep(0.05)
    finally:
        os.close(fd)
        if a.log:
            open(a.log, "w").write(buf)
    if shown == 0:
        print("no complete records received", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
