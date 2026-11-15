; Spin: 32 points turned about two axes and drawn in perspective, on the
; AstroCart math unit (docs/MATHUNIT.md). model.py is the same in floating
; point, and has the shapes.
;
; A point (x, y, z), each -72..72, is used as 8.8 fixed point (low byte 0):
;
;   (x1, z1) = (x, z) turned by A        trig block: the spin, about the y axis
;   (y2, z2) = (y, z1) turned by B       trig block: the tilt, about the x axis
;   D  = z2 / 4 + DIST64                 distance from the eye
;   sx = CX + x1 * FX / D                multiply, accumulator -> N, divide
;   sy = CY + y2 * FY / D
;
; Nothing is kept in memory on the way: x1 is read from the trig block
; straight into the multiplier, z1 straight back into the trig block's Y, and
; y2 is still in the trig block when the multiplier wants it.
;
; A new shape is not switched to: every coordinate walks 4 units a frame
; toward its new value, so the cloud flows from one shape into the next.

NPT     = 32
DIST64  = 280*64
FX      = 35
FY      = 60
CX      = 80
CY      = 106

s_cx    = $2200             ; the points now (coordinate + 128)
s_cy    = $2220
s_cz    = $2240
s_sx    = $2260             ; where to plot each one (see s_pf)
s_sy    = $2280
s_a     = $22A0             ; (2) angles, $10000 = a turn
s_b     = $22A2             ; (2)
s_da    = $22A4             ; (2) and what is added to them every frame
s_db    = $22A6             ; (2)
s_base  = $22A8             ; the shape wanted: 0, 32, 64, 96
s_ua    = $22AA             ; (2) the angles the last transform used
s_ub    = $22AC             ; (2)
                            ; ($22B0 up is display list memory: set extradlmemory)
s_pf    = var0              ; (32) palette * 32 + which sprite (0-16)

    MAC S_MORPH             ; {1} table (indexed by y), {2} the points now (by x)
    lda {1},y
    cmp {2},x
    beq .done
    bcc .down
    sbc {2},x               ; how far below
    cmp #5
    bcc .snap
    lda {2},x
    clc
    adc #4
    jmp .store
.down
    lda {2},x
    sec
    sbc {1},y               ; how far above
    cmp #5
    bcc .snap
    lda {2},x
    sbc #4
    jmp .store
.snap
    lda {1},y
.store
    sta {2},x
.done
    ENDM

    MAC S_SPEED             ; {1} a speed, {2} what to add; stays within -$0800..$07FF
    clc
    lda {1}
    adc #<{2}
    tay
    lda {1}+1
    adc #>{2}
    tax
    clc
    adc #8
    cmp #16
    bcs .no
    sty {1}
    stx {1}+1
.no
    ENDM

    MAC S_FLOOR             ; A = low byte of Q, rounded down (the divide rounds toward zero)
    lda $0434
    bit $0439               ; the remainder has the sign of N
    bpl .pos
    sec
    sbc #1
.pos
    ENDM

spin_init
    ldx #NPT-1
spin_init_1
    lda shp_x,x
    sta s_cx,x
    lda shp_y,x
    sta s_cy,x
    lda shp_z,x
    sta s_cz,x
    dex
    bpl spin_init_1
    lda #0
    sta s_base
    sta s_a
    sta s_a+1
    sta s_b
    sta s_da+1
    sta s_db+1
    lda #$E0
    sta s_b+1               ; tilted an eighth of a turn
    lda #$C0
    sta s_da
    lda #$50
    sta s_db
    rts

spin_next                   ; the next shape
    lda s_base
    clc
    adc #NPT
    and #$7F
    sta s_base
    rts

spin_step
    ; the stick changes the speeds
    lda $0280               ; SWCHA: right, left, down, up (0 = pushed)
    bmi spin_j1
    S_SPEED s_da, 8
spin_j1
    bit $0280
    bvs spin_j2
    S_SPEED s_da, -8
spin_j2
    lda $0280
    and #$20
    bne spin_j3
    S_SPEED s_db, 8
spin_j3
    lda $0280
    and #$10
    bne spin_j4
    S_SPEED s_db, -8
spin_j4

    ; the points walk toward the shape wanted
    ldx #NPT-1
spin_m1
    txa
    ora s_base
    tay
    S_MORPH shp_x, s_cx
    S_MORPH shp_y, s_cy
    S_MORPH shp_z, s_cz
    dex
    bmi spin_m2
    jmp spin_m1
spin_m2

    lda s_a
    sta s_ua
    lda s_a+1
    sta s_ua+1
    lda s_b
    sta s_ub
    lda s_b+1
    sta s_ub+1

    lda #1
    sta $043A               ; signed
    lda #0
    sta $0433               ; B high (FX and FY are bytes)
    sta $0420               ; X low: stays 0
    ldx #NPT-1
spin_pt
    lda #0
    sta $0422
    lda s_cx,x
    eor #$80
    sta $0421               ; X = x
    lda s_cz,x
    eor #$80
    sta $0423               ; Y = z
    lda s_ua
    sta $0424
    lda s_ua+1
    sta $0425               ; T = A
    lda $0420
    sta $0430
    lda $0421
    sta $0431               ; multiplier A = x1
    ldy $0422
    lda $0423
    sty $0422
    sta $0423               ; Y = z1
    lda #FX
    sta $0432
    lda #1
    sta $043B
    lda #2
    sta $043B               ; ACC = x1 * FX
    lda s_cy,x
    eor #$80
    sta $0421               ; X = y
    lda s_ub
    sta $0424
    lda s_ub+1
    sta $0425               ; T = B
    lda $0423               ; z2: how far away
    tay
    cmp #$80
    ror
    sta temp1
    lda $0422
    ror
    sta temp2
    lda temp1
    cmp #$80
    ror
    sta temp1
    lda temp2
    ror
    clc
    adc #<DIST64
    sta $0438
    lda temp1
    adc #>DIST64
    sta $0439               ; D = z2 / 4 + DIST64
    tya
    eor #$80
    lsr
    lsr
    lsr
    lsr
    tay
    sty temp3               ; 0..15, nearest first
    lda #4
    sta $043B               ; N = x1 * FX
    S_FLOOR
    clc
    adc #CX-2
    sta s_sx,x
    lda $0420
    sta $0430
    lda $0421
    sta $0431               ; multiplier A = y2
    lda #FY
    sta $0432
    lda #1
    sta $043B
    lda #2
    sta $043B
    lda #4
    sta $043B               ; N = y2 * FY
    S_FLOOR
    clc
    adc #128                ; keep it on the screen (only a morph can go this far)
    cmp #128-84
    bcs spin_y1
    lda #128-84
spin_y1
    cmp #128+81
    bcc spin_y2
    ldy temp3
    lda #128+80
spin_y2
    clc
    adc s_ltop,y            ; the dot's top line (from centre + 128)
    sta s_sy,x
    and #7
    cmp s_lfit,y
    bcs spin_y3
    adc s_lpf,y             ; it fits in one zone: the sprite with the dot that far down,
    sta s_pf,x
    lda s_sy,x
    and #$F8                ; plotted at the top of the zone
    sta s_sy,x
    jmp spin_y4
spin_y3
    lda s_lpf,y             ; it crosses into the next zone
    sta s_pf,x
spin_y4
    dex
    bmi spin_done
    jmp spin_pt
spin_done
    clc
    lda s_a
    adc s_da
    sta s_a
    lda s_a+1
    adc s_da+1
    sta s_a+1
    clc
    lda s_b
    adc s_db
    sta s_b
    lda s_b+1
    adc s_db+1
    sta s_b+1
    rts

; Plot them, with 7800basic's PLOTSPRITE macro straight from the tables. The
; display lists must not change while MARIA is reading them, and 32 dots take
; most of vertical blank, so it is done in two parts (A on entry):
;   A = $00  the dots wholly in the top ten zones. Called right after
;            spin_step, part of the way down the screen: spin_step starts
;            after the top of the screen and takes at least 11,000 cycles,
;            97 lines, so MARIA is past line 80 and will not read those
;            lists again this frame.
;   A = $80  the others, in vertical blank.
SPLIT   = 72                ; a dot starting above this line ends above line 80
MACARG2CONST SET 0
MACARG3CONST SET 0
MACARG4CONST SET 0
MACARG5CONST SET 0
spin_plot
    sta temp8
    lda #NPT-1
    sta temp9
spin_plot_1
    ldx temp9
    lda s_sy,x
    sta temp5
    cmp #SPLIT
    ror
    eor temp8
    bpl spin_plot_4
    jmp spin_plot_2         ; the other part's
spin_plot_4
    lda s_sx,x
    sta temp4
    lda s_pf,x
    and #$E0
    sta temp3
    lda s_pf,x
    and #$1F
    sta temp6
    PLOTSPRITE dot0,temp3,temp4,temp5,temp6
spin_plot_2
    dec temp9
    bmi spin_plot_3
    jmp spin_plot_1
spin_plot_3
    rts

; By z2 / 16 + 8, nearest first: 6 big, 4 middle, 6 small.
s_ltop                      ; centre + 128 -> top line: CY - 128, less 2 or 1 lines above the centre
    .byte CY-130,CY-130,CY-130,CY-130,CY-130,CY-130,CY-129,CY-129,CY-129,CY-129,CY-129,CY-129,CY-129,CY-129,CY-129,CY-129
s_lfit                      ; fits in a zone if it starts less than this far down
    .byte 4,4,4,4,4,4,6,6,6,6,7,7,7,7,7,7
s_lpf                       ; palette * 32 + first sprite of the size
    .byte $20,$20,$20,$20,$20,$20,$44,$44,$64,$64,$8A,$8A,$8A,$8A,$8A,$8A

    include "tab.asm"
