-- move_to: pure destination hop. Shared by traverse (and later escort/quest).
-- Args: x, y, z?, map_id?, intent?, reason?, destination_z_unknown?, arrival_radius?

local registry = require("registry")

registry.register({
  name = "move_to",
  when = "Walk or travel to a world destination point",
  decide = function(frame, args)
    args = args or {}
    local me = frame and frame.self_unit
    if args.x == nil or args.y == nil then
      return { kind = "hold", reason = "move_to_missing_xy" }
    end
    local map_id = args.map_id
    if map_id == nil and me then map_id = me.map_id end
    if map_id == nil then map_id = 0 end
    local z = args.z
    if z == nil and me then z = me.z end
    if z == nil then z = 0 end
    local intent = {
      kind = "move",
      map_id = map_id,
      x = args.x,
      y = args.y,
      z = z,
      intent = args.intent or "travel",
      reason = args.reason or "move_to",
    }
    if args.destination_z_unknown then
      intent.destination_z_unknown = true
    end
    if args.arrival_radius then
      intent.arrival_radius = args.arrival_radius
    end
    return intent
  end,
})

return registry.get("move_to")
