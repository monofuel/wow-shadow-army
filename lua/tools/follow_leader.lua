-- follow_leader: Phase 1 of the solo-leveling curriculum. Stay near the
-- party leader without pulling aggro; the intent degrades to "hold" when
-- the leader is not visible in the frame (remembered units are not action
-- truth — upstream control contract).
--
-- frame is a plain table projection of the environment frame; the brain
-- owns mapping real MessagePack frames into this shape (coupling
-- isolation: field names pinned in one place, brain/frame_projection).

local registry = require("registry")

local DEFAULT_NEAR = 8.0   -- yd; close enough to feel escorted
local DEFAULT_FAR = 30.0   -- yd; beyond this, catching up beats caution

local function dist2(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

return registry.register({
  name = "follow_leader",
  when = "Party leader is set and we have no combat or errand goal; keep formation.",
  decide = function(frame, args)
    args = args or {}
    local near = args.near or DEFAULT_NEAR
    local far = args.far or DEFAULT_FAR
    local me = frame.self_unit
    local leader = frame.party and frame.party.leader_unit
    if not me then return nil end
    if not leader or not leader.visible then
      -- Leader out of sight: hold rather than chase a memory.
      return { kind = "hold", reason = "leader_not_visible" }
    end
    local d2 = dist2(me, leader)
    if d2 <= near * near then
      return { kind = "hold", reason = "in_formation" }
    end
    return {
      kind = "move_to_unit",
      unit_id = leader.id,
      stop_range = near,
      urgent = d2 > far * far,
    }
  end,
})
