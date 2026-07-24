-- Unit tests for follow_leader. Style per crewrift: plain assertions,
-- counter, instant, zero deps.

local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local registry = require("registry")
require("follow_leader")

local tool = registry.get("follow_leader")
check(tool ~= nil, "tool registered")
check(tool.when:len() > 0, "has when-to-use")
check(registry.names()[1] == "follow_leader", "deterministic listing")

local function frame(me, leader)
  return { self_unit = me, party = { leader_unit = leader } }
end

-- No self unit: no intent at all.
check(tool.decide({}, nil) == nil, "nil without self")

-- Leader missing or not visible: hold, never chase memories.
local r = tool.decide(frame({ x = 0, y = 0 }, nil))
check(r.kind == "hold" and r.reason == "leader_not_visible", "hold when leaderless")
r = tool.decide(frame({ x = 0, y = 0 }, { id = 7, x = 5, y = 0, visible = false }))
check(r.kind == "hold" and r.reason == "leader_not_visible", "hold when leader remembered only")

-- In formation: hold.
r = tool.decide(frame({ x = 0, y = 0 }, { id = 7, x = 3, y = 0, visible = true }))
check(r.kind == "hold" and r.reason == "in_formation", "hold inside near radius")

-- Drifted: move to leader, not urgent inside far radius.
r = tool.decide(frame({ x = 0, y = 0 }, { id = 7, x = 15, y = 0, visible = true }))
check(r.kind == "move_to_unit" and r.unit_id == 7, "moves toward leader")
check(r.urgent == false, "not urgent at medium range")
check(r.stop_range == 8.0, "default stop range")

-- Far behind: urgent catch-up.
r = tool.decide(frame({ x = 0, y = 0 }, { id = 7, x = 50, y = 0, visible = true }))
check(r.kind == "move_to_unit" and r.urgent == true, "urgent when far")

-- Args override radii.
r = tool.decide(frame({ x = 0, y = 0 }, { id = 7, x = 3, y = 0, visible = true }), { near = 2 })
check(r.kind == "move_to_unit" and r.stop_range == 2, "near override respected")

print("test_follow_leader: " .. passed .. " checks passed")
