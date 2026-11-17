-- Wet-chain contract for the Petrel brain (the wet chain is unconditional).

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

-- Recorded route data is local-only. The brain runs on it when this checkout
-- has it, else on a synthetic route with the same shape
-- (lua/tests/fixtures/traverse_route.lua).
print("test_traverse_wet: route = "
  .. require("tests.fixtures.traverse_route").select())

local petrel = require("traverse")

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

-- The bay interior (2026-08-12): capturing bay_center hooks the swimmer
-- WEST toward the sandbar saddle — the beach goal detour, far outside the
-- old 40-yd south-lag band.
clock = clock + 5.0
local bay = petrel.decide(view(-1533.0, -4088.0,
  { shapeshift_form_id = 4, is_swimming = true }))
check(bay.kind == "navigate" and bay.reason == "swim_ribbon" and
    bay.x == -1652.0,
  "bay_center hooks west toward the sandbar saddle")

-- The merchant WATER goal (monofuel's scouted inner-bay pose) captures
-- swimming — 6.6+ yd of water across the ring, no grounding — and hands
-- off into the departure line at inlet_out.
clock = clock + 5.0
local goal = petrel.decide(view(-1816.8, -3899.5,
  { shapeshift_form_id = 4, is_swimming = true }))
check(goal.kind == "navigate" and goal.reason == "swim_ribbon" and
    goal.x == -1805.0,
  "merchant water goal hands off into the departure line")
check(goal.status and goal.status.dist_goal < 25.0,
  "the goal handoff retains merchant closing distance")

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
  require("config.traverse_beats"),
  require("config.traverse_coast_beats"),
  require("config.traverse_connector_wet_beats"),
}) do
  for _, b in ipairs(cfg.beats) do
    check(b.shore == nil, "no beat carries the removed shore flag: " .. b.id)
  end
end

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

print("test_traverse_wet: " .. passed .. " ok")
