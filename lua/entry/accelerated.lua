-- accelerated: grind low-level mobs for XP.
--
-- Scoring is level + xp/next_level_xp over a short episode, so every decision
-- serves kills per minute. A level 1-6 druid has about three Wraths worth of
-- mana, so auto-attack is the backbone and the nuke is an opener and a filler;
-- a brain that only casts spends most of each fight doing nothing.
--
-- Quests are off by default: upstream measured their own quest work delaying
-- the first kill and costing score. Flip QUESTS once the grind baseline is
-- recorded and compare the two on the same course.

local M = {}

local QUESTS = false

-- Opening nuke per class, highest rank first.
local NUKES_BY_CLASS = {
  [11] = { 5177, 5176 }, -- druid: Wrath r2/r1
  [7] = { 529, 403 },    -- shaman: Lightning Bolt r2/r1
  [9] = { 695, 686 },    -- warlock: Shadow Bolt r2/r1
  [5] = { 591, 585 },    -- priest: Smite r2/r1
  [8] = { 143, 133 },    -- mage: Fireball r2/r1
}

-- Buff once per life: cheap, and a level 1 character has almost no stats.
local BUFFS_BY_CLASS = {
  [11] = 1126, -- druid: Mark of the Wild
}

local ENGAGE_YARDS = 4.0
local SEARCH_YARDS = 40.0        -- a starting field is sparser than a road
local PATROL_YARDS = 35.0
local CORPSE_STOP_YARDS = 30.0   -- the reclaim radius is 39; stop short of it
local STALL_SECONDS = 8.0
-- Rotating a leg restarts the route, so a leg has to be given time to work.
local LEG_MIN_SECONDS = 4.0
local PROGRESS_YARDS = 3.0
local POST_KILL_HOLDS = 2

-- Upstream's own recovery gates: below these, a fresh pull is a bad trade.
local RECOVERY_HEALTH_PCT = 75.0
local RECOVERY_MANA_PCT = 55.0
local RETREAT_HEALTH_PCT = 20.0
local FINISH_TARGET_HEALTH_PCT = 20.0
local NUKE_MANA_FLOOR_PCT = 35.0

local PATROL = {
  { dx = PATROL_YARDS, dy = 0.0 },
  { dx = 0.0, dy = PATROL_YARDS },
  { dx = -PATROL_YARDS, dy = 0.0 },
  { dx = 0.0, dy = -PATROL_YARDS },
}

local anchor = nil
local patrolLeg = 1
local legStartedAt = nil
local lastPos = nil
local lastProgressAt = nil
local holdsAfterKill = 0
local buffedAt = nil

local function distance2d(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return math.sqrt(dx * dx + dy * dy)
end

local function percent(current, maximum)
  if not maximum or maximum <= 0 then return 100.0 end
  return (current or 0) * 100.0 / maximum
end

local function health_pct(view)
  if not view.health_known then return 100.0 end
  return percent(view.health, view.max_health)
end

-- Mana stays visible in the power pools even when a form hides it.
local function mana_pct(view)
  local pools, maxima = view.powers, view.max_powers
  if not pools or not maxima or not maxima[1] or maxima[1] <= 0 then
    return 100.0
  end
  return percent(pools[1], maxima[1])
end

local function unit_distance(unit)
  if unit.combat_distance_known then return unit.combat_distance end
  return unit.distance or 1e9
end

-- Mirrors upstream's actionable-target rule: the mobs that are safe to fight
-- and actually pay us.
local function huntable(view, unit, freshPull)
  if not unit.player_can_attack then return false end
  if unit.death_known and unit.is_dead then return false end
  if unit.health_known and unit.health <= 0 then return false end
  if unit.creature_rank_known and unit.creature_rank ~= 0 then return false end
  if unit.creature_type_known and unit.creature_type == 8 then return false end
  if unit.is_tapped and not unit.tapped_by_player then return false end
  if unit.summoner_guid and unit.summoner_guid ~= 0 then return false end
  if unit_distance(unit) > SEARCH_YARDS then return false end
  if unit.level_known then
    local ceiling = (view.level or 1) + (freshPull and 2 or 5)
    if unit.level > ceiling then return false end
  end
  return true
end

local function engaged_unit(view)
  local guid = view.auto_attack_guid or 0
  if guid == 0 then return nil end
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    if unit.guid == guid and not (unit.death_known and unit.is_dead) then
      return unit
    end
  end
  return nil
end

local function pick_target(view, freshPull)
  local best, bestDistance = nil, nil
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    if huntable(view, unit, freshPull) then
      local d = unit_distance(unit)
      if not bestDistance or d < bestDistance then
        best, bestDistance = unit, d
      end
    end
  end
  return best
end

local function usable_spell(view, spellId)
  for i = 1, #(view.action_buttons or {}) do
    local button = view.action_buttons[i]
    if button.spell_id == spellId then
      if button.usable_known and not button.usable then return false end
      if button.not_enough_mana then return false end
      return true
    end
  end
  return false
end

local function pick_nuke(view)
  local prio = NUKES_BY_CLASS[view.class_id or 0]
  if not prio then return nil end
  for i = 1, #prio do
    if usable_spell(view, prio[i]) then return prio[i] end
  end
  return nil
end

local function killed_target(view, guid)
  for i = 1, #(view.combat_kill_events or {}) do
    if view.combat_kill_events[i].target_guid == guid then return true end
  end
  return false
end

local function patrol_target(view, pos)
  local now = wow.time()
  local nav = wow.nav_progress()
  local moved = lastPos and
    distance2d(pos.x, pos.y, lastPos.x, lastPos.y) >= PROGRESS_YARDS
  if moved or not lastPos then
    lastPos, lastProgressAt = { x = pos.x, y = pos.y }, now
  end

  -- A pinned failure is not fixed by a different destination; the host takes
  -- a walkout step from this pose. Rotate only once that is spent, only on a
  -- route the client reports it cannot serve right now, and never faster than
  -- the route engine can plan one. Movement we do not control is not a stall.
  if not legStartedAt then legStartedAt = now end
  local unavailable = nav.state == "unavailable" and not nav.walkout_available
  local controllable = view.movement_allowed and not view.rooted
  local stalled = controllable and lastProgressAt and
    now - lastProgressAt > STALL_SECONDS
  if (unavailable or stalled) and now - legStartedAt >= LEG_MIN_SECONDS then
    patrolLeg = patrolLeg % #PATROL + 1
    legStartedAt = now
    lastPos, lastProgressAt = { x = pos.x, y = pos.y }, now
  end

  local leg = PATROL[patrolLeg]
  local tx, ty = anchor.x + leg.dx, anchor.y + leg.dy
  if distance2d(pos.x, pos.y, tx, ty) <= ENGAGE_YARDS then
    patrolLeg = patrolLeg % #PATROL + 1
    legStartedAt = now
    leg = PATROL[patrolLeg]
    tx, ty = anchor.x + leg.dx, anchor.y + leg.dy
  end
  return tx, ty
end

local function progress_status(view)
  return {
    level = view.level,
    xp = view.xp,
    next_level_xp = view.next_level_xp,
    health_pct = math.floor(health_pct(view)),
    mana_pct = math.floor(mana_pct(view)),
  }
end

function M.decide(view)
  -- Death first: everything else is unreachable from a corpse.
  if view.is_dead and not view.is_ghost then
    wow.set_status("dead: releasing")
    return { kind = "release", reason = "died", status = progress_status(view) }
  end
  if view.resurrect_offer_guid and view.resurrect_offer_guid ~= 0 then
    return { kind = "accept_rez", reason = "offered" }
  end
  if view.is_ghost then
    buffedAt = nil
    if view.can_reclaim_corpse then
      wow.set_status("ghost: reclaiming")
      return { kind = "reclaim", reason = "at_corpse" }
    end
    if view.corpse_known and view.corpse_location then
      local corpse = view.corpse_location.position
      wow.set_status("ghost: corpse run")
      return {
        kind = "navigate",
        x = corpse.x, y = corpse.y, z = corpse.z,
        map_id = math.floor(view.corpse_location.map_id or 0),
        stop_distance = CORPSE_STOP_YARDS,
        route_profile = "safe_ground",
        reason = "corpse_run",
        status = progress_status(view),
      }
    end
    return { kind = "hold", reason = "ghost_without_corpse" }
  end

  if not view.location_known or not view.location then
    return { kind = "hold", reason = "no_position" }
  end
  local pos = view.location.position
  if not anchor then
    anchor = { x = pos.x, y = pos.y, z = pos.z }
  end

  -- The server's combat bit lags a kill; re-acquiring into a corpse wastes
  -- the swing that would have started the next fight.
  if holdsAfterKill > 0 then
    holdsAfterKill = holdsAfterKill - 1
    return { kind = "hold", reason = "kill_settling" }
  end

  local health = health_pct(view)
  local mana = mana_pct(view)
  local engaged = engaged_unit(view)

  if engaged and killed_target(view, engaged.guid) then
    holdsAfterKill = POST_KILL_HOLDS
    return { kind = "hold", reason = "target_died" }
  end

  -- Break off a losing fight, unless the kill is one swing away.
  if engaged and health < RETREAT_HEALTH_PCT then
    local nearlyDead = engaged.health_known and
      percent(engaged.health, engaged.max_health) <= FINISH_TARGET_HEALTH_PCT
    if not nearlyDead then
      wow.set_status(string.format("retreat at %d%% hp", math.floor(health)))
      local away = distance2d(pos.x, pos.y, anchor.x, anchor.y)
      local tx = anchor.x + (pos.x - anchor.x) * (away > 1.0 and -1.0 or 1.0)
      local ty = anchor.y + (pos.y - anchor.y) * (away > 1.0 and -1.0 or 1.0)
      return {
        kind = "navigate",
        x = tx, y = ty, z = pos.z,
        map_id = math.floor(view.location.map_id or 0),
        stop_distance = ENGAGE_YARDS,
        route_profile = "safe_ground",
        reason = "retreat",
        status = progress_status(view),
      }
    end
  end

  -- One buff per life, while nothing is hitting us.
  local buff = BUFFS_BY_CLASS[view.class_id or 0]
  if buff and not engaged and not view.in_combat and buffedAt ~= view.level and
      usable_spell(view, buff) then
    buffedAt = view.level
    return { kind = "cast_spell", spell = buff, reason = "buff" }
  end

  -- Keep fighting what is already engaged; only fresh pulls face the gates.
  local target = engaged
  if not target then
    local rested = health >= RECOVERY_HEALTH_PCT and mana >= RECOVERY_MANA_PCT
    if not view.in_combat and not rested then
      -- Travel satisfies the five second rule, so walking to the next spawn
      -- regenerates for free where standing still would not.
      local tx, ty = patrol_target(view, pos)
      wow.set_status(string.format("recover %d%% hp %d%% mana",
        math.floor(health), math.floor(mana)))
      return {
        kind = "navigate",
        x = tx, y = ty, z = pos.z,
        map_id = math.floor(view.location.map_id or 0),
        stop_distance = ENGAGE_YARDS,
        route_profile = "prefer_ground",
        reason = "recover_walk",
        status = progress_status(view),
      }
    end
    target = pick_target(view, true)
  end

  if target then
    local spell = nil
    if mana >= NUKE_MANA_FLOOR_PCT then
      spell = pick_nuke(view)
    end
    wow.set_status(string.format(
      "attack %s lvl %d (%.0fyd) %d%% hp",
      target.name or "?", target.level or 0, unit_distance(target),
      math.floor(health)
    ))
    return {
      kind = "attack",
      guid = target.guid,
      spell = spell,
      stop_distance = ENGAGE_YARDS,
      route_profile = "prefer_ground",
      reason = "grind",
      status = progress_status(view),
    }
  end

  local tx, ty = patrol_target(view, pos)
  wow.set_status(string.format("patrol leg %d", patrolLeg))
  return {
    kind = "navigate",
    x = tx, y = ty, z = pos.z,
    map_id = math.floor(view.location.map_id or 0),
    stop_distance = ENGAGE_YARDS,
    route_profile = "prefer_ground",
    reason = "patrol_leg_" .. patrolLeg,
    status = progress_status(view),
  }
end

return M
