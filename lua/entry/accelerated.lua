-- accelerated: grind low-level mobs for XP.
--
-- Scoring is level + xp/next_level_xp over a short episode, so the loop is
-- deliberately plain: pick the nearest attackable mob in a sane level band,
-- attack it until it dies, then pick the next one. When nothing is visible
-- the seat walks a patrol leg to pull new spawns into view. Quests, loot and
-- corpse recovery are all out of scope — none of them pay XP fast enough to
-- earn their failure modes here.

local M = {}

-- Opening nuke per class, highest rank first. Melee auto-attack carries the
-- kill when nothing here is castable.
local NUKES_BY_CLASS = {
  [11] = { 5177, 5176 }, -- druid: Wrath r2/r1
  [7] = { 529, 403 },    -- shaman: Lightning Bolt r2/r1
  [9] = { 695, 686 },    -- warlock: Shadow Bolt r2/r1
  [5] = { 591, 585 },    -- priest: Smite r2/r1
  [8] = { 143, 133 },    -- mage: Fireball r2/r1
}

local ENGAGE_YARDS = 4.0
local SEARCH_YARDS = 45.0
local LEVEL_HEADROOM = 2
local PATROL_YARDS = 35.0
local STALL_SECONDS = 8.0
local PROGRESS_YARDS = 3.0

local PATROL = {
  { dx = PATROL_YARDS, dy = 0.0 },
  { dx = 0.0, dy = PATROL_YARDS },
  { dx = -PATROL_YARDS, dy = 0.0 },
  { dx = 0.0, dy = -PATROL_YARDS },
}

local anchor = nil
local patrolLeg = 1
local lastPos = nil
local lastProgressAt = nil

local function distance2d(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return math.sqrt(dx * dx + dy * dy)
end

local function huntable(unit, playerLevel)
  if not unit.player_can_attack then return false end
  if unit.death_known and unit.is_dead then return false end
  if unit.health_known and unit.health <= 0 then return false end
  if unit.distance and unit.distance > SEARCH_YARDS then return false end
  if unit.level_known and unit.level > playerLevel + LEVEL_HEADROOM then
    return false
  end
  return true
end

-- The mob already being fought stays the target until it dies, so a nuke is
-- never wasted swapping between two half-dead mobs.
local function pick_target(view)
  local playerLevel = view.level or 1
  local engaged = view.auto_attack_guid or 0
  local best, bestDistance = nil, nil
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    if huntable(unit, playerLevel) then
      if engaged ~= 0 and unit.guid == engaged then
        return unit
      end
      local d = unit.distance or 1e9
      if not bestDistance or d < bestDistance then
        best, bestDistance = unit, d
      end
    end
  end
  return best
end

local function pick_nuke(view)
  local prio = NUKES_BY_CLASS[view.class_id or 0]
  if not prio then return nil end
  for i = 1, #prio do
    local id = prio[i]
    for j = 1, #(view.action_buttons or {}) do
      local button = view.action_buttons[j]
      if button.spell_id == id then
        return id
      end
    end
  end
  return nil
end

local function patrol_target(view, pos)
  local now = wow.time()
  if lastPos and distance2d(pos.x, pos.y, lastPos.x, lastPos.y) >= PROGRESS_YARDS then
    lastProgressAt = now
    lastPos = { x = pos.x, y = pos.y }
  elseif not lastPos then
    lastPos, lastProgressAt = { x = pos.x, y = pos.y }, now
  end

  local nav = wow.nav_progress()
  if nav.state == "unavailable" or
      (lastProgressAt and now - lastProgressAt > STALL_SECONDS) then
    patrolLeg = patrolLeg % #PATROL + 1
    lastPos, lastProgressAt = { x = pos.x, y = pos.y }, now
  end

  local leg = PATROL[patrolLeg]
  local tx, ty = anchor.x + leg.dx, anchor.y + leg.dy
  if distance2d(pos.x, pos.y, tx, ty) <= ENGAGE_YARDS then
    patrolLeg = patrolLeg % #PATROL + 1
    leg = PATROL[patrolLeg]
    tx, ty = anchor.x + leg.dx, anchor.y + leg.dy
  end
  return tx, ty
end

function M.decide(view)
  if view.is_dead or view.is_ghost then
    wow.set_status("dead: no recovery in this brain yet")
    return { kind = "hold", reason = "dead" }
  end
  if not view.location_known or not view.location then
    return { kind = "hold", reason = "no_position" }
  end
  local pos = view.location.position
  if not anchor then
    anchor = { x = pos.x, y = pos.y, z = pos.z }
  end

  local target = pick_target(view)
  if target then
    local spell = pick_nuke(view)
    wow.set_status(string.format(
      "attack %s lvl %d (%.0fyd)",
      target.name or "?", target.level or 0, target.distance or 0
    ))
    return {
      kind = "attack",
      guid = target.guid,
      spell = spell,
      stop_distance = ENGAGE_YARDS,
      reason = "grind",
      status = {
        level = view.level,
        xp = view.xp,
        next_level_xp = view.next_level_xp,
        target = target.name,
      },
    }
  end

  local tx, ty = patrol_target(view, pos)
  wow.set_status(string.format("patrol leg %d", patrolLeg))
  return {
    kind = "navigate",
    x = tx,
    y = ty,
    z = pos.z,
    map_id = math.floor(view.location.map_id or 0),
    stop_distance = ENGAGE_YARDS,
    reason = "patrol_leg_" .. patrolLeg,
    status = { level = view.level, xp = view.xp, next_level_xp = view.next_level_xp },
  }
end

return M
