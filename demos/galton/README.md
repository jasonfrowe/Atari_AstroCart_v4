# Galton board

A demo for the AstroCart math unit (`docs/MATHUNIT.md`). Balls drop onto a
triangle of 28 pegs and collect in eight bins; the bins fill as a bell curve
(the central limit theorem, one bounce at a time). When a bin is full the
board pauses and starts again. Fire starts again at once.

It only runs where the math unit exists: on an AstroCart (the menu shows
`MATH` for it), or in the a7800 fork. Anywhere else it says so and stops.

    ./build.sh          ->  build/galton.a78

* `galton.bas` (7800basic): the display. 320A, one colour per object.
* `physics.asm`: the simulation, eight balls. Each ball-peg contact uses the
  unit for a square root (the distance, from the accumulator's
  `dx*dx + dy*dy`), three divides (the unit normal, and a shift) and six
  multiplies (approach speed, push-out, new velocity). The ball counter's
  decimal digits come from its divide too.
* `mkgfx.py` writes the sprites.

Tuning notes (2026-11-14, measured in the emulator over many rounds):

* Bounce keeps a quarter of the approach speed, and sideways speed decays by
  1/64 per frame. With a livelier bounce (half) and no drag the balls flew
  out of the triangle and the bins came out flat; with drag of 1/16 per frame
  everything fell into the two middle bins.
* Every rounding had to be symmetric. Dropping fractions with a plain
  arithmetic shift (toward minus infinity) made the board lean: the drag, the
  products' `>> 8`, and random kicks drawn from -8..7 each shifted the
  distribution visibly. Now: drag rounds toward zero, products round to
  nearest, kicks are the difference of two random numbers. Over eleven
  rounds the halves got 551 and 546 balls.
