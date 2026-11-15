# Gas in a box

A demo for the AstroCart math unit (`docs/MATHUNIT.md`). Twelve discs bounce
off the walls and off each other. Underneath, eight bars show how fast they
are going, slowest on the left, and a dash over each bar shows where the
Maxwell-Boltzmann distribution (in two dimensions: the Rayleigh distribution)
puts it. The discs all start at the same speed, so the first picture is a
single tall bar; the collisions spread it out. Fire starts again with other
directions.

It only runs where the math unit exists (an AstroCart, or the a7800 fork).

    ./build.sh          ->  build/gas.a78

* `gas.bas` (7800basic): the display.
* `physics.asm`: the simulation. A collision uses the accumulator twice
  (`d.d` and `dv.d`), a square root, four divides (two of them used as
  shifts) and four multiplies; every disc's speed, every frame, is the
  accumulator and a square root.
* `model.py`: the same arithmetic in Python, operation for operation. It
  chose the constants, writes the tables for the build, and the 6502 code was
  checked against it in the emulator: after 2,844 steps every position and
  velocity was identical.

Notes:

* The collision exchanges the velocity along the line of centres as
  `k d` with `k = (dv.d) / (d.d)`. The first version normalised `d` to a unit
  vector with the unit's (truncating) divide, as the Galton board does; every
  collision then lost about 2% of its energy and the gas cooled to a fifth of
  its energy in five minutes. As it is now the model keeps 99.6% after a
  minute and 92% after five.
* The bars are a running average over about eight windows of 128 frames (17
  seconds). One window of twelve discs is far too noisy: a disc keeps its
  speed between collisions, and there are only about four collisions a
  second.
* Measured in the model over 4.5 minutes, the fractions per bin were
  0.080 0.178 0.256 0.231 0.154 0.066 0.025 0.010 against the theory's
  0.078 0.200 0.242 0.209 0.141 0.077 0.035 0.018.
