 rem ** N-body gravity: stars, planets and a moon, every pair pulling on each
 rem ** other, on the AstroCart math unit at $0430 (docs/MATHUNIT.md). The
 rem ** physics is in physics.asm; model.py is the same arithmetic in Python.
 rem ** Fire: the next scenario (they also change by themselves).

 set romsize 32k
 displaymode 320A
 set zoneheight 8
 set screenheight 192

 BACKGRND=$00

 incgraphic gfx/menufont.png 320A
 incgraphic gfx/star.png 320A
 incgraphic gfx/planet.png 320A
 incgraphic gfx/dot.png 320A

 rem ** palette 0 text, 1-5 the bodies
 P0C2=$0F
 P1C2=$1E
 P2C2=$9C
 P3C2=$48
 P4C2=$CA
 P5C2=$6C

 characterset menufont
 alphachars ASCII

 dim bi = a
 dim pal = b
 dim tx = c
 dim ty = d
 dim tmp = e
 dim scen = f
 dim slot = g
 dim idx = h
 dim nofire = o
 dim timerlo = p
 dim timerhi = q

 rem ** physics.asm's memory
 dim nbn = $2200
 dim nsx = $2288
 dim nsy = $2290
 dim nvis = $2298
 dim nbig = $22A0
 dim ntx = $22A8
 dim nty = $22D0
 dim nname = $2300

 asm
 lda $043F
 sta tmp
end
 if tmp <> $A1 then goto nomath
 scen = 0

newscen
 tmp = scen
 asm
 lda tmp
 jsr nb_init
end
 clearscreen
 plotchars nname 0 4 0 16
 savescreen
 timerlo = 0
 timerhi = 0
 nofire = 1

main
 restorescreen
 asm
 jsr nb_step
end
 for bi = 0 to 4
 if bi >= nbn then goto skipbody
 pal = bi + 1
 idx = bi * 8
 for slot = 0 to 3
 tx = ntx[idx]
 if tx = 0 then goto skipdot
 ty = nty[idx]
 plotsprite dot pal tx ty
skipdot
 idx = idx + 1
 next
 if nvis[bi] = 0 then goto skipbody
 tx = nsx[bi]
 ty = nsy[bi]
 if nbig[bi] <> 0 then plotsprite star pal tx ty else plotsprite planet pal tx ty
skipbody
 next
 drawscreen
 timerlo = timerlo + 1
 if timerlo = 0 then timerhi = timerhi + 1
 if timerhi = 11 then goto nextscen
 if !joy0fire then nofire = 0
 if joy0fire && nofire = 0 then goto nextscen
 goto main

nextscen
 scen = scen + 1
 if scen = 4 then scen = 0
 goto newscen

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
