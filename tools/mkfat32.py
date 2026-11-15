#!/usr/bin/env python3
"""Build a small FAT32 card image for the simulations (standard library only).

  mkfat32.py OUT.img [--spc N] [--part LBA] [--size-mb M] [--fragment] [--root]
             [--sub NAME:I,J,...]... [--extra NAME:PATH,PATH,...]... FILE...

The files go into /ROMS (or the root directory with --root), each with long-
file-name entries in front of its 8.3 entry, like a card written by macOS or
Windows. The root directory also gets a volume label, a deleted entry and a
file that is not a .a78. --fragment interleaves the files' clusters so every
chain has to be followed through the FAT. --part 0 makes a "superfloppy"
(no partition table). --sub NAME:I,J puts files I and J (positions in the FILE
list) into a sub-directory NAME of the games directory instead; NAME may be
PARENT/CHILD for a directory inside an earlier --sub. --extra NAME:PATH,...
makes a directory NAME in the root with those files (/ASTROCART for the High
Score Cart's two).
"""
import argparse
import os
import struct

SEC = 512


def lfn_checksum(short):
    s = 0
    for c in short:
        s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
    return s


def short_name(name, used):
    base, ext = os.path.splitext(name)
    ext = ext[1:].upper()[:3]
    clean = "".join(c for c in base.upper() if c.isalnum())
    n = 1
    while True:
        tail = "~%d" % n
        cand = (clean[:8 - len(tail)] + tail) if (len(clean) > 8 or clean != base.upper() or n > 1) else clean
        s = cand.ljust(8)[:8] + ext.ljust(3)
        if s not in used:
            used.add(s)
            return s.encode("ascii")
        n += 1


def dir_entries(name, short, attr, cluster, size):
    out = b""
    u = name.encode("utf-16-le") + b"\0\0"
    chunks = [u[i:i + 26] for i in range(0, len(u), 26)]
    cs = lfn_checksum(short)
    for i in reversed(range(len(chunks))):
        c = chunks[i].ljust(26, b"\xFF")
        seq = (i + 1) | (0x40 if i == len(chunks) - 1 else 0)
        out += bytes([seq]) + c[0:10] + bytes([0x0F, 0, cs]) + c[10:22] + b"\0\0" + c[22:26]
    out += short + bytes([attr]) + bytes(8) + struct.pack("<H", cluster >> 16) + bytes(4) + \
        struct.pack("<HI", cluster & 0xFFFF, size)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("files", nargs="*")
    ap.add_argument("--spc", type=int, default=8)
    ap.add_argument("--part", type=int, default=2048)
    ap.add_argument("--size-mb", type=int, default=64)
    ap.add_argument("--fragment", action="store_true")
    ap.add_argument("--root", action="store_true")
    ap.add_argument("--sub", action="append", default=[])
    ap.add_argument("--extra", action="append", default=[])
    a = ap.parse_args()

    spc = a.spc
    total = a.size_mb * 1024 * 1024 // SEC - a.part
    rsvd = 32
    nfats = 2
    fatsz = ((total - rsvd) // spc * 4 + SEC - 1) // SEC + 1
    data0 = rsvd + nfats * fatsz                      # first data sector, relative to the volume
    nclus = (total - data0) // spc
    fat = [0x0FFFFFF8, 0x0FFFFFFF]
    clusters = {}                                     # cluster -> bytes

    def alloc_chain(data, order=None):
        n = max(1, (len(data) + spc * SEC - 1) // (spc * SEC))
        cl = order if order else list(range(len(fat), len(fat) + n))
        while len(fat) <= max(cl):
            fat.append(0)
        for i, c in enumerate(cl):
            fat[c] = cl[i + 1] if i + 1 < n else 0x0FFFFFFF
            clusters[c] = data[i * spc * SEC:(i + 1) * spc * SEC]
        return cl[0]

    root_clus = 2
    fat.append(0x0FFFFFFF)                            # root directory: cluster 2 (extended below)
    roms_clus = None
    if not a.root:
        roms_clus = 3
        fat.append(0x0FFFFFFF)

    blobs = [(os.path.basename(f), open(f, "rb").read()) for f in a.files]
    starts = []
    if a.fragment and len(blobs) > 1:
        need = [max(1, (len(d) + spc * SEC - 1) // (spc * SEC)) for _, d in blobs]
        orders = [[] for _ in blobs]
        nxt = len(fat)
        left = need[:]
        while any(left):
            for i in range(len(blobs)):
                if left[i]:
                    orders[i].append(nxt)
                    nxt += 1
                    left[i] -= 1
        for (name, d), o in zip(blobs, orders):
            starts.append(alloc_chain(d, o))
    else:
        for name, d in blobs:
            starts.append(alloc_chain(d))

    # sub-directories: name -> [cluster, parent name or None, file indices]
    subs = {}
    in_sub = set()
    for spec in a.sub:
        nm, _, idx = spec.partition(":")
        idx = [int(x) for x in idx.split(",") if x]
        parent, _, leaf = nm.rpartition("/")
        fat.append(0x0FFFFFFF)
        subs[nm] = [len(fat) - 1, parent or None, idx, leaf]
        in_sub.update(idx)

    def entries_of(parent):
        used = set()
        out = b""
        for nm, (cl, par, idx, leaf) in subs.items():
            if par == parent:
                out += dir_entries(leaf, short_name(leaf, used), 0x10, cl, 0)
        want = range(len(blobs)) if parent is None else subs[parent][2]
        for i in want:
            if parent is None and i in in_sub:
                continue
            name, d = blobs[i]
            out += dir_entries(name, short_name(name, used), 0x20, starts[i], len(d))
        return out

    gdir = entries_of(None)

    readme = b"not a game\r\n"
    readme_clus = alloc_chain(readme)
    root = b"ASTROCART  " + bytes([0x08]) + bytes(20)
    root += b"\xE5LDFILE A78" + bytes([0x20]) + bytes(20)                 # deleted entry
    root += dir_entries("Read Me.txt", b"README~1TXT", 0x20, readme_clus, len(readme))
    root += dir_entries(".Spotlight-V100", b"SPOTLI~1   ", 0x12, 0, 0)    # hidden directory (junk)
    if a.root:
        root += gdir
    else:
        root += b"ROMS       " + bytes([0x10]) + bytes(8) + struct.pack("<H", roms_clus >> 16) + \
            bytes(4) + struct.pack("<HI", roms_clus & 0xFFFF, 0)
        dot = b".          " + bytes([0x12]) + bytes(8) + struct.pack("<H", 0) + bytes(4) + struct.pack("<HI", roms_clus, 0)
        dotdot = b"..         " + bytes([0x12]) + bytes(20)
        gdir = dot + dotdot + gdir

    extras = []                                       # (name, cluster, directory bytes)
    for spec in a.extra:
        nm, _, paths = spec.partition(":")
        fat.append(0x0FFFFFFF)
        ecl = len(fat) - 1
        eused = set()
        ed = b".          " + bytes([0x12]) + bytes(8) + struct.pack("<H", ecl >> 16) + bytes(4) + struct.pack("<HI", ecl & 0xFFFF, 0)
        ed += b"..         " + bytes([0x12]) + bytes(20)
        for pth in [x for x in paths.split(",") if x]:
            d = open(pth, "rb").read()
            st = alloc_chain(d)
            ed += dir_entries(os.path.basename(pth), short_name(os.path.basename(pth), eused), 0x20, st, len(d))
        extras.append((nm, ecl, ed))
        rused = set()
        root += dir_entries(nm, short_name(nm, rused), 0x10, ecl, 0)

    def place_dir(first, data):
        csz = spc * SEC
        n = max(1, (len(data) + csz) // csz)          # always at least one free entry at the end
        cl = [first]
        for _ in range(n - 1):
            cl.append(len(fat))
            fat.append(0)
        for i, c in enumerate(cl):
            fat[c] = cl[i + 1] if i + 1 < n else 0x0FFFFFFF
            clusters[c] = data[i * csz:(i + 1) * csz]

    place_dir(root_clus, root)
    for nm, ecl, ed in extras:
        place_dir(ecl, ed)
    if roms_clus:
        place_dir(roms_clus, gdir)
    games_clus = roms_clus or 0                       # ".." of a directory in the root: cluster 0
    for nm, (cl, par, idx, leaf) in subs.items():
        up = subs[par][0] if par else games_clus
        dot = b".          " + bytes([0x12]) + bytes(8) + struct.pack("<H", cl >> 16) + bytes(4) + struct.pack("<HI", cl & 0xFFFF, 0)
        dotdot = b"..         " + bytes([0x12]) + bytes(8) + struct.pack("<H", up >> 16) + bytes(4) + struct.pack("<HI", up & 0xFFFF, 0)
        place_dir(cl, dot + dotdot + entries_of(nm))
    assert len(fat) < nclus + 2, "image too small"

    bpb = bytearray(SEC)
    bpb[0:3] = b"\xEB\x58\x90"
    bpb[3:11] = b"MSDOS5.0"
    struct.pack_into("<HBHBHHBHHHII", bpb, 11, SEC, spc, rsvd, nfats, 0, 0, 0xF8, 0, 63, 255, a.part, total)
    struct.pack_into("<IHHIHH", bpb, 36, fatsz, 0, 0, root_clus, 1, 6)
    bpb[66] = 0x29
    bpb[71:82] = b"ASTROCART  "
    bpb[82:90] = b"FAT32   "
    bpb[510:512] = b"\x55\xAA"

    with open(a.out, "wb") as f:
        f.truncate(a.size_mb * 1024 * 1024)
        if a.part:
            mbr = bytearray(SEC)
            mbr[446:462] = struct.pack("<BBBBBBBBII", 0, 0xFE, 0xFF, 0xFF, 0x0C, 0xFE, 0xFF, 0xFF, a.part, total)
            mbr[510:512] = b"\x55\xAA"
            f.seek(0)
            f.write(mbr)
        base = a.part * SEC
        f.seek(base)
        f.write(bpb)
        f.seek(base + 6 * SEC)
        f.write(bpb)
        fatb = b"".join(struct.pack("<I", x) for x in fat)
        for k in range(nfats):
            f.seek(base + (rsvd + k * fatsz) * SEC)
            f.write(fatb)
        for c, d in clusters.items():
            f.seek(base + (data0 + (c - 2) * spc) * SEC)
            f.write(d)
    print(f"{a.out}: {a.size_mb} MB, {spc} sectors/cluster, {len(blobs)} files, "
          f"partition at {a.part}, data at volume sector {data0}")


if __name__ == "__main__":
    main()
