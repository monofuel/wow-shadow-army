-- Wet-chain contract for the Petrel brain (the wet chain is unconditional).

package.path = "lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;"

-- Recorded route data is local-only; see lua/tests/fixtures/petrel_route.lua.
local routeSource = require("tests.fixtures.petrel_route").select()
print("test_petrel_wet: route = " .. routeSource)

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

local petrel = require("petrel")

local function view(x, y, extra)
  local v = {
    location_known = true,
    location = { map_id = 1, position = { x = x, y = y, z = 0.0, o = 0.0 } },
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

local aquatic = { shapeshift_form_id = 4 }

-- Dry on the sand inside the entry band: the brain presses toward the
-- first wet beat instead of holding.
local entry = petrel.decide(view(-6790.0, -4840.0, { shapeshift_form_id = 3 }))
check(entry.kind == "navigate", "no hold at the entry band")
check(entry.reason == "enter_water", "dry entry uses the entry reason")
check(entry.x == -6737.63, "dry entry targets the first wet beat")
check(entry.z == nil,
  "a liquid-blind dry entry omits z so planning projects onto the surface")
check(entry.status and entry.status.dist_goal and entry.status.dist_goal > 0,
  "status carries planar distance to the goal")

-- Wading at the shoreline now arms Aquatic FIRST (2026-08-13: a
-- waterline-shelf grounding auto-cancels the form and waiting for the
-- swim flag left the seat formless for the whole crossing).
clock = clock + 20.0
local wadeCast = petrel.decide(view(-6780.0, -4850.0, {
  shapeshift_form_id = 3,
  liquid_known = true, liquid_coverage_known = true,
  liquid_surface_z = 0.0,
}))
check(wadeCast.kind == "cast_spell" and wadeCast.spell == 1066,
  "formless wading casts Aquatic before pressing on")

-- Already-aquatic wading still drives the same entry.
clock = clock + 5.0
local wade = petrel.decide(view(-6780.0, -4850.0, {
  shapeshift_form_id = 4,
  liquid_known = true, liquid_coverage_known = true,
  liquid_surface_z = 0.0,
}))
check(wade.kind == "navigate" and wade.reason == "enter_water",
  "wading keeps the entry reason")
check(wade.z == -2.5,
  "with liquid observable the draft clamp owns the wet z again")

-- Swimming without Aquatic Form casts it before anything else.
-- (clock clears the form-retry window consumed by the wading cast above)
clock = clock + 20.0
local unformed = petrel.decide(view(-6600.0, -4865.0, { is_swimming = true }))
check(unformed.kind == "cast_spell" and unformed.spell == 1066,
  "swimming casts aquatic form first")

-- Mid-ribbon the goal key is the constant ribbon key, and the next beat is
-- always ahead of us — never one already passed or already inside radius.
clock = clock + 5.0
local swim = petrel.decide(view(-6600.0, -4865.0,
  { shapeshift_form_id = 4, is_swimming = true }))
check(swim.kind == "navigate" and swim.reason == "swim_ribbon",
  "swimming uses the ribbon goal key")
check(swim.x == -6584.86, "targets the next unpassed beat outside radius")
check(swim.z == -7.45, "open-water legs dive with the human profile")

clock = clock + 5.0
local later = petrel.decide(view(-6400.0, -4920.0,
  { shapeshift_form_id = 4, is_swimming = true }))
check(later.kind == "navigate" and later.reason == "swim_ribbon",
  "the goal key is constant across beat handoffs")
check(later.x == -6413.2, "beat advance follows the ribbon")

-- A swim-flag flicker mid-coast (stock clears swimming before the body has
-- left the liquid) must keep the same goal key, or the engine's shoreline
-- retention drops and a ground plan fires from a watery pose.
clock = clock + 1.0
local flicker = petrel.decide(view(-6400.0, -4920.0, { shapeshift_form_id = 4 }))
check(flicker.kind == "navigate" and flicker.reason == "swim_ribbon",
  "a swim-flag flicker keeps the ribbon goal key")

-- An "unavailable" while swimming is a liquid-observation flicker, not a
-- dead route: wet beats are never skipped while swimming, no matter how
-- long the patience clock runs.
nav = { state = "unavailable", failed_here = false, walkout_available = false,
  waypoint_count = 0 }
clock = clock + 5.0
petrel.decide(view(-6400.0, -4920.0,
  { shapeshift_form_id = 4, is_swimming = true }))
clock = clock + 200.0
local held = petrel.decide(view(-6400.0, -4920.0,
  { shapeshift_form_id = 4, is_swimming = true }))
check(held.kind == "navigate" and held.x == -6413.2,
  "wet beats are never skipped while swimming")
nav = { state = "following", failed_here = false, walkout_available = false }

-- duskwallow_coast is retired like any ordinary wet beat: swimming there
-- continues the coast chain toward merchant_coast, not a hold.
clock = clock + 5.0
local pastDusk = petrel.decide(view(-4627.0, -4869.5,
  { shapeshift_form_id = 4, is_swimming = true }))
check(pastDusk.kind == "navigate" and pastDusk.water == true,
  "at duskwallow_coast navigates the coast chain, no hold")
check(pastDusk.reason == "swim_ribbon",
  "coast continuation keeps the ribbon goal key")

-- Coast beat selection just north of dusk targets coast_01 or coast_02.
clock = clock + 5.0
local coastPick = petrel.decide(view(-4300.0, -4900.0,
  { shapeshift_form_id = 4, is_swimming = true }))
check(coastPick.kind == "navigate" and coastPick.water == true,
  "mid-coast selects a coast beat")
check(
  (math.abs(coastPick.x - (-4363.6)) < 0.1 and math.abs(coastPick.y - (-4903.7)) < 0.1)
    or (math.abs(coastPick.x - (-4125.7)) < 0.1 and math.abs(coastPick.y - (-4841.2)) < 0.1),
  "at (-4300,-4900) targets coast_01 or coast_02")

-- Merchant Bay, ticket 0014 recut (2026-08-13): the bay chain runs the
-- direct race line and NEVER turns back. The fatigue-free corridor beat
-- hands straight on to the next corridor beat, eastward.
clock = clock + 5.0
local corridor = petrel.decide(view(-1728.0, -4210.0,
  { shapeshift_form_id = 4, is_swimming = true }))
check(corridor.kind == "navigate" and corridor.reason == "swim_ribbon" and
    corridor.x == -1688.0,
  "the bay corridor advances east, never west into the inlet")

-- The sandbar ridge is crossed ONCE, at its deepest saddle, and the beat
-- after it is the goal — no second crossing, no retrace.
clock = clock + 5.0
local saddle = petrel.decide(view(-1654.0, -4090.0,
  { shapeshift_form_id = 4, is_swimming = true }))
check(saddle.kind == "navigate" and saddle.reason == "swim_ribbon" and
    saddle.x == -1581.0,
  "the ridge saddle hands off east to the merchant goal")

-- The merchant WATER goal (81 yd of water, ring min 32.9 yd, no grounding)
-- hands off straight into connector_swim_01 — the old four-beat bay
-- departure retrace is gone.
clock = clock + 5.0
local goal = petrel.decide(view(-1581.0, -4070.0,
  { shapeshift_form_id = 4, is_swimming = true }))
check(goal.kind == "navigate" and goal.reason == "swim_ribbon" and
    goal.x == -1400.0,
  "merchant water goal hands off east into the Ratchet connector")
check(goal.status and goal.status.dist_goal < 25.0,
  "the goal handoff retains merchant closing distance")

-- The invariant this recut exists to hold: every wet beat from the coast
-- chain through the Barrens connector strictly increases x (the scored
-- northing axis), so none of them needs the `hook` back-track exemption.
local prev_x = nil
for _, cfg in ipairs({
  require("config.petrel.traverse_coast_beats"),
  require("config.petrel.traverse_connector_wet_beats"),
}) do
  for _, b in ipairs(cfg.beats) do
    check(b.hook == nil,
      "no bay beat needs the hook exemption: " .. b.id)
    check(prev_x == nil or b.x > prev_x,
      "wet beat x strictly increases (no backtrack): " .. b.id)
    prev_x = b.x
  end
end

-- One decide at the last departure beat retires the whole outbound bay
-- line (capture retires up to the farthest captured index), restoring the
-- Barrens approach for the shelf checks below.
clock = clock + 5.0
local depart = petrel.decide(view(-950.0, -3850.0,
  { shapeshift_form_id = 4, is_swimming = true }))
check(depart.kind == "navigate" and depart.x == -910.0,
  "capturing the last departure beat targets the beach lip")

-- The final shelf beat steers the swimmer onto the waterline at clamped
-- depth — never above the surface. (A z=+9.5 "shore" bypass here once
-- launched the bot clear of the water, Aquatic auto-cancel and all;
-- monofuel watched it drown repeatedly. Gone for good.)
clock = clock + 5.0
local shelf = petrel.decide(view(-928.0, -3805.0,
  { shapeshift_form_id = 4, is_swimming = true }))
check(shelf.kind == "navigate" and shelf.x == -910.0,
  "the shore approach targets the beach-lip beat")
check(shelf.z == -2.5, "the shelf beat is clamped to the draft floor")
check(shelf.water == true, "the shelf beat stays a declared water goal")

-- Schema: the shore bypass flag no longer exists on any wet route.
for _, cfg in ipairs({
  require("config.petrel.traverse_beats"),
  require("config.petrel.traverse_coast_beats"),
  require("config.petrel.traverse_connector_wet_beats"),
}) do
  for _, b in ipairs(cfg.beats) do
    check(b.shore == nil, "no beat carries the removed shore flag: " .. b.id)
  end
end

-- 0062: refill touches sit on the 0x41 shelf WEST and EAST of the
-- aquatic patrol band. The old 026 dip and the 029/030 flags sat inside
-- it and steered every run through the (-5760,-4710) kill pocket.
local routeBeats = require("config.petrel.traverse_beats").beats
local byId = {}
for _, b in ipairs(routeBeats) do byId[b.id] = b end
local band = { x0 = -5790.0, x1 = -5640.0, y0 = -4800.0, y1 = -4700.0 }
local function inBand(b)
  return b.x >= band.x0 and b.x <= band.x1 and b.y >= band.y0 and b.y <= band.y1
end
local r025, r026 = byId.ribbon_025, byId.ribbon_026
local r029, r030, r031 = byId.ribbon_029, byId.ribbon_030, byId.ribbon_031
check(r026 ~= nil and r026.refill == true, "026 stays the west-shelf refill")
check(r026.x < band.x0, "026 refill sits west of the patrol band")
check(not inBand(r026), "026 refill is outside the patrol rectangle")
check(r026.x > r025.x, "026 stays north of 025 (selector window)")
check(math.abs(r026.x - (-5868.0)) < 0.1 and math.abs(r026.y - (-4736.0)) < 0.1,
  "026 is the probed west-shelf pose, not the old headland tip")
check(r031 ~= nil and r031.refill == true, "031 stays the east-shelf refill")
check(r031.x > band.x1, "031 refill sits east of the patrol band")
check(not inBand(r031), "031 refill is outside the patrol rectangle")
check(r029.refill ~= true, "029 is no longer an in-band refill")
check(r030.refill ~= true, "030 is no longer an in-band refill")
local function planar(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return math.sqrt(dx * dx + dy * dy)
end
local function pointSeg(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  if l2 == 0 then return planar(px, py, ax, ay) end
  local t = ((px - ax) * dx + (py - ay) * dy) / l2
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return planar(px, py, ax + t * dx, ay + t * dy)
end
local r027 = byId.ribbon_027
check(pointSeg(-5760.0, -4710.0, r026.x, r026.y, r027.x, r027.y) >= 40.0,
  "026->027 stays >=40 yd off the hosted kill site")

-- Once the shore beat has cleared swimming, Travel Form and the land road
-- take over automatically.
clock = clock + 20.0
local shoreForm = petrel.decide(view(-900.0, -3750.0,
  { shapeshift_form_id = 0, is_swimming = false }))
check(shoreForm.kind == "cast_spell" and shoreForm.spell == 783,
  "dry Barrens shore casts Travel Form")
clock = clock + 20.0
local shoreRoad = petrel.decide(view(-900.0, -3750.0,
  { shapeshift_form_id = 3, is_swimming = false }))
check(shoreRoad.kind == "navigate" and shoreRoad.x == -950.0 and
    shoreRoad.reason == "barrens_lower_road",
  "dry Barrens shore joins the land connector")

print("test_petrel_wet: " .. passed .. " ok")
