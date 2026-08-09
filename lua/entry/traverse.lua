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

-- Wet-chain gate: flip once the land legs are proven on the lua-bot host.
local SWIM = false

local TRAVEL_FORM_SPELL = 783
local TRAVEL_FORM_ID = 3
local AQUATIC_FORM_SPELL = 1066
local AQUATIC_FORM_ID = 4

-- wow.time() is SIMULATION time, and league episodes run at 10x — a "6
-- second" window in sim seconds elapses in 0.6 wall seconds. These windows
-- are sim-scaled so they give the engine real wall time at 10x; at 1x
-- (manual debugging) they are just patient.
-- The host holds a pending form cast for 3 sim seconds; retry slower.
local FORM_RETRY_SECONDS = 40.0
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

local lastPos = nil
local lastProgressAt = nil
local stallSince = nil
local unroutableSince = nil
local unroutableBeat = nil
local skipped = {}
local lastFormCastAt = nil
local deathLogged = false

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
    if not skipped[b.id] and not passed and
        planar(x, y, b.x, b.y) > b.radius then
      if b.x + b.radius >= x - 40.0 then
        return b
      end
    end
  end
  return wet[#wet]
end

local function bot_status(view, pos, beat, extra)
  local water = beat_by_id("water_entry")
  local status = {
    beat = beat and beat.id or "?",
    x = pos.x,
    y = pos.y,
    dist_water = water and planar(pos.x, pos.y, water.x, water.y) or -1,
    swimming = view.is_swimming or false,
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

--- Skip a beat only when the client positively reports it cannot serve the
--- route and the host's walkout step is spent. A stall with a healthy route
--- is never grounds to change the plan — that is the underlying bug.
local function route_dead(beat)
  local now = wow.time()
  local nav = wow.nav_progress()
  local dead = nav.state == "unavailable" and not nav.walkout_available
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
  if route_dead(beat) then return nil end
  local intent = {
    kind = "navigate",
    x = beat.x,
    y = beat.y,
    map_id = math.floor(view.location.map_id or ROUTE.map_id),
    stop_distance = beat.radius,
    route_profile = "prefer_ground",
    reason = reason or beat.id,
    status = bot_status(view, pos, beat, opts.status),
  }
  -- Swim legs omit z: an unknown target Z makes the host surface-ride
  -- (held JUMP) instead of pitching toward the seabed.
  if not opts.surface then intent.z = beat.z end
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
    return { kind = "hold", reason = "run_over" }
  end

  if not view.location_known or not view.location then
    return { kind = "hold", reason = "no_position" }
  end
  local pos = view.location.position
  local stalled = watch_progress(view, pos)

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
      wow.set_status(string.format("at the coast (%.0fyd), awaiting swim pass",
        water_dist))
      return { kind = "hold", reason = "awaiting_swim_pass",
        status = bot_status(view, pos, water, { stalled_seconds = stalled }) }
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

  if swimming or wading(view, pos) or mid_coast then
    local wet = next_wet_beat(pos.x, pos.y)
    if wet then
      local reason = swimming and ("swim_" .. wet.id) or "enter_water"
      local intent = navigate_to(view, pos, wet, reason,
        { surface = swimming, status = { stalled_seconds = stalled } })
      if intent then
        wow.set_status(reason)
        return intent
      end
    end
    local intent = navigate_to(view, pos, goal, "swim_" .. ROUTE.goal_id,
      { surface = true })
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
