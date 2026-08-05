local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

package.path = "lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;"
local entry = require("traverse")
check(entry.name == "traverse", "name")
check(type(entry.decide) == "function", "decide")

local start_x = -9187.0
local r = entry.decide({
  self_unit = { x = start_x, y = -2530.25, z = 14.09, map_id = 1 },
  death = {},
})
check(r.kind == "move", "kind move")
check(r.map_id == 1, "map 1")
check(r.x > start_x, "northward x")
check(r.y == -2530.25, "same y")
check(r.reason == "north_hop", "north_hop reason")
check(r.intent == "travel", "travel intent")

r = entry.decide({ self_unit = {}, death = {} })
check(r.kind == "hold" and r.reason == "no_self_position", "no position")

r = entry.decide({
  self_unit = { x = start_x, y = 0, z = 0, map_id = 1 },
  death = { is_dead = true },
})
check(r.kind == "hold" and r.reason == "dead", "dead hold")

print("test_traverse_entry: " .. passed .. " ok")
