package.path = "lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;"

local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local clock = 100.0
local nav = { state = "following", failed_here = false, walkout_available = false }
_G.wow = {
  log = function() end,
  set_status = function() end,
  time = function() return clock end,
  nav_progress = function() return nav end,
  position = function() return nil end,
}

local route = require("config.traverse_beats")
local landRoute = require("config.traverse_land_beats")
local petrel = require("traverse")

-- The route data survived the move off host-injected args.
check(route.goal_id == "duskwallow_coast", "route keeps the segment goal")
-- The north land phase is a SPARSE strategy-beat list (fair play): one beat
-- per road decision point, strictly increasing x, ending at the cave mouth.
check(landRoute.goal_id == "felwood_cave_entrance" and #landRoute.beats == 23,
  "land route is sparse and ends at the Timbermaw cave mouth")
for i = 2, #landRoute.beats do
  check(landRoute.beats[i].x > landRoute.beats[i - 1].x,
    "land beats march north monotonically")
end
check(#route.beats == 50, "route keeps every beat")
local wetCount = 0
for _, b in ipairs(route.beats) do
  if b.wet then wetCount = wetCount + 1 end
end
check(wetCount == 48, "route keeps the wet ribbon")
check(route.beats[1].id == "land_approach" and route.beats[2].id == "water_entry",
  "land legs lead the route")

local function view(x, y, extra)
  local v = {
    location_known = true,
    location = { map_id = 1, position = { x = x, y = y, z = 14.0, o = 0.0 } },
    is_dead = false,
    is_ghost = false,
    is_swimming = false,
    liquid_known = false,
    liquid_coverage_known = false,
    liquid_submerged = false,
    shapeshift_form_id = 0,
    shapeshift_form_spell_id = 0,
    movement_allowed = true,
    rooted = false,
    can_reclaim_corpse = false,
    units = {},
  }
  for k, v2 in pairs(extra or {}) do v[k] = v2 end
  return v
end

-- All brain clocks run on wow.time(), which is SIMULATION time (10x in
-- leagues) — windows in the brain are sim-scaled to match.

-- Speed first: an unformed druid on dry open ground casts Travel Form.
local spawn = view(-9187.0, -2530.25)
local opener = petrel.decide(spawn)
check(opener.kind == "cast_spell" and opener.spell == 783,
  "casts travel form at spawn")
clock = clock + 10.0
local throttled = petrel.decide(view(-9187.0, -2530.25))
check(throttled.kind ~= "cast_spell", "does not spam the form cast")

-- In form, the land legs walk the coast approach in order.
local formed = { shapeshift_form_id = 3 }
local leg = petrel.decide(view(-9100.0, -2600.0, formed))
check(leg.kind == "navigate", "navigates once formed")
check(leg.x == -7100.0 and leg.y == -4600.0, "first leg is the land approach")
check(leg.route_profile == "prefer_ground", "land legs prefer walkable ground")
check(leg.z ~= nil, "land legs keep their z")
check(leg.status and leg.status.beat == "land_approach", "status names the beat")
check(leg.status.dist_goal and leg.status.dist_goal > 0,
  "status carries planar distance to the goal")

-- Past the approach band, the target is the water entry, never the beach
-- behind us.
clock = clock + 5.0
local coastward = petrel.decide(view(-7050.0, -4650.0, formed))
check(coastward.kind == "navigate" and coastward.x == -6784.5,
  "second leg is the water entry")

-- At the coast the land pass is complete: hold for the swim pass, do not
-- enter the water.
clock = clock + 5.0
local arrived = petrel.decide(view(-6790.0, -4840.0, formed))
check(arrived.kind == "hold" and arrived.reason == "awaiting_swim_pass",
  "holds at the coast awaiting the swim pass")

-- SPEEDRUN RULE: never fight. A hostile on top of us changes nothing.
clock = clock + 5.0
local mobbed = petrel.decide(view(-8000.0, -3500.0, {
  shapeshift_form_id = 3,
  in_combat = true,
  units = { {
    guid = 42, name = "Fire Roc", distance = 3.0,
    player_can_attack = true, death_known = true, is_dead = false,
  } },
}))
check(mobbed.kind == "navigate", "keeps running when attacked")

-- SPEEDRUN RULE: a stall never rotates the goal — the route stands while
-- the stall is logged as evidence.
local stuckAt = view(-8000.0, -3500.0, formed)
petrel.decide(stuckAt)
clock = clock + 100.0
local stalled = petrel.decide(view(-8000.5, -3500.0, formed))
check(stalled.kind == "navigate" and stalled.x == -7100.0,
  "a stall keeps the same goal")
check(stalled.status.stalled_seconds > 80.0, "the stall is reported")

-- A pinned pose failure poisons ALL new planning; switching beats there
-- discards the only corridor that exists. The goal must stand no matter
-- how long the failure lasts.
nav = { state = "unavailable", failed_here = true, walkout_available = false,
  waypoint_count = 883 }
clock = clock + 200.0
local pinned = petrel.decide(view(-8000.0, -3500.0, formed))
check(pinned.kind == "navigate" and pinned.x == -7100.0,
  "a pinned pose failure never rotates the goal")

-- Only a beat the engine could never plan for, from a healthy pose, gets
-- skipped — and only after the patience window.
nav = { state = "unavailable", failed_here = false, walkout_available = false,
  waypoint_count = 0 }
clock = clock + 5.0
local patient = petrel.decide(view(-8000.0, -3500.0, formed))
check(patient.kind == "navigate" and patient.x == -7100.0,
  "an unplannable beat gets patience first")
clock = clock + 65.0
local skippingFrame = petrel.decide(view(-8000.0, -3500.0, formed))
check(skippingFrame.kind == "hold" and skippingFrame.reason == "replanning",
  "an unplannable beat is skipped after the patience window")
nav = { state = "following", failed_here = false, walkout_available = false }
clock = clock + 1.0
local rerouted = petrel.decide(view(-8000.0, -3500.0, formed))
check(rerouted.kind == "navigate" and rerouted.x == -6784.5,
  "the run continues on the next beat")

-- Swimming off plan still takes Aquatic Form: drowning slowly is not a plan.
clock = clock + 10.0
local wet = petrel.decide(view(-6700.0, -4870.0, {
  shapeshift_form_id = 3, is_swimming = true,
}))
check(wet.kind == "cast_spell" and wet.spell == 1066,
  "casts aquatic form when wet")

-- NORTH LAND PHASE: a checkpoint start at the top of the Barrens takes
-- Travel Form and runs the sparse road beats toward the Timbermaw cave.
clock = clock + 20.0
local northUnformed = petrel.decide(view(1071.6, -2303.4))
check(northUnformed.kind == "cast_spell" and northUnformed.spell == 783,
  "top-of-Barrens start casts Travel Form (mid_coast guard lifted)")
clock = clock + 20.0
local north1 = petrel.decide(view(1071.6, -2303.4, formed))
check(north1.kind == "navigate" and north1.x == 1191.7,
  "first land beat is the Ashenvale south road")
check(north1.status and north1.status.phase == "north_land",
  "land phase is visible in status")
check(north1.route_profile == "prefer_ground" and north1.stop_distance == 8.0,
  "land legs ground-route with a decisive stop")

-- Selection is monotonic: mid-Felwood picks the next beat ahead, never one
-- behind, without having visited any earlier beat.
clock = clock + 5.0
local mid = petrel.decide(view(5650.0, -1000.0, formed))
check(mid.kind == "navigate" and mid.x == 5720.0,
  "mid-Felwood selects the next road beat ahead")
-- Just short of the north collision-trap dodge the dodge is what gets
-- steered at, so the corridor swings wide of (5645,-1069).
clock = clock + 5.0
local preDodge = petrel.decide(view(5545.0, -1000.0, formed))
check(preDodge.kind == "navigate" and preDodge.x == 5585.0,
  "north trap dodge is selected before north_road_2")

-- SPEEDRUN DOCTRINE: hurt and in combat on the Felwood road, the answer is
-- still only to keep running — no heal, no defensive cast, no stopping.
clock = clock + 5.0
local hurt = petrel.decide(view(5600.0, -1000.0, {
  shapeshift_form_id = 3, in_combat = true,
  health_known = true, health = 900, max_health = 2754,
}))
check(hurt.kind == "navigate",
  "low health in combat still just runs — never heals, never stops")

-- Collision snag: pinned pose (unavailable + failed_here + no walkout) with
-- a frozen seat opens a short perpendicular hop window — the goal itself
-- never rotates, and the hop resumes the same beat after the window.
nav = { state = "unavailable", failed_here = true, walkout_available = false,
  waypoint_count = 0 }
clock = clock + 5.0
petrel.decide(view(3322.0, -1640.0, formed))
for _ = 1, 8 do
  clock = clock + 1.0
  petrel.decide(view(3322.0, -1640.0, formed))
end
local hop = petrel.decide(view(3322.0, -1640.0, formed))
check(hop.kind == "navigate" and hop.reason == "snag_hop",
  "a pinned frozen seat hops sideways")
local hopDx, hopDy = hop.x - 3322.0, hop.y - (-1640.0)
check(math.sqrt(hopDx * hopDx + hopDy * hopDy) > 10.0,
  "the hop target is a genuine sidestep")
-- A WALL, not a point object: when the same cluster keeps holding the seat,
-- the hop REACH grows (18 -> 36 -> 54 -> 72 yd) so a long baked wall can be
-- walked around instead of rubbed along. The goal still never rotates.
local function hopFrom(x, y)
  for _ = 1, 20 do
    clock = clock + 1.0
    local d = petrel.decide(view(x, y, formed))
    if d.reason == "snag_hop" then
      return math.sqrt((d.x - x) ^ 2 + (d.y - y) ^ 2)
    end
  end
  return nil
end
local firstReach = math.sqrt(hopDx * hopDx + hopDy * hopDy)
local grownReach = nil
for _ = 1, 12 do
  clock = clock + 30.0
  local r = hopFrom(3322.0, -1640.0)
  if r then grownReach = r end
end
check(grownReach ~= nil and grownReach > firstReach * 1.5,
  "a cluster that keeps holding the seat gets a longer hop reach")

-- Let the last (long) hop window close before checking the resume.
clock = clock + 40.0
nav = { state = "following", failed_here = false, walkout_available = false }
clock = clock + 7.0
local resumed = petrel.decide(view(3330.0, -1655.0, formed))
check(resumed.kind == "navigate" and resumed.reason ~= "snag_hop",
  "after the hop window the same beat resumes")

-- The cave mouth is the segment goal: hold there, alive.
clock = clock + 5.0
local atCave = petrel.decide(view(6500.0, -2060.0, formed))
check(atCave.kind == "hold" and atCave.reason == "felwood_cave_entrance",
  "holds at the Timbermaw cave mouth")

-- DOCTRINE GUARD: the brain must never contain form-cancel chat commands or
-- heal/defensive spells. Multiple AIs have now tried both; both are fatal
-- on a speedrun (casting stands still, and the cancel command does not
-- exist in 1.12). See docs/traverse/README.md.
local srcFile = assert(io.open("lua/entry/traverse.lua", "r"))
local src = srcFile:read("*a")
srcFile:close()
check(not src:lower():find("cancelform"),
  "doctrine guard: no form-cancel command in the brain")
for _, spellId in ipairs({ 25297, 25299, 22812, 17329, 5185, 774 }) do
  check(not src:find("%f[%d]" .. spellId .. "%f[%D]"),
    "doctrine guard: no heal/defensive spell " .. spellId .. " in the brain")
end

-- SPEEDRUN RULE: death is the end of the run. No release, no corpse run,
-- no reclaim — ever. The fix for dying lives in the pathfinding, not here.
local dead = petrel.decide(view(-8000.0, -3500.0, { is_dead = true }))
check(dead.kind == "hold" and dead.reason == "run_over",
  "death ends the run")
local ghost = petrel.decide(view(-8000.0, -3500.0, {
  is_ghost = true, can_reclaim_corpse = true,
  corpse_known = true,
  corpse_location = { map_id = 1, position = { x = 1, y = 2, z = 3 } },
}))
check(ghost.kind == "hold" and ghost.reason == "run_over",
  "a reclaimable corpse still ends the run — never corpse-run")

print("test_traverse: " .. passed .. " ok")
