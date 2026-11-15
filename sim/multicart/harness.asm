; Simulation harness for menu/fat.asm: runs on the 6502 model in tb.cpp, in
; place of the 7800basic menu. Results and requests go through console RAM:
;   $1F00 ac_init result   $1F01 games found   $1F02 game to load (from the tb)
;   $1F03 go (from the tb) $1F04 ac_load / ac_enter result
;   $1F05 what to do with entry $1F02: 0 load, 1 enter (a directory)
;   $1F06 ac_cur after ac_enter
;   $1FFF progress marker: $A1 after ac_init, $A2 after ac_load, $A3 after ac_enter
    processor 6502
FPTR = $FE
    org $8000
reset
    sei
    cld
    ldx #$FF
    txs
    jsr ac_init
    sta $1F00
    lda ac_nent
    sta $1F01
    lda #$A1
    sta $1FFF
waitgo
    lda $1F03
    beq waitgo
    lda #0
    sta $1F03
    lda $1F05
    beq doload
    lda $1F02
    jsr ac_enter
    sta $1F04
    lda ac_nent
    sta $1F01
    lda ac_cur
    sta $1F06
    lda #$A3
    sta $1FFF
    jmp waitgo
doload
    lda $1F02
    jsr ac_load
    sta $1F04
    lda #$A2
    sta $1FFF
    lda $1F04
    bne hang
    jmp ac_launch
hang
    jmp hang
    include "fat.asm"
    org $FFFA
    .word reset
    .word reset
    .word reset
