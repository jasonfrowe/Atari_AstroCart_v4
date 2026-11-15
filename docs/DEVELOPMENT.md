# AstroCart V4: development notes

How the cart got to where it is: what was measured, what failed and why, and
how each part works inside. The README says what the cart does and how to
build and use it; this file is the record behind it. Newest design first,
oldest measurements last.

Build numbers are git tags (`devcart-build9a`, ...). Sections that mention
`aborttest`, `copyopt`, `verify --dump`, `trace arm crash|writes` or the
hold-time histograms describe tag **`debug-full-7a`**, the last build with
all of the debug logic; check that out and build it if they are needed again.

## Build history

| | |
|---|---|
| PSRAM characterised on silicon | done (`lab/psram_lab`) |
| Development cart v1 (Atari read PSRAM directly) | **failed on the console**: MARIA moves to a new DMA address every ~140 ns, PSRAM needs 160 ns + overhead |
| Development cart v2 (Atari reads BRAM; PSRAM is the backing store; bank switch = HALT + copy) | **working on the console** (build 2j, 2026-11-13): Gamma Force plays through multiple levels and restarts with no faults |
| POKEY | build 2k: rewritten sound core, sounds right on the console; pitch not yet compared against a reference |
| Menu + SD card loading | **working on the console** (build 3e, 2026-11-13): games are picked in the menu and loaded from `/ROMS` on the SD card |
| Bank switching without HALT | **working on the console** (build 4d, 2026-11-14): all nine test games run, including ARTI, Tiger-Heli, Commando and Impossible Mission |
| Bitstream in flash | build 5b written to flash 2026-11-14 (`openFPGALoader -b tangnano9k -f hw/devcart/build/impl/pnr/devcart.fs`); a power cycle then comes back to the menu |
| Mappers | linear 8-48K (optional 16K RAM at `$4000`), SuperGame up to 512K (plain, with RAM, with ROM at `$4000`), Absolute (F-18 Hornet), mirror RAM, POKEY at `$4000` / `$0450` / `$0800` / `$0440`, two POKEYs at `$0450` + `$0440` (build 5b), Activision (Double Dragon, Rampage; build 5c), SuperGame up to 255 banks (4 MB), for the 528K and 1024K carts (build 6a). All on the console. Not yet: banked RAM, SOUPER, banksets, YM2151, COVOX, XM |
| High Score Cart | build 7a: ROM and RAM in PSRAM, RAM saved to `/ASTROCART/HSC.SAV` on the card. Confirmed on the console |
| Debug logic removed | build 7b: the hold-time histograms, crash recorder, write log, PSRAM abort test, copy timings and copy knobs are gone (logic 71% -> 59%; timing closes on 6 of 13 placement seeds, was 1). Kept: `ident`, the loader, `stats` (8 counters), `trace` (now / from the next bank switch), `sd`, `slots`. Sections below that mention `aborttest`, `copyopt`, `verify --dump`, `trace arm crash|writes` or the histograms describe tag **`debug-full-7a`**: check that out and build it if they are needed again |
| Math unit | build 8a (branch `mathunit`): fixed-point multiply / divide / square root / accumulator / random byte at `$0430-$043F` for carts whose header asks for it. Definition: `docs/MATHUNIT.md`. Its self-test cart (`tests/mathtest`, 12,358 register checks) passes in the a7800 fork, in simulation and **on the console** (green screen, 2026-11-14) |
| Math unit, version 2 | build 9a: adds a trig block at `$0420-$042F` -- turn a vector by an angle (which gives sine and cosine), and the angle and length of a vector (atan2). CORDIC; logic 67% -> 73%. `tests/mathtest` (13,130 register checks) passes in the a7800 fork (its branch `cordic`), in simulation and on the console |
| Menu: directories | build 5a: browse the card's directories, 255 entries per directory, sorted, file names as titles |

## The menu and the SD card (build 3 on)

The cart powers up **in the menu**: the bitstream initialises the `$8000` and
`$C000` slot BRAMs with a 32K 7800basic program (`menu/menu.bas`), gives it
16K of RAM at `$4000` (slot 0) and a set of registers at `$0460-$046F`.

* `rtl/sd/sd_spi.v` talks to the SD card (SPI mode, 8.4 MHz). The menu asks
  the FPGA for whole blocks: "block N into the buffer at `$4000-$41FF`", or
  "block N into PSRAM at the load pointer" (through the same write / read back
  both dies / retry loader the USB path uses).
* The file system is done by the 6502 (`menu/fat.asm`): MBR / GPT / no
  partition table, FAT32, long file names.
* The menu browses the card from its root directory (build 5a). A directory's
  list holds its sub-directories and its `*.a78` files: `..` first, then the
  directories (shown with a `/`), then the games, each group sorted by name
  without regard to case. The title is the file name, cut to 32 characters,
  without `.a78`. Fire opens a directory or starts a game; coming back up
  through `..` puts the cursor on the directory just left. Hidden and system
  entries and names beginning with a dot (macOS's `._name.a78`) are left out.
  A file is only checked for an .a78 header when it is started -- or when the
  cursor rests on it: two lines then show the title from its header and its
  ROM size, mapper, POKEY and TV system, or NOT SUPPORTED (build 5b).
* Choosing a game: its header is turned into the mapper configuration (the
  rules of `tools/devcart.py info`), the file is loaded into PSRAM, then the
  menu turns MARIA's DMA off, jumps to a stub in console RAM that writes the
  launch command, waits 30 ms and jumps through the game's reset vector. The
  FPGA meanwhile disables the cart, refills the three slots and leaves menu
  mode (the registers disappear).
* Back to the menu: power-cycle the FPGA (reload the bitstream). A console
  power cycle alone restarts the loaded game while USB keeps the FPGA alive.
* Limits: 255 entries per directory (the first 255 found; more are not
  shown), any depth (the name line shows the last 8 levels), FAT32 only (not
  exFAT), carts the dev cart supports
  (see Mappers in the table above); others get "CART TYPE NOT SUPPORTED".
* Build 5c, **Activision**: the cart is 8K pieces -- `$4000`/`$6000` bank 6,
  `$8000` and `$E000` bank 7, `$A000-$DFFF` the bank selected by a write to
  `$FF80-$FF87`. The slots still hold whole banks (6, selected, 7); only the
  address decode differs (`cart_bus.v` `win_of`, `hflip`), so the switch is
  the same HALT-free slot-1 refill. Two kinds of dump exist with the same
  header: "OM" and "AM" (the 8K halves of every bank exchanged); the menu
  tells them apart by the `$x7` signature byte of `$FFF9` in the file's last
  block.
* Build 5b's mappers: **Absolute** switches the bank at `$4000` (slot 0) with
  a write to `$8000` (bit 0: bank 0, else bit 1: bank 1), HALT-free like the
  SuperGame switch; **mirror RAM** is the RAM at `$4000` without A8 (odd pages
  mirror even ones); a second POKEY core sits at `$0440` for the "dual POKEY
  440 450" files, mixed half and half with the first. Definitions taken from
  the a7800 emulator's source; test files from Trebor's ROM PROPack
  (`sim/multicart/run.sh`, skipped if the pack is not there).

Tests that need no console:

```bash
menu/build.sh                      # the menu ROM -> menu/build/menu.bin
(cd sim/multicart && make run)     # fake6502 + SD card model + FAT32 images: all test carts,
                                   # through the harness and through the real menu ROM
menu/build.sh emu                  # a7800 build with a made-up list (menu/emu_shots.lua = snapshots)
python3 tools/carddump.py copy /tmp/card   # board: copy a real card's directories into an image, then run
                                   # the menu's 6502 code over it in the simulation and compare every list
                                   # (see the file's header; the Trebor pack: 90 directories, 0 differences)
python3 tools/mkhsc.py HSC-ROM.a78 OUTDIR   # the High Score Cart's two files for the card
python3 tools/devcart.py menucheck # board: the menu ROM is in the slots after configuration
python3 tools/devcart.py sd ls [DIR]   # board: real card, a directory listed as the menu lists it
python3 tools/devcart.py sd load DIR/NAME --check GAME.a78   # ... loaded, launched, compared
```

Found on the way: the menu's own RAM writes and the SD bytes going into the
block buffer share slot 0's write port, and one could overwrite the other in
the register stage (the simulation lost the last byte of a block). Both
writers now queue (`cart_bus.v`), and 6502 RAM writes present address and data
a clock before the write enable, as the copy engine does.

## High Score Cart (build 7a)

The Atari High Score Cartridge is a pass-through with a 4K ROM at
`$3000-$3FFF` and 2K of battery RAM at `$1000-$17FF`. Games that know it
(byte 58, bit 0 of the .a78 header) call into the ROM.

On the card (make them with `tools/mkhsc.py`, copy the folder to the root):

```
/ASTROCART/HSC.A78    the HSC's ROM, as the usual .a78 dump (128 + 4096 bytes)
/ASTROCART/HSC.SAV    2048 bytes: the RAM. All $FF = empty.
```

* When a game with the HSC bit is started and both files are there, the menu
  loads them into the last 16K of PSRAM (ROM at `$3FC000`, RAM at `$3FD000`)
  and tells the cart which four blocks of the card hold `HSC.SAV` (command 7).
  The info line shows `HSC`.
* **No block RAM is used** (all 26 are taken). Every read of the two ranges --
  by the 6502 and by MARIA, who draws the HSC's screens with the font in its
  ROM -- is answered from PSRAM die 1, through the path the HALT-free bank
  switch uses. In simulation a MARIA font read (27 clocks per address, as
  traced on the console) has its byte by clock 24. Whether MARIA accepts
  that is the open question of this build: if she samples earlier, the HSC's
  own screens will show wrong characters while everything else works.
* A write to the RAM waits in a four-entry queue (reads of a queued address
  are answered from the queue) and goes to PSRAM in the next bus cycle that
  does not need the die: a 6502 write cycle, or a read elsewhere. Two fit
  into one such cycle.
* When the RAM has changed and nothing has been written for a second, the
  FPGA writes its 2K to the four blocks of `HSC.SAV` (`sd_spi` CMD24; the
  words are read from PSRAM in the same free moments). Only those four
  blocks are ever written: no directory, no FAT. `HSC.SAV` must lie in one
  piece, which it does when clusters are 2K or more (the menu checks; with
  smaller clusters the HSC stays off).
* `devcart.py stats` shows: High Score Cart on/off, saves, failed saves,
  writes lost (queue full; 0 expected).

## HALT-free bank switching (builds 4a-4d)

Up to build 3g a SuperGame bank switch pulled HALT for the 243 us of the copy.
On the console that cost more than time: ARTI went black after its first
level with the music still playing. Its interrupt handler counts three
display-list interrupts per frame and never resynchronises; bus traces showed
the count slipped (the handler's long work now gets interrupted by the next
NMI). The explanation that fits: MARIA fired a display-list interrupt while
the cart held the 6502 frozen, and the 6502 never saw it.

Build 4a does not stop the 6502. While the `$8000` slot is refilled from PSRAM
die 0, the 6502's own reads of `$8000-$BFFF` are answered directly from die 1
(`cart_bus` px_*, `psram_dual` x_*): a 6502 cycle has ~500 ns, a PSRAM read
takes 160-200. MARIA, who has ~120 ns, keeps reading the slot (half old, half
new for those four scanlines, as before). In simulation the read still makes
it with the 6502 cycle shortened from 38 to 30 clocks. Games started from the
menu run this way; `devcart.py load` keeps HALT + copy unless `--no-halt`.
It took four console rounds:

* **4a** -- Gamma Force and Commando fine; ARTI wrong tiles; Impossible
  Mission and Tiger-Heli black.
* **4b** -- the copy engine owned the single slot write port, so the 6502's
  writes to cart RAM during a refill were dropped. Slot 0 got its own port.
  Counters added (`devcart.py stats`): PSRAM-served reads, reads whose byte
  never came, the slowest byte. They showed the bytes arrive in time.
* **4c** -- "is this the 6502's cycle or MARIA's?" was re-decided at every
  address change, and one disturbed address sample in the 6502's last cycle
  before DMA flipped it. Now decided from HALT and the filtered PHI2 edge.
  Impossible Mission ran; Tiger-Heli and ARTI still failed at random points.
* **4d** -- with Tiger-Heli stuck, the slots were correct but **die 1
  differed from die 0 in 518 words** (0 after a fresh load). The 6502 read
  path aborted a die-1 read (CS# high) as soon as the address moved on, and
  the bench test `devcart.py aborttest` showed what that does:

  | CS# raised ... after it fell | aborts | result |
  |---|---|---|
  | 1 clock | 2000 | no damage |
  | 2 clocks (mid command/address) | 10 | 496 of the 512 words of that 1 KB row garbled |
  | 3, 4, 5, 6, 7, 9, 12 clocks | 655350 each | no damage |

  Two clocks was the earliest abort the read path could issue, and the usual
  one when an address settled in two steps. It now waits 6 clocks. All nine
  test games run on the console.

After a HALT-free failure, compare the dies before anything else:
`devcart.py off`, then `devcart.py verify GAME.a78 [--dump FILE]`.

The cart no longer needs the HALT line for games started from the menu
(`devcart.py load` still uses HALT + copy unless `--no-halt`).

## Architecture (v2)

* The 48K the 6502 and MARIA can see lives in three 16K **BRAM slots**
  (`$4000`, `$8000`, `$C000`; 24 of the chip's 26 BSRAM blocks). The Atari
  only ever reads BRAM, through a fixed pipeline: data valid **3-4 clocks
  (45-60 ns)** after the address reaches the FPGA pins, whatever the address.
* The whole cart image lives in **PSRAM** (both dies, identical copies).
* A SuperGame **bank switch** (write to `$8000-$BFFF`) makes the cart pull
  HALT low through Q1 (the HALT bodge), copy the new 16K bank from PSRAM into
  the `$8000` slot in 16-word bursts (~230 us), and release HALT.
  `devcart.py load --no-halt` disables the HALT pull for experiments.
* Writes are taken at the falling edge of PHI2 (2-FF synchronized), and are
  ignored in any cycle where HALT was low (MARIA DMA, or our own halt).
  This is "build 2", the version that reached gameplay; later attempts to
  change the write capture (branch `wcap-experiments`) all crashed earlier.

## The corrupted slots (found on build 2h, fixed in build 2j, 2026-11-13)

Every build up to 2i corrupted about five words in each 16K it copied from
PSRAM into a BRAM slot -- at every load and at every bank switch, in
different places each time. That is what made every build fail in its own
way (wrong tiles, yellow screens, jams, a stuck title).

How it was found: bus captures on the garbled high-score screen showed
`$5591` reading `$23` where the ROM has `$22`, every time. That byte is the
high byte of `lda cutvec+1`, so the cut-scene's stripe interrupt routine
(320A + the bank's font) never ran. Build 2i added a slot read-back
(`devcart.py slots`), which reproduced the corruption with the Atari off:

* the PSRAM is innocent: a burst test of the whole image on both dies has 0 errors;
* the wrong word is always the one written to a slot address ending `...1000`,
  and it carries bits of the word written one clock later to `...1001`
  (reverse the order and the victim is `...1001`, the donor `...1000`);
* it follows the BRAM address, not the PSRAM word, the burst length or the
  spacing of the bursts.

So the GW1NR-9's BSRAM does not tolerate writes on consecutive clocks to
neighbouring addresses, although the design meets timing. Fix (2j): the copy
engine buffers each 16-word burst and writes one word every two clocks, with
address and data set up a clock before the write enable. A/B in one bitstream
(`devcart.py copyopt 0 1` restores the old writes): ~4 wrong words per copy
the old way, 0 in 150 copies (2.4 MB compared) the new way. A copy now takes
243 us. `devcart.py load` reads the slots back before it enables the cart;
`tools/slot_soak.py` repeats the copy test without an Atari.

The trace and histogram BRAMs are still written on consecutive clocks, so a
trace entry followed one clock later by another may carry bits of it.

## The yellow screen of build 2g (2026-11-13)

Recorded on 2g: 7800basic's BRK handler after a `BPL` operand read during
one-clock address spikes; 2h added the stable-address data filter. With the
slot corruption known, treat that as one observed route to a crash, not as
the cause of the crashes.

## Measured on the console (first test, 2026-11-12)

The first dev cart served reads straight from PSRAM. Its statistics showed
MARIA holding each DMA address for only **10-12 clocks at 81 MHz (123-148
ns)** -- one MARIA cycle -- and 4,362 "late" reads (address gone before the
data arrived). The game ran (BIOS signature check passed, POKEY set up, one
bank switch) and then the display died. CPU accesses hold ~550 ns, so only
MARIA is the problem -- and it rules out PSRAM on the bus for good. It also
explains V3: its BRAM path with the 4-sample glitch filter was ~80-110 ns,
close to MARIA's limit.

## What the PSRAM lab measured (81 MHz, both dies, millions of random reads)

* A random 16-bit read takes **13 cycles = 160 ns** from a registered request.
* About **0.012%** of reads per die collide with the die's internal refresh and
  take 16 cycles (198 ns).
* **Racing the two dies** (same data in both, same read to both, first answer
  wins) removed the collisions entirely: every one of millions of raced reads
  took 13 cycles. The cart reads this way.
* **Reads were error-free** at every request spacing.
* **Writes that collide with a refresh are silently lost** (~1 in 10,000). The
  collision only becomes visible on RWDS in cycle 6, after the 1x data slot
  (captured with an RWDS trace in the lab). So: every load is read back and
  retried (the loader does this), and nothing writes PSRAM during gameplay
  (cart RAM lives in BRAM).
* The inherited controller's CK path (`ck_e_p` -> CK ODDR on a +90° clock) had
  only a quarter period to meet timing and failed it in every build; V4
  clocks CK from +270° instead (same pin timing, three-quarter period).

## Timing

Earlier versions were also never timing-clean (V3 `main`: hundreds of failing
paths; V2's "81 MHz" design closed at ~44 MHz), which by itself produces random
corruption under load. **Every V4 build must have zero setup/hold violations.**

## Timing closure

The design is full (all 26 block RAMs but one, 73% of the logic, 6 of 10
multipliers at build 9a) and timing closes only by placement luck, which is
why `hw/devcart/build_clean.sh` sweeps placement seeds (`SEEDS="3 4 5"` to
choose) and removes the bitstream if no seed is clean. Build 9a closed on 5
of 6 seeds with a few hundredths of a nanosecond to spare; build 8b on 11 of
13.

## Console test procedure: multicart

1. Atari **off**, SD card (FAT32, `.a78` files in any directories) in the Tang Nano, USB-C to the Mac.
2. `openFPGALoader -b tangnano9k hw/devcart/build/impl/pnr/devcart.fs` (LED 1 on = cart enabled, in the menu)
3. Power on the Atari: "READING THE SD CARD", then the root directory. Up/down, left/right = page,
   fire = open the directory / start the game.
4. For another game: Atari off, step 2 again, Atari on.

`devcart.py stats` / `trace` work as before while a game runs; `devcart.py load FILE` still
replaces everything with a USB-loaded game.

## Console test procedure: one game over USB, with traces

1. Atari **off**, Tang Nano in the cart, cart in the Atari, USB-C to the Mac.
2. `openFPGALoader -b tangnano9k hw/devcart/build/impl/pnr/devcart.fs`
3. `python3 tools/devcart.py load ~/Software/Atari7800/AtariGammaForce/build/gammaforce.a78`
4. `python3 tools/devcart.py trace arm bank` (records the bus from the first
   DMA after the game's first bank switch)
5. Power on the Atari.
6. `python3 tools/devcart.py stats` and `python3 tools/devcart.py trace dump trace.txt`
7. With the Atari still running: `python3 tools/devcart.py verify GAME.a78`
   (turns the cart off, then checks PSRAM die 0 against die 1 -- does a
   running console disturb the PSRAM?). `load` again to re-enable.

To try another game: power the Atari off, `load` again, power on.
Other carts: Astro Wing (48K), Choplifter (32K), Commando (128K SuperGame +
POKEY @ $4000) all map with `tools/devcart.py info FILE`.

LEDs (on = lit): 0 heartbeat, 1 cart enabled, 2 loading / copying, 3 we
pulled HALT recently, 4 PHI2 activity, 5 HALT (DMA) activity.
