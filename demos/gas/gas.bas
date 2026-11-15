 rem ** Gas in a box: twelve discs bouncing off the walls and each other, and
 rem ** underneath, how fast they are going: eight bars, slowest on the left.
 rem ** They all start at the same speed (one bar); the collisions spread the
 rem ** speeds out into the Maxwell-Boltzmann distribution, marked by the
 rem ** dashes. On the AstroCart math unit at $0430 (docs/MATHUNIT.md);
 rem ** physics.asm is the simulation, model.py the same arithmetic in Python.
 rem ** Fire starts again with other directions.

 set romsize 32k
 displaymode 320A
 set zoneheight 8
 set screenheight 192

 BACKGRND=$00

 incgraphic gfx/menufont.png 320A
 incgraphic gfx/ball.png 320A
 incgraphic gfx/bar2.png 320A
 incgraphic gfx/bar4.png 320A
 incgraphic gfx/bar6.png 320A
 incgraphic gfx/bar8.png 320A
 incgraphic gfx/mark.png 320A

 rem ** palette 0 text and dashes, 1-4 discs, 5 bars
 P0C2=$0F
 P1C2=$1C
 P2C2=$9C
 P3C2=$48
 P4C2=$6C
 P5C2=$C6

 characterset menufont
 alphachars ASCII

 dim bi = a
 dim pal = b
 dim tx = c
 dim ty = d
 dim tmp = e
 dim lines = f
 dim bx = g
 dim by = h
 dim bj = o
 dim nofire = p

 rem ** physics.asm's memory
 dim gsx = $2280
 dim gsy = $2290
 dim gbar = $22B0
 dim gdirty = $22B8
 dim gseed = $22BA

 asm
 lda $043F
 sta tmp
end
 if tmp <> $A1 then goto nomath
 gseed[0] = $12
 gseed[1] = $A7
 gseed[2] = $4E
 gseed[3] = $31

restart
 asm
 jsr gas_init
end
 nofire = 1

main
 if gdirty <> 0 then gosub redraw : gdirty = 0
 restorescreen
 asm
 jsr gas_step
end
 pal = 1
 for bi = 0 to 11
 tx = gsx[bi]
 ty = gsy[bi]
 plotsprite ball pal tx ty
 pal = pal + 1
 if pal = 5 then pal = 1
 next
 drawscreen
 if !joy0fire then nofire = 0
 if joy0fire && nofire = 0 then gseed[0] = framecounter : goto restart
 goto main

redraw
 clearscreen
 plotchars 'GAS IN A BOX' 0 4 0
 plotchars 'BARS: SPEEDS  DASHES: THEORY' 0 4 1
 bx = 18
 for bj = 0 to 7
 lines = gbar[bj] & $FE
 if lines > 56 then lines = 56
 by = 184
redraw_bar
 if lines < 8 then goto redraw_top
 plotsprite bar8 5 bx by
 by = by - 8
 lines = lines - 8
 goto redraw_bar
redraw_top
 if lines = 2 then plotsprite bar2 5 bx by
 if lines = 4 then plotsprite bar4 5 bx by
 if lines = 6 then plotsprite bar6 5 bx by
 asm
 ldx bj
 lda #192
 sec
 sbc g_expect,x
 sta by
end
 plotsprite mark 0 bx by
 bx = bx + 16
 next
 savescreen
 return

nomath
 clearscreen
 plotchars 'THIS DEMO NEEDS THE' 0 42 9
 plotchars 'ASTROCART MATH UNIT' 0 42 11
 drawscreen
nomath_wait
 goto nomath_wait

 asm
 include "physics.asm"
end
