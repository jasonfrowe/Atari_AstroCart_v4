# AstroCart V4: an Atari 7800 multicart on a Tang Nano 9K

AstroCart is a cartridge for the Atari 7800 built around a Sipeed Tang Nano
9K FPGA board. It starts in a menu, lists the `.a78` files on a microSD
card, and runs the one you pick. It also has a High Score Cart, POKEY sound,
and a fixed-point math unit for new programs.

It runs on the AstroCart_V2 circuit board with two hand modifications
([docs/HARDWARE.md](docs/HARDWARE.md)); the next board revision is in
[pcb/](pcb/README.md).

| | |
|---|---|
| [docs/MATHUNIT.md](docs/MATHUNIT.md) | the math unit: registers, accuracy, examples, demos |
| [docs/HARDWARE.md](docs/HARDWARE.md) | the board, the two modifications, pins |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | how it works inside, and the history of getting it to work |
| [pcb/README.md](pcb/README.md) | the KiCad project and the changes for the next board |

## What it does

* **Menu.** Browses the card's directories; file names are the titles.
  Up / down move, left / right page, fire opens a directory or starts a
  game. Two lines show the selected file's title, size, mapper, POKEY and TV
  system from its header.
* **SD card.** FAT32, with or without a partition table (MBR or GPT), long
  file names, any directory depth.
* **Cart types**, chosen from the `.a78` header:
  * linear ROM, 8K to 48K, with or without 16K RAM at `$4000`
  * SuperGame up to 512K: plain, with RAM, or with ROM at `$4000`
  * SuperGame up to 255 banks (4 MB), for the 528K and 1024K carts
  * Absolute (F-18 Hornet)
  * Activision (Double Dragon, Rampage), both dump orders
  * mirror RAM
* **POKEY** at `$4000`, `$0450`, `$0800` or `$0440`, and two POKEYs at
  `$0450` + `$0440`.
* **High Score Cart.** Its ROM and RAM come from the card, and the scores are
  written back to the card.
* **Math unit.** For programs written for this cart: 16 x 16 multiply,
  32 / 16 divide, square root, a 32-bit accumulator, a random byte, and a
  trig block (turn a vector by an angle; the angle and length of a vector).
  See [docs/MATHUNIT.md](docs/MATHUNIT.md).
* **Loading over USB.** A game can be sent straight from a computer instead
  of from the card, with bus statistics and a bus trace for debugging.

## What it does not do

* **Other cart hardware:** banked RAM, SOUPER, banksets, YM2151, COVOX and
  the XM are not implemented. Such a file shows NOT SUPPORTED in the menu.
* **Return to the menu from a game.** The way back is to power-cycle the
  FPGA: console off and USB unplugged, or reload the bitstream. A console
  power cycle alone restarts the game if USB keeps the FPGA running.
* **Saves** other than the High Score Cart's.
* **exFAT.** Cards over 32 GB usually come formatted that way; reformat
  them as FAT32.
* **More than 255 entries in one directory.** The first 255 found are shown.
  Titles are cut to 32 characters.
* **PAL** has not been tried: all testing was with NTSC files.
* **POKEY** is the sound half of the chip only, and its pitch has not been
  compared against a real one.

## What you need

To use it:

* An AstroCart_V2 board with the two modifications in
  [docs/HARDWARE.md](docs/HARDWARE.md), and a Tang Nano 9K.
* A microSD card, FAT32.
* [openFPGALoader](https://github.com/trabucayre/openFPGALoader) to put the
  bitstream on the Tang Nano (`brew install openfpgaloader` on a Mac), and a
  USB-C cable.
* A bitstream: `devcart.fs` from this repository's GitHub releases, or built
  as below.

To build it and to work on it:

| Software | Used for | Where the scripts look |
|---|---|---|
| [Gowin IDE](https://www.gowinsemi.com/en/support/download_eda/) (Education edition is enough for the GW1NR-9) | the bitstream | `GOWIN_BIN`, default `/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin` |
| [7800basic](https://github.com/7800-devtools/7800basic) (a release; it includes `dasm`) | the menu ROM, the demos, the math self-test | `bas7800dir`, default `~/Software/Atari7800/7800basic` |
| Python 3 | every tool in `tools/` (standard library only) | `python3` |
| openFPGALoader | loading and flashing | `openFPGALoader` |
| [Verilator](https://verilator.org) 5 and a C++ compiler | the simulations in `sim/` | `verilator` |
| The [a7800 fork](https://github.com/jasonfrowe/a7800) (MAME-based, with the math unit) | running math-unit programs in an emulator; the demos' and self-test's `run_emu.sh` | `A7800`, default `~/Software/a7800/mame64` |
| [KiCad](https://www.kicad.org) 9 | the board in `pcb/` | |

Only the first four are needed to build and load the cart. The serial tools
use a POSIX serial port (macOS or Linux).

## Getting started

1. **Put the bitstream in the Tang Nano's flash** (once; console off):

   ```bash
   openFPGALoader -b tangnano9k -f devcart.fs
   ```

2. **Prepare the card.** Copy `.a78` files (with their 128-byte headers)
   anywhere on a FAT32 card, in any directories.

3. **For high scores**, add the High Score Cart's two files. You supply the
   HSC ROM as an `.a78` file (128 + 4096 bytes):

   ```bash
   python3 tools/mkhsc.py "High Score Cartridge.a78" OUTDIR
   ```

   and copy `OUTDIR/ASTROCART` to the root of the card. It holds `HSC.A78`
   (the ROM) and `HSC.SAV` (the scores, 2K). An existing `HSC.SAV` is kept.

4. **Card in the Tang Nano, cart in the console, power on.** The menu shows
   "READING THE SD CARD", then the root directory.

LEDs on the Tang Nano (lit = on): 0 heartbeat, 1 cart enabled, 2 loading,
3 HALT pulled recently, 4 PHI2 activity, 5 HALT (DMA) activity.

## Building

```bash
./build.sh                    # build the menu ROM and the bitstream
./build.sh sram               # build, then load into the FPGA's SRAM
./build.sh flash              # build, then write to the FPGA's flash
./build.sh sram  --no-build   # load the bitstream that is already built
./build.sh flash --no-build
```

* **SRAM** is for trying a build: a few seconds, and gone when the FPGA
  loses power (USB unplugged and console off). The FPGA then starts from
  whatever is in flash.
* **Flash** is for the build to keep: loaded at every power-on, so the cart
  works without USB. Writing takes about half a minute.
* Either way the cart restarts in the menu, so switch the console off first.

The bitstream is `hw/devcart/build/impl/pnr/devcart.fs`. The build tries
placement seeds until one meets timing (a few minutes each), because the
FPGA is nearly full; if none does, it removes the bitstream instead of
leaving a bad one. `SEEDS="3 4 5" ./build.sh` chooses the seeds.

The steps by hand:

```bash
menu/build.sh                 # 7800basic -> menu/build/menu.bin (goes into the bitstream)
hw/devcart/build_clean.sh     # Gowin synthesis, place and route, seed sweep
openFPGALoader -b tangnano9k    hw/devcart/build/impl/pnr/devcart.fs    # SRAM
openFPGALoader -b tangnano9k -f hw/devcart/build/impl/pnr/devcart.fs    # flash
```

## Loading a cart over USB: devcart.py

`tools/devcart.py` talks to the cart over the Tang Nano's USB serial port
(230400 baud; it finds `/dev/cu.usbserial-*1` by itself, or `--port PATH`).
It sends a game from the computer, without the SD card:

```bash
python3 tools/devcart.py info GAME.a78     # how the header would be mapped; nothing is sent
```

1. Console **off**, USB connected, bitstream running.
2. `python3 tools/devcart.py load GAME.a78`
   The file goes into the cart's memory, is read back and compared, and the
   cart is switched on with that game in place of the menu. A 32K game
   takes about 2 seconds; the upload runs at about 23 kB a second.
3. Console on: the game starts. To change game: console off, `load` again.

The game stays loaded for as long as the FPGA has power, so the console can
be switched off and on. The math unit is enabled from the header just as the
menu does it. `load --no-halt` switches banks without stopping the 6502, as
games started from the menu do; without it the older stop-and-copy method is
used.

While a game runs:

```bash
python3 tools/devcart.py ident             # is the cart there? -> AC78V4 <enabled> <trace> <bank>
python3 tools/devcart.py stats             # bank switches, POKEY writes, High Score Cart saves, ...
python3 tools/devcart.py trace arm now     # record 512 bus cycles from now
python3 tools/devcart.py trace arm bank    #   ... or from the next bank switch
python3 tools/devcart.py trace dump FILE
python3 tools/devcart.py off               # stop driving the bus
```

With the console off, the card can be exercised from the computer the way
the menu does it:

```bash
python3 tools/devcart.py sd ls [DIR]                           # a directory, as the menu lists it
python3 tools/devcart.py sd load DIR/NAME --check GAME.a78     # load, start, compare with a local copy
```

`python3 tools/devcart.py --help` lists everything.

## Programs for the math unit

A program asks for the math unit with three bytes in its `.a78` header
(`tools/a78math.py FILE.a78` sets them). The definition, with examples, is
[docs/MATHUNIT.md](docs/MATHUNIT.md). The a7800 fork implements the same
unit bit for bit, so such programs can be developed in the emulator.

Five demos, in 7800basic with assembly for the arithmetic; each directory
has a README, and `demos/NAME/build.sh` makes `demos/NAME/build/NAME.a78`:

| | |
|---|---|
| `demos/galton` | a Galton board: balls, pegs and a bell curve |
| `demos/nbody` | gravity between up to four bodies, four scenarios |
| `demos/gas` | twelve discs in a box, and their speed distribution |
| `demos/spin` | a 3D point cloud turning in perspective (trig block) |
| `demos/orbit` | a game for two: launch probes at a moon round a star (trig block) |

`tests/mathtest` is the unit's self-test cart: 13,130 register checks against
the reference model, green screen for a pass.

## Tests without a console

```bash
(cd sim/math && make)              # the math unit's Verilog against its reference model
(cd sim/devcart && make)           # the cart: load, mappers, 6502 and MARIA-style traffic
(cd sim/multicart && make run)     # menu + SD card model + every mapper, 6502 code included (15 minutes)
(cd sim/pokey && make)             # POKEY
tests/mathtest/run_emu.sh          # the math self-test in the a7800 fork
```

`sim/multicart` loads the carts in `tests/carts`, and adds more cases if
Trebor's 7800 ROM PROPack is at `$PROPACK` (default
`~/Downloads/Trebors 7800 ROM PROPack v8_17`).

## Layout

```
rtl/cart/cart_bus.v      the 7800 bus: address filter, BRAM slots, write capture, bank switches
rtl/dev/devcart_top.v    top level: USB loader and commands, PSRAM-to-slot copy, menu registers
rtl/psram/               PSRAM controller, and both dies raced
rtl/sd/sd_spi.v          SD card, SPI mode
rtl/audio/               POKEY (sound) and PWM output
rtl/math/astromath.v     the math unit
menu/                    the menu: menu.bas (7800basic), fat.asm (card, FAT32, loader, launch)
hw/devcart/              pin constraints and the Gowin build
tools/                   devcart.py (USB), mkhsc.py, a78math.py, mkfat32.py (card images for tests)
sim/                     Verilator testbenches; sim/math/astromath.h is the math unit's reference model
tests/mathtest/          the math unit's self-test cart
tests/carts/             directory for test cart images (see tests/carts/README.md)
demos/                   programs for the math unit
lab/psram_lab/           the bitstream that characterised the PSRAM
pcb/                     KiCad project for the next board revision
docs/                    MATHUNIT, HARDWARE, DEVELOPMENT
```

## Licence

AstroCart V4 is free software under the GNU General Public License, version
3 or (at your option) any later version; see [LICENSE](LICENSE). It comes
with no warranty.

That covers what was written for this project: the Verilog in `rtl/`, the
menu, the tools, the simulations, the demos, the documents and the board in
`pcb/`. It does not cover third-party cart images
([tests/carts/README.md](tests/carts/README.md)), nor the pieces below that
came from elsewhere under their own terms.

## Credits

* **PSRAM controller.** `rtl/psram/psram_ll.v` is derived from Feng Zhou's
  (nand2mario) [PSRAM/HyperRAM controller for the Tang Nano
  9K](https://github.com/zf3/psram-tang-nano-9k), Apache License 2.0.
* **6502 for the simulation.** `sim/third_party/fake6502` is Fake6502 by Mike
  Chambers as modified by the [LLVM-MOS
  project](https://github.com/llvm-mos/llvm-mos-sdk), Apache License 2.0
  with LLVM exceptions; an unmodified copy, used only by `sim/multicart`.
* **7800basic** by Michael Saarna, derived from Fred Quimby's batari Basic:
  the menu and the demos are written in it, and assembled with the `dasm`
  it ships. `menu/gfx/menufont.png` is the `atascii.png` font from its
  samples. The built menu ROM inside the bitstream contains 7800basic's
  runtime (its 6502 code is CC0).
* **a7800**, the MAME-based Atari 7800 emulator by Mike Saarna and Robert
  Tuccitto: the mapper definitions here follow its source, and the
  [fork](https://github.com/jasonfrowe/a7800) with the math unit is how
  programs for it are developed.
* **POKEY.** `rtl/audio/pokey.v` was written for this project from the
  description in Avery Lee's Altirra Hardware Reference Manual.
* **Trebor's 7800 ROM PROPack** supplied the test files for the mappers
  beyond the eight in `tests/carts`.
* **Tools:** the Gowin EDA software, Verilator, openFPGALoader, KiCad.
