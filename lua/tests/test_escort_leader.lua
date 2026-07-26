-- Unit tests for escort_leader (caster-first warlock escort).

local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local registry = require("registry")
require("escort_leader")

local tool = registry.get("escort_leader")
check(tool ~= nil, "tool registered")

local function frame(me, leader, combat)
  return {
    self_unit = me,
    party = { leader_unit = leader },
    combat = combat or {},
  }
end

local leader_near = { id = 2, x = 3, y = 0, visible = true, assistable = true }
local leader_far = { id = 2, x = 40, y = 0, visible = true, assistable = true }
local me = { x = 0, y = 0 }

check(tool.decide({}, nil) == nil, "nil without self")
local r = tool.decide(frame(me, nil))
check(r.kind == "hold" and r.reason == "leader_not_visible", "hold when leaderless")

-- Focused + bolt: cast even when slightly far of "near" if within combat rejoin
-- (40yd is still rejoin — cast only when we don't rejoin first). At 40yd with
-- bolt: still rejoin (beyond COMBAT_REJOIN 28). At 20yd with bolt: cast.
r = tool.decide(frame(me, { id = 2, x = 20, y = 0, visible = true, assistable = true }, {
  in_combat = true,
  mana_pct = 80,
  health_pct = 90,
  focus_guid = "99",
  focus_id = 5,
  auto_attack_guid = "0",
  attackable = { { id = 5, guid = "99" } },
  casts = {
    { target = 5, spell = 22, name = "Shadow Bolt", spell_id = 686 },
  },
}))
check(r.kind == "cast_spell" and r.spell == 22, "cast bolt before rejoin when in range band")

r = tool.decide(frame(me, leader_far, {
  in_combat = false,
  mana_pct = 100,
  health_pct = 100,
  focus_guid = "0",
  auto_attack_guid = "0",
  attackable = {},
  casts = {},
}))
check(r.kind == "move_to_unit", "rejoin when no combat cast")

-- Shadow Bolt when only bolt is offered.
r = tool.decide(frame(me, leader_near, {
  in_combat = true,
  mana_pct = 80,
  health_pct = 90,
  focus_guid = "99",
  auto_attack_guid = "0",
  attackable = { { id = 5, guid = "99" } },
  casts = {
    { target = 5, spell = 22, name = "Shadow Bolt", spell_id = 686 },
  },
}))
check(r.kind == "cast_spell" and r.spell == 22 and r.unit_id == 5, "casts shadow bolt")

-- DoT before bolt.
r = tool.decide(frame(me, leader_near, {
  in_combat = true,
  mana_pct = 80,
  health_pct = 90,
  focus_guid = "99",
  auto_attack_guid = "0",
  attackable = { { id = 5, guid = "99" } },
  casts = {
    { target = 5, spell = 22, name = "Shadow Bolt", spell_id = 686 },
    { target = 5, spell = 30, name = "Corruption", spell_id = 172 },
    { target = 5, spell = 32, name = "Curse of Agony", spell_id = 980 },
  },
}))
check(r.spell == 32, "curse of agony first")

-- Mana remaining, no cast mask: refresh target / follow — do NOT dagger.
r = tool.decide(frame(me, leader_near, {
  in_combat = true,
  mana_pct = 50,
  health_pct = 90,
  focus_guid = "99",
  auto_attack_guid = "0",
  attackable = { { id = 5, guid = "99" } },
  casts = {},
}))
check(r.kind ~= "attack_unit", "no dagger with mana")
check(r.kind == "assist_unit" or r.kind == "move_to_unit" or r.kind == "hold", "stay mobile or refresh")

-- Stale focus_id (not attackable, no casts, not in combat): follow when leader far.
r = tool.decide(frame(me, leader_far, {
  in_combat = false,
  mana_pct = 100,
  health_pct = 100,
  focus_guid = "0",
  focus_id = 31,
  auto_attack_guid = "0",
  attackable = {},
  casts = {},
}))
check(r.kind == "move_to_unit", "stale focus must not block follow")

-- Random SB on non-focus must NOT fire (no free-fire on rats).
r = tool.decide(frame(me, leader_near, {
  in_combat = true,
  mana_pct = 80,
  health_pct = 90,
  focus_guid = "0",
  focus_id = 0,
  auto_attack_guid = "0",
  attackable = {},
  casts = {
    { target = 9, spell = 22, name = "Shadow Bolt", spell_id = 686 },
  },
}))
check(r.kind ~= "cast_spell" or r.unit_id ~= 9, "no free-fire on random hostiles")

-- Vertical rejoin uses destination coords (crypt floors).
r = tool.decide(frame(
  { x = 1656, y = 1662, z = 141, map_id = 0 },
  { id = 2, x = 1644, y = 1662, z = 132, map_id = 0, visible = true, assistable = true },
  {
    in_combat = false,
    mana_pct = 100,
    health_pct = 100,
    focus_guid = "0",
    auto_attack_guid = "0",
    attackable = {},
    casts = {},
  }
))
check(r.kind == "move_to_unit" and r.z == 132, "crypt vertical rejoin has z dest")
check(r.reason and tostring(r.reason):find("vertical", 1, true), "vertical rejoin reason")

-- Same floor with z known: stock follow (no frozen xyz) so bots track live.
r = tool.decide(frame(
  { x = 1650, y = 1670, z = 120.5, map_id = 0 },
  { id = 2, x = 1670, y = 1670, z = 120.6, map_id = 0, visible = true, assistable = true },
  {
    in_combat = false,
    mana_pct = 100,
    health_pct = 100,
    focus_guid = "0",
    auto_attack_guid = "0",
    attackable = {},
    casts = {},
  }
))
check(r.kind == "move_to_unit" and r.z == nil, "same-floor rejoin is follow not dest")
check(r.unit_id == 2, "same-floor rejoin targets leader unit")

-- OOM: Shoot over dagger.
r = tool.decide(frame(me, leader_near, {
  in_combat = true,
  mana_pct = 5,
  health_pct = 90,
  focus_guid = "99",
  auto_attack_guid = "0",
  attackable = { { id = 5, guid = "99" } },
  casts = {
    { target = 5, spell = 13, name = "Shoot", spell_id = 5019 },
  },
}))
check(r.spell == 13 and tostring(r.reason):find("wand", 1, true) ~= nil, "wand when oom")

-- OOM, no shoot: dagger allowed.
r = tool.decide(frame(me, leader_near, {
  in_combat = true,
  mana_pct = 3,
  health_pct = 90,
  focus_guid = "99",
  auto_attack_guid = "0",
  attackable = { { id = 5, guid = "99" } },
  casts = {},
}))
check(r.kind == "attack_unit" and r.reason == "dagger_oom_only", "dagger only when oom")

-- No focus: assist.
r = tool.decide(frame(me, leader_near, {
  in_combat = true,
  mana_pct = 80,
  health_pct = 90,
  focus_guid = "0",
  auto_attack_guid = "0",
  attackable = {},
  casts = {},
}))
check(r.kind == "assist_unit" and r.unit_id == 2, "assist without focus")

-- Life Tap when dry.
r = tool.decide(frame(me, leader_near, {
  in_combat = true,
  mana_pct = 10,
  health_pct = 80,
  focus_guid = "99",
  auto_attack_guid = "0",
  attackable = { { id = 5, guid = "99" } },
  casts = {
    { target = 0, spell = 40, name = "Life Tap", spell_id = 1454 },
    { target = 5, spell = 22, name = "Shadow Bolt", spell_id = 686 },
  },
}))
check(r.spell == 40 and r.unit_id == 0, "life tap when dry")

-- OOC demon skin when no combat cast.
r = tool.decide(frame(me, leader_near, {
  in_combat = false,
  mana_pct = 100,
  health_pct = 100,
  focus_guid = "0",
  auto_attack_guid = "0",
  attackable = {},
  casts = {
    { target = 0, spell = 25, name = "Demon Skin", spell_id = 687 },
  },
}))
check(r.kind == "cast_spell" and r.spell == 25, "demon skin ooc")

print("test_escort_leader: " .. passed .. " checks passed")
