 rem ** Orbit, for two players: two ships circle a star. Aim with the stick
 rem ** (left / right), set the power (up / down) and launch a probe with
 rem ** fire: the star's gravity bends its path. Whoever's probe hits the
 rem ** moon scores. On the AstroCart math unit's trig block
 rem ** (docs/MATHUNIT.md); game.asm is the game.

 set romsize 32k
 displaymode 320A
 set zoneheight 8
 set screenheight 192
 set extradlmemory on

 BACKGRND=$00

 incgraphic gfx/menufont.png 320A
 incgraphic gfx/star.png 320A
 incgraphic gfx/ob0.png 320A
 incgraphic gfx/ob1.png 320A
 incgraphic gfx/ob2.png 320A
 incgraphic gfx/ob3.png 320A

 rem ** palette 0 text, 1 star, 2 moon, 3 player 1, 4 its trail, 5 player 2, 6 its trail
 P0C2=$0F
 P1C2=$1C
 P2C2=$0A
 P3C2=$CA
 P4C2=$C4
 P5C2=$3A
 P6C2=$34

 characterset menufont
 alphachars ASCII

 dim tmp = e

 rem ** game.asm's memory
 dim odirty = $2248
 dim od1 = $2290
 dim od2 = $2292

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
 jsr orbit_init
end
 gosub redraw

main
 rem ** (the scores are drawn from RAM: new digits show without redrawing)
 if odirty <> 0 then gosub digits : odirty = 0
 rem ** the arithmetic while the screen is drawn, the plotting after it
 asm
 jsr orbit_step
orbit_wait
 lda visibleover
 bne orbit_wait
end
 restorescreen
 asm
 jsr orbit_plot
end
 drawscreen
 goto main

digits
 asm
 jsr orbit_text
end
 return

redraw
 asm
 jsr orbit_text
end
 clearscreen
 plotchars 'ORBIT' 0 4 0
 plotchars 'PLAYER 1' 3 36 0
 plotchars od1 3 72 0 2
 plotchars 'PLAYER 2' 5 96 0
 plotchars od2 5 132 0 2
 plotchars 'STICK: AIM, POWER  FIRE: LAUNCH' 0 4 1
 plotsprite star 1 76 100
 savescreen
 return

nomath
 clearscreen
 plotchars 'THIS GAME NEEDS THE' 0 42 9
 plotchars 'ASTROCART MATH UNIT' 0 42 10
 plotchars '(VERSION 2: BUILD 9A ON)' 0 32 12
 drawscreen
nomath_wait
 goto nomath_wait

 asm
 include "game.asm"
end
