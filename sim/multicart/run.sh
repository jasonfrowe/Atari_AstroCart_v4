#!/bin/bash
# Multicart regression: every test cart, loaded from FAT32 images of different
# shapes, through the real 6502 code. The carts are in tests/carts; Gamma Force is
# added if it has been built beside this repository (skipped if absent).
set -u
cd "$(dirname "$0")"
C=../../tests/carts
GF=$HOME/Software/Atari7800/AtariGammaForce/build/gammaforce.a78
printf 'this is not a cartridge, although it is called .a78 %.0s' {1..40} > ._junk.a78
cp ._junk.a78 "not a game.a78"         # listed (the name is all the menu looks at); refused when loaded
FILES=("$C/ARTI_Final_digital_edition_jan24_1.1.a78" ./._junk.a78 "$C/astrowing.a78" "$C/Choplifter_NTSC.a78" "./not a game.a78"
       "$C/Commando (NTSC) (Atari) (1989) (CD1A98C5).a78" "$C/Food Fight (NTSC) (Atari) (1987) (E64A5CDE).a78")
[ -f "$GF" ] && FILES+=("$GF")
FILES+=("$C/Impossible Mission (NTSC) (Atari) (1987) (3B1F2F47).a78" "$C/Jinks (NTSC) (Atari) (1989) (0818D8CD).a78"
        "$C/Tiger-Heli 7800 (World) (NTSC) (Aftermarket).a78")
NG=$(( ${#FILES[@]} - 1 ))          # the dot file is not listed
bad=0
run() {     # name, HC, mkfat32 options...
    local name=$1 hc=$2; shift 2
    python3 ../../tools/mkfat32.py $name.img "$@" "${FILES[@]}" > /dev/null || exit 2
    local games=${ONLY:-$(seq 0 $((NG - 1)))}
    for g in -1 $games; do
        out=$(./obj_dir/Vdevcart_top $name.img $hc $g "${FILES[@]}" 2>&1)   # (ROOTDIR / SUB from the caller)
        if echo "$out" | tail -1 | grep -q PASSED; then
            echo "  $name game $g: $(echo "$out" | grep -E 'ac_load|LIST' | head -1 | cut -c1-70) -- $(echo "$out" | tail -1)"
        else
            bad=$((bad + 1)); echo "  $name game $g FAILED"; echo "$out" | tail -8
        fi
    done
}
echo "SDHC card, MBR, 8 sectors per cluster";              run mbr8  1 --spc 8
echo "SDHC card, MBR, 64 sectors per cluster";             ONLY="2 5" run mbr64 1 --spc 64 --size-mb 256
echo "SDSC (byte addressed) card, no partition table, fragmented files, 1 sector per cluster"
                                                           ONLY="0 5 8" run frag1 0 --spc 1 --part 0 --fragment
echo "games in the root directory, fragmented, 2 sectors per cluster"
                                                           ROOTDIR=1 ONLY="3 7" run root2 1 --spc 2 --root --fragment
echo "a sub-directory in /ROMS (in, list, back out), 4 sectors per cluster"
                                                           SUB="More Games (a sub-directory):3,6" ONLY="1 6" run sub4 1 --spc 4 --sub "More Games (a sub-directory):3,6"
echo "a sub-directory of the root directory, 8 sectors per cluster"
                                                           ROOTDIR=1 SUB="Sub:0,4" ONLY="2" run rsub8 1 --spc 8 --root --sub "Sub:0,4"
echo "300 files in one directory (the first 255 are listed, sorted), 1 sector per cluster"
rm -rf big; mkdir big
python3 - <<'PY'
import random
random.seed(7)
w = "Alpha beta GAMMA delta Epsilon zeta Eta theta IOTA kappa Lambda mu Nu xi Omicron pi Rho sigma TAU upsilon".split()
seen = set()
while len(seen) < 300:
    n = " ".join(random.choice(w) for _ in range(random.randint(1, 7)))
    if n.lower() in seen: continue
    seen.add(n.lower())
    open(f"big/{n}.a78", "wb").write(b"not a game " * 30)
PY
BIG=(big/*.a78)
python3 ../../tools/mkfat32.py big1.img --spc 1 "${BIG[@]}" > /dev/null || exit 2
out=$(./obj_dir/Vdevcart_top big1.img 1 -1 "${BIG[@]}" 2>&1)
if echo "$out" | tail -1 | grep -q PASSED; then echo "  big1: $(echo "$out" | grep '^/ROMS' | head -1) -- $(echo "$out" | tail -1)"
else bad=$((bad + 1)); echo "  big1 FAILED"; echo "$out" | grep -v '^  ' | tail -8; fi
rm -rf big
# Absolute, mirror RAM, two POKEYs ($0450 + $0440): files from Trebor's 7800 ROM PROPack, if it is there
P="${PROPACK:-$HOME/Downloads/Trebors 7800 ROM PROPack v8_17}"
if [ -d "$P" ]; then
    echo "Absolute (F-18 Hornet), mirror RAM (Rescue on Fractalus, Fader), two POKEYs (Byzex), Activision (Rampage AM, Double Dragon AM and OM); 8 sectors per cluster"
    SAVE=("${FILES[@]}"); SNG=$NG
    FILES=("$P/Retail_v7_0/NTSC/F-18 Hornet (NTSC) (Absolute) (1988) (63D1C7C1).a78"
           "$P/UPHHD_20260101/Prototypes/Rescue On Fractalus (Prototype) (xx-xx-84) (9A74FBF2).a78"
           "$P/UPHHD_20260101/Demos/F/Fader (20220829) (2EDE4E4E).a78"
           "$P/UPHHD_20260101/Demos/B/Byzex (Dual POKEY 440 450 Demo) (20210120) (362C673A).a78"
           "$P/Retail_v7_0/NTSC/Rampage (AM) (NTSC) (Activision) (1989) (39A316AA).a78"
           "$P/Retail_v7_0/NTSC/Double Dragon (AM) (NTSC) (Activision) (1989) (AA265865).a78"
           "$P/Retail_v7_0/NTSC/Alternates/Double Dragon (OM) (NTSC) (Activision) (1989) (F20773D5).a78")
    NG=7; run newmap 1 --spc 8
    echo "more than 512K: 528K (33 banks: Kinetescape, Drone Patrol with POKEY at \$0800) and 1024K (64 banks: Frankie demo); 32 sectors per cluster"
    FILES=("$P/UPHHD_20260101/Homebrews/K/Kinetescape (Test v1_78b) (20251031) (6E225DCD).a78"
           "$P/UPHHD_20260101/Homebrews/D/Drone Patrol (Final Rev C) (800) (20240709) (72B02356).a78"
           "$P/UPHHD_20260101/Demos/F/Frankie Goes To Hollywood - Relax (Music Demo) (20150311) (602334F5).a78")
    NG=3; run bigrom 1 --spc 32
    echo "High Score Cart: ROM and RAM from /ASTROCART on the card, served from PSRAM; RAM written back to the card"
    cp "$P/UPHHD_20260101/Utilities/High Score Cartridge (9BE408D3).a78" HSC.A78
    python3 -c "open('HSC.SAV','wb').write(bytes((i * 7 + 3) & 255 for i in range(2048)))"
    FILES=("$P/Retail_v7_0/NTSC/Asteroids (NTSC) (Atari) (1987) (DFB93F40).a78"
           "$P/UPHHD_20260101/Homebrews/W/WORDLE (20220308) (02C9EA66).a78"
           "$P/UPHHD_20260101/Homebrews/P/Plink (20201213) (F945CBD9).a78"
           "$P/Retail_v7_0/NTSC/Choplifter (NTSC) (Atari) (1987) (419BFF61).a78")
    # (a fresh image for every game: each one's save changes HSC.SAV on the card)
    NG=4; for hg in 0 1 2 3; do HSC=HSC.A78 HSCSAV=HSC.SAV ONLY=$hg run hsc8 1 --spc 8 --extra ASTROCART:HSC.A78,HSC.SAV; done
    rm -f HSC.A78 HSC.SAV
    FILES=("${SAVE[@]}"); NG=$SNG
fi
echo "math unit: the self-test cart (tests/mathtest) run by the 6502 model; Choplifter beside it gets no math unit"
../../tests/mathtest/build.sh > /dev/null || exit 2
SAVE=("${FILES[@]}"); SNG=$NG
FILES=("$C/Choplifter_NTSC.a78" ../../tests/mathtest/build/mathtest.a78); NG=2
MATHTEST=1 ONLY=1 run math8 1 --spc 8
ONLY=0 run math8 1 --spc 8
FILES=("${SAVE[@]}"); NG=$SNG
if [ -x obj_menu/Vdevcart_top ]; then
    echo "the real menu ROM (7800basic), joystick and display interrupts modelled; 16 sectors per cluster"
    python3 ../../tools/mkfat32.py menu16.img --spc 16 --sub "More Games (a sub-directory):3,6" "${FILES[@]}" > /dev/null || exit 2
    for g in -1 0 3 5 7; do
        out=$(REALMENU=1 SUB="More Games (a sub-directory):3,6" ./obj_menu/Vdevcart_top menu16.img 1 $g "${FILES[@]}" 2>&1)
        if echo "$out" | tail -1 | grep -q PASSED; then
            echo "  menu game $g: $(echo "$out" | grep -E '^load|^menu' | tail -1 | cut -c1-70) -- $(echo "$out" | tail -1)"
        else
            bad=$((bad + 1)); echo "  menu game $g FAILED"; echo "$out" | tail -8
        fi
    done
fi
rm -f ._junk.a78 "not a game.a78"
[ $bad = 0 ] && echo "MULTICART REGRESSION PASSED" || { echo "MULTICART REGRESSION FAILED ($bad)"; exit 1; }
