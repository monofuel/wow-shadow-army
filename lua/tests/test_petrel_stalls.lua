-- Ticket 0030: the three stall sources, each pinned by the behaviour that
-- replaces it.
--
-- Evidence these tests encode (2026-08-14 headed run + FLIGHT trace,
-- local_data/traverse-status/archive/run-20260814-232754-baseline.log and
-- run-20260814-s2-bracket.log):
--   * STARTUP — the first beat is 2,939 yd from the spawn pose, past the
--     fork's 400 yd coast gate, so the seat got no movement input until the
--     first corridor landed: STALL t=1786749767.1 cause=planning ->
--     RESUME dur=5.4 by=moved, on top of the opening form cast.
--   * WEDGE — 62 sim-s pinned at (-7678.4, -4045.3) with nav="following",
--     arrived down a clean straight line through (-7737.3, -3987.1) and
--     (-7703.6, -4021.0), and handed to the client's blind serpentine
--     (EV nav_no_route_escape) because this leg had no brain-side recovery.
--   * MOB DISPLACEMENT — the correction owed is toward the route line, not
--     merely away from the mob.
package.path = "lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;"

-- Recorded route data is local-only; see lua/tests/fixtures/petrel_route.lua.
local routeSource = require("tests.fixtures.petrel_route").select()
print("test_petrel_stalls: route = " .. routeSource)

local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local clock = 1000.0
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

local function log_find(needle)
  for _, line in ipairs(loggedLines) do
    if line:find(needle, 1, true) then return line end
  end
  return nil
end

--- Every scenario is a RUN: the kickstart, the tape and the form pacing are
--- all monotonic per run, so each one gets its own brain.
local function fresh()
  package.loaded["petrel"] = nil
  loggedLines = {}
  return require("petrel")
end

local function view(x, y, extra)
  local v = {
    location_known = true,
    location = { map_id = 1, position = { x = x, y = y, z = 12.0, o = 0.0 } },
    is_dead = false,
    is_ghost = false,
    is_swimming = false,
    liquid_known = false,
    liquid_coverage_known = false,
    liquid_submerged = false,
    shapeshift_form_id = 3,
    shapeshift_form_spell_id = 0,
    movement_allowed = true,
    rooted = false,
    health_known = true,
    health = 2754,
    units = {},
  }
  for k, v2 in pairs(extra or {}) do v[k] = v2 end
  return v
end

local function planar(ax, ay, bx, by)
  return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

-- ---------------------------------------------------------------------
-- 1. STARTUP: first movement input on the first decide.
-- ---------------------------------------------------------------------
local SPAWN_X, SPAWN_Y = -9187.0, -2530.2
local petrel = fresh()
nav = { state = "", failed_here = false, walkout_available = false,
  waypoint_count = 0 }
local opener = petrel.decide(view(SPAWN_X, SPAWN_Y, { shapeshift_form_id = 0 }))
check(opener.kind == "navigate",
  "the cold-engine opener is a movement intent, not a cast")
check(opener.navigation_mode == "local_steer",
  "with no corridor yet the opener steers by bearing — no plan to wait on")
check(opener.x == -9131.6 and opener.y == -2625.9,
  "the kickstart still steers at the run's own first beat (spawn corridor)")
check(opener.z == nil, "a bearing walk commands no z")
check(opener.status.kickstart == "steer", "and says so in its status")
check(log_find("KICKSTART: start") ~= nil, "the kickstart announces itself")

-- Planning is exactly the state the kickstart exists for: keep steering.
-- But local_steer returns before the route engine is asked, so the walk
-- must hand frames back or no corridor could ever land.
clock = clock + 0.2
nav = { state = "planning", failed_here = false, walkout_available = false,
  waypoint_count = 0 }
local planning = petrel.decide(view(SPAWN_X + 3.0, SPAWN_Y - 3.0,
  { shapeshift_form_id = 0 }))
check(planning.kind == "cast_spell",
  "with the body already moving the form press takes its turn")
local steerFrames, planFrames = 0, 0
for i = 1, 12 do
  clock = clock + 0.2
  local d = petrel.decide(view(SPAWN_X + 3.0 * i, SPAWN_Y - 3.0 * i))
  if d.status and d.status.kickstart == "steer" then
    steerFrames = steerFrames + 1
    check(d.navigation_mode == "local_steer", "steer frames steer by bearing")
  elseif d.status and d.status.kickstart == "plan" then
    planFrames = planFrames + 1
    check(d.navigation_mode == nil, "plan frames go to the route engine")
  end
end
check(steerFrames > planFrames and planFrames > 0,
  "the kickstart mostly steers but keeps asking for a corridor")

-- ...and the moment a corridor exists the kickstart is spent, for good.
clock = clock + 0.2
nav = { state = "following", failed_here = false, walkout_available = false,
  waypoint_count = 12 }
local corridor = petrel.decide(view(SPAWN_X + 40.0, SPAWN_Y - 40.0))
check(corridor.kind == "navigate" and corridor.navigation_mode == nil,
  "a served corridor ends the kickstart")
check(log_find("KICKSTART: end") ~= nil, "the kickstart end is logged")
clock = clock + 0.2
nav = { state = "planning", failed_here = false, walkout_available = false,
  waypoint_count = 0 }
local laterPlan = petrel.decide(view(SPAWN_X + 12.0, SPAWN_Y - 12.0))
check(laterPlan.navigation_mode == nil,
  "an ordinary mid-run replan never re-arms the kickstart")

-- A kickstart that outlives its window is just a blind walk: it expires on
-- displacement even if the engine never answers.
petrel = fresh()
nav = { state = "", failed_here = false, walkout_available = false,
  waypoint_count = 0 }
check(petrel.decide(view(SPAWN_X, SPAWN_Y)).navigation_mode == "local_steer",
  "fresh run arms the kickstart")
clock = clock + 15.0
local walked = petrel.decide(view(SPAWN_X + 130.0, SPAWN_Y - 130.0))
check(walked.navigation_mode == nil,
  "the kickstart expires once the seat has walked clear of the spawn pose")

-- A checkpoint start that drops the seat next to its beat must NOT kickstart:
-- inside the stop distance a bearing walk reports "reached" and stops the
-- seat, which is the exact failure this machinery exists to prevent.
petrel = fresh()
nav = { state = "", failed_here = false, walkout_available = false,
  waypoint_count = 0 }
-- 60 yd west of water_entry: inside its 50 yd stop plus the 20 yd margin.
local nextToBeat = petrel.decide(view(-6844.5, -4833.9))
check(nextToBeat.kind == "navigate" and nextToBeat.navigation_mode == nil,
  "a seat already on top of its beat never bearing-walks into a dead stop")

-- ...and on time, for a seat that is genuinely going nowhere.
petrel = fresh()
nav = { state = "", failed_here = false, walkout_available = false,
  waypoint_count = 0 }
petrel.decide(view(SPAWN_X, SPAWN_Y))
clock = clock + 40.0
local expired = petrel.decide(view(SPAWN_X, SPAWN_Y))
check(expired.navigation_mode == nil, "the kickstart window is bounded in time")

-- ---------------------------------------------------------------------
-- 2. WEDGE: retrace the incoming track instead of sawing at random.
-- ---------------------------------------------------------------------
-- The real approach: (-7737.3, -3987.1) -> (-7678.4, -4045.3), walked in
-- 8 yd strides, then the seat freezes on the wedge exactly as it did.
local WEDGE_X, WEDGE_Y = -7678.4, -4045.3
local function walk_to_wedge(brain)
  local x, y = -7737.3, -3987.1
  local dx, dy = WEDGE_X - x, WEDGE_Y - y
  local len = math.sqrt(dx * dx + dy * dy)
  local steps = math.floor(len / 8.0)
  for i = 0, steps do
    clock = clock + 1.0
    brain.decide(view(x + dx / len * (i * 8.0), y + dy / len * (i * 8.0)))
  end
  clock = clock + 1.0
  brain.decide(view(WEDGE_X, WEDGE_Y))
end

petrel = fresh()
nav = { state = "following", failed_here = false, walkout_available = false,
  waypoint_count = 12 }
walk_to_wedge(petrel)
-- 62 sim-s of nav="following" and not one yard of net displacement.
local wedgeHop = nil
for _ = 1, 80 do
  clock = clock + 1.0
  local d = petrel.decide(view(WEDGE_X, WEDGE_Y))
  if d.reason == "snag_hop" then wedgeHop = d break end
end
check(wedgeHop ~= nil,
  "a seat wedged on the coast approach escapes — this leg had no recovery")
check(wedgeHop.navigation_mode == "local_steer",
  "the retrace needs no corridor, and asks for none (replan storm capped)")
local retraceLog = log_find("retrace")
check(retraceLog ~= nil and retraceLog:find("SNAG:", 1, true) == 1,
  "the retrace names itself in the snag line")
local backDist = planar(WEDGE_X, WEDGE_Y, wedgeHop.x, wedgeHop.y)
check(backDist >= 10.0 and backDist <= 25.0,
  "the retrace steps 10-20 yd back, not a token nudge and not a new route")
-- BACKWARD along the incoming track: the dot product with the bearing to
-- the beat is negative. A blind serpentine is perpendicular; this is not.
local toBeatX, toBeatY = -7100.0 - WEDGE_X, -4600.0 - WEDGE_Y
local toHopX, toHopY = wedgeHop.x - WEDGE_X, wedgeHop.y - WEDGE_Y
check(toBeatX * toHopX + toBeatY * toHopY < 0.0,
  "the retrace walks BACK down the incoming track, not sideways")
-- The taped pose is one the seat actually held on the way in: it sits on
-- the walked approach segment, not merely somewhere behind us.
local function off_approach(px, py)
  local ax, ay = -7737.3, -3987.1
  local dx, dy = WEDGE_X - ax, WEDGE_Y - ay
  local t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
  if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
  return planar(px, py, ax + t * dx, ay + t * dy)
end
check(off_approach(wedgeHop.x, wedgeHop.y) < 2.0,
  "the retrace target sits on the walked approach line")
check(log_find("ESCAPE: start kind=snag_hop") ~= nil,
  "a retrace is still an escape episode, reported like any other")

-- The goal never rotates: when the window closes the same beat resumes.
clock = clock + 60.0
local resumed = petrel.decide(view(WEDGE_X - 12.0, WEDGE_Y + 12.0))
check(resumed.kind == "navigate" and resumed.reason ~= "snag_hop" and
    resumed.x == -7698.4,
  "after the retrace window the same beat resumes (spawn corridor serves it)")

-- A second retrace steps FURTHER back down the track. Retracing to a pose
-- retires the tape from there forward — otherwise the newest taped pose
-- would be the wedge itself and the pair would shuttle in and out of it.
petrel = fresh()
nav = { state = "following", failed_here = false, walkout_available = false,
  waypoint_count = 12 }
walk_to_wedge(petrel)
local hops = {}
for _ = 1, 200 do
  clock = clock + 1.0
  local d = petrel.decide(view(WEDGE_X, WEDGE_Y))
  if d.reason == "snag_hop" and d.navigation_mode == "local_steer" then
    if #hops == 0 or d.x ~= hops[#hops].x or d.y ~= hops[#hops].y then
      hops[#hops + 1] = { x = d.x, y = d.y }
    end
  end
end
check(#hops >= 2, "a wedge that holds gets more than one retrace")
check(planar(WEDGE_X, WEDGE_Y, hops[2].x, hops[2].y) >
    planar(WEDGE_X, WEDGE_Y, hops[1].x, hops[1].y),
  "the second retrace reaches further back, never forward into the wedge")

-- A wall the incoming track cannot undo still gets the old escalation:
-- retrace LEADS, it does not replace.
petrel = fresh()
nav = { state = "following", failed_here = false, walkout_available = false,
  waypoint_count = 12 }
walk_to_wedge(petrel)
local kinds = {}
for _ = 1, 400 do
  clock = clock + 1.0
  local d = petrel.decide(view(WEDGE_X, WEDGE_Y))
  if d.reason == "snag_hop" then
    kinds[#kinds + 1] = d.navigation_mode or "planned"
  end
end
local sawRetrace, sawPlanned = false, false
for _, k in ipairs(kinds) do
  if k == "local_steer" then sawRetrace = true end
  if k == "planned" then sawPlanned = true end
end
check(sawRetrace, "the escape opens with retraces")
check(sawPlanned,
  "a cluster the track cannot undo falls through to the flank escalation")

-- A step no body could have walked is not track: a checkpoint teleport (or
-- a server failsafe) must not hand the next escape a target across the map.
petrel = fresh()
nav = { state = "following", failed_here = false, walkout_available = false,
  waypoint_count = 12 }
walk_to_wedge(petrel)
clock = clock + 1.0
petrel.decide(view(-8600.0, -3000.0))  -- teleported: 1,300 yd in one frame
local jumped = nil
for _ = 1, 80 do
  clock = clock + 1.0
  local d = petrel.decide(view(-8600.0, -3000.0))
  if d.reason == "snag_hop" then jumped = d break end
end
check(jumped ~= nil, "the teleported seat still recovers")
check(jumped.navigation_mode == nil,
  "a teleport invalidates the tape — no retrace onto ground never walked")
check(planar(-8600.0, -3000.0, jumped.x, jumped.y) < 100.0,
  "and the fallback hop stays local")

-- A hop that has LANDED gives the rest of its window back. The window buys
-- one thing — a change of physical contact — and once the seat is standing
-- on the target that purchase is complete: local_steer answers "reached" and
-- STOPS the seat, which is the same dead stop the kickstart's stop-distance
-- guard exists to avoid. The 2026-08-15 baseline paid for the difference:
-- the retrace to (-605.8, -3005.0) landed 1.1 s into a 6.2 s window and the
-- seat then held (-602.6, -3003.3) with nav=reached until it expired
-- (STALL t=1786823912.0 cause=snag_hop -> RESUME dur=5.6 by=moved net=5.4).
petrel = fresh()
nav = { state = "following", failed_here = false, walkout_available = false,
  waypoint_count = 12 }
walk_to_wedge(petrel)
local landed = nil
for _ = 1, 80 do
  clock = clock + 1.0
  local d = petrel.decide(view(WEDGE_X, WEDGE_Y))
  if d.reason == "snag_hop" then landed = d break end
end
check(landed ~= nil, "the wedge hops, as before")
clock = clock + 1.0
local onTarget = petrel.decide(view(landed.x, landed.y))
check(onTarget.kind == "navigate" and onTarget.reason ~= "snag_hop",
  "a hop standing on its target hands the frame back to the beat")
check(log_find("HOP: landed at") ~= nil,
  "and reports the window seconds it returned to the run")
check(log_find("SNAG: hop") == nil,
  "the end of a hop is not logged as a new snag (the scorecard counts those)")
-- Still a deadline, not a dwell: a hop that has NOT landed keeps its window.
petrel = fresh()
nav = { state = "following", failed_here = false, walkout_available = false,
  waypoint_count = 12 }
walk_to_wedge(petrel)
local holding = nil
for _ = 1, 80 do
  clock = clock + 1.0
  local d = petrel.decide(view(WEDGE_X, WEDGE_Y))
  if d.reason == "snag_hop" then holding = d break end
end
clock = clock + 0.2
local stillHopping = petrel.decide(view(WEDGE_X + 1.0, WEDGE_Y))
check(stillHopping.reason == "snag_hop",
  "a seat still short of its hop target keeps the window open")
check(stillHopping.x == holding.x and stillHopping.y == holding.y,
  "and the hop target never moves under it")

-- ---------------------------------------------------------------------
-- 3. MOB DISPLACEMENT: bias back toward the route line.
-- ---------------------------------------------------------------------
-- Walk a clean stretch of the coast approach to lay down a track, then get
-- shoved off it while in combat.
petrel = fresh()
nav = { state = "following", failed_here = false, walkout_available = false,
  waypoint_count = 12 }
-- The track sits on the spawn-corridor chord spawn_7990 -> spawn_7740, so
-- "on line" means the line the corridor actually owns here.
local LX, LY = -7993.8, -3776.6
local BEAT_X, BEAT_Y = -7734.8, -3942.8
local ux, uy
do
  local dx, dy = BEAT_X - LX, BEAT_Y - LY
  local len = math.sqrt(dx * dx + dy * dy)
  ux, uy = dx / len, dy / len
end
for i = 0, 6 do
  clock = clock + 1.0
  petrel.decide(view(LX + ux * i * 8.0, LY + uy * i * 8.0))
end
local onLineX, onLineY = LX + ux * 6.0 * 8.0, LY + uy * 6.0 * 8.0

-- On the line, in combat: nothing to correct, the beat is the target.
clock = clock + 1.0
local onLine = petrel.decide(view(onLineX + ux * 8.0, onLineY + uy * 8.0,
  { in_combat = true }))
check(onLine.kind == "navigate" and onLine.x == BEAT_X and onLine.y == BEAT_Y,
  "an on-line seat in combat keeps steering at the beat itself")
check(onLine.status.line_bias == nil, "and reports no bias")

-- Shoved 35 yd perpendicular to the line: steer at the LINE, not the mob
-- and not straight at the distant beat from wherever we landed.
clock = clock + 1.0
local pushed = petrel.decide(view(onLineX - uy * 35.0, onLineY + ux * 35.0,
  { in_combat = true }))
check(pushed.kind == "navigate" and pushed.status.line_bias == true,
  "a displaced seat in combat is steered back onto the route line")
check(pushed.x ~= BEAT_X or pushed.y ~= BEAT_Y,
  "the commanded target is a point on the line, not the raw beat")
local biasOff = planar(pushed.x, pushed.y,
  onLineX - uy * 35.0, onLineY + ux * 35.0)
check(biasOff < 45.0, "the bias target is one stride away, not a new route")
check(log_find("EV combat_line_bias") ~= nil,
  "the bias engagement is logged as an event")

-- Out of combat the brain does not second-guess the client's line.
clock = clock + 1.0
local calm = petrel.decide(view(onLineX - uy * 35.0, onLineY + ux * 35.0))
check(calm.kind == "navigate" and calm.x == BEAT_X and calm.y == BEAT_Y,
  "off the line but out of combat, the beat stands")

print("test_petrel_stalls: " .. passed .. " ok")
