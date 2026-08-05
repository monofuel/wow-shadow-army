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

local start_x = -9187.0
local start_y = -2530.25
local goal_x = -6784.5
local goal_y = -4833.9
local land_spells = { known = { 783, 1066 } }

-- No form on land → cast Travel Form (783) before moving.
local r = entry.decide({
  self_unit = {
    x = start_x, y = start_y, z = 14.09, map_id = 1,
    shapeshift_form_id = 0,
    is_swimming = false,
  },
  death = {},
  spells = land_spells,
})
check(r.kind == "cast_spell", "cast travel form first")
check(r.spell == 783, "travel form spell 783")
check(r.reason == "travel_form", "travel_form reason")

-- In travel form, far from goal → hop toward water entry (not pure +x).
r = entry.decide({
  self_unit = {
    x = start_x, y = start_y, z = 14.09, map_id = 1,
    shapeshift_form_id = 3,
    shapeshift_form_spell_id = 783,
    is_swimming = false,
  },
  death = {},
  spells = land_spells,
})
check(r.kind == "move", "kind move in form")
check(r.map_id == 1, "map 1")
check(r.x > start_x, "northward x component")
check(r.y < start_y, "westward y component toward water entry")
check(r.reason == "water_entry", "water_entry reason")
check(r.intent == "travel", "travel intent")

-- Near water entry on land → hold.
r = entry.decide({
  self_unit = {
    x = goal_x + 10, y = goal_y + 10, z = 0.7, map_id = 1,
    shapeshift_form_id = 3,
    is_swimming = false,
  },
  death = {},
  spells = land_spells,
})
check(r.kind == "hold" and r.reason == "water_entry", "arrival hold")

-- Form drop en route → re-cast travel.
r = entry.decide({
  self_unit = {
    x = start_x + 200, y = start_y - 100, z = 14.0, map_id = 1,
    shapeshift_form_id = 0,
    is_swimming = false,
  },
  death = {},
  spells = land_spells,
})
check(r.kind == "cast_spell" and r.spell == 783, "re-cast after drop")

-- Known list without 783 → hold (do not walk human-shaped).
r = entry.decide({
  self_unit = {
    x = start_x, y = start_y, z = 14.09, map_id = 1,
    shapeshift_form_id = 0,
    is_swimming = false,
  },
  death = {},
  spells = { known = { 768 } },
})
check(r.kind == "hold" and r.reason == "travel_form_unknown", "unknown form hold")

-- In water, still in Travel Form → cast Aquatic Form (1066).
r = entry.decide({
  self_unit = {
    x = goal_x, y = goal_y, z = 0.7, map_id = 1,
    shapeshift_form_id = 3,
    shapeshift_form_spell_id = 783,
    is_swimming = true,
  },
  death = {},
  spells = land_spells,
})
check(r.kind == "cast_spell", "cast aquatic in water")
check(r.spell == 1066, "aquatic form spell 1066")
check(r.reason == "aquatic_form", "aquatic_form reason")

-- In water, no form → aquatic, not travel.
r = entry.decide({
  self_unit = {
    x = goal_x - 20, y = goal_y, z = -1.0, map_id = 1,
    shapeshift_form_id = 0,
    is_swimming = true,
  },
  death = {},
  spells = land_spells,
})
check(r.kind == "cast_spell" and r.spell == 1066, "no form in water → aquatic")

-- Aquatic form dropped mid-swim → re-cast before moving.
r = entry.decide({
  self_unit = {
    x = goal_x - 100, y = goal_y + 50, z = -2.0, map_id = 1,
    shapeshift_form_id = 0,
    is_swimming = true,
  },
  death = {},
  spells = land_spells,
})
check(r.kind == "cast_spell" and r.spell == 1066, "re-cast aquatic if dropped")

-- In water + aquatic + not at goal → swim hop (not travel form).
r = entry.decide({
  self_unit = {
    x = goal_x - 200, y = goal_y, z = -2.0, map_id = 1,
    shapeshift_form_id = 4,
    shapeshift_form_spell_id = 1066,
    is_swimming = true,
  },
  death = {},
  spells = land_spells,
})
check(r.kind == "move", "swim move in aquatic")
check(r.reason == "swim_toward", "swim_toward reason")
check(r.x > goal_x - 200, "swim hop northward-ish")

-- In water + aquatic + at goal → hold (still aquatic, not travel).
r = entry.decide({
  self_unit = {
    x = goal_x + 5, y = goal_y + 5, z = 0.7, map_id = 1,
    shapeshift_form_id = 4,
    shapeshift_form_spell_id = 1066,
    is_swimming = true,
  },
  death = {},
  spells = land_spells,
})
check(r.kind == "hold" and r.reason == "water_entry", "aquatic arrival hold")

-- Known without aquatic while swimming → hold (do not drown human-shaped).
r = entry.decide({
  self_unit = {
    x = goal_x, y = goal_y, z = 0.0, map_id = 1,
    shapeshift_form_id = 0,
    is_swimming = true,
  },
  death = {},
  spells = { known = { 783 } },
})
check(r.kind == "hold" and r.reason == "aquatic_form_unknown", "aquatic unknown hold")

r = entry.decide({ self_unit = {}, death = {} })
check(r.kind == "hold" and r.reason == "no_self_position", "no position")

r = entry.decide({
  self_unit = { x = start_x, y = start_y, z = 0, map_id = 1, shapeshift_form_id = 3 },
  death = { is_dead = true },
})
check(r.kind == "hold" and r.reason == "dead", "dead hold")

r = entry.decide({
  self_unit = {
    x = start_x, y = start_y, z = 14.0, map_id = 1, shapeshift_form_id = 0,
  },
  death = {},
  combat = { health_pct = 0 },
  spells = land_spells,
})
check(r.kind == "hold" and r.reason == "dead", "hp0 is dead (no form spam)")

print("test_traverse_entry: " .. passed .. " ok")
