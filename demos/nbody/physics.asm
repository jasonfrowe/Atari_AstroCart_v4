; N-body gravity on the AstroCart math unit (docs/MATHUNIT.md). model.py is
; this file's arithmetic in Python, operation for operation: it chose the
; constants and writes the scenarios (scen.asm).
;
; Positions and velocities are 24-bit signed with 14 fractional bits, in 320A
; pixels and pixels per frame. Each frame, for every pair of bodies i < j:
;
;   d   = position j - position i             (16 bits, 6 fractional bits)
;   r   = sqrt(dx*dx + dy*dy + eps*eps)       accumulator + square root
;   n   = d * 256 / r                         two divides: the unit vector
;   gj  = (Kj / r) / r                        two unsigned divides: GMj / r^2,
;   gi  = (Ki / r) / r                        14 fractional bits (K = GM * 2^26)
;   vi += gj * n / 256,  vj -= gi * n / 256   four multiplies
;
; then every position moves by its velocity. eps (5 pixels) keeps a close pass
; from throwing a body out of the picture.

NBMAX   = 5
NBEPS   = 320               ; 5 pixels * 64
NTRAIL  = 4                 ; trail dots kept per body

n_n     = $2200             ; bodies in this scenario
n_xl    = $2208
n_xm    = $2210
n_xh    = $2218
n_yl    = $2220
n_ym    = $2228
n_yh    = $2230
n_vxl   = $2238
n_vxm   = $2240
n_vxh   = $2248
n_vyl   = $2250
n_vym   = $2258
n_vyh   = $2260
n_k0    = $2268
n_k1    = $2270
n_k2    = $2278
n_k3    = $2280
n_sx    = $2288             ; where to draw it; n_vis = 0 when it is off the screen
n_sy    = $2290
n_vis   = $2298
n_big   = $22A0             ; a star
n_tx    = $22A8             ; trails: NTRAIL per body (body * 8 + slot); x = 0: no dot
n_ty    = $22D0
n_th    = $22F8             ; next slot to write
n_tdiv  = $22F9
n_name  = $2300             ; the scenario's name, 16 characters
n_i     = $2310
n_j     = $2311
n_t     = $2312             ; (3)
n_dxl   = $2315
n_dxh   = $2316
n_dyl   = $2317
n_dyh   = $2318
n_rl    = $2319
n_rh    = $231A
n_nxl   = $231B
n_nxh   = $231C
n_nyl   = $231D
n_nyh   = $231E
n_q     = $231F             ; (4)
n_gl    = $2323
n_gh    = $2324
n_steps = $2326             ; frames simulated (16 bits)
n_ptr   = $FC               ; (zero page, 2: 7800basic's y and z are not used by the demo)

    MAC N_ADDV              ; {1},{2},{3}[x] (24 bits) += n_t (16 bits, signed)
    ldy #0
    lda n_t+1
    bpl .pos
    dey
.pos
    sty n_t+2
    clc
    lda {1},x
    adc n_t
    sta {1},x
    lda {2},x
    adc n_t+1
    sta {2},x
    lda {3},x
    adc n_t+2
    sta {3},x
    ENDM

    MAC N_SUBV              ; {1},{2},{3}[x] (24 bits) -= n_t (16 bits, signed)
    ldy #0
    lda n_t+1
    bpl .pos
    dey
.pos
    sty n_t+2
    sec
    lda {1},x
    sbc n_t
    sta {1},x
    lda {2},x
    sbc n_t+1
    sta {2},x
    lda {3},x
    sbc n_t+2
    sta {3},x
    ENDM

; ---- A = scenario number: load it ----
nb_init
    asl
    tax
    lda scen_name,x
    sta n_ptr
    lda scen_name+1,x
    sta n_ptr+1
    ldy #15
ni0
    lda (n_ptr),y
    sta n_name,y
    dey
    bpl ni0
    lda scen_tab,x
    sta n_ptr
    lda scen_tab+1,x
    sta n_ptr+1
    ldy #0
    lda (n_ptr),y
    sta n_n
    iny
    ldx #0
ni1
    lda (n_ptr),y
    sta n_xl,x
    iny
    lda (n_ptr),y
    sta n_xm,x
    iny
    lda (n_ptr),y
    sta n_xh,x
    iny
    lda (n_ptr),y
    sta n_yl,x
    iny
    lda (n_ptr),y
    sta n_ym,x
    iny
    lda (n_ptr),y
    sta n_yh,x
    iny
    lda (n_ptr),y
    sta n_vxl,x
    iny
    lda (n_ptr),y
    sta n_vxm,x
    iny
    lda (n_ptr),y
    sta n_vxh,x
    iny
    lda (n_ptr),y
    sta n_vyl,x
    iny
    lda (n_ptr),y
    sta n_vym,x
    iny
    lda (n_ptr),y
    sta n_vyh,x
    iny
    lda (n_ptr),y
    sta n_k0,x
    iny
    lda (n_ptr),y
    sta n_k1,x
    iny
    lda (n_ptr),y
    sta n_k2,x
    iny
    lda (n_ptr),y
    sta n_k3,x
    iny
    cmp #$20                ; GM of 8 or more: draw it as a star
    lda #0
    rol
    sta n_big,x
    inx
    cpx n_n
    bne ni1
    lda #0
    ldx #NBMAX*8-1
ni2
    sta n_tx,x
    dex
    bpl ni2
    sta n_th
    sta n_tdiv
    sta n_steps
    sta n_steps+1
    lda #1
    sta $043A               ; signed
    jmp nb_coords

; ---- one frame ----
nb_step
    inc n_steps
    bne ns_0
    inc n_steps+1
ns_0
    lda #0
    sta n_i
ns_i
    ldx n_i
    inx
    cpx n_n
    bcc ns_i1
    jmp ns_move
ns_i1
    stx n_j
ns_j
    jsr nb_pair
    inc n_j
    lda n_j
    cmp n_n
    bcc ns_j
    inc n_i
    jmp ns_i

nb_pair
    ldx n_i
    ldy n_j
    sec                     ; d = j - i, 6 fractional bits
    lda n_xm,y
    sbc n_xm,x
    sta n_dxl
    lda n_xh,y
    sbc n_xh,x
    sta n_dxh
    clc
    adc #$40
    bpl np1
    rts                     ; more than 256 pixels apart
np1
    sec
    lda n_ym,y
    sbc n_ym,x
    sta n_dyl
    lda n_yh,y
    sbc n_yh,x
    sta n_dyh
    clc
    adc #$40
    bpl np2
    rts
np2
    lda #1                  ; r = sqrt(dx*dx + dy*dy + eps*eps)
    sta $043B
    lda n_dxl
    sta $0430
    sta $0432
    lda n_dxh
    sta $0431
    sta $0433
    lda #2
    sta $043B
    lda n_dyl
    sta $0430
    sta $0432
    lda n_dyh
    sta $0431
    sta $0433
    lda #2
    sta $043B
    lda #<NBEPS
    sta $0430
    sta $0432
    lda #>NBEPS
    sta $0431
    sta $0433
    lda #2
    sta $043B
    lda #4
    sta $043B
    lda $043A
    sta n_rl
    lda $043B
    sta n_rh
    lda #0                  ; n = d * 256 / r
    sta $0434
    lda n_dxl
    sta $0435
    lda n_dxh
    sta $0436
    jsr nb_sign
    sta $0437
    lda n_rl
    sta $0438
    lda n_rh
    sta $0439
    lda $0434
    sta n_nxl
    lda $0435
    sta n_nxh
    lda n_dyl
    sta $0435
    lda n_dyh
    sta $0436
    jsr nb_sign
    sta $0437
    lda $0434
    sta n_nyl
    lda $0435
    sta n_nyh
    ; body i feels gj = (Kj / r) / r
    ldy n_j
    jsr nb_g
    ldx n_i
    jsr nb_bnx
    jsr nb_phi
    N_ADDV n_vxl, n_vxm, n_vxh
    jsr nb_bny
    jsr nb_phi
    N_ADDV n_vyl, n_vym, n_vyh
    ; body j feels gi, the other way
    ldy n_i
    jsr nb_g
    ldx n_j
    jsr nb_bnx
    jsr nb_phi
    N_SUBV n_vxl, n_vxm, n_vxh
    jsr nb_bny
    jsr nb_phi
    N_SUBV n_vyl, n_vym, n_vyh
    rts

; A (the multiplier's first operand) = (K[y] / r) / r, unsigned
nb_g
    lda #0
    sta $043A               ; unsigned
    lda n_k0,y
    sta $0434
    lda n_k1,y
    sta $0435
    lda n_k2,y
    sta $0436
    lda n_k3,y
    sta $0437
    lda $0434               ; (D is still r)
    sta n_q
    lda $0435
    sta n_q+1
    lda $0436
    sta n_q+2
    lda $0437
    sta n_q+3
    lda n_q
    sta $0434
    lda n_q+1
    sta $0435
    lda n_q+2
    sta $0436
    lda n_q+3
    sta $0437
    lda $0434
    sta $0430
    lda $0435
    sta $0431
    lda #1
    sta $043A               ; signed again
    rts

nb_bnx
    lda n_nxl
    sta $0432
    lda n_nxh
    sta $0433
    rts
nb_bny
    lda n_nyl
    sta $0432
    lda n_nyh
    sta $0433
    rts
nb_phi                      ; n_t = the product / 256, rounded to nearest
    lda $0430
    cmp #$80
    lda $0431
    adc #0
    sta n_t
    lda $0432
    adc #0
    sta n_t+1
    rts
nb_sign
    and #$80
    beq nb_sign1
    lda #$FF
nb_sign1
    rts

; ---- positions += velocities; trails; screen coordinates ----
ns_move
    ldx #0
nm1
    clc
    lda n_xl,x
    adc n_vxl,x
    sta n_xl,x
    lda n_xm,x
    adc n_vxm,x
    sta n_xm,x
    lda n_xh,x
    adc n_vxh,x
    sta n_xh,x
    clc
    lda n_yl,x
    adc n_vyl,x
    sta n_yl,x
    lda n_ym,x
    adc n_vym,x
    sta n_ym,x
    lda n_yh,x
    adc n_vyh,x
    sta n_yh,x
    inx
    cpx n_n
    bne nm1
    inc n_tdiv              ; every 8th frame the old positions become trail dots
    lda n_tdiv
    cmp #8
    bcc nb_coords
    lda #0
    sta n_tdiv
    ldx #0
nm2
    txa
    asl
    asl
    asl
    ora n_th
    tay
    lda #0
    sta n_tx,y
    lda n_vis,x
    beq nm3
    lda n_sx,x
    clc
    adc #1
    sta n_tx,y
    lda n_sy,x
    sta n_ty,y
nm3
    inx
    cpx n_n
    bne nm2
    inc n_th
    lda n_th
    and #NTRAIL-1
    sta n_th

nb_coords
    ldx #0
nc1
    lda #0
    sta n_vis,x
    lda n_xh,x              ; x pixel / 2 = position >> 15
    cmp #$50
    bcs nc2                 ; (negative, or beyond 319)
    lda n_xm,x
    asl
    lda n_xh,x
    rol
    cmp #3
    bcc nc2
    cmp #156
    bcs nc2
    sec
    sbc #2
    sta n_sx,x
    lda n_yh,x              ; y pixel = position >> 14
    cmp #$30
    bcs nc2
    lda n_ym,x
    sta n_t
    lda n_yh,x
    asl n_t
    rol
    asl n_t
    rol
    cmp #14                 ; (below the title)
    bcc nc2
    cmp #187
    bcs nc2
    sec
    sbc #4
    sta n_sy,x
    lda #1
    sta n_vis,x
nc2
    inx
    cpx n_n
    bne nc1
    rts

    include "scen.asm"
