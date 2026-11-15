; AstroCart math unit self-test (docs/MATHUNIT.md). 32K linear cart.
; Runs the script in script.asm against the unit at $0420-$043F and reports:
;   green screen, $44 = $A5 : every read matched
;   red screen,   $44 = $EE : a read differed. $42/$43 = number of script steps
;                             done before it, $45 = register (0-31 = $0420-$043F), $46 = what
;                             was read, $47 = what the reference model says
;   $44 = 0 : still running
    processor 6502
INPTCTRL = $01
BACKGRND = $20
MSTAT    = $28
DPPH     = $2C
DPPL     = $30
CTRL     = $3C
ptr      = $40          ; script pointer
steps    = $42          ; steps done (16 bits)
status   = $44
freg     = $45
fgot     = $46
fwant    = $47
val      = $48
rdstub   = $50          ; lda $04xx / rts   (absolute, not indexed: no dummy reads)
wrstub   = $54          ; sta $04xx / rts
DLL      = $1800
NULLDL   = $1880

    org $8000
script
    include "script.asm"

    org $F000
reset
    sei
    cld
    lda #$07
    sta INPTCTRL        ; 7800 mode, lock
    lda #$7F
    sta CTRL            ; DMA off
    ldx #$FF
    txs
    lda #0
    sta BACKGRND
    sta status
    sta steps
    sta steps+1
    sta freg
    sta fgot
    sta fwant
    sta NULLDL
    sta NULLDL+1
    ; a display list list of empty 16-line zones, so the background colour shows
    ldx #0
mkdll
    lda #$0F
    sta DLL,x
    lda #>NULLDL
    sta DLL+1,x
    lda #<NULLDL
    sta DLL+2,x
    inx
    inx
    inx
    cpx #96
    bne mkdll
    lda #>DLL
    sta DPPH
    lda #<DLL
    sta DPPL
w1  bit MSTAT           ; wait for the start of vertical blank
    bmi w1
w2  bit MSTAT
    bpl w2
    lda #$40
    sta CTRL            ; DMA on
    ; the access stubs
    lda #$AD
    sta rdstub
    lda #$8D
    sta wrstub
    lda #$04
    sta rdstub+2
    sta wrstub+2
    lda #$60
    sta rdstub+3
    sta wrstub+3
    lda #<script
    sta ptr
    lda #>script
    sta ptr+1
next
    ldy #0
    lda (ptr),y
    cmp #$FF
    beq pass
    tax
    iny
    lda (ptr),y
    sta val
    txa
    and #$1F
    ora #$20
    sta rdstub+1
    sta wrstub+1
    cpx #$20
    bcs doread
    lda val
    jsr wrstub
    jmp step
doread
    jsr rdstub
    cmp val
    bne fail
step
    clc
    lda ptr
    adc #2
    sta ptr
    bcc s1
    inc ptr+1
s1  inc steps
    bne next
    inc steps+1
    jmp next
fail
    sta fgot
    lda val
    sta fwant
    txa
    and #$1F
    sta freg
    lda #$EE
    sta status
    lda #$44            ; red
    sta BACKGRND
hang
    jmp hang
pass
    lda #$A5
    sta status
    lda #$C8            ; green
    sta BACKGRND
    jmp hang
nmi
    rti

    org $FFF8
    .byte $FF, $F7      ; signature covers $F000-$FFFF
    .word nmi
    .word reset
    .word nmi
