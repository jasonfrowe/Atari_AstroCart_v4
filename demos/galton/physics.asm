; Galton board physics, on the AstroCart math unit (docs/MATHUNIT.md).
;
; Positions and velocities are 16-bit signed with 6 fractional bits, in 320A
; pixels (x 0-319, y 0-191) and pixels per frame. A ball is a disc of radius
; 4, a peg one of radius 2. Each frame a ball falls under gravity; when its
; centre is within 6 pixels of the nearest peg's it is pushed back out along
; the line between the centres and loses 1.5 times its velocity along that
; line (a bounce that keeps a quarter of the speed), plus a small random kick.
; A little drag sideways keeps a ball from flying across the board.
;
;   distance   r  = sqrt(dx*dx + dy*dy)       accumulator + square root
;   normal     n  = (dx, dy) / r              two divides (8 fractional bits)
;   approach   vn = vx*nx + vy*ny             accumulator, divide by 256
;   new v         = v - 1.25 * vn * n         two multiplies
;   new position  = peg + 6.1 * n             two multiplies
;
; Pegs: row r (0-6) has r+1 pegs at y = 24 + 14r, x = 160 + (2k - r) * 16.
; Bins: 8, each 32 pixels wide, centres at x = 48 + 32j.

NB      = 8                 ; balls
GRAV    = 5                 ; pixels/frame^2 * 64
VMAX    = 160               ; fastest fall: 2.5 pixels/frame (a ball must not jump a peg)
CONTACT = 384               ; 6 pixels * 64
PUSH    = 390               ; ...and a little more
BINTOP  = 116               ; below this line a ball is in a bin
FULL    = 36                ; balls that fill a bin (2 lines each)

M_A     = $0430
M_B     = $0432
M_N     = $0434
M_D     = $0438
M_CTRL  = $043A
M_CMD   = $043B
M_P     = $0430
M_Q     = $0434
M_R     = $0438
M_S     = $043A
M_RND   = $043E

g_xl    = $2200
g_xh    = $2208
g_yl    = $2210
g_yh    = $2218
g_vxl   = $2220
g_vxh   = $2228
g_vyl   = $2230
g_vyh   = $2238
g_st    = $2240             ; 0 waiting to drop, 1 falling
g_tm    = $2248             ; frames until the drop
g_sx    = $2250             ; where to draw it (plotsprite's x and y)
g_sy    = $2258
g_cnt   = $2260             ; balls in each bin
g_dirty = $2268             ; the background has changed
g_full  = $2269             ; a bin is full
g_tot   = $226A             ; balls landed (16 bits)
g_seed  = $226C
g_dig   = $226D             ; g_tot as three ASCII digits
g_i     = $2270
g_t     = $2271             ; (2)
g_sxv   = $2273             ; x / 2 in pixels (0-159)
g_ypv   = $2274             ; y in pixels
g_row   = $2275
g_base  = $2276
g_px    = $2277
g_py    = $2278
g_pxl   = $2279             ; the peg's position, 6 fractional bits
g_pxh   = $227A
g_pyl   = $227B
g_pyh   = $227C
g_dxl   = $227D
g_dxh   = $227E
g_dyl   = $227F
g_dyh   = $2280
g_sl    = $2281
g_sh    = $2282
g_nxl   = $2283
g_nxh   = $2284
g_nyl   = $2285
g_nyh   = $2286
g_vnl   = $2287
g_vnh   = $2288
g_j     = $2289

gal_init
    lda #1
    sta M_CTRL              ; signed
    lda g_seed
    sta M_RND
    lda #$A7
    sta M_RND
    lda g_seed
    eor #$5C
    sta M_RND
    lda #$31
    sta M_RND
    lda #0
    ldx #7
gi0
    sta g_cnt,x
    dex
    bpl gi0
    sta g_tot
    sta g_tot+1
    sta g_full
    lda #1
    sta g_dirty
    ldx #NB-1
gi1
    lda #0
    sta g_st,x
    txa
    asl
    asl
    asl
    asl
    asl
    clc
    adc #10
    sta g_tm,x
    dex
    bpl gi1
    jmp gal_digits

; g_tot -> three ASCII digits (the unit's divide: quotient and remainder by 10)
gal_digits
    lda g_tot
    sta M_N
    lda g_tot+1
    sta M_N+1
    lda #0
    sta M_N+2
    sta M_N+3
    sta M_D+1
    lda #10
    sta M_D
    ldx #2
gd1
    lda M_R
    ora #$30
    sta g_dig,x
    lda M_Q
    ldy M_Q+1
    sta M_N
    sty M_N+1
    dex
    bpl gd1
    rts

gal_step
    lda g_full
    beq gs0
    rts
gs0
    ldx #NB-1
gs_loop
    stx g_i
    lda g_st,x
    bne gs_fall
    dec g_tm,x
    beq gs_spawn
    jmp gs_next
gs_spawn
    lda M_RND               ; x = 160 +- 1 pixel
    lsr
    sec                     ; (+1: 0..127 is centred on 63.5)
    adc #$C0
    sta g_xl,x
    lda #$27
    adc #0
    sta g_xh,x
    lda #0
    sta g_yl,x
    sta g_vyl,x
    sta g_vyh,x
    lda #1
    sta g_yh,x              ; y = 4
    sta g_st,x
    lda M_RND               ; vx = +- 1/4 pixel/frame (a difference: no lean)
    and #15
    sta g_t
    lda M_RND
    and #15
    sec
    sbc g_t
    sta g_vxl,x
    lda #0
    bcs gs_sp1
    lda #$FF
gs_sp1
    sta g_vxh,x
    jmp gs_done

gs_fall
    clc                     ; gravity
    lda g_vyl,x
    adc #GRAV
    sta g_vyl,x
    lda g_vyh,x
    adc #0
    sta g_vyh,x
    bmi gs_vok
    bne gs_clamp
    lda g_vyl,x
    cmp #VMAX
    bcc gs_vok
gs_clamp
    lda #VMAX
    sta g_vyl,x
    lda #0
    sta g_vyh,x
gs_vok
    lda g_vxl,x             ; air drag sideways: vx = vx - vx / 64 (rounded toward 0,
    sta g_t                 ; or the board leans)
    lda g_vxh,x
    sta g_t+1
    bpl gs_drag0
    clc
    lda g_t
    adc #63
    sta g_t
    bcc gs_drag0
    inc g_t+1
gs_drag0
    ldy #6
gs_drag
    lda g_t+1
    cmp #$80
    ror g_t+1
    ror g_t
    dey
    bne gs_drag
    sec
    lda g_vxl,x
    sbc g_t
    sta g_vxl,x
    lda g_vxh,x
    sbc g_t+1
    sta g_vxh,x
    clc                     ; move
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
    jsr g_coords
    lda g_xh,x              ; side walls
    bmi gs_wall_l
    lda g_sxv
    cmp #6
    bcc gs_wall_l
    cmp #154
    bcc gs_wall_ok
    lda #$80
    sta g_xl,x
    lda #$4C
    sta g_xh,x
    bne gs_wall_b
gs_wall_l
    lda #0
    sta g_xl,x
    lda #3
    sta g_xh,x
gs_wall_b
    sec                     ; vx = -vx / 2
    lda #0
    sbc g_vxl,x
    sta g_vxl,x
    lda #0
    sbc g_vxh,x
    sta g_vxh,x
    cmp #$80
    ror g_vxh,x
    ror g_vxl,x
    jsr g_coords
gs_wall_ok
    lda g_ypv
    cmp #BINTOP
    bcs gs_bin
    jmp gs_pegs

; ---- in a bin: straight down its middle until it meets the pile ----
gs_bin
    lda g_sxv
    sec
    sbc #16
    bcs gs_b1
    lda #0
gs_b1
    lsr
    lsr
    lsr
    lsr
    cmp #8
    bcc gs_b2
    lda #7
gs_b2
    sta g_j
    tay
    asl
    asl
    asl
    clc
    adc #12
    sta g_xh,x              ; x = 48 + 32j
    lda #0
    sta g_xl,x
    sta g_vxl,x
    sta g_vxh,x
    lda g_cnt,y
    asl
    sta g_t
    lda #187
    sec
    sbc g_t
    sta g_t                 ; where its centre comes to rest
    lda g_ypv
    cmp g_t
    bcs gs_land
    jmp gs_done
gs_land
    lda g_cnt,y
    clc
    adc #1
    sta g_cnt,y
    cmp #FULL
    bcc gs_l1
    lda #1
    sta g_full
gs_l1
    inc g_tot
    bne gs_l2
    inc g_tot+1
gs_l2
    lda #1
    sta g_dirty
    lda #0
    sta g_st,x
    lda M_RND
    and #31
    clc
    adc #20
    sta g_tm,x
    jsr gal_digits
    jmp gs_next

; ---- the nearest peg ----
gs_pegs
    ldy #0
    lda #31
    sta g_t
gs_r1
    lda g_ypv
    cmp g_t
    bcc gs_r2
    lda g_t
    clc
    adc #14
    sta g_t
    iny
    cpy #7
    bne gs_r1
    dey
gs_r2
    sty g_row
    tya
    asl
    asl
    asl
    sta g_t
    lda #80
    sec
    sbc g_t
    sta g_base              ; x/2 of the row's first peg
    lda g_sxv
    clc
    adc #8
    sec
    sbc g_base
    bcs gs_k1
    jmp gs_done             ; left of the row
gs_k1
    lsr
    lsr
    lsr
    lsr
    cmp g_row
    beq gs_k2
    bcc gs_k2
    jmp gs_done             ; right of it
gs_k2
    asl
    asl
    asl
    asl
    clc
    adc g_base
    sta g_px
    lda g_pytab,y
    sta g_py
    lda g_px                ; the peg's position with 6 fractional bits
    lsr
    sta g_pxh
    lda #0
    ror
    sta g_pxl
    lda #0
    sta g_pyl
    lda g_py
    lsr
    ror g_pyl
    lsr
    ror g_pyl
    sta g_pyh
    sec                     ; d = ball - peg
    lda g_xl,x
    sbc g_pxl
    sta g_dxl
    lda g_xh,x
    sbc g_pxh
    sta g_dxh
    sec
    lda g_yl,x
    sbc g_pyl
    sta g_dyl
    lda g_yh,x
    sbc g_pyh
    sta g_dyh
    lda g_dxh               ; more than 8 pixels away either way: no contact
    clc
    adc #2
    cmp #4
    bcc gs_c1
    jmp gs_done
gs_c1
    lda g_dyh
    clc
    adc #2
    cmp #4
    bcc gs_c2
    jmp gs_done
gs_c2
    lda #1                  ; r = sqrt(dx*dx + dy*dy)
    sta M_CMD
    lda g_dxl
    sta M_A
    sta M_B
    lda g_dxh
    sta M_A+1
    sta M_B+1
    lda #2
    sta M_CMD
    lda g_dyl
    sta M_A
    sta M_B
    lda g_dyh
    sta M_A+1
    sta M_B+1
    lda #2
    sta M_CMD
    lda #4
    sta M_CMD
    lda M_S
    sta g_sl
    lda M_S+1
    sta g_sh
    lda g_sl
    cmp #<CONTACT
    lda g_sh
    sbc #>CONTACT
    bcc gs_c3
    jmp gs_done             ; not touching
gs_c3
    lda g_sl
    ora g_sh
    bne gs_c4
    jmp gs_done             ; dead centre: wait for the next frame
gs_c4
    lda #0                  ; nx = dx * 256 / r
    sta M_N
    lda g_dxl
    sta M_N+1
    lda g_dxh
    sta M_N+2
    jsr g_sign
    sta M_N+3
    lda g_sl
    sta M_D
    lda g_sh
    sta M_D+1
    lda M_Q
    sta g_nxl
    lda M_Q+1
    sta g_nxh
    lda g_dyl               ; ny
    sta M_N+1
    lda g_dyh
    sta M_N+2
    jsr g_sign
    sta M_N+3
    lda M_Q
    sta g_nyl
    lda M_Q+1
    sta g_nyh
    lda #1                  ; vn = (vx*nx + vy*ny) / 256
    sta M_CMD
    lda g_vxl,x
    sta M_A
    lda g_vxh,x
    sta M_A+1
    jsr g_bnx
    lda #2
    sta M_CMD
    lda g_vyl,x
    sta M_A
    lda g_vyh,x
    sta M_A+1
    jsr g_bny
    lda #2
    sta M_CMD
    lda #4
    sta M_CMD
    lda #0
    sta M_D
    lda #1
    sta M_D+1
    lda M_Q
    sta g_vnl
    lda M_Q+1
    sta g_vnh
    lda #<PUSH              ; out to the contact distance: position = peg + PUSH * n
    sta M_A
    lda #>PUSH
    sta M_A+1
    jsr g_bnx
    jsr g_phi
    clc
    lda g_t
    adc g_pxl
    sta g_xl,x
    lda g_t+1
    adc g_pxh
    sta g_xh,x
    jsr g_bny
    jsr g_phi
    clc
    lda g_t
    adc g_pyl
    sta g_yl,x
    lda g_t+1
    adc g_pyh
    sta g_yh,x
    lda g_vnh
    bmi gs_c5
    jmp gs_done             ; already moving away
gs_c5
    lda g_vnl               ; v = v - 1.25 * vn * n
    sta g_t
    lda g_vnh
    sta g_t+1
    cmp #$80
    ror g_t+1
    ror g_t
    lda g_t+1
    cmp #$80
    ror g_t+1
    ror g_t
    clc
    lda g_vnl
    adc g_t
    sta M_A
    lda g_vnh
    adc g_t+1
    sta M_A+1
    jsr g_bnx
    jsr g_phi
    sec
    lda g_vxl,x
    sbc g_t
    sta g_vxl,x
    lda g_vxh,x
    sbc g_t+1
    sta g_vxh,x
    jsr g_bny
    jsr g_phi
    sec
    lda g_vyl,x
    sbc g_t
    sta g_vyl,x
    lda g_vyh,x
    sbc g_t+1
    sta g_vyh,x
    lda M_RND               ; a random kick sideways, -7..7 (the difference of two
    and #7                  ; random numbers: no lean either way)
    sta g_t
    lda M_RND
    and #7
    sec
    sbc g_t
    sta g_t
    lda #0
    bcs gs_c6
    lda #$FF
gs_c6
    sta g_t+1
    clc
    lda g_vxl,x
    adc g_t
    sta g_vxl,x
    lda g_vxh,x
    adc g_t+1
    sta g_vxh,x

gs_done
    ldx g_i
    jsr g_coords
    lda g_sxv
    sec
    sbc #2
    bcs gs_d1
    lda #0
gs_d1
    sta g_sx,x
    lda g_ypv
    sec
    sbc #4
    bcs gs_d2
    lda #0
gs_d2
    cmp #184
    bcc gs_d3
    lda #184
gs_d3
    sta g_sy,x
gs_next
    ldx g_i
    dex
    bmi gs_end
    jmp gs_loop
gs_end
    rts

g_phi                       ; g_t = the product / 256, rounded to nearest
    lda M_P
    cmp #$80                ; carry = round up
    lda M_P+1
    adc #0
    sta g_t
    lda M_P+2
    adc #0
    sta g_t+1
    rts
g_sign                      ; A = $FF if A is negative, else 0
    and #$80
    beq g_sign1
    lda #$FF
g_sign1
    rts
g_bnx
    lda g_nxl
    sta M_B
    lda g_nxh
    sta M_B+1
    rts
g_bny
    lda g_nyl
    sta M_B
    lda g_nyh
    sta M_B+1
    rts

; g_sxv = x / 2 (pixels), g_ypv = y (pixels; 0 above the screen)
g_coords
    lda g_xl,x
    asl
    lda g_xh,x
    rol
    sta g_sxv
    lda g_yh,x
    bpl g_co1
    lda #0
    sta g_ypv
    rts
g_co1
    lda g_yl,x
    sta g_t
    lda g_yh,x
    asl g_t
    rol
    asl g_t
    rol
    sta g_ypv
    rts

g_pytab
    .byte 24, 38, 52, 66, 80, 94, 108
