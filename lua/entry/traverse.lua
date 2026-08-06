-- traverse mode: maximize Kalimdor northing under fair play.
-- V4/Petrel: Travel Form → water entry → Aquatic Form swim toward merchant coast.
-- Forms use shapeshift (not main action bar). See docs/traverse/petrel-plan.md.

local move_to = require("move_to")

local M = {
  name = "traverse",
  goal = "Maximize Kalimdor northing under fair play.",
}

-- Classic 1.12 Travel Form (spell 783, shapeshift form id 3).
local TRAVEL_FORM_SPELL = 783
local TRAVEL_FORM_ID = 3
-- Classic 1.12 Aquatic Form (spell 1066, shapeshift form id 4 / FORM_AQUA).
local AQUATIC_FORM_SPELL = 1066
local AQUATIC_FORM_ID = 4

-- Leg 1: north end of Tanaris desert in water.
local WATER_ENTRY_X = -6784.5
local WATER_ENTRY_Y = -4833.9
local WATER_ENTRY_Z = 0.7
local WATER_ENTRY_RADIUS = 50.0
-- Land approach waypoint (avoids cliff/mesa stick ~water 650 NE of entry).
local LAND_APPROACH_X = -7100.0
local LAND_APPROACH_Y = -4600.0
local LAND_APPROACH_RADIUS = 80.0

-- Leg 2: merchant-coast water (Barrens corner). Prove ≤100 yd.
local MERCHANT_X = -1533.7
local MERCHANT_Y = -4056.5
local MERCHANT_Z = -12.3
local MERCHANT_RADIUS = 100.0

-- Segment hops along the goal vector.
local HOP_YARDS = 80.0
-- Seaward track offset from bare water_entry→merchant line. Bare line clips
-- beach. Deep track (100yd) fatigue-kills ~x=-6100; shallow + early ocean-pull
-- beaches. Default mid corridor; fatigue band hugs tighter (see coast_track_yards).
local COAST_TRACK_YARDS = 50.0
-- Landward of track: soft/hard seaward pulls. Seaward of track: only pull
-- back when deep ocean (fatigue proxy).
local COAST_SOFT_YARDS = 18.0
local COAST_HARD_YARDS = 45.0
local COAST_OCEAN_YARDS = 70.0
local COAST_PULL_SOFT = 60.0
local COAST_PULL_HARD = 110.0
-- Fatigue corridor (Tanaris→Dustwallow open water): hug coast harder.
-- Live deaths ~x=-6160 with track 28 still too seaward; sit almost on bare line.
local FATIGUE_BAND_X0 = -6450.0
local FATIGUE_BAND_X1 = -5000.0
local FATIGUE_TRACK_YARDS = 8.0
local FATIGUE_OCEAN_YARDS = 22.0

local function is_corpse(frame)
  -- Body on the ground (not released). Ghost may still path.
  local d = frame and frame.death
  if d then
    if d.is_ghost == true or d.ghost == true then
      return false
    end
    if d.is_dead == true or d.dead == true then
      return true
    end
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
  if me and me.is_swimming == true then return true end
  return false
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

local function ensure_travel_form(frame)
  if in_travel_form(frame) then return nil end
  local known = frame.spells and frame.spells.known
  if known == nil or knows_spell(frame, TRAVEL_FORM_SPELL) then
    return {
      kind = "cast_spell",
      spell = TRAVEL_FORM_SPELL,
      reason = "travel_form",
    }
  end
  return { kind = "hold", reason = "travel_form_unknown" }
end

local function ensure_aquatic_form(frame)
  if in_aquatic_form(frame) then return nil end
  local known = frame.spells and frame.spells.known
  if known == nil or knows_spell(frame, AQUATIC_FORM_SPELL) then
    return {
      kind = "cast_spell",
      spell = AQUATIC_FORM_SPELL,
      reason = "aquatic_form",
    }
  end
  return { kind = "hold", reason = "aquatic_form_unknown" }
end

local function planar_dist(x0, y0, x1, y1)
  local dx = x1 - x0
  local dy = y1 - y0
  return math.sqrt(dx * dx + dy * dy)
end

local function hop_toward(x, y, tx, ty, hop_yards)
  local d = planar_dist(x, y, tx, ty)
  if d <= hop_yards or d < 1e-3 then
    return tx, ty
  end
  local s = hop_yards / d
  return x + (tx - x) * s, y + (ty - y) * s
end

--- Closest point on segment A→B to P (planar).
local function closest_on_segment(px, py, ax, ay, bx, by)
  local abx, aby = bx - ax, by - ay
  local len2 = abx * abx + aby * aby
  if len2 < 1e-6 then
    return ax, ay
  end
  local t = ((px - ax) * abx + (py - ay) * aby) / len2
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return ax + abx * t, ay + aby * t
end

--- Unit normal pointing seaward of the water_entry→merchant line.
--- Land approach is the inland reference (Tanaris beach / desert).
local function seaward_unit()
  local abx = MERCHANT_X - WATER_ENTRY_X
  local aby = MERCHANT_Y - WATER_ENTRY_Y
  local len = math.sqrt(abx * abx + aby * aby)
  if len < 1e-3 then
    return 0.0, -1.0
  end
  local n1x, n1y = -aby / len, abx / len
  local mx = (WATER_ENTRY_X + MERCHANT_X) * 0.5
  local my = (WATER_ENTRY_Y + MERCHANT_Y) * 0.5
  local toLandX = LAND_APPROACH_X - mx
  local toLandY = LAND_APPROACH_Y - my
  -- n1 landward → flip; else n1 is already seaward.
  if n1x * toLandX + n1y * toLandY > 0 then
    return -n1x, -n1y
  end
  return n1x, n1y
end

local function coast_track_yards(me_x)
  if me_x ~= nil and me_x > FATIGUE_BAND_X0 and me_x < FATIGUE_BAND_X1 then
    return FATIGUE_TRACK_YARDS
  end
  return COAST_TRACK_YARDS
end

local function coast_ocean_yards(me_x)
  if me_x ~= nil and me_x > FATIGUE_BAND_X0 and me_x < FATIGUE_BAND_X1 then
    return FATIGUE_OCEAN_YARDS
  end
  return COAST_OCEAN_YARDS
end

--- Bias hop vs a seaward track on water_entry→merchant.
--- Signed side: +seaward / −landward of track. Landward → pull out to sea.
--- Only pull landward when deep ocean (fatigue); mild seaward is fine water.
local function bias_hop_to_coast(hx, hy, me_x, me_y)
  local cx, cy = closest_on_segment(
    me_x, me_y,
    WATER_ENTRY_X, WATER_ENTRY_Y,
    MERCHANT_X, MERCHANT_Y
  )
  local sx, sy = seaward_unit()
  local track = coast_track_yards(me_x)
  local ocean = coast_ocean_yards(me_x)
  local tx = cx + sx * track
  local ty = cy + sy * track
  local side = (me_x - tx) * sx + (me_y - ty) * sy
  local off = math.abs(side)
  local pull = 0
  local px, py = 0, 0
  if side < -COAST_SOFT_YARDS then
    pull = (side < -COAST_HARD_YARDS) and COAST_PULL_HARD or COAST_PULL_SOFT
    px, py = sx * pull, sy * pull
  elseif side > ocean then
    -- Stronger landward pull inside fatigue band.
    local scale = 0.7
    if me_x ~= nil and me_x > FATIGUE_BAND_X0 and me_x < FATIGUE_BAND_X1 then
      scale = 1.15
    end
    pull = COAST_PULL_SOFT * scale
    px, py = -sx * pull, -sy * pull
  elseif me_x ~= nil and me_x > FATIGUE_BAND_X0 and me_x < FATIGUE_BAND_X1
      and side > 5.0 then
    -- Even mild seaward of the tight track: nudge landward (fatigue deaths
    -- at ~x=-6160 with track 28 still open-water).
    pull = COAST_PULL_SOFT * 0.55
    px, py = -sx * pull, -sy * pull
  else
    return hx, hy, off, 0
  end
  return hx + px, hy + py, off, pull
end

--- Merchant coast is a *swim* leg only (petrel: stay wet, no land-cut).
--- Land north of water entry still aims water_entry until actually swimming.
local function on_swim_leg(swimming)
  return swimming == true
end

function M.decide(frame, args)
  args = args or {}
  local me = frame and frame.self_unit
  if not me or me.x == nil or me.y == nil then
    return { kind = "hold", reason = "no_self_position" }
  end
  -- Death: corpse holds until release (lowerer clicks DEATH popup). Ghost keeps pathing.
  if is_corpse(frame) then
    return { kind = "hold", reason = "release_spirit" }
  end
  local death = frame.death or {}
  if death.can_reclaim_corpse == true then
    return { kind = "hold", reason = "reclaim_corpse" }
  end

  local hop = args.hop_yards or HOP_YARDS
  local water_x = args.checkpoint_x or WATER_ENTRY_X
  local water_y = args.checkpoint_y or WATER_ENTRY_Y
  local water_z = args.checkpoint_z or WATER_ENTRY_Z
  local water_r = args.arrival_radius or WATER_ENTRY_RADIUS
  local merch_x = args.merchant_x or MERCHANT_X
  local merch_y = args.merchant_y or MERCHANT_Y
  local merch_z = args.merchant_z or MERCHANT_Z
  local merch_r = args.merchant_radius or MERCHANT_RADIUS

  local swimming = is_swimming(frame)
  local water_dist = planar_dist(me.x, me.y, water_x, water_y)
  local merch_dist = planar_dist(me.x, me.y, merch_x, merch_y)

  -- Forms: Travel on land far from water; Aquatic while swimming.
  -- Classic 1.12 auto-cancels Travel Form when you enter water, and Aquatic
  -- Form when you leave water. No /cancelform, no re-cast to leave form, no
  -- manual form cancel at the shoreline — walk/swim and let the game drop it.
  -- Near water / mid-coast dry: do not recast Travel (water_dist to Tanaris
  -- entry is huge mid-coast and used to thrash travel_form).
  local mid_coast = me.x > (WATER_ENTRY_X + 80.0)
  local near_water = water_dist <= (water_r + 120.0) or mid_coast
  -- Ghosts cannot form; skip form gates and keep pathing.
  -- Form cast can flake headless; never hard-lock forever on cast_spell alone.
  -- Phase uses view_id (ticks) so stuck poses still rotate leave/cast/move.
  local ghost = is_ghost(frame)
  local phase = 0
  if type(frame.view_id) == "number" then
    phase = math.floor(frame.view_id)
  elseif type(me.x) == "number" and type(me.y) == "number" then
    phase = math.floor(math.abs(me.x) + math.abs(me.y) * 3 + math.abs(me.z or 0) * 7)
  end
  if not ghost then
    if swimming then
      -- Aquatic: cast sparingly so stance clicks don't thrash-toggle, and we
      -- keep moving. Hard only when breath timer is active (true unformed
      -- underwater) or still in Travel. Project patches form from last_ok 1066.
      local formAct = ensure_aquatic_form(frame)
      if formAct then
        local breathActive = me.breath_timer_active == true
        local wrongForm = in_travel_form(frame)
        -- Cadence: cast often enough to stick, not every tick (freezes W).
        -- Unformed + wet: prefer more frequent cast (phase%3) so form sticks
        -- during reenter flap before breath bar appears.
        if wrongForm and (phase % 2) == 0 then
          return formAct
        elseif breathActive and (phase % 2) == 0 then
          return formAct
        elseif (not breathActive) and (not wrongForm) and (phase % 3) == 0 then
          return formAct
        end
      end
    elseif near_water then
      -- Shore / mid-coast beach: keep moving; form change is automatic on water.
    else
      -- Travel far from shore (Tanaris approach only). Soft when form 0 —
      -- hard cast every tick froze live bot when Travel never stuck.
      local formAct = ensure_travel_form(frame)
      if formAct then
        local fid = me.shapeshift_form_id
        if fid == nil or fid == 0 then
          if (phase % 2) == 0 then return formAct end
        elseif (phase % 4) == 0 then
          return formAct
        end
      end
    end
  end

  -- Merchant prove only counts while wet (no land-cut victory).
  if swimming and merch_dist <= merch_r then
    return { kind = "hold", reason = "merchant_coast" }
  end

  local goal_x, goal_y, goal_z, reason
  -- Ghost recovery so living Aquatic swim can resume.
  if ghost and death.gossip_open == true then
    return {
      kind = "interact",
      reason = "spirit_healer_gossip",
      name = death.spirit_healer_name or "Spirit Healer",
    }
  end
  -- Interact when close enough. arrival_radius=8 used to stop the ghost ~5–8yd
  -- out (outside interact_dist ~3.7) and orbit forever. Prefer a generous
  -- interact band; InteractUnit works inside ~5yd.
  if ghost and death.spirit_healer_known == true
      and type(death.spirit_healer_dist) == "number" then
    local interactR = 5.5
    if type(death.spirit_healer_interact_dist) == "number"
        and death.spirit_healer_interact_dist > 0.5 then
      local soft = death.spirit_healer_interact_dist + 1.5
      if soft > interactR then interactR = soft end
    end
    if death.spirit_healer_dist <= interactR then
      return {
        kind = "interact",
        reason = "spirit_healer_interact",
        name = death.spirit_healer_name or "Spirit Healer",
      }
    end
  end
  if ghost and death.spirit_healer_known == true
      and type(death.spirit_healer_x) == "number"
      and type(death.spirit_healer_y) == "number" then
    goal_x, goal_y = death.spirit_healer_x, death.spirit_healer_y
    goal_z = death.spirit_healer_z or me.z or 10.0
    reason = "ghost_to_spirit_healer"
  elseif ghost and death.corpse_known == true
      and type(death.corpse_x) == "number" and type(death.corpse_y) == "number"
      and death.corpse_x ~= 0 then
    goal_x, goal_y = death.corpse_x, death.corpse_y
    goal_z = death.corpse_z or me.z or 0
    reason = "ghost_to_corpse"
  elseif ghost and not swimming then
    -- No corpse: Tanaris coast GY / spirit healer area (near water entry north).
    goal_x, goal_y, goal_z = -7200.0, -3940.0, 10.0
    reason = "ghost_to_spirit"
  elseif on_swim_leg(swimming) then
    -- Aim slightly ahead on a *seaward* track of water_entry→merchant (bare
    -- corridor clips beach — live hop y went landward and beached).
    local abx = merch_x - water_x
    local aby = merch_y - water_y
    local ab2 = abx * abx + aby * aby
    local t = 0
    if ab2 > 1e-3 then
      t = ((me.x - water_x) * abx + (me.y - water_y) * aby) / ab2
      if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local ahead = t + 0.08
    if ahead > 1 then ahead = 1 end
    local sx, sy = seaward_unit()
    local track = coast_track_yards(me.x)
    goal_x = water_x + abx * ahead + sx * track
    goal_y = water_y + aby * ahead + sy * track
    goal_z = merch_z
    reason = "swim_merchant"
  elseif water_dist <= (water_r + 25.0) then
    -- At shore: aim past entry into water along entry→merchant (not hold on beach).
    local dx, dy = merch_x - water_x, merch_y - water_y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 1e-3 then d = 1 end
    local into = ghost and 140.0 or 80.0
    goal_x = water_x + dx / d * into
    goal_y = water_y + dy / d * into
    goal_z = merch_z
    reason = "enter_water"
  elseif me.x > (WATER_ENTRY_X + 80.0) then
    -- Beached mid-coast: re-enter seaward *and* keep merchant progress.
    -- Pure seaward (mostly -Y) walks along beach; pure entry undoes northing.
    local sx, sy = seaward_unit()
    local abx = merch_x - water_x
    local aby = merch_y - water_y
    local ablen = math.sqrt(abx * abx + aby * aby)
    if ablen < 1e-3 then ablen = 1 end
    local fx, fy = abx / ablen, aby / ablen
    local into = ghost and 150.0 or 110.0
    local ahead = ghost and 60.0 or 50.0
    goal_x = me.x + sx * into + fx * ahead
    goal_y = me.y + sy * into + fy * ahead
    goal_z = merch_z
    reason = "reenter_water"
  else
    -- Land path. Prefer approach waypoint until close to water.
    -- East-clear is ONLY for GY/ridge band (water_dist already low, still
    -- north of approach) — not from spawn (live: crawled y~-2500 east for
    -- miles before southing).
    local ap_dist = planar_dist(me.x, me.y, LAND_APPROACH_X, LAND_APPROACH_Y)
    local northOfApproach = me.y > (LAND_APPROACH_Y + 120.0)
    -- GY ridge: still north of water latitude → go *south* first (live freeze
    -- at x~-6905 y~-4408 water_entry hop into cliff). Then east-clear / entry.
    local northOfWater = me.y > (water_y + 180.0)
    local onRidgeBand = me.x > -7200.0 and me.x < -6750.0
        and water_dist < 900.0
    if onRidgeBand and northOfWater then
      goal_x = math.min(me.x + 50.0, water_x + 40.0)
      goal_y = water_y + 60.0
      goal_z = water_z
      reason = "land_south_clear"
    elseif northOfApproach and water_dist > 550.0 and water_dist < 1400.0
        and me.x > -7400.0 and me.x < -6900.0 then
      goal_x, goal_y, goal_z = -6700.0, me.y - 80.0, water_z
      reason = "land_east_clear"
    elseif water_dist > 400.0 and ap_dist > LAND_APPROACH_RADIUS
        and not (northOfApproach and water_dist < 550.0 and me.x > -7000.0) then
      goal_x, goal_y, goal_z = LAND_APPROACH_X, LAND_APPROACH_Y, water_z
      reason = "land_approach"
    else
      goal_x, goal_y, goal_z = water_x, water_y, water_z
      reason = "water_entry"
    end
  end

  local nx, ny = hop_toward(me.x, me.y, goal_x, goal_y, hop)
  if swimming then
    local pull
    nx, ny, _, pull = bias_hop_to_coast(nx, ny, me.x, me.y)
    if pull > 0 then
      reason = "swim_merchant_coast_bias"
    end
  end

  -- Unstick only on a cadence. me.moving==false every tick (form cast) used to
  -- fire unstick constantly and reverse northing while swimming (live: thrash
  -- south along shore). Ghost near Spirit Healer: never hard-kick — live unstick
  -- sent hop to y~-3848 while spirit sat at y~-3941.
  local stuckLike = false
  local spiritClose = ghost and type(death.spirit_healer_dist) == "number"
      and death.spirit_healer_dist <= 25.0
  if ghost and spiritClose then
    stuckLike = false
  elseif ghost and (phase % 12) == 0 then
    stuckLike = true
  elseif swimming and me.moving == false and (phase % 15) == 0 then
    stuckLike = true
  elseif (not swimming) and me.moving == false and (phase % 10) == 0 then
    stuckLike = true
  elseif (not swimming) and water_dist < 500.0 and (phase % 12) == 0 then
    stuckLike = true
  elseif (not swimming) and (phase % 25) == 0 then
    stuckLike = true
  end
  if stuckLike then
    local dx, dy = goal_x - me.x, goal_y - me.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d > 5 then
      local ang = math.atan(dy, dx)
      local side = 1
      if (phase % 2) == 0 then side = -1 end
      local uhop = hop
      if swimming or ghost then
        -- Mild lateral only — keep forward component toward goal.
        ang = ang + side * 0.35
      elseif reason == "water_entry" or reason == "land_approach"
          or reason == "enter_water" or reason == "reenter_water"
          or reason == "land_south_clear" or reason == "land_east_clear" then
        -- Mild lateral; land_south_clear needs a bit more kick off ridge walls.
        local kick = 0.4
        if reason == "land_south_clear" or reason == "land_east_clear" then
          kick = 0.7
        end
        ang = ang + side * kick
      else
        local kick = 1.2 + 0.3 * (phase % 3)
        ang = ang + side * kick
        uhop = hop * (1.2 + 0.2 * (phase % 3))
      end
      nx = me.x + math.cos(ang) * uhop
      ny = me.y + math.sin(ang) * uhop
      reason = reason .. "_unstick"
    end
  end

  local arr = math.min(water_r, 8.0)
  -- Ghost walk-in: do not "arrive" 8yd out of Spirit Healer range.
  if ghost and reason and string.find(reason, "spirit_healer", 1, true) then
    arr = 2.0
  end
  return move_to.decide(frame, {
    map_id = me.map_id or 1,
    x = nx,
    y = ny,
    z = goal_z,
    intent = "travel",
    reason = reason,
    destination_z_unknown = true,
    arrival_radius = arr,
  })
end

return M
