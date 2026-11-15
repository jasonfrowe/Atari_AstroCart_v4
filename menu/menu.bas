 rem ** AstroCart V4 menu: browses the SD card's directories (fat.asm keeps a
 rem ** sorted list of up to 255 entries of the current one), loads the chosen
 rem ** .a78 file into the cart's PSRAM and starts it.
 rem ** The SD / FAT32 / loader code is in fat.asm (6502), included at the end.
 rem ** The cart gives the menu 16K of RAM at $4000: $4000-$41FF is the SD
 rem ** block buffer, the rest holds fat.asm's variables and the title lists.

 set romsize 32k
 displaymode 320A
 set zoneheight 8
 set screenheight 192

 BACKGRND=$00

 incgraphic gfx/menufont.png 320A

 rem ** palette 0: list text. palette 1: title and cursor. palette 2: messages
 P0C2=$0F
 P1C2=$1C
 P2C2=$46

 characterset menufont
 alphachars ASCII

 dim sel = a
 dim top = b
 dim count = c
 dim joydelay = d
 dim err = e
 dim rows = f
 dim cury = g
 dim tmp = h
 dim row = i
 dim errstage = j
 dim nofire = k
 dim idle = l
 rem ** y and z ($FE/$FF) are fat.asm's pointer (FPTR): not used here

 rem ** two hex digits for error codes
 dim hexbuf0 = var0
 dim hexbuf1 = var1

start
 clearscreen
 plotchars 'ASTROCART V4' 1 56 0
 plotchars 'READING THE SD CARD' 0 42 10
 drawscreen
 drawscreen

 asm
 jsr ac_init
 sta err
 lda ac_nent
 sta count
end
 errstage = 0
 if err <> 0 then goto show_error
 if count = 0 then err = $30 : goto show_error

 sel = 0
 top = 0
 joydelay = 20
 nofire = 1
 gosub build_page

main
 restorescreen
 cury = sel - top + 3
 plotchars '>' 1 0 cury
 rem ** two lines from the .a78 header of the game under the cursor, read
 rem ** once the cursor has rested a moment (fat.asm: ac_info)
 plotchars $7380 2 8 20 32
 plotchars $73A0 0 8 21 32
 if idle < 200 then idle = idle + 1
 if idle = 1 then gosub info_off
 if idle = 14 then gosub info_on
 if joydelay > 0 then joydelay = joydelay - 1 : goto input_done
 if joy0up then gosub move_up : joydelay = 8 : idle = 0
 if joy0down then gosub move_down : joydelay = 8 : idle = 0
 if joy0left then gosub page_up : joydelay = 14 : idle = 0
 if joy0right then gosub page_down : joydelay = 14 : idle = 0
 if !joy0fire then nofire = 0
 if joy0fire && nofire = 0 then goto do_select
input_done
 drawscreen
 goto main

info_off
 asm
 jsr ac_infoclr
end
 return

info_on
 asm
 lda sel
 jsr ac_info
end
 return

move_up
 if sel = 0 then return
 sel = sel - 1
 if sel < top then top = top - 16 : gosub build_page
 return

move_down
 tmp = sel + 1
 if tmp >= count then return
 sel = tmp
 rem ** (the last page starts at 240: top + 16 would wrap)
 if top >= 240 then return
 tmp = top + 16
 if sel >= tmp then top = tmp : gosub build_page
 return

page_up
 if top = 0 then sel = 0 : return
 top = top - 16
 sel = top
 gosub build_page
 return

page_down
 if top >= 240 then return
 tmp = top + 16
 if tmp >= count then return
 top = tmp
 sel = top
 gosub build_page
 return

 rem ** draw the 16 titles from `top` on, and save the screen
build_page
 rows = count - top
 if rows > 16 then rows = 16
 for row = 0 to 15
 if row >= rows then goto skip_line
 tmp = top + row
 asm
 lda tmp
 ldx row
 jsr ac_line
end
skip_line
 next
 clearscreen
 plotchars 'ASTROCART V4' 1 56 0
 plotchars $7200 2 8 1 32
 if rows > 0 then plotchars $4600 0 8 3 32
 if rows > 1 then plotchars $4620 0 8 4 32
 if rows > 2 then plotchars $4640 0 8 5 32
 if rows > 3 then plotchars $4660 0 8 6 32
 if rows > 4 then plotchars $4680 0 8 7 32
 if rows > 5 then plotchars $46A0 0 8 8 32
 if rows > 6 then plotchars $46C0 0 8 9 32
 if rows > 7 then plotchars $46E0 0 8 10 32
 if rows > 8 then plotchars $4700 0 8 11 32
 if rows > 9 then plotchars $4720 0 8 12 32
 if rows > 10 then plotchars $4740 0 8 13 32
 if rows > 11 then plotchars $4760 0 8 14 32
 if rows > 12 then plotchars $4780 0 8 15 32
 if rows > 13 then plotchars $47A0 0 8 16 32
 if rows > 14 then plotchars $47C0 0 8 17 32
 if rows > 15 then plotchars $47E0 0 8 18 32
 plotchars 'UP/DOWN SELECT   FIRE OPEN' 1 28 22
 if count > 16 then plotchars 'LEFT/RIGHT PAGE' 1 50 23
 idle = 0
 savescreen
 return

 rem ** fire: open a directory (".." goes back up), or load a game
do_select
 asm
 lda sel
 jsr ac_isdir
 sta tmp
end
 if tmp = 0 then goto do_load
 asm
 lda sel
 jsr ac_enter
 sta err
 lda ac_nent
 sta count
 lda ac_cur
 sta sel
end
 errstage = 0
 if err <> 0 then goto show_error
 if count = 0 then err = $30 : goto show_error
 top = sel & $F0
 joydelay = 10
 nofire = 1
 gosub build_page
 goto main

do_load
 asm
 lda sel
 ldx #0
 jsr ac_line
end
 clearscreen
 plotchars 'ASTROCART V4' 1 56 0
 plotchars 'LOADING' 2 66 9
 plotchars $4600 0 16 11 32
 drawscreen
 drawscreen
 asm
 lda sel
 jsr ac_load
 sta err
end
 errstage = 1
 if err <> 0 then goto show_error
 asm
 jmp ac_launch
end

 rem ** errors: a line of text and the code; fire tries again
show_error
 tmp = err / 16
 gosub hexdigit
 hexbuf0 = tmp
 tmp = err & 15
 gosub hexdigit
 hexbuf1 = tmp
 clearscreen
 plotchars 'ASTROCART V4' 1 56 0
 if err = $0E then plotchars 'CARTRIDGE HARDWARE NOT FOUND' 2 24 9 : goto error_shown
 if err = $01 then plotchars 'NO SD CARD' 2 60 9 : goto error_shown
 if err < $10 then plotchars 'SD CARD ERROR' 2 54 9 : goto error_shown
 if err < $20 then plotchars 'THE SD CARD IS NOT FAT32' 2 32 9 : goto error_shown
 if err = $20 then plotchars 'CART TYPE NOT SUPPORTED' 2 34 9 : goto error_shown
 if err = $22 then plotchars 'CART MEMORY ERROR' 2 46 9 : goto error_shown
 if err = $30 then plotchars 'NOTHING TO SHOW ON THE CARD' 2 26 9 : goto error_shown
 if err = $40 then plotchars 'CART RAM TEST FAILED' 2 40 9 : goto error_shown
 plotchars 'FILE ERROR' 2 60 9
error_shown
 plotchars 'CODE' 0 64 11
 plotchars hexbuf0 0 84 11 2
 plotchars 'PRESS FIRE' 1 60 14
 savescreen
error_release
 restorescreen
 drawscreen
 if joy0fire then goto error_release
error_wait
 restorescreen
 drawscreen
 if !joy0fire then goto error_wait
 if errstage = 0 then goto start
 joydelay = 20
 nofire = 1
 gosub build_page
 goto main

hexdigit
 if tmp < 10 then tmp = tmp + 48 : return
 tmp = tmp + 55
 return

 asm
FPTR = $FE
 include "fat.asm"
end
