-- Petrel: the traverse speedrun brain. Kalimdor south to north; score is
-- pure X-northing toward Everlook, 270 wall seconds at 10x.
--
-- SPEEDRUN RULES (non-negotiable, from monofuel's manual run):
--   * NEVER fight. No attack intents, ever. The run is running and swimming.
--   * NEVER corpse-run. Death means the run is over: hold "run_over", stop.
--     Do not add corpse recovery here — if the bot died, the bug is whatever
--     let it stop moving (pathfinding, streaming), and that is what gets
--     fixed. A moving bot does not die to mobs.
--   * Keep moving. A stall is evidence to log loudly, not a state to farm.
--
-- Route: sparse beats in lua/config/traverse_beats.lua — a land approach to
-- the Tanaris coast, then the manual-run cheese ribbon to the Dustwallow
-- coast, wet chain, Barrens connector, and finale
-- (see docs/traverse/README.md).

local M = { name = "petrel" }

local ROUTE = require("config.petrel.traverse_beats")
local SPAWN = require("config.petrel.traverse_spawn_beats")
local LAND = require("config.petrel.traverse_land_beats")
local COAST = require("config.petrel.traverse_coast_beats")
local CONNECT_WET = require("config.petrel.traverse_connector_wet_beats")
local CONNECT_LAND = require("config.petrel.traverse_connector_land_beats")
-- Timbermaw interior: walked-ground beats resampled from monofuel's manual
-- F9 cave logs (tools/resample_trace_beats.py; docs/traverse/
-- reference-logs.md). Live navigation through the WMO needs the fork's
-- local_steer + allow_jump features (ledgered); until they land, these
-- beats route like any others and the finale stays blocked at the cave.
local INTERIOR = require("config.petrel.traverse_finale_interior_beats")
local FINALE = require("config.petrel.traverse_finale_beats")

-- Junction deck (timbermaw_35..47). Cave battery 2026-08-16: every run
-- stalled here (~6838,-2109), indoors_trap hopped back toward Felwood,
-- then 15 yd lookahead skipped 42->45 through the WMO floor (z 625 -> -425)
-- and the failsafe dumped them onto the Felwood road still targeting 45.
-- z floor keeps the 0043 through-floor column (z~14) able to arm.
local JUNCTION_MIN_X, JUNCTION_MAX_X = 6810.0, 6900.0
local JUNCTION_MIN_Y, JUNCTION_MAX_Y = -2130.0, -2090.0
local JUNCTION_MIN_Z = 610.0

local function on_junction_deck(pos)
  return pos.x >= JUNCTION_MIN_X and pos.x <= JUNCTION_MAX_X
    and pos.y >= JUNCTION_MIN_Y and pos.y <= JUNCTION_MAX_Y
    and (pos.z or 0) >= JUNCTION_MIN_Z
end

-- Tanaris farmhouse WMO at (-8523,-3077). Hosted v27 hole stalls
-- (ereq_990e728e score 661, ereq_c723171f score 675) clipped through
-- it (z to -291) with indoors=false, then sat 2300s at x=-8526.
-- v28 ereq_9f1378f7 (score 656) kept clipping (z to -83.2) then
-- snapped onto the roof (-8530.6,-3070.5,z=28.6) and sat 2392s;
-- gazer2 is south down that slope and MOVEGATE-blocked.
-- Ground (z in [5,20)) exits south at gazer2. Roof and underground
-- clips exit west at dune2 — the pin they clipped in from. No jump:
-- a 16 yd roof drop is fall damage (WARN hp).
local FARMHOUSE_MIN_X, FARMHOUSE_MAX_X = -8550.0, -8495.0
local FARMHOUSE_MIN_Y, FARMHOUSE_MAX_Y = -3110.0, -3035.0
local FARMHOUSE_HOLE_EXIT_ID = "spawn_dodge_8740_gazer2"
local FARMHOUSE_WEST_EXIT_ID = "spawn_dodge_8740_dune2"
local FARMHOUSE_ROOF_Z = 20.0
local FARMHOUSE_UNDER_Z = 5.0

local function in_tanaris_farmhouse(pos)
  return pos.x >= FARMHOUSE_MIN_X and pos.x <= FARMHOUSE_MAX_X
    and pos.y >= FARMHOUSE_MIN_Y and pos.y <= FARMHOUSE_MAX_Y
end

local function farmhouse_kind(pos)
  local z = pos.z or 0
  if z >= FARMHOUSE_ROOF_Z then return "farmhouse_roof" end
  if z < FARMHOUSE_UNDER_Z then return "farmhouse_under" end
  return "farmhouse_hole"
end

local function farmhouse_exit_beat(kind)
  local id = FARMHOUSE_HOLE_EXIT_ID
  if kind == "farmhouse_roof" or kind == "farmhouse_under" then
    id = FARMHOUSE_WEST_EXIT_ID
  end
  for _, b in ipairs(SPAWN.beats) do
    if b.id == id then return b end
  end
  return nil
end

-- Failsafe dump onto the Felwood road (5936,-1218). Excludes the north
-- tunnel (6606,-2363) and Winterspring so a live exit is not unskipped.
local function felwood_failsafe_dump(pos)
  return pos.x < 6400.0 and pos.y > -1900.0
end

local TRAVEL_FORM_SPELL = 783
-- Bear (rank-agnostic at the stance bar; 5487 = base Bear Form)
local BEAR_FORM_SPELL = 5487
local TRAVEL_FORM_ID = 3
local AQUATIC_FORM_SPELL = 1066
local AQUATIC_FORM_ID = 4

-- wow.time() is SIMULATION time, and league episodes run at 10x — a "6
-- second" window in sim seconds elapses in 0.6 wall seconds. These windows
-- are sim-scaled so they give the engine real wall time at 10x; at 1x
-- (manual debugging) they are just patient.
-- The host holds a pending form cast for 3 sim seconds; retry slower — but
-- not much slower: water exit/entry auto-cancels forms, and every formless
-- sim-second in the fatigue ocean is swum at stock speed (run 4 died of
-- exactly that: fatigue exhaustion at 4.72 yd/s).
local FORM_RETRY_SECONDS = 15.0
-- A route the client cannot serve, with the walkout spent, gets this long
-- before the beat is skipped. Never faster than the engine can plan a long
-- corridor. ~6 wall seconds at 10x.
local ROUTE_PATIENCE_SECONDS = 60.0

-- SPLIT SHEET. The race is 2,700 sim-seconds and every one of them is
-- classified: at-pace, below-pace, stationary, or casting. Not a threshold
-- alarm — an account. A stationary second is ~7-10 lost yards AND the only
-- mob-exposure window, so the stationary budget is zero and each lost second
-- is named where it was spent.
local AT_PACE_FRACTION = 0.95
-- Below this the seat is not travelling at all. The slowest pose this bot
-- ever holds is a formless swim at 4.7 yd/s, so only measurement noise and
-- genuine freezes land here.
local STATIONARY_SPEED = 1.0
-- Aquatic Form is base swim x1.5, and this client's base swim is the vanilla
-- 4.722 yd/s — so the pose owes 7.08 yd/s, not the 10.4 the sheet was built
-- with. Measured, not assumed: aquatic-form swim medians 7.01 yd/s over 221
-- samples (run-20260815-193433-baseline), 7.01 over 232
-- (run-20260815-195110-0030-gatebranch) and 6.84 over 211
-- (run-20260815-101017-0043), p95 7.3-7.7, while the SAME runs median
-- 5.00 / 4.88 / 4.74 yd/s formless in the same water — exactly the x1.5 the
-- spell grants. Against 10.4 every one of those seconds was billed
-- below-pace by construction: 853 of the baseline's 1,436 below-pace
-- sim-seconds were an honest full-speed swim (ticket 0030's done-when reads
-- this sheet, and a sheet that cannot ever say "at pace" cannot name what is
-- actually costing the run).
local SPEED_AQUATIC = 7.08
local SPEED_SWIM = 4.7
local SPEED_TRAVEL = 9.8
local SPEED_RUN = 7.0
-- A stall episode closes only once the seat has genuinely left the spot it
-- froze on. Oscillation and the pilot's escape serpentine move the seat
-- without moving the run, and neither may end the episode by wiggling.
local STALL_CLEAR_YARDS = 5.0
-- A decide interval this long means the brain was never asked: at the fixed
-- ~5 Hz tick (fork 25e077e35) an interval past a full sim-second has swallowed
-- five turns. Those seconds are still lost yards and still bill to the
-- stationary budget — but they are not navigation, and ticket 0030's
-- done-when requires every not-at-pace second NAMED. The 2026-08-15 champion
-- (run-20260815-195110-0030-gatebranch, 11,474.7) spent 205.4 of its 506.5
-- stationary sim-seconds inside intervals like this, the baseline
-- (run-20260815-193433) 28.2 of 291.3, and the very first stall of every run
-- is one: STALL t=1786822329.4 dec=2 -> the next decide lands 6.2 sim-s later
-- still at dec=2, the world-stream hitch the ticket's startup pause is made
-- of. Calling that "nav_local_steer" blames the steering for a turn the
-- brain never got.
local DECIDE_GAP_SECONDS = 1.0
-- An escape freed the seat when the seat closes this much on the beat it was
-- hopping toward. Anything else retires the episode as abandoned.
local ESCAPE_FREED_YARDS = 15.0
-- Northing hysteresis: once well past a beat's X band, never re-target it.
local PASSED_YARDS = 20.0
-- Wet-beat select/arrive distance. The cheese carpet zigzags around
-- headlands; selecting the next beat at full beat radius (35) strings
-- 90+ yd chords that cut the corners the human line swims around (run 6
-- died pinned on the -5675,-4771 headland off exactly such a chord).
-- Chords must never exceed beat spacing — and a beat once entered is
-- reached forever, or the selection flip-flops on the boundary (run 7
-- orbited the start blob doing exactly that).
-- 10 on a 25-yd carpet keeps cross-track under ~10 yd: the fatigue weave
-- only refills when the body genuinely touches the safe band, and 20-yd
-- capture let the seat skirt those touches (run 22 arrived at the wall
-- bypass drained and died mid-sprint; run 21, tracing truer, crossed it
-- full).
local WET_SELECT_YARDS = 10.0
-- RETRACE TAPE (ticket 0030). The brain already knows the one piece of
-- ground this seat is certain about: the ground it just walked. Sampled
-- every 5 yd and kept for ~240 yd, that track is the escape the 2026-08-14
-- wedge needed — at (-7678.4, -4045.3) the seat arrived down a clean
-- straight line through (-7703.6, -4021.0) and (-7737.3, -3987.1), then
-- held the spot for 62 sim-s with nav="following" while the fork's no-route
-- escape (EV nav_no_route_escape, pilot.nim:502-545) blind-serpentined
-- until it happened to slide free. Walking BACK 10-20 yd along the incoming
-- track and re-planning is strictly better than sawing at random.
--
-- A step no body could have walked (checkpoint teleport, server failsafe,
-- collision clip) is not track: the old points no longer describe ground
-- this seat can reach, so the tape starts over.
local TAPE_STEP_YARDS = 5.0
local TAPE_JUMP_YARDS = 40.0
local TAPE_MAX_POINTS = 48
-- Far enough back to leave the wedge's physical contact, short enough that
-- the yards are cheap to re-run at 9.8 yd/s.
local RETRACE_MIN_YARDS = 10.0
-- Two retraces per snag cluster. A wall the incoming track cannot undo hands
-- the seat to the flank/backward escalation that has saved earlier runs —
-- retrace leads, it does not replace.
local RETRACE_TRIES = 2
-- Indoors trap (ticket 0043). Attempts 1-3 walked the whole tape
-- (1,616 yd/ks backtrack). The escape is the 0030 retrace with two
-- extra constraints: at most 40 yd of tape, and after two failed legs
-- hold-and-report. Arm on every indoor stall — the (866.7, -2349.9)
-- hosted wedge kept nav=following, so a no_route-only trigger never
-- fired (attempt 2 autopsy, run-20260816-052122-0043).
local TRAP_DECIDES = 2
local TRAP_NET_YARDS = 5.0
local TRAP_MAX_YARDS = 40.0
-- A hop is "landed" one yard OUTSIDE its own 4 yd stop distance, so the
-- window closes as the client starts braking rather than after it has parked.
local SNAG_ARRIVED_YARDS = 5.0

-- STARTUP (ticket 0030). The fork will not steer at a goal beyond
-- PlanCoastYards = 400 yd while a corridor computes (pilot.nim coastAllowed),
-- and the first beat of the run sits 2,939 yd from the spawn pose — so the
-- seat receives NO movement input at all until the first plan lands. The
-- 2026-08-14 baseline paid 5.4 stationary sim-s for exactly that
-- (STALL t=1786749767.1 cause=planning -> RESUME dur=5.4 by=moved) on top of
-- the opening form cast. Hosted wall episodes (ticket 0015) are the same
-- window with no end and mobs inside it.
-- Until the engine has served a corridor even once, steer at the beat by
-- BEARING (local_steer): it needs no plan, and the opening of the corridor
-- IS the bearing — the baseline walked the straight line from
-- (-9187.0, -2530.2) through (-9126, -2593) and on to the coast.
-- One frame in KICKSTART_PLAN_EVERY stays an ordinary navigate: local_steer
-- returns before the route engine is ever asked (fork pilot.nim), so an
-- unbroken bearing walk would keep the corridor from landing at all. That
-- one inputless planning frame is safe — held movement keys ride their
-- physics lease through it.
-- The window is generous because it is spent on plan latency: 5.4 sim-s at
-- 9.8 yd/s is ~53 yd, and every yard of it is on the beat's own bearing.
local KICKSTART_YARDS = 120.0
local KICKSTART_SECONDS = 20.0
local KICKSTART_PLAN_EVERY = 4

-- COMBAT LINE BIAS (ticket 0030). A seat shoved off the safe line by aggro
-- evasion ends up in terrain the route never vetted, and the wedge above was
-- entered after five combat stretches (hp 2754 -> 2064 on the approach). The
-- correction owed is toward the LINE, not merely away from the mob: while in
-- combat and this far off the incoming track chord, steer at the nearest
-- point on that chord, advanced one stride toward the beat.
-- On the 2026-08-14 build this is a GUARD, not a fix: those five combat
-- stretches held 8.4-10.5 yd/s straight down the corridor and never displaced
-- the seat (the lua-bot pilot has no evasion reflex today). It logs
-- EV combat_line_bias when it engages, so the next trace says so out loud.
local COMBAT_LINE_YARDS = 25.0
local COMBAT_LINE_STRIDE = 20.0

-- No dive span: 15 wet-lab runs proved z-following at 10x tunnels the
-- seat through world collision at random (void falls in the early ribbon,
-- the -5675 wall face, and the cheese_26-28 basin), while the surface
-- ride never tunneled once. The one surface blocker — the -5675 wall
-- spur — is bypassed seaward by the v7 route (cheese_21/22). Keep the
-- machinery: a future route may need a dive window again.

-- Split-sheet ledger: the interval just closed, the cumulative buckets, and
-- the open stall episode (if any).
local lastDecideAt = nil
local lastAcctPos = nil
local lastIntentKind = nil
local acctAtPace = 0.0
local acctBelow = 0.0
local acctStationary = 0.0
local acctCasting = 0.0
local intervalClass = "-"
local intervalPace = -1.0
local stallOpenAt = nil
local stallOpenPos = nil
local stallOpenDec = 0
local stallCause = "-"
local stallStuckAt = nil
-- The previous decide chose to stand at a segment goal. Standing there is the
-- run's own choice, so it bills to the account without opening an episode.
local deliberateHold = false
-- Open escape episode: one per occurrence, never latched.
local escapeEp = nil
local unroutableSince = nil
local unroutableBeat = nil
local skipped = {}
local lastFormCastAt = nil
local deathLogged = false
local gateLogged = false
local lastWetDbgAt = nil
local actionBarLogged = false
local parkCheckPos = nil
local parkCheckAt = nil
local parkCheckFrames = nil
local surfaceUntil = nil
local snagCheckPos = nil
local snagCheckAt = nil
local snagCheckFrames = nil
local snagUntil = nil
local snagTarget = nil
local snagSide = 1
local snagSteer = false
-- Which escape the open hop window is serving. indoors_trap rides the
-- intent reason, the stall cause and the ESCAPE episode so a hosted log
-- names the room, not just no_route.
local snagKind = "snag_hop"
local trapPos = nil
local trapDecides = 0
local trapArmed = false
local trapSpent = false
local trapRetrace = 0
local snagClusterPos = nil
local snagClusterCount = 0
-- Retraces already spent inside the CURRENT snag cluster.
local snagClusterRetrace = 0
-- Total hops spent inside the CURRENT snag cluster; unlike snagClusterCount
-- it never cycles, so the hop reach can grow the longer a wall holds us.
local snagClusterTries = 0
-- Closing-on-the-beat watch: a seat can be moving and still be snagged if
-- the client is walking it out sideways instead of down the corridor.
local progressBeatId = nil
local progressBest = nil
local progressAt = nil
-- Last beat the seat actually stood on. The land beats north of the pass are
-- resampled from a run that WALKED them, so a reached beat is proven ground
-- and the safest place to put a lost seat back down.
local lastReached = nil
-- Same proven ground, kept per sparse route (interior / finale / connector):
-- those chains are resampled from walked runs too, but each owns its own
-- captures and must never hand another route's beat back to a lost seat.
local sparseReached = {}
-- Edge-trigger for the indoors form denial: one EV per indoor entry, so
-- replays show the transition without a log line every frame.
local formDeniedLogged = false
local farmhouseEvKind = nil
-- One-way latch: the seat has stood at the waterline once; entry now
-- belongs to the wade machinery for the rest of the run.
local waterlineReached = false
local connectorStarted = false
local connectorComplete = false
local finaleStarted = false
-- The interior chain owns the run from the cave mouth until its last
-- walked beat retires; monotonic like finaleStarted — a failsafe fall must
-- stay visible as a finale failure, never re-run the cave.
local interiorComplete = false

-- Flight recorder: permanent telemetry + edge-triggered anomaly events.
-- Exists because a human replay watch caught pauses / path-leaving /
-- water-entry / z-clips that pass-fail telemetry missed. Pure logging —
-- never changes intents.
local lastFlightAt = nil
local lastEvAt = nil
local prevLandBeat = nil
local currLandBeatId = nil
local currLandBeatXY = nil
local swimEvArmed = true
local drySwimSince = nil
local lastFormId = nil
local lastFrameZ = nil
local lastFrameSwimming = nil
local offLineSince = nil
local offLineFired = false
-- Off-line only arms after the seat has been on the chord (xt < 20) once —
-- otherwise test teleports / first-frame wedges would false-positive.
local offLineArmed = false
-- Perf telemetry: decisions counted here in lua; fps/wall come from
-- wow.perf() (nil-guarded — older hosts and the test stub may lack it).
-- Hosted 1996.05-wall episodes die at spawn with beat="-" while escapes
-- engage beats immediately; route_engaged makes that split one grep.
local decideCount = 0
local routeEngagedLogged = false

-- The ground this seat has actually stood on, oldest first (ticket 0030).
local tape = {}
-- Startup kickstart: spent the moment the route engine serves a corridor,
-- the seat has walked clear of the spawn pose, or the window times out.
local kickstartDone = false
local kickstartLogged = false
local kickstartFrames = 0
local controlAt = nil
local controlPos = nil
-- The FIRST intent of a run is a movement intent. A form press is free once
-- the body is already moving, and standing still is the only way this bot
-- dies — the 2026-08-14 opener spent its whole first decide interval
-- (2.1 sim-s, the world-stream hitch) on a cast with no translation lease
-- to ride (fork 5c934e5b2 renews held movement per MOVEMENT frame).
local movementIssued = false
-- One EV per combat-bias engagement, re-armed when the seat is back on line.
local lineBiasArmed = true

local function planar(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return math.sqrt(dx * dx + dy * dy)
end

-- Closest point on the segment a->b to p, clamped to the segment.
local function seg_project(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local len2 = dx * dx + dy * dy
  if len2 < 0.001 then return ax, ay end
  local t = ((px - ax) * dx + (py - ay) * dy) / len2
  if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
  return ax + t * dx, ay + t * dy
end

-- Distance from a point to the segment a->b, used to tell "wandering near the
-- proven line" from "gone".
local function seg_distance(px, py, ax, ay, bx, by)
  local cx, cy = seg_project(px, py, ax, ay, bx, by)
  return planar(px, py, cx, cy)
end

--- Remember the ground under the seat. Only genuine walking is taped: a step
--- no body could have taken invalidates the whole track, and an escape
--- window's own backward steps must never become the track the NEXT retrace
--- follows (or the pair would shuttle in and out of the same wedge).
local function tape_record(pos, held)
  if held then return end
  local last = tape[#tape]
  if last then
    local d = planar(pos.x, pos.y, last.x, last.y)
    if d < TAPE_STEP_YARDS then return end
    if d > TAPE_JUMP_YARDS then
      tape = { { x = pos.x, y = pos.y } }
      return
    end
  end
  tape[#tape + 1] = { x = pos.x, y = pos.y }
  if #tape > TAPE_MAX_POINTS then table.remove(tape, 1) end
end

--- The newest taped pose at least RETRACE_MIN_YARDS behind the seat: ground
--- this body physically occupied seconds ago, so walkable by construction.
--- Returns the pose and its index, because retracing to it retires it.
--- `maxYards` is the 0043 bound: a pose further down the tape is not a
--- legal indoors-trap target. Callers that omit it keep the 0030 search.
local function retrace_point(pos, maxYards)
  for i = #tape, 1, -1 do
    local d = planar(pos.x, pos.y, tape[i].x, tape[i].y)
    if d >= RETRACE_MIN_YARDS then
      if maxYards and d > maxYards then return nil end
      return tape[i], i
    end
  end
  return nil
end

--- Retiring the tape from a retrace target forward. Everything the tape
--- recorded from there on IS the approach into the wedge; leaving it in
--- place would let the very next retrace walk straight back into the pin,
--- and the pair would shuttle forever. Dropping the target too means a
--- second retrace steps FURTHER back down the track instead of repeating.
local function tape_rewind(idx)
  for i = #tape, idx, -1 do table.remove(tape, i) end
end

local function beat_by_id(id)
  for _, b in ipairs(ROUTE.beats) do
    if b.id == id then return b end
  end
  for _, b in ipairs(COAST.beats) do
    if b.id == id then return b end
  end
  for _, route in ipairs({ LAND, CONNECT_WET, CONNECT_LAND, INTERIOR, FINALE }) do
    for _, b in ipairs(route.beats) do
      if b.id == id then return b end
    end
  end
  return nil
end

local function in_travel_form(view)
  return view.shapeshift_form_id == TRAVEL_FORM_ID or
    view.shapeshift_form_spell_id == TRAVEL_FORM_SPELL
end

local function in_bear_form(view)
  -- 1 = Bear, 5 = Dire Bear: the rank-agnostic stance press gives
  -- whichever the character knows (roll 2 re-cast once because Dire
  -- Bear's form id was unmatched).
  return view.shapeshift_form_id == 1 or view.shapeshift_form_id == 5
end

local function in_aquatic_form(view)
  return view.shapeshift_form_id == AQUATIC_FORM_ID or
    view.shapeshift_form_spell_id == AQUATIC_FORM_SPELL
end

local function wading(view, pos)
  if not view.liquid_coverage_known or not view.liquid_known then
    return false
  end
  if view.liquid_submerged then return true end
  if type(view.liquid_surface_z) ~= "number" then return false end
  return math.abs(view.liquid_surface_z - pos.z) <= 3.0
end

--- First wet beat still ahead of us. Stateless: after crossing well into a
--- beat's X band, lateral drift must not select that beat again, and beats
--- behind us (Kalimdor +X is north) never regress the run — except hook
--- beats, which retire only by capture, same rule as the land selector.
--- ROUTE wet ribbon first, then COAST beats through merchant_coast.
local function next_wet_beat(x, y, fatigued)
  local wet = {}
  for _, b in ipairs(ROUTE.beats) do
    if b.wet then wet[#wet + 1] = b end
  end
  for _, b in ipairs(COAST.beats) do
    wet[#wet + 1] = b
  end
  for _, b in ipairs(CONNECT_WET.beats) do
    wet[#wet + 1] = b
  end
  if #wet == 0 then return nil end
  local captured = 0
  for i, b in ipairs(wet) do
    -- Entering a beat's capture zone retires it permanently: monotonic
    -- selection, no boundary flip-flop.
    -- Refill beats demand the tight touch only while the bar is actually
    -- draining: a full-bar run pays no zigzag tax (a healthy full-course
    -- run timed out 216 yd short paying it on every beat).
    local cap = (b.refill and fatigued) and 5.0 or WET_SELECT_YARDS
    if not skipped[b.id] and planar(x, y, b.x, b.y) <= cap then
      captured = i
    end
  end
  for i = 1, captured do skipped[wet[i].id] = true end
  for _, b in ipairs(wet) do
    -- hook or still south of the X-pass band (land selector shape).
    if not skipped[b.id] and (b.hook or x < b.x + PASSED_YARDS) then
      -- Hook beats are retired ONLY by capture, so they also skip the
      -- south-lag band: a beat the route deliberately doubles back to sits
      -- outside the 40-yd guard that protects ordinary beats from
      -- lateral-drift regression, and would never be selectable.
      if b.hook or b.x + b.radius >= x - 40.0 then
        return b
      end
    end
  end
  return wet[#wet]
end

local function next_sparse_beat(route, x, y)
  local captured = 0
  for i, b in ipairs(route.beats) do
    if not skipped[b.id] and planar(x, y, b.x, b.y) <= b.radius then
      captured = i
    end
  end
  for i = 1, captured do skipped[route.beats[i].id] = true end
  -- Standing on a sparse beat retires it AND proves the ground, the same way
  -- next_land_beat records lastReached: snag recovery needs somewhere known
  -- walkable to put a seat that the client has carried off the line.
  if captured > 0 then
    local reached = route.beats[captured]
    sparseReached[route] = { x = reached.x, y = reached.y }
  end
  for _, b in ipairs(route.beats) do
    if not skipped[b.id] and (b.hook or x < b.x + PASSED_YARDS) then
      return b
    end
  end
  return route.beats[#route.beats]
end

local function peek_sparse_beat(route, x, y)
  local retired = {}
  for _, b in ipairs(route.beats) do
    if not skipped[b.id] and not retired[b.id] and
        planar(x, y, b.x, b.y) <= b.radius then
      retired[b.id] = true
    end
    if not skipped[b.id] and not retired[b.id] and
        (b.hook or x < b.x + PASSED_YARDS) then
      return b
    end
  end
  return route.beats[#route.beats]
end

--- First land beat still ahead of us, same monotonic shape as the wet
--- selection: capture retires a beat forever, and a beat well behind our X
--- never regresses the run — except hook beats (westward Timbermaw descent),
--- which are only retired by capture. Land capture is the full beat radius.
local function next_land_beat(x, y)
  for _, b in ipairs(LAND.beats) do
    if not skipped[b.id] and planar(x, y, b.x, b.y) <= b.radius then
      skipped[b.id] = true
      -- Standing here retires the beat AND proves the ground: remember it as
      -- the place to put the seat back down if walkout carries it off.
      lastReached = { x = b.x, y = b.y }
    end
    if not skipped[b.id] and (b.hook or x < b.x + PASSED_YARDS) then
      return b
    end
  end
  return LAND.beats[#LAND.beats]
end

-- Read-only twin of next_land_beat for the flight recorder: same selection
-- shape without mutating skipped / lastReached (those side effects must stay
-- on the real navigate path so form-cast early returns do not change policy).
local function peek_land_beat(x, y)
  local retired = {}
  for _, b in ipairs(LAND.beats) do
    if not skipped[b.id] and not retired[b.id]
        and planar(x, y, b.x, b.y) <= b.radius then
      retired[b.id] = true
    end
    if not skipped[b.id] and not retired[b.id]
        and (b.hook or x < b.x + PASSED_YARDS) then
      return b
    end
  end
  return LAND.beats[#LAND.beats]
end

local function bot_status(view, pos, beat, extra)
  local water = beat_by_id("water_entry")
  local goal = beat_by_id(COAST.goal_id)
  local status = {
    beat = beat and beat.id or "?",
    x = pos.x,
    y = pos.y,
    dist_water = water and planar(pos.x, pos.y, water.x, water.y) or -1,
    dist_goal = goal and planar(pos.x, pos.y, goal.x, goal.y) or -1,
    swimming = view.is_swimming or false,
    fatigue = (view.fatigue_timer and view.fatigue_timer.active) and
      view.fatigue_timer.remaining_fraction or 1.0,
    -- Deaths must arrive with a cause attached: mobs show up as combat and
    -- sinking health well before the kill, falls do not.
    health = view.health_known and view.health or -1,
    in_combat = view.in_combat or false,
    -- Outdoor-only forms need this visible everywhere a human debugs.
    indoors = (view.indoors_known == true) and (view.indoors == true) or false,
  }
  for k, v in pairs(extra or {}) do status[k] = v end
  return status
end

local function mark_ev()
  lastEvAt = wow.time()
end

--- Permanent flight recorder + anomaly EVs. Logging only; never returns an
--- intent. Must run after position is known and before any early form-cast
--- return so unplanned-swim still fires on the wet frame that casts aquatic.
local function flight_recorder(view, pos, land_route)
  local now = wow.time()
  local swimming = view.is_swimming == true
  local formId = view.shapeshift_form_id or 0
  local beatId = "-"
  local xt = -1.0

  if land_route then
    local beat = land_route == LAND and peek_land_beat(pos.x, pos.y) or
      peek_sparse_beat(land_route, pos.x, pos.y)
    beatId = beat and beat.id or "-"
    if beat then
      if prevLandBeat == nil then
        -- Chord starts at land-phase entry pose until the first beat swap.
        prevLandBeat = { x = pos.x, y = pos.y }
        currLandBeatId = beat.id
        currLandBeatXY = { x = beat.x, y = beat.y }
        offLineSince, offLineFired, offLineArmed = nil, false, false
      elseif beat.id ~= currLandBeatId then
        prevLandBeat = currLandBeatXY
        currLandBeatId = beat.id
        currLandBeatXY = { x = beat.x, y = beat.y }
        offLineSince, offLineFired, offLineArmed = nil, false, false
      end
      if prevLandBeat then
        xt = seg_distance(pos.x, pos.y, prevLandBeat.x, prevLandBeat.y,
          beat.x, beat.y)
      end
    end
  end

  -- EV unplanned_swim: one event per land-phase swim bout; re-arm after
  -- dry for 5+ sim-seconds.
  if swimming then
    drySwimSince = nil
    if land_route and swimEvArmed then
      swimEvArmed = false
      mark_ev()
      wow.log(string.format("EV unplanned_swim x=%.1f y=%.1f", pos.x, pos.y))
    end
  else
    if drySwimSince == nil then
      drySwimSince = now
    elseif now - drySwimSince >= 5.0 then
      swimEvArmed = true
    end
  end

  -- EV form_lost / form_gained on shapeshift_form_id edges.
  if lastFormId ~= nil and formId ~= lastFormId then
    if lastFormId ~= 0 then
      mark_ev()
      wow.log(string.format("EV form_lost form=%d x=%.1f y=%.1f",
        lastFormId, pos.x, pos.y))
    end
    if formId ~= 0 then
      mark_ev()
      wow.log(string.format("EV form_gained form=%d x=%.1f y=%.1f",
        formId, pos.x, pos.y))
    end
  end
  lastFormId = formId

  -- EV clip: large z jump between frames while dry on both sides.
  if lastFrameZ ~= nil and not swimming and lastFrameSwimming == false then
    local dz = math.abs((pos.z or 0) - lastFrameZ)
    if dz > 10.0 then
      mark_ev()
      wow.log(string.format("EV clip dz=%.1f x=%.1f y=%.1f z=%.1f",
        dz, pos.x, pos.y, pos.z or 0))
    end
  end
  lastFrameZ = pos.z or 0
  lastFrameSwimming = swimming

  -- EV off_line: land cross-track > 35 sustained 5s after once being on
  -- the line (xt < 20). Re-arm when xt drops back below 20.
  if land_route and xt >= 0.0 then
    if xt < 20.0 then
      offLineArmed = true
      offLineFired = false
      offLineSince = nil
    elseif offLineArmed and xt > 35.0 then
      if offLineSince == nil then offLineSince = now end
      if not offLineFired and now - offLineSince >= 5.0 then
        offLineFired = true
        mark_ev()
        wow.log(string.format("EV off_line xt=%.1f x=%.1f y=%.1f",
          xt, pos.x, pos.y))
      end
    else
      offLineSince = nil
    end
  end

  -- EV route_engaged: once, on the first frame a beat is assigned. Hosted
  -- wall episodes (ticket 0015) die at spawn with beat="-" forever; this
  -- line is the discriminator, and its wall clock dates the engagement.
  if not routeEngagedLogged and beatId ~= "-" then
    routeEngagedLogged = true
    local wallNow = -1.0
    if wow.perf then wallNow = wow.perf().wall_s or -1.0 end
    mark_ev()
    wow.log(string.format(
      "EV route_engaged beat=%s t=%.1f wall=%.1f x=%.1f y=%.1f",
      beatId, now, wallNow, pos.x, pos.y))
  end

  -- FLIGHT cadence: 5s normal, 1s for 10s after any EV.
  local cadence = 5.0
  if lastEvAt and now - lastEvAt < 10.0 then cadence = 1.0 end
  if lastFlightAt == nil or now - lastFlightAt >= cadence then
    lastFlightAt = now
    local hp = -1
    if view.health_known then hp = math.floor(view.health or 0) end
    -- fat: fatigue bar fraction remaining (1.0 = safe water/land, active
    -- timer counts DOWN; three 2026-08-13 runs died with no metric —
    -- ticket 0018's observation-to-metric duty).
    local fat = 1.0
    if view.fatigue_timer and view.fatigue_timer.active then
      fat = view.fatigue_timer.remaining_fraction or 0.0
    end
    -- fps/wall/dec: host render rate, wall clock, and decide count let the
    -- scorecard separate CPU starvation (sim-rate sag, decision famine)
    -- from route trouble. Older hosts / the test stub lack wow.perf.
    local fps, wall = -1.0, -1.0
    if wow.perf then
      local perf = wow.perf()
      fps = perf.fps or -1.0
      wall = perf.wall_s or -1.0
    end
    -- cls/pace classify the interval that just closed; at_s/bp_s/sta_s/cast_s
    -- are the cumulative split sheet, so consecutive samples difference into
    -- a per-interval account and their sum is the whole run.
    wow.log(string.format(
      'FLIGHT {"t":%.1f,"x":%.1f,"y":%.1f,"z":%.1f,"hp":%d,"form":%d,' ..
      '"swim":%s,"combat":%s,"indoors":%s,"nav":"%s","beat":"%s","xt":%.1f,' ..
      '"fat":%.2f,"fps":%.1f,"wall":%.1f,"dec":%d,"cls":"%s","pace":%.2f,' ..
      '"at_s":%.1f,"bp_s":%.1f,"sta_s":%.1f,"cast_s":%.1f}',
      now, pos.x, pos.y, pos.z or 0, hp, formId,
      swimming and "true" or "false",
      (view.in_combat == true) and "true" or "false",
      (view.indoors_known == true and view.indoors == true) and "true" or "false",
      tostring(wow.nav_progress().state or "?"),
      beatId, xt, fat, fps, wall, decideCount,
      intervalClass, math.min(9.99, intervalPace),
      acctAtPace, acctBelow, acctStationary, acctCasting))
  end
end

--- Yards per second the current pose owes the run. Form is speed and speed is
--- the score, so the pace bar moves with the form the seat is actually in.
local function expected_speed(view)
  if view.is_swimming == true then
    return in_aquatic_form(view) and SPEED_AQUATIC or SPEED_SWIM
  end
  return in_travel_form(view) and SPEED_TRAVEL or SPEED_RUN
end

--- Why the seat is not travelling, named at the moment displacement dies.
--- `dt` is the interval that just closed: an interval longer than the decide
--- cadence means the brain was never called across it, and nothing the brain
--- chose can own seconds it was not present for.
local function stall_cause(view, now, dt)
  if dt and dt > DECIDE_GAP_SECONDS then return "host_gap" end
  if snagUntil and now < snagUntil then return snagKind end
  if trapArmed or trapSpent then return "indoors_trap" end
  if surfaceUntil and now < surfaceUntil then return "park_surface" end
  if view.rooted then return "rooted" end
  if not view.movement_allowed then return "movement_denied" end
  local state = tostring(wow.nav_progress().state or "?")
  if state == "planning" then return "planning" end
  if state == "unavailable" or state == "walkout" then
    if view.indoors_known == true and view.indoors == true then
      return "indoors_trap"
    end
    return "no_route"
  end
  return "nav_" .. state
end

local function escape_close(now, pos, outcome)
  if escapeEp == nil then return end
  wow.log(string.format(
    "ESCAPE: end kind=%s t=%.1f dur=%.1f outcome=%s beat=%s hops=%d " ..
    "closed=%.1f at (%.1f, %.1f) dec=%d",
    escapeEp.kind, now, now - escapeEp.at, outcome, escapeEp.beat,
    escapeEp.hops,
    escapeEp.base - planar(pos.x, pos.y, escapeEp.bx, escapeEp.by),
    pos.x, pos.y, decideCount))
  escapeEp = nil
end

--- One episode per occurrence: a repeat hop at the same beat extends the open
--- episode, a hop anywhere else retires it first. Nothing latches, so a run
--- that escapes twenty times reports twenty pairs.
local function escape_note(kind, now, pos, beat)
  if escapeEp and escapeEp.kind == kind and escapeEp.beat == beat.id then
    escapeEp.hops = escapeEp.hops + 1
    return
  end
  escape_close(now, pos, "abandoned")
  local dist = planar(pos.x, pos.y, beat.x, beat.y)
  escapeEp = { kind = kind, at = now, beat = beat.id, bx = beat.x,
    by = beat.y, base = dist, hops = 1 }
  wow.log(string.format(
    "ESCAPE: start kind=%s t=%.1f at (%.1f, %.1f) beat=%s dist=%.1f dec=%d",
    kind, now, pos.x, pos.y, beat.id, dist, decideCount))
end

local function escape_watch(now, pos)
  if escapeEp == nil then return end
  local dist = planar(pos.x, pos.y, escapeEp.bx, escapeEp.by)
  if dist <= escapeEp.base - ESCAPE_FREED_YARDS then
    escape_close(now, pos, "freed")
  elseif skipped[escapeEp.beat] then
    escape_close(now, pos, dist < escapeEp.base and "freed" or "abandoned")
  end
end

--- Holding at a segment goal is a choice, not a stall: close the episode
--- against the goal instead of billing the hold to the stationary budget.
local function stall_release(pos, now)
  if stallOpenAt == nil then return end
  wow.log(string.format(
    "RESUME: t=%.1f dur=%.1f cause=%s by=goal_hold at (%.1f, %.1f) " ..
    "nav=%s decs=%d net=%.1f",
    now, now - stallOpenAt, stallCause, pos.x, pos.y,
    tostring(wow.nav_progress().state), decideCount - stallOpenDec,
    planar(pos.x, pos.y, stallOpenPos.x, stallOpenPos.y)))
  stallOpenAt, stallOpenPos, stallStuckAt = nil, nil, nil
end

--- The split sheet itself: classify the interval that just ended, keep the
--- cumulative account, and open/close the stall episode. Returns the seconds
--- the open stall has been running (0 when the seat is travelling).
---
--- The interval belongs to the intent the PREVIOUS decide returned, so a form
--- press is billed to casting rather than to the stationary budget.
local function account(view, pos)
  local now = wow.time()
  escape_watch(now, pos)
  if lastDecideAt == nil or lastAcctPos == nil then
    lastDecideAt, lastAcctPos = now, { x = pos.x, y = pos.y }
    return 0
  end
  local dt = now - lastDecideAt
  if dt <= 0 then
    return stallOpenAt and (now - stallOpenAt) or 0
  end
  local speed = planar(pos.x, pos.y, lastAcctPos.x, lastAcctPos.y) / dt
  local expect = expected_speed(view)
  intervalPace = speed / expect
  local casting = lastIntentKind == "cast_spell"
  local travelling = speed >= STATIONARY_SPEED

  -- Stall ledger. The episode opens on the FIRST decide that observes no
  -- travel — at 5 Hz the seat is known frozen 0.2 sim-s in, with no
  -- threshold to hide under. It is anchored on NET displacement from where
  -- the seat froze, so serpentining in place accrues duration instead of
  -- resetting the clock (the 2026-08-14 wedge went 62 s undetected because
  -- the old watchdog re-armed on any 3 yd move and waited 80 s besides).
  local frozen = not travelling and not casting and not deliberateHold
  if stallOpenAt ~= nil then
    -- One-way re-owning: an episode that opened on an ordinary frame and then
    -- swallowed a decide gap spent those seconds with no brain in the loop,
    -- so the gap owns it whatever opened it. The real startup pause is
    -- exactly this shape — the episode opens at dec=2 under nav=local_steer
    -- and the NEXT decide arrives 6.2 sim-s later, still dec=2.
    if dt > DECIDE_GAP_SECONDS and stallCause ~= "host_gap" then
      stallCause = "host_gap"
    end
    -- Duration runs to the last decide that still found the seat on the spot,
    -- not to the first twitch: a serpentine twitches constantly and travels
    -- nowhere, and the yards spent escaping the circle belong to the run.
    local net = planar(pos.x, pos.y, stallOpenPos.x, stallOpenPos.y)
    if net < STALL_CLEAR_YARDS then
      stallStuckAt = now
    else
      wow.log(string.format(
        "RESUME: t=%.1f dur=%.1f cause=%s by=moved at (%.1f, %.1f) " ..
        "nav=%s decs=%d net=%.1f",
        now, stallStuckAt - stallOpenAt, stallCause, pos.x, pos.y,
        tostring(wow.nav_progress().state), decideCount - stallOpenDec, net))
      stallOpenAt, stallOpenPos, stallStuckAt = nil, nil, nil
    end
  elseif frozen then
    stallOpenAt = lastDecideAt
    stallStuckAt = now
    stallOpenPos = { x = lastAcctPos.x, y = lastAcctPos.y }
    stallOpenDec = decideCount
    stallCause = stall_cause(view, now, dt)
    wow.log(string.format(
      "STALL: t=%.1f at (%.1f, %.1f) nav=%s cause=%s dec=%d",
      stallOpenAt, stallOpenPos.x, stallOpenPos.y,
      tostring(wow.nav_progress().state), stallCause, decideCount))
  end

  -- A seat inside an unresolved stall has not left the spot, so raw speed
  -- cannot buy it at-pace credit: a serpentine oscillating in place clocks
  -- 15 yd/s and moves the run nowhere.
  if casting then
    acctCasting = acctCasting + dt
    intervalClass = "casting"
  elseif not travelling then
    acctStationary = acctStationary + dt
    intervalClass = "stationary"
  elseif speed >= AT_PACE_FRACTION * expect and stallOpenAt == nil then
    acctAtPace = acctAtPace + dt
    intervalClass = "at_pace"
  else
    acctBelow = acctBelow + dt
    intervalClass = "below_pace"
  end

  lastDecideAt, lastAcctPos = now, { x = pos.x, y = pos.y }
  return stallOpenAt and (now - stallOpenAt) or 0
end

--- Skip a beat only when the engine could never plan a corridor to it from
--- a healthy pose (waypoint_count 0, no pinned pose failure). A pinned pose
--- failure (`failed_here`) poisons ALL new planning — switching beats there
--- discards the only corridor that exists (proven in the 2026-08-09 desert
--- run: the skip turned an inching-but-alive route into a permanent wedge).
--- A stall on a planned route is never grounds to change the plan either —
--- that is the underlying bug, and it gets logged, not worked around.
local function route_dead(view, beat)
  -- The direct-water route cannot fail while genuinely swimming; an
  -- "unavailable" there is a transient liquid-observation flicker, never
  -- grounds to burn a wet beat off the ribbon.
  if beat.wet and view.is_swimming == true then
    unroutableBeat, unroutableSince = nil, nil
    return false
  end
  local now = wow.time()
  local nav = wow.nav_progress()
  local dead = nav.state == "unavailable" and not nav.walkout_available
    and not nav.failed_here and (nav.waypoint_count or 0) == 0
  if not dead or unroutableBeat ~= beat.id then
    unroutableBeat = dead and beat.id or nil
    unroutableSince = dead and now or nil
    return false
  end
  if now - unroutableSince < ROUTE_PATIENCE_SECONDS then return false end
  skipped[beat.id] = true
  unroutableBeat, unroutableSince = nil, nil
  wow.log("route unavailable, skipping beat " .. beat.id)
  return true
end

--- Is the opening bearing-walk still owed? True only before the route engine
--- has ever answered with a corridor, and only for the first few yards /
--- seconds of the run — a kickstart that outlived its window would be a
--- blind walk, which is the fork's coast gate all over again.
local function kickstart_ready(view, pos)
  if kickstartDone then return false end
  local now = wow.time()
  local nav = tostring(wow.nav_progress().state or "")
  local why = nil
  if nav == "following" or nav == "reached" or nav == "walkout" then
    why = "corridor"
  elseif controlAt == nil then
    -- Should not happen (decide records control before navigating), but a
    -- kickstart with no window is a blind walk: refuse it.
    why = "no_window"
  elseif planar(pos.x, pos.y, controlPos.x, controlPos.y) > KICKSTART_YARDS then
    why = "moved"
  elseif now - controlAt > KICKSTART_SECONDS then
    why = "timeout"
  end
  if why then
    kickstartDone = true
    if kickstartLogged then
      wow.log(string.format(
        "KICKSTART: end t=%.1f by=%s at (%.1f, %.1f) nav=%s dec=%d",
        now, why, pos.x, pos.y, nav, decideCount))
    end
    return false
  end
  if not kickstartLogged then
    kickstartLogged = true
    wow.log(string.format(
      "KICKSTART: start t=%.1f at (%.1f, %.1f) nav=%s dec=%d",
      now, pos.x, pos.y, nav, decideCount))
  end
  return true
end

--- Steer back onto the line the run intends to walk, not merely away from
--- whatever is hitting the seat. The chord is the incoming track (the taped
--- pose behind us) to the beat ahead: the seat was ON it moments ago, so the
--- projection is ground the route already committed to.
local function line_bias(view, pos, beat)
  if view.in_combat ~= true then return nil end
  local anchor = retrace_point(pos)
  if anchor == nil then return nil end
  local off = seg_distance(pos.x, pos.y, anchor.x, anchor.y, beat.x, beat.y)
  if off <= COMBAT_LINE_YARDS then
    lineBiasArmed = true
    return nil
  end
  local cx, cy = seg_project(pos.x, pos.y, anchor.x, anchor.y, beat.x, beat.y)
  local dx, dy = beat.x - cx, beat.y - cy
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1.0 then return nil end
  local step = math.min(COMBAT_LINE_STRIDE, len)
  return { x = cx + dx / len * step, y = cy + dy / len * step, off = off }
end

local function navigate_to(view, pos, beat, reason, opts)
  opts = opts or {}
  if route_dead(view, beat) then return nil end
  local intent = {
    kind = "navigate",
    x = beat.x,
    y = beat.y,
    map_id = math.floor(view.location.map_id or ROUTE.map_id),
    stop_distance = opts.stop or beat.radius,
    route_profile = "prefer_ground",
    reason = reason or beat.id,
    status = bot_status(view, pos, beat, opts.status),
  }
  -- Wet beats swim the human run's z profile: it is the only line that
  -- threads the -5675 wall's under-gap, and the fatigue-priced seaward
  -- bypass is unaffordable (~a full bar per crossing, wet-lab run 26).
  -- Descent safety is owned by client physics now — a swimmer's descent
  -- requires floor evidence — so the void-fall roulette that once forced
  -- surface-only riding is gone. Aquatic Form makes depth free.
  -- Anti-park: the 10x pitch controller can freeze translation chasing a
  -- depth (run 27 died parked at a beat, full stop, in drain water). While
  -- the override window is open, omit z — surface-ride input (held JUMP +
  -- forward) always translates.
  if not opts.surface and
      not (beat.wet and surfaceUntil and wow.time() < surfaceUntil) then
    -- Draft floor on wet beats: never command shallower than 2.5 yd. The
    -- host's ascent toward a near-surface target is what launched the bot
    -- clear of the water (Aquatic auto-cancel, breath panic) — monofuel
    -- watched it happen repeatedly. Dive depths pass through untouched.
    -- NO exceptions: a "shore" bypass here once commanded z=+9.5 on a wet
    -- beat and relaunched exactly that failure. Shore exits work by
    -- steering the swimmer onto the shallow shelf (planar target) until
    -- the client clears the swim flag — never by commanding air.
    intent.z = beat.wet and math.min(beat.z, -2.5) or beat.z
  end
  -- Wet beats are declared water goals: the host commits to the water
  -- (wade steering at the bearing until the swim flag flips) instead of
  -- asking ground planning for a corridor it will never grant. This is a
  -- speedrun — walk INTO the water, no inching on walkout crumbs.
  if beat.wet then intent.water = true end
  -- Fork features (forward-safe: the committed intent parser ignores
  -- unknown keys). local_steer drives collision-observed steps through WMO
  -- interiors where Detour serves the exterior surface; allow_jump lets an
  -- advertised jump step clear the Timbermaw cave lip (monofuel's walk
  -- proved plain forward walking is rejected there).
  if beat.navigation_mode then intent.navigation_mode = beat.navigation_mode end
  if beat.allow_jump then intent.allow_jump = true end
  -- Combat line bias: pull the commanded target back onto the incoming
  -- chord before anything else rewrites it. The BEAT is untouched — this is
  -- a waypoint on the line to it, so the run never re-aims.
  if not beat.wet then
    local bias = line_bias(view, pos, beat)
    if bias then
      intent.x, intent.y = bias.x, bias.y
      intent.z = nil
      intent.stop_distance = math.min(intent.stop_distance, 8.0)
      intent.status.line_bias = true
      if lineBiasArmed then
        lineBiasArmed = false
        mark_ev()
        wow.log(string.format(
          "EV combat_line_bias off=%.1f x=%.1f y=%.1f beat=%s",
          bias.off, pos.x, pos.y, beat.id))
      end
    end
  end
  -- Startup kickstart: bearing-only steering while the route engine has
  -- never served a corridor. Water goals are exempt — the wade machinery
  -- already commits without a plan, and local_steer would bypass it.
  -- ...and only for a goal genuinely out of reach: inside its stop distance
  -- local_steer answers "reached" and STOPS the seat, which is the opposite
  -- of the point (a checkpoint start can drop the seat next to a beat).
  if not beat.wet and view.is_swimming ~= true and
      intent.navigation_mode == nil and
      planar(pos.x, pos.y, intent.x, intent.y) >
        intent.stop_distance + 20.0 and
      kickstart_ready(view, pos) then
    kickstartFrames = kickstartFrames + 1
    if kickstartFrames % KICKSTART_PLAN_EVERY == 0 then
      -- Hand this frame to the route engine so a corridor can actually
      -- land and retire the kickstart.
      intent.status.kickstart = "plan"
    else
      intent.navigation_mode = "local_steer"
      intent.z = nil
      intent.status.kickstart = "steer"
    end
  end
  return intent
end

--- Indoors + no net displacement for TRAP_DECIDES cycles. Every indoor
--- entry starts a fresh watch (form_denied_indoors is the same edge);
--- nav state is ignored — attempt 2 required no_route and missed the
--- (866.7, -2349.9) following+collision wedge. Once a retrace has been
--- issued, stay armed until the seat is outdoors. Outdoors clears
--- everything so the next room can arm.
local function trap_watch(view, pos)
  -- The junction is the route, not a 0043 room. Retracing here walks
  -- the seat back out the Felwood mouth (cave_run_{1,2,3}).
  if on_junction_deck(pos) then
    trapPos, trapDecides, trapArmed, trapSpent, trapRetrace =
      nil, 0, false, false, 0
    return false
  end
  local indoors = view.indoors_known == true and view.indoors == true
  if not indoors then
    trapPos, trapDecides, trapArmed, trapSpent, trapRetrace =
      nil, 0, false, false, 0
    return false
  end
  if trapSpent or trapRetrace > 0 then
    trapArmed = true
    return true
  end
  if trapPos == nil or
      planar(pos.x, pos.y, trapPos.x, trapPos.y) > TRAP_NET_YARDS then
    trapPos, trapDecides, trapArmed = { x = pos.x, y = pos.y }, 1, false
    return false
  end
  trapDecides = trapDecides + 1
  if trapDecides >= TRAP_DECIDES then trapArmed = true end
  return trapArmed
end

-- Snag hop: the nim client's collision can pin the seat on a road-side
-- point object — corridor planned, but every ground input toward it is
-- rejected ("no productive ground input", failed_here, no walkout) and
-- the seat freezes to the millimeter (run 2 wedge at (3322,-1640),
-- 2026-08-10). The goal NEVER rotates: open a short window that steps
-- ~18 yd perpendicular to the beat bearing (alternating sides) purely
-- to change the physical contact, then resume the same beat. Land twin
-- of the wet park detector's surface-ride window.
--
-- Shared by every walking phase. The machinery only ever needed a beat and
-- the proven ground behind it, and the sparse routes went without it until
-- the interior chain froze 380 yd inside Timbermaw at (6866.6, -2126.2)
-- with nav=unavailable on timbermaw_17 and never attempted a thing
-- (2026-08-11). `proven` is the last beat this phase actually stood on.
--
-- Returns a hop intent only while a window is OPEN; arming one is silent so
-- the caller still issues the corridor for the beat on the arming frame.
local function snag_recovery(view, pos, beat, phase, proven)
  local now = wow.time()
  -- ARRIVED IS DONE (ticket 0030). The window buys ONE thing: a change of
  -- physical contact. Once the seat is standing on the hop target that
  -- purchase is complete, and the rest of the window is paid in stationary
  -- seconds — local_steer answers "reached" and STOPS the seat, exactly the
  -- dead stop the kickstart's stop-distance guard exists to avoid. The
  -- 2026-08-15 baseline shows the bill: the retrace to (-605.8, -3005.0)
  -- landed 1.1 s into a 6.2 s window and the seat then held (-602.6,
  -- -3003.3) with nav=reached until it expired (STALL t=1786823912.0
  -- cause=snag_hop -> RESUME dur=5.6 by=moved net=5.4), 6.9 stationary
  -- sim-s across that run's hops. The window was always a deadline, never a
  -- dwell: close it on arrival and the same beat resumes on this very frame.
  if snagUntil and now < snagUntil and snagTarget and
      planar(pos.x, pos.y, snagTarget.x, snagTarget.y) <= SNAG_ARRIVED_YARDS then
    -- Its own prefix, deliberately: a "SNAG:" line is how the scorecard
    -- counts snags, and the END of a hop is not a new one.
    wow.log(string.format(
      "HOP: landed at (%.1f, %.1f) — %.1fs of window returned to the run",
      pos.x, pos.y, snagUntil - now))
    snagUntil, snagTarget, snagSteer = nil, nil, false
  end
  if snagUntil and now < snagUntil and snagTarget then
    local hop = { kind = "navigate", x = snagTarget.x, y = snagTarget.y,
      z = pos.z, map_id = math.floor(view.location.map_id or ROUTE.map_id),
      stop_distance = 4.0, route_profile = "prefer_ground",
      reason = snagKind,
      status = bot_status(view, pos, beat,
        { phase = phase, snag_hop = true,
          indoors_trap = (snagKind == "indoors_trap") or nil }) }
    -- A retrace walks ground this body held seconds ago, so it needs no
    -- corridor — and asking for none is the point: the wedge halved fps
    -- (80 -> 43) replanning every frame at zero displacement. local_steer
    -- returns before the route engine is touched (fork pilot.nim), so the
    -- replan storm stops for the length of the window.
    if snagSteer then
      hop.navigation_mode = "local_steer"
      hop.z = nil
      hop.status.retrace = true
    end
    return hop
  end
  snagUntil, snagTarget, snagSteer = nil, nil, false
  -- Indoors trap (ticket 0043): the 0030 retrace, bounded and terminating.
  -- Two legs, each at most TRAP_MAX_YARDS down the tape; then hold. Never
  -- fall through to the flank/backward saw — that is how attempts 1-3
  -- wandered 1,616 yd/ks. Hop on this frame: the corridor the room
  -- refuses is not worth another decide.
  if trapArmed then
    local retrace, retraceIdx = retrace_point(pos, TRAP_MAX_YARDS)
    if retrace and trapRetrace < RETRACE_TRIES then
      trapRetrace = trapRetrace + 1
      local dist = planar(pos.x, pos.y, retrace.x, retrace.y)
      snagTarget = { x = retrace.x, y = retrace.y }
      snagUntil = now + 4.0 + dist / 8.0
      snagSteer = true
      snagKind = "indoors_trap"
      tape_rewind(retraceIdx)
      escape_note("indoors_trap", now, pos, beat)
      wow.log(string.format(
        "SNAG: indoors trap at (%.1f, %.1f) — hopping retrace %.0fyd to (%.1f, %.1f)",
        pos.x, pos.y, dist, snagTarget.x, snagTarget.y))
      local hop = { kind = "navigate", x = snagTarget.x, y = snagTarget.y,
        map_id = math.floor(view.location.map_id or ROUTE.map_id),
        stop_distance = 4.0, route_profile = "prefer_ground",
        reason = "indoors_trap", navigation_mode = "local_steer",
        status = bot_status(view, pos, beat,
          { phase = phase, snag_hop = true, retrace = true,
            indoors_trap = true }) }
      return hop
    end
    if not trapSpent then
      trapSpent = true
      if escapeEp and escapeEp.kind == "indoors_trap" then
        escape_close(now, pos, "held")
      else
        escape_note("indoors_trap", now, pos, beat)
        escape_close(now, pos, "held")
      end
      wow.log(string.format(
        "ESCAPE: held indoors_trap at (%.1f, %.1f) after %d retraces dec=%d",
        pos.x, pos.y, trapRetrace, decideCount))
    end
    return { kind = "hold", reason = "indoors_trap",
      status = bot_status(view, pos, beat,
        { phase = phase, indoors_trap = true }) }
  end
  snagKind = "snag_hop"
  -- Trigger on the FROZEN SEAT itself, not on any nav-state combination:
  -- the run-2 death froze under nav=walkout ("input returned to the same
  -- pose") while a mob train burned 138 hp/sim-s — the seat was pinned
  -- but the walkout machinery still claimed progress was possible.
  -- ...and on a seat that MOVES without ever getting closer. A frozen
  -- seat is only the loud half of a snag. When the client cannot follow
  -- the planned corridor it drops to "walkout" and drives the seat off
  -- on its own — still moving, so the freeze test never trips, while the
  -- brain waits. That wander is what has actually been killing this
  -- segment: leaving north_road_2 the seat walks 55 yd SOUTH of a
  -- corridor that stays clear of the Felpaw camp and straight through
  -- the camp instead (runs 10, 11 and valley-run 1 each lost 350-1200 hp
  -- there), and the three walls that ended valley-run 1 at (6034,-1280),
  -- (6069,-1305) and (6196,-1419) all sit 45-69 yd OFF the planned
  -- corridor — the seat only reached them by wandering. So treat "no
  -- closing on the beat for 15 sim-s" as a snag too and hand it to the
  -- same hop machinery. The beat never changes; only the seat's contact
  -- with the geometry does.
  local bdist = planar(pos.x, pos.y, beat.x, beat.y)
  if progressBeatId ~= beat.id or progressAt == nil then
    progressBeatId, progressBest, progressAt = beat.id, bdist, now
  elseif bdist < progressBest - 5.0 then
    progressBest, progressAt = bdist, now
  end
  local drifting = (now - progressAt) > 15.0
  local pinned = view.movement_allowed and not view.rooted
  if pinned or drifting then
    if not drifting and (snagCheckPos == nil or
        planar(pos.x, pos.y, snagCheckPos.x, snagCheckPos.y) > 1.0) then
      snagCheckPos, snagCheckAt, snagCheckFrames =
        { x = pos.x, y = pos.y }, now, 0
    else
      snagCheckFrames = (snagCheckFrames or 0) + 1
      -- 5 sim-s clears a pilot form-cast pause; 8 real frames keeps
      -- jumpy test clocks from tripping it.
      if drifting or (snagCheckAt and now - snagCheckAt > 5.0 and
          snagCheckFrames >= 8) then
        local dx, dy = beat.x - pos.x, beat.y - pos.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 0.1 then
          local ux, uy = dx / len, dy / len
          -- Escalate within a snag cluster: left, then right, then
          -- RETREAT along the bearing — the way in is the one exit
          -- proven walkable (run 6 died oscillating ±10 yd at
          -- (3724,-1407) with both flanks blocked while a mob train
          -- burned it down).
          if snagClusterPos and
              planar(pos.x, pos.y, snagClusterPos.x, snagClusterPos.y) <= 30.0 then
            snagClusterCount = snagClusterCount + 1
            snagClusterTries = snagClusterTries + 1
          else
            snagClusterPos = { x = pos.x, y = pos.y }
            snagClusterCount = 1
            snagClusterTries = 1
            snagClusterRetrace = 0
          end
          -- ESCALATE THE REACH, not the goal. Some of these pins are not
          -- point objects at all but long baked walls the mesh does not
          -- model: run 8 (2026-08-10) burned 131 hops on one pose at
          -- (2615,-1801) and run 1 burned 67 at (4774,-806), every one of
          -- them an 18/30 yd shuffle inside the same wall. A fixed reach
          -- can only ever free a snag narrower than itself, so the reach
          -- grows with how long this cluster has held us: 18 -> 36 -> 54
          -- -> 72 yd on the flanks (30 -> 120 backward), which is enough
          -- to walk around a wall instead of rubbing along it. The beat
          -- never changes and no new destination is adopted — this is
          -- still one short window of physical repositioning, then the
          -- same corridor is re-planned.
          local reach = 1 + math.min(3, math.floor(snagClusterTries / 6))
          local label
          -- RETURN TO PROVEN GROUND. A sidestep assumes the seat is on the
          -- line and merely stuck against something; once walkout has
          -- carried it off the line, ±18 yd of shuffle is noise. Trace-run
          -- 2 drifted 130 yd north of a walked corridor while every hop
          -- politely stepped 18 yd sideways, and the "backward" hop made
          -- it worse — retreating along the bearing to a beat you are no
          -- longer approaching just pushes you further out. When the seat
          -- is more than 40 yd off the segment between the last beat it
          -- actually stood on and the beat it is steering at, put it back
          -- on that last beat: north of the pass those beats are resampled
          -- from a run that walked them, so it is the one piece of ground
          -- known to hold. Still no goal rotation — the beat is untouched
          -- and resumes the moment the window closes.
          -- RETRACE FIRST (ticket 0030). Before any blind sawing, walk back
          -- along the track this seat actually came in on. It is the only
          -- ground the brain can prove walkable without asking anything, it
          -- undoes the exact contact that pinned the seat, and it is
          -- available in every phase — including the coast approach, which
          -- owns the 62-s (-7678, -4045) wedge and had no recovery at all.
          -- Two per cluster: a wall the incoming track cannot undo still
          -- gets the flank/backward escalation that saved earlier runs.
          local retrace, retraceIdx = retrace_point(pos)
          if retrace and snagClusterRetrace < RETRACE_TRIES then
            snagClusterRetrace = snagClusterRetrace + 1
            local dist = planar(pos.x, pos.y, retrace.x, retrace.y)
            snagTarget = { x = retrace.x, y = retrace.y }
            snagUntil = now + 4.0 + dist / 8.0
            snagSteer = true
            tape_rewind(retraceIdx)
            label = string.format("retrace %.0fyd", dist)
          elseif drifting and proven and
              seg_distance(pos.x, pos.y, proven.x, proven.y,
                beat.x, beat.y) > 40.0 then
            local back = planar(pos.x, pos.y, proven.x, proven.y)
            snagTarget = { x = proven.x, y = proven.y }
            snagUntil = now + 4.0 + back / 8.0
            label = "back to proven ground"
          elseif snagClusterCount >= 3 then
            local d = 30.0 * reach
            snagTarget = { x = pos.x - ux * d, y = pos.y - uy * d }
            snagUntil = now + 4.0 + d / 8.0
            label = "backward"
            if snagClusterCount >= 5 then snagClusterCount = 0 end
          else
            local d = 18.0 * reach
            snagSide = -snagSide
            snagTarget = { x = pos.x - uy * d * snagSide,
              y = pos.y + ux * d * snagSide }
            snagUntil = now + 4.0 + d / 8.0
            label = snagSide > 0 and "left" or "right"
          end
          snagCheckPos, snagCheckAt, snagCheckFrames = nil, nil, nil
          -- The hop itself is not "progress"; give it a fresh window so
          -- the drift test judges the corridor, not the sidestep.
          progressBest, progressAt = bdist, now
          escape_note("snag_hop", now, pos, beat)
          wow.log(string.format(
            "SNAG: %s at (%.1f, %.1f) — hopping %s to (%.1f, %.1f) (cluster %d reach %d)",
            drifting and "drifting" or "pinned",
            pos.x, pos.y, label, snagTarget.x, snagTarget.y,
            snagClusterCount, reach))
        end
      end
    end
  else
    snagCheckPos, snagCheckAt, snagCheckFrames = nil, nil, nil
  end
  return nil
end

local function navigate_sparse_land(view, pos, route, phase, stalled)
  -- A failsafe dump onto the Felwood road is still timbermaw-owned, but
  -- the captured mid-hold beats are now on the far side of a mountain.
  -- Unskip the walked chain so the seat re-enters at the mouth — not
  -- request timbermaw_45 across the range (cave_run_{1,2,3}).
  if phase == "timbermaw" and felwood_failsafe_dump(pos) then
    for _, b in ipairs(route.beats) do
      skipped[b.id] = nil
    end
  end
  local goal = route.beats[#route.beats]
  if planar(pos.x, pos.y, goal.x, goal.y) <= goal.radius then
    return nil
  end
  -- Hosted farmhouse: indoors stays false after the through-floor
  -- clip, so the 0043 trap never arms. Ground steers south at gazer2;
  -- roof (z>=20) and underground clip (z<5) steer west at dune2 —
  -- gazer2 is the steep south face (v28 MOVEGATE at z=28.6).
  if phase == "spawn_leg" and in_tanaris_farmhouse(pos)
      and not (view.indoors_known == true and view.indoors == true) then
    local kind = farmhouse_kind(pos)
    local exitBeat = farmhouse_exit_beat(kind)
    if exitBeat then
      if farmhouseEvKind ~= kind then
        farmhouseEvKind = kind
        mark_ev()
        wow.log(string.format("EV %s x=%.1f y=%.1f z=%.1f",
          kind, pos.x, pos.y, pos.z or 0))
      end
      local intent = navigate_to(view, pos, exitBeat, exitBeat.id,
        { stop = 8.0, status = { phase = phase, farmhouse = true } })
      if intent then
        intent.navigation_mode = "local_steer"
        intent.z = nil
        wow.set_status(string.format("%s farmhouse %.0fyd", phase,
          planar(pos.x, pos.y, exitBeat.x, exitBeat.y)))
        return intent
      end
    end
  end
  local beat = next_sparse_beat(route, pos.x, pos.y)
  -- Interior lookahead: with beats every ~7 yd, re-targeting each one
  -- replans the corridor every couple of seconds, and each replan is a
  -- pause paid inside the Warder picket. Steer at the first beat a real
  -- stride away; the skipped ones retire by capture as the seat passes,
  -- and the corridor to a beat ~20 yd down the walked line still follows
  -- the walked line. The goal beat is never skipped past.
  -- ...but NOT indoors: a 15+ yd target inside a bent WMO corridor asks
  -- the seam's broken projection for exactly the corridor it cannot
  -- serve (live roll: wedged at the pocket for a full timeout at 100%
  -- hp). The 7 yd density exists to keep interior planning local.
  -- The junction is the same rule even when the indoors flag flickers
  -- off (cave battery: indoors=true for two frames at 40, then false
  -- at z 625 while the 42->45 skip punched the floor).
  local look = beat
  if (view.indoors_known == true and view.indoors == true)
      or (phase == "timbermaw" and on_junction_deck(pos)) then
    look = nil
  end
  while look and planar(pos.x, pos.y, look.x, look.y) < 15.0 do
    local nxt = nil
    local seen = false
    for _, b in ipairs(route.beats) do
      if seen and not skipped[b.id] then nxt = b break end
      if b.id == look.id then seen = true end
    end
    if not nxt then break end
    look = nxt
  end
  if look then beat = look end
  -- Same recovery the painted road gets: a sparse corridor pins a seat just
  -- as hard (Timbermaw interior, 2026-08-11), and an open hop window must
  -- win over re-issuing the corridor the client has already refused.
  local hop = snag_recovery(view, pos, beat, phase, sparseReached[route])
  if hop then return hop end
  -- Rotation while moving needs CAPTURE before engine arrival: the land
  -- road's 25 yd radius / 8 yd stop geometry never lets the engine stop
  -- at a beat, but the interior chain's 8 yd beats with the same 8 yd
  -- stop fully ARRIVED at every one — 104 dead stops through the cave
  -- (monofuel's replay, 2026-08-12). Keep the stop strictly inside the
  -- capture radius so greedy capture rotates the target first; the goal
  -- hold above still keys on the final beat's full radius.
  local stop = math.min(8.0, math.max(3.0, beat.radius - 4.0))
  local intent = navigate_to(view, pos, beat, beat.id,
    { stop = stop, status = { phase = phase, stalled_seconds = stalled } })
  if intent then
    wow.set_status(string.format("%s %s %.0fyd", phase, beat.id,
      planar(pos.x, pos.y, beat.x, beat.y)))
    return intent
  end
  return { kind = "hold", reason = "replanning",
    status = bot_status(view, pos, beat, { phase = phase }) }
end

local function want_form(view, pos, spell, label)
  local now = wow.time()
  if lastFormCastAt and now - lastFormCastAt < FORM_RETRY_SECONDS then
    return nil
  end
  lastFormCastAt = now
  return { kind = "cast_spell", spell = spell, reason = label,
    status = bot_status(view, pos, nil) }
end

local function decide_intent(view)
  decideCount = decideCount + 1
  if not gateLogged then
    gateLogged = true
    wow.log("petrel: wet chain ON (hardwired)")
  end
  -- Death = the speedrun is over. No release, no corpse run, no recovery.
  if view.is_dead or view.is_ghost then
    if not deathLogged then
      deathLogged = true
      local where = "?"
      if view.location_known and view.location then
        where = string.format("(%.1f, %.1f)",
          view.location.position.x, view.location.position.y)
      end
      wow.log("SPEEDRUN OVER: died at " .. where ..
        " — do not corpse-run; fix whatever stopped the movement")
      if view.location_known and view.location then
        escape_close(wow.time(), view.location.position, "abandoned")
      end
    end
    wow.set_status("run over (died)")
    local status = { run_over = true }
    if view.location_known and view.location then
      status.x = view.location.position.x
      status.y = view.location.position.y
    end
    return { kind = "hold", reason = "run_over", status = status }
  end

  if not view.location_known or not view.location then
    return { kind = "hold", reason = "no_position" }
  end
  local pos = view.location.position
  -- The retrace tape and the kickstart window both date from the first
  -- decide that ever saw this seat: that instant IS "control" for the
  -- ~1-second startup budget.
  if controlAt == nil then
    controlAt = wow.time()
    controlPos = { x = pos.x, y = pos.y }
  end
  -- Escape windows drive the seat backward on purpose; taping those steps
  -- would make the next retrace follow the escape instead of the run.
  tape_record(pos, snagUntil ~= nil and wow.time() < snagUntil)
  local stalled = account(view, pos)
  deliberateHold = false
  trap_watch(view, pos)

  -- Park detector: a swimming seat that has not moved ~a body length for 3
  -- sim-seconds of real frames is frozen (pitch bang-bang, bank graze) —
  -- and a frozen swimmer in DRAIN water is dying for nothing (run 27).
  -- Open a short surface-ride window; held JUMP + forward always
  -- translates. Requires sustained frames so test harnesses with jumpy
  -- clocks cannot trip it, and active fatigue so safe-water pauses (form
  -- casts, beat handoffs) are left alone.
  if view.is_swimming then
    local now = wow.time()
    if parkCheckPos == nil or
        planar(pos.x, pos.y, parkCheckPos.x, parkCheckPos.y) > 2.0 then
      parkCheckPos, parkCheckAt, parkCheckFrames =
        { x = pos.x, y = pos.y }, now, 0
    else
      parkCheckFrames = (parkCheckFrames or 0) + 1
      if now - parkCheckAt > 3.0 and parkCheckFrames >= 10 and
          view.fatigue_timer and view.fatigue_timer.active and
          not (surfaceUntil and now < surfaceUntil) then
        surfaceUntil = now + 8.0
        parkCheckPos, parkCheckAt, parkCheckFrames =
          { x = pos.x, y = pos.y }, now, 0
        wow.log(string.format(
          "PARK: frozen swimmer at (%.1f, %.1f) — surfacing to unstick",
          pos.x, pos.y))
      end
    end
  else
    parkCheckPos, parkCheckAt, parkCheckFrames = nil, nil, nil
  end

  -- TEMP WETSTATEDBG: post-upstream-merge wet regressions (2026-08-11).
  -- Segment B: dry seat at the beach never wades in (nav=planning forever).
  -- Segment C: seat suspended mid-column, swim flag false, unrecovered.
  -- Log the client's liquid observation whenever the wet chain would want
  -- water but the seat is NOT swimming. Remove after the fork report.
  if not view.is_swimming then
    local near_beach = planar(pos.x, pos.y, -6784.5, -4833.9) < 250.0
    local submerged_odd = view.liquid_submerged or
      (view.liquid_known and type(view.liquid_surface_z) == "number" and
       pos.z < view.liquid_surface_z - 3.0)
    if near_beach or submerged_odd then
      local now = wow.time()
      if lastWetDbgAt == nil or now - lastWetDbgAt > 5.0 then
        lastWetDbgAt = now
        wow.log(string.format(
          "WETSTATEDBG pos=(%.1f,%.1f,%.1f) swim=%s lk=%s lck=%s sub=%s surf=%s form=%s nav=%s",
          pos.x, pos.y, pos.z or -99,
          tostring(view.is_swimming), tostring(view.liquid_known),
          tostring(view.liquid_coverage_known),
          tostring(view.liquid_submerged), tostring(view.liquid_surface_z),
          tostring(view.shapeshift_form_id), wow.nav_progress().state))
      end
    end
  end

  -- TEMP WETDBG: frozen-swimmer investigation (2026-08-10). Remove after.
  if view.is_swimming then
    local now = wow.time()
    -- Fine-grained inside the wall corridor: the parks live there.
    local dbg_window = pos.x > -5760.0 and pos.x < -5540.0
    if lastWetDbgAt == nil or now - lastWetDbgAt > (dbg_window and 5.0 or 50.0) then
      lastWetDbgAt = now
      wow.log(string.format(
        "WETDBG pos=(%.2f,%.2f,%.2f,o=%.3f) mode=%s spd=%s/%.2f form=%s/%s breath=%s/%.2f fat=%s/%.2f sub=%s surf=%s",
        pos.x, pos.y, pos.z or -99, pos.o or -99,
        tostring(view.movement_mode),
        tostring(view.movement_speed_known), view.movement_speed or -1,
        tostring(view.shapeshift_form_id),
        tostring(view.shapeshift_form_spell_id),
        tostring(view.breath_timer and view.breath_timer.active),
        (view.breath_timer and view.breath_timer.remaining_fraction) or -1,
        tostring(view.fatigue_timer and view.fatigue_timer.active),
        (view.fatigue_timer and view.fatigue_timer.remaining_fraction) or -1,
        tostring(view.liquid_submerged), tostring(view.liquid_surface_z))
        .. string.format(" nav=%s", wow.nav_progress().state))
    end
    if not actionBarLogged and view.action_bar_known then
      actionBarLogged = true
      local slots = {}
      for _, b in ipairs(view.action_buttons or {}) do
        if b.spell_id and b.spell_id > 0 then
          slots[#slots + 1] = string.format("%d=%d", b.slot or -1, b.spell_id)
        end
      end
      wow.log("WETDBG action_bar: " ..
        (#slots > 0 and table.concat(slots, " ") or "empty"))
    end
  end

  local land = beat_by_id("land_approach")
  local water = beat_by_id("water_entry")
  local goal = beat_by_id(CONNECT_WET.goal_id)
  local connectorGoal = beat_by_id(CONNECT_LAND.goal_id)
  local cave = beat_by_id(LAND.goal_id)
  local water_dist = planar(pos.x, pos.y, water.x, water.y)
  local land_dist = planar(pos.x, pos.y, land.x, land.y)
  local swimming = view.is_swimming == true
  local near_water = water_dist <= water.radius + 120.0
  -- North of the entry band: never re-target the beach.
  local mid_coast = pos.x > water.x + 40.0
  -- Dry west of -1000 is Bruiser displacement, not a course reset.
  if connectorStarted and pos.x < -1000.0 and swimming then
    connectorStarted, connectorComplete = false, false
  end
  -- Finale ownership is monotonic for the lifetime of the run. A collision
  -- fall inside Timbermaw can trigger the server's ordinary failsafe and put
  -- the seat back in Felwood; reverting to the northern-land route there
  -- hides the actual finale failure and sends the bot south. Checkpoint runs
  -- start a fresh process, so no in-run reset is needed.
  if not connectorStarted and
      ((pos.x >= -920.0 and pos.x < LAND.start_x) or
       planar(pos.x, pos.y, goal.x, goal.y) <= goal.radius + 20.0) then
    connectorStarted = true
  end
  if connectorStarted and not connectorComplete and
      planar(pos.x, pos.y, connectorGoal.x, connectorGoal.y) <=
        connectorGoal.radius then
    connectorComplete = true
  end
  if not finaleStarted and pos.x > 6300.0 and
      (pos.y < cave.y - 20.0 or
       planar(pos.x, pos.y, cave.x, cave.y) <= cave.radius + 50.0) then
    finaleStarted = true
  end
  local finale_phase = finaleStarted
  local interiorGoal = INTERIOR.beats[#INTERIOR.beats]
  if finale_phase and not interiorComplete and
      planar(pos.x, pos.y, interiorGoal.x, interiorGoal.y) <=
        interiorGoal.radius then
    interiorComplete = true
  end
  local connector_land_phase = connectorStarted and not connectorComplete and
    not swimming
  -- At/past the top of the Barrens the painted northern road owns the run,
  -- until the cave handoff starts the Winterspring finale.
  local land_phase = pos.x >= LAND.start_x and not finale_phase and
    not connector_land_phase
  local active_land_route = finale_phase and
    (interiorComplete and FINALE or INTERIOR) or
    (connector_land_phase and CONNECT_LAND or (land_phase and LAND or nil))

  -- Spawn leg: the corridor chain owns the run from spawn until its last
  -- beat retires (or the seat is simply past it) — a single 2,900 yd mesh
  -- leg to land_approach has no line to hold at starved hosted fps (v9/v10
  -- episodes wedged 400-600 yd off the champion line; see
  -- config/traverse_spawn_beats.lua).
  local spawn_phase = not swimming and not waterlineReached and
    pos.x < SPAWN.beats[#SPAWN.beats].x

  -- Flight recorder + anomaly EVs (logging only). Before form casts so a
  -- land-phase swim frame still records unplanned_swim before aquatic cast.
  flight_recorder(view, pos,
    active_land_route or (spawn_phase and SPAWN or nil))

  -- Forms are speed, and speed is the score. Aquatic whenever wet (even off
  -- plan — drowning slower is still better); Travel on dry open ground.
  -- Forms are also the ONLY casts this brain ever emits: no heals, no
  -- defensive cooldowns, no form canceling — casting means standing still,
  -- and standing still is the only way this bot dies (doctrine,
  -- docs/traverse/README.md).
  -- Aquatic also re-arms while WADING: grounding on a waterline shelf
  -- auto-cancels the form, and waiting for the swim flag to return left
  -- the seat formless for the whole shelf crossing (2026-08-13 water
  -- entry). Forms are instant and movement-safe (stance-bar press).
  -- ...but the FIRST intent of the run is always movement (ticket 0030).
  -- Forms are instant stance presses; a cast frame is not a movement frame,
  -- so it renews no translation lease and the seat stands there for however
  -- long the next decide takes to arrive — 2.1 sim-s at spawn on
  -- 2026-08-14, before the 5.4 s planning stall even started. Moving first
  -- costs one decide of Travel Form and buys the opening seconds. The
  -- decide-count arm keeps a hold-only opening (no position, replanning)
  -- from starving forms forever.
  if decideCount >= 4 then movementIssued = true end
  if movementIssued and (swimming or wading(view, pos)) then
    if not in_aquatic_form(view) then
      local cast = want_form(view, pos, AQUATIC_FORM_SPELL, "aquatic_form")
      if cast then return cast end
    end
  elseif movementIssued and
      (active_land_route or (not near_water and not mid_coast)) then
    -- Travel Form is OUTDOOR-ONLY in 1.12: inside a WMO the cast can
    -- never succeed, and every retry used to stand the seat still — the
    -- Timbermaw crawl monofuel watched (2026-08-12) was largely this.
    -- With the fork's indoors bridge the brain just keeps running
    -- formless and re-arms the moment it steps back outside.
    if view.indoors_known == true and view.indoors == true then
      if not formDeniedLogged then
        formDeniedLogged = true
        mark_ev()
        wow.log(string.format(
          "EV form_denied_indoors x=%.1f y=%.1f", pos.x, pos.y))
      end
      -- BEAR works indoors (only Travel/Aquatic are outdoor-only): same
      -- run speed, far more armor and health. The Timbermaw crossing is
      -- ~40 s inside the Warder picket's train; a formless seat burned
      -- 2,582 hp and died at beat 67 (2026-08-13 roll 1). The stance
      -- press is rank-agnostic (SHAPESHIFTBUTTON1 casts whatever bear
      -- the character knows). Still never fighting - bear is armor, not
      -- claws.
      -- Skip the stance press only while the trap is armed: walkout and
      -- unavailable are also how Timbermaw looks, and a formless seat
      -- dies there.
      if not in_bear_form(view) and not trapArmed then
        local cast = want_form(view, pos, BEAR_FORM_SPELL, "bear_form")
        if cast then return cast end
      end
    else
      formDeniedLogged = false
      -- Approaching the cave mouth: armor up OUTDOORS so the seat enters
      -- the picket already in bear, with no indoor cast dance and no
      -- form-bonus reset mid-crossing (rolls 2-4 re-cast inside).
      if finaleStarted and not interiorComplete and pos.x > 6440.0 and
          pos.y > -2160.0 then
        if not in_bear_form(view) then
          local cast = want_form(view, pos, BEAR_FORM_SPELL, "bear_form")
          if cast then return cast end
        end
      elseif not in_travel_form(view) then
        local cast = want_form(view, pos, TRAVEL_FORM_SPELL, "travel_form")
        if cast then return cast end
      end
    end
  end

  if finale_phase then
    -- The walked interior chain owns the cave until its last beat retires;
    -- only then does the Winterspring finale line take over.
    if not interiorComplete then
      return navigate_sparse_land(view, pos, INTERIOR, "timbermaw", stalled)
    end
    local fgoal = FINALE.beats[#FINALE.beats]
    if planar(pos.x, pos.y, fgoal.x, fgoal.y) <= fgoal.radius then
      stall_release(pos, wow.time())
      deliberateHold = true
      wow.set_status("goal: " .. FINALE.goal_id)
      return { kind = "hold", reason = FINALE.goal_id,
        status = bot_status(view, pos, fgoal, { phase = "finale" }) }
    end
    return navigate_sparse_land(view, pos, FINALE, "finale", stalled)
  end

  if connector_land_phase then
    return navigate_sparse_land(view, pos, CONNECT_LAND,
      "barrens_connector", stalled)
  end

  -- North land phase: top of the Barrens through Ashenvale and Felwood to
  -- the Timbermaw cave mouth. Sparse road beats + mesh navigation, always
  -- moving; never fight, never heal, never stop.
  if land_phase then
    local lgoal = LAND.beats[#LAND.beats]
    if planar(pos.x, pos.y, lgoal.x, lgoal.y) <= lgoal.radius then
      stall_release(pos, wow.time())
      deliberateHold = true
      wow.set_status("goal: " .. LAND.goal_id)
      return { kind = "hold", reason = LAND.goal_id,
        status = bot_status(view, pos, lgoal, { phase = "north_land" }) }
    end
    local beat = next_land_beat(pos.x, pos.y)
    -- lastReached is the proven ground here: the northern beats are
    -- resampled from a run that walked them.
    local hop = snag_recovery(view, pos, beat, "north_land", lastReached)
    if hop then return hop end

    local intent = navigate_to(view, pos, beat, beat.id,
      { stop = 8.0,
        status = { phase = "north_land", stalled_seconds = stalled } })
    if intent then
      wow.set_status(string.format("north_land %s %.0fyd", beat.id,
        planar(pos.x, pos.y, beat.x, beat.y)))
      return intent
    end
    return { kind = "hold", reason = "replanning",
      status = bot_status(view, pos, beat, { phase = "north_land" }) }
  end

  -- Wet chain: cheese ribbon through Duskwallow and Merchant
  -- Bay, then the final coastal approach to the Barrens shore.

  -- The wet chain also engages dry inside the entry band: standing on the
  -- sand at water_entry must press on toward the first wet beat (the ground
  -- route ends at the shoreline; wading and physics finish the entry).
  if swimming or wading(view, pos) or mid_coast or
      water_dist <= water.radius then
    -- One goal key for the whole ribbon: the engine's shoreline-retention
    -- clause requires the incoming goal key to match the stored one to
    -- bridge frames where stock clears the swim flag before the body has
    -- left the liquid. Per-beat keys would drop retention exactly at a
    -- beat handoff. Wet beats carry the human run's z (see navigate_to).
    local reason = (swimming or mid_coast) and "swim_ribbon" or "enter_water"
    -- Dry in the entry region with NO OBSERVABLE LIQUID: ground planning
    -- can never serve a wet beat and the wade entry needs liquid at the
    -- feet, so walk to the waterline point first (tight stop — the 50 yd
    -- beat radius would declare arrival on dry sand). The moment liquid
    -- becomes observable the wade machinery owns entry — a distance-based
    -- release deadlocked here (ground nav stalls ~14 yd out in the surf,
    -- battery four).
    -- ONE-WAY: once the seat has stood at the waterline, this branch never
    -- fires again. The waterline point is the BEACH beat, ~11 yd shy of
    -- the actual sea, and honest ADT liquid keeps lk=false on the sand —
    -- so wading east out of the 12 yd ring used to re-trigger this branch
    -- and drag the seat back west forever (dry-entry oscillation,
    -- 2026-08-12: 513 wading frames, zero net progress).
    if water_dist <= 12.0 then waterlineReached = true end
    if not swimming and not wading(view, pos) and not waterlineReached and
        not (view.liquid_coverage_known and view.liquid_known) and
        pos.x < water.x + 150.0 and water_dist > 12.0 then
      local intent = navigate_to(view, pos, water, "to_waterline",
        { stop = 8.0, status = { stalled_seconds = stalled } })
      if intent then
        wow.set_status(string.format("to_waterline %.0fyd", water_dist))
        return intent
      end
    end
    local fatigued = (view.fatigue_timer and view.fatigue_timer.active)
      or false
    local wet = next_wet_beat(pos.x, pos.y, fatigued)
    if wet then
      -- Refill beats demand a genuine touch inside the safe band: tight
      -- stop, tight capture — the instant refill skips anything skirted.
      -- Liquid-blind shoreline (post-merge fork bug: the sample is
      -- REJECTED, not corrected, so liquid_known=false at the beach): the
      -- wade gate cannot open, and a commanded z of -2.5 sits below the
      -- swim polys' projection band so ground planning cannot serve the
      -- wet target either — the seat parks on the sand jiggling (stitched
      -- run, 2026-08-11). With no z the planner projects the target onto
      -- the surface poly and simply walks in; the wade/swim machinery
      -- takes over the moment liquid becomes observable.
      local liquid_blind = not swimming and
        not (view.liquid_coverage_known and view.liquid_known)
      local intent = navigate_to(view, pos, wet, reason,
        { stop = (wet.refill and fatigued) and 4.0 or WET_SELECT_YARDS - 4.0,
          surface = liquid_blind,
          status = { stalled_seconds = stalled } })
      if intent then
        wow.set_status(string.format("%s %s %.0fyd", reason, wet.id,
          planar(pos.x, pos.y, wet.x, wet.y)))
        return intent
      end
    end
    local intent = navigate_to(view, pos, goal, reason, {})
    if intent then return intent end
  end

  -- Dry approach, same shape as the land-only phase. The spawn corridor
  -- chain steers first; when it retires (goal beat captured or passed) the
  -- land_approach handoff below owns the last ~150 yd to the wet chain.
  if spawn_phase then
    local intent = navigate_sparse_land(view, pos, SPAWN, "spawn_leg",
      stalled)
    if intent then return intent end
  end
  local beat = water
  if not skipped[land.id] and land_dist > land.radius and
      water_dist > 400.0 and pos.x < land.x + PASSED_YARDS then
    beat = land
  end
  -- ...including the recovery every other walking phase already had. This
  -- leg had NONE, which is why the 2026-08-14 wedge at (-7678.4, -4045.3) —
  -- squarely on it, steering at land_approach with nav="following" — logged
  -- not one brain-side SNAG in 62 sim-s and was left to the fork's blind
  -- serpentine. The retrace tape is the proven ground out here; the two
  -- sparse beats are hundreds of yards apart and prove nothing local.
  local hop = snag_recovery(view, pos, beat, "coast_approach", nil)
  if hop then return hop end
  local intent = navigate_to(view, pos, beat, beat.id,
    { status = { stalled_seconds = stalled } })
  if intent then
    wow.set_status(beat.id)
    return intent
  end
  return { kind = "hold", reason = "replanning",
    status = bot_status(view, pos, beat) }
end

--- The split sheet bills each interval to the intent that owned it, and only
--- the returning decide knows which intent that was.
function M.decide(view)
  local intent = decide_intent(view)
  lastIntentKind = intent and intent.kind or nil
  if lastIntentKind == "navigate" then movementIssued = true end
  return intent
end

return M
