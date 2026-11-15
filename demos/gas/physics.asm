; Gas in a box, on the AstroCart math unit (docs/MATHUNIT.md). model.py is
; this file's arithmetic in Python, operation for operation.
;
; Twelve equal discs (radius 4) in a box, 16-bit positions and velocities with
; 6 fractional bits. They start with the same speed in random directions.
; Walls reflect. Two discs closer than 8 pixels are moved apart and exchange
; their velocity along the line between their centres:
;
;   d   = position i - position j
;   r2  = dx*dx + dy*dy,  r = sqrt(r2)        accumulator + square root
;   apart:  d * (8 - r) / 2r                  one divide, two multiplies
;   k   = (dv . d) / r2                       accumulator, three divides (two
;                                             of them shifts), 12 fractional bits
;   vi -= k d,  vj += k d                     two multiplies
;
; No unit vector is formed: normalising with a truncating divide lost 2% of
; the energy at every collision (model.py, first version) and the gas cooled.
;
; Every frame each disc's speed, sqrt(vx*vx + vy*vy), is counted into one of
; eight bins; every 128 frames the counts go into the bars' running averages.

NB      = 12
XMIN    = 6*64
XMAX    = 313*64
YMIN    = 22*64
YMAX    = 122*64
CONTACT = 512

g_xl    = $2200
g_xh    = $2210
g_yl    = $2220
g_yh    = $2230
g_vxl   = $2240
g_vxh   = $2250
g_vyl   = $2260
g_vyh   = $2270
g_sx    = $2280
g_sy    = $2290
g_hl    = $22A0             ; this window's counts (16 bits each)
g_hh    = $22A8
g_bar   = $22B0             ; the last window's bars, in lines
g_dirty = $22B8
g_frame = $22B9
g_seed  = $22BA             ; (4)
g_steps = $22BE             ; (2)
g_i     = $22C0
g_j     = $22C1
g_t     = $22C2             ; (2)
g_dxl   = $22C4
g_dxh   = $22C5
g_dyl   = $22C6
g_dyh   = $22C7
g_rl    = $22C8
g_rh    = $22C9
g_d16l  = $22CA
g_d16h  = $22CB
g_q     = $22CC             ; (4)
g_ul    = $22D0             ; dv
g_uh    = $22D1
g_wl    = $22D2
g_wh    = $22D3
g_first = $22D4             ; no window finished yet
g_al    = $22D8             ; the bars' running sums (16 bits each)
g_ah    = $22E0

    MAC G_WALL              ; {1},{2} position, {3},{4} velocity, {5} low limit, {6} high limit
    sec
    lda {1},x
    sbc #<{5}
    lda {2},x
    sbc #>{5}
    bcs .hi
    sec                     ; below: x = 2 * limit - x
    lda #<(2*{5})
    sbc {1},x
    sta {1},x
    lda #>(2*{5})
    sbc {2},x
    sta {2},x
    jmp .neg
.hi
    sec
    lda {1},x
    sbc #<{6}
    lda {2},x
    sbc #>{6}
    bcc .done
    sec
    lda #<(2*{6})
    sbc {1},x
    sta {1},x
    lda #>(2*{6})
    sbc {2},x
    sta {2},x
.neg
    sec
    lda #0
    sbc {3},x
    sta {3},x
    lda #0
    sbc {4},x
    sta {4},x
.done
    ENDM

gas_init
    lda #1
    sta $043A               ; signed
    ldx #0
gi0
    lda g_seed,x
    sta $043E
    inx
    cpx #4
    bne gi0
    ldx #0
gi1
    lda g_x0l,x
    sta g_xl,x
    lda g_x0h,x
    sta g_xh,x
    lda g_y0l,x
    sta g_yl,x
    lda g_y0h,x
    sta g_yh,x
    lda $043E               ; one of 16 directions
    and #15
    tay
    lda g_dirx,y
    sta g_vxl,x
    jsr g_sign
    sta g_vxh,x
    lda g_diry,y
    sta g_vyl,x
    jsr g_sign
    sta g_vyh,x
    inx
    cpx #NB
    bne gi1
    lda #0
    ldx #7
gi2
    sta g_hl,x
    sta g_hh,x
    sta g_bar,x
    dex
    bpl gi2
    sta g_frame
    sta g_steps
    sta g_steps+1
    lda #1
    sta g_first
    sta g_dirty
    jmp g_coords

gas_step
    inc g_steps
    bne gs0
    inc g_steps+1
gs0
    ; ---- move, walls ----
    ldx #0
gs_mv
    clc
    lda g_xl,x
    adc g_vxl,x
    sta g_xl,x
    lda g_xh,x
    adc g_vxh,x
    sta g_xh,x
    clc
    lda g_yl,x
    adc g_vyl,x
    sta g_yl,x
    lda g_yh,x
    adc g_vyh,x
    sta g_yh,x
    G_WALL g_xl, g_xh, g_vxl, g_vxh, XMIN, XMAX
    G_WALL g_yl, g_yh, g_vyl, g_vyh, YMIN, YMAX
    inx
    cpx #NB
    beq gs_mv1
    jmp gs_mv
gs_mv1
    ; ---- every pair ----
    lda #0
    sta g_i
gs_i
    ldx g_i
    inx
    stx g_j
gs_j
    jsr g_pair
    inc g_j
    lda g_j
    cmp #NB
    bcc gs_j
    inc g_i
    lda g_i
    cmp #NB-1
    bcc gs_i
    ; ---- speeds ----
    ldx #0
gs_sp
    lda #1
    sta $043B
    lda g_vxl,x
    sta $0430
    sta $0432
    lda g_vxh,x
    sta $0431
    sta $0433
    lda #2
    sta $043B
    lda g_vyl,x
    sta $0430
    sta $0432
    lda g_vyh,x
    sta $0431
    sta $0433
    lda #2
    sta $043B
    lda #4
    sta $043B
    lda $043A               ; speed >> 5: the bin
    sta g_t
    lda $043B
    ldy #5
gs_sp1
    lsr
    ror g_t
    dey
    bne gs_sp1
    tay                     ; (what is left of the high byte)
    bne gs_sp2
    lda g_t
    cmp #8
    bcc gs_sp3
gs_sp2
    lda #7
gs_sp3
    tay
    lda g_hl,y
    clc
    adc #1
    sta g_hl,y
    bcc gs_sp4
    lda g_hh,y
    adc #0
    sta g_hh,y
gs_sp4
    inx
    cpx #NB
    bne gs_sp
    ; ---- a window done: counts / 8 are the bars ----
    inc g_frame
    lda g_frame
    cmp #128
    bcs gs_win
    jmp g_coords
gs_win
    lda #0
    sta g_frame
    ldx #7
gs_w
    ; A running average over about eight windows (17 seconds): one window of
    ; twelve discs is too few to show a distribution.
    ;   sum = sum - sum / 8 + count      (the first window: sum = 8 * count)
    ;   bar = sum / 64 lines             (= the average count / 8)
    lda g_first
    beq gs_w1
    lda g_hl,x              ; sum = 8 * count
    sta g_al,x
    lda g_hh,x
    asl g_al,x
    rol
    asl g_al,x
    rol
    asl g_al,x
    rol
    sta g_ah,x
    jmp gs_w2
gs_w1
    lda g_al,x              ; t = sum / 8
    sta g_t
    lda g_ah,x
    lsr
    ror g_t
    lsr
    ror g_t
    lsr
    ror g_t
    sta g_t+1
    sec
    lda g_al,x
    sbc g_t
    sta g_al,x
    lda g_ah,x
    sbc g_t+1
    sta g_ah,x
    clc
    lda g_al,x
    adc g_hl,x
    sta g_al,x
    lda g_ah,x
    adc g_hh,x
    sta g_ah,x
gs_w2
    lda g_al,x              ; bar = sum / 64, at most 255
    sta g_t
    lda g_ah,x
    asl g_t
    rol
    asl g_t
    rol
    sta g_bar,x             ; (sum < 16384: the top two bits of the sum's high byte are 0)
    lda #0
    sta g_hl,x
    sta g_hh,x
    dex
    bpl gs_w
    lda #0
    sta g_first
    lda #1
    sta g_dirty

g_coords
    ldx #0
gc1
    lda g_xl,x
    asl
    lda g_xh,x
    rol
    sec
    sbc #2
    sta g_sx,x
    lda g_yl,x
    sta g_t
    lda g_yh,x
    asl g_t
    rol
    asl g_t
    rol
    sec
    sbc #4
    sta g_sy,x
    inx
    cpx #NB
    bne gc1
    rts

; ---- discs g_i and g_j ----
g_pair
    ldx g_i
    ldy g_j
    sec
    lda g_xl,x
    sbc g_xl,y
    sta g_dxl
    lda g_xh,x
    sbc g_xh,y
    sta g_dxh
    clc
    adc #2
    cmp #4
    bcc gp1
    rts
gp1
    sec
    lda g_yl,x
    sbc g_yl,y
    sta g_dyl
    lda g_yh,x
    sbc g_yh,y
    sta g_dyh
    clc
    adc #2
    cmp #4
    bcc gp2
    rts
gp2
    lda #1                  ; r2 = dx*dx + dy*dy, r
    sta $043B
    jsr g_adx
    jsr g_bdx
    lda #2
    sta $043B
    jsr g_ady
    jsr g_bdy
    lda #2
    sta $043B
    lda #4
    sta $043B
    lda $043A
    sta g_rl
    lda $043B
    sta g_rh
    cmp #>CONTACT
    bcc gp3
    rts                     ; not touching
gp3
    ora g_rl
    bne gp4
    rts
gp4
    lda #16                 ; r2 >> 4
    sta $0438
    lda #0
    sta $0439
    lda $0434
    sta g_d16l
    lda $0435
    sta g_d16h
    sec                     ; apart: m = ((CONTACT - r) << 8) / 2r
    lda #<CONTACT
    sbc g_rl
    sta $0435
    lda #>CONTACT
    sbc g_rh
    sta $0436
    lda #0
    sta $0434
    sta $0437
    lda g_rl
    asl
    sta $0438
    lda g_rh
    rol
    sta $0439
    lda $0434
    sta $0430
    lda $0435
    sta $0431
    jsr g_bdx
    jsr g_phi
    clc
    lda g_xl,x
    adc g_t
    sta g_xl,x
    lda g_xh,x
    adc g_t+1
    sta g_xh,x
    sec
    lda g_xl,y
    sbc g_t
    sta g_xl,y
    lda g_xh,y
    sbc g_t+1
    sta g_xh,y
    jsr g_bdy
    jsr g_phi
    clc
    lda g_yl,x
    adc g_t
    sta g_yl,x
    lda g_yh,x
    adc g_t+1
    sta g_yh,x
    sec
    lda g_yl,y
    sbc g_t
    sta g_yl,y
    lda g_yh,y
    sbc g_t+1
    sta g_yh,y
    sec                     ; dv = v i - v j
    lda g_vxl,x
    sbc g_vxl,y
    sta g_ul
    lda g_vxh,x
    sbc g_vxh,y
    sta g_uh
    sec
    lda g_vyl,x
    sbc g_vyl,y
    sta g_wl
    lda g_vyh,x
    sbc g_vyh,y
    sta g_wh
    lda #1                  ; dv . d
    sta $043B
    lda g_ul
    sta $0430
    lda g_uh
    sta $0431
    jsr g_bdx
    lda #2
    sta $043B
    lda g_wl
    sta $0430
    lda g_wh
    sta $0431
    jsr g_bdy
    lda #2
    sta $043B
    lda #4
    sta $043B
    lda #1
    sta $0438
    lda #0
    sta $0439
    lda $0434
    sta g_q
    lda $0435
    sta g_q+1
    lda $0436
    sta g_q+2
    lda $0437
    bmi gp5
    rts                     ; already separating
gp5
    lda #0                  ; k = ((dv . d) << 8) / (r2 >> 4)
    sta $0434
    lda g_q
    sta $0435
    lda g_q+1
    sta $0436
    lda g_q+2
    sta $0437
    lda g_d16l
    sta $0438
    lda g_d16h
    sta $0439
    lda $0434
    sta $0430
    lda $0435
    sta $0431
    jsr g_bdx
    jsr g_phi4
    sec
    lda g_vxl,x
    sbc g_t
    sta g_vxl,x
    lda g_vxh,x
    sbc g_t+1
    sta g_vxh,x
    clc
    lda g_vxl,y
    adc g_t
    sta g_vxl,y
    lda g_vxh,y
    adc g_t+1
    sta g_vxh,y
    jsr g_bdy
    jsr g_phi4
    sec
    lda g_vyl,x
    sbc g_t
    sta g_vyl,x
    lda g_vyh,x
    sbc g_t+1
    sta g_vyh,x
    clc
    lda g_vyl,y
    adc g_t
    sta g_vyl,y
    lda g_vyh,y
    adc g_t+1
    sta g_vyh,y
    rts

g_adx
    lda g_dxl
    sta $0430
    lda g_dxh
    sta $0431
    rts
g_ady
    lda g_dyl
    sta $0430
    lda g_dyh
    sta $0431
    rts
g_bdx
    lda g_dxl
    sta $0432
    lda g_dxh
    sta $0433
    rts
g_bdy
    lda g_dyl
    sta $0432
    lda g_dyh
    sta $0433
    rts
g_phi                       ; g_t = the product / 256, rounded to nearest
    lda $0430
    cmp #$80
    lda $0431
    adc #0
    sta g_t
    lda $0432
    adc #0
    sta g_t+1
    rts
g_phi4                      ; g_t = (the product / 256 rounded, + 8) >> 4
    jsr g_phi
    clc
    lda g_t
    adc #8
    sta g_t
    bcc g_p41
    inc g_t+1
g_p41
    lda g_t+1
    cmp #$80
    ror g_t+1
    ror g_t
    lda g_t+1
    cmp #$80
    ror g_t+1
    ror g_t
    lda g_t+1
    cmp #$80
    ror g_t+1
    ror g_t
    lda g_t+1
    cmp #$80
    ror g_t+1
    ror g_t
    rts
g_sign
    and #$80
    beq g_sign1
    lda #$FF
g_sign1
    rts

    include "tab.asm"
