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
local water_x, water_y = -6784.5, -4833.9
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
check(r.reason == "swim_merchant", "swim to merchant beat")
check(r.mode == "liquid_prefer", "liquid mode")
check(r.x == merch_x and r.y == merch_y, "merchant coords as goal")

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
