# Spin

A demo for the trig block of the AstroCart math unit (`docs/MATHUNIT.md`,
version 2: build 9a on). A cloud of 32 points turns about two axes and is
drawn in perspective, 60 times a second. Near points are big and white, far
ones small and blue. The stick changes the two speeds (left/right the spin,
up/down the tilt); fire flows the cloud into the next shape: cube, sphere,
torus, double helix.

It only runs where the trig block exists (an AstroCart with build 9a or
later, or the a7800 fork).

    ./build.sh          ->  build/spin.a78
    ./run_emu.sh            run it in the a7800 fork and check it against model.py

* `spin.bas` (7800basic): the main loop and the text.
* `transform.asm`: the arithmetic and the plotting. For every point, two
  rotations in the trig block, then a multiply, the accumulator and a divide
  for each screen coordinate. Nothing is kept in memory on the way: the
  results go from one part of the unit straight into the next.
* `model.py`: the shapes, and the same arithmetic in floating point.
  `run_emu.sh` dumps 15 frames from the emulator and compares every dot with
  it: all within one pixel (the trig block is not exact).

Notes:

* The angles are 16 bits and so are the speeds, which is why the cloud can
  turn as slowly as you like without stepping.
* A new shape is not switched to: each coordinate walks toward its new value,
  4 units a frame.
* Time, not arithmetic, was the problem. The arithmetic is about 300 cycles a
  point. Plotting a sprite costs about as much again, and with 7800basic the
  display lists may only change while MARIA is not reading them. Three things
  made 60 frames a second fit:
  * 7800basic's `PLOTSPRITE` macro, called from assembly, instead of 32
    `plotsprite` commands.
  * A dot is at most 5 lines high but a sprite is 8, so nearly every sprite
    crossed a zone boundary and needed two display list entries. There are 17
    sprites now, each size of dot at each height at which it fits in a zone,
    and a dot that fits is plotted once: 41 entries a frame instead of 60.
  * The arithmetic runs while the screen is being drawn and is done about
    line 150. The dots in the top 80 lines are plotted then (MARIA is past
    them), and only the rest in vertical blank.
* `set extradlmemory on` gives 24 display list entries a zone; the most the
  four shapes need is 12 (`model.py` with no arguments). It also means only
  `$2200-$22AF` is free for the demo's own memory.
