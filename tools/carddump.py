#!/usr/bin/env python3
"""Test the menu's directory code against a real SD card, without the console.

  carddump.py copy OUT        (board on USB, console off) copy the card's file-system
                              metadata -- boot blocks, FAT blocks, directory clusters,
                              three levels deep -- into OUT.img (sparse) and the listing
                              tools/devcart.py makes of every directory into OUT.pkl
  carddump.py compare OUT WALK.txt
                              compare with what the menu's 6502 code listed:
                              (cd sim/multicart && echo x > d.a78 &&
                               WALK=1 ./obj_dir/Vdevcart_top OUT.img 1 -1 d.a78 > WALK.txt)
"""
import os
import pickle
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import devcart as d

DEPTH = 3


def copy(out):
    p = d.Port(d.default_port())
    d.sync(p)
    sd = d.SD(p)
    sd.init()
    cache = {}
    raw = sd.read

    def rd(n):
        if n not in cache:
            cache[n] = raw(n)
        return cache[n]
    sd.read = rd
    sd.mount()
    lists = {}

    def walk(path, c, depth):
        lists[path] = sd.listing(c)
        for cls, title, name, clus, size in lists[path]:
            if cls == 1 and depth < DEPTH:
                walk(path + "/" + name, clus, depth + 1)
    walk("", sd.root, 0)
    with open(out + ".img", "wb") as f:
        for n, b in cache.items():
            f.seek(n * 512)
            f.write(b)
    pickle.dump(lists, open(out + ".pkl", "wb"))
    print(len(cache), "blocks,", len(lists), "directories,", sum(len(v) for v in lists.values()), "entries")


def clean(t):
    t = "".join(c if ord(c) < 256 else "?" for c in t)
    return "".join(c if 32 <= ord(c) <= 122 else " " for c in t).ljust(32)[:32]


def compare(out, walkfile):
    lists = pickle.load(open(out + ".pkl", "rb"))
    exp = []

    def walk(path, depth):
        exp.append("D %d" % len(lists[path]))
        for cls, title, name, clus, size in lists[path]:
            exp.append("E %d %s|" % (cls, clean(title)))
        for cls, title, name, clus, size in lists[path]:
            if cls == 1 and depth < DEPTH:
                walk(path + "/" + name, depth + 1)
    walk("", 0)
    text = open(walkfile).read().splitlines()
    got = [l for l in text if l[:2] in ("D ", "E ")]
    bad = [(i, e, g) for i, (e, g) in enumerate(zip(exp, got)) if e != g]
    print(f"{len(exp)} lines expected, {len(got)} from the 6502, {len(bad)} differences; the walk ended with: {text[-1]}")
    for b in bad[:12]:
        print("  ", b)
    sys.exit(1 if bad or len(exp) != len(got) or text[-1] != "WALK DONE" else 0)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "copy":
        copy(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "compare":
        compare(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
