#!/usr/bin/env python3
"""Host tool for the AstroCart V4 development cart (rtl/dev/devcart_top.v).

  devcart.py info  GAME.a78                 show how the cart would be mapped
  devcart.py load  GAME.a78 [--fill] [--no-halt]
                                            upload over USB, verify, fill the BRAM slots, enable
  devcart.py stats [--zero]                 counters (bank switches, POKEY writes, PSRAM-served reads, High Score Cart)
  devcart.py zero                           clear statistics
  devcart.py verify GAME.a78                compare PSRAM die 0 vs die 1 over the image (cart goes off)
  devcart.py trace arm [now|bank]           arm the bus trace (bank: from the next bank-switch write, the default)
  devcart.py trace dump [FILE]              print / save the 512-entry trace
  devcart.py off                            disable the cart (stop driving the bus)
  devcart.py ident
  devcart.py reg                            the menu's registers
  devcart.py menucheck [MENU.bin]           (right after loading the bitstream) turn the cart off and
                                            compare the $8000/$C000 slots with the menu ROM
  devcart.py sd ls [DIR]                    (bench, console off) initialise the SD card and list a
                                            directory the way the menu does, using the menu's registers
  devcart.py sd load [DIR/]NAME [--check GAME.a78]  load a game from the SD card into PSRAM the way the
                                            menu does and enable it; --check compares PSRAM and the
                                            BRAM slots with a local copy of the file
  devcart.py sd read LBA                    hex dump of one block

The serial port defaults to the Tang Nano 9K's UART (/dev/cu.usbserial-*1).
Standard library only.
"""
import argparse
import glob
import os
import sys
import termios
import time

BAUD = 230400
CLK_NS = 1e9 / 67.5e6     # devcart clock
NSTATS = 8


# ---------------------------------------------------------------- serial
class Port:
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        a = termios.tcgetattr(self.fd)
        a[0] = 0
        a[1] = 0
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        a[3] = 0
        a[4] = a[5] = termios.B230400
        a[6][termios.VMIN] = 0
        a[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, a)
        termios.tcflush(self.fd, termios.TCIOFLUSH)
        self.buf = b""

    def write(self, data):
        view = memoryview(bytes(data))
        while view:
            try:
                n = os.write(self.fd, view)
                view = view[n:]
            except BlockingIOError:
                time.sleep(0.001)
        termios.tcdrain(self.fd)

    def _fill(self):
        try:
            d = os.read(self.fd, 4096)
        except BlockingIOError:
            d = b""
        if d:
            self.buf += d
        return bool(d)

    def readline(self, timeout=5.0):
        t0 = time.time()
        while time.time() - t0 < timeout:
            nl = self.buf.find(b"\n")
            if nl >= 0:
                line, self.buf = self.buf[:nl], self.buf[nl + 1:]
                line = line.strip()
                if line:
                    return line.decode(errors="replace")
                continue
            if not self._fill():
                time.sleep(0.002)
        raise TimeoutError("no reply from the cart (is devcart.fs loaded? right port?)")

    def read_until(self, marker, count_words, timeout=10.0):
        t0 = time.time()
        while time.time() - t0 < timeout:
            i = self.buf.find(marker)
            if i >= 0:
                toks = self.buf[i + 1:].split()
                if len(toks) > count_words or (len(toks) == count_words and self.buf.endswith(b"\n")):
                    words = [int(t, 16) for t in toks[:count_words]]
                    self.buf = b""
                    return words
            if not self._fill():
                time.sleep(0.005)
        raise TimeoutError("statistics dump incomplete")


def sync(p):
    """Get the command FSM to a known state: let any reply in progress finish,
    drop it, and ask for the ident until it answers."""
    for attempt in range(4):
        time.sleep(0.2)
        while p._fill():
            time.sleep(0.05)
        p.buf = b""
        p.write(b"S")
        try:
            for _ in range(40):
                line = p.readline(timeout=1.0)
                if line.startswith("AC78V4"):
                    return line
        except TimeoutError:
            pass
    sys.exit("cart does not answer (is devcart.fs loaded? right port?)")


def default_port():
    c = sorted(glob.glob("/dev/cu.usbserial-*1"))
    if not c:
        sys.exit("no /dev/cu.usbserial-*1 port found; pass --port")
    return c[0]


# ---------------------------------------------------------------- a78
class Cart:
    pass


def parse_a78(path, fill=False):
    data = open(path, "rb").read()
    if data[1:10] != b"ATARI7800":
        sys.exit(f"{path}: not an .a78 file (no ATARI7800 header)")
    h, rom = data[:128], data[128:]
    c = Cart()
    c.title = h[17:49].rstrip(b"\0 ").decode(errors="replace")
    c.version = h[0]
    c.size = int.from_bytes(h[49:53], "big")
    c.ctype = (h[53] << 8) | h[54]
    if c.size != len(rom):
        print(f"warning: header size {c.size} != payload {len(rom)}; using payload")
        c.size = len(rom)
    t = c.ctype
    if c.version >= 4:                             # v4 fields folded into the type bits (as menu/fat.asm)
        if h[64] == 1:
            t |= 0x0002
        elif h[64] == 3:
            t |= 0x0200
        elif h[64] == 2:
            t |= 0x0100
        elif h[64]:
            sys.exit(f"v4 mapper {h[64]} is not supported")
        if h[65] & 0x80:
            sys.exit("bankset carts are not supported")
        opt = {0: 0, 1: 0x04, 2: 0x80, 4: 0x08, 5: 0x10}.get(h[65] & 7)
        if opt is None:
            sys.exit(f"v4 mapper option {h[65] & 7} (banked RAM) is not supported")
        t |= opt
    if t & 0x7000:
        sys.exit(f"cart type ${t:04X}: SOUPER / bankset formats are not supported")
    if t & 0x0020:
        sys.exit("banked-RAM carts are not supported")
    c.mram = bool(t & 0x0080)
    if c.mram:
        t |= 0x0004

    # POKEY location: cart-type bits, refined by the v4 audio field (byte 67)
    pokey = 0
    if t & 0x0001:
        pokey = 1                                  # $4000
    if t & 0x0040:
        pokey = 2                                  # $0450
    if t & 0x0400:
        pokey = 5 if pokey == 2 else 4             # $0440 (5: with the one at $0450)
    if t & 0x8000:
        pokey = 3                                  # $0800
    if c.version >= 4:
        a = h[67] & 0x07
        pokey = {0: pokey, 1: 4, 2: 2, 3: 5, 4: 3, 5: 1}.get(a, pokey)
    c.pokey = pokey
    c.math = h[59:62] == b"ACM"                    # the math unit (docs/MATHUNIT.md)

    nb = (c.size + 0x3FFF) // 0x4000
    if t & 0x0100:                                 # Activision (Double Dragon, Rampage)
        if nb != 8:
            sys.exit("an Activision cart is 128K")
        img = bytearray(rom)
        am = (rom[0x1FFF9] & 0x0F) != 7            # an "OM" dump ends with the cart's last 8K ($x7 at $FFF9)
        c.mapper = f"Activision ({'AM' if am else 'OM'} dump: bank 6 at $4000, bank 7 at $8000 / $E000, switched at $A000)"
        c.cfg = dict(win4000=1, bank4000=6, sg_en=0x18 if am else 0x08, bank_mask=0, bank_add=0, bank8000=0, bankC000=7)
    elif t & 0x0200:                               # Absolute (F-18 Hornet)
        if nb != 4:
            sys.exit("an Absolute cart is 64K")
        img = bytearray(rom) + b"\xFF" * (nb * 0x4000 - len(rom))
        c.mapper = "Absolute (banks 0/1 at $4000, 2 and 3 fixed)"
        c.cfg = dict(win4000=1, bank4000=0, sg_en=2, bank_mask=0, bank_add=0, bank8000=2, bankC000=3)
    elif t & 0x0002:                               # SuperGame
        if nb < 2:
            sys.exit("SuperGame image smaller than 32K?")
        img = bytearray(rom) + b"\xFF" * (nb * 0x4000 - len(rom))
        if (t & 0x0008) or (nb & 1):               # 'sg9'-style: extra 16K fixed at $4000
            c.mapper = f"SuperGame + ROM at $4000 ({nb} banks)"
            c.cfg = dict(win4000=1, bank4000=0, sg_en=1, bank_mask=nb - 2, bank_add=1,
                         bank8000=0, bankC000=nb - 1)
        elif t & 0x0004:
            c.mapper = f"SuperGame + 16K RAM at $4000 ({nb} banks)"
            c.cfg = dict(win4000=2, bank4000=0, sg_en=1, bank_mask=nb - 1, bank_add=0,
                         bank8000=0, bankC000=nb - 1)
        else:
            c.mapper = f"SuperGame ({nb} banks, bank {nb - 2} at $4000)"
            c.cfg = dict(win4000=1, bank4000=nb - 2, sg_en=1, bank_mask=nb - 1, bank_add=0,
                         bank8000=0, bankC000=nb - 1)
        if nb > 255:
            sys.exit("more than 255 banks (4 MB) is not supported")
        if (c.cfg["bank_mask"] + 1) & c.cfg["bank_mask"]:
            print(f"warning: {nb} banks is not a power-of-two layout; bank mask {c.cfg['bank_mask']}")
    else:                                          # linear, ends at $FFFF
        if c.size > 0xC000:
            sys.exit("linear image larger than 48K")
        unit = bytearray(rom)
        while len(unit) < 0x4000:                  # mirror small images up to 16K
            unit = unit + unit
        nb = len(unit) // 0x4000
        img = unit
        c.mapper = f"linear {c.size // 1024}K"
        if nb == 3:
            c.cfg = dict(win4000=1, bank4000=0, sg_en=0, bank_mask=0, bank_add=0, bank8000=1, bankC000=2)
        elif nb == 2:
            c.cfg = dict(win4000=3 if fill else 0, bank4000=0, sg_en=0, bank_mask=0, bank_add=0,
                         bank8000=0, bankC000=1)
        else:
            c.cfg = dict(win4000=3 if fill else 0, bank4000=0, sg_en=0, bank_mask=0, bank_add=0,
                         bank8000=0, bankC000=0)
        if (t & 0x0004) and nb < 3:
            c.cfg["win4000"] = 2                   # 16K RAM at $4000
            c.mapper += " + RAM at $4000"
    if c.mram and c.cfg["win4000"] == 2:
        c.cfg["sg_en"] |= 4                        # mapper bit 2: the RAM has no A8
        c.mapper += " (mirror RAM)"
    c.image = bytes(img)
    return c


def describe(c):
    pk = {0: "none", 1: "$4000", 2: "$0450", 3: "$0800", 4: "$0440", 5: "$0450 + $0440"}[c.pokey]
    w4 = {0: "open bus", 1: f"ROM bank {c.cfg['bank4000']}", 2: "16K RAM", 3: "$00 fill"}[c.cfg["win4000"]]
    print(f"{c.title}  (a78 v{c.version}, type ${c.ctype:04X}, {c.size // 1024}K)")
    print(f"  mapper : {c.mapper}")
    print(f"  $4000  : {w4}")
    if c.cfg["sg_en"] & 1:
        print(f"  $8000  : switched, bank = (value & {c.cfg['bank_mask']}) + {c.cfg['bank_add']}"
              f" (starts at {c.cfg['bank8000']})")
    else:
        print(f"  $8000  : ROM bank {c.cfg['bank8000']}")
    print(f"  $C000  : ROM bank {c.cfg['bankC000']}")
    print(f"  POKEY  : {pk}")
    print(f"  image  : {len(c.image)} bytes in PSRAM")


def cfg_bytes(c, halt=True):
    g = c.cfg
    return bytes([ord("C"), g["win4000"], g["bank4000"], g["sg_en"] | (0x20 if c.math else 0), g["bank_mask"], g["bank_add"],
                  g["bank8000"], g["bankC000"], c.pokey, 1 if halt else 0])


# ---------------------------------------------------------------- commands
def cmd_load(p, c, halt=True):
    describe(c)
    n = len(c.image)
    print(f"uploading {n} bytes at {BAUD} baud (~{n * 10 / BAUD:.0f} s)...")
    t0 = time.time()
    p.write(b"L" + n.to_bytes(3, "little"))
    step = 4096
    for i in range(0, n, step):
        p.write(c.image[i:i + step])
        sys.stdout.write(f"\r  {min(i + step, n) * 100 // n:3d}%")
        sys.stdout.flush()
    print()
    reply = p.readline(timeout=30)
    dt = time.time() - t0
    parts = reply.split()
    if len(parts) != 4 or parts[0] != "OK":
        sys.exit(f"load failed: {reply!r}")
    got, retries, fails = int(parts[1], 16), int(parts[2], 16), int(parts[3], 16)
    want = sum(c.image) & 0xFFFFFFFF
    print(f"  loaded in {dt:.1f} s; read-back sum {got:08X} (expected {want:08X}); "
          f"write retries {retries}, unrecoverable {fails}")
    if got != want or fails:
        sys.exit("VERIFY FAILED -- cart left disabled")
    p.write(cfg_bytes(c, halt))
    r = p.readline(timeout=5)
    if r != "OK":
        sys.exit(f"config failed: {r!r}")
    # read the slots back before trusting them (the cart has to be off for that)
    p.write(b"X"); p.readline()
    if cmd_slots(p, c, quiet=True):
        sys.exit("SLOT VERIFY FAILED -- cart left disabled")
    p.write(cfg_bytes(c, halt))
    if p.readline(timeout=5) != "OK":
        sys.exit("config failed")
    print("BRAM slots filled and read back OK, cart enabled -- power on / reset the Atari"
          + ("" if halt else "  (HALT pulling disabled)"))


def cmd_stats(p, zero_after=False):
    """(build 7b on: 8 words. The histograms and copy timings are in tag debug-full-7a.)"""
    p.write(b"T")
    w = p.read_until(b"@", NSTATS)
    for n, v in (("bank switches", w[0]), ("POKEY writes", w[1]), ("writes ignored (HALT)", w[2]),
                 ("6502 reads from PSRAM", w[3]), ("  ... byte never came", w[4]), ("bank on show", w[5] & 255)):
        print(f"  {n:22s} {v:10d}")
    f = w[5] >> 8
    print(f"  {'flags':22s}   halt_en={f >> 2 & 1} holding_halt={f >> 1 & 1} copying={f & 1}")
    hsc = "on" if f & 8 else "off"
    print(f"  {'math unit':22s} {'on' if f & 16 else 'off':>10s}")
    print(f"  {'High Score Cart':22s} {hsc:>10s}   saves to the card {w[6] & 0xFFFF}, failed {w[6] >> 16}, "
          f"writes lost {w[7] & 0xFFFF}{', unsaved changes' if w[7] & 0x40000 else ''}")
    if zero_after:
        p.write(b"Z")
        p.readline()


def cmd_verify(p, c):
    n = len(c.image)
    p.write(b"V" + n.to_bytes(3, "little"))
    r = p.readline(timeout=30).split()
    if len(r) != 4 or r[0] != "OK":
        sys.exit(f"verify failed: {r}")
    got, mism = int(r[1], 16), int(r[3], 16)
    want = sum(c.image) & 0xFFFFFFFF
    print(f"die-0 sum {got:08X} (image {want:08X}); words where die 0 != die 1: {mism}")
    print("PSRAM OK" if got == want and mism == 0 else "PSRAM MISMATCH")


def decode_trace(words):
    """entry = {dt[8:0], halt, rw, our_halt, addr[15:0], data[7:0]}"""
    out = []
    t = 0
    for v in words:
        dt = v >> 27
        t += dt
        out.append((t, dt, (v >> 26) & 1, (v >> 25) & 1, (v >> 24) & 1, (v >> 8) & 0xFFFF, v & 0xFF))
    return out


def cmd_trace(p, action, arg):
    if action == "arm":
        mode = {"now": 0, "bank": 2}[arg or "bank"]
        p.write(bytes([ord("A"), mode]))
        print(p.readline(), f"(trace armed: {arg or 'bank'})")
        return
    p.write(b"Y")
    words = p.read_until(b"@", 512, timeout=20)
    rows = decode_trace(words)
    lines = ["   time(clk)    ns     dt  HALT R/W ours  addr  data"]
    for t, dt, h, rw, drv, a, dd in rows:
        lines.append(f"  {t:9d} {t * CLK_NS:8.0f} {dt:5d}   {'L' if not h else '-'}   {'R' if rw else 'W'}   "
                     f"{'P' if drv else '.'}   ${a:04X}  {dd:02X}")
    text = "\n".join(lines) + "\n"
    if arg:
        if os.path.exists(arg):
            sys.exit(f"{arg} exists -- not overwriting (choose another name)")
        open(arg, "w").write(text)
        print(f"wrote {len(rows)} entries to {arg}")
    else:
        sys.stdout.write(text)
    print("note: a full recording stays in the buffer until the trace is armed again")


def cmd_slots(p, c, bank8000=None, quiet=False):
    """Read the BRAM slots back (cart off) and compare them with the image."""
    g = c.cfg
    # (with POKEY at $4000 the slot behind it cannot be read, by the Atari or by us)
    banks = {1: g["bank4000"] if g["win4000"] == 1 and c.pokey != 1 else None,
             2: g["bank8000"] if bank8000 is None else bank8000, 3: g["bankC000"]}
    total = 0
    for slot in (1, 2, 3):
        if banks[slot] is None:
            continue
        p.write(bytes([ord("D"), slot]))
        got = p.read_until(b"@", 16384, timeout=30)
        off = banks[slot] * 16384
        bad = [(i, got[i], c.image[off + i]) for i in range(16384) if got[i] != c.image[off + i]]
        total += len(bad)
        if not quiet or bad:
            print(f"  slot ${slot * 0x4000:04X} (bank {banks[slot]}): {len(bad)} wrong bytes")
        for i, gg, e in bad[:12]:
            print(f"    ${slot * 0x4000 + i:04X}: slot {gg:02X} image {e:02X}  (xor {gg ^ e:02X})")
    return total


# ---------------------------------------------------------------- SD card (bench)
SD_ERR = {0: "ok", 1: "no answer to CMD0 (no card?)", 2: "CMD8 echo wrong", 3: "ACMD41 never ready",
          4: "CMD58 failed", 5: "CMD16 failed", 6: "CMD17 refused", 7: "no data token", 8: "not initialised"}


class SD:
    """Drives the cart's SD registers over the UART exactly as the menu's 6502 code does."""

    def __init__(self, p):
        self.p = p
        # A neutral mapping first (RAM at $4000, no POKEY): a POKEY left at $4000 by an
        # earlier game would hide the block buffer from the slot dump. Then cart off.
        p.write(bytes([ord("C"), 2, 0, 0, 0, 0, 0, 0, 0, 1])); p.readline(timeout=5)
        p.write(b"X"); p.readline()

    def w(self, r, v):
        self.p.write(bytes([ord("W"), r, v & 0xFF]))
        if self.p.readline() != "OK":
            sys.exit("register write failed")

    def r(self, r):
        self.p.write(bytes([ord("R"), r]))
        return int(self.p.readline(), 16)

    def wait(self, timeout=15.0):
        """Poll the status register. While the cart is busy with the card its
        UART command loop is not listening, so a poll may go unanswered (or
        half-heard): ask again until a clean two-digit answer says 'not busy'."""
        t0 = time.time()
        while time.time() - t0 < timeout:
            self.p.write(bytes([ord("R"), 0]))
            try:
                line = self.p.readline(timeout=0.15)
            except TimeoutError:
                continue
            if len(line) != 2:
                continue
            try:
                st = int(line, 16)
            except ValueError:
                continue
            if not st & 0x80:
                time.sleep(0.03)                # let any stray reply arrive, then drop it
                while self.p._fill():
                    time.sleep(0.01)
                self.p.buf = b""
                return st
        sys.exit("SD operation timed out")

    def cmd(self, c):
        self.w(0, c)
        s = self.wait()
        if s & 0x0F:
            sys.exit(f"SD error {s & 15}: {SD_ERR.get(s & 15, '?')} (status ${s:02X})")
        return s

    def init(self):
        t0 = time.time()
        s = self.cmd(1)
        print(f"card initialised in {time.time() - t0:.2f} s: {'block' if s & 0x20 else 'byte'} addressed (status ${s:02X})")

    def lba(self, n):
        for k in range(4):
            self.w(1 + k, (n >> (8 * k)) & 0xFF)

    def read(self, n):
        self.lba(n)
        self.cmd(2)
        self.p.write(bytes([ord("D"), 0x81]))
        return bytes(self.p.read_until(b"@", 512, timeout=10))

    # ---- FAT32, the same way menu/fat.asm does it ----
    def mount(self):
        b = self.read(0)
        if b[510:512] != b"\x55\xAA":
            sys.exit("block 0 has no boot signature")
        part = 0
        if not (b[0] in (0xEB, 0xE9) and b[11:13] == b"\x00\x02" and b[16] in (1, 2)):
            if b[0x1C2] == 0xEE:
                part = int.from_bytes(self.read(2)[32:36], "little")
                print(f"GPT; first partition at block {part}")
            else:
                part = int.from_bytes(b[0x1C6:0x1CA], "little")
                print(f"MBR; partition type ${b[0x1C2]:02X} at block {part}")
            b = self.read(part)
        if b[0x11] | b[0x12] | b[0x16] | b[0x17]:
            sys.exit("not FAT32 (FAT12/16 or exFAT?)")
        self.spc = b[0x0D]
        self.fat = part + int.from_bytes(b[0x0E:0x10], "little")
        self.data = self.fat + b[0x10] * int.from_bytes(b[0x24:0x28], "little")
        self.root = int.from_bytes(b[0x2C:0x30], "little")
        self.fatcache = (None, None)
        print(f"FAT32: {self.spc} blocks per cluster, FAT at {self.fat}, data at {self.data}, root cluster {self.root}")

    def c2lba(self, c):
        return self.data + (c - 2) * self.spc

    def next(self, c):
        blk = self.fat + (c >> 7)
        if self.fatcache[0] != blk:
            self.fatcache = (blk, self.read(blk))
        n = int.from_bytes(self.fatcache[1][(c & 127) * 4:(c & 127) * 4 + 4], "little") & 0x0FFFFFFF
        return None if n >= 0x0FFFFFF8 or n < 2 else n

    def dir(self, c):
        """Entries of the directory at cluster c: (long or 8.3 name, raw entry)."""
        lfn = {}
        while c is not None:
            for s in range(self.spc):
                b = self.read(self.c2lba(c) + s)
                for i in range(16):
                    e = b[i * 32:i * 32 + 32]
                    if e[0] == 0:
                        return
                    if e[0] == 0xE5:
                        lfn = {}
                        continue
                    if e[11] & 0x3F == 0x0F:
                        if e[0] & 0x40:
                            lfn = {}
                        lfn[e[0] & 0x1F] = e[1:11] + e[14:26] + e[28:32]
                        continue
                    if e[11] & 0x08:
                        lfn = {}
                        continue
                    name = b"".join(lfn[k] for k in sorted(lfn)).decode("utf-16-le", errors="replace").split("\0")[0]
                    lfn = {}
                    if not name:
                        base, ext = e[:8].decode(errors="replace").rstrip(), e[8:11].decode(errors="replace").rstrip()
                        name = base + ("." + ext if ext else "")
                    yield name, e
            c = self.next(c)

    def listing(self, c):
        """What the menu lists for the directory at cluster c, in its order:
        (class, title, name, cluster, size); class 0 "..", 1 directory, 2 game."""
        out = []
        for name, e in self.dir(c):
            clus = (e[20] | e[21] << 8) << 16 | e[26] | e[27] << 8
            size = int.from_bytes(e[28:32], "little")
            if name.startswith("."):
                if name != "..":
                    continue
                cls, title = 0, ".."            # (macOS writes it as a hidden directory)
            elif e[11] & 0x06:
                continue
            elif e[11] & 0x10:
                cls, title = 1, name[:31] + "/" if len(name) < 32 else name[:31] + "/"
            elif e[8:11] == b"A78":
                cls, title = 2, (name[:-4] if len(name) > 4 else name)[:32]
            else:
                continue
            if len(out) < 255:
                out.append((cls, title, name, clus, size))
        out.sort(key=lambda t: (t[0], t[1].upper().ljust(32)))
        return out

    def walk(self, path):
        """Cluster of the directory PATH (components matched without case)."""
        c = self.root
        for part in [x for x in path.split("/") if x]:
            hit = [t for t in self.listing(c) if t[0] == 1 and t[2].lower() == part.lower()]
            if not hit:
                sys.exit(f"no directory {part!r} there")
            c = hit[0][3]
        return c

    def load(self, clus, size, ptr):
        """Load a file's blocks into PSRAM at ptr (header skipped), like ac_ldfile."""
        for k in range(3):
            self.w(5 + k, (ptr >> (8 * k)) & 0xFF)
        left = (size + 511) // 512
        first = True
        c = clus
        while left:
            if c is None:
                sys.exit("cluster chain ends before the file does")
            self.lba(self.c2lba(c))
            for s in range(self.spc):
                self.cmd(4 if first else 3)
                first = False
                left -= 1
                if not left:
                    break
                if left % 64 == 0:
                    sys.stdout.write(f"\r  {left:5d} blocks to go ")
                    sys.stdout.flush()
            else:
                c = self.next(c)
        sys.stdout.write("\r" + " " * 30 + "\r")


def cmd_sd(p, a):
    sd = SD(p)
    sd.init()
    if a.action == "read":
        b = sd.read(int(a.name, 0))
        for i in range(0, 512, 16):
            print(f"  {i:03X}: " + " ".join(f"{x:02X}" for x in b[i:i + 16]) + "  " +
                  "".join(chr(x) if 32 <= x < 127 else "." for x in b[i:i + 16]))
        return
    sd.mount()
    # 'ls [DIR]', 'load [DIR/]NAME': NAME is a number in the listing or part of a title
    path, _, leaf = (a.name or "").rpartition("/")
    if a.action == "ls":
        path, leaf = a.name or "", ""
    entries = sd.listing(sd.walk(path))
    print(f"/{path.strip('/')}: {len(entries)} entries, as the menu lists them")
    for i, (cls, title, name, clus, size) in enumerate(entries):
        print(f"  {i:3d}  {title:32s}  " + ("" if cls < 2 else f"cluster {clus:7d}  {size:7d} bytes"))
    if a.action == "ls":
        return
    if not leaf:
        sys.exit("which game? give its number or part of its title")
    pick = [t for i, t in enumerate(entries) if t[0] == 2 and (leaf == str(i) or leaf.lower() in t[1].lower())]
    if len(pick) != 1:
        sys.exit(f"{len(pick)} games match {leaf!r}")
    cls, title, short, clus, size = pick[0]
    if sd.read(sd.c2lba(clus))[1:10] != b"ATARI7800":
        sys.exit(f"{short!r} is not an .a78 file")
    rom = size - 128
    nb = (rom + 0x3FFF) // 0x4000
    off = nb * 0x4000 - rom
    print(f"loading {title!r}: {rom} bytes -> PSRAM ${off:06X}")
    sd.w(0, 6); sd.wait()
    t0 = time.time()
    sd.load(clus, size, off)
    p.write(b"Q")
    q = p.readline().split()
    print(f"  {time.time() - t0:.1f} s; checksum {q[1]}, write retries {int(q[2], 16)}, unrecoverable {int(q[3], 16)}")
    if int(q[3], 16):
        sys.exit("PSRAM WRITE FAILURES")
    if not a.check:
        print("loaded (not enabled; use --check with a local copy to verify and enable)")
        return
    c = parse_a78(a.check)
    if len(c.image) != nb * 0x4000 or off:
        sys.exit("--check needs an image that is a whole number of 16K banks")
    print("comparing PSRAM with the local file (checksum, both dies)...")
    cmd_verify(p, c)
    # launch the way the menu does: mapper registers $8-$F, then command 5
    for k, v in enumerate(cfg_bytes(c)[1:9]):
        sd.w(8 + k, v)
    sd.w(0, 5)
    sd.wait()
    p.write(b"S")
    print(f"after the launch command: {p.readline()}  (cart enabled = 1 expected)")
    p.write(b"X"); p.readline()
    bad = cmd_slots(p, c)
    if bad:
        sys.exit("SLOT VERIFY FAILED -- cart left disabled")
    p.write(cfg_bytes(c))
    p.readline(timeout=5)
    describe(c)
    print("slots match; cart enabled")


def cmd_hunt(p, prefix, ranges, tries, keep):
    """Arm 'now' + dump repeatedly; keep captures in which the bus visits one
    of the address ranges within the first 60% of the entries."""
    rr = [tuple(int(x, 16) for x in r.split("-")) for r in ranges]
    kept = 0
    for n in range(tries):
        p.write(bytes([ord("A"), 0])); p.readline()
        time.sleep(0.02)
        p.write(b"S")
        if p.readline().split()[2] != "3":
            sys.exit("the trace did not fill: the bus is idle (is the Atari on?)")
        p.write(b"Y")
        rows = decode_trace(p.read_until(b"@", 512, timeout=20))
        hit = [i for i, r in enumerate(rows[:310]) if any(lo <= r[5] <= hi for lo, hi in rr)]
        if not hit:
            continue
        name = f"{prefix}_{kept:02d}.txt"
        if os.path.exists(name):
            sys.exit(f"{name} exists -- not overwriting (choose another prefix)")
        with open(name, "w") as f:
            f.write("   time(clk)    ns     dt  HALT R/W ours  addr  data\n")
            for t, dt, h, rw, drv, a, dd in rows:
                f.write(f"  {t:9d} {t * CLK_NS:8.0f} {dt:5d}   {'L' if not h else '-'}   {'R' if rw else 'W'}   "
                        f"{'P' if drv else '.'}   ${a:04X}  {dd:02X}\n")
        kept += 1
        print(f"  capture {n + 1}: hit at entry {hit[0]} -> {name}")
        if kept >= keep:
            break
    print(f"{kept} captures kept out of {n + 1} tries")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("info"); s.add_argument("file"); s.add_argument("--fill", action="store_true")
    s = sub.add_parser("load"); s.add_argument("file"); s.add_argument("--fill", action="store_true",
                                                                       help="drive $00 at $4000-$7FFF for small linear carts")
    s.add_argument("--no-halt", action="store_true",
                   help="HALT-free bank switches (build 4a+): the 6502 keeps running and reads the new bank "
                        "from PSRAM while the slot refills. Games started from the menu always run this way; "
                        "without this option a USB-loaded game uses the old HALT + copy")
    s = sub.add_parser("verify"); s.add_argument("file")
    s = sub.add_parser("trace"); s.add_argument("action", choices=["arm", "dump"]); s.add_argument("arg", nargs="?")
    s = sub.add_parser("hunt", help="repeat 'trace arm now' until the bus visits an address range")
    s.add_argument("prefix"); s.add_argument("ranges", nargs="+", help="hex LO-HI")
    s.add_argument("--tries", type=int, default=600); s.add_argument("--keep", type=int, default=6)
    s = sub.add_parser("slots", help="read the BRAM slots back and compare (cart must be off)")
    s.add_argument("file"); s.add_argument("--bank", type=int, help="bank the $8000 slot should hold")
    s = sub.add_parser("stats"); s.add_argument("--zero", action="store_true")
    sub.add_parser("zero")
    sub.add_parser("off")
    sub.add_parser("ident")
    sub.add_parser("reg")
    s = sub.add_parser("menucheck"); s.add_argument("file", nargs="?")
    s = sub.add_parser("sd"); s.add_argument("action", choices=["ls", "load", "read"]); s.add_argument("name", nargs="?")
    s.add_argument("--check", help="local copy of the .a78 to compare against")
    a = ap.parse_args()

    if a.cmd == "info":
        describe(parse_a78(a.file, a.fill))
        return
    p = Port(a.port or default_port())
    ident = sync(p)
    if a.cmd == "ident":
        print(ident)
    elif a.cmd == "load":
        cmd_load(p, parse_a78(a.file, a.fill), not a.no_halt)
    elif a.cmd == "verify":
        cmd_verify(p, parse_a78(a.file))
    elif a.cmd == "trace":
        cmd_trace(p, a.action, a.arg)
    elif a.cmd == "slots":
        cmd_slots(p, parse_a78(a.file), a.bank)
    elif a.cmd == "hunt":
        cmd_hunt(p, a.prefix, a.ranges, a.tries, a.keep)
    elif a.cmd == "stats":
        cmd_stats(p, a.zero)
    elif a.cmd == "zero":
        p.write(b"Z"); print(p.readline())
    elif a.cmd == "off":
        p.write(b"X"); print(p.readline())
    elif a.cmd == "reg":
        names = ["status", "signature", "version", "write fails", "sum0", "sum1", "sum2", "sum3",
                 "lba0", "lba1", "lba2", "lba3", "ldptr0", "ldptr1", "ldptr2", "write retries"]
        for r in range(16):
            p.write(bytes([ord("R"), r]))
            print(f"  ${0x460 + r:04X} {names[r]:14s} {p.readline()}")
    elif a.cmd == "sd":
        cmd_sd(p, a)
    elif a.cmd == "menucheck":
        path = a.file or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "menu", "build", "menu.bin")
        rom = open(path, "rb").read()
        if len(rom) != 0x8000:
            sys.exit("the menu ROM must be 32K")
        print(f"before: {ident}  (cart enabled = {ident.split()[1]})")
        p.write(b"X"); p.readline()
        bad = 0
        for slot, part in ((2, rom[:0x4000]), (3, rom[0x4000:])):
            p.write(bytes([ord("D"), slot]))
            got = bytes(p.read_until(b"@", 16384, timeout=30))
            n = sum(1 for x, y in zip(got, part) if x != y)
            bad += n
            print(f"  slot ${slot * 0x4000:04X}: {n} bytes differ from the menu ROM")
        print("menu ROM is in the slots" if not bad else "MENU ROM MISMATCH")
        print("the cart is now off: load the bitstream again (or power-cycle) to bring the menu back")

if __name__ == "__main__":
    main()
