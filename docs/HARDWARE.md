# AstroCart V4 hardware reference

Board: **AstroCart_V2 PCB** (KiCad: `pcb/AstroCart_V4` is a copy of it, the starting point of the next
revision; see `pcb/README.md`)
carrying a Sipeed Tang Nano 9K (GW1NR-LV9QN88PC6/I5), **plus the HALT bodge below**.
The pin table was generated from the KiCad netlist (`kicad-cli sch export netlist`)
and is what `hw/devcart/devcart.cst` implements.

## HALT bodge (not in the schematic)

The schematic has Q1 (BSS138, gate = FPGA pin 83 / net `T_IRQ`, source = GND)
with its drain on cartridge **pin 31 (IRQ)**. On the built board the drain has
been moved to cartridge **pin 2 (HALT)**:

| | schematic | as built |
|---|---|---|
| Q1 drain | J1 pin 31 (IRQ) | J1 pin 2 (HALT), also U5 B3 |
| FPGA pin 83 = 1 | pulls IRQ low | **pulls HALT low (6502 stops)** |
| FPGA pin 83 = 0 | IRQ released | HALT released (motherboard pull-up) |

The FPGA can therefore both **read** HALT (pin 84, through U5) and **pull it
low** (pin 83). In the RTL the pin-83 port is called `halt_pull`; it is held
at 0 (`PULL_MODE=DOWN` keeps Q1 off before configuration). Nothing drives
cartridge IRQ any more.

### Q1 gate pull-down (second bodge, 2026-11-14)

A **10 k resistor from Q1's gate (pin 1) to its source (pin 2, GND)** is
required. Q1's gate net had only the FPGA pin on it, and `PULL_MODE=DOWN` in
the constraints means nothing until the bitstream is loaded: while the FPGA
configures, the pin floats (weak pull-up to the 1.8 V bank), Q1 conducts and
HALT is pulled during the console's power-on reset.

Symptom without it, on one of two consoles, when the cart is powered only
from the cartridge port: black screen. The bus trace showed the console
locked in the slow-clock (TIA) mode with the BIOS still mapped and RAM off,
looping in the BIOS RAM test at `$F880-$F8E6` without ever reading the cart
(every 6502 cycle 56 clocks instead of 37). Powering the cart from USB first
hid it, because the FPGA was then already driving the gate low. With the
resistor the console starts every time.

For the next PCB revision (`pcb/README.md`): add the 10 k gate pull-down, route Q1's drain to
HALT in the schematic, and if
IRQ is still wanted give it its own transistor (e.g. on the unused U5 A8/B8
channel's FPGA pin).

## Level shifting and FPGA I/O banks

| FPGA bank | pins used | VCCIO | driven by | IO_TYPE |
|---|---|---|---|---|
| 1 (right + top-right) | 48-57, 63, 76, 77 | 3.3 V | U2/U4 SN74LVC245 (3.3 V) | LVCMOS33 |
| 2 (bottom) | 25-42 | 3.3 V | U2/U3/U4 SN74LVC245 (3.3 V), SD slot | LVCMOS33 |
| 3 (top-left + left) | 79-86, LEDs 10-16 | 1.8 V | U5 SN74LVC8T245 A side (VCCA = 1.8 V from U6) | LVCMOS18 |

(Bank numbers from Gowin's pin report, `hw/devcart/build/impl/pnr/devcart.pin.html`.)

V3's constraints declared most bank-1 address pins as LVCMOS18. They are
driven at 3.3 V; LVCMOS18 input thresholds (~0.6/1.2 V) on a 3.3 V signal
shift each bit's switching point differently from its LVCMOS33 neighbours --
extra, avoidable address skew, which V3 then had to filter. V4 uses LVCMOS33
on banks 1 and 2.

The address bus is split across two transceiver types: A0-A13 through
SN74LVC245 (U2, U4), A14/A15 + R/W, PHI2, HALT through SN74LVC8T245 (U5).
Expect a few ns of skew between them; `cart_bus.v` accepts an address only
after two samples agree.

## Pin map

| Signal | FPGA pin | Path | Notes |
|---|---|---|---|
| A0 | 41 | U2 | |
| A1 | 51 | U2 | |
| A2 | 54 | U2 | |
| A3 | 56 | U2 | |
| A4 | 63 | U4 | |
| A5 | 48 | U4 | |
| A6 | 49 | U4 | |
| A7 | 31 | U4 | |
| A8 | 77 | U4 | |
| A9 | 57 | U2 | |
| A10 | 53 | U2 | |
| A11 | 55 | U2 | |
| A12 | 42 | U2 | |
| A13 | 32 | U4 | |
| A14 | 82 | U5 (1.8 V) | |
| A15 | 81 | U5 (1.8 V) | |
| D0-D7 | 33, 29, 27, 25, 26, 28, 30, 34 | U3 (bidirectional) | |
| U3 DIR | 40 | | 1 = FPGA drives the Atari |
| U3 /OE | 35 | | R2 pulls high (off) until configured |
| R/W | 86 | U5 | |
| PHI2 | 85 | U5 | |
| HALT (in) | 84 | U5 | |
| HALT pull (Q1 gate) | 83 | Q1 | bodge, see above |
| EAUD | 76 | R1/C5/C8 | PWM audio |
| UIP_0 / UIP_1 | 80 / 79 | U5 -> J2 | spare (R3/R4 pull-downs on the 5 V side) |
| microSD CS/MOSI/SCLK/MISO | 38 / 37 / 36 / 39 | Tang Nano slot | SPI mode, `rtl/sd/sd_spi.v`; card init 0.19 s on the bench |
| UART TX / RX | 17 / 18 | BL702 USB bridge | `/dev/cu.usbserial-*1` |
| 27 MHz clock | 52 | | |

## Test equipment notes

FNIRSI-1014D (2 ch, 100 MHz): enough to see a cart read on the bus (e.g. CH1 on
A15 or A0 at the cart edge, CH2 on a data line) and measure address-to-data
time. The cart also measures itself (`devcart.py stats`, `devcart.py trace`).
