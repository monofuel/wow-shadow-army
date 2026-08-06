-- Petrel strategy: sparse beats + forms + wet-only prove.
-- Navigation geometry lives in Nim (RPB / client navmesh), not here.
-- See docs/traverse/embed-lua-client.md and pathing.md.
--
-- Intent kinds only:
--   navigate { x, y, z?, map_id, stop_distance, mode, reason }
--   cast_spell { spell, reason }   -- forms
--   hold { reason }
--
-- MOTION SICKNESS BAN: never emit lateral unstick / L/R thrash hops.

local M = {
  name = "traverse",
  goal = "Maximize Kalimdor northing under fair play.",
}

local TRAVEL_FORM_SPELL = 783
local TRAVEL_FORM_ID = 3
local AQUATIC_FORM_SPELL = 1066
local AQUATIC_FORM_ID = 4

-- Defaults match lua/config/traverse_beats.json (overridable via args).
local DEFAULT_BEATS = {
  {
    id = "land_approach",
    x = -7100.0, y = -4600.0, z = 10.0,
    radius = 80.0, mode = "land", require_wet = false,
  },
  {
    id = "water_entry",
    x = -6784.5, y = -4833.9, z = 0.7,
    radius = 50.0, mode = "land", require_wet = false,
  },
  {
    id = "merchant",
    x = -1533.7, y = -4056.5, z = -12.3,
    radius = 100.0, mode = "liquid_prefer", require_wet = true,
  },
}

local function is_corpse(frame)
  local d = frame and frame.death
  if d then
    if d.is_ghost == true or d.ghost == true then return false end
    if d.is_dead == true or d.dead == true then return true end
  end
  local c = frame and frame.combat
  if c and type(c.health_pct) == "number" and c.health_pct <= 0 then
    local g = d and (d.is_ghost == true or d.ghost == true)
    if not g then return true end
  end
  return false
end

local function is_ghost(frame)
  local d = frame and frame.death
  if not d then return false end
  return d.is_ghost == true or d.ghost == true
end

local function knows_spell(frame, spellId)
  local known = frame and frame.spells and frame.spells.known
  if type(known) ~= "table" then return false end
  for _, s in ipairs(known) do
    if s == spellId then return true end
  end
  return false
end

local function is_swimming(frame)
  local me = frame and frame.self_unit
  return me and me.is_swimming == true
end

local function in_travel_form(frame)
  local me = frame and frame.self_unit
  if not me then return false end
  if me.shapeshift_form_id == TRAVEL_FORM_ID then return true end
  if me.shapeshift_form_spell_id == TRAVEL_FORM_SPELL then return true end
  return false
end

local function in_aquatic_form(frame)
  local me = frame and frame.self_unit
  if not me then return false end
  if me.shapeshift_form_id == AQUATIC_FORM_ID then return true end
  if me.shapeshift_form_spell_id == AQUATIC_FORM_SPELL then return true end
  return false
end

local function planar_dist(x0, y0, x1, y1)
  local dx, dy = x1 - x0, y1 - y0
  return math.sqrt(dx * dx + dy * dy)
end

local function navigate_to(beat, reason, map_id)
  return {
    kind = "navigate",
    map_id = map_id or 1,
    x = beat.x,
    y = beat.y,
    z = beat.z,
    stop_distance = beat.radius or 8.0,
    mode = beat.mode or "land",
    reason = reason or beat.id or "navigate",
    beat_id = beat.id,
  }
end

local function load_beats(args)
  if args and type(args.beats) == "table" and #args.beats > 0 then
    return args.beats
  end
  return DEFAULT_BEATS
end

local function beat_by_id(beats, id)
  for _, b in ipairs(beats) do
    if b.id == id then return b end
  end
  return nil
end

function M.decide(frame, args)
  args = args or {}
  local me = frame and frame.self_unit
  if not me or me.x == nil or me.y == nil then
    return { kind = "hold", reason = "no_self_position" }
  end

  -- Death: hold for reset (petrel: die → reset run). No ghost thrash pathing.
  if is_corpse(frame) then
    return { kind = "hold", reason = "release_spirit" }
  end
  if is_ghost(frame) then
    return { kind = "hold", reason = "dead_reset" }
  end
  local death = frame.death or {}
  if death.can_reclaim_corpse == true then
    return { kind = "hold", reason = "reclaim_corpse" }
  end

  local beats = load_beats(args)
  local land = beat_by_id(beats, "land_approach") or beats[1]
  local water = beat_by_id(beats, "water_entry") or beats[2] or land
  local merch = beat_by_id(beats, "merchant") or beats[#beats]
  local map_id = me.map_id or 1
  local swimming = is_swimming(frame)
  local merch_dist = planar_dist(me.x, me.y, merch.x, merch.y)
  local water_dist = planar_dist(me.x, me.y, water.x, water.y)
  local land_dist = planar_dist(me.x, me.y, land.x, land.y)

  local phase = 0
  if type(frame.view_id) == "number" then
    phase = math.floor(frame.view_id)
  end

  -- Forms: Travel on land far from shore; Aquatic while swimming.
  local near_water = water_dist <= ((water.radius or 50) + 120.0)
  local mid_coast = me.x > (water.x + 80.0)
  if swimming then
    -- Wet without Aquatic: cast hard (breath). ensure_* not used — every tick
    -- until form sticks; lowerer/fork skip re-cast if already shifted.
    if not in_aquatic_form(frame) then
      local known = frame.spells and frame.spells.known
      if known == nil or knows_spell(frame, AQUATIC_FORM_SPELL) then
        return {
          kind = "cast_spell",
          spell = AQUATIC_FORM_SPELL,
          reason = "aquatic_form",
        }
      else
        return { kind = "hold", reason = "aquatic_form_unknown" }
      end
    end
  elseif not near_water and not mid_coast then
    if not in_travel_form(frame) then
      local known = frame.spells and frame.spells.known
      if known == nil or knows_spell(frame, TRAVEL_FORM_SPELL) then
        local fid = me.shapeshift_form_id
        if (fid == nil or fid == 0) and (phase % 3) == 0 then
          return {
            kind = "cast_spell",
            spell = TRAVEL_FORM_SPELL,
            reason = "travel_form",
          }
        end
      else
        return { kind = "hold", reason = "travel_form_unknown" }
      end
    end
  end

  -- Wet-only merchant prove.
  if swimming and merch_dist <= (merch.radius or 100.0) then
    return { kind = "hold", reason = "merchant_coast" }
  end

  -- Active beat selection (sparse).
  if swimming then
    return navigate_to(merch, "swim_merchant", map_id)
  end

  -- Beached mid-coast: aim seaward of bare chord toward merchant (nav feet).
  if mid_coast then
    -- Target slightly seaward of merchant path: use merchant with land mode
    -- until wet; reenter goal is merchant itself so mesh/liquid can take over.
    local reenter = {
      id = "reenter",
      x = merch.x,
      y = merch.y,
      z = merch.z,
      radius = merch.radius,
      mode = "land",
    }
    return navigate_to(reenter, "reenter_water", map_id)
  end

  if water_dist <= ((water.radius or 50) + 25.0) then
    -- Do not park on the shoreline beat (radius would report "reached" forever).
    -- Aim seaward + slightly along merchant so feet enter liquid for Aquatic.
    local abx = merch.x - water.x
    local aby = merch.y - water.y
    local ablen = math.sqrt(abx * abx + aby * aby)
    if ablen < 1e-3 then ablen = 1 end
    local fx, fy = abx / ablen, aby / ablen
    -- Perpendicular seaward of water→merchant (land approach is inland).
    local n1x, n1y = -fy, fx
    local mx = (water.x + merch.x) * 0.5
    local my = (water.y + merch.y) * 0.5
    local toLandX = land.x - mx
    local toLandY = land.y - my
    if n1x * toLandX + n1y * toLandY > 0 then
      n1x, n1y = -n1x, -n1y
    end
    local into = {
      id = "enter_water",
      x = water.x + fx * 120.0 + n1x * 80.0,
      y = water.y + fy * 120.0 + n1y * 80.0,
      z = -5.0,
      radius = 20.0,
      mode = "land",
    }
    return navigate_to(into, "enter_water", map_id)
  end

  if land_dist > (land.radius or 80) and water_dist > 400.0 then
    return navigate_to(land, "land_approach", map_id)
  end

  return navigate_to(water, "water_entry", map_id)
end

return M
