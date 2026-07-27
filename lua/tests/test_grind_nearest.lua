local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local registry = require("registry")
require("grind_nearest")
local tool = registry.get("grind_nearest")
check(tool ~= nil, "registered")

local r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 9 },
  combat = {
    in_combat = true,
    attackable = { { id = 5, guid = "9", x = 3, y = 0 } },
    casts = { { target = 5, spell = 22, name = "Shadow Bolt", spell_id = 686 } },
    focus_id = 5,
    focus_guid = "9",
    auto_attack_guid = "0",
  },
  death = {},
})
check(r.kind == "cast_spell" and r.spell == 22, "bolts nearest")

r = tool.decide({
  self_unit = { x = 0, y = 0 },
  combat = {
    attackable = { { id = 7, guid = "1", x = 2, y = 0 } },
    casts = {},
    focus_id = 0,
  },
  death = {},
})
check(r.kind == "attack_unit" and r.unit_id == 7, "melee when no cast")

-- Far hostile (>12y): approach.
r = tool.decide({
  self_unit = { x = 0, y = 0, z = 0, map_id = 0 },
  combat = {
    attackable = { { id = 11, guid = "far", x = 26, y = 0, z = 0, map_id = 0 } },
    casts = {},
    focus_id = 11,
  },
  death = {},
})
check(r.kind == "move_to_unit" and r.unit_id == 11, "approach far hostile")
check(r.reason == "approach_hostile", "approach reason")
check(r.x == 26 and r.y == 0, "approach destination")

-- Mid-range (within 12y): attack so client combat-path closes.
r = tool.decide({
  self_unit = { x = 0, y = 0 },
  combat = {
    attackable = { { id = 9, guid = "mid", x = 10, y = 0 } },
    casts = {},
    focus_id = 0,
  },
  death = {},
})
check(r.kind == "attack_unit" and r.unit_id == 9, "attack mid-range hostile")

-- Prefer nearer unit over far focus.
r = tool.decide({
  self_unit = { x = 0, y = 0 },
  combat = {
    attackable = {
      { id = 11, guid = "far", x = 26, y = 0 },
      { id = 5, guid = "near", x = 3, y = 0 },
    },
    casts = {},
    focus_id = 11,
  },
  death = {},
})
check(r.kind == "attack_unit" and r.unit_id == 5, "prefer nearest over far focus")

r = tool.decide({
  self_unit = { x = 0, y = 0 },
  combat = { attackable = {}, casts = {} },
  death = {},
})
check(r.kind == "hold", "hold without hostiles")

-- v2: nuke from frame.spells (no per-target cast mask), highest known rank.
r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 9 },
  combat = {
    attackable = { { id = 3, x = 4, y = 0 } },
    casts = {},
    focus_id = 0,
  },
  spells = { known = { 686, 695 }, cooldowns = {}, mana_pct = 80 },
  death = {},
})
check(r.kind == "cast_spell" and r.spell == 695 and r.unit_id == 3,
  "v2 highest known Shadow Bolt rank")

-- v2: dry mana falls back to melee.
r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 9 },
  combat = {
    attackable = { { id = 3, x = 4, y = 0 } },
    casts = {},
    focus_id = 0,
  },
  spells = { known = { 686 }, cooldowns = {}, mana_pct = 4 },
  death = {},
})
check(r.kind == "attack_unit" and r.unit_id == 3, "v2 melee when OOM")

-- v2: cooldown skips to lower rank; unknown class melees.
r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 5 },
  combat = {
    attackable = { { id = 2, x = 4, y = 0 } },
    casts = {},
    focus_id = 0,
  },
  spells = { known = { 585, 591 }, cooldowns = { 591 }, mana_pct = 50 },
  death = {},
})
check(r.kind == "cast_spell" and r.spell == 585, "v2 cooldown skips rank")

r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 1 },
  combat = {
    attackable = { { id = 2, x = 4, y = 0 } },
    casts = {},
    focus_id = 0,
  },
  spells = { known = { 78 }, cooldowns = {}, mana_pct = 100 },
  death = {},
})
check(r.kind == "attack_unit", "v2 warrior melees")

print("test_grind_nearest: " .. passed .. " checks passed")
