-- traverse mode: maximize Kalimdor northing under fair play.
-- V1: stay in Travel Form, then short open-field north hops from live position.
-- No authored continent waypoint list.

local move_to = require("move_to")

local M = {
  name = "traverse",
  goal = "Maximize Kalimdor northing under fair play.",
}

-- Classic 1.12 Travel Form (spell id 783, shapeshift form id 3).
local TRAVEL_FORM_SPELL = 783
local TRAVEL_FORM_ID = 3

-- Short hop along world +X (north). Open-field only; not a route.
local HOP_YARDS = 40.0

local function is_dead(frame)
  local d = frame and frame.death
  if not d then return false end
  return d.is_dead == true or d.is_ghost == true or d.dead == true or d.ghost == true
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

function M.decide(frame, args)
  args = args or {}
  local me = frame and frame.self_unit
  if not me or me.x == nil or me.y == nil then
    return { kind = "hold", reason = "no_self_position" }
  end
  if is_dead(frame) then
    return { kind = "hold", reason = "dead" }
  end
  -- V1: always travel-shaped before any hop; re-cast if dropped.
  if not in_travel_form(frame) then
    local known = frame.spells and frame.spells.known
    -- Missing known list: still cast (fixture has Travel Form; projection may lag).
    if known == nil or knows_spell(frame, TRAVEL_FORM_SPELL) then
      return {
        kind = "cast_spell",
        spell = TRAVEL_FORM_SPELL,
        reason = "travel_form",
      }
    end
    return { kind = "hold", reason = "travel_form_unknown" }
  end
  local hop = args.hop_yards or HOP_YARDS
  return move_to.decide(frame, {
    map_id = me.map_id or 1,
    x = me.x + hop,
    y = me.y,
    z = me.z or 0,
    intent = "travel",
    reason = "north_hop",
    destination_z_unknown = (me.z == nil),
  })
end

return M
