package.path = "lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;"

local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local clock = 0.0
local navState = "following"
_G.wow = {
  log = function() end,
  set_status = function() end,
  time = function() return clock end,
  nav_progress = function() return { state = navState } end,
}

local grind = require("accelerated")

local function unit(guid, distance, level, extra)
  local u = {
    guid = guid,
    name = "mob" .. guid,
    distance = distance,
    level_known = true,
    level = level,
    player_can_attack = true,
    death_known = true,
    is_dead = false,
    health_known = true,
    health = 40,
    location = { map_id = 1, position = { x = 0, y = 0, z = 50, o = 0 } },
  }
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end

local function view(units, extra)
  local v = {
    location_known = true,
    location = { map_id = 1, position = { x = 0.0, y = 0.0, z = 50.0, o = 0.0 } },
    level = 3,
    class_id = 11,
    units = units,
    auto_attack_guid = 0,
    action_buttons = {
      { slot = 1, spell_id = 5176, usable = true, in_range = true },
    },
  }
  for k, v2 in pairs(extra or {}) do v[k] = v2 end
  return v
end

-- Nearest huntable mob wins.
local near = grind.decide(view({ unit(11, 30.0, 3), unit(22, 8.0, 2) }))
check(near.kind == "attack", "attacks a visible mob")
check(near.guid == 22, "picks the nearest")
check(near.spell == 5176, "druid opens with Wrath")
check(near.status.level == 3, "status carries level")

-- Mobs too far above the player's level are left alone.
local overLevel = grind.decide(view({ unit(33, 5.0, 40) }))
check(overLevel.kind == "navigate", "skips an over-level mob")

-- Dead and unattackable rows are ignored.
local corpses = grind.decide(view({
  unit(44, 5.0, 2, { is_dead = true }),
  unit(55, 6.0, 2, { player_can_attack = false }),
}))
check(corpses.kind == "navigate", "ignores corpses and friendlies")

-- The engaged mob stays the target even when another is closer.
local engaged = grind.decide(view(
  { unit(66, 25.0, 3), unit(77, 2.0, 3) },
  { auto_attack_guid = 66 }
))
check(engaged.guid == 66, "sticks with the engaged mob")

-- No mobs: patrol, and rotate the leg when the route dies.
local firstPatrol = grind.decide(view({}))
check(firstPatrol.kind == "navigate", "patrols with no mobs")
navState = "unavailable"
local rerouted = grind.decide(view({}))
check(rerouted.x ~= firstPatrol.x or rerouted.y ~= firstPatrol.y,
  "unavailable route rotates the patrol")
navState = "following"

-- An unknown class still fights, just without a nuke.
local noSpell = grind.decide(view({ unit(88, 5.0, 2) }, { class_id = 1 }))
check(noSpell.kind == "attack" and noSpell.spell == nil,
  "warrior attacks without a nuke")

-- Death is reported rather than silently ignored.
local dead = grind.decide(view({}, { is_dead = true }))
check(dead.kind == "hold" and dead.reason == "dead", "holds while dead")

print("test_accelerated: " .. passed .. " ok")
