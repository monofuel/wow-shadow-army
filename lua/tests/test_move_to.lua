local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local registry = require("registry")
require("move_to")
local tool = registry.get("move_to")
check(tool ~= nil, "registered")

local r = tool.decide({ self_unit = { x = 1, y = 2, z = 3, map_id = 1 } }, {
  x = 10, y = 20, z = 30, map_id = 1, reason = "test",
})
check(r.kind == "move", "kind move")
check(r.x == 10 and r.y == 20 and r.z == 30, "destination")
check(r.map_id == 1, "map_id")
check(r.intent == "travel", "intent travel")
check(r.reason == "test", "reason")

r = tool.decide({ self_unit = { x = 0, y = 0 } }, {})
check(r.kind == "hold" and r.reason == "move_to_missing_xy", "missing xy hold")

print("test_move_to: " .. passed .. " ok")
