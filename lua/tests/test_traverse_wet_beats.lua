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

-- Cheese coast: ordered human-ribbon waypoints (not sparse coast_* only).
local r = swim(-6700, -4870)
check(r.kind == "navigate", "early navigate")
check(type(r.beat_id) == "string" and r.beat_id:match("^cheese_"),
  "early targets cheese waypoint: " .. tostring(r.beat_id))
check(r.mode == "liquid_prefer", "liquid mode")

r = swim(-5400, -4890)
check(r.kind == "navigate", "mid navigate")
check(type(r.beat_id) == "string", "mid has beat")
-- Must still be a wet cheese point or duskwallow, not land_approach.
check(r.beat_id ~= "land_approach" and r.beat_id ~= "water_entry",
  "mid stays on wet cheese chain")
check(r.route_reference and r.route_reference.along_route_yards
    and r.route_reference.along_route_yards > 500,
  "along-route progress")
check(r.route_reference.total_route_yards > r.route_reference.along_route_yards,
  "route total")

r = swim(-4627, -4869)
check(r.kind == "hold" and r.reason == "duskwallow_coast", "Dustwallow proof")

r = swim(-6700, -4870, 0)
check(r.kind == "cast_spell" and r.spell == 1066, "reapply Aquatic")

-- Sequential: further north should not select a far-behind early cheese id.
r = swim(-5000, -4800)
check(r.kind == "navigate" or r.kind == "hold", "late segment intent")
if r.kind == "navigate" then
  local id = r.beat_id or ""
  local num = tonumber(id:match("cheese_(%d+)"))
  check(num == nil or num >= 10, "late does not regress to early cheese: " .. id)
end

print("test_traverse_wet_beats: " .. passed .. " ok")
