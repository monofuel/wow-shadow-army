-- Unit tests for warlock_imp_quest (real registry decide, synthetic frames).

local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local registry = require("registry")
require("warlock_imp_quest")

local tool = registry.get("warlock_imp_quest")
check(tool ~= nil, "tool registered")

local function frame(opts)
  opts = opts or {}
  return {
    self_unit = opts.self_unit or { class_id = 9, x = 0, y = 0 },
    quest = opts.quest or {},
    combat = opts.combat or {
      in_combat = false,
      attackable = {},
      casts = {},
      focus_guid = "0",
      auto_attack_guid = "0",
    },
    abilities = opts.abilities,
  }
end

-- Non-warlock holds.
local r = tool.decide(frame({ self_unit = { class_id = 1 } }))
check(r.kind == "hold" and r.reason == "not_warlock", "non-warlock holds")

-- Accept when offer masked.
r = tool.decide(frame({
  quest = {
    offers = { { id = 1470, entity_id = 12 } },
  },
}))
check(r.kind == "accept_quest", "accept when offer present")
check(r.quest_id == 1470, "accept quest id 1470")
check(r.unit_id == 12, "accept targets questgiver entity")
check(r.reason == "accept_piercing_the_veil", "accept reason")

-- Turn-in when complete surface offered.
r = tool.decide(frame({
  quest = {
    turn_ins = { { id = 1470, entity_id = 12 } },
    active = { { id = 1470, complete = true } },
  },
}))
check(r.kind == "turn_in_quest", "turn_in when ready")
check(r.quest_id == 1470 and r.unit_id == 12, "turn_in fields")
check(r.reason == "turn_in_piercing_the_veil", "turn_in reason")

-- Turn-in beats accept if both present.
r = tool.decide(frame({
  quest = {
    offers = { { id = 1470, entity_id = 12 } },
    turn_ins = { { id = 1470, entity_id = 12 } },
  },
}))
check(r.kind == "turn_in_quest", "turn_in priority over accept")

-- Summon Imp when ability/cast masked (quest reward learned).
r = tool.decide(frame({
  abilities = { summon_imp = { spell = 40 } },
  quest = {
    active = { { id = 1470, complete = true } },
  },
}))
check(r.kind == "cast_spell" and r.spell == 40 and r.unit_id == 0, "summon imp ability")
check(r.reason == "summon_imp", "summon reason")

r = tool.decide(frame({
  combat = {
    casts = {
      { target = 0, spell = 41, name = "Summon Imp", spell_id = 688 },
    },
    attackable = {},
    focus_guid = "0",
    auto_attack_guid = "0",
  },
}))
check(r.kind == "cast_spell" and r.spell == 41, "summon imp from cast mask")

-- Active incomplete: loot before combat.
r = tool.decide(frame({
  quest = {
    active = { { id = 1470, complete = false, item_count = 1 } },
  },
  combat = {
    in_combat = false,
    focus_guid = "0",
    attackable = {
      { id = 5, guid = "99", x = 3, y = 0, lootable = true },
      { id = 6, guid = "100", x = 4, y = 0 },
    },
    casts = {
      { target = 6, spell = 22, name = "Shadow Bolt", spell_id = 686 },
    },
  },
}))
check(r.kind == "loot_unit" and r.unit_id == 5, "loot before grind")
check(r.reason == "loot_skull_corpse", "loot reason")

-- Active incomplete: bolt focus.
r = tool.decide(frame({
  quest = {
    active = { { id = 1470, complete = false, item_count = 1 } },
  },
  combat = {
    in_combat = true,
    focus_guid = "99",
    auto_attack_guid = "0",
    attackable = { { id = 5, guid = "99", x = 3, y = 0 } },
    casts = {
      { target = 5, spell = 22, name = "Shadow Bolt", spell_id = 686 },
    },
  },
}))
check(r.kind == "cast_spell" and r.spell == 22, "grind bolts focus")
check(r.reason and tostring(r.reason):find("imp_quest_grind", 1, true), "grind reason")

-- Active incomplete, no casts: melee.
r = tool.decide(frame({
  quest = {
    active = { { id = 1470, complete = false, item_count = 0 } },
  },
  combat = {
    in_combat = true,
    focus_guid = "99",
    attackable = { { id = 5, guid = "99", x = 2, y = 0 } },
    casts = {},
  },
}))
check(r.kind == "attack_unit" and r.unit_id == 5, "grind melee fallback")

-- Far skull mob: approach.
r = tool.decide(frame({
  quest = {
    active = { { id = 1470, complete = false, item_count = 0 } },
  },
  combat = {
    attackable = { { id = 11, guid = "far", x = 30, y = 0, z = 5, map_id = 0 } },
    casts = {},
  },
}))
check(r.kind == "move_to_unit" and r.unit_id == 11, "approach far skull mob")
check(r.reason == "approach_skull_mob", "approach skull reason")

-- Active incomplete, no mobs: hold need_mobs.
r = tool.decide(frame({
  quest = {
    active = { { id = 1470, complete = false, item_count = 2 } },
  },
  combat = {
    attackable = {},
    casts = {},
    focus_guid = "0",
    auto_attack_guid = "0",
  },
}))
check(r.kind == "hold", "hold when no mobs")
check(r.reason and tostring(r.reason):find("need_mobs", 1, true), "need_mobs reason")

-- Complete without turn_in mask: interact if entity known.
r = tool.decide(frame({
  quest = {
    active = { { id = 1470, complete = true, entity_id = 12 } },
  },
}))
check(r.kind == "interact_unit" and r.unit_id == 12, "interact turnin npc")

-- Complete: nearest interactable unit when no entity_id.
r = tool.decide(frame({
  self_unit = { class_id = 9, x = 0, y = 0, z = 0 },
  quest = {
    active = { { id = 1470, complete = true } },
    interactables = {
      { id = 44, kind = "unit", x = 2, y = 0, z = 0 },
      { id = 99, kind = "unit", x = 40, y = 0, z = 0 },
    },
  },
}))
check(r.kind == "interact_unit" and r.unit_id == 44, "interact nearest turnin npc")

-- Empty quest surface: masks unavailable path.
r = tool.decide(frame({
  quest = { masks_empty = true },
}))
check(r.kind == "hold" and r.reason == "quest_masks_unavailable", "masks unavailable")

-- Idle without flags.
r = tool.decide(frame({ quest = {} }))
check(r.kind == "hold" and r.reason == "imp_quest_idle", "idle hold")

print("test_warlock_imp_quest: " .. passed .. " checks passed")
