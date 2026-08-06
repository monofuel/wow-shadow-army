-- Unit tests for lua/entry/traverse.lua (multi-leg Petrel, wet-only merchant).
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
local water_x = -6784.5
local water_y = -4833.9
local merch_x = -1533.7
local merch_y = -4056.5
local land_spells = { known = { 783, 1066 } }

-- No form on land: cast Travel Form (783) or soft-move.
local r = entry.decide({
  self_unit = {
    x = start_x, y = start_y, z = 14.09, map_id = 1,
    shapeshift_form_id = 0,
    is_swimming = false,
  },
  death = {},
  spells = land_spells,
  view_id = 0,
})
check(r.kind == "cast_spell" or r.kind == "move", "cast form or move without form")
if r.kind == "cast_spell" then
  check(r.spell == 783, "travel form spell 783")
  check(r.reason == "travel_form", "travel_form reason")
end

-- In travel form, far from water → hop toward water entry.
r = entry.decide({
  self_unit = {
    x = start_x, y = start_y, z = 14.09, map_id = 1,
    shapeshift_form_id = 3,
    shapeshift_form_spell_id = 783,
    is_swimming = false,
  },
  death = {},
  spells = land_spells,
  view_id = 1,
})
check(r.kind == "move", "kind move in form")
check(r.map_id == 1, "map 1")
check(r.x > start_x, "northward x component")
check(r.y < start_y, "westward y component toward water entry")
check(r.reason == "water_entry" or r.reason == "water_entry_unstick"
  or r.reason == "land_approach" or r.reason == "land_approach_unstick"
  or r.reason == "land_west_clear" or r.reason == "land_west_clear_unstick"
  or r.reason == "land_east_clear" or r.reason == "land_east_clear_unstick"
  or r.reason == "land_south_clear" or r.reason == "land_south_clear_unstick"
  or r.reason == "land_approach_west" or r.reason == "land_approach_west_unstick",
  "water_entry or land_approach reason")
check(r.intent == "travel", "travel intent")

-- Human form near water entry (not swimming) → still water_entry, NOT merchant land-cut.
r = entry.decide({
  self_unit = {
    x = water_x + 10, y = water_y + 10, z = 0.7, map_id = 1,
    shapeshift_form_id = 0,
    is_swimming = false,
  },
  death = {},
  spells = land_spells,
  view_id = 2,
})
check(r.kind == "move", "human at shore still moves")
check(r.reason == "water_entry" or r.reason == "water_entry_unstick"
  or r.reason == "enter_water" or r.reason == "enter_water_unstick",
  "shore not swimming → enter/water_entry (no to_merchant land-cut)")
check(r.reason ~= "to_merchant" and r.reason ~= "to_merchant_unstick"
  and r.reason ~= "swim_merchant",
  "no land-cut merchant reason")

-- Land north of water entry (dry) must NOT chase merchant — stay wet thesis.
-- Mid-coast beach: re-enter seaward from here (not back to Tanaris entry).
r = entry.decide({
  self_unit = {
    x = water_x + 500, y = water_y, z = 5.0, map_id = 1,
    shapeshift_form_id = 3,
    shapeshift_form_spell_id = 783,
    is_swimming = false,
  },
  death = {},
  spells = land_spells,
  view_id = 3,
})
check(r.kind == "move", "dry north of entry still moves")
check(r.reason == "reenter_water" or r.reason == "reenter_water_unstick",
  "dry mid-coast → reenter_water (not merchant land-cut)")
check(r.reason ~= "swim_merchant" and r.reason ~= "to_merchant",
  "no land-cut merchant reason mid-coast dry")

-- Still in Travel Form near shore → keep moving into water (game drops Travel).
-- No leave_travel /cancelform thrash.
r = entry.decide({
  self_unit = {
    x = water_x + 40, y = water_y + 40, z = 2.0, map_id = 1,
    shapeshift_form_id = 3,
    shapeshift_form_spell_id = 783,
    is_swimming = false,
  },
  death = {},
  spells = land_spells,
  view_id = 0,
})
check(r.kind == "move", "travel at shore moves into water")
check(r.reason ~= "leave_travel_at_shore", "no leave_travel_at_shore")
check(r.kind ~= "cast_spell" or (r.spell ~= 783), "no travel toggle at shore")

-- Known list without 783 → hold far from water (do not walk human-shaped forever).
r = entry.decide({
  self_unit = {
    x = start_x, y = start_y, z = 14.09, map_id = 1,
    shapeshift_form_id = 0,
    is_swimming = false,
  },
  death = {},
  spells = { known = { 1066 } },
  view_id = 0, -- phase forces form attempt
})
check(r.kind == "hold" and r.reason == "travel_form_unknown", "unknown form hold")

-- Swimming without aquatic → must cast 1066 (breath-critical, no soft skip).
r = entry.decide({
  self_unit = {
    x = water_x, y = water_y, z = 0.5, map_id = 1,
    shapeshift_form_id = 3,
    shapeshift_form_spell_id = 783,
    is_swimming = true,
  },
  death = {},
  spells = land_spells,
  view_id = 0, -- phase % 2 == 0 for wrong-form aquatic cadence
})
check(r.kind == "cast_spell", "cast aquatic in water")
check(r.spell == 1066, "aquatic spell 1066")
check(r.reason == "aquatic_form", "aquatic_form reason")

-- Swimming + aquatic, mid-ocean toward merchant → move swim_merchant*.
r = entry.decide({
  self_unit = {
    x = -5000, y = -4500, z = -5, map_id = 1,
    shapeshift_form_id = 4,
    shapeshift_form_spell_id = 1066,
    is_swimming = true,
  },
  death = {},
  spells = land_spells,
  view_id = 10,
})
check(r.kind == "move", "swim move")
check(r.reason == "swim_merchant" or r.reason == "swim_merchant_coast_bias"
  or r.reason == "swim_merchant_unstick"
  or r.reason == "swim_merchant_coast_bias_unstick",
  "swim toward merchant")
check(r.x > -5000, "swim hop north")

-- Near merchant on land (dry) → NOT merchant_coast hold (must be wet).
r = entry.decide({
  self_unit = {
    x = merch_x + 20, y = merch_y - 20, z = 5, map_id = 1,
    shapeshift_form_id = 3,
    shapeshift_form_spell_id = 783,
    is_swimming = false,
  },
  death = {},
  spells = land_spells,
  view_id = 11,
})
check(r.kind ~= "hold" or r.reason ~= "merchant_coast",
  "dry near merchant is not merchant_coast prove")
-- Dry past water entry → reenter_water (seaward), not merchant land path.
if r.kind == "move" then
  check(r.reason == "reenter_water" or r.reason == "reenter_water_unstick"
    or r.reason == "enter_water" or r.reason == "enter_water_unstick",
    "dry past entry reenters water not land-cut merchant")
end

-- Near merchant coast swimming + aquatic → hold.
r = entry.decide({
  self_unit = {
    x = merch_x + 20, y = merch_y - 20, z = -12, map_id = 1,
    shapeshift_form_id = 4,
    shapeshift_form_spell_id = 1066,
    is_swimming = true,
  },
  death = {},
  spells = land_spells,
  view_id = 12,
})
check(r.kind == "hold" and r.reason == "merchant_coast", "merchant arrival hold wet")

-- No position.
r = entry.decide({ self_unit = {}, death = {}, spells = land_spells })
check(r.kind == "hold" and r.reason == "no_self_position", "no position")

-- Corpse (not released) → release_spirit hold.
r = entry.decide({
  self_unit = { x = 0, y = 0, z = 0, map_id = 1, is_swimming = false },
  death = { is_dead = true, is_ghost = false },
  spells = land_spells,
})
check(r.kind == "hold" and r.reason == "release_spirit", "corpse release hold")

-- Ghost keeps pathing.
r = entry.decide({
  self_unit = {
    x = start_x, y = start_y, z = 14, map_id = 1,
    shapeshift_form_id = 0, is_swimming = false,
  },
  death = { is_dead = false, is_ghost = true },
  spells = land_spells,
  view_id = 1,
})
check(r.kind == "move" or r.kind == "cast_spell", "ghost still paths")

-- Ghost inside interact band (≤5.5) → interact.
r = entry.decide({
  self_unit = {
    x = -7199.0, y = -3940.0, z = 9.5, map_id = 1,
    shapeshift_form_id = 0, is_swimming = false,
  },
  death = {
    is_ghost = true,
    spirit_healer_known = true,
    spirit_healer_name = "Spirit Healer",
    spirit_healer_dist = 4.0,
    spirit_healer_x = -7199.6,
    spirit_healer_y = -3940.9,
    spirit_healer_z = 9.5,
  },
  spells = land_spells,
  view_id = 20,
})
check(r.kind == "interact", "ghost interact spirit healer")
check(r.reason == "spirit_healer_interact", "spirit_healer_interact reason")
-- Ghost 8yd out → walk closer, not interact.
r = entry.decide({
  self_unit = {
    x = -7192.0, y = -3940.0, z = 9.1, map_id = 1,
    shapeshift_form_id = 0, is_swimming = false,
  },
  death = {
    is_ghost = true,
    spirit_healer_known = true,
    spirit_healer_name = "Spirit Healer",
    spirit_healer_dist = 8.0,
    spirit_healer_interact_dist = 3.8,
    spirit_healer_x = -7199.6,
    spirit_healer_y = -3940.9,
    spirit_healer_z = 9.5,
  },
  spells = land_spells,
  view_id = 21,
})
check(r.kind == "move", "ghost 8yd walks to spirit")
check(r.reason == "ghost_to_spirit_healer" or r.reason == "ghost_to_spirit_healer_unstick",
  "ghost_to_spirit_healer when outside interact range")

-- Swimming form 0 + breath draining → hard aquatic cast.
r = entry.decide({
  self_unit = {
    x = water_x, y = water_y, z = 0.5, map_id = 1,
    shapeshift_form_id = 0,
    is_swimming = true,
    breath_timer_active = true,
    breath_remaining_fraction = 0.5,
  },
  death = {},
  spells = land_spells,
  view_id = 0, -- phase % 2 == 0 for breath cast cadence
})
check(r.kind == "cast_spell" and r.spell == 1066, "breath draining → hard aquatic cast")
-- Swimming form 0, no breath bar: soft retry only on phase%6==0 (avoid toggle thrash).
r = entry.decide({
  self_unit = {
    x = water_x, y = water_y, z = 0.5, map_id = 1,
    shapeshift_form_id = 0,
    is_swimming = true,
    breath_timer_active = false,
    breath_remaining_fraction = 0.0,
  },
  death = {},
  spells = land_spells,
  view_id = 11, -- 11%6 != 0 → prefer move
})
check(r.kind == "move" or (r.kind == "cast_spell" and r.spell == 1066),
  "no breath bar → soft aquatic or move")

-- hp0 corpse.
r = entry.decide({
  self_unit = {
    x = start_x, y = start_y, z = 14, map_id = 1,
    shapeshift_form_id = 0, is_swimming = false,
  },
  combat = { health_pct = 0 },
  death = { is_ghost = false },
  spells = land_spells,
})
check(r.kind == "hold" and r.reason == "release_spirit", "hp0 corpse hold")

print("test_traverse_entry: " .. passed .. " ok")
