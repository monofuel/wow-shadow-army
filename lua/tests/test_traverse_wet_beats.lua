-- Wet beat chain: never one straight merchant-only swim from early coast.
package.path = "lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;"
local entry = require("traverse")
local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local spells = { known = { 783, 1066 } }

local r = entry.decide({
  self_unit = {
    x = -6473.0, y = -4863.0, z = -2.3, map_id = 1,
    shapeshift_form_id = 4, shapeshift_form_spell_id = 1066,
    is_swimming = true,
  },
  death = {}, spells = spells, view_id = 10,
})
check(r.kind == "navigate", "early wet navigates")
check(type(r.x) == "number" and type(r.y) == "number", "has coords")
check(r.x < -5000, "early wet aims intermediate open water first")
check(r.beat_id == "wet_leg_a", "wet_leg_a first (not merchant)")
check(r.reason == "swim_wet_leg_a", "reason swim_wet_leg_a")

-- Mid coast wet: next leg not merchant if far.
r = entry.decide({
  self_unit = {
    x = -5100.0, y = -4750.0, z = -8.0, map_id = 1,
    shapeshift_form_id = 4, shapeshift_form_spell_id = 1066,
    is_swimming = true,
  },
  death = {}, spells = spells, view_id = 20,
})
check(r.kind == "navigate", "mid wet navigates")
check(r.beat_id ~= "merchant" or r.x < -2000, "not merchant while far")
check(r.x > -5600 and r.x < -3000, "mid wet intermediate beat")

-- Near merchant wet: prove hold.
r = entry.decide({
  self_unit = {
    x = -1533.7 + 20, y = -4056.5 - 20, z = -12, map_id = 1,
    shapeshift_form_id = 4, shapeshift_form_spell_id = 1066,
    is_swimming = true,
  },
  death = {}, spells = spells, view_id = 30,
})
check(r.kind == "hold" and r.reason == "merchant_coast", "merchant prove wet")

-- Unformed wet: aquatic first.
r = entry.decide({
  self_unit = {
    x = -6473.0, y = -4863.0, z = -2.3, map_id = 1,
    shapeshift_form_id = 0, is_swimming = true,
  },
  death = {}, spells = spells, view_id = 11,
})
check(r.kind == "cast_spell" and r.spell == 1066, "aquatic before wet progress")

print("test_traverse_wet_beats: " .. passed .. " ok")
