package.path = "lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;"

local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local clock = 0.0
local nav = { state = "following", failed_here = false, walkout_available = false }
_G.wow = {
  log = function() end,
  set_status = function() end,
  time = function() return clock end,
  nav_progress = function() return nav end,
}

local grind = require("accelerated")

local function unit(guid, distance, level, extra)
  local u = {
    guid = guid,
    name = "mob" .. guid,
    distance = distance,
    level_known = true,
    level = level,
    player_can_attack = true,
    death_known = true,
    is_dead = false,
    health_known = true,
    health = 40,
    max_health = 40,
    creature_rank_known = true,
    creature_rank = 0,
    creature_type_known = true,
    creature_type = 1,
    is_tapped = false,
    tapped_by_player = false,
    summoner_guid = 0,
    location = { map_id = 1, position = { x = 0, y = 0, z = 50, o = 0 } },
  }
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end

local function view(units, extra)
  local v = {
    location_known = true,
    location = { map_id = 1, position = { x = 0.0, y = 0.0, z = 50.0, o = 0.0 } },
    level = 3,
    class_id = 11,
    units = units,
    auto_attack_guid = 0,
    in_combat = false,
    is_dead = false,
    is_ghost = false,
    resurrect_offer_guid = 0,
    movement_allowed = true,
    rooted = false,
    health_known = true,
    health = 100,
    max_health = 100,
    powers = { 100 },
    max_powers = { 100 },
    combat_kill_events = {},
    action_buttons = {
      { slot = 1, spell_id = 5176, usable = true, usable_known = true, in_range = true },
      { slot = 2, spell_id = 1126, usable = true, usable_known = true },
    },
  }
  for k, v2 in pairs(extra or {}) do v[k] = v2 end
  return v
end

-- The buff is worth one cast per life before anything else happens.
local opener = grind.decide(view({ unit(11, 10.0, 3) }))
check(opener.kind == "cast_spell" and opener.spell == 1126, "buffs once at spawn")

local near = grind.decide(view({ unit(11, 25.0, 3), unit(22, 8.0, 2) }))
check(near.kind == "attack", "attacks after buffing")
check(near.guid == 22, "picks the nearest")
check(near.spell == 5176, "opens with Wrath at full mana")
check(near.route_profile == "prefer_ground", "travel prefers walkable ground")

-- Dangerous or worthless targets are skipped.
check(grind.decide(view({ unit(33, 5.0, 3, { creature_rank = 1 }) })).kind == "navigate",
  "skips elites")
check(grind.decide(view({ unit(34, 5.0, 3, { is_tapped = true }) })).kind == "navigate",
  "skips mobs tapped by others")
check(grind.decide(view({ unit(35, 5.0, 3, { creature_type = 8 }) })).kind == "navigate",
  "skips critters")
check(grind.decide(view({ unit(36, 5.0, 3, { summoner_guid = 99 }) })).kind == "navigate",
  "skips summoned pets")
check(grind.decide(view({ unit(37, 5.0, 9) })).kind == "navigate",
  "refuses a fresh pull above the level ceiling")
check(grind.decide(view({ unit(38, 5.0, 5) })).kind == "attack",
  "takes a pull two levels up")

-- Wounded or drained: walk to the next spawn instead of pulling.
local drained = grind.decide(view({ unit(41, 6.0, 2) }, { powers = { 10 } }))
check(drained.kind == "navigate" and drained.reason == "recover_walk",
  "walks to recover rather than pulling on empty mana")
local hurt = grind.decide(view({ unit(42, 6.0, 2) }, { health = 40 }))
check(hurt.reason == "recover_walk", "walks to recover on low health")

-- Already engaged: keep swinging even while hurt, and skip the nuke on fumes.
local engagedView = view({ unit(51, 3.0, 3) },
  { auto_attack_guid = 51, in_combat = true, health = 40, powers = { 20 } })
local engaged = grind.decide(engagedView)
check(engaged.kind == "attack" and engaged.guid == 51, "stays on the engaged mob")
check(engaged.spell == nil, "no nuke below the mana floor")

-- Melee fillers: the host closes first, then presses the bar button.
local warrior = grind.decide(view({ unit(81, 5.0, 3) }, {
  class_id = 1,
  action_buttons = {
    { slot = 1, spell_id = 78, usable = true, usable_known = true },
  },
}))
check(warrior.kind == "attack" and warrior.spell == 78,
  "warrior fills with Heroic Strike")

local charged = grind.decide(view({ unit(84, 15.0, 3) }, {
  class_id = 1,
  action_buttons = {
    { slot = 1, spell_id = 100, usable = true, usable_known = true,
      in_range = true, in_range_known = true, range_min = 8, range_max = 25 },
    { slot = 2, spell_id = 78, usable = true, usable_known = true },
  },
}))
check(charged.kind == "attack" and charged.spell == 100 and
  charged.reason == "charge",
  "warrior Charges from mid range")
check(charged.stop_distance == 25.0, "Charge stop stays at Charge max range")

local meleeCharge = grind.decide(view({ unit(85, 3.0, 3) }, {
  class_id = 1,
  in_combat = true,
  auto_attack_guid = 85,
  action_buttons = {
    { slot = 1, spell_id = 100, usable = true, usable_known = true },
    { slot = 2, spell_id = 78, usable = true, usable_known = true },
  },
}))
check(meleeCharge.kind == "attack" and meleeCharge.spell == 78,
  "warrior does not Charge in melee; fills with Heroic Strike")

local mageNoCharge = grind.decide(view({ unit(86, 15.0, 3) }, {
  class_id = 8,
  action_buttons = {
    { slot = 1, spell_id = 100, usable = true, usable_known = true,
      in_range = true, in_range_known = true },
    { slot = 2, spell_id = 133, usable = true, usable_known = true },
  },
}))
check(mageNoCharge.spell ~= 100, "non-warrior does not Charge")
check(mageNoCharge.spell == 133 and mageNoCharge.stop_distance == 22.0,
  "mage stands at Fireball range instead of walking into melee")
check(mageNoCharge.reason == "mage_nuke", "mage filler reason is mage_nuke")

-- Rakan: a bolt that is ready must not walk into 2yd staff range, even
-- under the old 35% mana floor, and even while the cast is movement-locked.
grind.reset()
local mageMelee = grind.decide(view({ unit(87, 2.0, 2) }, {
  class_id = 8,
  in_combat = true,
  auto_attack_guid = 87,
  powers = { 20 },
  action_buttons = {
    { slot = 2, spell_id = 133, usable = true, usable_known = true },
  },
}))
check(mageMelee.kind == "attack" and mageMelee.spell == 133 and
  mageMelee.stop_distance == 22.0,
  "mage Fireballs from 2yd even below the mana floor")

local mageWalking = grind.decide(view({ unit(88, 2.0, 2) }, {
  class_id = 8,
  in_combat = true,
  auto_attack_guid = 88,
  is_moving = true,
  action_buttons = {
    { slot = 2, spell_id = 133, usable = false, usable_known = true,
      not_enough_mana = false, movement_inhibits_cast_start = true },
    { slot = 5, spell_id = 5019, usable = true, usable_known = true },
  },
}))
check(mageWalking.kind == "attack" and mageWalking.spell == nil and
  mageWalking.stop_distance == 22.0 and mageWalking.reason == "mage_hold_range",
  "a movement-locked Fireball holds caster range instead of wanding or melee")

local mageFrost = grind.decide(view({ unit(89, 18.0, 2) }, {
  class_id = 8,
  action_buttons = {
    { slot = 2, spell_id = 116, usable = true, usable_known = true },
  },
}))
check(mageFrost.spell == 116 and mageFrost.stop_distance == 22.0,
  "mage fills with Frostbolt when that is the bolt on the bar")

local mageOom = grind.decide(view({ unit(90, 8.0, 2) }, {
  class_id = 8,
  in_combat = true,
  auto_attack_guid = 90,
  powers = { 5 },
  action_buttons = {
    { slot = 2, spell_id = 133, usable = false, usable_known = true,
      not_enough_mana = true },
    { slot = 5, spell_id = 5019, usable = true, usable_known = true },
  },
}))
check(mageOom.kind == "attack" and mageOom.spell == 5019 and
  mageOom.stop_distance == 22.0 and mageOom.reason == "mage_wand",
  "OOM mage wands at caster range")

local mageWanding = grind.decide(view({ unit(90, 8.0, 2) }, {
  class_id = 8,
  in_combat = true,
  auto_attack_guid = 90,
  powers = { 5 },
  action_buttons = {
    { slot = 2, spell_id = 133, usable = false, usable_known = true,
      not_enough_mana = true },
    { slot = 5, spell_id = 5019, usable = true, usable_known = true,
      active = true },
  },
}))
check(mageWanding.spell == nil and mageWanding.stop_distance == 22.0 and
  mageWanding.reason == "mage_wanding",
  "an already-firing wand is not re-pressed")

local rogue = grind.decide(view({ unit(82, 5.0, 3) }, {
  class_id = 4,
  action_buttons = {
    { slot = 1, spell_id = 1752, usable = true, usable_known = true },
  },
}))
check(rogue.kind == "attack" and rogue.spell == 1752,
  "rogue fills with Sinister Strike")

local starved = grind.decide(view({ unit(83, 5.0, 3) }, {
  class_id = 4,
  action_buttons = {
    { slot = 1, spell_id = 1752, usable = true, usable_known = true,
      not_enough_mana = true },
  },
}))
check(starved.kind == "attack" and starved.spell == nil,
  "rogue auto-attacks when energy-starved")

-- Losing badly: break off, unless the mob is nearly dead.
local losing = grind.decide(view({ unit(61, 3.0, 3) },
  { auto_attack_guid = 61, in_combat = true, health = 10 }))
check(losing.kind == "navigate" and losing.reason == "retreat", "retreats when losing")
local finishing = grind.decide(view({ unit(62, 3.0, 3, { health = 4 }) },
  { auto_attack_guid = 62, in_combat = true, health = 10 }))
check(finishing.kind == "attack", "finishes a nearly dead mob instead of fleeing")

-- A kill settles before the next pull.
local killed = grind.decide(view({ unit(71, 3.0, 3) }, {
  auto_attack_guid = 71, in_combat = true,
  combat_kill_events = { { source_guid = 1, target_guid = 71 } },
}))
check(killed.kind == "hold" and killed.reason == "target_died", "holds on the kill")
check(grind.decide(view({})).reason == "kill_settling", "keeps holding briefly")

-- Death is a loop, not a wall.
check(grind.decide(view({}, { is_dead = true })).kind == "release", "releases when dead")
local ghost = grind.decide(view({}, {
  is_ghost = true, corpse_known = true,
  corpse_location = { map_id = 1, position = { x = 200, y = 0, z = 50 } },
}))
check(ghost.kind == "navigate" and ghost.reason == "corpse_run", "runs to the corpse")
check(ghost.route_profile == "safe_ground", "ghost travel avoids steep ground")
check(ghost.stop_distance < 39.0, "stops inside the reclaim radius")
check(grind.decide(view({}, { is_ghost = true, can_reclaim_corpse = true })).kind
  == "reclaim", "reclaims at the corpse")
check(grind.decide(view({}, { resurrect_offer_guid = 5 })).kind == "accept_rez",
  "takes a resurrect offer")

-- A pinned failure rotates the patrol; movement we do not control does not.
-- Dying cleared the buff, so take that cast out of the way first, and drop the
-- buff from the bar to keep this section about navigation alone.
local function patrolViewAt(x, y)
  local v = view({}, { action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  } })
  v.location.position.x, v.location.position.y = x, y
  return v
end
local function patrolView() return patrolViewAt(0.0, 0.0) end
local before = grind.decide(patrolView())
nav = { state = "unavailable", failed_here = true, walkout_available = false }
clock = clock + 10.0
local rotated = grind.decide(patrolView())
check(rotated.x ~= before.x or rotated.y ~= before.y, "turns when the pose is blocked")
-- While the host still has a walkout step, the leg stands: keep the seat
-- moving so this is about the walkout and not the stall timer.
nav = { state = "unavailable", failed_here = true, walkout_available = true }
clock = clock + 10.0
local waiting = grind.decide(patrolViewAt(0.0, 0.0))
clock = clock + 1.0
local stillWaiting = grind.decide(patrolViewAt(6.0, 0.0))
check(waiting.x == stillWaiting.x and waiting.y == stillWaiting.y,
  "lets the walkout run before rotating")

-- A leg gets time to work: an unavailable frame right after a rotation must
-- not restart the route again.
nav = { state = "unavailable", failed_here = true, walkout_available = false }
clock = clock + 10.0
local first = grind.decide(patrolViewAt(12.0, 0.0))
clock = clock + 0.5
local second = grind.decide(patrolViewAt(12.0, 0.0))
check(first.x == second.x and first.y == second.y,
  "does not turn faster than a route can plan")

-- Roaming leaves from where the seat stands, so a cleared patch leads on to
-- new ground instead of pacing the same box.
clock = clock + 30.0
local farAway = grind.decide(patrolViewAt(500.0, 500.0))
check(farAway.x > 400.0 and farAway.y > 400.0,
  "roams onward from the current position")
nav = { state = "following", failed_here = false, walkout_available = false }


-- Soft quests: no travel to accepts at level 1, and no travel while a hunt
-- is available. Open dialogs still get answered.
local function giver(guid, distance, name)
  return unit(guid, distance, 3, {
    name = name or "Giver",
    player_can_attack_known = true,
    player_can_attack = false,
  })
end

-- Soft-quest unit tests force the flag on (default is off after 2.009 score).
grind.set_quests(true)
-- No generated quest-hub table unless a test asks for one: every check below
-- this line is therefore also a check that a deploy without the artifact
-- behaves exactly as it did before it existed.
grind.set_quest_hubs({})

local lowLevelGiver = view({
  giver(900, 10.0, "Chief"),
}, {
  level = 1,
  quest_markers = { { questgiver_guid = 900, status = 5 } },
  quest_frame = { open = false },
  accepted_quests = {}, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
clock = clock + 10.0
check(grind.decide(lowLevelGiver).kind ~= "interact",
  "does not walk to new quests at level 1")

-- An idle quest log outranks the next pull: grinding with nothing to
-- progress is wasted XP, so the available giver wins even with a mob close.
local huntAndGiver = view({
  unit(901, 8.0, 3),
  giver(900, 10.0, "Chief"),
}, {
  level = 3,
  quest_markers = { { questgiver_guid = 900, status = 5 } },
  quest_frame = { open = false },
  accepted_quests = {}, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
clock = clock + 10.0
local idleAccept = grind.decide(huntAndGiver)
check(idleAccept.kind == "interact" and idleAccept.guid == 900,
  "idle log: walks to the available giver past a nearby hunt")

-- With an unfinished objective in the log, the old rule stands: the pull wins.
local huntWithWork = view({
  unit(901, 8.0, 3),
  giver(900, 10.0, "Chief"),
}, {
  level = 3,
  quest_markers = { { questgiver_guid = 900, status = 5 } },
  quest_frame = { open = false },
  accepted_quests = { 1 },
  quest_objectives = { { complete = false } },
  completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
clock = clock + 10.0
check(grind.decide(huntWithWork).kind == "attack",
  "busy log: prefers grinding when a huntable mob is nearby")

-- Scouting: an idle log and no markers anywhere sends the seat to the
-- nearest untried friendly NPC — dialogs are the only marker source for a
-- client that never sends the giver-status query.
local unmarkedNpc = view({
  giver(910, 20.0, "Deathguard"),
}, {
  level = 3,
  quest_markers = {},
  quest_frame = { open = false },
  accepted_quests = {}, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
clock = clock + 10.0
local scout = grind.decide(unmarkedNpc)
check(scout.kind == "interact" and scout.guid == 910 and
  scout.reason == "scout_npc",
  "idle log: scouts an unmarked friendly NPC")

-- When routing has no path to a distant giver, the pursuit falls back to a
-- local-steer leg at the NPC instead of stalling on "unavailable".
nav = { state = "unavailable", failed_here = true, walkout_available = false }
clock = clock + 10.0
local steer = grind.decide(unmarkedNpc)
check(steer.kind == "navigate" and steer.navigation_mode == "local_steer" and
  steer.reason == "scout_walk",
  "unroutable scout falls back to a local-steer leg")
nav = { state = "following", failed_here = false, walkout_available = false }

-- A friendly PLAYER is not a scout target: no dialog to give.
local playerNoScout = view({
  giver(915, 10.0, "Igris"),
}, {
  level = 3,
  quest_markers = {},
  quest_frame = { open = false },
  accepted_quests = {}, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
playerNoScout.units[1].object_kind = "player"
clock = clock + 10.0
check(grind.decide(playerNoScout).kind ~= "interact",
  "does not scout friendly players")

-- A busy log never scouts: unmarked NPCs are only interesting when idle.
local busyNoScout = view({
  giver(910, 20.0, "Deathguard"),
}, {
  level = 3,
  quest_markers = {},
  quest_frame = { open = false },
  accepted_quests = { 1 },
  quest_objectives = { { complete = false } },
  completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
clock = clock + 10.0
check(grind.decide(busyNoScout).kind ~= "interact",
  "busy log: does not scout unmarked NPCs")

-- One banked objective (Encrypted Scroll) must not arm the rank-2 vendor
-- crawl while another accepted quest still needs field work (The Damned).
local mixedBankedNoScout = view({
  giver(910, 20.0, "Deathguard"),
  unit(911, 8.0, 3),
}, {
  level = 3,
  quest_markers = {},
  quest_frame = { open = false },
  accepted_quests = { 3096, 376 },
  quest_objectives = {
    { quest_id = 3096, complete = true, entry = 0, item_id = 9559 },
    { quest_id = 376, complete = false, entry = 0, item_id = 3265 },
  },
  completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
clock = clock + 10.0
local mixedStep = grind.decide(mixedBankedNoScout)
check(mixedStep.kind == "attack" and mixedStep.guid == 911,
  "mixed log: banked talk-quest does not scout; unfinished work grinds")

-- Same mixed log, but the chapel has a live ! marker. Banked 3096 used to
-- override the hunt gate for rank-1 accepts and park on Sarvis.
local mixedNoNewAccept = view({
  unit(911, 8.0, 3),
  giver(900, 10.0, "Sarvis"),
}, {
  level = 3,
  quest_markers = { { questgiver_guid = 900, status = 5 } },
  quest_frame = { open = false },
  accepted_quests = { 3096, 376 },
  quest_objectives = {
    { quest_id = 3096, complete = true, entry = 0, item_id = 9559 },
    { quest_id = 376, complete = false, entry = 0, item_id = 3265 },
  },
  completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
clock = clock + 10.0
local mixedHunt = grind.decide(mixedNoNewAccept)
check(mixedHunt.kind == "attack" and mixedHunt.guid == 911,
  "mixed log: unfinished field work outranks a new accept")

-- Item-drop objectives report entry=0. A close leftover zombie must not
-- beat a visible scavenger/duskbat while The Damned still needs paws/wings.
do
  local zombie = unit(1501, 8.0, 1, { name = "Mindless Zombie", entry = 1501 })
  local scavenger = unit(1508, 85.0, 2, { name = "Young Scavenger", entry = 1508 })
  local duskbat = unit(1513, 90.0, 4, { name = "Mangy Duskbat", entry = 1513 })
  local damned = view({ zombie, scavenger, duskbat }, {
    level = 4,
    class_id = 4,
    quest_markers = {},
    quest_frame = { open = false },
    accepted_quests = { 376 },
    quest_objectives = {
      { quest_id = 376, complete = false, entry = 0, item_id = 3265 },
      { quest_id = 376, complete = false, entry = 0, item_id = 3264 },
    },
    completed_quest_ids = {},
    ui_nodes = {},
    action_buttons = {
      { slot = 1, spell_id = 1752, usable = true, usable_known = true },
    },
  })
  clock = clock + 10.0
  local pick = grind.decide(damned)
  check(pick.kind == "attack" and pick.guid == 1508,
    "376 item-drop: prefers Young Scavenger at 85yd over a 8yd zombie")

  damned.quest_objectives[1].complete = true
  clock = clock + 10.0
  local wings = grind.decide(damned)
  check(wings.kind == "attack" and wings.guid == 1513,
    "376 item-drop: paws done prefers Mangy Duskbat over leftover zombie")

  local grindOnly = view({ zombie, scavenger }, {
    level = 4,
    quest_markers = {},
    quest_frame = { open = false },
    accepted_quests = {},
    quest_objectives = {},
    completed_quest_ids = { 376 },
    ui_nodes = {},
    action_buttons = {
      { slot = 1, spell_id = 5176, usable = true, usable_known = true },
    },
  })
  clock = clock + 10.0
  local trash = grind.decide(grindOnly)
  check(trash.kind == "attack" and trash.guid == 1501,
    "no item-drop work: far scavenger stays outside SEARCH_YARDS")
end

-- One finished counter on an unfinished quest is not banked work.
-- 376 wings 6/6 + paws 2/6 must not walk a remembered hub past a hunt.
do
  local seeGiver = view({
    giver(925, 10.0, "HubGiver"),
  }, {
    level = 6,
    quest_markers = { { questgiver_guid = 925, status = 5 } },
    quest_frame = { open = false },
    accepted_quests = { 364, 376 },
    quest_objectives = {
      { quest_id = 364, complete = false, entry = 1501 },
      { quest_id = 376, complete = false, entry = 0 },
    },
    completed_quest_ids = {},
    ui_nodes = {},
    action_buttons = {
      { slot = 1, spell_id = 5176, usable = true, usable_known = true },
    },
  })
  seeGiver.units[1].location = { map_id = 1,
    position = { x = 500.0, y = 500.0, z = 50.0 } }
  clock = clock + 10.0
  grind.decide(seeGiver)
  local partial = view({
    unit(926, 8.0, 3),
  }, {
    level = 6,
    quest_markers = {},
    quest_frame = { open = false },
    accepted_quests = { 364, 376 },
    quest_objectives = {
      { quest_id = 364, complete = false, entry = 1501 },
      { quest_id = 364, complete = false, entry = 1502 },
      { quest_id = 376, complete = false, entry = 0, item_id = 3265 },
      { quest_id = 376, complete = true, entry = 0, item_id = 3264 },
    },
    completed_quest_ids = {},
    ui_nodes = {},
    action_buttons = {
      { slot = 1, spell_id = 5176, usable = true, usable_known = true },
    },
  })
  clock = clock + 10.0
  local stay = grind.decide(partial)
  check(stay.kind == "attack" and stay.guid == 926,
    "partial objective: one finished counter does not hub-walk past a hunt")
end

-- An empty greeting exhausts the NPC, so the scout rank moves on instead of
-- bouncing off the same guard forever.
local emptyGreeting = view({
  giver(910, 2.0, "Deathguard"),
}, {
  level = 3,
  quest_markers = {},
  quest_frame = { open = true, panel = "greeting", npc_guid = 910,
    greeting_rows = {} },
  accepted_quests = {}, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
clock = clock + 10.0
local goodbye = grind.decide(emptyGreeting)
check(goodbye.kind == "ui_press" and goodbye.reason == "nothing_offered",
  "empty greeting says goodbye")
local afterGoodbye = view({
  giver(910, 20.0, "Deathguard"),
}, {
  level = 3,
  quest_markers = {},
  quest_frame = { open = false },
  accepted_quests = {}, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
clock = clock + 10.0
check(grind.decide(afterGoodbye).kind ~= "interact",
  "empty greeting exhausts the NPC for the scout rank")

local openDialog = view({}, {
  level = 3,
  quest_frame = { open = true, panel = "details" },
  accepted_quests = {}, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
local accept = grind.decide(openDialog)
check(accept.kind == "ui_press" and accept.control == "QuestFrameAcceptButton",
  "accepts by button when the details panel is open")

local turnInOnly = view({
  giver(902, 12.0, "TurnIn"),
}, {
  level = 1,
  quest_markers = { { questgiver_guid = 902, status = 6 } },
  quest_frame = { open = false },
  accepted_quests = { 1 }, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
local turnInWalk = grind.decide(turnInOnly)
check(turnInWalk.kind == "interact" and turnInWalk.guid == 902,
  "walks to reward markers even at level 1")
check(turnInWalk.stop_distance and turnInWalk.stop_distance <= 4.0,
  "stops close enough to interact")

-- A completed quest arms the hub walk-back even with mobs nearby: banked
-- work outranks the next pull for the return leg too.
do
  -- Seed the hub memory: see a giver once, then lose sight of it.
  local seeGiver = view({
    giver(905, 10.0, "HubGiver"),
  }, {
    level = 3,
    quest_markers = { { questgiver_guid = 905, status = 5 } },
    quest_frame = { open = false },
    accepted_quests = { 1 },
    quest_objectives = { { complete = false } },
    completed_quest_ids = {},
    ui_nodes = {},
    action_buttons = {
      { slot = 1, spell_id = 5176, usable = true, usable_known = true },
    },
  })
  seeGiver.units[1].location = { map_id = 1,
    position = { x = 500.0, y = 500.0, z = 50.0 } }
  clock = clock + 10.0
  grind.decide(seeGiver)
  local walkBack = view({
    unit(906, 8.0, 3),
  }, {
    level = 3,
    quest_markers = {},
    quest_frame = { open = false },
    accepted_quests = { 1 },
    quest_objectives = { { complete = true } },
    completed_quest_ids = {},
    ui_nodes = {},
    action_buttons = {
      { slot = 1, spell_id = 5176, usable = true, usable_known = true },
    },
  })
  clock = clock + 10.0
  local back = grind.decide(walkBack)
  check(back.kind == "navigate" and back.reason == "quest_hub",
    "a banked quest walks back to the hub past a nearby hunt")
end

-- Fights en route pause the pursuit clocks: two minutes of combat must not
-- exhaust the giver the courier was 20yd short of (Sarvis, live 2026-08-16).
do
  local fighting = view({
    unit(908, 2.0, 3),
    giver(902, 12.0, "TurnIn"),
  }, {
    level = 1,
    in_combat = true,
    auto_attack_guid = 908,
    quest_markers = { { questgiver_guid = 902, status = 6 } },
    quest_frame = { open = false },
    accepted_quests = { 1 }, quest_objectives = {}, completed_quest_ids = {},
    ui_nodes = {},
    action_buttons = {
      { slot = 1, spell_id = 5176, usable = true, usable_known = true },
    },
  })
  clock = clock + 5.0
  grind.decide(fighting)          -- pursuit pauses here
  clock = clock + 120.0           -- a long fight, way past both budgets
  grind.decide(fighting)
  clock = clock + 5.0
  local resumed = grind.decide(turnInOnly)
  check(resumed.kind == "interact" and resumed.guid == 902,
    "combat time does not burn the pursuit budget")
end

-- Patience: a giver that never opens is exhausted and grind resumes.
local stuckGiver = view({
  giver(903, 5.0, "Stuck"),
}, {
  level = 3,
  quest_markers = { { questgiver_guid = 903, status = 5 } },
  quest_frame = { open = false },
  accepted_quests = {}, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
local firstTry = grind.decide(stuckGiver)
check(firstTry.kind == "interact", "approaches a questgiver when idle at level 3")
clock = clock + 80.0
local afterPatience = grind.decide(stuckGiver)
check(afterPatience.kind ~= "interact" or afterPatience.guid ~= 903,
  "gives up on a questgiver after patience")

-- A turn-in we never reached is a failed walk, not a silent giver. Exhausting
-- it strands the rank-0 marker for the rest of the session (Baran: Sarvis).
do
  grind.reset()
  local farTurnIn = view({
    giver(940, 40.0, "Sarvis"),
  }, {
    level = 4,
    quest_markers = { { questgiver_guid = 940, status = 6 } },
    quest_frame = { open = false },
    accepted_quests = { 364, 376 },
    quest_objectives = {
      { quest_id = 364, complete = true, entry = 1501 },
      { quest_id = 376, complete = false, entry = 0 },
    },
    completed_quest_ids = {},
    ui_nodes = {},
    action_buttons = {
      { slot = 1, spell_id = 5176, usable = true, usable_known = true },
    },
  })
  clock = clock + 5.0
  local approach = grind.decide(farTurnIn)
  check(approach.kind == "interact" and approach.guid == 940,
    "starts a far turn-in walk")
  clock = clock + 65.0
  local timedOut = grind.decide(farTurnIn)
  check(not timedOut or timedOut.guid ~= 940,
    "releases the far giver when the approach budget expires")
  clock = clock + 5.0
  local cooling = grind.decide(farTurnIn)
  check(not cooling or cooling.guid ~= 940,
    "cools down a failed approach instead of exhausting the giver")
  clock = clock + 50.0
  local retry = grind.decide(farTurnIn)
  check(retry.kind == "interact" and retry.guid == 940,
    "retries the turn-in after the approach cooldown")
end

-- Reward panels that offer a choice: a bare /questreward is rejected by the
-- client ("Choose a quest reward first"), so the choice button is pressed
-- first and the plain verb only runs once a choice is selected.
local function rewardView(frame, nodes)
  return view({}, {
    level = 3,
    quest_frame = frame,
    accepted_quests = { 1 }, quest_objectives = {}, completed_quest_ids = {},
    ui_nodes = nodes or {},
    action_buttons = {
      { slot = 1, spell_id = 5176, usable = true, usable_known = true },
    },
  })
end

local rewardChoiceNodes = {
  { source_name = "QuestRewardItem1", reference_id = "quest-reward:1",
    enabled = true, hit_testable = true },
  { source_name = "QuestRewardItem2", reference_id = "quest-reward:2",
    enabled = true, hit_testable = true },
}
local chooseReward = grind.decide(rewardView({
  open = true, panel = "reward", selected_choice = 0,
  choice_items = { { item_id = 3270, count = 1 }, { item_id = 3273, count = 1 } },
}, rewardChoiceNodes))
check(chooseReward.kind == "ui_press" and
  chooseReward.reference == "quest-reward:1" and
  chooseReward.reason == "reward_choice",
  "selects a reward choice before turning in")

-- The choice buttons are not in every snapshot. Pressing Complete while a
-- choice is still required is refused and wedges the panel; hold instead.
local waitReward = grind.decide(rewardView({
  open = true, panel = "reward", selected_choice = 0,
  choice_items = { { item_id = 3270, count = 1 }, { item_id = 3273, count = 1 } },
}))
check(waitReward.kind == "hold" and waitReward.reason == "reward_choice_wait",
  "holds for a missing reward-choice control instead of a refused Complete")

local takeReward = grind.decide(rewardView({
  open = true, panel = "reward", selected_choice = 1,
  choice_items = { { item_id = 3270, count = 1 }, { item_id = 3273, count = 1 } },
}, rewardChoiceNodes))
check(takeReward.kind == "ui_press" and
  takeReward.control == "QuestFrameCompleteQuestButton" and
  takeReward.reason == "turn_in",
  "turns in by button once a choice is selected")

local noChoiceReward = grind.decide(rewardView({
  open = true, panel = "reward", selected_choice = 0, choice_items = {},
}))
check(noChoiceReward.kind == "ui_press" and
  noChoiceReward.control == "QuestFrameCompleteQuestButton" and
  noChoiceReward.reason == "turn_in",
  "turns in by button when the quest offers no choice")

-- A reward that cannot complete (full bags) is pressed a bounded number of
-- times, then closed so the seat can grind instead of looping forever.
local function stuckRewardView(questId)
  return rewardView({
    open = true, panel = "reward", selected_choice = 0, choice_items = {},
    quest_id = questId or 9991, npc_guid = 1661,
  })
end
local REWARD_COMPLETE_ATTEMPTS = 12
for i = 1, REWARD_COMPLETE_ATTEMPTS do
  local press = grind.decide(stuckRewardView())
  check(press.kind == "ui_press" and
    press.control == "QuestFrameCompleteQuestButton" and
    press.reason == "turn_in",
    "tries Complete honestly before giving up (" .. i .. ")")
end
local blocked = grind.decide(stuckRewardView())
check(blocked.kind == "ui_press" and
  blocked.control == "QuestFrameCancelButton" and
  blocked.reason == "reward_blocked",
  "closes a refused reward panel after the attempt budget")

-- Closing the panel (or changing the quest) resets the budget so a later
-- legitimate turn-in still gets its full quota of attempts.
grind.decide(rewardView({ open = false }))
local afterClose = grind.decide(stuckRewardView())
check(afterClose.kind == "ui_press" and
  afterClose.control == "QuestFrameCompleteQuestButton" and
  afterClose.reason == "turn_in",
  "a later turn-in gets a fresh attempt budget after the panel closes")

grind.reset()
for _ = 1, REWARD_COMPLETE_ATTEMPTS do
  grind.decide(stuckRewardView(9991))
end
check(grind.decide(stuckRewardView(9991)).reason == "reward_blocked",
  "same quest is still blocked after the budget")
local otherQuest = grind.decide(stuckRewardView(9992))
check(otherQuest.kind == "ui_press" and
  otherQuest.control == "QuestFrameCompleteQuestButton" and
  otherQuest.reason == "turn_in",
  "a different quest gets a fresh attempt budget")

-- After the Complete budget, consume an action-bar use-item stack so the
-- next Complete can store the reward, then walk back to the same giver.
grind.reset()
for _ = 1, REWARD_COMPLETE_ATTEMPTS do
  grind.decide(stuckRewardView(376))
end
check(grind.decide(stuckRewardView(376)).reason == "reward_blocked",
  "full-bag turn-in still closes the panel")
local eatView = view({}, {
  level = 3,
  quest_frame = { open = false },
  accepted_quests = { 376 }, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {
    { source_name = "ActionButton12", enabled = true, hit_testable = true },
  },
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
    { slot = 12, kind = "use-item", spell_id = 433, usable = true,
      usable_known = true },
  },
})
local eat = grind.decide(eatView)
check(eat.kind == "ui_press" and eat.control == "ActionButton12" and
  eat.reason == "bag_slot_use",
  "uses an action-bar consumable to free a bag slot")
eatView.eating = true
local chew = grind.decide(eatView)
check(chew.kind == "hold" and chew.reason == "bag_slot_consume",
  "waits out the eat before clicking again")
eatView.eating = false
clock = clock + 2.0
local eatAgain = grind.decide(eatView)
check(eatAgain.reason == "bag_slot_use",
  "clicks the consumable again after the eat settles")
local cleared = view({
  giver(1661, 5.0, "Elreth"),
}, {
  level = 3,
  quest_markers = { { questgiver_guid = 1661, status = 6 } },
  quest_frame = { open = false },
  accepted_quests = { 376 }, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
local resume = grind.decide(cleared)
check(resume.kind == "interact" and resume.guid == 1661,
  "returns to the turn-in once a bag slot is free")
grind.reset()

-- Banking a turn-in outranks the next pull. Every Deathknell giver has mobs
-- inside the hunt radius, so a shared gate stranded finished quests forever.
local turnInWithHunt = view({
  unit(910, 8.0, 3),
  giver(911, 12.0, "TurnIn"),
}, {
  level = 3,
  quest_markers = { { questgiver_guid = 911, status = 6 } },
  quest_frame = { open = false },
  accepted_quests = { 1 }, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
local banking = grind.decide(turnInWithHunt)
check(banking.kind == "interact" and banking.guid == 911,
  "walks to a turn-in even with a huntable mob nearby")

local acceptWithHunt = view({
  unit(912, 8.0, 3),
  giver(913, 12.0, "Offer"),
}, {
  level = 3,
  quest_markers = { { questgiver_guid = 913, status = 5 } },
  quest_frame = { open = false },
  accepted_quests = { 1 },
  quest_objectives = { { complete = false } },
  completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
check(grind.decide(acceptWithHunt).kind == "attack",
  "busy log still yields a new accept to a nearby pull")

-- Questgiver memory: standing next to a giver records where it was, so a seat
-- that grinds its way out of sight can walk back to hand work in.
local hubGiver = giver(940, 10.0, "Hub")
hubGiver.location = { map_id = 1, position = { x = 1845.0, y = 1620.0, z = 97.0, o = 0 } }
grind.decide(view({ hubGiver }, {
  level = 3,
  quest_markers = { { questgiver_guid = 940, status = 5 } },
  quest_frame = { open = false },
  accepted_quests = {}, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {},
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
}))

-- Out of sight, with a finished objective to bank: walk back to it.
local farAwayWithWork = view({}, {
  level = 3,
  quest_markers = {},
  quest_frame = { open = false },
  accepted_quests = { 1 },
  quest_objectives = { { quest_id = 1, complete = true, entry = 0 } },
  completed_quest_ids = {},
  ui_nodes = {},
  location = { map_id = 1, position = { x = 1990.0, y = 1700.0, z = 85.0, o = 0 } },
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
clock = clock + 5.0
local walkBack = grind.decide(farAwayWithWork)
check(walkBack.reason == "quest_hub" and math.abs(walkBack.x - 1845.0) < 1.0,
  "walks back to a remembered questgiver to bank a finished objective")

-- Nothing to hand in and a full-enough log: no reason to walk back.
local farAwayIdle = view({}, {
  level = 3,
  quest_markers = {},
  quest_frame = { open = false },
  accepted_quests = { 1 },
  quest_objectives = { { quest_id = 1, complete = false, entry = 0 } },
  completed_quest_ids = {},
  ui_nodes = {},
  location = { map_id = 1, position = { x = 1990.0, y = 1700.0, z = 85.0, o = 0 } },
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
check(grind.decide(farAwayIdle).reason ~= "quest_hub",
  "does not walk back with unfinished work in the log")

-- A banked quest whose ender this seat has NEVER seen. Remembered hubs are
-- all on map 1, so on map 0 the seen-givers table is structurally empty and
-- the generated turn-in position is the only thing that knows where to walk.
local strandedView = view({}, {
  level = 3,
  quest_markers = {},
  quest_frame = { open = false },
  accepted_quests = { { quest_id = 364, title = "The Mindless Ones" } },
  quest_objectives = { { quest_id = 364, complete = true, entry = 0 } },
  completed_quest_ids = {},
  ui_nodes = {},
  location = { map_id = 0, position = { x = 2400.0, y = 1900.0, z = 85.0, o = 0 } },
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})

clock = clock + 5.0
check(grind.decide(strandedView).reason ~= "quest_hub",
  "without generated data a never-seen turn-in is still unreachable")

grind.set_quest_hubs({
  [364] = {
    starter = { 0, 1857.9, 1600.9, 93.6, "Deathguard Simmer" },
    ender = { 0, 1843.3, 1639.9, 97.8, "Shadow Priest Sarvis" },
  },
})
clock = clock + 5.0
local generated = grind.decide(strandedView)
check(generated.reason == "quest_hub",
  "walks to the generated turn-in of a banked quest with no giver in memory")
check(math.abs(generated.x - 1843.3) < 1.0 and
  math.abs(generated.y - 1639.9) < 1.0 and generated.map_id == 0,
  "aims at the ender, not the starter")
check(generated.stop_distance == 25.0 and
  generated.route_profile == "safe_ground",
  "generated leg uses the same arrive distance and route profile as a hub walk")

-- Empty log in a mob field: walk to the generated starter, do not scout a
-- 96yd guard and do not grind (Bellion, Deathknell, 2026-08-16).
local emptyField = view({
  unit(88, 8.0, 1),
  giver(920, 96.0, "Deathguard Randolph"),
}, {
  level = 3,
  class_id = 8,
  quest_markers = {},
  quest_frame = { open = false },
  accepted_quests = {},
  quest_objectives = {},
  completed_quest_ids = {},
  ui_nodes = {},
  location = { map_id = 0, position = { x = 1981.0, y = 1611.0, z = 82.3, o = 0 } },
  action_buttons = {
    { slot = 1, spell_id = 133, usable = true, usable_known = true },
  },
})
clock = clock + 5.0
local starterWalk = grind.decide(emptyField)
check(starterWalk.reason == "quest_hub",
  "empty log walks to a generated starter instead of grinding or scouting a guard")
check(math.abs(starterWalk.x - 1857.9) < 1.0 and
  math.abs(starterWalk.y - 1600.9) < 1.0,
  "empty-log walk aims at the generated starter")

-- Rank-2 scout is last-yards only. A far unmarked NPC is not a walk target.
local farGuard = view({
  giver(921, 96.0, "Deathguard Randolph"),
}, {
  level = 3,
  quest_markers = {},
  quest_frame = { open = false },
  accepted_quests = { 1 },
  quest_objectives = { { quest_id = 1, complete = false, entry = 0 } },
  completed_quest_ids = {},
  ui_nodes = {},
  location = { map_id = 0, position = { x = 1981.0, y = 1611.0, z = 82.3, o = 0 } },
  action_buttons = {
    { slot = 1, spell_id = 133, usable = true, usable_known = true },
  },
})
clock = clock + 5.0
local farScout = grind.decide(farGuard)
check(farScout.reason ~= "scout_npc" and farScout.reason ~= "scout_walk",
  "does not scout an unmarked NPC beyond SCOUT_YARDS")

-- Unfinished work in that same quest is field work, not a walk to the ender.
local strandedBusy = view({}, {
  level = 3,
  quest_markers = {},
  quest_frame = { open = false },
  accepted_quests = { { quest_id = 364, title = "The Mindless Ones" } },
  quest_objectives = {
    { quest_id = 364, complete = true, entry = 0 },
    { quest_id = 364, complete = false, entry = 0 },
  },
  completed_quest_ids = {},
  ui_nodes = {},
  location = { map_id = 0, position = { x = 2400.0, y = 1900.0, z = 85.0, o = 0 } },
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
clock = clock + 5.0
check(grind.decide(strandedBusy).reason ~= "quest_hub",
  "one finished objective out of two is not a banked quest")

-- A quest the generated table does not cover falls straight back to today's
-- behavior rather than walking somewhere else's turn-in.
local strandedUnknown = view({}, {
  level = 3,
  quest_markers = {},
  quest_frame = { open = false },
  accepted_quests = { { quest_id = 999999, title = "Unknown" } },
  quest_objectives = { { quest_id = 999999, complete = true, entry = 0 } },
  completed_quest_ids = {},
  ui_nodes = {},
  location = { map_id = 0, position = { x = 2400.0, y = 1900.0, z = 85.0, o = 0 } },
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
clock = clock + 5.0
check(grind.decide(strandedUnknown).reason ~= "quest_hub",
  "a quest missing from the generated table walks nowhere")

grind.set_quest_hubs({})

-- Loot: item objectives are only satisfied by taking the drop.
local corpse = unit(920, 2.0, 2, { is_dead = true, health = 0 })
local function lootView(nodes, extra)
  local v = view({ corpse }, {
    level = 3,
    quest_markers = {},
    quest_frame = { open = false },
    accepted_quests = { 1 }, quest_objectives = {}, completed_quest_ids = {},
    ui_nodes = nodes or {},
    action_buttons = {
      { slot = 1, spell_id = 5176, usable = true, usable_known = true },
    },
  })
  for k, v2 in pairs(extra or {}) do v[k] = v2 end
  return v
end

-- The kill itself arms the loot attempt, off the kill feed (by the time the
-- event lands the engaged unit is usually already filtered out as dead).
local killView = lootView({}, {
  player_guid = 77,
  units = { unit(920, 2.0, 2) },
  auto_attack_guid = 920,
  combat_kill_events = { { source_guid = 77, target_guid = 920 } },
})
check(grind.decide(killView).reason == "target_died", "notices the kill")

grind.decide(lootView({}))  -- kill_settling holds
grind.decide(lootView({}))

local openLoot = grind.decide(lootView({}))
check(openLoot.kind == "interact" and openLoot.guid == 920 and
  openLoot.reason == "loot_corpse",
  "interacts with the corpse to open the loot window")

local takeSlot = grind.decide(lootView({
  { source_name = "LootButton1", reference_id = "loot-slot:1234:0",
    enabled = true, hit_testable = true },
}))
check(takeSlot.kind == "ui_press" and takeSlot.reference == "loot-slot:1234:0",
  "presses the loot slot the client presented")

-- A single empty frame is a pending take, not an empty corpse.
check(grind.decide(lootView({})).reason == "loot_settling",
  "waits out a pending take")
for _ = 1, 10 do grind.decide(lootView({})) end
local afterLoot = grind.decide(lootView({}))
check(afterLoot.reason ~= "loot_settling" and afterLoot.reason ~= "loot_corpse",
  "gives the corpse up once the window stays empty")

-- The kill feed is the retained combat-log ring, so the same death line
-- replays every frame; a corpse armed once must not re-arm and reset the
-- loot clock (that pinned a live seat on one unresolving money slot forever).
local replay = grind.decide(lootView({}, {
  player_guid = 77,
  units = { unit(920, 2.0, 2, { is_dead = true, death_known = true }) },
  combat_kill_events = { { source_guid = 77, target_guid = 920 } },
}))
check(replay.reason ~= "loot_corpse" and replay.reason ~= "loot_settling",
  "a replayed kill line does not re-arm a finished loot")

-- Someone else's kill is not ours to loot. (Runs with no settling holds
-- pending, so the kill feed really is what decides.)
local ignored = grind.decide(view({ unit(930, 2.0, 2, { is_dead = true }) }, {
  level = 3,
  player_guid = 77,
  quest_markers = {},
  quest_frame = { open = false },
  accepted_quests = { 1 }, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {},
  combat_kill_events = { { source_guid = 99, target_guid = 930 } },
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
}))
check(ignored.reason ~= "loot_corpse",
  "ignores a corpse someone else killed")

-- A stranded chat edit box eats every movement key. It is only stranded once
-- it has been open for seconds: an in-flight command must not be cancelled.
local function chatView()
  return view({}, {
    level = 3,
    chat_input_visible = true,
    chat_input_text = "",
    quest_markers = {},
    quest_frame = { open = false },
    accepted_quests = {}, quest_objectives = {}, completed_quest_ids = {},
    ui_nodes = {},
    action_buttons = {
      { slot = 1, spell_id = 5176, usable = true, usable_known = true },
    },
  })
end

clock = clock + 60.0
check(grind.decide(chatView()).reason ~= "close_chat_box",
  "does not cancel a chat command that is still in flight")
clock = clock + 5.0
check(grind.decide(chatView()).reason == "close_chat_box",
  "flushes a chat box that stayed open")

-- Wedge watchdog: a seat that stops displacing out of combat escapes by
-- bearing, but only on sustained evidence — never on one slow frame.
local function wedgedView()
  return view({}, {
    level = 3,
    quest_markers = {},
    quest_frame = { open = false },
    accepted_quests = {}, quest_objectives = {}, completed_quest_ids = {},
    ui_nodes = {},
    location = { map_id = 1, position = { x = 1837.7, y = 1630.1, z = 96.9, o = 0 } },
    action_buttons = {
      { slot = 1, spell_id = 5176, usable = true, usable_known = true },
    },
  })
end

clock = clock + 60.0
local firstStill = grind.decide(wedgedView())
check(firstStill.reason ~= "unstick", "does not call one still frame a wedge")
clock = clock + 30.0
check(grind.decide(wedgedView()).reason ~= "unstick",
  "wall clock alone is not evidence of a wedge")
local escape = nil
for _ = 1, 60 do
  clock = clock + 0.1
  escape = grind.decide(wedgedView())
end
check(escape.reason == "unstick", "escapes after sustained zero displacement")
check(escape.navigation_mode == "local_steer" and escape.allow_jump == true,
  "escape uses the bearing-only reflex that owns walls")
check(math.abs(escape.x - 1837.7) < 25.0 and math.abs(escape.y - 1630.1) < 25.0,
  "escape leg is short")

-- Same pose through a full compass (church/WMO, nav returns the seat)
-- must yield. Spinning bearings 0..7 forever owns decide.
for i = 1, 7 do
  clock = clock + 6.1
  local nextLeg = grind.decide(wedgedView())
  check(nextLeg.reason == "unstick",
    "compass bearing " .. i .. " still unsticks")
end
clock = clock + 6.1
check(grind.decide(wedgedView()).reason ~= "unstick",
  "a same-pose compass does not spin forever")

-- Displacement clears it.
local moved = view({}, {
  level = 3,
  quest_markers = {},
  quest_frame = { open = false },
  accepted_quests = {}, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {},
  location = { map_id = 1, position = { x = 1857.7, y = 1650.1, z = 96.9, o = 0 } },
  action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  },
})
clock = clock + 10.0
check(grind.decide(moved).reason ~= "unstick", "a moving seat is never unstuck")

print("test_accelerated: " .. passed .. " ok")
