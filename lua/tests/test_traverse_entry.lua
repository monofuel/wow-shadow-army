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
local goal_x = -6960.4
local goal_y = -3714.4

-- No form → cast Travel Form (783) before moving.
local r = entry.decide({
  self_unit = {
    x = start_x, y = start_y, z = 14.09, map_id = 1,
    shapeshift_form_id = 0,
  },
  death = {},
  spells = { known = { 783 } },
})
check(r.kind == "cast_spell", "cast travel form first")
check(r.spell == 783, "travel form spell 783")
check(r.reason == "travel_form", "travel_form reason")

-- In form, far from goal → hop toward checkpoint (not pure +x).
r = entry.decide({
  self_unit = {
    x = start_x, y = start_y, z = 14.09, map_id = 1,
    shapeshift_form_id = 3,
    shapeshift_form_spell_id = 783,
  },
  death = {},
  spells = { known = { 783 } },
})
check(r.kind == "move", "kind move in form")
check(r.map_id == 1, "map 1")
check(r.x > start_x, "northward x component")
check(r.y < start_y, "westward y component toward checkpoint")
check(r.reason == "desert_checkpoint", "desert_checkpoint reason")
check(r.intent == "travel", "travel intent")

-- Closer to goal in x only would still need y; full near goal → hold.
r = entry.decide({
  self_unit = {
    x = goal_x + 10, y = goal_y + 10, z = 38.9, map_id = 1,
    shapeshift_form_id = 3,
  },
  death = {},
  spells = { known = { 783 } },
})
check(r.kind == "hold" and r.reason == "desert_checkpoint", "arrival hold")

-- Form drop en route → re-cast.
r = entry.decide({
  self_unit = {
    x = start_x + 200, y = start_y - 100, z = 14.0, map_id = 1,
    shapeshift_form_id = 0,
  },
  death = {},
  spells = { known = { 783 } },
})
check(r.kind == "cast_spell" and r.spell == 783, "re-cast after drop")

-- Known list without 783 → hold (do not walk human-shaped).
r = entry.decide({
  self_unit = {
    x = start_x, y = start_y, z = 14.09, map_id = 1,
    shapeshift_form_id = 0,
  },
  death = {},
  spells = { known = { 768 } },
})
check(r.kind == "hold" and r.reason == "travel_form_unknown", "unknown form hold")

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
  spells = { known = { 783 } },
})
check(r.kind == "hold" and r.reason == "dead", "hp0 is dead (no form spam)")

print("test_traverse_entry: " .. passed .. " ok")
