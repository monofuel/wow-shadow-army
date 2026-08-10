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

local function planar(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return math.sqrt(dx * dx + dy * dy)
end

local function beat_by_id(id)
  for _, b in ipairs(ROUTE.beats) do
    if b.id == id then return b end
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
--- behind us (Kalimdor +X is north) never regress the run.
local function next_wet_beat(x, y)
  local wet = {}
  for _, b in ipairs(ROUTE.beats) do
    if b.wet then wet[#wet + 1] = b end
  end
  if #wet == 0 then return nil end
  for _, b in ipairs(wet) do
    local passed = x >= (b.x + PASSED_YARDS)
    -- Entering a beat's capture zone retires it permanently: monotonic
    -- selection, no boundary flip-flop.
    if not skipped[b.id] and planar(x, y, b.x, b.y) <= WET_SELECT_YARDS then
      skipped[b.id] = true
    end
    if not skipped[b.id] and not passed then
      if b.x + b.radius >= x - 40.0 then
        return b
      end
    end
  end
  return wet[#wet]
end

local function bot_status(view, pos, beat, extra)
  local water = beat_by_id("water_entry")
  local goal = beat_by_id(ROUTE.goal_id)
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
    intent.z = beat.z
  end
  -- Wet beats are declared water goals: the host commits to the water
  -- (wade steering at the bearing until the swim flag flips) instead of
  -- asking ground planning for a corridor it will never grant. This is a
  -- speedrun — walk INTO the water, no inching on walkout crumbs.
  if beat.wet then intent.water = true end
  return intent
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
  local goal = beat_by_id(ROUTE.goal_id)
  local water_dist = planar(pos.x, pos.y, water.x, water.y)
  local land_dist = planar(pos.x, pos.y, land.x, land.y)
  local swimming = view.is_swimming == true
  local near_water = water_dist <= water.radius + 120.0
  -- North of the entry band: never re-target the beach.
  local mid_coast = pos.x > water.x + 40.0

  -- Forms are speed, and speed is the score. Aquatic whenever wet (even off
  -- plan — drowning slower is still better); Travel on dry open ground.
  if swimming then
    if not in_aquatic_form(view) then
      local cast = want_form(view, pos, AQUATIC_FORM_SPELL, "aquatic_form")
      if cast then return cast end
    end
  elseif not near_water and not mid_coast then
    if not in_travel_form(view) then
      local cast = want_form(view, pos, TRAVEL_FORM_SPELL, "travel_form")
      if cast then return cast end
    end
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

  -- Wet chain (SWIM=true): the manual-run ribbon, one sparse beat at a time,
  -- never a single ocean chord.
  if swimming and planar(pos.x, pos.y, goal.x, goal.y) <= goal.radius then
    wow.set_status("goal: " .. ROUTE.goal_id)
    return { kind = "hold", reason = ROUTE.goal_id,
      status = bot_status(view, pos, goal) }
  end

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
    local wet = next_wet_beat(pos.x, pos.y)
    if wet then
      local intent = navigate_to(view, pos, wet, reason,
        { stop = WET_SELECT_YARDS - 4.0,
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
