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
check(rotated.x ~= before.x or rotated.y ~= before.y, "rotates when the pose is blocked")
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
  "does not rotate faster than a route can plan")
nav = { state = "following", failed_here = false, walkout_available = false }


-- Quest work is off by default and must stay invisible until enabled.
local questView = view({}, {
  quest_markers = { { questgiver_guid = 900, status = 5 } },
  units = { unit(900, 10.0, 3) },
  quest_frame = { open = false },
  accepted_quests = {}, quest_objectives = {}, completed_quest_ids = {},
  ui_nodes = {},
})
clock = clock + 10.0
check(grind.decide(questView).kind ~= "interact",
  "ignores questgivers while quests are off")

print("test_accelerated: " .. passed .. " ok")
