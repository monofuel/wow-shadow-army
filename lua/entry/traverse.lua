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
-- coast. This pass drives only the land legs; SWIM gates the wet chain until
-- the swim segment is proven separately (see docs/traverse/README.md).

local M = { name = "petrel" }

local ROUTE = require("config.traverse_beats")
local LAND = require("config.traverse_land_beats")
local COAST = require("config.traverse_coast_beats")
local CONNECT_WET = require("config.traverse_connector_wet_beats")
local CONNECT_LAND = require("config.traverse_connector_land_beats")
-- Timbermaw interior: walked-ground beats resampled from monofuel's manual
-- F9 cave logs (tools/resample_trace_beats.py; docs/traverse/
-- reference-logs.md). Live navigation through the WMO needs the fork's
-- local_steer + allow_jump features (ledgered); until they land, these
-- beats route like any others and the finale stays blocked at the cave.
local INTERIOR = require("config.traverse_finale_interior_beats")
local FINALE = require("config.traverse_finale_beats")

-- Wet-chain gate: PETREL_SWIM=1 opts a run into the wet chain. Default off
-- keeps traverse-desert's land-only PASS semantics ("awaiting_swim_pass").
local SWIM = os.getenv("PETREL_SWIM") == "1"

local TRAVEL_FORM_SPELL = 783
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
-- No progress for this long while movement is ours = a stall worth shouting
-- about (the suspected RPB-CPU/world-streaming blocker looks exactly like
-- this: route healthy, seat frozen). ~8 wall seconds at 10x.
local STALL_SECONDS = 80.0
-- A route the client cannot serve, with the walkout spent, gets this long
-- before the beat is skipped. Never faster than the engine can plan a long
-- corridor. ~6 wall seconds at 10x.
local ROUTE_PATIENCE_SECONDS = 60.0
local PROGRESS_YARDS = 3.0
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
-- No dive span: 15 wet-lab runs proved z-following at 10x tunnels the
-- seat through world collision at random (void falls in the early ribbon,
-- the -5675 wall face, and the cheese_26-28 basin), while the surface
-- ride never tunneled once. The one surface blocker — the -5675 wall
-- spur — is bypassed seaward by the v7 route (cheese_21/22). Keep the
-- machinery: a future route may need a dive window again.

local lastPos = nil
local lastProgressAt = nil
local stallSince = nil
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
local snagClusterPos = nil
local snagClusterCount = 0
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

local function planar(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return math.sqrt(dx * dx + dy * dy)
end

-- Distance from a point to the segment a->b, used to tell "wandering near the
-- proven line" from "gone".
local function seg_distance(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local len2 = dx * dx + dy * dy
  if len2 < 0.001 then return planar(px, py, ax, ay) end
  local t = ((px - ax) * dx + (py - ay) * dy) / len2
  if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
  return planar(px, py, ax + t * dx, ay + t * dy)
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
--- beats (westward Merchant Bay mouth), same rule as the land selector.
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
      if b.x + b.radius >= x - 40.0 then
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
  -- Wet chain reports distance to merchant_coast; land-only still uses
  -- the ROUTE segment goal (duskwallow_coast).
  local goal = beat_by_id(SWIM and COAST.goal_id or ROUTE.goal_id)
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

  -- FLIGHT cadence: 5s normal, 1s for 10s after any EV.
  local cadence = 5.0
  if lastEvAt and now - lastEvAt < 10.0 then cadence = 1.0 end
  if lastFlightAt == nil or now - lastFlightAt >= cadence then
    lastFlightAt = now
    local hp = -1
    if view.health_known then hp = math.floor(view.health or 0) end
    wow.log(string.format(
      'FLIGHT {"t":%.1f,"x":%.1f,"y":%.1f,"z":%.1f,"hp":%d,"form":%d,' ..
      '"swim":%s,"combat":%s,"nav":"%s","beat":"%s","xt":%.1f}',
      now, pos.x, pos.y, pos.z or 0, hp, formId,
      swimming and "true" or "false",
      (view.in_combat == true) and "true" or "false",
      tostring(wow.nav_progress().state or "?"),
      beatId, xt))
  end
end

--- Progress watchdog. Returns stall seconds (0 when moving) and logs the
--- transition once — a healthy route with a frozen seat is the evidence the
--- CPU/streaming investigation needs, so make it unmissable.
local function watch_progress(view, pos)
  local now = wow.time()
  if lastPos == nil or
      planar(pos.x, pos.y, lastPos.x, lastPos.y) >= PROGRESS_YARDS then
    lastPos, lastProgressAt = { x = pos.x, y = pos.y }, now
    stallSince = nil
    return 0
  end
  local controllable = view.movement_allowed and not view.rooted
  if not controllable or lastProgressAt == nil then return 0 end
  local stalled = now - lastProgressAt
  if stalled > STALL_SECONDS then
    if stallSince == nil then
      stallSince = now
      wow.log(string.format(
        "STALL: no progress for %.0fs at (%.1f, %.1f), nav=%s",
        stalled, pos.x, pos.y, wow.nav_progress().state))
    end
    return stalled
  end
  return 0
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
  return intent
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
  if snagUntil and now < snagUntil and snagTarget then
    return { kind = "navigate", x = snagTarget.x, y = snagTarget.y,
      z = pos.z, map_id = math.floor(view.location.map_id or ROUTE.map_id),
      stop_distance = 4.0, route_profile = "prefer_ground",
      reason = "snag_hop",
      status = bot_status(view, pos, beat,
        { phase = phase, snag_hop = true }) }
  end
  snagUntil, snagTarget = nil, nil
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
          if drifting and proven and
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
  local goal = route.beats[#route.beats]
  if planar(pos.x, pos.y, goal.x, goal.y) <= goal.radius then
    return nil
  end
  local beat = next_sparse_beat(route, pos.x, pos.y)
  -- Same recovery the painted road gets: a sparse corridor pins a seat just
  -- as hard (Timbermaw interior, 2026-08-11), and an open hop window must
  -- win over re-issuing the corridor the client has already refused.
  local hop = snag_recovery(view, pos, beat, phase, sparseReached[route])
  if hop then return hop end
  local intent = navigate_to(view, pos, beat, beat.id,
    { stop = 8.0, status = { phase = phase, stalled_seconds = stalled } })
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

function M.decide(view)
  if not gateLogged then
    gateLogged = true
    wow.log("petrel: wet chain " .. (SWIM and "ON (PETREL_SWIM=1)" or "off"))
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
  local stalled = watch_progress(view, pos)

  -- Park detector: a swimming seat that has not moved ~a body length for 3
  -- sim-seconds of real frames is frozen (pitch bang-bang, bank graze) —
  -- and a frozen swimmer in DRAIN water is dying for nothing (run 27).
  -- Open a short surface-ride window; held JUMP + forward always
  -- translates. Requires sustained frames so test harnesses with jumpy
  -- clocks cannot trip it, and active fatigue so safe-water pauses (form
  -- casts, beat handoffs) are left alone.
  if SWIM and view.is_swimming then
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
  if SWIM and not view.is_swimming then
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
  if SWIM and view.is_swimming then
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
  if connectorStarted and pos.x < -1000.0 then
    connectorStarted, connectorComplete = false, false
  end
  -- Finale ownership is monotonic for the lifetime of the run. A collision
  -- fall inside Timbermaw can trigger the server's ordinary failsafe and put
  -- the seat back in Felwood; reverting to the northern-land route there
  -- hides the actual finale failure and sends the bot south. Checkpoint runs
  -- start a fresh process, so no in-run reset is needed.
  if SWIM and not connectorStarted and
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

  -- Flight recorder + anomaly EVs (logging only). Before form casts so a
  -- land-phase swim frame still records unplanned_swim before aquatic cast.
  flight_recorder(view, pos, active_land_route)

  -- Forms are speed, and speed is the score. Aquatic whenever wet (even off
  -- plan — drowning slower is still better); Travel on dry open ground.
  -- Forms are also the ONLY casts this brain ever emits: no heals, no
  -- defensive cooldowns, no form canceling — casting means standing still,
  -- and standing still is the only way this bot dies (doctrine,
  -- docs/traverse/README.md).
  if swimming then
    if not in_aquatic_form(view) then
      local cast = want_form(view, pos, AQUATIC_FORM_SPELL, "aquatic_form")
      if cast then return cast end
    end
  elseif active_land_route or (not near_water and not mid_coast) then
    if not in_travel_form(view) then
      local cast = want_form(view, pos, TRAVEL_FORM_SPELL, "travel_form")
      if cast then return cast end
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
      lastPos, lastProgressAt, stallSince = { x = pos.x, y = pos.y },
        wow.time(), nil
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
      -- Holding at the segment goal by choice is not a stall.
      lastPos, lastProgressAt, stallSince = { x = pos.x, y = pos.y },
        wow.time(), nil
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

  if not SWIM then
    -- Land legs only: prove the seat can cross Tanaris to the coast.
    if water_dist <= water.radius then
      -- Holding by choice is not a stall; keep the watchdog quiet here.
      lastPos, lastProgressAt, stallSince = { x = pos.x, y = pos.y },
        wow.time(), nil
      wow.set_status(string.format("at the coast (%.0fyd), awaiting swim pass",
        water_dist))
      return { kind = "hold", reason = "awaiting_swim_pass",
        status = bot_status(view, pos, water) }
    end
    local beat = water
    if not skipped[land.id] and land_dist > land.radius and
        water_dist > 400.0 and pos.x < land.x + PASSED_YARDS then
      beat = land
    end
    local intent = navigate_to(view, pos, beat, beat.id,
      { status = { stalled_seconds = stalled } })
    if intent then
      wow.set_status(string.format("%s %.0fyd%s", beat.id,
        planar(pos.x, pos.y, beat.x, beat.y),
        stalled > 0 and string.format(" STALLED %.0fs", stalled) or ""))
      return intent
    end
    -- Beat just skipped; next frame re-plans against what is left.
    return { kind = "hold", reason = "replanning",
      status = bot_status(view, pos, beat) }
  end

  -- Wet chain (SWIM=true): cheese ribbon through Duskwallow and Merchant
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
    if not swimming and not wading(view, pos) and
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

  -- Dry approach, same shape as the land-only phase.
  local beat = water
  if not skipped[land.id] and land_dist > land.radius and
      water_dist > 400.0 and pos.x < land.x + PASSED_YARDS then
    beat = land
  end
  local intent = navigate_to(view, pos, beat, beat.id,
    { status = { stalled_seconds = stalled } })
  if intent then
    wow.set_status(beat.id)
    return intent
  end
  return { kind = "hold", reason = "replanning",
    status = bot_status(view, pos, beat) }
end

return M
