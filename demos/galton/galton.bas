 rem ** Galton board: balls fall through a triangle of pegs into eight bins,
 rem ** and the bins fill as a bell curve. The physics (physics.asm) runs on
 rem ** the AstroCart math unit at $0430 (docs/MATHUNIT.md): this cart only
 rem ** works on an AstroCart, or in the a7800 fork that emulates the unit.
 rem ** Fire starts again.

 set romsize 32k
 displaymode 320A
 set zoneheight 8
 set screenheight 192

 BACKGRND=$00

 incgraphic gfx/menufont.png 320A
 incgraphic gfx/ball.png 320A
 incgraphic gfx/peg.png 320A
 incgraphic gfx/bar2.png 320A
 incgraphic gfx/bar4.png 320A
 incgraphic gfx/bar6.png 320A
 incgraphic gfx/bar8.png 320A

 rem ** palette 0 text, 1 balls, 2 pegs, 3 the bins' bars
 P0C2=$0F
 P1C2=$1C
 P2C2=$88
 P3C2=$C8

 characterset menufont
 alphachars ASCII

 dim bi = a
 dim bj = b
 dim row = c
 dim col = d
 dim px = e
 dim py = f
 dim lines = g
 dim bx = h
 dim by = o
 dim tmp = m
 dim wait = n
 dim tx = p
 dim ty = q

 rem ** physics.asm's memory
 dim bst = $2240
 dim bsx = $2250
 dim bsy = $2258
 dim bcnt = $2260
 dim bdirty = $2268
 dim bfull = $2269
 dim bseed = $226C
 dim bdig = $226D

 asm
 lda $043F
 sta tmp
end
 if tmp <> $A1 then goto nomath

restart
 bseed = framecounter
 asm
 jsr gal_init
end

main
 if bdirty <> 0 then gosub redraw : bdirty = 0
 restorescreen
 asm
 jsr gal_step
end
 for bi = 0 to 7
 if bst[bi] = 0 then goto skipball
 tx = bsx[bi]
 ty = bsy[bi]
 plotsprite ball 1 tx ty
skipball
 next
 drawscreen
 if bfull <> 0 then goto full
 if joy0fire then goto restart
 goto main

full
 for wait = 0 to 240
 restorescreen
 drawscreen
 next
 goto restart

redraw
 clearscreen
 plotchars 'GALTON BOARD' 0 4 0
 plotchars 'BALLS' 0 116 0
 plotchars bdig 0 140 0 3
 py = 20
 for row = 0 to 6
 px = 78 - row * 8
 for col = 0 to row
 plotsprite peg 2 px py
 px = px + 16
 next
 py = py + 14
 next
 bx = 18
 for bj = 0 to 7
 lines = bcnt[bj] * 2
 by = 184
redraw_bar
 if lines < 8 then goto redraw_top
 plotsprite bar8 3 bx by
 by = by - 8
 lines = lines - 8
 goto redraw_bar
redraw_top
 if lines = 2 then plotsprite bar2 3 bx by
 if lines = 4 then plotsprite bar4 3 bx by
 if lines = 6 then plotsprite bar6 3 bx by
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
