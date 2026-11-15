; Orbit, for two players: aim and launch probes at a moon, under a star's
; gravity; whoever's probe hits it scores. On the
; AstroCart math unit (docs/MATHUNIT.md, version 2); the trig block does all
; of the geometry:
;
;   moon, ships     position = (radius, 0) turned by the orbit angle (the two
;                   ships are half a turn apart on one orbit)
;   aim dots, launch  (step, 0) and (speed, 0) turned by the aim angle
;   gravity         ANG and LEN of the probe's position (the star is at 0, 0);
;                   a = K / LEN / LEN (two divides);
;                   (a, 0) turned by ANG + half a turn is the acceleration
;   hit             LEN of (probe - moon)
;
; Units: positions 16 bits signed, 1/32 line (a 160-wide pixel is 1.714
; lines); the probe's position has 8 more fractional bits; its velocity is
; 16 bits signed, 1/8192 line per frame. GM = 40 lines^3 / frame^2.

NOBJ    = 25                ; 0 moon; then for players 0 and 1: ships 1, 2; probes 3, 4;
                            ; aim dots 5-6, 7-8; trails 9-16, 17-24
NTRAIL  = 8
HIDE    = 224               ; a y that plots nothing
DLFULL  = 116               ; a zone with this much in its display list takes no more (24 objects)
SHIPR   = 80*32
SHIPW   = 92                ; angle per frame: a circular orbit at 80 lines
STAR_R  = 6*32              ; the probe is gone this close to the star,
FAR_HI  = $32               ; this far from it (400 lines),
MOON_R  = 5*32              ; and has hit the moon this close to it
KGM     = $14000000         ; 8192 * 40 * 32 * 32
AIMSTEP = $0140

o_x     = $2200             ; (25) where to plot each object
o_y     = $2219             ; (25)
o_ma    = $2238             ; (2) moon: angle, angle per frame, radius, position
o_mw    = $223A
o_mr    = $223C
o_mx    = $223E
o_my    = $2240
o_sa    = $2242             ; (2) player 0's ship's angle
o_p     = $2244             ; the player being worked on
o_stk   = $2245             ; that player's stick: right, left, down, up in bits 7-4 (0 = pushed)
o_frame = $2246
o_flash = $2247
o_dirty = $2248             ; a score has changed
o_wx    = $2249             ; (2) a world position on its way to the screen
o_wy    = $224B             ; (2)
o_dx    = $224D             ; (2) step between aim dots
o_dy    = $224F             ; (2)
o_t     = $2251             ; (2)
o_ang   = $2253             ; (2) the direction from the probe to the star
o_len   = $2255             ; (2) and the distance
o_ta    = $2257             ; (2) an angle for O_TURN
; one of each per player
o_aiml  = $2260             ; aim angle
o_aimh  = $2262
o_pow   = $2264             ; power 0-15
o_fire  = $2266             ; launch (set from the fire button)
o_act   = $2268             ; a probe is flying
o_timl  = $226A             ; frames it has flown
o_timh  = $226C
o_tr    = $226E             ; next trail dot
o_pxf   = $2270             ; probe position: fraction, low, high
o_pxl   = $2272
o_pxh   = $2274
o_pyf   = $2276
o_pyl   = $2278
o_pyh   = $227A
o_vxl   = $227C             ; probe velocity
o_vxh   = $227E
o_vyl   = $2280
o_vyh   = $2282
o_sxl   = $2284             ; ship position
o_sxh   = $2286
o_syl   = $2288
o_syh   = $228A
o_score = $228C             ; BCD
o_held  = $228E             ; the fire button was down last frame
o_d1    = $2290             ; (2) player 0's score as two ASCII digits
o_d2    = $2292             ; (2) player 1's
O_END   = $2294

    MAC O_TURN              ; ({1}, 0) turned by {2}: results at $0420-$0423
    lda {1}
    sta $0420
    lda {1}+1
    sta $0421
    lda #0
    sta $0422
    sta $0423
    lda {2}
    sta $0424
    lda {2}+1
    sta $0425
    ENDM

    MAC O_GET               ; the turned vector into {1} (x) and {2} (y)
    lda $0420
    sta {1}
    lda $0421
    sta {1}+1
    lda $0422
    sta {2}
    lda $0423
    sta {2}+1
    ENDM

    MAC O_ADD16             ; {1} += {2}
    clc
    lda {1}
    adc {2}
    sta {1}
    lda {1}+1
    adc {2}+1
    sta {1}+1
    ENDM

    MAC O_AIM               ; this player's aim angle into o_ta (x = player)
    lda o_aiml,x
    sta o_ta
    lda o_aimh,x
    sta o_ta+1
    ENDM

orbit_init
    ldx #NOBJ-1
    lda #HIDE
orbit_init_1
    sta o_y,x
    dex
    bpl orbit_init_1
    ldx #O_END-1-o_ma
    lda #0
orbit_init_2
    sta o_ma,x
    dex
    bpl orbit_init_2
    lda #<(56*32)
    sta o_mr
    lda #>(56*32)
    sta o_mr+1
    lda #157
    sta o_mw
    lda #$80
    sta o_sa+1              ; player 0 starts on the left, aiming right;
    sta o_aimh+1            ; player 1 on the right, aiming left
    lda #6
    sta o_pow
    sta o_pow+1
    lda #1
    sta o_dirty
    sta o_held              ; (a button held at the start launches nothing)
    sta o_held+1
    ; One-button mode on both ports. A 7800 pad's two buttons then both pull
    ; INPT4 / INPT5 low, as a 2600 stick's one button does, so either kind of
    ; controller works in either port. (In two-button mode, which 7800basic
    ; starts in, the 2600 stick in port 2 did not fire on the console.)
    ldx #0
    jsr setonebuttonmode
    ldx #1
    jsr setonebuttonmode
    lda joybuttonmode
    ora #$14
    sta joybuttonmode
    rts

orbit_text                  ; the two scores as digits
    ldx #1
orbit_text_1
    txa
    asl
    tay
    lda o_score,x
    lsr
    lsr
    lsr
    lsr
    ora #$30
    sta o_d1,y
    lda o_score,x
    and #$0F
    ora #$30
    sta o_d1+1,y
    dex
    bpl orbit_text_1
    rts

; World position o_wx, o_wy -> object x's plot position, or hidden. The
; multiplier does the scaling: x / 54.86 = x * 1195 / 65536, y / 32.
o_toscr
    lda o_wx
    sta $0430
    lda o_wx+1
    sta $0431
    lda #<1195
    sta $0432
    lda #>1195
    sta $0433
    clc
    lda $0432               ; (the product's bytes 2 and 3)
    adc #78
    tay
    lda $0433
    adc #0
    bne o_toscr_hide
    cpy #154
    bcs o_toscr_hide
    tya
    sta o_x,x
    lda o_wy
    sta $0430
    lda o_wy+1
    sta $0431
    lda #<2048
    sta $0432
    lda #>2048
    sta $0433
    clc
    lda $0432
    adc #100
    tay
    lda $0433
    adc #0
    bne o_toscr_hide
    cpy #16
    bcc o_toscr_hide
    cpy #184
    bcs o_toscr_hide
    tya
    sta o_y,x
    rts
o_toscr_hide
    lda #HIDE
    sta o_y,x
    rts

orbit_step
    inc o_frame
    lda #1
    sta $043A               ; signed
    lda o_flash
    beq orbit_f1
    dec o_flash
    lda #$42
orbit_f1
    sta BACKGRND

    ; moon
    O_ADD16 o_ma, o_mw
    O_TURN o_mr, o_ma
    O_GET o_mx, o_my
    O_GET o_wx, o_wy
    ldx #0
    jsr o_toscr

    clc
    lda o_sa
    adc #SHIPW
    sta o_sa
    bcc orbit_s1
    inc o_sa+1
orbit_s1
    lda #0
    sta o_p
    jsr orbit_player
    lda #1
    sta o_p

; Everything of one player (o_p): stick, ship, aim dots, launch, probe.
orbit_player
    ldx o_p
    lda $0280               ; SWCHA: player 0 in bits 7-4, player 1 in bits 3-0
    cpx #0
    beq orbit_j0
    asl
    asl
    asl
    asl
orbit_j0
    sta o_stk
    ; fire: either kind of controller pulls INPT4 / INPT5 low in one-button mode
    lda INPT4,x
    bmi orbit_b1
    lda o_held,x
    bne orbit_b2
    lda #1
    sta o_held,x
    sta o_fire,x
    bne orbit_b2
orbit_b1
    lda #0
    sta o_held,x
orbit_b2
    ; left / right turn the aim, up / down change the power
    lda o_stk               ; (the flags must be the stick's, not the player number's)
    bmi orbit_j1
    clc
    lda o_aiml,x
    adc #<AIMSTEP
    sta o_aiml,x
    lda o_aimh,x
    adc #>AIMSTEP
    sta o_aimh,x
orbit_j1
    bit o_stk
    bvs orbit_j2
    sec
    lda o_aiml,x
    sbc #<AIMSTEP
    sta o_aiml,x
    lda o_aimh,x
    sbc #>AIMSTEP
    sta o_aimh,x
orbit_j2
    lda o_frame
    and #7
    bne orbit_j4
    lda o_stk
    and #$10
    bne orbit_j3
    lda o_pow,x
    cmp #15
    bcs orbit_j3
    inc o_pow,x
orbit_j3
    lda o_stk
    and #$20
    bne orbit_j4
    lda o_pow,x
    beq orbit_j4
    dec o_pow,x
orbit_j4

    ; ship: player 1's is half a turn from player 0's
    lda o_sa
    sta o_ta
    lda o_sideh,x
    eor o_sa+1
    sta o_ta+1
    O_TURN o_shipr, o_ta
    O_GET o_wx, o_wy
    lda o_wx
    sta o_sxl,x
    lda o_wx+1
    sta o_sxh,x
    lda o_wy
    sta o_syl,x
    lda o_wy+1
    sta o_syh,x
    inx                     ; object 1 + player
    jsr o_toscr

    ; two aim dots, (6 + power) lines apart
    ldx o_p
    lda o_pow,x             ; (192 + 32 * power, in 1/32 line)
    lsr
    lsr
    lsr
    sta o_t+1
    lda o_pow,x
    asl
    asl
    asl
    asl
    asl
    clc
    adc #192
    sta o_t
    bcc orbit_a0
    inc o_t+1
orbit_a0
    O_AIM
    O_TURN o_t, o_ta
    O_GET o_dx, o_dy
    lda o_aimobj,x
    tax
    O_ADD16 o_wx, o_dx
    O_ADD16 o_wy, o_dy
    jsr o_toscr
    inx
    O_ADD16 o_wx, o_dx
    O_ADD16 o_wy, o_dy
    jsr o_toscr

    ; launch
    ldx o_p
    lda o_fire,x
    bne orbit_l0
    jmp orbit_l2
orbit_l0
    lda #0
    sta o_fire,x
    sta o_pxf,x
    sta o_pyf,x
    sta o_timl,x
    sta o_timh,x
    sta o_tr,x
    lda o_sxl,x
    sta o_pxl,x
    lda o_sxh,x
    sta o_pxh,x
    lda o_syl,x
    sta o_pyl,x
    lda o_syh,x
    sta o_pyh,x
    lda o_pow,x
    asl
    tay
    lda o_speed,y
    sta o_t
    lda o_speed+1,y
    sta o_t+1
    O_AIM
    O_TURN o_t, o_ta
    lda $0420
    sta o_vxl,x
    lda $0421
    sta o_vxh,x
    lda $0422
    sta o_vyl,x
    lda $0423
    sta o_vyh,x
    lda #1
    sta o_act,x
    ldy o_trobj,x           ; the old trail goes
    ldx #NTRAIL-1
    lda #HIDE
orbit_l1
    sta o_y,y
    iny
    dex
    bpl orbit_l1
orbit_l2

    ; the probe
    ldx o_p
    lda o_act,x
    bne orbit_p0
    jmp orbit_gone
orbit_p0
    lda o_pxl,x
    sta $0420
    lda o_pxh,x
    sta $0421
    lda o_pyl,x
    sta $0422
    lda o_pyh,x
    sta $0423
    lda $0424
    sta o_ang
    lda $0425
    eor #$80                ; toward the star
    sta o_ang+1
    lda $0426
    sta o_len
    lda $0427
    sta o_len+1
    bne orbit_p1
    lda o_len
    cmp #STAR_R
    bcs orbit_p2
    jmp orbit_dead          ; into the star
orbit_p1
    cmp #FAR_HI
    bcc orbit_p2
    jmp orbit_dead          ; lost
orbit_p2
    lda #<KGM               ; a = K / LEN / LEN
    sta $0434
    lda #[KGM>>8]&$FF
    sta $0435
    lda #[KGM>>16]&$FF
    sta $0436
    lda #[KGM>>24]&$FF
    sta $0437
    lda o_len
    sta $0438
    lda o_len+1
    sta $0439
    lda o_len+1             ; K / LEN is under 2^24. LEN / 2 is added so that the second
    lsr                     ; divide rounds: truncating made gravity 0.3% weak, and the
    sta temp2               ; probe was 8 lines from where it should be after 800 frames
    lda o_len
    ror
    sta temp1
    clc
    lda $0434               ; (all of the quotient is read before any of it goes back into N)
    adc temp1
    tax
    lda $0435
    adc temp2
    tay
    lda $0436
    adc #0
    stx $0434
    sty $0435
    sta $0436
    lda #0
    sta $0437
    lda $0434
    sta $0420
    lda $0435
    sta $0421
    lda #0
    sta $0422
    sta $0423
    lda o_ang
    sta $0424
    lda o_ang+1
    sta $0425
    ldx o_p
    clc                     ; v += a
    lda o_vxl,x
    adc $0420
    sta o_vxl,x
    lda o_vxh,x
    adc $0421
    sta o_vxh,x
    clc
    lda o_vyl,x
    adc $0422
    sta o_vyl,x
    lda o_vyh,x
    adc $0423
    sta o_vyh,x
    ldy #0                  ; p += v
    lda o_vxh,x
    bpl orbit_p3
    dey
orbit_p3
    clc
    lda o_pxf,x
    adc o_vxl,x
    sta o_pxf,x
    lda o_pxl,x
    adc o_vxh,x
    sta o_pxl,x
    sta o_wx
    tya
    adc o_pxh,x
    sta o_pxh,x
    sta o_wx+1
    ldy #0
    lda o_vyh,x
    bpl orbit_p4
    dey
orbit_p4
    clc
    lda o_pyf,x
    adc o_vyl,x
    sta o_pyf,x
    lda o_pyl,x
    adc o_vyh,x
    sta o_pyl,x
    sta o_wy
    tya
    adc o_pyh,x
    sta o_pyh,x
    sta o_wy+1

    sec                     ; how far from the moon?
    lda o_wx
    sbc o_mx
    sta $0420
    lda o_wx+1
    sbc o_mx+1
    sta $0421
    sec
    lda o_wy
    sbc o_my
    sta $0422
    lda o_wy+1
    sbc o_my+1
    sta $0423
    lda $0427
    bne orbit_p6
    lda $0426
    cmp #MOON_R
    bcs orbit_p6
    sed                     ; a hit: a point, and the moon goes to another orbit
    clc
    lda o_score,x
    adc #1
    sta o_score,x
    cld
    lda #1
    sta o_dirty
    lda #12
    sta o_flash
    lda $043E
    and #3
    asl
    tay
    lda o_moonr,y
    sta o_mr
    lda o_moonr+1,y
    sta o_mr+1
    lda o_moonw,y
    sta o_mw
    lda #0
    sta o_mw+1
    lda $043E
    bpl orbit_p5
    sec                     ; the other way round
    lda #0
    sbc o_mw
    sta o_mw
    lda #$FF
    sta o_mw+1
orbit_p5
    jmp orbit_dead
orbit_p6
    inc o_timl,x
    bne orbit_p7
    inc o_timh,x
orbit_p7
    lda o_timh,x
    cmp #5
    bcs orbit_dead          ; 21 seconds is enough
    inx
    inx
    inx                     ; object 3 + player
    jsr o_toscr
    lda o_frame
    and #7
    bne orbit_p8
    ldx o_p                 ; leave a dot behind
    clc
    lda o_trobj,x
    adc o_tr,x
    tay
    lda o_x+3,x
    sta o_x,y
    lda o_y+3,x
    sta o_y,y
    inc o_tr,x
    lda o_tr,x
    cmp #NTRAIL
    bcc orbit_p8
    lda #0
    sta o_tr,x
orbit_p8
    rts
orbit_dead
    ldx o_p
    lda #0
    sta o_act,x
orbit_gone
    ldx o_p
    lda #HIDE
    sta o_y+3,x
    rts

; Plot the objects, in vertical blank, with 7800basic's PLOTSPRITE macro. The
; macro does not look whether a zone's display list is full, so that is done
; here: 25 objects can in principle crowd into one zone, which holds 24.
MACARG2CONST SET 0
MACARG3CONST SET 0
MACARG4CONST SET 0
MACARG5CONST SET 0
orbit_plot
    lda #NOBJ-1
    sta temp9
orbit_plot_1
    ldx temp9
    lda o_y,x
    sta temp5
    lsr
    lsr
    lsr
    tay
    cpy #23                 ; (hidden objects have a zone that does not exist)
    bcs orbit_plot_4
    lda dlend,y
    cmp #DLFULL
    bcs orbit_plot_4
    lda dlend+1,y
    cmp #DLFULL
    bcc orbit_plot_5
orbit_plot_4
    jmp orbit_plot_3
orbit_plot_5
    lda o_x,x
    sta temp4
    lda o_pf,x
    and #$E0
    sta temp3
    lda o_pf,x
    and #$03
    sta temp6
    PLOTSPRITE ob0,temp3,temp4,temp5,temp6
orbit_plot_3
    dec temp9
    bmi orbit_plot_2
    jmp orbit_plot_1
orbit_plot_2
    rts

o_pf                        ; palette * 32 + sprite: moon; ships; probes; aim dots; trails
    .byte $40,$61,$A1,$62,$A2,$63,$63,$A3,$A3
    .byte $83,$83,$83,$83,$83,$83,$83,$83,$C3,$C3,$C3,$C3,$C3,$C3,$C3,$C3
o_sideh                     ; added to the ship angle's high byte
    .byte $00,$80
o_aimobj                    ; each player's first aim dot and first trail dot
    .byte 5,7
o_trobj
    .byte 9,17
o_shipr
    .word SHIPR
o_speed                     ; launch speed by power: 0.5 to 1.38 lines a frame
    .word 4096,4576,5056,5536,6016,6496,6976,7456,7936,8416,8896,9376,9856,10336,10816,11296
o_moonr                     ; the moon's orbits: 36, 46, 56, 66 lines
    .word 36*32,46*32,56*32,66*32
o_moonw                     ; and their angle per frame (circular orbits)
    .word 305,211,157,123
