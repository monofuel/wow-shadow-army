package.path = "lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;"

local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

-- The host installs `wow` before requiring the entry module.
local logs = {}
local clock = 0.0
local navState = "following"
_G.wow = {
  log = function(msg) logs[#logs + 1] = msg end,
  set_status = function() end,
  time = function() return clock end,
  nav_progress = function() return { state = navState } end,
}

local wander = require("wander")

local function view_at(x, y)
  return {
    location_known = true,
    location = { map_id = 1, position = { x = x, y = y, z = 50.0, o = 0.0 } },
  }
end

local first = wander.decide(view_at(0.0, 0.0))
check(first.kind == "navigate", "navigate from spawn")
check(first.map_id == 1, "map id passthrough")
check(first.z == 50.0, "anchor z")
check(first.x > 0.0 and first.y == 0.0, "first leg heads out on x")
check(#logs == 1, "anchor logged once")

local again = wander.decide(view_at(1.0, 0.0))
check(again.x == first.x and again.y == first.y, "same leg while travelling")
check(#logs == 1, "anchor not re-logged")

local arrived = wander.decide(view_at(first.x, first.y))
check(arrived.x == first.x and arrived.y > 0.0, "advances on arrival")

-- An unusable route is abandoned rather than waited on.
local beforeLeg = arrived.y
navState = "unavailable"
local rerouted = wander.decide(view_at(first.x, first.y))
check(rerouted.y ~= beforeLeg or rerouted.x ~= arrived.x, "unavailable route switches leg")
navState = "following"

-- Standing still for too long also switches legs.
local held = wander.decide(view_at(0.0, 0.0))
clock = clock + 30.0
local unstuck = wander.decide(view_at(0.0, 0.0))
check(unstuck.x ~= held.x or unstuck.y ~= held.y, "stall switches leg")

local unknown = wander.decide({ location_known = false })
check(unknown.kind == "hold", "hold without position")
check(unknown.reason == "no_position", "hold reason")

print("test_wander: " .. passed .. " ok")
