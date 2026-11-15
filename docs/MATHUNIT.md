# AstroCart math unit (version 2)

A fixed-point arithmetic unit for programs written for this cart: 16x16
multiply, 32/16 divide, 32-bit square root, a 32-bit accumulator for sums of
products, a pseudo-random byte, and (version 2) a trig block: turn a vector
by an angle, and find the angle and length of a vector. It is **not** part of any published 7800
standard; this file is its definition. The a7800 emulator fork
(`~/Software/a7800`) and the FPGA implement exactly what is written here,
bit for bit, and `tests/` programs compare the two.

Status (2026-11-15): version 1 (`$0430-$043F`) is in the a7800 fork, the FPGA
(build 8a on) and passes `tests/mathtest` on the console. Version 2 adds the
trig block at `$0420-$042F` (branch `cordic` here and in the fork, build 9a):
passes `tests/mathtest` in the emulator, in simulation and on the console.
Both are on `main`.

## Enabling it: the .a78 header

The unit exists only for a program whose header asks for it. Bytes 59-61 of
the 128-byte .a78 header (reserved in header versions 3 and 4) hold the three
characters

```
offset 59: $41 'A'    offset 60: $43 'C'    offset 61: $4D 'M'
```

Without them nothing answers at `$0420-$043F`. With them the unit sits beside
whatever mapper, POKEY or High Score Cart the header also asks for.
`tools/a78math.py FILE.a78` sets the bytes (`--off` clears them).

A program can also check at run time: `$043F` reads `$A1` when the unit is
there (open bus otherwise), and `$042F` reads `$A2` when it has the trig
block (version 2).

## Registers

All values are little endian. Writes and reads use different registers at
the same addresses.

| Address | Write | Read |
|---|---|---|
| `$0430-$0431` | **A** (16 bits) | **P** bits 0-15 |
| `$0432-$0433` | **B** (16 bits) | **P** bits 16-31 |
| `$0434-$0437` | **N** (32 bits) | **Q** (32 bits) |
| `$0438-$0439` | **D** (16 bits) | **R** (16 bits) |
| `$043A` | **CTRL** | **S** bits 0-7 |
| `$043B` | **CMD** | **S** bits 8-15 |
| `$043C` | - | CTRL |
| `$043D` | - | STATUS |
| `$043E` | **SEED** | **RND** |
| `$043F` | - | ID = `$A1` |

Results:

* **P = A x B** (32 bits).
* **Q = N / D**, **R = N mod D**.
* **S = floor(sqrt(N))**, N taken as unsigned. Always 16 bits.

Every result is a pure function of the registers it names: it changes when
one of them is written and is valid by the time the 6502 can read it (the
very next instruction). There is no start command and no busy flag to poll.

### CTRL (`$043A` write, `$043C` read)

| Bit | Meaning |
|---|---|
| 0 | SIGNED: 0 = A, B, N, D are unsigned; 1 = two's complement |
| 1-7 | write 0 |

Signed arithmetic: P is the 32-bit signed product. Q is rounded toward zero
and R has the sign of N (as in C): `-7 / 2` gives Q = -3, R = -1.
`$80000000 / -1` gives Q = `$80000000`, R = 0.

Division by zero (D = 0, either mode): Q = `$FFFFFFFF`, R = N bits 0-15, and
STATUS bit 0 is set.

### CMD (`$043B` write): the accumulator

A 32-bit accumulator ACC for sums of products (dot products, r squared).
Writing CMD does one thing, at once:

| Value | Action |
|---|---|
| 1 | ACC = 0 |
| 2 | ACC = ACC + P |
| 3 | ACC = ACC - P |
| 4 | N = ACC |
| other | nothing |

ACC wraps at 32 bits. It has no read address of its own: copy it to N
(CMD 4) and read S for its square root, or Q with D = 1 for its value.

### STATUS (`$043D` read)

| Bit | Meaning |
|---|---|
| 0 | DIVZERO: D is 0 |
| 7 | BUSY: always 0 in version 1 (reserved for slower units) |

### RND and SEED (`$043E`)

A 32-bit xorshift generator X. Each **read** of `$043E` steps it once and
returns the new X bits 0-7:

```
X ^= X << 13;   X ^= X >> 17;   X ^= X << 5;      (32 bits)
```

Each **write** shifts a byte into the seed: `X = (X << 8) | value`; if that
makes X zero, X becomes 1. Four writes set the whole seed. Power-on: X = 1.

The sequence is fixed, so a program wanting different runs seeds it from
something a person does (frames until the first button press, for example).

Use `LDA $043E` to read it. Instructions that read their operand twice or
make a dummy read (`INC abs`, indexed modes that cross a page) step the
generator more than once.

### Power-on / reset

A, B, N, D, CTRL, ACC = 0; X = 1. The console has no reset line on the
cartridge port, so a program should not assume this after a warm start:
write what it uses.

## Trig block (`$0420-$042F`, version 2)

| Address | Write | Read |
|---|---|---|
| `$0420-$0421` | **X** (16 bits, signed) | **XR** (16 bits, signed) |
| `$0422-$0423` | **Y** (16 bits, signed) | **YR** (16 bits, signed) |
| `$0424-$0425` | **T** (angle, 16 bits) | **ANG** (angle, 16 bits) |
| `$0426-$0427` | - | **LEN** (16 bits, unsigned) |
| `$0428-$042E` | - | `$00` |
| `$042F` | - | VERSION = `$A2` |

Angles are binary: `$10000` is a full turn, so `$4000` is a quarter turn and
the high byte alone is an angle in 256ths of a turn. They wrap, which is what
angles should do.

Results (the same rule as the rest of the unit: functions of X, Y and T,
valid by the next instruction, nothing to start or wait for):

* **(XR, YR) = (X, Y) turned by T**: `XR = X cos T - Y sin T`,
  `YR = X sin T + Y cos T`. Clamped to -32768..32767 (a vector longer than
  32767 can turn into one that does not fit; it never wraps).
* **ANG = the direction of (X, Y)**: atan2(Y, X). (1, 0) is 0, (0, 1) is
  `$4000`, (-1, 0) is `$8000`, (0, -1) is `$C000`. X = Y = 0 gives 0.
* **LEN = the length of (X, Y)**, rounded to nearest.

CTRL does not apply here: X and Y are always signed.

Sine and cosine are the rotation of a vector along the X axis: write the
amplitude to X, 0 to Y and the angle to T; XR is `amplitude x cos T`, YR is
`amplitude x sin T`. Polar to rectangular is the same thing (X = r, T =
angle); rectangular to polar is ANG and LEN.

On a screen Y runs downward, so a positive T turns clockwise as seen and ANG
is measured clockwise from "right".

### Accuracy

The block is a CORDIC (18 shift-and-add steps). Its results are close to the
exact values but not correctly rounded, and the reference model's arithmetic
is the definition (the emulator and the FPGA give the same bits). Measured by
`sim/math/selftest` over 3 million random vectors and angles:

| Result | Largest error |
|---|---|
| XR, YR | 1.45 (mean 0.25) |
| LEN | 0.96 |
| ANG | 0.73 angle units for long vectors; for short ones, less than 1 unit of distance at the vector's tip |

Exact cases: T a multiple of a quarter turn (T = 0 returns X and Y
unchanged); ANG of a vector along an axis or a diagonal, e.g. (1, 1) gives
`$2000`.

A 16-bit angle is finer than a 16-bit coordinate can show: at a radius of
32767 one angle unit moves the tip by 3 units.

### Example: aim and move

```
        ; dx, dy = target - me (signed 16-bit). Which way, and how far?
        lda dx      : sta $0420
        lda dx+1    : sta $0421
        lda dy      : sta $0422
        lda dy+1    : sta $0423
        lda $0425   : sta heading   ; direction in 256ths of a turn
        lda $0426   : sta dist      ; distance
        lda $0427   : sta dist+1

        ; velocity = speed along heading (speed in 8.8)
        lda speed   : sta $0420
        lda speed+1 : sta $0421
        lda #0      : sta $0422 : sta $0423 : sta $0424
        lda heading : sta $0425
        lda $0420   : sta vx        ; speed x cos
        lda $0421   : sta vx+1
        lda $0422   : sta vy        ; speed x sin
        lda $0423   : sta vy+1
```

## Fixed point

There is no shift register because none is needed: read the product at the
byte offset that suits the format. For 8.8 x 8.8 -> 8.8, read P bytes 1 and
2 (`$0431`, `$0432`). For 8.8 / 8.8 -> 8.8, write the dividend to N shifted
left 8 bits (bytes 1-3, byte 0 = 0).

## Example: distance between two points

```
        ; dx, dy: signed 16-bit
        lda #1      : sta $043A     ; signed
        sta $043B                   ; ACC = 0   (A = 1)
        lda dx      : sta $0430 : sta $0432
        lda dx+1    : sta $0431 : sta $0433
        lda #2      : sta $043B     ; ACC += dx*dx
        lda dy      : sta $0430 : sta $0432
        lda dy+1    : sta $0431 : sta $0433
        lda #2      : sta $043B     ; ACC += dy*dy
        lda #4      : sta $043B     ; N = ACC
        lda $043A   : sta r         ; r = sqrt(dx*dx + dy*dy)
        lda $043B   : sta r+1
```

## Self-test

`tests/mathtest/build.sh` builds `build/mathtest.a78`, a 32K cart that plays a
script of register writes and expected reads (generated from the reference
model by `gen.cpp`: 400 random and edge-case operand sets in both modes, the
accumulator, the random generator and its seed; then 190 vectors and angles
through the trig block). Green screen = pass, red =
fail; the details are in zero page (`$44` status, see `mathtest.asm`).
`tests/mathtest/run_emu.sh` runs it in the emulator, headless.

## In the FPGA

`rtl/math/astromath.v`: one hardware multiplier (product two clocks after an
operand changes), a restoring divider (one bit per clock, 34 clocks) and a
bit-per-clock square root (17 clocks), all restarted by a write to what they
depend on -- against roughly 110 clocks between a 6502 write and the next
instruction's read. The trig block is one CORDIC datapath (22-bit vector,
21-bit angle). A step takes two clocks (shift, then add or subtract), so the
datapath is a ring of two register stages and the two jobs follow each other
round it: the angle and length of (X, Y) in one stage while the rotation is
in the other. After any write to X, Y or T both are done in about 45 clocks;
a vector only a few units long is first scaled up one bit per clock (up to
16 more) so that its angle is as good as a long one's, and the length comes
3-19 clocks after the angle. The shifts are done by hardware multipliers
(v >> i = v x 2^(17-i) / 2^17: two 36 x 36), and three 18 x 18 multipliers do
the scaling by 1 / (the CORDIC gain) and the quarter turns; the FPGA has
them to spare, and logic is what is short. `sim/math` checks the
module alone against the reference model (400,000 random operations, 64 and
110 clocks apart). `sim/multicart/run.sh`
loads `mathtest.a78` from a card image through the menu code and lets the
6502 model run it, with MARIA's DMA and the address-line disturbances seen on
the console modelled.

Two things the bus logic (`cart_bus.v`) does for it:

* The read path is combinational from the address, like the menu's registers,
  so the existing filter (data frozen while the address is unsettled) covers
  it.
* The random generator (the only register whose read has a side effect) steps
  at the end of a 6502 read cycle in which the address was `$043E` for at least 12 clocks of the 6502's own bus time. One
  sample would not do: a one-clock disturbance on A2 during a read of `$043A`
  looks like `$043E`, and after DMA the old address sits on the bus until the
  6502 carries on.

The menu turns the unit on from the header (mapper register bit 5; info line
`MATH`); `devcart.py load` does the same over USB.

## Demos

`demos/NAME/build.sh` builds `build/NAME.a78`; each has a README.

| Demo | Uses |
|---|---|
| `galton` | a Galton board: multiply, divide, square root, random |
| `nbody` | gravity between bodies: accumulator, square root, divide |
| `gas` | discs colliding in a box, and their speed distribution |
| `spin` | a 3D point cloud: the trig block for both rotations, multiply and divide for perspective |
| `orbit` | a game for two players, probes under a star's gravity: the trig block's angle and length for gravity and hits, rotations for everything that moves |

## Reference model

`sim/math/astromath.h` (C++, no dependencies) is the reference. The a7800
fork carries the same file as `src/devices/bus/a7800/astromath.h`; keep the
two identical.
