-- Split sheet: 100% of run time classified, stationary budget zero.
--
-- The standard is an account, not an alarm. These checks pin the three
-- properties a threshold watchdog cannot give: a stall is known one decision
-- cycle after net displacement dies, oscillation in place cannot end the
-- episode or buy at-pace credit, and every escape reports its own start,
-- duration and outcome.
package.path = "lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;"

-- Recorded route data is local-only; see lua/tests/fixtures/petrel_route.lua.
local routeSource = require("tests.fixtures.petrel_route").select()
print("test_petrel_split: route = " .. routeSource)

local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local clock = 100.0
local nav = { state = "following", failed_here = false, walkout_available = false,
  waypoint_count = 12 }
local loggedLines = {}
_G.wow = {
  log = function(msg) loggedLines[#loggedLines + 1] = msg end,
  set_status = function() end,
  time = function() return clock end,
  nav_progress = function() return nav end,
  position = function() return nil end,
  perf = function()
    return { fps = 60.0, wall_s = clock / 10.0, frame_dt = 0.016,
      decision_count = 0 }
  end,
}

local function last_log(prefix)
  local found = nil
  for _, line in ipairs(loggedLines) do
    if line:sub(1, #prefix) == prefix then found = line end
  end
  return found
end

local function count_log(prefix)
  local n = 0
  for _, line in ipairs(loggedLines) do
    if line:sub(1, #prefix) == prefix then n = n + 1 end
  end
  return n
end

local function field(line, key)
  return tonumber(line:match('"' .. key .. '":([%d%.%-]+)'))
end

local petrel = require("petrel")

local function view(x, y, extra)
  local v = {
    location_known = true,
    location = { map_id = 1, position = { x = x, y = y, z = 100.0, o = 0.0 } },
    movement_allowed = true,
    rooted = false,
    is_swimming = false,
    health_known = true,
    health = 2000,
    shapeshift_form_id = 3,
  }
  for k, v2 in pairs(extra or {}) do v[k] = v2 end
  return v
end

-- North land phase (x >= LAND.start_x): the painted road owns the run, so the
-- snag machinery is live and the beat is in hand.
local START_T = clock
petrel.decide(view(1000.0, -2300.0))

-- ONE decision cycle of dead displacement is the whole detection latency.
-- The wedge that drove this ticket held (-7678, -4045) for 62 sim-seconds and
-- fired nothing: the old watchdog waited 80 s before it would even look.
clock = clock + 0.2
local frozen = petrel.decide(view(1000.0, -2300.0))
local stallLine = last_log("STALL:")
check(stallLine ~= nil, "a frozen decide opens the stall episode immediately")
check(stallLine:find("cause=", 1, true) ~= nil, "the stall names its cause")
check(stallLine:find("dec=", 1, true) ~= nil, "the stall carries the decide count")
check(frozen.status.stalled_seconds > 0.0, "the open stall is reported live")
check(last_log("RESUME:") == nil, "no pair closes while the seat is frozen")

-- Serpentining in place is what the escape reflex does to a wedged seat. It
-- moves the body and not the run, so it must neither close the episode nor
-- earn at-pace credit.
for _ = 1, 3 do
  clock = clock + 0.2
  petrel.decide(view(1003.0, -2300.0))
  clock = clock + 0.2
  petrel.decide(view(1000.0, -2300.0))
end
check(last_log("RESUME:") == nil,
  "oscillation inside the clear radius cannot end the stall")
clock = clock + 0.2
local stillStalled = petrel.decide(view(1003.0, -2300.0))
check(stillStalled.status.stalled_seconds > 1.0,
  "the stall duration keeps accruing through the serpentine")

-- Genuine net displacement is the only thing that closes it.
clock = clock + 0.2
petrel.decide(view(1060.0, -2300.0))
local resumeLine = last_log("RESUME:")
check(resumeLine ~= nil, "net displacement closes the pair")
check(resumeLine:find("by=moved", 1, true) ~= nil, "the pair says how it ended")
check(tonumber(resumeLine:match("dur=([%d%.]+)")) > 1.0,
  "the pair carries the duration the seat was not travelling")
check(resumeLine:find("decs=", 1, true) ~= nil,
  "the pair carries the decisions burned while stalled")

-- Per-interval classification: a seat covering its form's expected speed is
-- at pace, and the FLIGHT line carries the running account.
for _ = 1, 3 do
  clock = clock + 5.0
  petrel.decide(view(1060.0 + 49.0 * _, -2300.0))
end
local flightLine = last_log("FLIGHT ")
check(flightLine ~= nil, "the flight recorder is still writing")
check(flightLine:find('"cls":"at_pace"', 1, true) ~= nil,
  "a seat at travel-form speed classifies at_pace")
check(field(flightLine, "pace") >= 0.95, "the interval reports its pace")
for _, key in ipairs({ "at_s", "bp_s", "sta_s", "cast_s" }) do
  check(field(flightLine, key) ~= nil, "FLIGHT carries the " .. key .. " bucket")
end
check(field(flightLine, "sta_s") > 0.0,
  "the frozen seconds are billed to the stationary budget")

-- 100% of run time is classified: the four buckets are the whole clock.
local accounted = field(flightLine, "at_s") + field(flightLine, "bp_s") +
  field(flightLine, "sta_s") + field(flightLine, "cast_s")
check(math.abs(accounted - (clock - START_T)) < 0.05,
  "every second between the first and last decide lands in a bucket")

-- A form press is its own line on the split sheet, never a stall: casting is
-- a named cost, not an unexplained stop.
local x = 1060.0 + 49.0 * 4
clock = clock + 5.0
local cast = petrel.decide(view(x, -2300.0, { shapeshift_form_id = 0 }))
check(cast.kind == "cast_spell", "a formless seat on dry ground presses travel")
-- The seat holds still for the press. That second is casting, and casting is
-- not a stall.
local stallsBefore = count_log("STALL:")
clock = clock + 5.0
petrel.decide(view(x, -2300.0, { shapeshift_form_id = 0 }))
local castFlight = last_log("FLIGHT ")
check(castFlight:find('"cls":"casting"', 1, true) ~= nil,
  "the interval a cast owned is billed to casting")
check(field(castFlight, "cast_s") > 0.0, "casting seconds accumulate")
check(count_log("STALL:") == stallsBefore,
  "a form press is a named cost, not a stall")

-- Escapes report per occurrence: start, duration, outcome. Nothing latches,
-- so the second wedge of a run is as visible as the first.
local approach = petrel.decide(view(x, -2300.0))
check(approach.kind == "navigate", "back in form, back on the corridor")
local bx, by = approach.x, approach.y
clock = clock + 20.0
petrel.decide(view(x, -2300.0))
local escStart = last_log("ESCAPE: start")
check(escStart ~= nil, "a snag hop opens an escape episode")
check(escStart:find("kind=snag_hop", 1, true) ~= nil, "the episode names its kind")
check(escStart:find("dist=", 1, true) ~= nil,
  "the episode records how far the beat was when it opened")

-- Closing on the beat is what "freed" means; the hop reaching its sidestep
-- target is not.
local dx, dy = bx - x, by - (-2300.0)
local len = math.sqrt(dx * dx + dy * dy)
clock = clock + 5.0
petrel.decide(view(x + dx / len * 40.0, -2300.0 + dy / len * 40.0))
local escEnd = last_log("ESCAPE: end")
check(escEnd ~= nil, "the episode closes when the seat closes on the beat")
check(escEnd:find("outcome=freed", 1, true) ~= nil, "a freed escape says so")
check(escEnd:find("hops=", 1, true) ~= nil, "the episode counts its hops")
check(tonumber(escEnd:match("dur=([%d%.]+)")) > 0.0,
  "the episode carries its duration")

-- ---------------------------------------------------------------------
-- DECIDE GAPS (ticket 0030): a stall the brain was never called for is
-- named for what it is. The tick is fixed at ~5 Hz, so an interval past a
-- full sim-second has swallowed five turns — the 2026-08-15 champion spent
-- 205.4 of its 506.5 stationary sim-seconds inside intervals like that, and
-- every run's FIRST stall is one (STALL dec=2, next decide 6.2 sim-s later,
-- still dec=2). Those seconds are still billed to the stationary budget;
-- they are simply no longer blamed on the steering.
-- ---------------------------------------------------------------------
local gx = x + dx / len * 40.0
local gy = -2300.0 + dy / len * 40.0
clock = clock + 0.2
petrel.decide(view(gx, gy))
clock = clock + 0.2
petrel.decide(view(gx, gy))
local navStall = last_log("STALL:")
check(navStall:find("cause=host_gap", 1, true) == nil,
  "a stall observed at the decide cadence is never blamed on the host")

-- The same open episode, after the host swallows the next five turns.
local staBefore = field(last_log("FLIGHT "), "sta_s")
clock = clock + 3.0
petrel.decide(view(gx, gy))
clock = clock + 0.2
petrel.decide(view(gx + 60.0, gy))
local gapResume = last_log("RESUME:")
check(gapResume:find("cause=host_gap", 1, true) ~= nil,
  "an episode that swallowed a decide gap is re-owned by the gap")

-- ...and a gap that IS the opening interval names itself at the STALL line.
clock = clock + 3.0
petrel.decide(view(gx + 60.0, gy))
local openGap = last_log("STALL:")
check(openGap:find("cause=host_gap", 1, true) ~= nil,
  "a stall that opens across a decide gap names the gap from the start")
clock = clock + 5.0
petrel.decide(view(gx + 60.0, gy))
check(field(last_log("FLIGHT "), "sta_s") > staBefore + 3.0,
  "naming the host is not excusing it — the seconds still bill to stationary")

-- ---------------------------------------------------------------------
-- PACE BASIS (ticket 0030): the sheet measures against the speed the pose
-- actually owns. Aquatic Form is base swim x1.5, and this client's base
-- swim is the vanilla 4.722 yd/s — measured 7.01 yd/s median over 221
-- aquatic samples in run-20260815-193433-baseline against 5.00 formless in
-- the same water. Billed against the old 10.4 the pose read 0.68 forever,
-- and 853 of that run's 1,436 below-pace sim-seconds were an honest
-- full-speed swim.
-- ---------------------------------------------------------------------
local sx, sy = gx + 60.0, gy
for _ = 1, 3 do
  clock = clock + 5.0
  sx = sx + 7.08 * 5.0
  petrel.decide(view(sx, sy, { is_swimming = true, shapeshift_form_id = 4 }))
end
local swimFlight = last_log("FLIGHT ")
check(swimFlight:find('"cls":"at_pace"', 1, true) ~= nil,
  "an Aquatic Form seat at 7.08 yd/s is at pace, not 68% of a phantom 10.4")
check(field(swimFlight, "pace") >= 0.95 and field(swimFlight, "pace") <= 1.05,
  "and the pace it reports is the one it is actually swimming")

-- Strip the form and the same water bills the base swim: the x1.5 the spell
-- grants is the whole difference between the two numbers.
for _ = 1, 3 do
  clock = clock + 5.0
  sx = sx + 4.72 * 5.0
  petrel.decide(view(sx, sy, { is_swimming = true, shapeshift_form_id = 0 }))
end
local bareFlight = last_log("FLIGHT ")
check(field(bareFlight, "pace") >= 0.95 and field(bareFlight, "pace") <= 1.05,
  "a formless swim at 4.72 yd/s is full speed for that pose too")

print("test_petrel_split: " .. passed .. " ok")
