-- Objective payout under an owner's objective-first request.
-- The guide is tools/tests/fixtures/dropper_ids/expected_areas.lua: the
-- golden tools/tests/test_gen_objective_areas.nim requires gen_objective_areas
-- to reproduce byte for byte (typed ids plus --dropper-ids relations) from
-- SYNTHETIC fixtures. No real quest data. Run from the repo root.
--
-- Quest 9301: kill rows North Raider (5301, finished) and South Raider (5302,
-- unfinished, spots 300yd away) and item 7301, a typed corpse drop of 5301,
-- 5302 and 5303. Local North kills pay only the drop chance; a South kill
-- pays certain kill credit plus the same chance. Quest 9302: item 7302,
-- dropped by 5301 only. Quest 9303: refused typed ids (untyped guide).
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

local clock = 5000.0
_G.wow = {
  log = function() end,
  set_status = function() end,
  time = function() return clock end,
  nav_progress = function() return { state = "following" } end,
}

local GOLDEN = "tools/tests/fixtures/dropper_ids/expected_areas.lua"
local function guide() return assert(dofile(GOLDEN)) end
local AREAS = guide()
check(AREAS[9301].objectives[2].entry == 5302 and
  AREAS[9301].objectives[3].from_entries[2] == 5302,
  "fixture: producer typed ids and droppers present")
check(AREAS[9303].objectives[2].from_entries == nil,
  "fixture: refused quest carries no droppers")

-- A fresh VM: no state survives from an earlier scenario, as after a reload.
local solo
local function fresh(areas)
  package.loaded.accelerated = nil
  solo = require("accelerated")
  solo.set_quests(true)
  solo.set_quest_hubs({})
  solo.set_objective_travel(true)
  solo.set_objective_areas(areas or guide())
end

local PLAYER = 777
local function unit(guid, entry, distance, name, extra)
  local u = {
    guid = guid, name = name, entry = entry, distance = distance,
    level_known = true, level = 6, player_can_attack = true,
    death_known = true, is_dead = false, health_known = true,
    health = 40, max_health = 40, creature_rank_known = true,
    creature_rank = 0, creature_type_known = true, creature_type = 7,
    is_tapped = false, tapped_by_player = false, summoner_guid = 0,
  }
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end
local function north(d, extra) return unit(21, 5301, d or 10.0, "North Raider", extra) end
local function south(d, extra) return unit(22, 5302, d or 60.0, "South Raider", extra) end
local function west(d, extra) return unit(23, 5303, d or 10.0, "West Raider", extra) end

local function rows(opts)
  opts = opts or {}
  local r = {
    { quest_id = 9301, entry = 5301, item_id = 0, current = 8, required = 8,
      complete = true },
    { quest_id = 9301, entry = 5302, item_id = 0, current = opts.south or 0,
      required = 5, complete = (opts.south or 0) >= 5, failed = opts.southFailed },
    { quest_id = 9301, entry = 0, item_id = 7301, current = 3, required = 8,
      complete = false },
  }
  for _, extra in ipairs(opts.extra or {}) do r[#r + 1] = extra end
  return r
end

local frameNo = 0
local function view(units, extra)
  frameNo = frameNo + 1
  local v = {
    location_known = true,
    location = { map_id = 1,
      position = { x = 0.0, y = (frameNo % 2) * 2.5, z = 50.0, o = 0.0 } },
    level = 7, xp = 100, class_id = 9, units = units, player_guid = PLAYER,
    auto_attack_guid = 0, in_combat = false, is_dead = false,
    is_ghost = false, resurrect_offer_guid = 0,
    health_known = true, health = 150, max_health = 150,
    quest_markers = {}, quest_frame = { open = false },
    accepted_quests = { 9301 },
    quest_objectives = rows(),
    completed_quest_ids = {}, rewarded_quest_ids = {}, ui_nodes = {},
    action_buttons = {}, bag_space_known = true,
    inventory_items = { { item_id = 7301, count = 3 } },
  }
  for k, val in pairs(extra or {}) do v[k] = val end
  return v
end

local REQUEST = { objective_first = true }
local function decide(units, extra, policy)
  clock = clock + 1
  return solo.decide(view(units, extra), policy)
end
local function attacks(step, guid)
  return step.kind == "attack" and step.guid == guid
end
local function walks_south(step)
  return step.kind == "navigate" and step.reason == "objective_area" and
    step.x == 0.0 and step.y == 300.0
end

-- B: out-of-view kill area from typed droppers, after a fresh VM with no
-- South Raider ever in view.
fresh()
check(walks_south(decide({ north() }, nil, REQUEST)),
  "fresh VM, South never seen: drop-only North yields to the typed kill area")
check(walks_south(decide({ west() }, nil, REQUEST)),
  "pure dropper West (no kill row) yields the same way")
fresh()
check(attacks(decide({ north() }), 21), "control: no policy, North pulled")
fresh()
check(attacks(decide({ north() }, nil, { objective_first = false }), 21),
  "control: policy without objective_first, North pulled")
fresh()
check(solo.credits_objective(view({ north() }), north()) == true,
  "credit predicate still counts North as paying")

-- Fail closed on missing or malformed typed data.
local function without(mutate)
  local g = guide()
  mutate(g)
  fresh(g)
  return decide({ north() }, nil, REQUEST)
end
check(attacks(without(function(g) g[9301].objectives[3].from_entries = nil end), 21),
  "no from_entries (legacy guide): North pulled")
check(attacks(without(function(g) g[9301].objectives[3].from_entries = { 5301, 5303 } end), 21),
  "relations without the kill creature: North pulled")
check(attacks(without(function(g) g[9301].objectives[3].from_entries = { "5302" } end), 21),
  "string entry: North pulled")
check(attacks(without(function(g) g[9301].objectives[3].from_entries = { 5302, 0 } end), 21),
  "non-positive entry poisons the list: North pulled")
check(attacks(without(function(g) g[9301].objectives[3].from_entries = { 5302.5 } end), 21),
  "fractional entry: North pulled")
check(attacks(without(function(g) g[9301].objectives[3].from_entries = { x = 5302 } end), 21),
  "non-sequence list: North pulled")
check(attacks(without(function(g) g[9301].objectives[3].from_entries = "5302" end), 21),
  "non-table list: North pulled")
check(attacks(without(function(g) g[9301].objectives[3].item_id = nil end), 21),
  "partly typed quest pairs nothing: North pulled")
check(attacks(without(function(g) g[9301].objectives[2].entry = 5399 end), 21),
  "kill guide id disagreeing with the live row: North pulled")
check(attacks(without(function(g) g[9301].objectives[2].kind = "item" end), 21),
  "malformed kill guide kind: North pulled")

-- Relations on an untyped guide (class-paired, no item_id) prove nothing.
do
  local g = guide()
  g[9303].objectives[2].from_entries = { 5302, 5311 }
  fresh(g)
  local east = unit(24, 5311, 10.0, "East Raider")
  local fang = { accepted_quests = { 9301, 9303 }, quest_objectives = rows({ extra = {
    { quest_id = 9303, entry = 5311, item_id = 0, current = 7, required = 7,
      complete = true },
    { quest_id = 9303, entry = 0, item_id = 7303, current = 0, required = 2,
      complete = false } } }) }
  check(solo.credits_objective(view({ east }, fang), east) == true and
    attacks(decide({ east }, fang, REQUEST), 24),
    "untyped item guide with from_entries: East pulled, no walk")
end

-- Existing area filters still apply to the limited walk.
check(attacks(without(function(g) g[9301].level = 20 end), 21),
  "quest level above the margin: North pulled")
check(attacks(without(function(g) g[9301].objectives[2].spots = { { 1, 0.0, 700.0 } } end), 21),
  "kill spot beyond 600yd: North pulled")
fresh()
check(attacks(decide({ north() }, { location = { map_id = 0,
    position = { x = 0.0, y = 0.0, z = 50.0, o = 0.0 } } }, REQUEST), 21),
  "kill spot on another map: North pulled")
fresh()
check(attacks(decide({ north() }, { quest_objectives = rows({ south = 5 }) }, REQUEST), 21),
  "kill row finished: North pulled")
fresh()
check(attacks(decide({ north() }, { quest_objectives = rows({ southFailed = true }) }, REQUEST), 21),
  "kill row failed: North pulled")
fresh()
check(attacks(decide({ north() }, { accepted_quests = { { quest_id = 9301, failed = true } } },
    REQUEST), 21), "quest failed: North pulled")

-- Every row the pull pays must be covered.
local POUCH = { quest_id = 9302, entry = 0, item_id = 7302, current = 1,
  required = 4, complete = false }
fresh()
check(attacks(decide({ north() }, { accepted_quests = { 9301, 9302 },
    quest_objectives = rows({ extra = { POUCH } }) }, REQUEST), 21),
  "North also pays a pure item row South does not drop: North pulled")
fresh()
check(walks_south(decide({ west() }, { accepted_quests = { 9301, 9302 },
    quest_objectives = rows({ extra = { POUCH } }) }, REQUEST)),
  "control: West pays only the covered row and still yields")

-- Threat, combat and engagement are never traded for the walk.
fresh()
check(attacks(decide({ north(), west(30.0, { target_guid_known = true,
    target_guid = PLAYER }) }, nil, REQUEST), 21),
  "targeted by a hostile: nearest payer pulled, no tour")
fresh()
check(decide({ north() }, { in_combat = true }, REQUEST).kind == "attack",
  "in combat: no tour")
fresh()
check(attacks(decide({ north() }, { auto_attack_guid = 21 }, REQUEST), 21),
  "engaged North kept")

-- A: in-view ranking by live rows paid.
fresh()
check(attacks(decide({ north(), south() }, nil, REQUEST), 22),
  "in view: South (kill + drop) outranks nearer drop-only North")
fresh()
check(attacks(decide({ north(), south() }), 21),
  "control: no policy, nearest payer North")
fresh()
check(attacks(decide({ north(), south(), west(30.0, { target_guid_known = true,
    target_guid = PLAYER }) }, nil, REQUEST), 21),
  "under threat: nearest payer North, no farther pull")
fresh()
check(attacks(decide({ north(), south() }, { accepted_quests = { 9301,
    { quest_id = 9303, failed = true } },
    quest_objectives = rows({ south = 5, extra = { { quest_id = 9303,
      entry = 5302, item_id = 0, current = 0, required = 7, complete = false } } }) },
    REQUEST), 21),
  "a failed quest's kill row does not boost far South over nearer North")
fresh()
check(attacks(decide({ north(), south() }, { quest_objectives = rows({ southFailed = true }) },
    REQUEST), 21),
  "a failed kill row does not boost far South over nearer North")
fresh()
check(solo.credits_objective(view({}, { accepted_quests = { { quest_id = 9301, failed = true } } }),
    south()) == true,
  "legacy credit predicate unchanged: failed-quest rows still count")

-- Caster without a policy keeps its old pull.
fresh()
local mage = decide({ north(), south() }, { class_id = 8, mana = 100, max_mana = 100,
  mana_known = true })
check(attacks(mage, 21) and mage.stop_distance == 22.0,
  "mage without policy: nearest payer North at caster range")

-- Area patience: any XP counts as progress, so XP from fights on the way
-- keeps a dominated walk alive past 180s; without XP it retires.
fresh()
check(walks_south(decide({ north() }, nil, REQUEST)), "patience: walk starts")
clock = clock + 170
check(walks_south(decide({ north() }, nil, REQUEST)), "patience: still walking at 170s")
clock = clock + 15
check(attacks(decide({ north() }, nil, REQUEST), 21),
  "patience: no XP or credit for 180s retires the area; North pulled")
fresh()
check(walks_south(decide({ north() }, nil, REQUEST)), "patience+XP: walk starts")
clock = clock + 170
check(walks_south(decide({ north() }, { xp = 140 }, REQUEST)), "patience+XP: XP at 170s")
clock = clock + 170
check(walks_south(decide({ north() }, { xp = 140 }, REQUEST)),
  "patience+XP: XP reset the clock, still walking at 340s (documented tradeoff)")

-- Walk continuation. A synthetic item 7301 spot 120yd north is nearer than
-- half the 300yd to the South kill spot, so an unrestricted area step on a
-- frame without the dominated North in view would turn back to it.
local function churn(mutate)
  local g = guide()
  local spots = g[9301].objectives[3].spots
  spots[#spots + 1] = { 1, 0.0, -120.0 }
  if mutate then mutate(g) end
  fresh(g)
end
local function walks_north(step)
  return step.kind == "navigate" and step.reason == "objective_area" and
    step.x == 0.0 and step.y == -120.0
end
local function boar() return unit(25, 5399, 10.0, "Gray Boar") end

churn()
check(walks_south(decide({ north() }, nil, REQUEST)), "churn: paying North frame walks south")
check(walks_south(decide({}, nil, REQUEST)), "churn: empty frame still walks south")
check(walks_south(decide({ boar() }, nil, REQUEST)), "churn: filler frame still walks south")
churn()
check(walks_north(decide({}, nil, REQUEST)),
  "control: no remembered walk, the empty frame takes the nearer item spot")

-- Same with South seen before the walk: it is attacked while in view, then
-- the walk starts once only North is left.
churn()
check(attacks(decide({ north(), south() }, nil, REQUEST), 22), "seen South: attacked in view")
check(walks_south(decide({ north() }, nil, REQUEST)), "seen South gone: North frame walks south")
check(walks_south(decide({}, nil, REQUEST)), "seen South gone: empty frame still south")
check(walks_south(decide({ boar() }, nil, REQUEST)), "seen South gone: filler frame still south")

-- 20Hz alternation of paying, empty and filler frames keeps one key, so it
-- is no progress: without XP or credit the walk still retires after 180s.
churn()
do
  local t0, frames, south = clock, 0, true
  local kinds = { function() return { north() } end, function() return {} end,
    function() return { boar() } end }
  while clock - t0 < 179.9 do
    local step = solo.decide(view(kinds[frames % 3 + 1]()), REQUEST)
    south = south and walks_south(step)
    frames = frames + 1
    clock = clock + 0.05
  end
  check(south and frames > 3000, "20Hz alternation: every frame walks south")
  clock = t0 + 181
  check(attacks(solo.decide(view({ north() }), REQUEST), 21),
    "20Hz alternation: no XP or credit, the walk retires after 180s; North pulled")
end

-- The South kill arriving keeps the walk: one kill of five does not end it.
churn()
check(walks_south(decide({ north() }, nil, REQUEST)), "arrival: walk starts")
check(attacks(decide({ south() }, nil, REQUEST), 22), "arrival: South in view attacked")
check(walks_south(decide({}, { quest_objectives = rows({ south = 1 }) }, REQUEST)),
  "arrival: after one kill of five the empty frame still walks south")

-- Threat and combat interrupt the walk without ending it.
churn()
check(walks_south(decide({ north() }, nil, REQUEST)), "threat: walk starts")
check(attacks(decide({ north(), west(30.0, { target_guid_known = true,
    target_guid = PLAYER }) }, nil, REQUEST), 21), "threat: nearest payer defended")
check(decide({ north() }, { in_combat = true }, REQUEST).kind == "attack",
  "threat: in combat, attack")
check(walks_south(decide({}, nil, REQUEST)), "threat: afterwards the walk resumes")

-- A fresh payer of an uncovered pure item row is pulled, and the walk ends:
-- its area is no longer suppressed.
churn(function(g) g[9302].objectives[1].spots = { { 1, -100.0, 0.0 } } end)
do
  local pouch = { accepted_quests = { 9301, 9302 },
    quest_objectives = rows({ extra = { POUCH } }) }
  check(walks_south(decide({ west() }, pouch, REQUEST)), "uncovered: West walks south")
  check(walks_south(decide({}, pouch, REQUEST)), "uncovered: empty frame still south")
  check(attacks(decide({ north() }, pouch, REQUEST), 21),
    "uncovered: North paying the pouch row is pulled")
  local step = decide({}, pouch, REQUEST)
  check(step.kind == "navigate" and step.x == -100.0 and step.y == 0.0,
    "uncovered: then the empty frame may take the pouch area")
end

-- Completion, failure, log removal, policy off and reset end the walk; the
-- next empty frame is unrestricted again (the nearer item spot).
local function ended(name, between)
  churn()
  check(walks_south(decide({ north() }, nil, REQUEST)), name .. ": walk starts")
  between()
  check(walks_north(decide({}, nil, REQUEST)), name .. ": walk ended")
end
ended("completed", function()
  decide({}, { quest_objectives = rows({ south = 5 }) }, REQUEST)
end)
ended("failed row", function()
  decide({}, { quest_objectives = rows({ southFailed = true }) }, REQUEST)
end)
ended("log removal", function()
  decide({}, { accepted_quests = {}, quest_objectives = {} }, REQUEST)
end)
ended("policy off", function() decide({}) end)
ended("reset", function() solo.reset() end)

io.write(string.format("test_objective_payout: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
