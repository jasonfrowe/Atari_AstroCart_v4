#!/bin/bash
# Run the math unit self-test in the a7800 fork, headless. Prints the result line; exit 0 on a pass.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
A7800="${A7800:-$HOME/Software/a7800/mame64}"
[ -f "$HERE/build/mathtest.a78" ] || "$HERE/build.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/check.lua" <<'LUA'
emu.register_stop(function()
  local mem = manager:machine().devices[":maincpu"].spaces["program"]
  print(string.format("MATHTEST status=%02X steps=%d reg=%d got=%02X want=%02X",
    mem:read_u8(0x44), mem:read_u8(0x42) + 256 * mem:read_u8(0x43), mem:read_u8(0x45), mem:read_u8(0x46), mem:read_u8(0x47)))
end)
LUA
cd "$T"
out=$("$A7800" a7800 -cart "$HERE/build/mathtest.a78" -video none -sound none -nothrottle -seconds_to_run 4 -autoboot_script check.lua 2>&1 | grep MATHTEST || true)
echo "${out:-no result line (did the emulator start?)}"
echo "$out" | grep -q "status=A5"
