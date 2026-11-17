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

local grind = require("peregrine")

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
    player_can_attack = false,
  })
end

-- Soft-quest unit tests force the flag on (default is off after 2.009 score).
grind.set_quests(true)

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
check(grind.decide(huntAndGiver).kind == "attack",
  "prefers grinding when a huntable mob is nearby")

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
check(accept.kind == "quest_cmd" and accept.command == "/questaccept",
  "accepts when the details panel is open")

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
clock = clock + 50.0
local afterPatience = grind.decide(stuckGiver)
check(afterPatience.kind ~= "interact" or afterPatience.guid ~= 903,
  "gives up on a questgiver after patience")

-- A pull whose route the engine keeps vetoing (an observed clearance
-- constraint) replans as planning, planning, unavailable and never follows.
-- It is set aside after a stall window, and only then.
grind.set_quests(false)
local logged = {}
wow.log = function(msg) logged[#logged + 1] = msg end
local VETO = "travel route crosses an observed clearance constraint"
local REPLAN = { "planning", "planning", "unavailable" }
local function huntView(units)
  return view(units, { action_buttons = {
    { slot = 1, spell_id = 5176, usable = true, usable_known = true },
  } })
end
local function chase(seconds, states, units, walkout)
  local last = nil
  for i = 1, math.floor(seconds / 0.15 + 0.5) do
    local state = states[(i - 1) % #states + 1]
    nav = { state = state, failed_here = false, walkout_available = walkout or false,
      error = state == "unavailable" and VETO or "" }
    clock = clock + 0.15
    last = grind.decide(huntView(units))
  end
  return last
end
local guarded, open = unit(1001, 13.0, 3), unit(1002, 30.0, 3)
local pack = { guarded, open }
check(chase(0.15, { "following" }, pack).guid == 1001, "chases the nearest pull")
check(chase(20.0, { "planning" }, pack).guid == 1001,
  "keeps a pull whose route is still planning")
check(chase(6.0, REPLAN, pack).guid == 1001,
  "keeps a vetoed pull inside the stall window")
check(chase(0.15, { "following" }, pack).guid == 1001 and
  chase(6.0, REPLAN, pack).guid == 1001,
  "a followed route resets the window")
check(chase(20.0, { "planning" }, pack).guid == 1001,
  "an old refusal followed only by planning does not set the pull aside")
check(#logged == 0, "nothing set aside yet")
local moved = chase(3.0, REPLAN, pack)
check(moved.kind == "attack" and moved.guid == 1002,
  "moves on to the next pull once the veto outlasts the window")
check(#logged == 1 and logged[1]:find("mob1001", 1, true) and
  logged[1]:find(VETO, 1, true), "logs the pull it set aside")
nav = { state = "following", failed_here = false, walkout_available = false }
clock = clock + 0.15
local alone = grind.decide(huntView({ guarded }))
check(alone.kind == "navigate" and alone.reason:sub(1, 5) == "roam_",
  "roams when the only pull is set aside")
clock = clock + 60.0
check(grind.decide(huntView({ guarded })).guid == 1001,
  "retries the pull once the exclusion expires")

-- A fight with the unit ends that approach: refusals from before the fight
-- do not carry into a later fresh acquisition of the same unit.
local function fightView(units)
  local v = huntView(units)
  v.auto_attack_guid, v.in_combat = 1001, true
  return v
end
chase(6.0, REPLAN, { guarded })
nav = { state = "unavailable", failed_here = false, walkout_available = false, error = VETO }
clock = clock + 0.15
check(grind.decide(fightView({ guarded })).guid == 1001, "fights the engaged unit")
check(chase(3.0, REPLAN, { guarded }).guid == 1001,
  "a fresh approach after a fight starts its own window")
check(chase(6.0, REPLAN, pack).guid == 1002,
  "and still sets the pull aside when its refusals persist")
check(grind.decide(fightView(pack)).guid == 1001,
  "an engaged unit is fought even while set aside for fresh pulls")

-- A roam leg's failures are not charged to a pull that appears afterwards.
chase(10.0, { "unavailable" }, {})
local fresh = { unit(1003, 12.0, 3) }
check(chase(7.5, { "unavailable" }, fresh).guid == 1003,
  "starts a new pull's window at its own first report")
check(chase(1.0, { "unavailable" }, fresh).kind == "navigate",
  "and sets it aside when its own window runs out")

-- The host walks out only for navigate and interact goals, so an attack
-- approach that reports a walkout as available still gets set aside, and the
-- roam leg that follows is where that walkout runs.
check(chase(9.0, REPLAN, { unit(1004, 12.0, 3) }, true).kind == "navigate",
  "a reported walkout does not hold a refused attack approach")

print("test_peregrine: " .. passed .. " ok")
