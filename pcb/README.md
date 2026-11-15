# AstroCart PCB

`AstroCart_V4/` is the KiCad project for the V4 board revision. It builds
upon the original AstroCart_V2 board that development was done on,
incorporating the required hardware bodges and an audio filter improvement.

## Changes implemented in V4

The V2 prototype board required hand modifications to operate reliably. These
modifications, along with an audio low-pass filter component update, have been
incorporated into the V4 schematic and PCB layout:

| | V2 as drawn | V4 implementation |
|---|---|---|
| 1 | Q1 (BSS138) drain on cartridge pin 31 (`IRQ`) | Q1 drain routed to cartridge **pin 2 (`HALT`)**. In schematic/PCB, gate net is `/Q_HALT` (Tang Nano pin 83). Allows the FPGA to pull HALT low to stop the 6502 (e.g., during `devcart.py load`). |
| 2 | Q1 gate had no pull-down resistor (floated during FPGA configuration) | Added **R5 (10 kΩ, 0805)** from Q1 gate (`/Q_HALT`) to GND. Prevents Q1 from conducting and asserting HALT during console power-on reset. |
| 3 | Audio low-pass filter: R1 = 1 kΩ, C8 = 0.1 µF (cutoff ~1.6 kHz) | Updated **C8 to 10 nF** (with R1 = 1 kΩ), raising the low-pass cutoff to **~16 kHz**. Keeps audio clear without attenuating audible high frequencies while still filtering the 264 kHz PWM carrier. |

Background context, timing observations, and startup symptoms without the gate
pull-down are documented in [docs/HARDWARE.md](../docs/HARDWARE.md).

Since build 4, the cart does not pull HALT for games started from the menu
(bank switches are handled without stopping the 6502). Only `devcart.py load`
without `--no-halt` uses Q1. It remains on the board because it costs minimal
parts and provides the only mechanism for the cart to stop the 6502.

## Remaining suggestions for future revisions

Read from the schematic and from development findings. None of these are
strictly necessary for the cart to function as intended:

1. **A button for "back to the menu".** The only way back today is to
   power-cycle the FPGA. A push button on a free 3.3 V pin (Tang Nano pins
   68-75 are unconnected), reachable with the cart in the console, would let
   the bitstream do it. The Tang Nano's own buttons S1 and S2 (pins 4 and 3)
   could serve if they can be reached in the shell; a button on the board
   edge is easier to press. Needs RTL as well.
2. **A14 and A15 through U4.** A0-A13 come through SN74LVC245s on 3.3 V
   banks, A14 and A15 through the SN74LVC8T245 (U5) on the 1.8 V bank, so the
   two top address lines have different delays and thresholds from the rest;
   the bus logic waits for two equal samples because of it. U4 has two unused
   channels (A1/B1, A2/B2, inputs tied to ground now) and the Tang Nano has
   free 3.3 V pins, so all sixteen could take the same path. This changes
   the pin constraints, and the present arrangement works; do it only if the
   board is being re-routed there anyway.
3. **IRQ, if it is ever wanted** (POKEY interrupts, for example): its own
   BSS138 with a gate pull-down, on a free pin. U5's eighth channel (A8/B8)
   is free if the cart should also read the line.
4. **Test points** for PHI2, HALT, R/W, A15 and a data line at the cartridge
   edge: every timing question in this project was answered with a probe on
   those.

Things looked at and left alone: D2 (SS14) keeps USB power from back-feeding
the console; U5's B side and the 1.8 V regulator run from the console's 5 V
only, and the SN74LVC8T245 isolates its A side when that is off, so
USB-only operation on the bench is fine; R2 holds the data-bus driver off
until the FPGA is configured.
