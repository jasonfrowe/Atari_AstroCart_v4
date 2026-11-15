; ============================================================================
; fat.asm -- AstroCart V4 menu: SD card, FAT32, .a78 headers, game loading.
;
; dasm syntax; included by the 7800basic menu (menu.bas) and by the
; simulation harness (sim/multicart/harness.asm). The includer defines
;     FPTR    two zero-page bytes
; All other state lives in the cart's RAM at $4000 (slot 0), which is also
; where the FPGA puts SD blocks ($4000-$41FF).
;
; Cart registers (rtl/dev/devcart_top.v), $0460-$046F while the menu runs.
;
; Entry points (A = 0 and Z set when all is well, else an error code):
;     ac_init       card + file system + the root directory's list
;     ac_isdir      A = 1 if list entry A is a directory (".." included)
;     ac_enter      list entry A is a directory: go there, new list; ac_cur =
;                   the entry to put the cursor on (the directory just left)
;     ac_load       load list entry A (a game), set up the mapper registers
;     ac_launch     start the loaded game (does not return)
;     ac_line       copy the name of entry A into line buffer X (display)
;     ac_info       two lines about list entry A in AC_INFO (for a game: the
;                   title in its .a78 header; ROM size, mapper, POKEY, TV
;                   system, or NOT SUPPORTED); ac_infoclr blanks them
;
; The list: up to AC_MAXENT (255) entries of one directory -- its
; sub-directories and its *.a78 files -- with the file name (long name, cut
; to 32 characters, without ".a78") as the title. Sorted: "..", then the
; directories, then the games, each group alphabetically (case ignored).
; Entry numbers passed in A are positions in that sorted list (ac_ord maps
; them to the order the entries were found in). Hidden and system entries
; and names that begin with a dot (macOS's "._" files) are left out.
; AC_CWD holds the current directory's name for the display.
;
; High Score Cart: if the game's header asks for one and the card has
; /ASTROCART/HSC.A78 (the HSC's 4K ROM as an .a78 file) and
; /ASTROCART/HSC.SAV (2048 bytes: its battery RAM), ac_load puts both into
; PSRAM above the game ($3FC000 / $3FD000) and tells the cart where HSC.SAV's
; four blocks are; the cart then answers at $3000-$3FFF and $1000-$17FF and
; writes the RAM back to those blocks when it has changed. HSC.SAV must lie
; in one piece on the card (clusters of 2K or more: it then always does).
;
; Error codes:  $01-$0F SD card (sd_spi.v; $0F = timeout)   $0E no AstroCart
;               $10 no boot sector   $11 not FAT32          $12 bad cluster size
;               $20 cart type not supported   $21 file chain ends early
;               $22 PSRAM write failed        $23 not an .a78 file
;               $40 the cart's RAM does not read back what was written
; ============================================================================

SDREG       = $0460         ; W command / R status
SD_LBA      = $0461         ; ..$0464
SD_PTR      = $0465         ; ..$0467
SD_CFG      = $0468         ; ..$046F
SD_SIG      = $0461         ; R: $A7

SECBUF      = $4000         ; 512 bytes
FR          = $4200         ; variables
ac_part     = FR+$00        ; partition start (4)
ac_fatlba   = FR+$04
ac_datalba  = FR+$08
ac_rootclus = FR+$0C
ac_spc      = FR+$10        ; sectors per cluster
ac_shift    = FR+$11        ; log2 of it
ac_clus     = FR+$12        ; current cluster (4)
ac_lba      = FR+$16        ; block number (4)
ac_clba     = FR+$1A        ; block in SECBUF (4)
ac_cok      = FR+$1E        ; ... is valid
ac_dsec     = FR+$1F        ; directory walk: sector in cluster
ac_didx     = FR+$20        ; ... entry in sector (0-16)
ac_nent     = FR+$21        ; games found
ac_tmp      = FR+$22        ; (4)
ac_rem      = FR+$26        ; blocks left to load (2)
ac_first    = FR+$28
ac_fsize    = FR+$29        ; ROM size (3)
ac_nb       = FR+$2C        ; 16K banks
ac_off      = FR+$2D        ; PSRAM address of the image's first byte (3)
ac_cfg      = FR+$30        ; win4000, bank4000, sg, mask, add, bank8000, bankC000, pokey
ac_tl       = FR+$38        ; cart type, low / high byte (with the v4 fields folded in)
ac_th       = FR+$39
ac_gclus    = FR+$3A        ; the games directory (4)
ac_i        = FR+$3E
ac_j        = FR+$3F
ac_secleft  = FR+$40
ac_tmo      = FR+$41        ; (3)
ac_sel      = FR+$44
ac_dirent   = FR+$60        ; (32)

ac_lfnlen   = FR+$45        ; long name: length (0 = none), checksum
ac_lfnsum   = FR+$46
ac_lo       = FR+$47        ; sorted insert
ac_hi       = FR+$48
ac_mid      = FR+$49
ac_kcls     = FR+$4A        ; class of the new entry: 0 "..", 1 directory, 2 game
ac_depth    = FR+$4B        ; directories below the root
ac_cur      = FR+$4C        ; where the cursor should go after ac_enter
ac_from     = FR+$4D        ; (4) the directory left through ".."
ac_k        = FR+$51
ac_n        = FR+$52
ac_c        = FR+$53
ac_hsflag   = FR+$54        ; the game header's save-device byte (bit 0: High Score Cart)
ac_hsok     = FR+$55        ; /ASTROCART/HSC.A78 and HSC.SAV: 0 not looked for, 1 there, $FF not there
ac_hrc      = FR+$56        ; (4) first cluster of HSC.A78
ac_hsv      = FR+$5A        ; (4) first cluster of HSC.SAV

AC_MAXENT   = 255
ac_ec0      = $6800         ; first cluster, byte 0..3
ac_ec1      = ac_ec0+AC_MAXENT
ac_ec2      = ac_ec1+AC_MAXENT
ac_ec3      = ac_ec2+AC_MAXENT
ac_es0      = ac_ec3+AC_MAXENT      ; file size, byte 0..3
ac_es1      = ac_es0+AC_MAXENT
ac_es2      = ac_es1+AC_MAXENT
ac_es3      = ac_es2+AC_MAXENT
AC_LINES    = $4600         ; 16 lines of 32 characters for the display
AC_TITLES   = $4800         ; AC_MAXENT titles of 32 characters (to $67DF)
ac_ef       = $7000         ; class of each entry (as ac_kcls)
ac_ord      = $7100         ; list position -> entry
AC_CWD      = $7200         ; 32 characters: the current directory
AC_PATH     = $7220         ; 8 x 32: the names on the way down
ac_lfn      = $7320         ; first 39 characters of a long name
ac_key      = $7350         ; 32: the new entry's title, then its sort key
AC_INFO     = $7380         ; 2 x 32 characters about the entry under the cursor

; ---------------------------------------------------------------------------
; wait for the cart: A = SD error (0 = ok)
; ---------------------------------------------------------------------------
ac_wait
    lda #0
    sta ac_tmo
    sta ac_tmo+1
    sta ac_tmo+2
ac_wait1
    lda SDREG
    bpl ac_wait2
    inc ac_tmo
    bne ac_wait1
    inc ac_tmo+1
    bne ac_wait1
    inc ac_tmo+2
    lda ac_tmo+2
    cmp #12                 ; ~ 10 s
    bne ac_wait1
    lda #$0F
    rts
ac_wait2
    lda SDREG               ; busy is clear: read the rest again, settled
    and #$0F
    rts

; ---------------------------------------------------------------------------
; read block ac_lba into SECBUF (unless it is there already)
; ---------------------------------------------------------------------------
ac_rdbuf
    lda ac_cok
    beq ac_rdbuf1
    lda ac_lba
    cmp ac_clba
    bne ac_rdbuf1
    lda ac_lba+1
    cmp ac_clba+1
    bne ac_rdbuf1
    lda ac_lba+2
    cmp ac_clba+2
    bne ac_rdbuf1
    lda ac_lba+3
    cmp ac_clba+3
    bne ac_rdbuf1
    lda #0
    rts
ac_rdbuf1
    lda #0
    sta ac_cok
    jsr ac_setlba
    lda #2
    sta SDREG
    jsr ac_wait
    bne ac_rdbuf2
    ldx #3
ac_rdbuf3
    lda ac_lba,x
    sta ac_clba,x
    dex
    bpl ac_rdbuf3
    lda #1
    sta ac_cok
    lda #0
ac_rdbuf2
    rts

ac_setlba
    ldx #3
ac_setlba1
    lda ac_lba,x
    sta SD_LBA,x
    dex
    bpl ac_setlba1
    rts

; ---------------------------------------------------------------------------
; ac_lba = first block of cluster ac_clus
; ---------------------------------------------------------------------------
ac_c2lba
    sec
    lda ac_clus
    sbc #2
    sta ac_lba
    lda ac_clus+1
    sbc #0
    sta ac_lba+1
    lda ac_clus+2
    sbc #0
    sta ac_lba+2
    lda ac_clus+3
    sbc #0
    sta ac_lba+3
    ldx ac_shift
    beq ac_c2lba2
ac_c2lba1
    asl ac_lba
    rol ac_lba+1
    rol ac_lba+2
    rol ac_lba+3
    dex
    bne ac_c2lba1
ac_c2lba2
    clc
    ldx #0
    ldy #4
ac_c2lba3
    lda ac_lba,x
    adc ac_datalba,x
    sta ac_lba,x
    inx
    dey
    bne ac_c2lba3
    rts

; ---------------------------------------------------------------------------
; ac_clus = the cluster after ac_clus. Carry set at the end of the chain;
; A != 0 with carry set on a read error.
; ---------------------------------------------------------------------------
ac_next
    ; block = fat + (clus >> 7)
    lda ac_clus
    asl
    lda ac_clus+1
    rol
    sta ac_lba
    lda ac_clus+2
    rol
    sta ac_lba+1
    lda ac_clus+3
    rol
    sta ac_lba+2
    lda #0
    rol
    sta ac_lba+3
    clc
    ldx #0
    ldy #4
ac_next1
    lda ac_lba,x
    adc ac_fatlba,x
    sta ac_lba,x
    inx
    dey
    bne ac_next1
    jsr ac_rdbuf
    beq ac_next2
    sec
    rts
ac_next2
    lda ac_clus
    and #$3F
    asl
    asl
    tax
    lda ac_clus
    and #$40
    bne ac_next3
    lda SECBUF,x
    sta ac_clus
    lda SECBUF+1,x
    sta ac_clus+1
    lda SECBUF+2,x
    sta ac_clus+2
    lda SECBUF+3,x
    jmp ac_next4
ac_next3
    lda SECBUF+$100,x
    sta ac_clus
    lda SECBUF+$101,x
    sta ac_clus+1
    lda SECBUF+$102,x
    sta ac_clus+2
    lda SECBUF+$103,x
ac_next4
    and #$0F
    sta ac_clus+3
    ; end of chain: >= $0FFFFFF8, or < 2 (a broken chain)
    cmp #$0F
    bne ac_next5
    lda ac_clus+2
    and ac_clus+1
    cmp #$FF
    bne ac_next6
    lda ac_clus
    cmp #$F8
    bcc ac_next6
ac_nextend
    lda #0
    sec
    rts
ac_next5
    lda ac_clus+3
    ora ac_clus+2
    ora ac_clus+1
    bne ac_next6
    lda ac_clus
    cmp #2
    bcc ac_nextend
ac_next6
    lda #0
    clc
    rts

; ---------------------------------------------------------------------------
; mount: find the FAT32 volume
; ---------------------------------------------------------------------------
ac_mount
    lda #0
    sta ac_cok
    ldx #3
ac_mount1
    sta ac_lba,x
    sta ac_part,x
    dex
    bpl ac_mount1
    jsr ac_rdbuf
    beq ac_mount2
    rts
ac_mount2
    jsr ac_sig
    beq ac_mount3
    lda #$10
    rts
ac_mount3
    jsr ac_isbpb
    beq ac_mount8           ; no partition table
    lda SECBUF+$1C2
    cmp #$EE
    bne ac_mount5
    ; GPT: first entry's start block is at offset 32 of block 2
    lda #2
    sta ac_lba
    jsr ac_rdbuf
    beq ac_mount4
    rts
ac_mount4
    ldx #3
ac_mount4a
    lda SECBUF+32,x
    sta ac_part,x
    dex
    bpl ac_mount4a
    jmp ac_mount7
ac_mount5
    ldx #3
ac_mount6
    lda SECBUF+$1C6,x
    sta ac_part,x
    dex
    bpl ac_mount6
ac_mount7
    ldx #3
ac_mount7a
    lda ac_part,x
    sta ac_lba,x
    dex
    bpl ac_mount7a
    jsr ac_rdbuf
    beq ac_mount7b
    rts
ac_mount7b
    jsr ac_sig
    bne ac_mount7c
    jsr ac_isbpb
    beq ac_mount8
ac_mount7c
    lda #$10
    rts
ac_mount8
    ; FAT32: no fixed root directory, 16-bit FAT size is 0
    lda SECBUF+$11
    ora SECBUF+$12
    ora SECBUF+$16
    ora SECBUF+$17
    beq ac_mount9
    lda #$11
    rts
ac_mount9
    lda SECBUF+$0D
    sta ac_spc
    ldx #0
ac_mount10
    lsr
    bcs ac_mount11
    inx
    cpx #8
    bne ac_mount10
ac_mountbad
    lda #$12
    rts
ac_mount11
    bne ac_mountbad         ; more than one bit set
    stx ac_shift
    ; fat = part + reserved
    clc
    lda ac_part
    adc SECBUF+$0E
    sta ac_fatlba
    lda ac_part+1
    adc SECBUF+$0F
    sta ac_fatlba+1
    lda ac_part+2
    adc #0
    sta ac_fatlba+2
    lda ac_part+3
    adc #0
    sta ac_fatlba+3
    ; data = fat + nfats * fatsize
    ldx #3
ac_mount12
    lda ac_fatlba,x
    sta ac_datalba,x
    lda SECBUF+$2C,x
    sta ac_rootclus,x
    dex
    bpl ac_mount12
    ldy SECBUF+$10
ac_mount13
    clc
    lda ac_datalba
    adc SECBUF+$24
    sta ac_datalba
    lda ac_datalba+1
    adc SECBUF+$25
    sta ac_datalba+1
    lda ac_datalba+2
    adc SECBUF+$26
    sta ac_datalba+2
    lda ac_datalba+3
    adc SECBUF+$27
    sta ac_datalba+3
    dey
    bne ac_mount13
    lda #0
    rts

ac_sig                      ; Z set if the block ends $55 $AA
    lda SECBUF+$1FE
    cmp #$55
    bne ac_sig1
    lda SECBUF+$1FF
    cmp #$AA
ac_sig1
    rts

ac_isbpb                    ; Z set if SECBUF looks like a boot sector (512-byte sectors)
    lda SECBUF
    cmp #$EB
    beq ac_isbpb1
    cmp #$E9
    bne ac_isbpb2
ac_isbpb1
    lda SECBUF+$0B
    bne ac_isbpb2
    lda SECBUF+$0C
    cmp #2
    bne ac_isbpb2
    lda SECBUF+$10          ; number of FATs: 1 or 2
    beq ac_isbpb3
    cmp #3
    bcs ac_isbpb3
    lda #0
    rts
ac_isbpb3
    lda #1
ac_isbpb2
    rts

; ---------------------------------------------------------------------------
; directory walk: ac_diropen (cluster in ac_clus), then ac_dirnext until the
; carry comes back set. Each entry is copied to ac_dirent; deleted and
; volume-label entries are skipped. The long-name entries in front of an
; entry are collected: ac_lfnlen = the name's length (0: there is none, or
; its checksum does not belong to this entry) and ac_lfn = its first 39
; characters. A != 0 with carry set: read error.
; ---------------------------------------------------------------------------
ac_diropen
    lda #0
    sta ac_dsec
    sta ac_didx
    rts

ac_dirnext
    lda #0
    sta ac_lfnlen
ac_dirnext0
    lda ac_didx
    cmp #16
    bne ac_dirnext2
    lda #0
    sta ac_didx
    inc ac_dsec
    lda ac_dsec
    cmp ac_spc
    bne ac_dirnext2
    lda #0
    sta ac_dsec
    jsr ac_next
    bcc ac_dirnext2
    rts                     ; end of the chain (A = 0) or error
ac_dirnext2
    jsr ac_c2lba
    clc
    lda ac_lba
    adc ac_dsec
    sta ac_lba
    bcc ac_dirnext3
    inc ac_lba+1
    bne ac_dirnext3
    inc ac_lba+2
    bne ac_dirnext3
    inc ac_lba+3
ac_dirnext3
    jsr ac_rdbuf
    beq ac_dirnext4
    sec
    rts
ac_dirnext4
    lda ac_didx
    and #7
    asl
    asl
    asl
    asl
    asl
    tax
    ldy #0
    lda ac_didx
    and #8
    bne ac_dirnext6
ac_dirnext5
    lda SECBUF,x
    sta ac_dirent,y
    inx
    iny
    cpy #32
    bne ac_dirnext5
    beq ac_dirnext7
ac_dirnext6
    lda SECBUF+$100,x
    sta ac_dirent,y
    inx
    iny
    cpy #32
    bne ac_dirnext6
ac_dirnext7
    inc ac_didx
    lda ac_dirent
    bne ac_dirnext8
    sec                     ; first byte 0: no more entries
    rts
ac_dirnext8
    cmp #$E5
    bne ac_dirnext9
    jmp ac_dirnext
ac_dirnext9
    lda ac_dirent+11
    and #$3F
    cmp #$0F
    bne ac_dirnext9a
    jsr ac_lfnpart          ; a piece of the next entry's long name
    jmp ac_dirnext0
ac_dirnext9a
    and #$08                ; volume label
    beq ac_dirnext10
    jmp ac_dirnext
ac_dirnext10
    lda ac_lfnlen
    beq ac_dirnext12
    ; the long name belongs to this entry if it carries the checksum of
    ; the entry's 8.3 name
    lda #0
    ldx #0
ac_dirnext11
    lsr
    bcc ac_dirnext11a
    ora #$80
ac_dirnext11a
    clc
    adc ac_dirent,x
    inx
    cpx #11
    bne ac_dirnext11
    cmp ac_lfnsum
    beq ac_dirnext12
    lda #0
    sta ac_lfnlen
ac_dirnext12
    lda #0
    clc
    rts

; one long-name entry (in ac_dirent). They come last piece first; a piece
; holds 13 UTF-16 characters.
ac_lfnoff
    .byte 1,3,5,7,9,14,16,18,20,22,24,28,30
ac_lfnbase
    .byte 0,13,26
ac_lfnpart
    lda ac_dirent
    and #$40
    beq ac_lfnp4
    ; the last piece: checksum, and the length of the whole name
    lda ac_dirent+13
    sta ac_lfnsum
    ldx #0
ac_lfnp1
    ldy ac_lfnoff,x
    lda ac_dirent,y
    ora ac_dirent+1,y
    beq ac_lfnp2
    inx
    cpx #13
    bne ac_lfnp1
ac_lfnp2
    stx ac_k                ; characters in this piece
    lda ac_dirent
    and #$1F
    beq ac_lfnbad
    cmp #20
    bcs ac_lfnbad           ; (longer than 255 characters)
    tax
    lda ac_k
    clc
ac_lfnp3
    dex
    beq ac_lfnp3a
    adc #13
    bne ac_lfnp3
ac_lfnp3a
    sta ac_lfnlen
    jmp ac_lfnp5
ac_lfnbad
    lda #0
    sta ac_lfnlen
    rts
ac_lfnp4
    lda ac_dirent+13        ; the other pieces: the same checksum
    cmp ac_lfnsum
    bne ac_lfnbad
ac_lfnp5
    ; the first three pieces hold all we show
    lda ac_dirent
    and #$1F
    beq ac_lfnp9
    cmp #4
    bcs ac_lfnp9
    tax
    lda ac_lfnbase-1,x
    sta ac_k
    ldx #0
ac_lfnp6
    ldy ac_lfnoff,x
    lda ac_dirent+1,y
    bne ac_lfnp7
    lda ac_dirent,y
    jmp ac_lfnp8
ac_lfnp7
    lda #"?"                ; not Latin-1
ac_lfnp8
    ldy ac_k
    sta ac_lfn,y
    inc ac_k
    inx
    cpx #13
    bne ac_lfnp6
ac_lfnp9
    rts

ac_entclus                  ; ac_clus = the entry's first cluster
    lda ac_dirent+26
    sta ac_clus
    lda ac_dirent+27
    sta ac_clus+1
    lda ac_dirent+20
    sta ac_clus+2
    lda ac_dirent+21
    sta ac_clus+3
    rts

; ---------------------------------------------------------------------------
; ac_ramtest: write two patterns to $6000-$6FFF (cart RAM nothing else uses)
; and read them back. A = number of wrong bytes (saturating), Z set if none.
; Uses only FPTR and the registers: the RAM is what is being tested.
; ---------------------------------------------------------------------------
ac_ramtest
    ldx #0
    lda #$60
    sta FPTR+1
    lda #0
    sta FPTR
ac_rt1
    ldy #0
ac_rt2
    tya
    clc
    adc FPTR+1
    sta (FPTR),y
    iny
    bne ac_rt2
    inc FPTR+1
    lda FPTR+1
    cmp #$70
    bne ac_rt1
    lda #$60
    sta FPTR+1
ac_rt3
    ldy #0
ac_rt4
    tya
    clc
    adc FPTR+1
    cmp (FPTR),y
    beq ac_rt5
    inx
    bne ac_rt5
    dex
ac_rt5
    eor #$FF                ; second pattern: the complement
    sta (FPTR),y
    iny
    bne ac_rt4
    inc FPTR+1
    lda FPTR+1
    cmp #$70
    bne ac_rt3
    lda #$60
    sta FPTR+1
ac_rt6
    ldy #0
ac_rt7
    tya
    clc
    adc FPTR+1
    eor #$FF
    cmp (FPTR),y
    beq ac_rt8
    inx
    bne ac_rt8
    dex
ac_rt8
    iny
    bne ac_rt7
    inc FPTR+1
    lda FPTR+1
    cmp #$70
    bne ac_rt6
    stx $6FFF               ; (for a RAM dump from the host)
    txa
    rts

; ---------------------------------------------------------------------------
; ac_init: card, volume, the root directory's list
; ---------------------------------------------------------------------------
ac_magic
    .byte "ATARI7800"
ac_rootname
    .byte "SD CARD                         "

ac_init
    lda #0
    sta ac_nent
    lda SD_SIG
    cmp #$A7
    beq ac_init1
    lda #$0E
    rts
ac_init1
    jsr ac_ramtest
    beq ac_init1a
    lda #$40
    rts
ac_init1a
    lda #1
    sta SDREG
    jsr ac_wait
    beq ac_init2
    rts
ac_init2
    jsr ac_mount
    beq ac_init3
    rts
ac_init3
    ldx #3
ac_init4
    lda ac_rootclus,x
    sta ac_gclus,x
    lda #$FF
    sta ac_from,x
    dex
    bpl ac_init4
    lda #0
    sta ac_depth
    jsr ac_cwdroot
    jmp ac_scandir

ac_cwdroot
    ldy #31
ac_cwdroot1
    lda ac_rootname,y
    sta AC_CWD,y
    dey
    bpl ac_cwdroot1
    rts

; ---------------------------------------------------------------------------
; ac_isdir: A = 1 if list entry A is a directory, else 0
; ---------------------------------------------------------------------------
ac_isdir
    tax
    lda ac_ord,x
    tax
    lda ac_ef,x
    cmp #2
    lda #0
    bcs ac_isdir1
    lda #1
ac_isdir1
    rts

; ---------------------------------------------------------------------------
; ac_enter: go into the directory that is list entry A (".." goes up: its
; cluster is the parent's, 0 for the root). The list is rebuilt; ac_cur is
; the entry for the cursor -- after "..", the directory that was left.
; ---------------------------------------------------------------------------
ac_enter
    tax
    lda ac_ord,x
    sta ac_i
    tax
    lda ac_ef,x
    sta ac_j
    bne ac_enter3
    ; up: remember where we were, one name less on the path
    ldx #3
ac_enter1
    lda ac_gclus,x
    sta ac_from,x
    dex
    bpl ac_enter1
    lda ac_depth
    beq ac_enter6
    dec ac_depth
    bne ac_enter1a
    jsr ac_cwdroot
    jmp ac_enter6
ac_enter1a
    lda ac_depth
    cmp #9
    bcc ac_enter1c
    ldy #31                 ; deeper than the path we keep: no name
    lda #32
ac_enter1b
    sta AC_CWD,y
    dey
    bpl ac_enter1b
    bmi ac_enter6
ac_enter1c
    sec
    sbc #1
    asl
    asl
    asl
    asl
    asl
    tax
    ldy #0
ac_enter2
    lda AC_PATH,x
    sta AC_CWD,y
    inx
    iny
    cpy #32
    bne ac_enter2
    beq ac_enter6
ac_enter3
    ; down: the directory's title is the new name
    ldx #3
    lda #$FF
ac_enter3a
    sta ac_from,x
    dex
    bpl ac_enter3a
    lda ac_i
    jsr ac_tptr
    ldy #31
ac_enter4
    lda (FPTR),y
    sta AC_CWD,y
    dey
    bpl ac_enter4
    lda ac_depth
    cmp #8
    bcs ac_enter5a
    asl
    asl
    asl
    asl
    asl
    tax
    ldy #0
ac_enter5
    lda AC_CWD,y
    sta AC_PATH,x
    inx
    iny
    cpy #32
    bne ac_enter5
ac_enter5a
    inc ac_depth
ac_enter6
    ldx ac_i
    lda ac_ec0,x
    sta ac_gclus
    lda ac_ec1,x
    sta ac_gclus+1
    lda ac_ec2,x
    sta ac_gclus+2
    lda ac_ec3,x
    sta ac_gclus+3
    ora ac_gclus+2
    ora ac_gclus+1
    ora ac_gclus
    bne ac_enter8
    ldx #3                  ; cluster 0: the root directory
ac_enter7
    lda ac_rootclus,x
    sta ac_gclus,x
    dex
    bpl ac_enter7
ac_enter8
    jsr ac_scandir
    beq ac_enter9
    rts
ac_enter9
    ; the cursor: on the directory we came out of
    ldy #0
ac_enter10
    cpy ac_nent
    beq ac_enter12
    ldx ac_ord,y
    lda ac_ef,x
    cmp #1
    bne ac_enter11
    lda ac_ec0,x
    cmp ac_from
    bne ac_enter11
    lda ac_ec1,x
    cmp ac_from+1
    bne ac_enter11
    lda ac_ec2,x
    cmp ac_from+2
    bne ac_enter11
    lda ac_ec3,x
    cmp ac_from+3
    bne ac_enter11
    sty ac_cur
    lda #0
    rts
ac_enter11
    iny
    bne ac_enter10
ac_enter12
    lda #0
    rts

; ---------------------------------------------------------------------------
; ac_scandir: the list of directory ac_gclus (see the top of the file)
; ---------------------------------------------------------------------------
ac_scandir
    lda #0
    sta ac_nent
    sta ac_cur
    ldx #3
ac_scan1
    lda ac_gclus,x
    sta ac_clus,x
    dex
    bpl ac_scan1
    jsr ac_diropen
ac_scan2
    jsr ac_dirnext
    bcc ac_scan3
    rts                     ; the end (A = 0), or a read error
ac_scan3
    lda ac_dirent
    ldx ac_lfnlen
    beq ac_scan3a
    lda ac_lfn
ac_scan3a
    cmp #"."
    bne ac_scan4
    ; names that begin with a dot: only ".." is kept
    lda ac_lfnlen
    bne ac_scan2
    lda ac_dirent+1
    cmp #"."
    bne ac_scan2
    lda ac_dirent+2
    cmp #" "
    bne ac_scan2
    lda #0
    beq ac_scan6
ac_scan4
    lda ac_dirent+11
    and #$06                ; hidden, system (after the dot names: macOS
    bne ac_scan2            ; writes ".." as a hidden directory)
    lda ac_dirent+11
    and #$10
    beq ac_scan5
    lda #1
    bne ac_scan6
ac_scan5
    lda ac_dirent+8
    cmp #"A"
    bne ac_scan2
    lda ac_dirent+9
    cmp #"7"
    bne ac_scan2
    lda ac_dirent+10
    cmp #"8"
    bne ac_scan2
    lda #2
ac_scan6
    sta ac_kcls
    ldx ac_nent
    cpx #AC_MAXENT
    bcc ac_scan7
    lda #0                  ; the list is full
    rts
ac_scan7
    sta ac_ef,x
    lda ac_dirent+26
    sta ac_ec0,x
    lda ac_dirent+27
    sta ac_ec1,x
    lda ac_dirent+20
    sta ac_ec2,x
    lda ac_dirent+21
    sta ac_ec3,x
    lda ac_dirent+28
    sta ac_es0,x
    lda ac_dirent+29
    sta ac_es1,x
    lda ac_dirent+30
    sta ac_es2,x
    lda ac_dirent+31
    sta ac_es3,x

    ; ---- the title, in ac_key ----
    ldy #31
    lda #32
ac_scan8
    sta ac_key,y
    dey
    bpl ac_scan8
    lda ac_kcls
    bne ac_scan9
    lda #"."
    sta ac_key
    sta ac_key+1
    jmp ac_scan20
ac_scan9
    lda ac_lfnlen
    beq ac_scan13
    ; the long name; a game's loses its ".a78"
    sta ac_n
    lda ac_kcls
    cmp #2
    bne ac_scan10
    lda ac_n
    cmp #5
    bcc ac_scan10
    sbc #4
    sta ac_n
ac_scan10
    lda ac_n
    cmp #33
    bcc ac_scan11
    lda #32
    sta ac_n
ac_scan11
    ldy #0
ac_scan12
    lda ac_lfn,y
    jsr ac_clean
    sta ac_key,y
    iny
    cpy ac_n
    bne ac_scan12
    jmp ac_scan18
ac_scan13
    ; the 8.3 name (a directory's with its extension, if it has one)
    ldy #0
ac_scan14
    lda ac_dirent,y
    cmp #32
    beq ac_scan15
    jsr ac_clean
    sta ac_key,y
    iny
    cpy #8
    bne ac_scan14
ac_scan15
    lda ac_kcls
    cmp #1
    bne ac_scan18
    lda ac_dirent+8
    cmp #32
    beq ac_scan18
    lda #"."
    sta ac_key,y
    iny
    ldx #8
ac_scan16
    lda ac_dirent,x
    cmp #32
    beq ac_scan18
    jsr ac_clean
    sta ac_key,y
    iny
    inx
    cpx #11
    bne ac_scan16
ac_scan18
    ; a directory is shown with a slash behind its name
    lda ac_kcls
    cmp #1
    bne ac_scan20
    cpy #32
    bcc ac_scan19
    ldy #31
ac_scan19
    lda #"/"
    sta ac_key,y
ac_scan20
    lda ac_nent
    jsr ac_tptr
    ldy #31
ac_scan21
    lda ac_key,y
    sta (FPTR),y
    jsr ac_fold             ; ac_key becomes the sort key
    sta ac_key,y
    dey
    bpl ac_scan21

    ; ---- where does it go? (binary search; equal names keep their order) ----
    lda #0
    sta ac_lo
    lda ac_nent
    sta ac_hi
ac_scan22
    lda ac_lo
    cmp ac_hi
    bcs ac_scan24
    clc
    adc ac_hi
    ror
    sta ac_mid
    tax
    lda ac_ord,x
    jsr ac_cmp
    bcs ac_scan23
    lda ac_mid
    sta ac_hi
    jmp ac_scan22
ac_scan23
    ldx ac_mid
    inx
    stx ac_lo
    jmp ac_scan22
ac_scan24
    ldx ac_nent
ac_scan25
    cpx ac_lo
    beq ac_scan26
    lda ac_ord-1,x
    sta ac_ord,x
    dex
    jmp ac_scan25
ac_scan26
    lda ac_nent
    sta ac_ord,x
    inc ac_nent
    jmp ac_scan2

; carry clear if the new entry (ac_kcls, ac_key) sorts before entry A
ac_cmp
    tax
    lda ac_kcls
    cmp ac_ef,x
    bne ac_cmp3             ; another class: the carry says which way
    txa
    jsr ac_tptr
    ldy #0
ac_cmp1
    lda (FPTR),y
    jsr ac_fold
    sta ac_c
    lda ac_key,y
    cmp ac_c
    bne ac_cmp3
    iny
    cpy #32
    bne ac_cmp1
    sec
ac_cmp3
    rts

ac_fold                     ; lower case -> upper case
    cmp #$61
    bcc ac_fold1
    cmp #$7B
    bcs ac_fold1
    and #$DF
ac_fold1
    rts

ac_clean                    ; a printable character for the menu font
    cmp #32
    bcc ac_clean1
    cmp #123
    bcc ac_clean2
ac_clean1
    lda #32
ac_clean2
    rts

ac_cproot
    ldx #3
ac_cproot1
    lda ac_rootclus,x
    sta ac_clus,x
    dex
    bpl ac_cproot1
    rts

ac_tptr                     ; FPTR = AC_TITLES + 32 * A
    sta FPTR
    lda #0
    sta FPTR+1
    ldx #5
ac_tptr1
    asl FPTR
    rol FPTR+1
    dex
    bne ac_tptr1
    clc
    lda FPTR+1
    adc #>AC_TITLES
    sta FPTR+1
    rts

; ac_line: title A -> line buffer X (0-15), for the display
ac_line
    pha
    txa
    sta ac_tmp+2
    lda #0
    sta ac_tmp+3
    ldx #5
ac_line1
    asl ac_tmp+2
    rol ac_tmp+3
    dex
    bne ac_line1
    clc
    lda ac_tmp+3
    adc #>AC_LINES
    sta ac_tmp+3
    pla
    tax
    lda ac_ord,x
    jsr ac_tptr
    ldy #31
ac_line2
    lda (FPTR),y
    pha
    dey
    bpl ac_line2
    lda ac_tmp+2
    sta FPTR
    lda ac_tmp+3
    sta FPTR+1
    ldy #0
ac_line3
    pla
    sta (FPTR),y
    iny
    cpy #32
    bne ac_line3
    rts

; ---------------------------------------------------------------------------
; ac_hdr: read the first block of game X; A = 0 if it is an .a78 header
; ---------------------------------------------------------------------------
ac_hdr
    lda ac_ec0,x
    sta ac_clus
    lda ac_ec1,x
    sta ac_clus+1
    lda ac_ec2,x
    sta ac_clus+2
    lda ac_ec3,x
    sta ac_clus+3
    ; a file shorter than header + 1 byte, or without a cluster, is not a game
    lda ac_es1,x
    ora ac_es2,x
    ora ac_es3,x
    beq ac_hdrbad
    lda ac_clus
    ora ac_clus+1
    ora ac_clus+2
    ora ac_clus+3
    beq ac_hdrbad
    jsr ac_c2lba
    jsr ac_rdbuf
    beq ac_hdr1
    rts
ac_hdr1
    ldx #8
ac_hdr2
    lda SECBUF+1,x
    cmp ac_magic,x
    bne ac_hdrbad
    dex
    bpl ac_hdr2
    lda #0
    rts
ac_hdrbad
    lda #$23
    rts

; ---------------------------------------------------------------------------
; High Score Cart (see the top of the file)
; ---------------------------------------------------------------------------
ac_hsname
    .byte "ASTROCART"
ac_hsrom
    .byte "HSC     A78"
ac_hssav
    .byte "HSC     SAV"

; look for the two files: ac_hsok = 1 and their clusters, or ac_hsok = $FF
ac_hsfind
    lda #$FF
    sta ac_hsok
    lda ac_spc
    cmp #4
    bcs ac_hsf0
    rts                     ; clusters under 2K: HSC.SAV might be in pieces
ac_hsf0
    jsr ac_cproot
    jsr ac_diropen
ac_hsf1
    jsr ac_dirnext
    bcc ac_hsf2
    rts
ac_hsf2
    lda ac_dirent+11
    and #$10
    beq ac_hsf1
    lda ac_lfnlen
    cmp #9
    bne ac_hsf1
    ldx #8
ac_hsf3
    lda ac_lfn,x
    jsr ac_fold
    cmp ac_hsname,x
    bne ac_hsf1
    dex
    bpl ac_hsf3
    jsr ac_entclus
    jsr ac_diropen
    lda #0
    sta ac_i
ac_hsf4
    jsr ac_dirnext
    bcc ac_hsf5
    lda ac_i                ; the end: both there?
    cmp #3
    bne ac_hsf4a
    lda #1
    sta ac_hsok
ac_hsf4a
    rts
ac_hsf5
    lda ac_dirent+11
    and #$18
    bne ac_hsf4
    ldx #10
ac_hsf6
    lda ac_dirent,x
    cmp ac_hsrom,x
    bne ac_hsf8
    dex
    bpl ac_hsf6
    lda ac_dirent+30
    ora ac_dirent+31
    bne ac_hsf7
    lda ac_dirent+29        ; 128 + 4096 bytes at least
    cmp #$10
    bcc ac_hsf4
ac_hsf7
    lda ac_dirent+26
    sta ac_hrc
    lda ac_dirent+27
    sta ac_hrc+1
    lda ac_dirent+20
    sta ac_hrc+2
    lda ac_dirent+21
    sta ac_hrc+3
    lda ac_i
    ora #1
    sta ac_i
    jmp ac_hsf4
ac_hsf8
    ldx #10
ac_hsf9
    lda ac_dirent,x
    cmp ac_hssav,x
    beq ac_hsf9a
    jmp ac_hsf4
ac_hsf9a
    dex
    bpl ac_hsf9
    lda ac_dirent+30
    ora ac_dirent+31
    bne ac_hsf10
    lda ac_dirent+29        ; 2048 bytes at least
    cmp #$08
    bcs ac_hsf10
    jmp ac_hsf4
ac_hsf10
    lda ac_dirent+26
    sta ac_hsv
    lda ac_dirent+27
    sta ac_hsv+1
    lda ac_dirent+20
    sta ac_hsv+2
    lda ac_dirent+21
    sta ac_hsv+3
    lda ac_i
    ora #2
    sta ac_i
    jmp ac_hsf4

; the game is in PSRAM: add the HSC if it wants one and the card has it.
; A = 0, or an error from the card.
ac_hsload
    lda ac_hsflag
    lsr
    bcc ac_hsl9
    lda ac_nb
    cmp #255
    bcs ac_hsl9             ; (the HSC takes the last 16K of PSRAM)
    lda ac_hsok
    bne ac_hsl1
    jsr ac_hsfind
ac_hsl1
    lda ac_hsok
    cmp #1
    bne ac_hsl9
    ; the ROM: 128 + 4096 bytes = 9 blocks, without the header, to $3FC000
    ldx #3
ac_hsl2
    lda ac_hrc,x
    sta ac_clus,x
    dex
    bpl ac_hsl2
    lda #$00
    sta SD_PTR
    lda #$C0
    sta SD_PTR+1
    lda #$3F
    sta SD_PTR+2
    lda #9
    sta ac_rem
    lda #0
    sta ac_rem+1
    lda #4
    sta ac_first
    jsr ac_ldrun
    bne ac_hsl10
    ; the RAM: 4 blocks to $3FD000
    jsr ac_hsl20
    lda #$00
    sta SD_PTR
    lda #$D0
    sta SD_PTR+1
    lda #$3F
    sta SD_PTR+2
    lda #4
    sta ac_rem
    lda #0
    sta ac_rem+1
    lda #3
    sta ac_first
    jsr ac_ldrun
    bne ac_hsl10
    ; and where to save it
    jsr ac_hsl20
    jsr ac_c2lba
    jsr ac_setlba
    lda #7
    sta SDREG
    jsr ac_wait
ac_hsl9
    lda #0
ac_hsl10
    rts
ac_hsl20
    ldx #3
ac_hsl21
    lda ac_hsv,x
    sta ac_clus,x
    dex
    bpl ac_hsl21
    rts

; ---------------------------------------------------------------------------
; ac_info: what the header of list entry A says (see the top of the file)
; ---------------------------------------------------------------------------
ac_infoclr
    ldy #63
    lda #32
ac_infoclr1
    sta AC_INFO,y
    dey
    bpl ac_infoclr1
    rts

ac_istr
    .byte "NOT AN .A78 FILE",0
ac_istr_ns = . - ac_istr
    .byte " NOT SUPPORTED",0
ac_istr_sg = . - ac_istr
    .byte " SUPERGAME",0
ac_istr_ab = . - ac_istr
    .byte " ABSOLUTE",0
ac_istr_ac = . - ac_istr
    .byte " ACTIVISION",0
ac_istr_ram = . - ac_istr
    .byte "+RAM",0
ac_istr_pk = . - ac_istr
    .byte " POKEY",0
ac_istr_pk2 = . - ac_istr
    .byte " 2 POKEYS",0
ac_istr_hsc = . - ac_istr
    .byte " HSC",0
ac_istr_math = . - ac_istr
    .byte " MATH",0
ac_istr_ntsc = . - ac_istr
    .byte " NTSC",0
ac_istr_pal = . - ac_istr
    .byte " PAL",0

ac_iputs                    ; string at ac_istr+Y -> line 2 at X
    lda ac_istr,y
    beq ac_iputs1
    cpx #32
    bcs ac_iputs1
    sta AC_INFO+32,x
    inx
    iny
    bne ac_iputs
ac_iputs1
    rts

ac_idig                     ; one decimal digit of ac_tmp (16 bit): how often ac_tmp+2/+3 fits
    ldy #"0"
ac_idig1
    lda ac_tmp
    cmp ac_tmp+2
    lda ac_tmp+1
    sbc ac_tmp+3
    bcc ac_idig2
    sec
    lda ac_tmp
    sbc ac_tmp+2
    sta ac_tmp
    lda ac_tmp+1
    sbc ac_tmp+3
    sta ac_tmp+1
    iny
    bne ac_idig1
ac_idig2
    cpy #"0"
    bne ac_idig3
    lda ac_k                ; no leading zeros
    beq ac_idig4
ac_idig3
    tya
    sta AC_INFO+32,x
    inx
    inc ac_k
ac_idig4
    rts

ac_info
    pha
    jsr ac_infoclr
    pla
    tax
    lda ac_ord,x
    sta ac_sel
    tax
    lda ac_ef,x
    cmp #2
    beq ac_info1
    rts
ac_info1
    jsr ac_hdr
    beq ac_info3
    cmp #$23
    bne ac_info2a           ; (a read error: say nothing)
    ldy #0
    ldx #0
ac_info2
    lda ac_istr,y
    beq ac_info2a
    sta AC_INFO,x
    inx
    iny
    bne ac_info2
ac_info2a
    rts
ac_info3
    ldy #31
ac_info4
    lda SECBUF+17,y
    jsr ac_clean
    sta AC_INFO,y
    dey
    bpl ac_info4
    ; ROM size = file size - 128, in K (rounded up)
    ldx ac_sel
    sec
    lda ac_es0,x
    sbc #128
    sta ac_fsize
    lda ac_es1,x
    sbc #0
    sta ac_fsize+1
    lda ac_es2,x
    sbc #0
    sta ac_fsize+2
    clc
    lda ac_fsize
    adc #$FF
    lda ac_fsize+1
    adc #$03
    sta ac_tmp
    lda ac_fsize+2
    adc #0
    sta ac_tmp+1
    lsr ac_tmp+1
    ror ac_tmp
    lsr ac_tmp+1
    ror ac_tmp
    ldx #0
    stx ac_k
    lda #<1000
    sta ac_tmp+2
    lda #>1000
    sta ac_tmp+3
    jsr ac_idig
    lda #100
    sta ac_tmp+2
    lda #0
    sta ac_tmp+3
    jsr ac_idig
    lda #10
    sta ac_tmp+2
    jsr ac_idig
    lda ac_tmp
    ora #"0"
    sta AC_INFO+32,x
    inx
    lda #"K"
    sta AC_INFO+32,x
    inx
    stx ac_n
    jsr ac_mapper           ; (uses ac_tmp)
    ldx ac_n
    cmp #0
    beq ac_info5
    ldy #ac_istr_ns
    jsr ac_iputs
    jmp ac_info9
ac_info5
    lda ac_cfg+2
    lsr
    bcc ac_info6
    ldy #ac_istr_sg
    jsr ac_iputs
ac_info6
    lda ac_cfg+2
    and #$02
    beq ac_info7
    ldy #ac_istr_ab
    jsr ac_iputs
ac_info7
    lda ac_cfg+2
    and #$08
    beq ac_info7a
    ldy #ac_istr_ac
    jsr ac_iputs
ac_info7a
    lda ac_cfg
    cmp #2
    bne ac_info8
    ldy #ac_istr_ram
    jsr ac_iputs
ac_info8
    lda ac_cfg+7
    beq ac_info9
    ldy #ac_istr_pk
    cmp #5
    bne ac_info8a
    ldy #ac_istr_pk2
ac_info8a
    jsr ac_iputs
ac_info9
    lda SECBUF+58
    lsr
    bcc ac_info9a
    ldy #ac_istr_hsc
    jsr ac_iputs
ac_info9a
    lda ac_cfg+2
    and #$20
    beq ac_info9b
    ldy #ac_istr_math
    jsr ac_iputs
ac_info9b
    ldy #ac_istr_ntsc
    lda SECBUF+57
    lsr
    bcc ac_info10
    ldy #ac_istr_pal
ac_info10
    jmp ac_iputs

; ---------------------------------------------------------------------------
; ac_load: load game A into PSRAM and set the mapper registers
; ---------------------------------------------------------------------------
ac_load
    tax
    lda ac_ord,x
    sta ac_sel
    tax
    jsr ac_hdr
    beq ac_load1
    rts
ac_load1
    ; ROM size = file size - 128
    ldx ac_sel
    sec
    lda ac_es0,x
    sbc #128
    sta ac_fsize
    lda ac_es1,x
    sbc #0
    sta ac_fsize+1
    lda ac_es2,x
    sbc #0
    sta ac_fsize+2
    lda ac_es3,x
    sbc #0
    beq ac_load1a
    lda #$20                ; 16 MB?
    rts
ac_load1a
    lda SECBUF+58
    sta ac_hsflag
    jsr ac_mapper
    beq ac_load2
    rts
ac_load2
    lda #6                  ; clear the checksum and the error counts
    sta SDREG
    jsr ac_wait
    lda ac_off
    sta SD_PTR
    lda ac_off+1
    sta SD_PTR+1
    lda ac_off+2
    sta SD_PTR+2
    jsr ac_ldfile
    beq ac_load3
    rts
ac_load3
    ; an 8K (or smaller) image fills the top half of its bank: mirror it below
    lda ac_fsize+2
    bne ac_load5
    lda ac_fsize+1
    cmp #$20
    bcc ac_load4
    bne ac_load5
    lda ac_fsize
    bne ac_load5
ac_load4
    sec
    lda ac_off
    sbc ac_fsize
    sta SD_PTR
    lda ac_off+1
    sbc ac_fsize+1
    sta SD_PTR+1
    lda #0
    sta SD_PTR+2
    jsr ac_ldfile
    beq ac_load5
    rts
ac_load5
    ; Activision: there are two kinds of dump. "OM" ends with the cart's last
    ; 8K -- its final block (still the cart's block register - 1) has $x7 at
    ; $FFF9, the signature the console checks; "AM" has the halves of every
    ; bank the other way round (mapper bit 4).
    lda ac_cfg+2
    and #$08
    beq ac_load5b
    sec
    lda SDREG+8
    sbc #1
    sta ac_lba
    lda SDREG+9
    sbc #0
    sta ac_lba+1
    lda SDREG+10
    sbc #0
    sta ac_lba+2
    lda SDREG+11
    sbc #0
    sta ac_lba+3
    jsr ac_rdbuf
    beq ac_load5a
    rts
ac_load5a
    lda SECBUF+$79
    and #$0F
    cmp #7
    bne ac_load5b
    lda ac_cfg+2
    and #$EF
    sta ac_cfg+2
ac_load5b
    jsr ac_hsload
    beq ac_load5c
    rts
ac_load5c
    ldx #7
ac_load6
    lda ac_cfg,x
    sta SD_CFG,x
    dex
    bpl ac_load6
    lda #0
    rts
ac_unsup
    lda #$20
    rts

; "ACM" in header bytes 59-61 (SECBUF): the math unit, mapper bit 5. A = 0.
ac_mathchk
    lda SECBUF+59
    cmp #"A"
    bne ac_mathchk1
    lda SECBUF+60
    cmp #"C"
    bne ac_mathchk1
    lda SECBUF+61
    cmp #"M"
    bne ac_mathchk1
    lda ac_cfg+2
    ora #$20
    sta ac_cfg+2
ac_mathchk1
    lda #0
    rts

; load the file of game ac_sel at the PSRAM address in SD_PTR
ac_ldfile
    ldx ac_sel
    lda ac_ec0,x
    sta ac_clus
    lda ac_ec1,x
    sta ac_clus+1
    lda ac_ec2,x
    sta ac_clus+2
    lda ac_ec3,x
    sta ac_clus+3
    ; blocks = (ROM size + 128 + 511) / 512
    clc
    lda ac_fsize
    adc #<639
    lda ac_fsize+1
    adc #>639
    sta ac_rem
    lda ac_fsize+2
    adc #0
    lsr
    sta ac_rem+1
    ror ac_rem
    lda #4
    sta ac_first
ac_ldrun                    ; (entry with ac_clus, ac_rem and ac_first set, SD_PTR written)
ac_ldfile1
    jsr ac_c2lba
    jsr ac_setlba
    lda ac_spc
    sta ac_secleft
ac_ldfile2
    lda ac_first            ; 4: skip the header; then 3
    sta SDREG
    lda #3
    sta ac_first
    jsr ac_wait
    beq ac_ldfile3
    rts
ac_ldfile3
    lda ac_rem
    bne ac_ldfile4
    dec ac_rem+1
ac_ldfile4
    dec ac_rem
    lda ac_rem
    ora ac_rem+1
    beq ac_ldfile6
    dec ac_secleft
    bne ac_ldfile2
    jsr ac_next
    bcc ac_ldfile1
    cmp #0
    bne ac_ldfile5
    lda #$21                ; the chain ended before the file did
ac_ldfile5
    rts
ac_ldfile6
    lda SDREG
    and #$10
    beq ac_ldfile7
    lda #$22
    rts
ac_ldfile7
    lda #0
    rts

; ---------------------------------------------------------------------------
; ac_mapper: .a78 header in SECBUF + ac_fsize -> ac_cfg, ac_nb, ac_off
; (the same rules as tools/devcart.py)
; ---------------------------------------------------------------------------
ac_mapbad1
    lda #$20
    rts
ac_mapper
    jsr ac_mapper0
    bne ac_mapperx
    lda ac_tl
    bpl ac_mapperok
    lda ac_cfg
    cmp #2
    bne ac_mapperok         ; (48K: ROM is there instead)
    lda ac_cfg+2
    ora #$04                ; mirror RAM
    sta ac_cfg+2
ac_mapperok
    jmp ac_mathchk          ; (ends with A = 0)
ac_mapperx
    rts
ac_mapper0
    lda SECBUF+54
    sta ac_tl
    lda SECBUF+53
    sta ac_th
    lda SECBUF
    cmp #4
    bcc ac_map3
    ; v4 header: mapper and mapper options
    lda SECBUF+64
    beq ac_map1
    cmp #3
    beq ac_map0             ; Absolute
    cmp #2
    beq ac_map0a            ; Activision
    cmp #1
    bne ac_mapbad1
    lda ac_tl
    ora #$02
    sta ac_tl
    bne ac_map1
ac_map0a
    lda #$01
    bne ac_map0b
ac_map0
    lda #$02
ac_map0b
    ora ac_th
    sta ac_th
ac_map1
    lda SECBUF+65
    bmi ac_mapbad1           ; bankset ROM
    and #$07
    beq ac_map3
    tax
    lda ac_optbits,x
    beq ac_mapbad1
    ora ac_tl
    sta ac_tl
ac_map3
    lda ac_th
    and #$70                ; souper, banksets, halt RAM
    bne ac_mapbad1
    lda ac_tl
    and #$20                ; banked RAM
    bne ac_mapbad1
    lda ac_tl
    bpl ac_map3a
    ora #$04                ; mirror RAM is RAM at $4000 (without A8: flagged at the end)
    sta ac_tl
ac_map3a

    ; POKEY
    ldx #0
    lda ac_tl
    and #$01
    beq ac_map4
    ldx #1                  ; $4000
ac_map4
    lda ac_tl
    and #$40
    beq ac_map5
    ldx #2                  ; $0450
ac_map5
    lda ac_th
    and #$04
    beq ac_map5a
    cpx #2
    beq ac_map5b
    ldx #4                  ; $0440
    bne ac_map5a
ac_map5b
    ldx #5                  ; two: $0450 and $0440
ac_map5a
    lda ac_th
    bpl ac_map6
    ldx #3                  ; $0800
ac_map6
    lda SECBUF
    cmp #4
    bcc ac_map8
    lda SECBUF+67
    and #$07
    beq ac_map8
    tay
    lda ac_audsel,y
    beq ac_mapbad2
    tax
ac_map8
    stx ac_cfg+7

    jmp ac_map9
ac_mapbad2
    lda #$20
    rts
ac_map9
    ; banks = (size + $3FFF) / $4000; image start = banks * $4000 - size
    clc
    lda ac_fsize
    adc #$FF
    lda ac_fsize+1
    adc #$3F
    sta ac_tmp
    lda ac_fsize+2
    adc #0
    sta ac_tmp+1
    asl ac_tmp
    rol ac_tmp+1
    asl ac_tmp
    rol ac_tmp+1
    lda ac_tmp+1
    sta ac_nb
    beq ac_mapbad2
    lda ac_fsize+2
    cmp #$40
    bcs ac_mapbad2           ; 4 MB or more: 255 banks is all the cart's registers hold
                             ; (and it keeps the shift above honest)
    lda ac_nb
    lsr
    sta ac_tmp+1            ; banks * $4000, top two bytes
    lda #0
    ror
    lsr ac_tmp+1
    ror
    sta ac_tmp
    sec
    lda #0
    sbc ac_fsize
    sta ac_off
    lda ac_tmp
    sbc ac_fsize+1
    sta ac_off+1
    lda ac_tmp+1
    sbc ac_fsize+2
    sta ac_off+2

    lda #0
    sta ac_cfg+1            ; bank at $4000
    sta ac_cfg+2            ; SuperGame
    sta ac_cfg+3            ; mask
    sta ac_cfg+4            ; add
    sta ac_cfg+5            ; bank at $8000
    ldx ac_nb
    dex
    stx ac_cfg+6            ; bank at $C000: the last one
    lda ac_th
    lsr
    bcc ac_mapnact
    ; ---- Activision: 128K; bank 6 at $4000, the selected bank at $A000-$DFFF,
    ; bank 7 around it. Mapper bit 4 (halves) is settled once the file is in:
    ; see ac_load ----
    lda ac_nb
    cmp #8
    beq ac_mapact1
    lda #$20
    rts
ac_mapact1
    lda #1
    sta ac_cfg
    lda #6
    sta ac_cfg+1
    lda #$18
    sta ac_cfg+2
    lda #0
    rts
ac_mapnact
    lda ac_th
    and #$02
    beq ac_mapnabs
    ; ---- Absolute: 64K; banks 0 / 1 switched at $4000, 2 and 3 fixed ----
    lda ac_nb
    cmp #4
    bne ac_mapbad
    lda #1
    sta ac_cfg              ; ROM at $4000, bank 0
    lda #2
    sta ac_cfg+2            ; mapper: Absolute
    sta ac_cfg+5            ; bank 2 at $8000
    lda #0
    rts
ac_mapnabs
    lda ac_tl
    and #$02
    bne ac_mapsg

    ; ---- linear ----
    lda ac_nb
    cmp #4
    bcs ac_mapbad
    cmp #3
    bne ac_map10
    lda #1
    sta ac_cfg              ; 48K: ROM at $4000, banks 0 1 2
    sta ac_cfg+5
    lda #0
    rts
ac_map10
    lda ac_tl
    and #$04
    lsr                     ; 16K RAM at $4000 (2), or nothing (0)
    sta ac_cfg
    lda #0
    rts
ac_mapbad
    lda #$20
    rts

    ; ---- SuperGame ----
ac_mapsg
    lda ac_nb
    cmp #2
    bcc ac_mapbad
    lda #1
    sta ac_cfg+2
    lda ac_tl
    and #$08
    bne ac_mapsg1
    lda ac_nb
    lsr
    bcc ac_mapsg2
ac_mapsg1
    ; ROM at $4000 (EXROM): bank 0 there, the switched banks start at 1
    lda #1
    sta ac_cfg
    sta ac_cfg+4
    ldx ac_nb
    dex
    dex
    stx ac_cfg+3
    lda #0
    rts
ac_mapsg2
    ldx ac_nb
    dex
    stx ac_cfg+3
    lda ac_tl
    and #$04
    beq ac_mapsg3
    lda #2                  ; 16K RAM at $4000
    sta ac_cfg
    lda #0
    rts
ac_mapsg3
    lda #1                  ; the second-last bank at $4000
    sta ac_cfg
    dex
    stx ac_cfg+1
    lda #0
    rts

ac_optbits                  ; v4 mapper option -> cart type bit (0 = not supported)
    .byte $00,$04,$80,$00,$08,$10,$00,$00
ac_audsel                   ; v4 POKEY mode -> our POKEY select (0 = not supported)
    .byte $00,$04,$02,$05,$03,$01,$00,$00

; ---------------------------------------------------------------------------
; ac_launch: hand over to the loaded game. The slots (this code included)
; are refilled by the cart, so the last steps run from the console's RAM.
; ---------------------------------------------------------------------------
AC_STUB = $1800
ac_launch
    sei
    lda #$7F                ; MARIA: DMA off (no display, no display-list interrupts)
    sta $3C
    ldx #ac_stubend-ac_stub-1
ac_launch1
    lda ac_stub,x
    sta AC_STUB,x
    dex
    bpl ac_launch1
    jmp AC_STUB
ac_stub
    lda #5
    sta SDREG               ; launch: the cart goes quiet, refills its slots (~1 ms)
    ldx #40
    ldy #0
ac_stub1
    dey
    bne ac_stub1            ; (relative branches only: this runs at AC_STUB)
    dex
    bne ac_stub1            ; ~ 30 ms
    jmp ($FFFC)
ac_stubend
