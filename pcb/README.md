# AstroCart PCB

`AstroCart_V4/` is the KiCad 9 project for the next board revision. It
starts as an exact copy of the AstroCart_V2 board that everything in this
repository was developed on (same netlist: 25 parts, 86 nets; only the
project name changed), without V2's Gerbers and production files, which
would no longer match once the board is edited. The copy passes KiCad's
design rule check with schematic parity (0 violations, 0 unconnected); the
electrical rule check has one complaint, a power input with no power output
driving it, which is a matter of a PWR_FLAG.

The V2 board works with this repository's bitstream after two hand
modifications. They are the two changes to make here.

## Required changes

| | V2 as drawn | V2 as modified, and what to draw |
|---|---|---|
| 1 | Q1 (BSS138) drain on cartridge pin 31 (IRQ) | Q1 drain on cartridge **pin 2 (HALT)**. Net `/IRQ` at Q1 pin 3 becomes `/HALT` (which already goes to U5 pin 19) |
| 2 | Q1 gate (net `/T_IRQ`, Tang Nano pin 83) has nothing on it but the FPGA pin | **10 k from Q1's gate to GND.** Without it the gate floats high while the FPGA configures, Q1 pulls HALT during the console's power-on reset and some consoles do not start |

The details and the symptoms are in `docs/HARDWARE.md`. Renaming the net
`/T_IRQ` to `/T_HALT_PULL` would match the RTL (`halt_pull`); `/T_HALT` is
already the name of the HALT input through U5.

Since build 4 the cart does not pull HALT for games started from the menu
(bank switches are done without stopping the 6502). Only `devcart.py load`
without `--no-halt` still uses Q1. It is worth keeping on the board: it
costs two parts and is the only way the cart can stop the 6502.

## Suggestions for the same revision

Read from the schematic and from what the development turned up. None is
needed for the cart to work as it does now; the first two are the most
worthwhile.

1. **Audio filter.** R1 (1 k) and C8 (0.1 uF) form a low-pass with its
   corner at 1.6 kHz, so everything above that is attenuated (about 16 dB at
   10 kHz) before it reaches the console's audio input. The PWM carrier is
   264 kHz (67.5 MHz / 256), far above anything audible, so the corner can
   go much higher: 10 nF for C8 gives 16 kHz. This can be tried on the V2
   board first by changing the capacitor, and judged by ear against a real
   POKEY cart. (Not measured: this is from the component values.)
2. **A button for "back to the menu".** The only way back today is to
   power-cycle the FPGA. A push button on a free 3.3 V pin (Tang Nano pins
   68-75 are unconnected), reachable with the cart in the console, would let
   the bitstream do it. The Tang Nano's own buttons S1 and S2 (pins 4 and 3)
   could serve if they can be reached in the shell; a button on the board
   edge is easier to press. Needs RTL as well.
3. **A14 and A15 through U4.** A0-A13 come through SN74LVC245s on 3.3 V
   banks, A14 and A15 through the SN74LVC8T245 (U5) on the 1.8 V bank, so the
   two top address lines have different delays and thresholds from the rest;
   the bus logic waits for two equal samples because of it. U4 has two unused
   channels (A1/B1, A2/B2, inputs tied to ground now) and the Tang Nano has
   free 3.3 V pins, so all sixteen could take the same path. This changes
   the pin constraints, and the present arrangement works; do it only if the
   board is being re-routed there anyway.
4. **IRQ, if it is ever wanted** (POKEY interrupts, for example): its own
   BSS138 with a gate pull-down, on a free pin. U5's eighth channel (A8/B8)
   is free if the cart should also read the line.
5. **Test points** for PHI2, HALT, R/W, A15 and a data line at the cartridge
   edge: every timing question in this project was answered with a probe on
   those.

Things looked at and left alone: D2 (SS14) keeps USB power from back-feeding
the console; U5's B side and the 1.8 V regulator run from the console's 5 V
only, and the SN74LVC8T245 isolates its A side when that is off, so
USB-only operation on the bench is fine; R2 holds the data-bus driver off
until the FPGA is configured.
