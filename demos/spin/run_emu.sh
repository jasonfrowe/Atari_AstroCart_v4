#!/bin/bash
# Run the spin demo in the a7800 fork, headless: dump a few frames' points and
# plot positions, let model.py check them, and leave snapshots in build/snap.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
A7800="${A7800:-$HOME/Software/a7800/mame64}"
[ -f "$HERE/build/spin.a78" ] || "$HERE/build.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
rm -rf "$HERE/build/snap"; mkdir -p "$HERE/build/snap"
cat > "$T/check.lua" <<'LUA'
local n, steps, last = 0, 0, 0
local function dump(mem)
  local t = {string.format("SPIN %X %X", mem:read_u16(0x22AA), mem:read_u16(0x22AC))}
  for a = 0x2200, 0x229F do t[#t + 1] = string.format("%X", mem:read_u8(a)) end
  for a = 0x0140, 0x015F do t[#t + 1] = string.format("%X", mem:read_u8(a)) end
  print(table.concat(t, " "))
end
emu.register_frame_done(function()
  n = n + 1
  local mem = manager:machine().devices[":maincpu"].spaces["program"]
  if n == 200 or n == 420 or n == 800 or n == 1200 then mem:write_u8(0x22A8, (mem:read_u8(0x22A8) + 32) % 128) end
  if (n >= 150 and n < 155) or (n >= 430 and n < 435) or (n >= 1000 and n < 1005) then dump(mem) end
  if n >= 200 and n <= 1400 then
    local a = mem:read_u16(0x22A0)
    if n > 200 and a ~= last then steps = steps + 1 end
    last = a
    if n == 1400 then print(string.format("STEPS %d in 1200 frames", steps)) end
  end
  if n == 150 or n == 215 or n == 400 or n == 780 or n == 1180 or n == 1400 then manager:machine():video():snapshot() end
end)
LUA
cd "$T"
"$A7800" a7800 -cart "$HERE/build/spin.a78" -video none -sound none -nothrottle -seconds_to_run 25 \
    -autoboot_script check.lua -snapshot_directory "$HERE/build/snap" > out.txt 2>&1 || true
grep STEPS out.txt || true
python3 "$HERE/model.py" check out.txt
