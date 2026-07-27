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

-- Alive with no self still nil (legacy).
check(tool.decide({}, nil) == nil, "nil without self")
local r = tool.decide(frame(me, nil))
check(r.kind == "hold" and r.reason == "leader_not_visible", "hold when leaderless")

-- Dead (not ghost): release_spirit when allowed.
r = tool.decide({
  self_unit = me,
  party = { leader_unit = leader_near },
  combat = { casts = {}, mana_pct = 0, health_pct = 0, attackable = {} },
  death = {
    is_dead = true,
    is_ghost = false,
    can_release_spirit = true,
    can_reclaim_corpse = false,
    can_reclaim_action = false,
    can_move = false,
    corpse_known = false,
  },
})
check(r.kind == "release_spirit", "dead selects release_spirit")

-- Dead but release not masked: hold waiting.
r = tool.decide({
  self_unit = me,
  party = { leader_unit = leader_near },
  combat = { casts = {}, mana_pct = 0, health_pct = 0, attackable = {} },
  death = {
    is_dead = true,
    is_ghost = false,
    can_release_spirit = false,
    can_reclaim_corpse = false,
    can_reclaim_action = false,
    can_move = false,
    corpse_known = false,
  },
})
check(r.kind == "hold" and r.reason == "dead_waiting_release", "dead holds without release mask")

-- Ghost + reclaim ready.
r = tool.decide({
  self_unit = me,
  party = { leader_unit = leader_near },
  combat = { casts = {}, mana_pct = 0, health_pct = 0, attackable = {} },
  death = {
    is_dead = false,
    is_ghost = true,
    can_release_spirit = false,
    can_reclaim_corpse = true,
    can_reclaim_action = true,
    can_move = true,
    corpse_known = true,
    corpse = { map_id = 0, x = 1, y = 2, z = 3 },
  },
})
check(r.kind == "reclaim_corpse", "ghost reclaim when ready")

-- Ghost not reclaimable: hop toward corpse when far (avoids long blocked moves).
r = tool.decide({
  self_unit = { x = 1965, y = 1729, z = 94, map_id = 0 },
  party = { leader_unit = leader_near },
  combat = { casts = {}, mana_pct = 0, health_pct = 0, attackable = {} },
  death = {
    is_dead = false,
    is_ghost = true,
    can_release_spirit = false,
    can_reclaim_corpse = false,
    can_reclaim_action = false,
    can_move = true,
    corpse_known = true,
    corpse = { map_id = 0, x = 2040, y = 1840, z = 106 },
  },
})
check(r.kind == "move_to_corpse", "ghost moves toward corpse")
check(r.reason == "move_to_corpse_hop", "far corpse uses hop")
check(r.x > 1965 and r.x < 2040, "hop x between self and corpse")
check(r.y > 1729 and r.y < 1840, "hop y between self and corpse")

-- Ghost close to corpse: go to body directly.
r = tool.decide({
  self_unit = { x = 2035, y = 1835, z = 105, map_id = 0 },
  party = { leader_unit = leader_near },
  combat = { casts = {}, mana_pct = 0, health_pct = 0, attackable = {} },
  death = {
    is_dead = false,
    is_ghost = true,
    can_release_spirit = false,
    can_reclaim_corpse = false,
    can_reclaim_action = false,
    can_move = true,
    corpse_known = true,
    corpse = { map_id = 0, x = 2040, y = 1840, z = 106 },
  },
})
check(r.kind == "move_to_corpse" and r.x == 2040 and r.z == 106, "near corpse goes direct")
check(r.reason == "move_to_corpse", "near corpse reason is direct")

-- Ghost blocked (no corpse point, no reclaim): hold.
r = tool.decide({
  self_unit = me,
  party = { leader_unit = leader_near },
  combat = { casts = {}, mana_pct = 0, health_pct = 0, attackable = {} },
  death = {
    is_dead = false,
    is_ghost = true,
    can_release_spirit = false,
    can_reclaim_corpse = false,
    can_reclaim_action = false,
    can_move = false,
    corpse_known = false,
  },
})
check(r.kind == "hold" and r.reason == "ghost_waiting_corpse", "ghost holds when blocked")

-- Death intents beat escort even with leader missing.
r = tool.decide({
  death = {
    is_dead = true,
    is_ghost = false,
    can_release_spirit = true,
  },
})
check(r.kind == "release_spirit", "release without leader/self")

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

-- In combat, focus, no cast mask, no xy: casters approach (not free-fire).
r = tool.decide(frame(me, leader_near, {
  in_combat = true,
  mana_pct = 50,
  health_pct = 90,
  focus_guid = "99",
  auto_attack_guid = "0",
  attackable = { { id = 5, guid = "99" } },
  casts = {},
}))
check(r.kind == "move_to_unit" and r.unit_id == 5, "caster approaches focus when no cast")
check(r.reason == "approach_cast_range", "approach_cast_range reason")

-- Tank in combat, focus, no cast: melee fallback.
r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 1 },
  party = { leader_unit = leader_near },
  combat = {
    in_combat = true,
    mana_pct = 0,
    health_pct = 90,
    focus_guid = "99",
    auto_attack_guid = "0",
    attackable = { { id = 5, guid = "99", x = 2, y = 0 } },
    casts = {},
  },
})
check(r.kind == "attack_unit" and r.unit_id == 5, "tank melees when engaged")
check(r.reason == "defend_melee_fallback" or r.reason == "tank_melee", "tank melee reason")

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

-- Same floor with z: always destination rejoin (stock follow sticks on WMO).
r = tool.decide(frame(
  { x = 1650, y = 1670, z = 120.5, map_id = 0 },
  { id = 2, x = 1660, y = 1670, z = 120.6, map_id = 0, visible = true, assistable = true },
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
check(r.kind == "move_to_unit" and r.z ~= nil, "same-floor rejoin uses dest when z known")
check(r.unit_id == 2, "same-floor rejoin targets leader unit")
check(r.reason and tostring(r.reason):find("dest", 1, true), "dest reason tag")

-- Urgent/far: destination.
r = tool.decide(frame(
  { x = 1650, y = 1670, z = 120.5, map_id = 0 },
  { id = 2, x = 1750, y = 1670, z = 120.6, map_id = 0, visible = true, assistable = true },
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
check(r.kind == "move_to_unit" and r.z ~= nil, "urgent far rejoin uses dest")
check(r.reason and tostring(r.reason):find("urgent", 1, true), "urgent dest reason")

-- No leader z: stock follow (no xyz on intent).
r = tool.decide(frame(
  { x = 0, y = 0 },
  { id = 2, x = 40, y = 0, visible = true, assistable = true },
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
check(r.kind == "move_to_unit" and r.z == nil, "no-z rejoin is stock follow")

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

-- OOM, no shoot, focus in melee band: swing.
r = tool.decide(frame(me, leader_near, {
  in_combat = true,
  mana_pct = 3,
  health_pct = 90,
  focus_guid = "99",
  auto_attack_guid = "0",
  attackable = { { id = 5, guid = "99", x = 2, y = 0 } },
  casts = {},
}))
check(r.kind == "attack_unit" and r.unit_id == 5, "attack when oom with no wand")
check(
  r.reason == "dagger_oom_only"
    or r.reason == "defend_melee_fallback"
    or r.reason == "caster_melee_band",
  "oom attack reason"
)

-- OOM, no shoot, focus far: approach cast range (not OOR melee thrash).
r = tool.decide(frame(me, leader_near, {
  in_combat = true,
  mana_pct = 3,
  health_pct = 90,
  focus_guid = "99",
  auto_attack_guid = "0",
  attackable = { { id = 5, guid = "99", x = 20, y = 0 } },
  casts = {},
}))
check(r.kind == "move_to_unit" and r.unit_id == 5, "oom far focus approaches")

-- In combat, no focus: assist once when attackable empty.
r = tool.decide(frame(me, leader_near, {
  in_combat = true,
  mana_pct = 80,
  health_pct = 90,
  focus_guid = "0",
  auto_attack_guid = "0",
  attackable = {},
  casts = {},
}))
check(r.kind == "assist_unit" and r.unit_id == 2, "assist without focus when in combat")

-- Defensive: in combat, no focus, but attackable hostiles — bolt nearest.
r = tool.decide(frame(me, leader_near, {
  in_combat = true,
  mana_pct = 80,
  health_pct = 90,
  focus_guid = "0",
  auto_attack_guid = "0",
  attackable = {
    { id = 9, guid = "90", x = 50, y = 0 },
    { id = 5, guid = "50", x = 5, y = 0 },
  },
  casts = {
    { target = 5, spell = 22, name = "Shadow Bolt", spell_id = 686 },
    { target = 9, spell = 22, name = "Shadow Bolt", spell_id = 686 },
  },
}))
check(r.kind == "cast_spell" and r.unit_id == 5, "defensive picks nearest attackable")

-- OOC in formation: HOLD — never spam assist (was freezing follow + chat).
r = tool.decide(frame(me, leader_near, {
  in_combat = false,
  mana_pct = 80,
  health_pct = 90,
  focus_guid = "0",
  auto_attack_guid = "0",
  attackable = {},
  casts = {},
}))
check(r.kind == "hold" or r.kind == "cast_spell", "OOC in formation does not assist-spam")

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

-- === Role-aware combat (tank / healer / dps) ===

-- Warlock DPS still bolts with class_id=9.
r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 9 },
  party = { leader_unit = leader_near },
  combat = {
    in_combat = true,
    mana_pct = 80,
    health_pct = 90,
    focus_guid = "99",
    auto_attack_guid = "0",
    attackable = { { id = 5, guid = "99" } },
    casts = {
      { target = 5, spell = 22, name = "Shadow Bolt", spell_id = 686 },
    },
  },
})
check(r.kind == "cast_spell" and r.spell == 22, "warlock dps bolts")
check(r.reason and tostring(r.reason):find("shadow", 1, true), "warlock reason")

-- Warrior tank: attack_unit when threat casts absent.
r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 1 },
  party = { leader_unit = leader_near },
  combat = {
    in_combat = true,
    mana_pct = 0,
    health_pct = 90,
    focus_guid = "99",
    auto_attack_guid = "0",
    attackable = { { id = 5, guid = "99", x = 2, y = 0 } },
    casts = {},
  },
})
check(r.kind == "attack_unit" and r.unit_id == 5, "tank melees focus")
check(r.reason == "tank_melee", "tank_melee reason")

-- Warrior tank: heroic strike when offered.
r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 1 },
  party = { leader_unit = leader_near },
  combat = {
    in_combat = true,
    mana_pct = 0,
    health_pct = 90,
    focus_guid = "99",
    auto_attack_guid = "0",
    attackable = { { id = 5, guid = "99" } },
    casts = {
      { target = 5, spell = 11, name = "Heroic Strike", spell_id = 78 },
    },
  },
})
check(r.kind == "cast_spell" and r.spell == 11, "tank heroic strike")
check(r.reason and tostring(r.reason):find("tank_threat", 1, true), "tank threat reason")

-- Priest healer: lesser heal when offered.
r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 5 },
  party = { leader_unit = leader_near },
  combat = {
    in_combat = true,
    mana_pct = 80,
    health_pct = 40,
    focus_guid = "99",
    auto_attack_guid = "0",
    attackable = { { id = 5, guid = "99" } },
    casts = {
      { target = 0, spell = 7, name = "Lesser Heal", spell_id = 2050 },
      { target = 5, spell = 22, name = "Smite", spell_id = 585 },
    },
  },
})
check(r.kind == "cast_spell" and r.spell == 7, "healer heals first")
check(r.reason and tostring(r.reason):find("heal", 1, true), "heal reason")

-- OOC: assist leader only — never open on ambient hostiles.
r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 1 },
  party = { leader_unit = leader_near },
  combat = {
    in_combat = false,
    mana_pct = 0,
    health_pct = 100,
    focus_guid = "0",
    auto_attack_guid = "0",
    attackable = { { id = 5, guid = "99", x = 3, y = 0 } },
    casts = {},
  },
})
check(r.kind == "assist_unit", "OOC assists leader only")
check(r.reason == "mirror_leader_ooc", "mirror_leader_ooc reason")

-- Death still beats tank combat.
r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 1 },
  party = { leader_unit = leader_near },
  combat = {
    in_combat = true,
    attackable = { { id = 5, guid = "99" } },
    casts = {},
  },
  death = {
    is_dead = true,
    is_ghost = false,
    can_release_spirit = true,
  },
})
check(r.kind == "release_spirit", "death beats tank combat")

-- OOC stale focus + SB on random target: MUST NOT free-fire (assist or hold).
r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 9 },
  party = { leader_unit = leader_near },
  combat = {
    in_combat = false,
    mana_pct = 100,
    health_pct = 100,
    focus_guid = "56",
    focus_id = 56,
    auto_attack_guid = "0",
    attackable = {
      { id = 56, guid = "56", x = 40, y = 0 },
      { id = 27, guid = "27", x = 5, y = 0 },
    },
    casts = {
      { target = 27, spell = 22, name = "Shadow Bolt", spell_id = 686 },
    },
  },
})
check(r.kind ~= "cast_spell", "OOC never free-fires cast masks")
check(r.kind == "assist_unit" or r.kind == "hold", "OOC assist or hold only")

-- Tank 40yd from leader while in combat: HARD rejoin beats melee thrash.
r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 1 },
  party = { leader_unit = leader_far },
  combat = {
    in_combat = true,
    mana_pct = 0,
    health_pct = 100,
    focus_guid = "99",
    auto_attack_guid = "99",
    attackable = { { id = 5, guid = "99", x = 2, y = 0 } },
    casts = {},
  },
})
check(r.kind == "move_to_unit", "far tank rejoins leader over melee")
check(r.reason and tostring(r.reason):find("rejoin_far", 1, true), "rejoin_far reason")

-- Priest OOC with Smite offered on ambient: do NOT open fire.
r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 5 },
  party = { leader_unit = leader_near },
  combat = {
    in_combat = false,
    mana_pct = 100,
    health_pct = 100,
    focus_guid = "0",
    auto_attack_guid = "0",
    attackable = { { id = 9, guid = "9", x = 6, y = 0 } },
    casts = {
      { target = 9, spell = 18, name = "Smite", spell_id = 585 },
    },
  },
})
check(r.kind ~= "cast_spell" or r.unit_id ~= 9, "priest OOC does not smite neutrals")
check(r.kind == "assist_unit" or r.kind == "hold" or (r.kind == "cast_spell" and r.unit_id == 0),
  "priest OOC assist/buff/hold only")

-- Engaged warlock with SB on focus: bolt, do not melee thrash.
r = tool.decide({
  self_unit = { x = 0, y = 0, class_id = 9 },
  party = { leader_unit = leader_near },
  combat = {
    in_combat = true,
    mana_pct = 80,
    health_pct = 90,
    focus_guid = "99",
    auto_attack_guid = "0",
    attackable = { { id = 5, guid = "99", x = 18, y = 0 } },
    casts = {
      { target = 5, spell = 22, name = "Shadow Bolt", spell_id = 686 },
    },
  },
})
check(r.kind == "cast_spell" and r.spell == 22, "engaged warlock bolts focus")

print("OK " .. passed .. " checks")
