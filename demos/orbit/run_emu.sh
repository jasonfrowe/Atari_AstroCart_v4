#!/bin/bash
# Run the orbit game in the a7800 fork, headless. A Lua script plays it by
# writing the game's variables: player 1 launches a probe and its path is logged,
# which check.py compares with the same motion in floating point; player 2
# launches, then that probe is put on the moon and a point for player 2 is expected. Snapshots go to build/snap.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
A7800="${A7800:-$HOME/Software/a7800/mame64}"
[ -f "$HERE/build/orbit.a78" ] || "$HERE/build.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
rm -rf "$HERE/build/snap"; mkdir -p "$HERE/build/snap"
cat > "$T/play.lua" <<'LUA'
local n, steps, last = 0, 0, -1
local function s16(v) if v >= 32768 then return v - 65536 end return v end
local function u16(mem, lo, hi) return mem:read_u8(lo) + 256 * mem:read_u8(hi) end
emu.register_frame_done(function()
  n = n + 1
  local mem = manager:machine().devices[":maincpu"].spaces["program"]
  if n == 200 then                          -- player 1: aim along the orbit, a little under circular speed
    local sa = mem:read_u16(0x2242)
    local aim = (sa + 0x4000) % 65536
    mem:write_u8(0x2260, aim % 256); mem:write_u8(0x2262, aim // 256)
    mem:write_u8(0x2264, 3)
    mem:write_u8(0x2266, 1)
  end
  if n > 201 and n <= 1000 and mem:read_u8(0x2268) == 1 then
    print(string.format("PATH %d %d %d %d %d", u16(mem, 0x226A, 0x226C),
      s16(u16(mem, 0x2272, 0x2274)), s16(u16(mem, 0x2278, 0x227A)), s16(u16(mem, 0x227C, 0x227E)), s16(u16(mem, 0x2280, 0x2282))))
  end
  if n == 600 then mem:write_u8(0x2267, 1) end      -- player 2 launches too
  if n == 1010 then                         -- player 2's probe at rest on the moon
    local mx, my = mem:read_u16(0x223E), mem:read_u16(0x2240)
    mem:write_u8(0x2273, mx % 256); mem:write_u8(0x2275, mx // 256)
    mem:write_u8(0x2279, my % 256); mem:write_u8(0x227B, my // 256)
    mem:write_u8(0x227D, 0); mem:write_u8(0x227F, 0); mem:write_u8(0x2281, 0); mem:write_u8(0x2283, 0)
    mem:write_u8(0x226B, 0); mem:write_u8(0x226D, 0); mem:write_u8(0x2269, 1)
  end
  if n == 1020 then
    print(string.format("COUNTS scores %02X %02X flying %d %d text %s%s %s%s", mem:read_u8(0x228C), mem:read_u8(0x228D),
      mem:read_u8(0x2268), mem:read_u8(0x2269), string.char(mem:read_u8(0x2290)), string.char(mem:read_u8(0x2291)),
      string.char(mem:read_u8(0x2292)), string.char(mem:read_u8(0x2293))))
  end
  if n > 400 and n <= 1000 then local f = mem:read_u8(0x2246); if f ~= last then steps = steps + 1 end; last = f end
  if n == 1000 then print("FPS " .. steps .. " steps in 600 frames") end
  if n == 190 or n == 400 or n == 700 or n == 1016 or n == 1100 then manager:machine():video():snapshot() end
end)
LUA
cd "$T"
"$A7800" a7800 -cart "$HERE/build/orbit.a78" -video none -sound none -nothrottle -seconds_to_run 22 \
    -autoboot_script play.lua -snapshot_directory "$HERE/build/snap" > out.txt 2>&1 || true
cp out.txt "${KEEP:-/dev/null}" 2>/dev/null || true
python3 "$HERE/check.py" out.txt
