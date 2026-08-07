local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

package.path = "lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;"
local entry = require("traverse")
local route = dofile("lua/tests/traverse_route_fixture.lua")
local spells = { known = { 783, 1066 } }
local function decide(unit, view_id, death)
  return entry.decide({
    self_unit = unit,
    death = death or {},
    spells = spells,
    view_id = view_id or 1,
  }, route)
end

check(entry.name == "traverse", "name")
check(entry.decide({}, {}).reason == "no_self_position", "missing position")

local r = decide({
  x = -9187, y = -2530.25, z = 14, map_id = 1,
  shapeshift_form_id = 0, is_swimming = false,
}, 0)
check(r.kind == "cast_spell" and r.spell == 783, "travel form")

r = decide({
  x = -9187, y = -2530.25, z = 14, map_id = 1,
  shapeshift_form_id = 3, shapeshift_form_spell_id = 783,
  is_swimming = false,
})
check(r.kind == "navigate" and r.reason == "land_approach", "land approach")

r = decide({
  x = -6760, y = -4900, z = 0, map_id = 1,
  shapeshift_form_id = 3, is_swimming = true,
})
check(r.kind == "cast_spell" and r.spell == 1066, "aquatic after entry")

r = decide({
  x = -6737, y = -4871, z = -2, map_id = 1,
  shapeshift_form_id = 4, shapeshift_form_spell_id = 1066,
  is_swimming = true,
})
-- On cheese ribbon: at first human sample, next unreached wet pearl is cheese_02.
check(r.kind == "navigate" and r.beat_id == "cheese_02", "first cheese advance")
check(r.route_reference.cross_track_yards < 150, "reference metric attached")

r = decide({
  x = -6575, y = -4868, z = -7, map_id = 1,
  shapeshift_form_id = 4, shapeshift_form_spell_id = 1066,
  is_swimming = true,
})
check(r.beat_id == "cheese_05", "passed cheese never reopens early")

r = decide({
  x = -5480, y = -4845, z = -5, map_id = 1,
  shapeshift_form_id = 4, shapeshift_form_spell_id = 1066,
  is_swimming = true,
})
check(r.beat_id == "cheese_25", "mid-route remains ordered cheese")

r = decide({
  x = -5480, y = -4800, z = 1, map_id = 1,
  shapeshift_form_id = 0, is_swimming = false,
  liquid_coverage_known = true, liquid_known = false,
})
check(r.reason == "reenter_water" and r.beat_id == "cheese_24",
  "dry recovery rejoins next cheese beat")

r = decide({
  x = -4627, y = -4869, z = -2, map_id = 1,
  shapeshift_form_id = 4, shapeshift_form_spell_id = 1066,
  is_swimming = true,
})
check(r.kind == "hold" and r.reason == "duskwallow_coast", "goal hold")

r = decide({
  x = -4627, y = -4869, z = 2, map_id = 1,
  shapeshift_form_id = 3, is_swimming = false,
})
check(r.kind ~= "hold" or r.reason ~= "duskwallow_coast", "dry is not success")

r = decide({ x = 0, y = 0, z = 0, map_id = 1, is_swimming = false }, 1,
  { is_dead = true, is_ghost = false })
check(r.kind == "hold" and r.reason == "release_spirit", "corpse hold")

print("test_traverse_entry: " .. passed .. " ok")
