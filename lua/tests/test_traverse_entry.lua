-- Unit tests for strategy-only lua/entry/traverse.lua
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
check(entry.name == "traverse", "name")
check(type(entry.decide) == "function", "decide")

local start_x, start_y = -9187.0, -2530.25
local water_x, water_y = -6784.5, -4920.0
local merch_x, merch_y = -1533.7, -4056.5
local land_spells = { known = { 783, 1066 } }

local r = entry.decide({
  self_unit = {
    x = start_x, y = start_y, z = 14.09, map_id = 1,
    shapeshift_form_id = 0, is_swimming = false,
  },
  death = {}, spells = land_spells, view_id = 0,
})
check(r.kind == "cast_spell" or r.kind == "navigate", "cast or navigate without form")
if r.kind == "cast_spell" then
  check(r.spell == 783, "travel form")
end

r = entry.decide({
  self_unit = {
    x = start_x, y = start_y, z = 14.09, map_id = 1,
    shapeshift_form_id = 3, shapeshift_form_spell_id = 783,
    is_swimming = false,
  },
  death = {}, spells = land_spells, view_id = 1,
})
check(r.kind == "navigate", "navigate in travel form")
check(r.reason == "land_approach" or r.reason == "water_entry" or r.reason == "enter_water",
  "land beat reason")
check(type(r.x) == "number" and type(r.y) == "number", "navigate has xy")
check(r.mode == "land" or r.mode == "liquid_prefer", "has mode")
check(not string.find(r.reason or "", "unstick", 1, true), "no unstick")

r = entry.decide({
  self_unit = {
    x = water_x + 10, y = water_y + 10, z = 0.7, map_id = 1,
    shapeshift_form_id = 0, is_swimming = false,
  },
  death = {}, spells = land_spells, view_id = 2,
})
check(r.kind == "navigate", "shore navigate")
check(r.reason == "enter_water" or r.reason == "water_entry", "enter water beat")

r = entry.decide({
  self_unit = {
    x = water_x + 40, y = water_y - 10, z = 0.2, map_id = 1,
    shapeshift_form_id = 3, is_swimming = false,
    liquid_coverage_known = true, liquid_known = true,
    liquid_surface_z = 0.5, liquid_submerged = false,
  },
  death = {}, spells = land_spells, view_id = 2,
})
check(r.kind == "navigate", "wading navigate")
check(r.reason == "enter_water", "wading stays on wet leg")
check(r.mode == "liquid_prefer", "wading uses liquid corridor")

r = entry.decide({
  self_unit = {
    x = water_x + 500, y = water_y, z = 5.0, map_id = 1,
    shapeshift_form_id = 3, is_swimming = false,
  },
  death = {}, spells = land_spells, view_id = 3,
})
check(r.kind == "navigate", "mid-coast navigate")
check(r.reason == "reenter_water", "reenter when dry mid-coast")

r = entry.decide({
  self_unit = {
    x = water_x, y = water_y, z = 0.5, map_id = 1,
    shapeshift_form_id = 3, is_swimming = true,
  },
  death = {}, spells = land_spells, view_id = 0,
})
check(r.kind == "cast_spell" and r.spell == 1066, "aquatic when wet wrong form")

r = entry.decide({
  self_unit = {
    x = -5000, y = -4500, z = -5, map_id = 1,
    shapeshift_form_id = 4, shapeshift_form_spell_id = 1066,
    is_swimming = true,
  },
  death = {}, spells = land_spells, view_id = 10,
})
check(r.kind == "navigate", "swim navigate")
check(r.mode == "liquid_prefer", "liquid mode")
-- Sparse wet legs first; merchant only when nearby (pathfinding-plan).
check(r.reason:find("swim_", 1, true) == 1, "swim_* wet leg")
check(r.x > -5500 and r.x <= merch_x + 50, "wet leg north of early coast")

r = entry.decide({
  self_unit = {
    x = -6140, y = -4932, z = -3.4, map_id = 1,
    shapeshift_form_id = 4, shapeshift_form_spell_id = 1066,
    is_swimming = true,
  },
  death = {}, spells = land_spells, view_id = 11,
})
check(r.kind == "navigate", "past wet leg navigate")
check(r.beat_id == "wet_leg_b", "northing hysteresis does not reselect wet leg a")

r = entry.decide({
  self_unit = {
    x = -6175, y = -4872, z = -3.0, map_id = 1,
    shapeshift_form_id = 4, shapeshift_form_spell_id = 1066,
    is_swimming = true,
  },
  death = {}, spells = land_spells, view_id = 11,
})
check(r.beat_id == "wet_leg_b", "shoreline correction cannot reopen wet leg a")

r = entry.decide({
  self_unit = {
    x = -6710.0, y = -4834.0, z = 0.3, map_id = 1,
    shapeshift_form_id = 3, is_swimming = false,
    liquid_coverage_known = true, liquid_known = false,
  },
  death = {}, spells = land_spells, view_id = 11,
})
check(r.reason == "reenter_water" and r.beat_id == "wet_leg_a",
  "past entry shoreline stays committed to first wet leg")

r = entry.decide({
  self_unit = {
    x = merch_x + 20, y = merch_y - 20, z = -12, map_id = 1,
    shapeshift_form_id = 4, is_swimming = true,
  },
  death = {}, spells = land_spells, view_id = 12,
})
check(r.kind == "hold" and r.reason == "merchant_coast", "wet prove hold")

r = entry.decide({
  self_unit = {
    x = merch_x + 20, y = merch_y - 20, z = 5, map_id = 1,
    shapeshift_form_id = 3, is_swimming = false,
  },
  death = {}, spells = land_spells, view_id = 11,
})
check(r.kind ~= "hold" or r.reason ~= "merchant_coast", "dry not merchant_coast")

r = entry.decide({
  self_unit = { x = 0, y = 0, z = 0, map_id = 1, is_swimming = false },
  death = { is_dead = true, is_ghost = false },
  spells = land_spells,
})
check(r.kind == "hold" and r.reason == "release_spirit", "corpse hold")

r = entry.decide({
  self_unit = {
    x = start_x, y = start_y, z = 14, map_id = 1,
    shapeshift_form_id = 0, is_swimming = false,
  },
  death = { is_ghost = true },
  spells = land_spells, view_id = 1,
})
check(r.kind == "hold" and r.reason == "dead_reset", "ghost hold for reset")

print("test_traverse_entry: " .. passed .. " ok")
