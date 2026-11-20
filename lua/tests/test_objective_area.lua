-- Objective-area travel in the accelerated solo brain. Synthetic positions
-- and quest ids only; the generated table is injected.
package.path = "lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;"

local passed, failed = 0, 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    failed = failed + 1
    return
  end
  passed = passed + 1
end

local clock = 1000.0
_G.wow = {
  log = function() end,
  set_status = function() end,
  time = function() return clock end,
  nav_progress = function() return { state = "following" } end,
}

local solo = require("accelerated")
solo.set_quests(true)
solo.set_quest_hubs({})

local AREAS = {
  [9001] = { level = 4, objectives = {
    { kind = "item", from = { "Field Raider", "Field Raider Captain" },
      spots = { { 1, 200.0, 0.0 }, { 1, 260.0, 0.0 } } },
  } },
  [9003] = { level = 4, objectives = {
    { kind = "item", from = { "Alpha Raider" }, spots = { { 1, 200.0, 0.0 } } },
    { kind = "item", from = { "Beta Raider" }, spots = { { 1, -200.0, 0.0 } } },
  } },
  [9004] = { level = 4, objectives = {
    { kind = "mob", from = {}, spots = { { 1, 300.0, 0.0 } } },
    { kind = "item", from = { "Gamma Raider" }, spots = { { 1, -300.0, 0.0 } } },
  } },
  [9005] = { level = 99, objectives = {
    { kind = "item", from = { "Far Raider" }, spots = { { 1, 0.0, 300.0 } } },
  } },
  [9006] = { level = 4, objectives = {
    { kind = "mob", from = {}, spots = { { 1, 0.0, -250.0 } } },
  } },
  [9002] = { level = 3, objectives = {
    { kind = "object", from = { "Supply Crate" }, spots = { { 1, 150.0, 0.0 } } },
  } },
}

local function unit(guid, distance, level, name)
  return {
    guid = guid, name = name, entry = guid, distance = distance,
    level_known = true, level = level, player_can_attack = true,
    death_known = true, is_dead = false, health_known = true,
    health = 40, max_health = 40, creature_rank_known = true,
    creature_rank = 0, creature_type_known = true, creature_type = 6,
    is_tapped = false, tapped_by_player = false, summoner_guid = 0,
  }
end

-- A real seat displaces between frames (it is following the legs these
-- frames return); a seat pinned at one point for 40+ frames trips the
-- existing still-seat watchdog, which is not what these cases test.
local frameNo = 0
local function view(units, extra)
  frameNo = frameNo + 1
  local v = {
    location_known = true,
    location = { map_id = 1,
      position = { x = 0.0, y = (frameNo % 2) * 2.5, z = 50.0, o = 0.0 } },
    level = 7, xp = 100, class_id = 9, units = units,
    auto_attack_guid = 0, in_combat = false, is_dead = false,
    is_ghost = false, resurrect_offer_guid = 0,
    health_known = true, health = 150, max_health = 150,
    quest_markers = {}, quest_frame = { open = false },
    accepted_quests = { 9001 },
    quest_objectives = {
      { quest_id = 9001, complete = false, entry = 0, item_id = 7001 },
    },
    completed_quest_ids = {}, rewarded_quest_ids = {}, ui_nodes = {},
    action_buttons = {}, inventory_items = {}, bag_space_known = true,
  }
  for k, val in pairs(extra or {}) do v[k] = val end
  return v
end

local function fresh(on)
  solo.reset()
  solo.set_objective_travel(on)
  solo.set_objective_areas(on and AREAS or {})
end

local zombie = unit(11, 6.0, 1, "Field Zombie")

-- Counterexample: a gray pull in the starter field while a drop quest waits
-- 200 yards away.
fresh(false)
clock = clock + 10
local old = solo.decide(view({ zombie }))
check(old.kind == "attack" and old.guid == 11, "default off: gray pull kept")

fresh(true)
clock = clock + 10
local step = solo.decide(view({ zombie }))
check(step.kind == "navigate" and step.reason == "objective_area" and
  step.x == 200.0 and step.y == 0.0, "gray pull yields to the drop area")

-- Our own out-of-combat auto-attack on that gray mob is the same loop.
clock = clock + 1
step = solo.decide(view({ zombie }, { auto_attack_guid = 11 }))
check(step.reason == "objective_area", "own gray auto-attack yields too")

-- Defense: anything hitting us is fought.
clock = clock + 1
step = solo.decide(view({ zombie }, { auto_attack_guid = 11, in_combat = true }))
check(step.kind == "attack" and step.guid == 11, "in combat: keep fighting")

-- A pull that still pays XP is ordinary grinding.
clock = clock + 1
step = solo.decide(view({ unit(12, 20.0, 5, "Field Wolf") }))
check(step.kind == "attack" and step.guid == 12, "non-gray pull kept")

-- A named dropper beats a closer gray mob, at objective reach.
clock = clock + 1
step = solo.decide(view({ zombie, unit(13, 90.0, 5, "Field Raider") }))
check(step.kind == "attack" and step.guid == 13, "generated dropper outranks gray")

-- Gathered objects are not faked as field work.
fresh(true)
clock = clock + 1
step = solo.decide(view({ zombie }, {
  accepted_quests = { 9002 },
  quest_objectives = {
    { quest_id = 9002, complete = false, entry = 0, item_id = 7002 },
  },
}))
check(step.kind == "attack" and step.guid == 11, "object row: no travel")

-- Unpaired rows (count mismatch) stay unknown.
clock = clock + 1
step = solo.decide(view({ zombie }, {
  quest_objectives = {
    { quest_id = 9001, complete = false, entry = 0, item_id = 7001 },
    { quest_id = 9001, complete = false, entry = 0, item_id = 7003 },
  },
}))
check(step.kind == "attack", "unpaired rows: no travel")

-- Above the level margin: not this seat's field yet.
clock = clock + 1
step = solo.decide(view({ zombie }, { level = 1 }))
check(step.kind ~= "navigate" or step.reason ~= "objective_area",
  "quest above level margin: no travel")

-- Arrival sweeps on to the next spot.
fresh(true)
clock = clock + 1
step = solo.decide(view({}, {
  location = { map_id = 1, position = { x = 190.0, y = 0.0, z = 50.0, o = 0 } },
}))
check(step.reason == "objective_area" and step.x == 260.0, "arrived: next spot")

-- Patience counts real progress only. XP resets it; time alone retires the
-- objective and the old behavior returns.
fresh(true)
local t0 = clock + 1
clock = t0
check(solo.decide(view({ zombie })).reason == "objective_area", "patience: start")
clock = t0 + 120
check(solo.decide(view({ zombie }, { xp = 140 })).reason == "objective_area",
  "patience: xp gain keeps the area")
clock = t0 + 290
check(solo.decide(view({ zombie }, { xp = 140 })).reason == "objective_area",
  "patience: reset by xp, not expired")
clock = t0 + 310
check(solo.decide(view({ zombie }, { xp = 140 })).kind == "attack",
  "patience: no credit retires the area")

-- Moving and status changes are not progress.
fresh(true)
t0 = clock + 1
clock = t0
solo.decide(view({ zombie }))
clock = t0 + 100
solo.decide(view({ zombie }, {
  location = { map_id = 1, position = { x = 60.0, y = 5.0, z = 50.0, o = 0 } },
}))
clock = t0 + 190
check(solo.decide(view({ zombie })).kind == "attack",
  "patience: movement does not reset")

-- Carried quest items are credit.
fresh(true)
t0 = clock + 1
clock = t0
solo.decide(view({ zombie }))
clock = t0 + 170
solo.decide(view({ zombie }, { inventory_items = { { item_id = 7001, count = 1 } } }))
clock = t0 + 300
check(solo.decide(view({ zombie }, {
  inventory_items = { { item_id = 7001, count = 1 } },
})).reason == "objective_area", "patience: a drop resets it")

-- Live rows arrive out of definition order (credit before definition).
-- Two item rows of one quest, reversed: which is which is unknown, so no
-- guide area is claimed and no guide dropper is preferred.
fresh(true)
clock = clock + 1
local reversed = {
  accepted_quests = { 9003 },
  quest_objectives = {
    { quest_id = 9003, complete = false, entry = 0, item_id = 7012 },
    { quest_id = 9003, complete = true, entry = 0, item_id = 7011 },
  },
}
step = solo.decide(view({ zombie }, reversed))
check(step.reason ~= "objective_area", "reversed same-kind rows: no guessed area")
clock = clock + 1
step = solo.decide(view({ zombie, unit(14, 90.0, 5, "Alpha Raider") }, reversed))
check(step.kind == "attack" and step.guid == 11,
  "reversed same-kind rows: finished row's dropper not preferred")

-- A kill row and an item row, reversed: each is the sole row of its class,
-- so the item row still finds its own droppers' area.
fresh(true)
clock = clock + 1
step = solo.decide(view({ zombie }, {
  accepted_quests = { 9004 },
  quest_objectives = {
    { quest_id = 9004, complete = false, entry = 0, item_id = 7021 },
    { quest_id = 9004, complete = true, entry = 5000, item_id = 0 },
  },
}))
check(step.reason == "objective_area" and step.x == -300.0,
  "reversed kill/item rows: item row walks to its own area")

-- A retired objective stays retired when an earlier quest leaves the log.
fresh(true)
t0 = clock + 1
clock = t0
local both = {
  accepted_quests = { 9005, 9001 },
  quest_objectives = {
    { quest_id = 9005, complete = false, entry = 0, item_id = 7005 },
    { quest_id = 9001, complete = false, entry = 0, item_id = 7001 },
  },
}
check(solo.decide(view({ zombie }, both)).reason == "objective_area", "shift: start")
clock = t0 + 190
check(solo.decide(view({ zombie }, both)).kind == "attack", "shift: retired")
clock = t0 + 200
check(solo.decide(view({ zombie })).kind == "attack",
  "shift: earlier quest removed, retirement kept")

-- Two fruitless retirements drop the objective; unrelated XP does not
-- bring it back, its own credit does.
fresh(true)
t0 = clock + 1
clock = t0
solo.decide(view({ zombie }))
clock = t0 + 190
check(solo.decide(view({ zombie })).kind == "attack", "strikes: first retirement")
clock = t0 + 800
check(solo.decide(view({ zombie })).reason == "objective_area",
  "strikes: one retirement is a cooldown")
clock = t0 + 990
check(solo.decide(view({ zombie })).kind == "attack", "strikes: second retirement")
clock = t0 + 3000
check(solo.decide(view({ zombie })).kind == "attack",
  "strikes: second retirement holds past the cooldown")
clock = t0 + 3010
check(solo.decide(view({ zombie }, { xp = 400 })).kind == "attack",
  "strikes: unrelated XP does not rearm")
clock = t0 + 3020
check(solo.decide(view({ zombie }, {
  xp = 400, inventory_items = { { item_id = 7001, count = 1 } },
})).reason == "objective_area", "strikes: own credit rearms")

-- Missing data is not credit. Retire twice, then frames where the quest is
-- still accepted but its row is unpaired, or bags are unknown: the
-- retirement holds. Only a known quest removal or a known change of the
-- objective's own credit rearms it.
local function retire_twice(extra)
  fresh(true)
  local t = clock + 1
  clock = t
  solo.decide(view({ zombie }, extra))
  clock = t + 190
  solo.decide(view({ zombie }, extra))
  clock = t + 800
  solo.decide(view({ zombie }, extra))
  clock = t + 990
  return solo.decide(view({ zombie }, extra))
end
check(retire_twice().kind == "attack", "unknown: retired twice")
clock = clock + 10
solo.decide(view({ zombie }, { quest_objectives = {} }))
clock = clock + 10
check(solo.decide(view({ zombie })).kind == "attack",
  "unknown: row missing then back, retirement holds")
clock = clock + 10
solo.decide(view({ zombie }, {
  accepted_quests = { { quest_id = 9001 } }, quest_objectives = {},
}))
clock = clock + 10
check(solo.decide(view({ zombie })).kind == "attack",
  "unknown: table accept list, row missing, retirement holds")
clock = clock + 10
solo.decide(view({ zombie }, {
  inventory_items = {}, bag_space_known = false,
  quest_objectives = {
    { quest_id = 9001, complete = false, entry = 0, item_id = 7001, current = 1 },
  },
}))
clock = clock + 10
check(solo.decide(view({ zombie })).reason ~= "objective_area",
  "unknown: bags unknown then known, no fake credit")
clock = clock + 10
solo.decide(view({}, { accepted_quests = {}, quest_objectives = {} }))
clock = clock + 10
check(solo.decide(view({ zombie })).reason == "objective_area",
  "known quest removal rearms")

-- Retired while bags were unknown: the first known count is adopted, not
-- treated as a change; a later real change rearms.
check(retire_twice({ inventory_items = {}, bag_space_known = false }).kind == "attack",
  "adopt: retired with unknown credit")
clock = clock + 10
check(solo.decide(view({ zombie })).kind == "attack",
  "adopt: first known count does not rearm")
clock = clock + 10
check(solo.decide(view({ zombie }, {
  inventory_items = { { item_id = 7001, count = 1 } },
})).reason == "objective_area", "adopt: later own credit rearms")

-- Real SDK shape: inventory_items remains a table while bag_space_known is
-- false. Losing the known nonzero count is not a new objective credit.
local one_item = { inventory_items = { { item_id = 7001, count = 1 } } }
check(retire_twice(one_item).kind == "attack", "partial bags: retired at one item")
clock = clock + 10
solo.decide(view({ zombie }, { inventory_items = {}, bag_space_known = false }))
clock = clock + 10
check(solo.decide(view({ zombie }, one_item)).kind == "attack",
  "partial bags: empty unknown table then known count keeps retirement")

-- Patience timer: a known count of one, an unknown empty bag frame near the
-- deadline, then the same known count. Nothing moved, so the area retires.
fresh(true)
t0 = clock + 1
clock = t0
check(solo.decide(view({ zombie }, one_item)).reason == "objective_area",
  "timer: known one starts the area")
clock = t0 + 170
check(solo.decide(view({ zombie }, { inventory_items = {}, bag_space_known = false }))
  .reason == "objective_area", "timer: unknown bags at 170s")
clock = t0 + 175
check(solo.decide(view({ zombie }, one_item)).reason == "objective_area",
  "timer: same known one at 175s")
clock = t0 + 185
check(solo.decide(view({ zombie }, one_item)).kind == "attack",
  "timer: unknown bag flicker is not progress, retires past 180s")

-- Reconnect can leave an accepted quest without requirement rows temporarily.
-- Restoring those rows with unchanged credit is observation recovery.
fresh(true)
t0 = clock + 1
clock = t0
solo.decide(view({ zombie }, one_item))
clock = t0 + 170
solo.decide(view({ zombie }, { quest_objectives = {},
  inventory_items = one_item.inventory_items }))
clock = t0 + 175
solo.decide(view({ zombie }, one_item))
clock = t0 + 185
check(solo.decide(view({ zombie }, one_item)).kind == "attack",
  "timer: missing requirement row is not progress")

-- Kill credit with no XP (a gray target) is the objective's own progress.
local kill_row = function(current) return {
  accepted_quests = { 9006 },
  quest_objectives = {
    { quest_id = 9006, complete = false, entry = 5000, item_id = 0,
      current = current },
  },
} end
fresh(true)
t0 = clock + 1
clock = t0
check(solo.decide(view({ zombie }, kill_row(0))).reason == "objective_area",
  "kill credit: start")
clock = t0 + 170
solo.decide(view({ zombie }, kill_row(1)))
clock = t0 + 175
solo.decide(view({ zombie }, kill_row(nil)))
clock = t0 + 185
check(solo.decide(view({ zombie }, kill_row(1))).reason == "objective_area",
  "kill credit at 170s keeps the area; unknown current is not progress")
clock = t0 + 355
check(solo.decide(view({ zombie }, kill_row(1))).kind == "attack",
  "kill credit: unknown current did not reset patience")

-- A quest the log marks failed is not field work; an unknown flag is kept.
fresh(true)
clock = clock + 1
check(solo.decide(view({ zombie }, {
  accepted_quests = { { quest_id = 9001, failed = true } },
})).kind == "attack", "failed quest: no travel")
clock = clock + 1
check(solo.decide(view({ zombie }, {
  accepted_quests = { { quest_id = 9001, failed = false } },
})).reason == "objective_area", "live quest: travel")

print("test_objective_area: " .. passed .. " passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
