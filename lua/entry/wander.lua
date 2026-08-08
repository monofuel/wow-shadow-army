-- wander: walk a square patrol around the spawn point.
--
-- The smallest useful lua-bot entry: proves the whole host chain (view ->
-- decide -> navigate intent -> upstream navigation) and satisfies the
-- proof-of-life movement criteria without needing combat. Leg length is
-- well over the 50-yard proof floor with a full lap to spare.

local M = {}

local LEG_YARDS = 40.0
local ARRIVE_YARDS = 4.0

-- Square patrol offsets from the anchor, walked in order and repeated.
local LEGS = {
  { dx = LEG_YARDS, dy = 0.0 },
  { dx = LEG_YARDS, dy = LEG_YARDS },
  { dx = 0.0, dy = LEG_YARDS },
  { dx = 0.0, dy = 0.0 },
}

-- A leg the route engine cannot serve, or one that stops making ground, is
-- abandoned for the next one: standing still is the only real failure.
local STALL_SECONDS = 6.0
local PROGRESS_YARDS = 3.0

local anchor = nil
local leg = 1
local lastPos = nil
local lastProgressAt = nil

local function distance2d(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return math.sqrt(dx * dx + dy * dy)
end

local function nextLeg(why)
  leg = leg % #LEGS + 1
  lastProgressAt = nil
  wow.log("leg " .. leg .. " (" .. why .. ")")
end

function M.decide(view)
  if not view.location_known or not view.location then
    return { kind = "hold", reason = "no_position" }
  end
  local pos = view.location.position
  local map_id = math.floor(view.location.map_id or 0)
  local now = wow.time()
  if not anchor then
    anchor = { x = pos.x, y = pos.y, z = pos.z }
    wow.log(string.format("anchor %.1f, %.1f", anchor.x, anchor.y))
  end

  if lastPos and distance2d(pos.x, pos.y, lastPos.x, lastPos.y) >= PROGRESS_YARDS then
    lastProgressAt = now
    lastPos = { x = pos.x, y = pos.y }
  elseif not lastPos then
    lastPos = { x = pos.x, y = pos.y }
    lastProgressAt = now
  end

  local nav = wow.nav_progress()
  if nav.state == "unavailable" then
    nextLeg("route unavailable")
    lastPos = { x = pos.x, y = pos.y }
  elseif lastProgressAt and now - lastProgressAt > STALL_SECONDS then
    nextLeg("stalled")
    lastPos = { x = pos.x, y = pos.y }
  end

  local target = LEGS[leg]
  local tx, ty = anchor.x + target.dx, anchor.y + target.dy
  if distance2d(pos.x, pos.y, tx, ty) <= ARRIVE_YARDS then
    nextLeg("arrived")
    target = LEGS[leg]
    tx, ty = anchor.x + target.dx, anchor.y + target.dy
  end

  wow.set_status(string.format("wander leg %d (%s)", leg, nav.state))
  return {
    kind = "navigate",
    x = tx,
    y = ty,
    z = pos.z,
    map_id = map_id,
    stop_distance = ARRIVE_YARDS,
    reason = "wander_leg_" .. leg,
  }
end

return M
