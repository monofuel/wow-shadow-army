-- traverse mode: maximize Kalimdor northing under fair play.
-- V1 desert segment: Travel Form, then move toward Gadgetzan-area checkpoint.
-- Single checkpoint only — not a continent waypoint list.
-- No authored multi-zone route.

local move_to = require("move_to")

local M = {
  name = "traverse",
  goal = "Maximize Kalimdor northing under fair play.",
}

-- Classic 1.12 Travel Form (spell id 783, shapeshift form id 3).
local TRAVEL_FORM_SPELL = 783
local TRAVEL_FORM_ID = 3

-- Monofuel personal run: north end of starting desert (near Gadgetzan).
local CHECKPOINT_X = -7033.0
local CHECKPOINT_Y = -3681.1
local CHECKPOINT_Z = 17.2
local ARRIVAL_RADIUS = 50.0

-- Segment hops along the goal vector (navmesh handles mild obstacles).
local HOP_YARDS = 80.0

local function is_dead(frame)
  local d = frame and frame.death
  if d then
    if d.is_dead == true or d.is_ghost == true or d.dead == true or d.ghost == true then
      return true
    end
  end
  -- Frames sometimes lag is_dead while health is already zero.
  local c = frame and frame.combat
  if c and type(c.health_pct) == "number" and c.health_pct <= 0 then
    return true
  end
  return false
end

local function knows_spell(frame, spellId)
  local known = frame and frame.spells and frame.spells.known
  if type(known) ~= "table" then return false end
  for _, s in ipairs(known) do
    if s == spellId then return true end
  end
  return false
end

local function in_travel_form(frame)
  local me = frame and frame.self_unit
  if not me then return false end
  if me.shapeshift_form_id == TRAVEL_FORM_ID then return true end
  if me.shapeshift_form_spell_id == TRAVEL_FORM_SPELL then return true end
  return false
end

local function planar_dist(x0, y0, x1, y1)
  local dx = x1 - x0
  local dy = y1 - y0
  return math.sqrt(dx * dx + dy * dy)
end

--- Point hop_yards toward (tx,ty) from (x,y), or the target if closer.
local function hop_toward(x, y, tx, ty, hop_yards)
  local d = planar_dist(x, y, tx, ty)
  if d <= hop_yards or d < 1e-3 then
    return tx, ty
  end
  local s = hop_yards / d
  return x + (tx - x) * s, y + (ty - y) * s
end

function M.decide(frame, args)
  args = args or {}
  local me = frame and frame.self_unit
  if not me or me.x == nil or me.y == nil then
    return { kind = "hold", reason = "no_self_position" }
  end
  if is_dead(frame) then
    return { kind = "hold", reason = "dead" }
  end

  local goal_x = args.checkpoint_x or CHECKPOINT_X
  local goal_y = args.checkpoint_y or CHECKPOINT_Y
  local goal_z = args.checkpoint_z or CHECKPOINT_Z
  local arrival = args.arrival_radius or ARRIVAL_RADIUS
  local hop = args.hop_yards or HOP_YARDS

  -- V1: always travel-shaped before any hop; re-cast if dropped.
  if not in_travel_form(frame) then
    local known = frame.spells and frame.spells.known
    if known == nil or knows_spell(frame, TRAVEL_FORM_SPELL) then
      return {
        kind = "cast_spell",
        spell = TRAVEL_FORM_SPELL,
        reason = "travel_form",
      }
    end
    return { kind = "hold", reason = "travel_form_unknown" }
  end

  local dist = planar_dist(me.x, me.y, goal_x, goal_y)
  if dist <= arrival then
    return { kind = "hold", reason = "desert_checkpoint" }
  end

  local nx, ny = hop_toward(me.x, me.y, goal_x, goal_y, hop)
  return move_to.decide(frame, {
    map_id = me.map_id or 1,
    x = nx,
    y = ny,
    z = goal_z,
    intent = "travel",
    reason = "desert_checkpoint",
    destination_z_unknown = true,
    arrival_radius = math.min(arrival, 8.0),
  })
end

return M
