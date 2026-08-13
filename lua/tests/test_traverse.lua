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
local loggedLines = {}
_G.wow = {
  log = function(msg) loggedLines[#loggedLines + 1] = msg end,
  set_status = function() end,
  time = function() return clock end,
  nav_progress = function() return nav end,
  position = function() return nil end,
}

local function any_log(prefix)
  for _, line in ipairs(loggedLines) do
    if line:sub(1, #prefix) == prefix then return line end
  end
  return nil
end

local function any_log_find(needle)
  for _, line in ipairs(loggedLines) do
    if line:find(needle, 1, true) then return line end
  end
  return nil
end

local route = require("config.traverse_beats")
local landRoute = require("config.traverse_land_beats")
local connectorRoute = require("config.traverse_connector_land_beats")
local finaleRoute = require("config.traverse_finale_beats")
local petrel = require("traverse")

-- The route data survived the move off host-injected args.
check(route.goal_id == "duskwallow_coast", "route keeps the segment goal")
-- The north land phase is a SPARSE strategy-beat list (fair play): one beat
-- per road decision point, strictly increasing x (hook beats may decrease),
-- ending at the cave mouth.
check(landRoute.goal_id == "felwood_cave_entrance" and #landRoute.beats == 34,
  "land route is sparse and ends at the Timbermaw cave mouth")
check(connectorRoute.goal_id == "top_barrens" and #connectorRoute.beats == 9,
  "connector route reaches the northern land handoff")
check(finaleRoute.goal_id == "everlook" and #finaleRoute.beats == 11,
  "finale route runs north tunnel to Everlook (no exterior hold node)")
local interiorRoute = require("config.traverse_finale_interior_beats")
check(#interiorRoute.beats >= 30,
  "interior route carries the walked Timbermaw chain")
for _, b in ipairs(interiorRoute.beats) do
  check(b.hook == true,
    "interior beats are all hooks (galleries double back in x): " .. b.id)
  check(b.navigation_mode == "local_steer",
    "interior beats declare local_steer for the WMO: " .. b.id)
end
check(finaleRoute.beats[1].id == "timbermaw_north_tunnel",
  "finale starts at the north tunnel after the interior chain")
for i = 2, #landRoute.beats do
  check(landRoute.beats[i].hook or landRoute.beats[i].x > landRoute.beats[i - 1].x,
    "land beats march north monotonically (hooks exempt)")
end
check(#route.beats == 55, "route keeps every beat (incl. the two clearance guards)")
local wetCount = 0
for _, b in ipairs(route.beats) do
  if b.wet then wetCount = wetCount + 1 end
end
check(wetCount == 53, "route keeps the wet ribbon")
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

-- Selection is monotonic: mid-course on the painted Timbermaw road picks
-- the next beat ahead, never one behind, without having visited any earlier.
clock = clock + 5.0
local mid = petrel.decide(view(5500.0, -650.0, formed))
check(mid.kind == "navigate" and mid.x == 5600.0,
  "mid-Felwood selects timbermaw_road_02 ahead")
-- Past road_02's X band, the next painted beat is selected.
clock = clock + 5.0
local mid2 = petrel.decide(view(5650.0, -600.0, formed))
check(mid2.kind == "navigate" and mid2.x == 5850.0,
  "past road_02 selects timbermaw_road_03")

-- SPEEDRUN DOCTRINE: hurt and in combat on the Felwood road, the answer is
-- still only to keep running — no heal, no defensive cast, no stopping.
clock = clock + 5.0
local hurt = petrel.decide(view(5600.0, -1000.0, {
  shapeshift_form_id = 3, in_combat = true,
  health_known = true, health = 900, max_health = 2754,
}))
check(hurt.kind == "navigate",
  "low health in combat still just runs — never heals, never stops")

-- Flight recorder false-positive guard: ordinary on-corridor land nav
-- (before snag tests that deliberately freeze far off a test teleport)
-- must not emit EV off_line.
check(any_log("EV off_line") == nil,
  "ordinary land navigation never logs EV off_line")

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

-- Drift: a seat can be MOVING and still be snagged. When the client drops
-- to walkout it drives the seat sideways off the corridor forever, which the
-- frozen-seat test can never see. No closing on the beat for 15 sim-s is a
-- snag too, and it goes to the same hop machinery (same beat, always).
nav = { state = "walkout", failed_here = true, walkout_available = true }
clock = clock + 1.0
petrel.decide(view(3400.0, -1600.0, formed))
local drift = nil
for i = 1, 40 do
  clock = clock + 1.0
  local d = petrel.decide(view(3400.0 + (i % 2) * 2.0, -1600.0, formed))
  if d.reason == "snag_hop" then drift = d break end
end
check(drift ~= nil, "a moving seat that never closes on the beat hops too")

-- ...and a seat that IS closing on the beat is left alone. Walk it in on
-- the NEXT beat, so the drift watch starts clean the way it does in flight.
nav = { state = "following", failed_here = false, walkout_available = false }
clock = clock + 40.0
local closing = nil
local cx, cy = 3600.0, -1500.0
local bx, by = 3700.0, -1360.0
closing = petrel.decide(view(cx, cy, formed))
check(closing.reason ~= "snag_hop", "a fresh beat starts the drift watch clean")
for _ = 1, 12 do
  clock = clock + 1.0
  local dx, dy = bx - cx, by - cy
  local len = math.sqrt(dx * dx + dy * dy)
  cx, cy = cx + dx / len * 10.0, cy + dy / len * 10.0
  closing = petrel.decide(view(cx, cy, formed))
  if closing.reason == "snag_hop" then break end
end
check(closing.reason ~= "snag_hop", "honest progress toward the beat never hops")


-- A seat that walkout has carried far off the line is put back on the last
-- beat it actually stood on, not nudged 18 yd sideways.
nav = { state = "walkout", failed_here = true, walkout_available = true }
clock = clock + 40.0
-- Stand on felwood_road_bend so it becomes the proven ground...
petrel.decide(view(3813.0, -1324.0, formed))
-- ...then get dragged far off the line toward the beats beyond it.
local recovered = nil
for i = 1, 40 do
  clock = clock + 1.0
  local d = petrel.decide(view(3900.0 + (i % 2) * 2.0, -900.0, formed))
  if d.reason == "snag_hop" then recovered = d break end
end
check(recovered ~= nil, "a seat dragged off the line still hops")
check(math.abs(recovered.x - 3813.0) < 1.0 and math.abs(recovered.y + 1324.0) < 1.0,
  "the hop steers back to the last beat actually stood on")

-- Hook beats: past road_10 in X (x > road_11.x + PASSED_YARDS) must still
-- NAVIGATE to timbermaw_road_11 — hook exempts westward descent from the
-- monotonic-x skip. Clear any snag window left by the walkout tests, retire
-- road_09 by capture first (its X band still covers 6640: 6625+20), then
-- the test pose captures road_10 (20 yd away) and must select road_11.
-- Far enough from road_11 that it is not captured. Before the cave hold.
-- Proven-ground snag windows can last 4 + dist/8 sim-s (~50+ after the
-- walkout recovery hop); clear that before asserting pure navigate.
nav = { state = "following", failed_here = false, walkout_available = false }
clock = clock + 100.0
petrel.decide(view(6625.0, -1400.0, formed))  -- capture timbermaw_road_09
clock = clock + 1.0
local hookNav = petrel.decide(view(6640.0, -1520.0, formed))
check(hookNav.kind == "navigate" and hookNav.reason ~= "snag_hop"
    and hookNav.x == 6612.0,
  "hook beat timbermaw_road_11 is not x-skipped past its X band")

-- The cave mouth is a handoff: the walked interior chain owns Timbermaw.
-- Approaching the mouth in Travel now armors up OUTDOORS first: the seat
-- enters the picket already in bear (rolls 2-4 paid an indoor cast).
clock = clock + 20.0
local preBear = petrel.decide(view(6500.0, -2060.0, formed))
check(preBear.kind == "cast_spell" and preBear.spell == 5487,
  "the cave approach armors up in bear before entering")

-- timbermaw_01 (the mouth itself) captures immediately; the next intent
-- targets the first gallery beat and carries the fork steering features.
clock = clock + 5.0
local atCave = petrel.decide(view(6500.0, -2060.0,
  { shapeshift_form_id = 5 }))
check(atCave.kind == "navigate" and
    atCave.reason:find("^timbermaw_") ~= nil,
  "the cave mouth hands off to the walked interior chain")
check(math.sqrt((atCave.x - 6500.0) ^ 2 + (atCave.y + 2060.0) ^ 2) >= 14.9,
  "the interior target is a genuine stride away (lookahead skips the near beat)")
check(atCave.navigation_mode == "local_steer",
  "interior intents declare local_steer for the WMO")
check(atCave.allow_jump == true,
  "interior intents allow the advertised jump at the cave lip")

-- Once Timbermaw owns the run, a fall/failsafe relocation back into Felwood
-- must stay a finale failure instead of silently resuming the old land route.
clock = clock + 5.0
local afterFinaleFall = petrel.decide(view(5935.5, -1217.8, formed))
check(afterFinaleFall.kind == "navigate" and
    afterFinaleFall.reason == "timbermaw_02",
  "finale ownership survives a Timbermaw failsafe relocation")

-- The last WALKED beat now continues into the hand-authored exit-tunnel
-- line (no walked coverage there; roll 2 died when the route engine took
-- over at this exact pose).
clock = clock + 5.0
local tunnelNext = petrel.decide(view(6875.1, -2306.2, formed))
check(tunnelNext.kind == "navigate" and
    tunnelNext.reason:find("^timbermaw_tunnel") ~= nil,
  "the walked chain continues into the exit-tunnel line")

-- Reaching the tunnel mouth retires the cave chain and hands the run to
-- the Winterspring finale line.
clock = clock + 5.0
local interiorDone = petrel.decide(view(6606.3, -2363.0, formed))
check(interiorDone.kind == "navigate" and
    interiorDone.reason == "winterspring_west_entry",
  "the interior goal hands off past the auto-captured tunnel bridge")

clock = clock + 5.0
local atEverlook = petrel.decide(view(6687.3, -4647.7, formed))
check(atEverlook.kind == "hold" and atEverlook.reason == "everlook",
  "holds only at the final Everlook goal")

-- Flight recorder: land navigation emits FLIGHT telemetry with beat + xt.
local flightLine = any_log("FLIGHT ")
check(flightLine ~= nil, "land navigation logs a FLIGHT line")
check(flightLine:find('"beat":', 1, true) ~= nil, "FLIGHT carries beat")
check(flightLine:find('"xt":', 1, true) ~= nil, "FLIGHT carries xt")

-- EV unplanned_swim on land-phase swim (before aquatic form cast return).
loggedLines = {}
clock = clock + 20.0
local landSwim = petrel.decide(view(1200.0, -2300.0, {
  shapeshift_form_id = 3, is_swimming = true,
}))
check(any_log("EV unplanned_swim") ~= nil,
  "land-phase swim logs EV unplanned_swim")
check(landSwim.kind == "cast_spell" and landSwim.spell == 1066,
  "land-phase swim still casts aquatic form")

-- EV clip: dry |z| jump > 10 between consecutive frames.
loggedLines = {}
clock = clock + 1.0
petrel.decide(view(1200.0, -2300.0, {
  shapeshift_form_id = 3,
  location = { map_id = 1, position = { x = 1200.0, y = -2300.0, z = 14.0, o = 0.0 } },
}))
clock = clock + 0.1
petrel.decide(view(1200.0, -2300.0, {
  shapeshift_form_id = 3,
  location = { map_id = 1, position = { x = 1200.0, y = -2300.0, z = 64.0, o = 0.0 } },
}))
check(any_log("EV clip") ~= nil, "large dry z jump logs EV clip")

-- EV form_lost when shapeshift_form_id drops 3 -> 0.
loggedLines = {}
clock = clock + 1.0
petrel.decide(view(1200.0, -2300.0, { shapeshift_form_id = 3 }))
clock = clock + 0.1
petrel.decide(view(1200.0, -2300.0, { shapeshift_form_id = 0 }))
check(any_log_find("EV form_lost form=3") ~= nil,
  "form 3 -> 0 logs EV form_lost")

-- SPARSE ROUTE RECOVERY: the walked Timbermaw chain is dispatched through
-- the sparse navigator, which had no snag machinery at all — the run of
-- 2026-08-11 walked 380 yd into the cave, froze to the millimeter at
-- (6866.6, -2126.2) with nav=unavailable on timbermaw_17, and never
-- attempted a single recovery. Interior ownership is monotonic for the life
-- of a run, so the cave cannot be replayed on the instance that already
-- finished it: take a fresh brain.
package.loaded["traverse"] = nil
local cavePetrel = require("traverse")
clock = clock + 100.0
nav = { state = "following", failed_here = false, walkout_available = false }
-- Walk the gallery so the frozen pose steers at the next hold-chamber beat
-- like the live run did (interior beats are all hooks: they retire by
-- capture only). The chain is regenerated whenever spacing changes, so the
-- expectation is looked up by COORDINATE (the walked point past the ramp),
-- never by beat number.
local holdNextId
for _, b in ipairs(interiorRoute.beats) do
  if math.abs(b.x - 6886.6) < 0.2 and math.abs(b.y + 2104.7) < 0.2 then
    holdNextId = b.id
  end
end
check(holdNextId ~= nil, "the hold-chamber walked point is in the chain")
-- cave decides run in bear (form 5): the approach gate now casts bear
-- on any unformed/travel seat this deep into the finale band.
cavePetrel.decide(view(6854.6, -2114.7, { shapeshift_form_id = 5 }))
clock = clock + 1.0
cavePetrel.decide(view(6876.1, -2115.8, { shapeshift_form_id = 5 }))
clock = clock + 1.0
nav = { state = "unavailable", failed_here = true, walkout_available = false,
  waypoint_count = 0 }
local caveBeat = cavePetrel.decide(view(6866.6, -2126.2, { shapeshift_form_id = 5 }))
check(caveBeat.kind == "navigate" and caveBeat.reason == holdNextId,
  "the frozen interior pose steers at the next hold-chamber beat")
local caveHop = nil
for _ = 1, 20 do
  clock = clock + 1.0
  local d = cavePetrel.decide(view(6866.6, -2126.2, { shapeshift_form_id = 5 }))
  if d.reason == "snag_hop" then caveHop = d break end
end
check(caveHop ~= nil and caveHop.kind == "navigate",
  "a seat frozen inside Timbermaw hops instead of waiting forever")
check(caveHop.stop_distance == 4.0 and
    caveHop.route_profile == "prefer_ground",
  "the interior hop keeps the hop intent shape")
check(caveHop.status and caveHop.status.snag_hop == true and
    caveHop.status.phase == "timbermaw",
  "the interior hop reports the sparse phase")
local caveDx = caveHop.x - 6866.6
local caveDy = caveHop.y - (-2126.2)
check(math.sqrt(caveDx * caveDx + caveDy * caveDy) > 10.0,
  "the interior hop target is a genuine sidestep")

-- ...and the hop is repositioning only: once the window closes the SAME
-- beat is steered at again. Sparse routes never rotate a goal either.
clock = clock + 60.0
local caveResume = cavePetrel.decide(view(6866.6, -2126.2, { shapeshift_form_id = 5 }))
check(caveResume.kind == "navigate" and caveResume.reason == holdNextId,
  "after the interior hop window the same beat resumes")
nav = { state = "following", failed_here = false, walkout_available = false }

-- INDOORS FORM GATE: Travel Form is outdoor-only in 1.12. Inside a WMO
-- the brain must keep navigating formless (one edge-triggered EV) instead
-- of standing still to chat-cast a spell that can never succeed — the
-- Timbermaw crawl of 2026-08-12. Fresh brain: interior ownership and the
-- form-retry pacing are monotonic per run.
package.loaded["traverse"] = nil
local indoorPetrel = require("traverse")
clock = clock + 100.0
nav = { state = "following", failed_here = false, walkout_available = false }
local indoorBear = indoorPetrel.decide(view(6600.0, -2085.0,
  { shapeshift_form_id = 0, indoors_known = true, indoors = true }))
check(indoorBear.kind == "cast_spell" and indoorBear.spell == 5487,
  "an indoors formless seat armors up in Bear (never Travel)")
clock = clock + 5.0
local indoorMove = indoorPetrel.decide(view(6600.0, -2085.0,
  { shapeshift_form_id = 1, indoors_known = true, indoors = true }))
check(indoorMove.kind == "navigate",
  "an indoors bear-form seat navigates — no further casting")
check(any_log_find("EV form_denied_indoors") ~= nil,
  "the indoor denial logs one EV")
check(indoorMove.stop_distance == 4.0,
  "sparse stops stay strictly inside the capture radius")
clock = clock + 6.0
local indoorAgain = indoorPetrel.decide(view(6610.0, -2085.0,
  { shapeshift_form_id = 0, indoors_known = true, indoors = true }))
check(indoorAgain.kind == "navigate",
  "still navigating formless while indoors")
clock = clock + 20.0
local outdoorCast = indoorPetrel.decide(view(6620.0, -2085.0,
  { shapeshift_form_id = 0, indoors_known = true, indoors = false }))
-- Inside the cave-approach band the re-arm is BEAR: the seat is at the
-- mouth where the indoors flag flickers, and Travel is what got the old
-- runs killed re-casting into denial. True-outdoor Travel re-arms are
-- covered by the road tests far from the cave.
check(outdoorCast.kind == "cast_spell" and outdoorCast.spell == 5487,
  "stepping outside at the mouth re-arms BEAR, not Travel")
check(any_log_find('"indoors":true') ~= nil,
  "the flight recorder carries the indoors flag")

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
