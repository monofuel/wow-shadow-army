-- Ticket 0043: an indoors seat that is not making ground must leave, not wait.
--
-- Evidence (hosted v9 ereq_a0b084a5, petrel:v9, 2026-08-15 ingest): the seat
-- entered a building at (-8523, -3077) — 88 yd off the champion walked line
-- — logged indoors=true / EV form_denied_indoors, then sat in nav=walkout
-- with STALL cause=no_route for the rest of the 2,319 sim-s window.
-- Attempts 1-3 escaped by walking the whole tape and scored 1,616 yd/ks of
-- backtrack. Redesign: 2 decision cycles to a retrace, at most ~40 yd of
-- tape, two legs, then hold-and-report.
--
-- Attempt 2 autopsy (run-20260816-052122-0043): the Ratchet room escaped,
-- then a second indoor wedge at (866.7, -2349.9) logged form_denied_indoors
-- with nav=following and never produced an indoors_trap escape. Arming is
-- event-driven on every indoor stall, not only the farmhouse no_route site.
package.path = "lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;"

-- Recorded route data is local-only; see lua/tests/fixtures/petrel_route.lua.
local routeSource = require("tests.fixtures.petrel_route").select()
print("test_petrel_indoors: route = " .. routeSource)

local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local clock = 1000.0
local nav = { state = "following", failed_here = false,
  walkout_available = false, waypoint_count = 12 }
local loggedLines = {}
_G.wow = {
  log = function(msg) loggedLines[#loggedLines + 1] = msg end,
  set_status = function() end,
  time = function() return clock end,
  nav_progress = function() return nav end,
  position = function() return nil end,
  perf = function()
    return { fps = 4.0, wall_s = clock / 10.0, frame_dt = 0.25,
      decision_count = 0 }
  end,
}

local function log_find(needle)
  for _, line in ipairs(loggedLines) do
    if line:find(needle, 1, true) then return line end
  end
  return nil
end

local function fresh()
  package.loaded["petrel"] = nil
  loggedLines = {}
  nav = { state = "following", failed_here = false,
    walkout_available = false, waypoint_count = 12 }
  return require("petrel")
end

local function view(x, y, extra)
  local v = {
    location_known = true,
    location = { map_id = 1, position = { x = x, y = y, z = 9.0, o = 0.0 } },
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
    indoors_known = true,
    indoors = false,
    units = {},
  }
  for k, v2 in pairs(extra or {}) do v[k] = v2 end
  return v
end

local function planar(ax, ay, bx, by)
  return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

local function seg_distance(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
  if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
  return planar(px, py, ax + t * dx, ay + t * dy)
end

-- Hosted geometry: walked chord, the leave point, the farmhouse.
local CHORD_AX, CHORD_AY = -8743.9, -2977.5   -- spawn_8740
local LEAVE_X, LEAVE_Y = -8586.4, -3138.8
local TRAP_X, TRAP_Y = -8523.0, -3077.0
local DECIDE_DT = 1.0

local function stride(brain, fx, fy, tx, ty, extra)
  local dx, dy = tx - fx, ty - fy
  local len = math.sqrt(dx * dx + dy * dy)
  local steps = math.ceil(len / 10.0)
  for i = 1, steps do
    local d = len * i / steps
    clock = clock + DECIDE_DT
    brain.decide(view(fx + dx / len * d, fy + dy / len * d, extra))
  end
end

local function walk_into_building(brain)
  stride(brain, CHORD_AX, CHORD_AY, LEAVE_X, LEAVE_Y)
  stride(brain, LEAVE_X, LEAVE_Y, TRAP_X, TRAP_Y)
end

-- ---------------------------------------------------------------------
-- 1. THE TRAP: indoors + no_route + no displacement = escape, not a hold.
-- ---------------------------------------------------------------------
local petrel = fresh()
walk_into_building(petrel)

nav = { state = "walkout", failed_here = false, walkout_available = true,
  waypoint_count = 0 }
local escape, cycles = nil, 0
for _ = 1, 6 do
  clock = clock + DECIDE_DT
  cycles = cycles + 1
  local d = petrel.decide(view(TRAP_X, TRAP_Y, { indoors = true }))
  check(d.kind ~= "hold", "a trapped seat is never handed a hold intent")
  if d.reason == "indoors_trap" then escape = d break end
end
check(escape ~= nil, "the seat trapped in the building escapes on its own")
check(cycles <= 2,
  "the escape arrives within 2 decision cycles, not 2,319 sim-s")
check(escape.kind == "navigate",
  "the escape is a movement intent — the trap is losing yards, not armor")
check(escape.navigation_mode == "local_steer",
  "the retrace walks ground this body held: no corridor asked for")
check(escape.status.indoors_trap == true,
  "the intent names the trap it is escaping")

local back = planar(TRAP_X, TRAP_Y, escape.x, escape.y)
check(back >= 10.0 and back <= 40.0,
  "the retrace stays on the 10-40 yd tape bound")
check(seg_distance(escape.x, escape.y, LEAVE_X, LEAVE_Y, TRAP_X, TRAP_Y) < 2.0,
  "and the target sits on the line the seat actually walked in on")

check(log_find("ESCAPE: start kind=indoors_trap") ~= nil,
  "the escape opens an episode under its own cause tag")
local snagLine = log_find("SNAG: indoors trap")
check(snagLine ~= nil and snagLine:find("retrace", 1, true) ~= nil,
  "the snag line says indoors trap, and says it retraced")
check(log_find("cause=indoors_trap") ~= nil,
  "the stall ledger tags the trap by room, not just no_route")
check(log_find("EV form_denied_indoors") ~= nil,
  "the indoors form denial still reports, exactly as the hosted episode did")

-- ---------------------------------------------------------------------
-- 2. BOUNDED + TERMINATING: two legs, then hold. Never the whole tape.
-- ---------------------------------------------------------------------
petrel = fresh()
walk_into_building(petrel)
nav = { state = "walkout", failed_here = false, walkout_available = true,
  waypoint_count = 0 }
local hops, sawHold = {}, false
for _ = 1, 40 do
  clock = clock + DECIDE_DT
  local d = petrel.decide(view(TRAP_X, TRAP_Y, { indoors = true }))
  if d.reason == "indoors_trap" and d.kind == "navigate" then
    if #hops == 0 or d.x ~= hops[#hops].x or d.y ~= hops[#hops].y then
      hops[#hops + 1] = { x = d.x, y = d.y }
    end
    check(planar(TRAP_X, TRAP_Y, d.x, d.y) <= 40.0,
      "no retrace leg walks more than 40 yd down the tape")
  elseif d.kind == "hold" and d.reason == "indoors_trap" then
    sawHold = true
    break
  end
end
check(#hops == 2, "the trap gets exactly two retrace legs, not the whole tape")
check(planar(TRAP_X, TRAP_Y, hops[2].x, hops[2].y) >
    planar(TRAP_X, TRAP_Y, hops[1].x, hops[1].y),
  "the second retrace reaches further back, never into the building")
check(sawHold, "after two failed legs the seat holds rather than wander")
check(log_find("ESCAPE: held indoors_trap") ~= nil,
  "the hold is reported under the same cause tag")
check(log_find("outcome=held") ~= nil,
  "the escape episode closes as held, not abandoned")

-- A hold that keeps holding is the point: a lost episode beats 1,616 yd.
-- Formless on purpose: the spent trap must not stand to press bear.
clock = clock + DECIDE_DT
local stillHeld = petrel.decide(view(TRAP_X, TRAP_Y,
  { indoors = true, shapeshift_form_id = 0 }))
check(stillHeld.kind == "hold" and stillHeld.reason == "indoors_trap",
  "a spent trap does not re-arm more hops or stand to cast")

-- ---------------------------------------------------------------------
-- 3. RE-ENGAGE: outdoors + a serving route resumes the beat line.
-- ---------------------------------------------------------------------
clock = clock + 1.0
nav = { state = "following", failed_here = false, walkout_available = false,
  waypoint_count = 12 }
local resumed = petrel.decide(view(LEAVE_X, LEAVE_Y))
check(resumed.kind == "navigate" and resumed.reason == "spawn_8490",
  "with the route serving again the run rejoins its own beat line")
check(resumed.x == -8506.0 and resumed.y == -3221.2,
  "and steers at the beat itself — the escape never rotated the goal")

-- ---------------------------------------------------------------------
-- 4. NOT A TRAP: indoors and travelling is the Timbermaw crossing.
-- ---------------------------------------------------------------------
petrel = fresh()
walk_into_building(petrel)
nav = { state = "walkout", failed_here = false, walkout_available = true,
  waypoint_count = 0 }
local trapped = false
for i = 1, 20 do
  clock = clock + DECIDE_DT
  local d = petrel.decide(view(TRAP_X - i * 7.0, TRAP_Y - i * 7.0,
    { indoors = true }))
  if d.reason == "indoors_trap" then trapped = true end
end
check(not trapped,
  "an indoors seat that is making ground is crossing, not trapped")

-- ---------------------------------------------------------------------
-- 5. BEAR FORM: walkout/unavailable is not a reason to drop armor.
--    Gate the stance skip on trapArmed alone. Timbermaw (and any other
--    indoor walkout that is still moving, or has not sat for 2 decides)
--    still armors up. An armed trap issues the retrace, not a cast.
-- ---------------------------------------------------------------------
petrel = fresh()
walk_into_building(petrel)
nav = { state = "walkout", failed_here = false, walkout_available = true,
  waypoint_count = 0 }
clock = clock + DECIDE_DT
local firstPin = petrel.decide(view(TRAP_X, TRAP_Y,
  { indoors = true, shapeshift_form_id = 0 }))
check(firstPin.kind == "cast_spell" and firstPin.spell == 5487,
  "indoor walkout before the trap arms still presses bear")

-- Expire FORM_RETRY so the next decide is free to cast. The armed trap
-- must still issue the retrace instead.
clock = clock + 16.0
local secondPin = petrel.decide(view(TRAP_X, TRAP_Y,
  { indoors = true, shapeshift_form_id = 0 }))
check(secondPin.kind == "navigate" and secondPin.reason == "indoors_trap",
  "once the trap arms the decide is the retrace, not another bear press")

-- ---------------------------------------------------------------------
-- 6. SECOND ROOM: form_denied_indoors + nav=following still arms.
--    Attempt 2 (run-20260816-052122-0043) escaped Ratchet, then wedged
--    at (866.7, -2349.9) on the Barrens climb — clip, form_denied_indoors,
--    nav=following, no indoors_trap event, timeout at max_northing 10064.5.
-- ---------------------------------------------------------------------
petrel = fresh()
local CLIP_X, CLIP_Y = 774.3, -2356.4
local PIN_X, PIN_Y = 866.7, -2349.9
-- Retire the connector the hosted run already walked so the pin sits on
-- top_barrens, not a hook beat south of the climb. Jumps reset the tape;
-- the last stride re-lays it.
for _, p in ipairs({
  { -900.0, -3750.0 }, { -950.0, -3650.0 }, { -1000.0, -3500.0 },
  { -950.0, -3250.0 }, { -800.0, -3050.0 }, { -620.1, -3058.9 },
  { 22.8, -2723.1 }, { 674.9, -2393.2 },
  { 738.0, -2302.0 }, { 827.0, -2289.0 },
  { 901.0, -2291.0 }, { 990.0, -2288.0 },
}) do
  clock = clock + DECIDE_DT
  petrel.decide(view(p[1], p[2]))
end
stride(petrel, CLIP_X, CLIP_Y, PIN_X, PIN_Y)
nav = { state = "following", failed_here = false, walkout_available = false,
  waypoint_count = 12 }
local secondEscape, secondCycles = nil, 0
for _ = 1, 6 do
  clock = clock + DECIDE_DT
  secondCycles = secondCycles + 1
  local d = petrel.decide(view(PIN_X, PIN_Y,
    { indoors = true, shapeshift_form_id = 5 }))
  check(d.kind ~= "hold" or d.reason == "indoors_trap",
    "the Barrens indoor wedge is never a silent hold")
  if d.reason == "indoors_trap" and d.kind == "navigate" then
    secondEscape = d
    break
  end
end
check(secondEscape ~= nil,
  "a seat wedged indoors on a serving corridor still escapes")
check(secondCycles <= 2,
  "the second indoor occurrence arms within 2 decision cycles")
check(secondEscape.navigation_mode == "local_steer",
  "the second room reuses the 0030 retrace, no new movement primitive")
check(planar(PIN_X, PIN_Y, secondEscape.x, secondEscape.y) <= 40.0,
  "the Barrens retrace stays inside the 40 yd bound")
check(log_find("ESCAPE: start kind=indoors_trap") ~= nil,
  "the second room reports its own indoors_trap episode")
check(log_find("EV form_denied_indoors") ~= nil,
  "form_denied_indoors still fires at the Barrens pin")

clock = clock + 1.0
nav = { state = "following", failed_here = false, walkout_available = false,
  waypoint_count = 12 }
local climbResume = petrel.decide(view(secondEscape.x, secondEscape.y))
check(climbResume.kind == "navigate" and climbResume.reason == "top_barrens",
  "leaving the Barrens room rejoins the climb beat, not a rotated goal")
check(climbResume.x == 1071.6 and climbResume.y == -2303.4,
  "and steers at top_barrens itself")

-- ---------------------------------------------------------------------
-- 7. HOSTED v27 FLOOR: the same farmhouse, but indoors=false after a
--    through-floor clip. ereq_990e728e sat at (-8525.7,-3051.0) for
--    2300s with nav=unavailable; 0043 never armed. Steer south at
--    gazer2 on bearing instead of holding the 661 northing.
-- ---------------------------------------------------------------------
petrel = fresh()
nav = { state = "unavailable", failed_here = true, walkout_available = false,
  waypoint_count = 0 }
local hole = petrel.decide(view(-8525.7, -3051.0, { indoors = false }))
check(hole.kind == "navigate" and hole.x == -8566.0 and hole.y == -3130.8,
  "the indoors-false farmhouse hole steers at gazer2, not spawn_8490")
check(hole.navigation_mode == "local_steer",
  "hosted has no mmap in the hole — bearing, not a mesh corridor")
check(log_find("EV farmhouse_hole") ~= nil,
  "the hole reports itself so the next hosted log names the room")

-- Same room, 675's clip pose: host-gap +X from dune2, still indoors=false.
petrel = fresh()
nav = { state = "planning", failed_here = false, walkout_available = false,
  waypoint_count = 0 }
local clip675 = petrel.decide(view(-8543.5, -3056.0, { indoors = false }))
check(clip675.kind == "navigate" and clip675.x == -8566.0
    and clip675.y == -3130.8,
  "the 675 clip pose also steers south at gazer2")
check(clip675.navigation_mode == "local_steer",
  "and it is a bearing walk, not a mesh ask the hole cannot serve")

-- 8. HOSTED v28 FLOOR: same WMO, but the clip snapped onto the roof.
--    ereq_9f1378f7 sat at (-8530.6,-3070.5,z=28.6) for 2392s, hp 2754,
--    MOVEGATE "terrain slope is too steep" — gazer2 is south down that
--    face. Steer west at dune2 (the clip-in pin). No jump: a 16 yd
--    roof drop is fall damage.
-- ---------------------------------------------------------------------
petrel = fresh()
nav = { state = "local_steer", failed_here = false, walkout_available = false,
  waypoint_count = 0 }
local roofView = view(-8530.6, -3070.5, { indoors = false })
roofView.location.position.z = 28.6
local roof = petrel.decide(roofView)
check(roof.kind == "navigate" and roof.x == -8574.7 and roof.y == -3050.9,
  "the v28 roof pose steers west at dune2, not south down gazer2")
check(roof.navigation_mode == "local_steer",
  "roof exit is a bearing walk — hosted has no mmap on the WMO")
check(roof.allow_jump ~= true,
  "the roof walk does not jump — fall damage is WARN hp")
check(log_find("EV farmhouse_roof") ~= nil,
  "the roof reports itself so the next hosted log names the snap")

-- Underground clip on the same episode: z=-83.2 at (-8542.7,-3053.6)
-- walked south under the WMO before the roof snap. Back out west.
petrel = fresh()
nav = { state = "local_steer", failed_here = false, walkout_available = false,
  waypoint_count = 0 }
local underView = view(-8542.7, -3053.6, { indoors = false })
underView.location.position.z = -83.2
local under = petrel.decide(underView)
check(under.kind == "navigate" and under.x == -8574.7 and under.y == -3050.9,
  "the underground clip backs out west at dune2, not deeper south")
check(under.allow_jump ~= true,
  "the underground walk does not jump either")
check(log_find("EV farmhouse_under") ~= nil,
  "the underground clip reports itself")

print("test_petrel_indoors: " .. passed .. " ok")
