; Emulator-only stand-in for ac_init (build.sh emu): no SD card there, so
; make up a list of titles to look at the menu's display and paging.
ac_fakeinit
    lda #37
    sta ac_nent
    lda #0
    sta ac_i
ac_fake1
    ldx ac_i
    txa
    sta ac_ord,x
    lda #2
    cpx #3
    bcs ac_fake1a
    lda #1                  ; the first three: directories (do not open them here)
ac_fake1a
    sta ac_ef,x
    lda ac_i
    jsr ac_tptr
    ldy #31
ac_fake2
    lda ac_faketitle,y
    sta (FPTR),y
    dey
    bpl ac_fake2
    ; two decimal digits of the game number
    lda ac_i
    ldx #"0"
ac_fake3
    cmp #10
    bcc ac_fake4
    sbc #10
    inx
    bne ac_fake3
ac_fake4
    ora #"0"
    ldy #13
    sta (FPTR),y
    dey
    txa
    sta (FPTR),y
    inc ac_i
    lda ac_i
    cmp ac_nent
    bne ac_fake1
    ldy #31
ac_fake5
    lda ac_fakecwd,y
    sta AC_CWD,y
    dey
    bpl ac_fake5
    lda #0
    rts
ac_fakeinfo                 ; (no SD card: a made-up header)
    ldy #31
ac_fakeinfo1
    lda ac_fakei1,y
    sta AC_INFO,y
    lda ac_fakei2,y
    sta AC_INFO+32,y
    dey
    bpl ac_fakeinfo1
    rts
ac_fakei1
    .byte "Title From The Header           "
ac_fakei2
    .byte "128K SUPERGAME+RAM POKEY NTSC   "
ac_fakecwd
    .byte "Homebrews/                      "
ac_faketitle
    .byte "Test Game # 00 (Emulator) wxyz|!"
