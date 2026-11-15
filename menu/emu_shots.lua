-- a7800 autoboot script: walk the menu with the joystick and save snapshots.
-- (run by tools/menu_shots.sh; snapshots land in the snapshot directory)
local m = manager:machine()
local frame = 0
local function port(tag, field)
    for t, p in pairs(m:ioport().ports) do
        for name, f in pairs(p.fields) do
            if name == field then return f end
        end
    end
end
local down, up, right, fire = port("", "P1 Down"), port("", "P1 Up"), port("", "P1 Right"), port("", "P1 Button 1")
local plan = {}      -- frame -> action
local function press(f, at, len) plan[at] = function() f:set_value(1) end; plan[at + len] = function() f:set_value(0) end end
local t = 200
plan[t] = function() m:video():snapshot() end                                   -- 0000: first page
for i = 1, 5 do press(down, t + 10 + i * 20, 4) end
plan[t + 140] = function() m:video():snapshot() end                             -- 0001: cursor on game 5
press(right, t + 150, 4)
plan[t + 190] = function() m:video():snapshot() end                             -- 0002: second page
press(right, t + 200, 4)
for i = 1, 6 do press(down, t + 230 + i * 20, 4) end
plan[t + 400] = function() m:video():snapshot() end                             -- 0003: last page, last game
press(fire, t + 410, 4)
plan[t + 440] = function() m:video():snapshot() end                             -- 0004: loading screen
plan[t + 1100] = function() m:video():snapshot() end                            -- 0005: error (no SD in the emulator)
plan[t + 1110] = function() m:exit() end
emu.register_frame_done(function()
    frame = frame + 1
    if plan[frame] then plan[frame]() end
end)
