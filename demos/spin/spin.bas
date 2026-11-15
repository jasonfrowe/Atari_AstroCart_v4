 rem ** Spin: a cloud of 32 points turning about two axes, in perspective.
 rem ** Near points are big and bright, far ones small and dim. The stick
 rem ** changes the two speeds; fire flows the cloud into the next shape.
 rem ** On the AstroCart math unit's trig block at $0420 (docs/MATHUNIT.md);
 rem ** transform.asm is the arithmetic, model.py the shapes.

 set romsize 32k
 displaymode 320A
 set zoneheight 8
 set screenheight 192
 set extradlmemory on

 BACKGRND=$00

 incgraphic gfx/menufont.png 320A
 incgraphic gfx/dot0.png 320A
 incgraphic gfx/dot1.png 320A
 incgraphic gfx/dot2.png 320A
 incgraphic gfx/dot3.png 320A
 incgraphic gfx/dot4.png 320A
 incgraphic gfx/dot5.png 320A
 incgraphic gfx/dot6.png 320A
 incgraphic gfx/dot7.png 320A
 incgraphic gfx/dot8.png 320A
 incgraphic gfx/dot9.png 320A
 incgraphic gfx/dot10.png 320A
 incgraphic gfx/dot11.png 320A
 incgraphic gfx/dot12.png 320A
 incgraphic gfx/dot13.png 320A
 incgraphic gfx/dot14.png 320A
 incgraphic gfx/dot15.png 320A
 incgraphic gfx/dot16.png 320A

 rem ** palette 0 text, 1-4 dots from near to far
 P0C2=$0F
 P1C2=$0F
 P2C2=$AE
 P3C2=$9A
 P4C2=$96

 characterset menufont
 alphachars ASCII

 dim tmp = e
 dim nofire = g

 rem ** transform.asm's memory
 dim sbase = $22A8

 asm
 lda $043F
 sta tmp
end
 if tmp <> $A1 then goto nomath
 asm
 lda $042F
 sta tmp
end
 if tmp <> $A2 then goto nomath

 asm
 jsr spin_init
end
 nofire = 1
 gosub title

main
 rem ** The display lists must not change under MARIA. The arithmetic runs
 rem ** while the screen is being drawn; by the time it is done the top 80 lines
 rem ** have been drawn, so the dots up there are plotted at once and only the
 rem ** rest have to fit in vertical blank (transform.asm, spin_plot).
 asm
 jsr spin_step
end
 restorescreen
 asm
 lda #$00
 jsr spin_plot
spin_wait
 lda visibleover
 bne spin_wait
 lda #$80
 jsr spin_plot
end
 drawscreen
 if !joy0fire then nofire = 0
 if joy0fire && nofire = 0 then nofire = 1 : gosub nextshape
 goto main

nextshape
 asm
 jsr spin_next
end
title
 clearscreen
 if sbase = 0 then plotchars 'SPIN: CUBE' 0 4 0
 if sbase = 32 then plotchars 'SPIN: SPHERE' 0 4 0
 if sbase = 64 then plotchars 'SPIN: TORUS' 0 4 0
 if sbase = 96 then plotchars 'SPIN: HELIX' 0 4 0
 plotchars 'STICK: SPEED  FIRE: NEXT SHAPE' 0 4 1
 savescreen
 return

nomath
 clearscreen
 plotchars 'THIS DEMO NEEDS THE' 0 42 9
 plotchars 'ASTROCART MATH UNIT' 0 42 10
 plotchars '(VERSION 2: BUILD 9A ON)' 0 32 12
 drawscreen
nomath_wait
 goto nomath_wait

 asm
 include "transform.asm"
end
