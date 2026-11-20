-- Identity-aware objective pairing in the accelerated solo brain (0157).
-- The guide is tools/tests/fixtures/objective_ids/expected_areas.lua: the
-- golden that tools/tests/test_gen_objective_areas.nim requires the generator
-- to reproduce byte for byte from SYNTHETIC fixtures. No real quest data.
-- Run from the repo root (as `make test-lua` does).
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
local AREAS = assert(dofile("tools/tests/fixtures/objective_ids/expected_areas.lua"))
check(AREAS[9101].objectives[1].item_id == 7101 and
  AREAS[9101].objectives[2].item_id == 7102, "fixture: producer ids present")
check(AREAS[9104].objectives[1].item_id == nil, "fixture: refused quest untyped")

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

local frameNo = 0
local function view(units, quest, rows)
  frameNo = frameNo + 1
  return {
    location_known = true,
    location = { map_id = 1,
      position = { x = 0.0, y = (frameNo % 2) * 2.5, z = 50.0, o = 0.0 } },
    level = 7, xp = 100, class_id = 9, units = units,
    auto_attack_guid = 0, in_combat = false, is_dead = false,
    is_ghost = false, resurrect_offer_guid = 0,
    health_known = true, health = 150, max_health = 150,
    quest_markers = {}, quest_frame = { open = false },
    accepted_quests = { quest }, quest_objectives = rows,
    completed_quest_ids = {}, rewarded_quest_ids = {}, ui_nodes = {},
    action_buttons = {}, inventory_items = {}, bag_space_known = true,
  }
end

local function item(q, id, done)
  return { quest_id = q, complete = done, entry = 0, item_id = id, current = 0 }
end
local function kill(q, entry, done)
  return { quest_id = q, complete = done, entry = entry, item_id = 0, current = 0 }
end

local function fresh(on, areas)
  solo.reset()
  solo.set_objective_travel(on)
  solo.set_objective_areas(areas or AREAS)
end

local zombie = unit(11, 6.0, 1, "Field Zombie")
local function decide(quest, rows, units)
  clock = clock + 1
  return solo.decide(view(units or { zombie }, quest, rows))
end
local function walks_to(step, x, y)
  return step.kind == "navigate" and step.reason == "objective_area" and
    step.x == x and step.y == y
end

-- Two live item rows of one quest, reversed against definition order: each
-- pairs by its own id. The nearer spot belongs to the finished row.
fresh(true)
check(walks_to(decide(9101, { item(9101, 7102, false), item(9101, 7101, true) }),
  -150.0, 0.0), "reversed rows: open second objective walks to its own area")
fresh(true)
check(walks_to(decide(9101, { item(9101, 7102, true), item(9101, 7101, false) }),
  300.0, 0.0), "reversed rows: open first objective skips the nearer finished area")
fresh(true)
check(walks_to(decide(9101, { item(9101, 7101, false), item(9101, 7102, true) }),
  300.0, 0.0), "definition order gives the same answer")

-- Droppers follow the identity too: the finished objective's dropper is not
-- credit, the open one's is.
fresh(true)
check(walks_to(decide(9101, { item(9101, 7102, false), item(9101, 7101, true) },
  { zombie, unit(14, 90.0, 5, "Alpha Raider") }), -150.0, 0.0),
  "finished objective's dropper not preferred over its own walk")
fresh(true)
local step = decide(9101, { item(9101, 7102, false), item(9101, 7101, true) },
  { zombie, unit(15, 90.0, 5, "Beta Raider") })
check(step.kind == "attack" and step.guid == 15, "open objective's dropper preferred")

-- Completed rows never route.
fresh(true)
check(decide(9101, { item(9101, 7102, true), item(9101, 7101, true) }).reason ~=
  "objective_area", "all rows complete: no travel")

-- A live id the guide does not carry, and duplicated live ids, are unknown.
fresh(true)
check(decide(9101, { item(9101, 7999, false), item(9101, 7101, true) }).reason ~=
  "objective_area", "unknown live item id: no travel")
fresh(true)
check(decide(9101, { item(9101, 7101, false), item(9101, 7101, false),
  item(9101, 7102, true) }).reason ~= "objective_area",
  "duplicated live id: no travel")

-- Producer refused ids (repeated definition id): legacy class rule, which
-- refuses two same-class rows.
fresh(true)
check(decide(9104, { item(9104, 7141, false), item(9104, 7142, true) }).reason ~=
  "objective_area", "refused quest keeps conservative class rule")

-- Mixed kill / game object / item quest. Legacy pairing refuses the item row
-- (object and item guides are one class); typed ids pair it, the kill row
-- pairs by creature entry, and game-object credit stays unsupported.
local GO = 2147483648 + 5191
fresh(true)
check(walks_to(decide(9109, { item(9109, 7191, false), kill(9109, GO, true),
  kill(9109, 5190, true) }), 300.0, 0.0), "mixed: item row pairs by id")
fresh(true)
check(walks_to(decide(9109, { kill(9109, GO, true), item(9109, 7191, true),
  kill(9109, 5190, false) }), 0.0, 500.0), "mixed: kill row pairs by entry")
fresh(true)
check(decide(9109, { kill(9109, GO, false), item(9109, 7191, true),
  kill(9109, 5190, true) }).reason ~= "objective_area",
  "mixed: game-object row stays unsupported")
fresh(true)
check(decide(9109, { item(9109, 7191, true), kill(9109, 5999, false),
  kill(9109, 5190, true) }).reason ~= "objective_area",
  "mixed: unknown creature entry does not borrow the kill area")

-- Opt-in stays off by default.
fresh(false)
check(decide(9101, { item(9101, 7102, false), item(9101, 7101, true) }).reason ~=
  "objective_area", "objective travel off: unchanged")

-- Hand-built guides the generator never writes: partial, malformed or
-- repeated ids pair nothing.
local function guide(objs) return { [9201] = { level = 4, objectives = objs } } end
local A = { 1, 300.0, 0.0 }
local B = { 1, -150.0, 0.0 }
local bad = {
  ["partial ids"] = guide({
    { kind = "item", item_id = 7101, from = { "Alpha Raider" }, spots = { A } },
    { kind = "item", from = { "Beta Raider" }, spots = { B } } }),
  ["string id"] = guide({
    { kind = "item", item_id = "7101", from = { "Alpha Raider" }, spots = { A } } }),
  ["fractional id"] = guide({
    { kind = "item", item_id = 7101.5, from = { "Alpha Raider" }, spots = { A } } }),
  ["id field disagrees with kind"] = guide({
    { kind = "mob", item_id = 7101, from = {}, spots = { A } } }),
  ["two id fields"] = guide({
    { kind = "item", item_id = 7101, entry = 5190, from = { "Alpha Raider" },
      spots = { A } } }),
  ["repeated guide id"] = guide({
    { kind = "item", item_id = 7101, from = { "Alpha Raider" }, spots = { A } },
    { kind = "item", item_id = 7101, from = { "Beta Raider" }, spots = { B } } }),
}
for name, areas in pairs(bad) do
  fresh(true, areas)
  check(decide(9201, { item(9201, 7101, false) }).reason ~= "objective_area",
    name .. ": no travel")
end
-- Control for the hand-built shape: a well-formed single typed objective
-- does route, so the refusals above are the ids, not the fixture.
fresh(true, guide({
  { kind = "item", item_id = 7101, from = { "Alpha Raider" }, spots = { A } } }))
check(walks_to(decide(9201, { item(9201, 7101, false) }), 300.0, 0.0),
  "well-formed typed guide routes")

print("test_objective_identity: " .. passed .. " passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
