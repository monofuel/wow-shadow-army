-- traverse mode: maximize Kalimdor northing under fair play.
-- PoL / V1 smoke: keep issuing short open-field north hops from live position.
-- No authored continent waypoint list.

local move_to = require("move_to")

local M = {
  name = "traverse",
  goal = "Maximize Kalimdor northing under fair play.",
}

-- Short hop along world +X (north). Open-field only; not a route.
local HOP_YARDS = 40.0

local function is_dead(frame)
  local d = frame and frame.death
  if not d then return false end
  return d.is_dead == true or d.is_ghost == true or d.dead == true or d.ghost == true
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
