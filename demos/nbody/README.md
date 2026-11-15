# N-body gravity

A demo for the AstroCart math unit (`docs/MATHUNIT.md`): up to four bodies,
every pair attracting each other with a 1/r^2 force, at 60 steps a second.
Four scenarios, 45 seconds each; fire skips to the next.

* **Star and planets**: three planets on near-circular orbits.
* **Binary star**: two equal stars round each other, two planets round both.
* **Figure eight**: three equal masses chasing each other along one
  figure-eight curve (the Chenciner-Montgomery solution).
* **Planet and moon**: a star, a planet with a moon, and an inner planet.

It only runs where the math unit exists (an AstroCart, or the a7800 fork).

    ./build.sh          ->  build/nbody.a78

* `nbody.bas` (7800basic): the display. Each body leaves four trail dots.
* `physics.asm`: the simulation. Per pair and frame: the accumulator and a
  square root for the distance, six divides (the unit vector, and GM/r^2 for
  each of the two bodies) and four multiplies.
* `model.py`: the same arithmetic in Python, operation for operation. It was
  used to choose the constants and the scenarios, it writes the scenario
  tables for the build, and the 6502 code was checked against it in the
  emulator: after 545 steps every position and velocity was identical.

Notes:

* Positions and velocities have 14 fractional bits. With 6, as in the Galton
  board, the accelerations (around 1/100 pixel per frame squared) would
  round to nothing.
* GM/r^2 is two unsigned 32/16 divides, (K / r) / r with K = GM * 2^26, so
  the star's constant fits in 32 bits and the result keeps 14 fractional
  bits. A light planet's pull on a distant star rounds down to zero while
  the star's pull on the planet does not, so momentum is not exactly
  conserved: in the first scenario the whole system drifts about 10 pixels
  in 45 seconds. More fractional bits there would cure it.
* The force is softened (r^2 + 5^2 pixels) so that a close pass cannot throw
  a body out of the picture; the starting speeds allow for it.
* Five bodies (ten pairs) take slightly more than one frame, so the
  scenarios stop at four.
