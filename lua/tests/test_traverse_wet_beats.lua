package.path = "lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;"
local entry = require("traverse")
local route = dofile("lua/tests/traverse_route_fixture.lua")
local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end
local spells = { known = { 783, 1066 } }
local function swim(x, y, form)
  return entry.decide({
    self_unit = {
      x = x, y = y, z = -5, map_id = 1,
      shapeshift_form_id = form or 4,
      shapeshift_form_spell_id = form == 0 and 0 or 1066,
      is_swimming = true,
    },
    death = {}, spells = spells, view_id = 10,
  }, route)
end

local r = swim(-6473, -4900)
check(r.kind == "navigate" and r.beat_id == "coast_02", "early ordered beat")
check(r.reason == "swim_coast_02", "named swim intent")

r = swim(-5100, -4858)
check(r.kind == "navigate" and r.beat_id == "coast_10", "mid-route next beat")
check(r.route_reference.along_route_yards > 1000, "along-route progress")
check(r.route_reference.total_route_yards > r.route_reference.along_route_yards,
  "route total")

r = swim(-4627, -4869)
check(r.kind == "hold" and r.reason == "duskwallow_coast", "Dustwallow proof")

r = swim(-6473, -4900, 0)
check(r.kind == "cast_spell" and r.spell == 1066, "reapply Aquatic")

print("test_traverse_wet_beats: " .. passed .. " ok")
