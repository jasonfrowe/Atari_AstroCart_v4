#!/bin/bash
# Build until timing is clean: sweep the placement seed (see SEED in devcart_top.v).
# Leaves the clean bitstream in build/impl/pnr/devcart.fs and prints the seed that made it.
HERE="$(cd "$(dirname "$0")" && pwd)"
for seed in ${SEEDS:-0 1 2 3 4 5 6 7 8 9 10 11 12}; do
    out=$(SEED=$seed "$HERE/build.sh" 2>&1) || { echo "$out" | tail -5; exit 1; }
    if echo "$out" | grep -q "^TNS"; then
        echo "seed $seed: $(echo "$out" | grep '^TNS' | head -1 | sed 's/.*Setup: //')"
    else
        echo "seed $seed: CLEAN"; echo "$out" | grep -E "^Fmax|^ +[0-9]" | head -3
        exit 0
    fi
done
rm -f "$HERE/build/impl/pnr/devcart.fs"
echo "no clean seed found (bitstream removed)"; exit 1
