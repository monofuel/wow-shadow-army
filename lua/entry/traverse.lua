-- Petrel strategy: sparse beats + forms + wet-only prove.
-- Feet/pathfinding (mesh + recover) live in Nim RPB — see pathfinding-plan.md.
--
-- Intent kinds only:
--   navigate { x, y, z?, map_id, stop_distance, mode, reason, beat_id }
--   cast_spell { spell, reason }
--   hold { reason }
--
-- Never: hop polylines, L/R thrash, one straight swim across the ocean.

local M = {
  name = "traverse",
  goal = "Maximize Kalimdor northing under fair play.",
}

local TRAVEL_FORM_SPELL = 783
local TRAVEL_FORM_ID = 3
local AQUATIC_FORM_SPELL = 1066
local AQUATIC_FORM_ID = 4

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

local function is_wading(frame)
  local me = frame and frame.self_unit
  if not me or me.liquid_coverage_known ~= true or me.liquid_known ~= true then
    return false
  end
  if me.liquid_submerged == true then return true end
  if type(me.liquid_surface_z) ~= "number" or type(me.z) ~= "number" then
    return false
  end
  return math.abs(me.liquid_surface_z - me.z) <= 3.0
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

local function navigate_to(beat, reason, map_id, reference)
  local intent = {
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
  if reference then intent.route_reference = reference end
  return intent
end

local function load_beats(args)
  if args and type(args.beats) == "table" and #args.beats > 0 then
    return args.beats
  end
  return nil
end

local function beat_by_id(beats, id)
  for _, b in ipairs(beats) do
    if b.id == id then return b end
  end
  return nil
end

--- First wet beat not yet reached (by northing / planar). Sparse open-water chain.
local function next_wet_beat(beats, me_x, me_y)
  local wet = {}
  for _, b in ipairs(beats) do
    if b.require_wet or b.mode == "liquid_prefer" then
      wet[#wet + 1] = b
    end
  end
  if #wet == 0 then return nil end
  for _, b in ipairs(wet) do
    local r = b.radius or 60.0
    -- Stateless northing hysteresis: after crossing well into a beat's
    -- acceptance band, lateral drift must not select that beat again.
    local passed_northing = me_x >= (b.x + 20.0)
    if not passed_northing and planar_dist(me_x, me_y, b.x, b.y) > r then
      -- Prefer beats still north of us (Kalimdor +X north) so we don't regress.
      if b.x + r >= me_x - 40.0 then
        return b
      end
    end
  end
  return wet[#wet]
end

local function route_reference(beats, me_x, me_y)
  local wet = {}
  for _, b in ipairs(beats) do
    if b.require_wet or b.mode == "liquid_prefer" then
      wet[#wet + 1] = b
    end
  end
  if #wet == 0 then return nil end
  if #wet == 1 then
    return {
      segment_index = 1,
      cross_track_yards = planar_dist(me_x, me_y, wet[1].x, wet[1].y),
      along_route_yards = 0.0,
      total_route_yards = 0.0,
    }
  end

  local best_dist2, best_along, best_segment = nil, 0.0, 1
  local cumulative, total = 0.0, 0.0
  for i = 1, #wet - 1 do
    local a, b = wet[i], wet[i + 1]
    local dx, dy = b.x - a.x, b.y - a.y
    local len2 = dx * dx + dy * dy
    local len = math.sqrt(len2)
    local t = 0.0
    if len2 > 0 then
      t = ((me_x - a.x) * dx + (me_y - a.y) * dy) / len2
      if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local qx, qy = a.x + t * dx, a.y + t * dy
    local ex, ey = me_x - qx, me_y - qy
    local dist2 = ex * ex + ey * ey
    if best_dist2 == nil or dist2 < best_dist2 then
      best_dist2 = dist2
      best_along = cumulative + t * len
      best_segment = i
    end
    cumulative = cumulative + len
  end
  total = cumulative
  return {
    segment_index = best_segment,
    cross_track_yards = math.sqrt(best_dist2 or 0.0),
    along_route_yards = best_along,
    total_route_yards = total,
  }
end

function M.decide(frame, args)
  args = args or {}
  local me = frame and frame.self_unit
  if not me or me.x == nil or me.y == nil then
    return { kind = "hold", reason = "no_self_position" }
  end

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
  if not beats then
    return { kind = "hold", reason = "route_config_missing" }
  end
  local land = beat_by_id(beats, "land_approach") or beats[1]
  local water = beat_by_id(beats, "water_entry") or beats[2] or land
  local goal_id = args.goal_id or "duskwallow_coast"
  local goal = beat_by_id(beats, goal_id) or beats[#beats]
  local map_id = me.map_id or 1
  local swimming = is_swimming(frame)
  local wading = is_wading(frame)
  local goal_dist = planar_dist(me.x, me.y, goal.x, goal.y)
  local water_dist = planar_dist(me.x, me.y, water.x, water.y)
  local land_dist = planar_dist(me.x, me.y, land.x, land.y)
  local reference = route_reference(beats, me.x, me.y)

  local phase = 0
  if type(frame.view_id) == "number" then
    phase = math.floor(frame.view_id)
  end

  local near_water = water_dist <= ((water.radius or 50) + 120.0)
  -- Once north of the entry beat's acceptance band, never retarget the beach.
  -- The previous +80 boundary sat exactly on the observed shoreline and made
  -- adjacent frames alternate between water_entry and the first wet leg.
  local mid_coast = me.x > (water.x + 40.0)

  if swimming then
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

  if swimming and goal_dist <= (goal.radius or 100.0) then
    return {
      kind = "hold",
      reason = goal_id,
      beat_id = goal.id,
      route_reference = reference,
    }
  end

  -- Wet: next manual-route beat only (never one ocean chord).
  if swimming then
    local wet = next_wet_beat(beats, me.x, me.y)
    if wet then
      return navigate_to(
        wet, "swim_" .. (wet.id or "leg"), map_id, reference)
    end
    return navigate_to(goal, "swim_" .. goal_id, map_id, reference)
  end


  if wading then
    local wet = next_wet_beat(beats, me.x, me.y)
    if wet then
      return navigate_to(wet, "enter_water", map_id, reference)
    end
  end

  if mid_coast then
    -- Dry past entry: rejoin the next manual-route beat, never the first beat.
    local wet = next_wet_beat(beats, me.x, me.y)
    if wet then
      return navigate_to(wet, "reenter_water", map_id, reference)
    end
    return navigate_to(water, "reenter_water", map_id)
  end

  if water_dist <= ((water.radius or 50) + 25.0) then
    -- Into first wet open-water beat so we leave the beach.
    local wet = next_wet_beat(beats, me.x, me.y)
    if wet then
      return navigate_to(wet, "enter_water", map_id, reference)
    end
    local into = {
      id = "enter_water",
      x = water.x + 150.0,
      y = water.y - 80.0,
      z = -5.0,
      radius = 25.0,
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
