-- Wet-chain contract for the Petrel brain. The SWIM gate is read from the
-- process environment at module load, so this file re-runs itself with
-- PETREL_SWIM=1 rather than mutating what a process cannot mutate.
if os.getenv("PETREL_SWIM") ~= "1" then
  local lua = arg and arg[-1] or "lua"
  local ok = os.execute('PETREL_SWIM=1 "' .. lua .. '" "' .. arg[0] .. '"')
  -- Lua 5.1 os.execute returns a number; 5.2+ returns a boolean first.
  if ok == true or ok == 0 then os.exit(0) end
  os.exit(1)
end

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

-- Dry on the sand inside the entry band: the gate is on, so the brain
-- presses toward the first wet beat instead of holding for a swim pass.
local entry = petrel.decide(view(-6790.0, -4840.0, { shapeshift_form_id = 3 }))
check(entry.kind == "navigate", "gate on: no awaiting_swim_pass hold")
check(entry.reason == "enter_water", "dry entry uses the entry reason")
check(entry.x == -6737.63, "dry entry targets the first wet beat")
check(entry.z == -2.5, "shallow wet beats sink to the 2.5 yd draft floor")
check(entry.status and entry.status.dist_goal and entry.status.dist_goal > 0,
  "status carries planar distance to the goal")

-- Wading at the shoreline still drives the same entry.
clock = clock + 5.0
local wade = petrel.decide(view(-6780.0, -4850.0, {
  shapeshift_form_id = 3,
  liquid_known = true, liquid_coverage_known = true,
  liquid_surface_z = 0.0,
}))
check(wade.kind == "navigate" and wade.reason == "enter_water",
  "wading keeps the entry reason")

-- Swimming without Aquatic Form casts it before anything else.
clock = clock + 5.0
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

-- Inside the goal radius, swimming: hold the segment goal.
clock = clock + 5.0
local goal = petrel.decide(view(-4630.0, -4869.0,
  { shapeshift_form_id = 4, is_swimming = true }))
check(goal.kind == "hold" and goal.reason == "duskwallow_coast",
  "holds at the duskwallow goal")
check(goal.status and goal.status.dist_goal < 25.0,
  "the goal hold reports the closing distance")

print("test_traverse_wet: " .. passed .. " ok")
