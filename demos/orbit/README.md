# Orbit

A small game for two players on the trig block of the AstroCart math unit
(`docs/MATHUNIT.md`, version 2: build 9a on). Two ships (green and orange)
circle a star, half a turn apart. Each player aims with their stick (left /
right; two dots show the direction), sets the power (up / down; the dots
spread out) and launches a probe with fire. The star's gravity bends its
path, and it leaves a trail. Whoever's probe hits the moon (grey) scores a
point, and the moon moves to another orbit, sometimes the other way round.
A probe is lost when it falls into the star, flies 400 lines away or has
flown for 21 seconds; fire launches a new one at any time. One player can
play alone: the second ship just circles.

It only runs where the trig block exists (an AstroCart with build 9a or
later, or the a7800 fork).

    ./build.sh          ->  build/orbit.a78
    ./run_emu.sh            play it in the a7800 fork from a script, and check it

* `orbit.bas` (7800basic): the main loop, the text and the star.
* `game.asm`: the game. The trig block does all of the geometry:
  * the moon and the ships are `(radius, 0)` turned by their orbit angle;
  * the aim dots and the launch velocity are `(step, 0)` and `(speed, 0)`
    turned by the aim angle;
  * gravity: the trig block gives the probe's direction and distance from
    the star (ANG, LEN); `K / LEN / LEN` (two divides) is the acceleration,
    and `(a, 0)` turned by ANG plus half a turn is its vector;
  * a hit is LEN of (probe - moon) under 5 lines.

  The multiplier scales positions to the screen.
* `check.py`: `run_emu.sh` has player 1 launch a probe along the ship's
  orbit, logs 800 frames of its flight and compares them with the same
  motion in floating point (2.5 lines apart at the worst, after one and a
  third orbits); then it puts player 2's probe on the moon and expects the
  point to go to player 2; and it counts the frames (none dropped).

Notes:

* The second divide is rounded (half of LEN is added to the dividend first).
  Truncated, gravity was 0.3% weak and the probe ended 8 lines from the
  floating-point path.
* The two scores are drawn from RAM, so new digits appear without redrawing
  the screen.
* Plotting follows `demos/spin`: `PLOTSPRITE` from assembly, in vertical
  blank, after the arithmetic.
* `PLOTSPRITE` does not check whether a zone's display list is full. With 25
  objects and room for 24 in a zone, the plot loop checks it itself.
* The game puts both ports in one-button mode and reads the fire lines
  itself, so a 7800 pad (either button) or a 2600 joystick works in either
  port. In two-button mode, where 7800basic starts, a 2600 joystick in port
  2 did not fire on the console (it did in the emulator).
