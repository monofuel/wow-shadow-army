-- The do_quests request end to end through home.decide: the job runs home's
-- own solo pipeline (emergency heal, survival, talents, progression, the
-- accelerated quest stack with its road/unstick/attack wrappers) via the
-- requests ctx.quest callback. It counts a turn-in only on a server reward
-- witness (rewarded_quest_ids), keeps questing after one until its bounds,
-- and counts as quest work only what the world shows: travel that closes on
-- a goal, damage to a mob that pays an objective, and server quest changes.
-- All quests, units, positions and ids are synthetic.

local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local clock = 0.0
_G.wow = { log = function() end, set_status = function() end, time = function() return clock end,
  nav_progress = function() return { state = "following" } end }

require("tests.lifecycle_fixture")
local requests = require("tools.requests")
local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p " .. dir)
local rs = requests.new(dir)
requests.from_env = function() return rs end
local grind = require("accelerated")
local home = require("home")
home.set_roads({})
grind.set_quest_hubs({})
-- One synthetic drop quest: item 7101 drops from "Synthetic Hound".
grind.set_objective_areas({
  [200] = { level = 4, objectives = {
    { kind = "item", from = { "Synthetic Hound" }, spots = { { 0, 400.0, 100.0 } } } } },
})

local function write(path, body)
  local f = assert(io.open(path, "w")) f:write(body) f:close()
end
local function read(path)
  local f = io.open(path, "r") if not f then return nil end
  local b = f:read("*a") f:close() return b
end
local function receipts() return read(dir .. "/receipts.jsonl") or "" end
local function last_state(key)
  local state
  for line in receipts():gmatch("[^\n]+") do
    if line:find('"key":"' .. key .. '"', 1, true) then state = line:match('"state":"([^"]*)"') end
  end
  return state
end

local SEAT = 1000027
local MOB_ENTRY = 7001

local function mob(guid, extra)
  local u = { guid = guid, entry = MOB_ENTRY, name = "Synthetic Cull Target", distance = 10.0,
    level_known = true, level = 3, player_can_attack = true, player_can_attack_known = true,
    death_known = true, is_dead = false, health_known = true, health = 40, max_health = 40,
    creature_rank_known = true, creature_rank = 0, creature_type_known = true,
    creature_type = 1, is_tapped = false, tapped_by_player = false, summoner_guid = 0,
    location = { map_id = 0, position = { x = 110, y = 100, z = 10, o = 0 } } }
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end

-- Murist on the roster and in sight 40 yards off: past the escort's 18 yard
-- hard leash, so any frame the escort brain owns chases back to him. With
-- `murist_unseen` he is on the roster only, and the escort brain walks to
-- his roster position instead.
local function murist_unit()
  return { guid = 100, name = "Murist", is_player_controlled = true, player_can_attack = false,
    death_known = true, is_dead = false, combat_known = true, is_in_combat = false,
    target_guid_known = false, target_guid = 0, distance = 40,
    location = { map_id = 0, position = { x = 140, y = 100, z = 10 } } }
end
local function member(guid, name, hp)
  return { guid = guid, name = name, health_known = true, health = hp or 100, max_health = 100,
    level_known = true, level = 4, death_state_known = true, is_dead = false, is_ghost = false,
    active_auras_known = true, active_aura_spell_ids = {}, location_known = true,
    elevation_known = true, location = { map_id = 0, x = 140, y = 100, z = 10 } }
end

local function view(extra)
  local murist = member(100, "Murist")
  murist.leader = true
  local v = {
    simulation_time = clock, player_guid = SEAT, class_id = 1, level = 4, xp = 900,
    next_level_xp = 1800, copper = 0, copper_known = true,
    location_known = true, in_combat = false, is_dead = false, is_ghost = false,
    can_reclaim_corpse = false, resurrect_offer_guid = 0, movement_allowed = true,
    rooted = false, auto_attack_guid = 0, selected_target_guid = 0,
    active_cast_spell_id = 0, active_channel_spell_id = 0,
    health_known = true, health = 100, max_health = 100, powers = { 100 },
    max_powers = { 100 }, active_aura_spell_ids = {}, combat_kill_events = {},
    location = { map_id = 0, position = { x = 100, y = 100, z = 10, o = 0 } },
    party = { in_group = true, leader_guid = 100, leader_name = "Murist",
      invite_pending = false, invite_from = "",
      members = { member(SEAT, "Tusk"), murist } },
    units = {}, known_spells = {}, spell_facts = {}, action_buttons = {},
    pet = { guid_known = true, guid = 0 }, inventory_items = {}, equipment_items = {},
    ui_nodes = {}, quest_frame = { open = false }, quest_markers = {},
    accepted_quests = {}, quest_objectives = {}, completed_quest_ids = {},
    rewarded_quest_ids = {},
  }
  local unseen = extra and extra.murist_unseen
  for k, val in pairs(extra or {}) do
    if k ~= "murist_unseen" then v[k] = val end
  end
  if not unseen then table.insert(v.units, 1, murist_unit()) end
  return v
end

local function at(x, y) return { map_id = 0, position = { x = x, y = y, z = 10, o = 0 } } end

local function cull(current, complete)
  return { { quest_id = 100, entry = MOB_ENTRY, item_id = 0, text = "Synthetic Cull Target",
    current = current, required = 10, complete = complete or false } }
end
local ACCEPTED = { { quest_id = 100, title = "Synthetic Cull", level = 4, failed = false } }

local function job(key, choice)
  return string.format('{"key":"%s","origin":"whisper","actor":"Murist","actor_guid":"100",' ..
    '"choice":"%s","intent":"action","reply":"","x":0,"y":0,"z":10,"map_id":0}\n', key, choice)
end

local function tick(t, extra)
  clock = t
  local v = view(extra)
  v.simulation_time = t
  return home.decide(v)
end

local function start(key, t, extra)
  home.reset()
  grind.reset()
  rs.last_poll = nil
  write(dir .. "/inbox.json", job(key, "do_quests"))
  return tick(t, extra)
end

-- Accepted, with the objective's mob in reach: the request runs home's
-- solo pipeline, which pulls the objective's mob.
local i = start("q1", 1, { units = { mob(501) }, accepted_quests = ACCEPTED,
  quest_objectives = cull(2) })
check(i and i.kind == "attack" and i.guid == 501, "the quest pipeline pulls the objective's mob")
check(i.status and i.status.mode == "request", "the frame is the request's")
check(receipts():find('"key":"q1".-"state":"progress".-quest baseline: 1 in log'),
  "the job records its quest baseline")
check((read(dir .. "/active.json") or ""):find('"rewarded0":""', 1, true),
  "the turn-in baseline is durable in active.json")

-- Its own pull is fought by the quest pipeline even 40 yards from Murist,
-- where the escort brain would hard-rejoin him mid-pull.
i = tick(2, { in_combat = true, auto_attack_guid = 501,
  units = { mob(501, { target_guid = SEAT, health = 30 }) },
  accepted_quests = ACCEPTED, quest_objectives = cull(2) })
check(i and i.kind == "attack" and i.guid == 501 and i.status.mode == "request",
  "its own pull is fought by the quest pipeline")
-- Survival still outranks the pull: home's flee runs inside the pipeline.
i = tick(2.2, { in_combat = true, auto_attack_guid = 501, health = 10,
  units = { mob(501, { target_guid = SEAT, health = 30 }) },
  accepted_quests = ACCEPTED, quest_objectives = cull(2) })
check(i and i.reason == "survive_flee" and i.status.mode == "request",
  "a dying seat flees its own pull")
-- Every fight the job meets alive runs the quest pipeline, never the escort
-- brain's walk back to Murist: mid-walk aggro by a mob that pays nothing, an
-- add after the pull died, and the combat that lingers after a kill, with
-- Murist in sight 40 yards off or on the roster only.
local BOAR = 8001
local function boar(guid, extra)
  local u = mob(guid, { entry = BOAR, name = "Synthetic Boar" })
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end
local function chases(intent)
  local why = tostring(intent and intent.reason)
  return why:find("murist", 1, true) ~= nil or why:find("rejoin", 1, true) ~= nil or
    why:find("follow", 1, true) ~= nil
end
for _, unseen in ipairs({ false, true }) do
  local where = unseen and " (Murist unseen)" or " (Murist visible)"
  i = tick(2.5, { murist_unseen = unseen, in_combat = true,
    units = { boar(777, { target_guid = SEAT, health = 35 }) },
    accepted_quests = ACCEPTED, quest_objectives = cull(2) })
  check(i and i.kind == "attack" and i.guid == 777 and i.status.mode == "request",
    "mid-walk aggro is fought back by the quest pipeline" .. where)
  i = tick(2.6, { murist_unseen = unseen, in_combat = true, health = 10,
    units = { boar(777, { target_guid = SEAT, health = 35 }) },
    accepted_quests = ACCEPTED, quest_objectives = cull(2) })
  check(i and i.reason == "survive_flee" and i.status.mode == "request",
    "a dying seat flees mid-walk aggro inside the pipeline" .. where)
  i = tick(2.7, { murist_unseen = unseen, in_combat = true,
    units = { mob(501, { health = 0, is_dead = true }),
      boar(778, { target_guid = SEAT, health = 35 }) },
    accepted_quests = ACCEPTED, quest_objectives = cull(2) })
  check(i and i.kind == "attack" and i.guid == 778 and i.status.mode == "request",
    "an add after the pull died is fought by the pipeline" .. where)
  i = tick(2.8, { murist_unseen = unseen, in_combat = true,
    units = { mob(501, { health = 0, is_dead = true }) },
    accepted_quests = ACCEPTED, quest_objectives = cull(2) })
  check(i and i.status.mode == "request" and not chases(i),
    "lingering combat stays with the pipeline, no walk back to Murist" .. where)
end
-- Control: the same Murist-unseen fight without a quest job is the escort
-- brain's, which walks to his roster position.
local saved = rs.active
rs.active = nil
local control = tick(2.9, { murist_unseen = true, in_combat = true,
  units = { boar(779, { target_guid = SEAT, health = 35 }) } })
rs.active = saved
check(control and control.status.mode ~= "request" and chases(control),
  "control: without the job that fight walks back to Murist")

-- Objective credit, xp, objectives done and a pressed turn-in button are
-- progress, never completion.
tick(3, { accepted_quests = ACCEPTED, quest_objectives = cull(3) })
check(receipts():find('"key":"q1".-objective credit quest 100: Synthetic Cull Target 3/10'),
  "server objective credit is a progress receipt")
check(last_state("q1") == "progress", "and does not finish the job")
tick(4, { xp = 1200, accepted_quests = ACCEPTED, quest_objectives = cull(3) })
check(last_state("q1") == "progress" and read(dir .. "/active.json"), "xp alone finishes nothing")
tick(5, { accepted_quests = ACCEPTED, quest_objectives = cull(10, true),
  completed_quest_ids = { 100 } })
check(receipts():find('objectives done for quest 100; turn%-in pending'),
  "objectives done is recorded as pending turn-in")
grind.reset()
i = tick(6, { accepted_quests = ACCEPTED, quest_objectives = cull(10, true),
  completed_quest_ids = { 100 },
  quest_frame = { open = true, panel = "reward", quest_id = 100, npc_guid = 900,
    choice_items = {}, selected_choice = 0 } })
check(i and i.kind == "ui_press" and i.control == "QuestFrameCompleteQuestButton" and
  i.reason == "turn_in", "the reward panel is completed by the existing turn-in button")
check(read(dir .. "/active.json") ~= nil, "a pressed turn-in button is not completion")

-- The server's quest-complete witness is a turn-in, counted once and made
-- durable, and the same job keeps questing: it is progress, not the end.
local function count(pattern)
  local n = 0
  for _ in receipts():gmatch(pattern) do n = n + 1 end
  return n
end
local function active_field(name) return (read(dir .. "/active.json") or ""):match(
  '"' .. name .. '":"?([^",}]*)') end
local FOLLOW = { { quest_id = 102, title = "Synthetic Follow-up", level = 4, failed = false } }
local function errand(current)
  return { { quest_id = 102, entry = MOB_ENTRY, item_id = 0, text = "Synthetic Errand Target",
    current = current, required = 4, complete = false } }
end
tick(7, { xp = 1500, copper = 35, rewarded_quest_ids = { 100 } })
check(receipts():find('"key":"q1".-"state":"progress".-turned in quest 100 Synthetic Cull ' ..
  '%(server reward witness, 1 this request%)'), "a rewarded quest id is a turn-in receipt")
check(receipts():find('"key":"q1".-turned in quest 100[^\n]-"copper_gain":"35"'),
  "with the observed reward deltas")
check(last_state("q1") == "progress" and read(dir .. "/active.json"),
  "the first turn-in does not finish the request")
check(active_field("rewarded") == "100", "the acknowledged turn-in is durable in active.json")
check(not receipts():find('quest 100 Synthetic Cull left the log without a reward witness'),
  "a turned-in quest leaving the log is not reported as unrewarded")
-- The server offers the follow-up; the same job's pipeline accepts it.
grind.reset()
i = tick(7.5, { xp = 1500, copper = 35, rewarded_quest_ids = { 100 },
  quest_frame = { open = true, panel = "details", quest_id = 102, npc_guid = 900 } })
check(i and i.kind == "ui_press" and i.control == "QuestFrameAcceptButton" and
  i.reason == "accept" and i.status.mode == "request",
  "the follow-up's details are accepted by the same request")
tick(8, { xp = 1500, copper = 35, rewarded_quest_ids = { 100 }, accepted_quests = FOLLOW,
  quest_objectives = errand(0) })
check(receipts():find('"key":"q1".-accepted quest 102 Synthetic Follow%-up %(accepted, not completed%)'),
  "the follow-up accept is progress")
tick(8.5, { xp = 1500, copper = 35, rewarded_quest_ids = { 100 }, accepted_quests = FOLLOW,
  quest_objectives = errand(1) })
check(count('turned in quest 100 ') == 1, "the same reward witness is counted once")
-- A reload mid-chain resumes the same job with its original deadline and
-- acknowledged turn-ins; a reconnect's empty list and its refill add nothing.
local wall0 = active_field("started_wall")
local fresh = requests.new(dir)
for k in pairs(rs) do rs[k] = nil end
for k, val in pairs(fresh) do rs[k] = val end
tick(9, { xp = 1500, copper = 35, rewarded_quest_ids = {}, accepted_quests = FOLLOW,
  quest_objectives = errand(1) })
check(last_state("q1") == "progress" and receipts():find('"key":"q1".-"state":"resumed"'),
  "the chain resumes after a reload")
check(active_field("started_wall") == wall0 and active_field("rewarded") == "100",
  "with its original deadline and acknowledged turn-in")
tick(9.2, { xp = 1500, copper = 35, rewarded_quest_ids = { 100 }, accepted_quests = FOLLOW,
  quest_objectives = errand(1) })
check(count('turned in quest 100 ') == 1, "the refilled reward list repeats no turn-in")
-- A second, distinct turn-in is counted once.
tick(9.4, { xp = 1700, copper = 60, rewarded_quest_ids = { 100, 102 } })
tick(9.5, { xp = 1700, copper = 60, rewarded_quest_ids = { 100, 102 } })
check(count('turned in quest 102 Synthetic Follow%-up %(server reward witness, 2 this request%)') == 1,
  "a second distinct turn-in is counted once")
check(count('turned in quest 100 ') == 1 and active_field("rewarded") == "100 102",
  "and both turn-ins are durable")
check(last_state("q1") == "progress", "intermediate turn-ins never finish the request")
-- The owner's stop still wins, and reports what the chain achieved.
rs.last_poll = nil
write(dir .. "/inbox.json", job("h1", "hold_here"))
i = tick(9.7, { rewarded_quest_ids = { 100, 102 } })
check(last_state("q1") == "superseded" and
  receipts():find('"key":"q1"[^\n]-"state":"superseded"[^\n]-"rewards":"2"'),
  "stop and stay ends the chain with its turn-in count")
check(i and (i.reason == "request_hold" or i.reason == "request_hold_return"),
  "and the seat holds")

-- A turn-in witnessed before the request began never counts; a new accept
-- is progress only; a restart with a reconnect's empty list resumes.
start("q2", 10, { rewarded_quest_ids = { 100 }, accepted_quests = ACCEPTED,
  quest_objectives = cull(0) })
check(last_state("q2") == "progress", "an earlier turn-in does not complete a new request")
check(not receipts():find('"key":"q2"[^\n]-turned in quest 100'),
  "the baseline turn-in is not counted")
tick(11, { rewarded_quest_ids = { 100 },
  accepted_quests = { ACCEPTED[1], { quest_id = 101, title = "Synthetic Errand", level = 4 } },
  quest_objectives = cull(0) })
check(receipts():find('"key":"q2".-accepted quest 101 Synthetic Errand %(accepted, not completed%)'),
  "accepting a quest is recorded as progress, not completion")
-- A restart: home keeps its state table, so the fresh one replaces its contents.
fresh = requests.new(dir)
for k in pairs(rs) do rs[k] = nil end
for k, val in pairs(fresh) do rs[k] = val end
tick(12, { accepted_quests = ACCEPTED, quest_objectives = cull(0) })
check(receipts():find('"key":"q2".-"state":"resumed"'), "the quest request resumes after a restart")
check(last_state("q2") == "progress", "a reconnect's empty reward list completes nothing")
tick(13, { rewarded_quest_ids = { 100 }, accepted_quests = ACCEPTED, quest_objectives = cull(0) })
check(last_state("q2") == "progress" and not receipts():find('"key":"q2"[^\n]-turned in quest'),
  "the baseline turn-in still counts nothing")
tick(14, { rewarded_quest_ids = { 100, 101 }, accepted_quests = ACCEPTED,
  quest_objectives = cull(0) })
check(receipts():find('"key":"q2"[^\n]-"state":"progress"[^\n]-turned in quest 101'),
  "a new turn-in after the restart counts for the same request")
check(last_state("q2") == "progress", "and the request keeps running")

-- The owner's hold supersedes a running quest request, even mid-pull.
start("q3", 20, { units = { mob(501) }, accepted_quests = ACCEPTED, quest_objectives = cull(0) })
rs.last_poll = nil
write(dir .. "/inbox.json", job("h3", "hold_here"))
i = tick(21, { in_combat = true, auto_attack_guid = 501,
  units = { mob(501, { target_guid = SEAT }) }, accepted_quests = ACCEPTED,
  quest_objectives = cull(0) })
check(last_state("q3") == "superseded", "stop and stay supersedes the quest request mid-pull")

-- A priest on its own pull still answers a party member's emergency first.
local function spell(id, name)
  return { spell_id = id, name = name, name_known = true, rank = 1, usable_known = true,
    usable = true, cooldown_ms = 0, reagents_available = true }
end
local function priest(t, igris_hp, extra)
  local igris = member(300, "Igris", igris_hp)
  igris.location = { map_id = 0, x = 110, y = 100, z = 10 }
  local v = { class_id = 5, accepted_quests = ACCEPTED, quest_objectives = cull(0),
    spell_facts = { spell(17, "Power Word: Shield"), spell(2050, "Lesser Heal") },
    party = { in_group = true, leader_guid = 100, leader_name = "Murist",
      invite_pending = false, invite_from = "",
      members = { member(SEAT, "Beru"), member(100, "Murist"), igris } } }
  for k, val in pairs(extra or {}) do v[k] = val end
  return tick(t, v)
end
start("q3b", 30, { class_id = 5, units = { mob(501) }, accepted_quests = ACCEPTED,
  quest_objectives = cull(0) })
local fight = { in_combat = true, auto_attack_guid = 501,
  units = { mob(501, { target_guid = SEAT, health = 30 }) } }
i = priest(31, 100, fight)
check(i and i.kind == "attack" and i.guid == 501 and i.status.mode == "request",
  "the priest fights its own pull while the party is healthy")
fight.units = { mob(501, { target_guid = SEAT, health = 30 }) }
i = priest(32, 30, fight)
check(i and i.kind == "cast_spell" and i.target_guid == 300 and i.status.mode == "request",
  "a falling party member is healed before the pull")
fight = { in_combat = true, units = { boar(780, { target_guid = SEAT, health = 30 }) } }
i = priest(33, 30, fight)
check(i and i.kind == "cast_spell" and i.target_guid == 300 and i.status.mode == "request",
  "mid-walk aggro on a priest still heals a falling party member first")
fight.units = { boar(780, { target_guid = SEAT, health = 30 }) }
i = priest(34, 100, fight)
check(i and i.kind == "attack" and i.guid == 780 and i.status.mode == "request",
  "and the priest fights it back once the party is healthy")

-- Counterexample: the pipeline grinds mobs that pay no objective, one after
-- another, each killed 22 yards off (a caster's stop) with combat lingering
-- after the kill, then walks 20 yards to loot the corpse. None of it is
-- quest work, so the request fails once 90 s pass without any.
start("q4", 100, { accepted_quests = ACCEPTED, quest_objectives = cull(0) })
local t, guid, sawGrind, sawLoot, lootWalk = 100, 600, false, false, 0
local CORPSE_X = 122
local function corpse(seat_x, extra)
  local u = boar(guid, { distance = CORPSE_X - seat_x, location = at(CORPSE_X, 100) })
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end
while t < 260 and last_state("q4") == "progress" do
  guid = guid + 1
  local hp = 40
  for _ = 1, 4 do
    t = t + 2
    local fighting = hp < 40
    local intent = tick(t, { in_combat = fighting, auto_attack_guid = fighting and guid or 0,
      units = { corpse(100, { health = hp, target_guid = fighting and SEAT or 0 }) },
      accepted_quests = ACCEPTED, quest_objectives = cull(0) })
    if intent and intent.kind == "attack" and intent.guid == guid then sawGrind = true end
    hp = hp - 10
  end
  t = t + 2
  tick(t, { in_combat = true, auto_attack_guid = guid,
    units = { corpse(100, { health = 0, is_dead = true }) },
    accepted_quests = ACCEPTED, quest_objectives = cull(0),
    combat_kill_events = { { target_guid = guid, source_guid = SEAT } } })
  -- Combat lingers two seconds at the kill spot, then the walk to the
  -- corpse closes 4 yards a second.
  local x = 100
  for k = 1, 8 do
    t = t + 1
    local intent = tick(t, { in_combat = k <= 2, location = at(x, 100),
      units = { corpse(x, { health = 0, is_dead = true, lootable = true }) },
      accepted_quests = ACCEPTED, quest_objectives = cull(0) })
    if intent and intent.kind == "interact" and intent.reason == "loot_corpse" then
      sawLoot = true
      lootWalk = math.max(lootWalk, CORPSE_X - x)
    end
    if k > 2 then x = x + 4 end
  end
end
check(sawGrind, "the pipeline really grinds the non-objective mobs")
check(sawLoot and lootWalk >= 20, "and really walks 20+ yards to loot each corpse")
check(last_state("q4") == "failed" and receipts():find('"key":"q4".-no reachable quest work'),
  "a non-objective grind and loot loop fails as no quest work")
local failedAt = tonumber(receipts():match(
  '"key":"q4","choice":"do_quests"[^\n]-"state":"failed","at":([%d.]+)'))
check(failedAt and failedAt > 190 and failedAt <= 195, "at the idle window, not the 420 s stall")

-- Idle is judged between fights: a job past its idle window while a mob is
-- hitting the seat keeps fighting it (no hand-off to the walk back to
-- Murist), then fails on the first frame nothing is hitting it.
start("q4b", 270, { murist_unseen = true, accepted_quests = ACCEPTED,
  quest_objectives = cull(0) })
i = tick(365, { murist_unseen = true, in_combat = true,
  units = { boar(651, { target_guid_known = true, target_guid = SEAT, health = 30 }) },
  accepted_quests = ACCEPTED, quest_objectives = cull(0) })
check(last_state("q4b") == "progress" and i and i.kind == "attack" and i.guid == 651 and
  i.status.mode == "request", "past the idle window, the seat still fights what is hitting it")
tick(368, { murist_unseen = true, in_combat = true,
  units = { boar(651, { health = 0, is_dead = true }) },
  accepted_quests = ACCEPTED, quest_objectives = cull(0) })
check(last_state("q4b") == "failed" and receipts():find('"key":"q4b".-no reachable quest work'),
  "and fails as soon as nothing is hitting it, lingering combat included")

-- A stale nonzero target is not evidence of a current attack. The raw
-- projection retains a GUID while explicitly marking its fact unknown.
start("q4c", 270, { murist_unseen = true, accepted_quests = ACCEPTED,
  quest_objectives = cull(0) })
tick(365, { murist_unseen = true, in_combat = true,
  units = { boar(652, { target_guid_known = false, target_guid = SEAT, health = 30 }) },
  accepted_quests = ACCEPTED, quest_objectives = cull(0) })
check(last_state("q4c") == "failed" and receipts():find('"key":"q4c".-no reachable quest work'),
  "an unknown target GUID cannot postpone the idle failure")

-- A kill that pays an item-drop objective is quest work: the seat fights a
-- named dropper for well over 90 s and the job keeps running.
local DROP = { { quest_id = 200, entry = 0, item_id = 7101, text = "Synthetic Pelt",
  current = 0, required = 8, complete = false } }
local DROP_Q = { { quest_id = 200, title = "Synthetic Pelts", level = 4, failed = false } }
start("q5", 300, { accepted_quests = DROP_Q, quest_objectives = DROP })
t, guid = 300, 700
while t < 420 do
  guid = guid + 1
  local hp = 40
  for _ = 1, 4 do
    t = t + 2
    local fighting = hp < 40
    tick(t, { in_combat = fighting, auto_attack_guid = fighting and guid or 0,
      units = { mob(guid, { entry = 8101, name = "Synthetic Hound", health = hp,
        target_guid = fighting and SEAT or 0 }) },
      accepted_quests = DROP_Q, quest_objectives = DROP })
    hp = hp - 10
  end
  t = t + 2
  tick(t, { units = {}, accepted_quests = DROP_Q, quest_objectives = DROP })
end
check(last_state("q5") == "progress", "fighting an item-drop objective's dropper is quest work")

-- Counterexample: a walk to the drop area that never displaces the seat.
-- Repeated identical navigates at one spot (and the unstick legs they
-- trip) are not travel.
start("q6", 500, { accepted_quests = DROP_Q, quest_objectives = DROP })
local reasons = {}
t = 500
while t < 620 and last_state("q6") == "progress" do
  t = t + 1
  local intent = tick(t, { accepted_quests = DROP_Q, quest_objectives = DROP })
  if intent then reasons[tostring(intent.reason)] = true end
end
check(reasons.objective_area_road or reasons.objective_area,
  "the pipeline walks toward the drop area")
check(last_state("q6") == "failed" and t <= 600, "a walk that never closes on its goal fails")

-- The same walk with the seat really closing on the area is quest travel.
start("q7", 700, { accepted_quests = DROP_Q, quest_objectives = DROP })
t = 700
local x = 100
while t < 820 do
  t = t + 1
  x = x + 2
  tick(t, { location = at(x, 100), accepted_quests = DROP_Q, quest_objectives = DROP })
end
check(last_state("q7") == "progress", "real travel toward the objective area keeps the job")

-- Counterexample: an open quest panel the pipeline keeps answering while
-- the server never moves, at one spot.
start("q8", 900, { accepted_quests = ACCEPTED, quest_objectives = cull(0) })
t = 900
local pressed = false
while t < 1020 and last_state("q8") == "progress" do
  t = t + 1
  local intent = tick(t, { accepted_quests = ACCEPTED, quest_objectives = cull(0),
    quest_frame = { open = true, panel = "progress", quest_id = 100, npc_guid = 900 } })
  if intent and intent.kind == "ui_press" then pressed = true end
end
check(pressed, "the pipeline answers the panel")
check(last_state("q8") == "failed" and t <= 1000, "repeated dialog presses are not quest work")

-- Counterexample: no position at all.
start("q9", 1100, { location_known = false, accepted_quests = ACCEPTED,
  quest_objectives = cull(0) })
t = 1100
while t < 1220 and last_state("q9") == "progress" do
  t = t + 1
  tick(t, { location_known = false, accepted_quests = ACCEPTED, quest_objectives = cull(0) })
end
check(last_state("q9") == "failed" and t <= 1200, "a seat without a position is not questing")

-- A corpse run is the way back to the quest, not idling.
start("q10", 1300, { accepted_quests = ACCEPTED, quest_objectives = cull(0) })
tick(1380, { is_dead = true, is_ghost = true, accepted_quests = ACCEPTED,
  quest_objectives = cull(0) })
tick(1390, { accepted_quests = ACCEPTED, quest_objectives = cull(0) })
check(last_state("q10") == "progress", "death and the corpse run reset the idle clock")

-- A chain ends only at the request's bounds. With turn-ins achieved it is
-- done with their count and what stopped it; a quest failing is progress,
-- never a turn-in.
start("q12", 1600, { accepted_quests = ACCEPTED, quest_objectives = cull(0) })
tick(1601, { rewarded_quest_ids = { 300 }, accepted_quests = ACCEPTED,
  quest_objectives = cull(0) })
tick(1602, { rewarded_quest_ids = { 300 },
  accepted_quests = { { quest_id = 100, title = "Synthetic Cull", level = 4, failed = true } },
  quest_objectives = cull(0) })
check(receipts():find('"key":"q12".-quest 100 failed') and last_state("q12") == "progress" and
  active_field("rewarded") == "300", "a failed quest is progress, not a turn-in")
tick(1700, { rewarded_quest_ids = { 300 },
  accepted_quests = { { quest_id = 100, title = "Synthetic Cull", level = 4, failed = true } },
  quest_objectives = cull(0) })
check(receipts():find('"key":"q12"[^\n]-"state":"done"[^\n]-turned in 1 quest this request ' ..
  '%(300%); stopped: no reachable quest work[^\n]-"rewards":"1"'),
  "the chain ends done at its idle bound with what it achieved and why it stopped")
check(read(dir .. "/active.json") == nil, "and clears the active job")

-- XP and a new accept without any turn-in end failed, never done.
start("q13", 1800, { accepted_quests = ACCEPTED, quest_objectives = cull(0) })
tick(1801, { xp = 1700, accepted_quests = { ACCEPTED[1],
  { quest_id = 101, title = "Synthetic Errand", level = 4 } }, quest_objectives = cull(0) })
tick(1900, { xp = 1700, accepted_quests = { ACCEPTED[1],
  { quest_id = 101, title = "Synthetic Errand", level = 4 } }, quest_objectives = cull(0) })
check(last_state("q13") == "failed" and receipts():find('"key":"q13".-no reachable quest work') and
  not receipts():find('"key":"q13"[^\n]-turned in'), "xp and accepts alone end failed")

-- The request window is not extended by turn-ins: real objective credit
-- keeps the job alive, and it ends done when the window closes.
local function long(current)
  return { { quest_id = 400, entry = MOB_ENTRY, item_id = 0, text = "Synthetic Long Target",
    current = current, required = 100, complete = false } }
end
local LONG_Q = { { quest_id = 400, title = "Synthetic Long", level = 4, failed = false } }
start("q14", 2000, { accepted_quests = LONG_Q, quest_objectives = long(0) })
tick(2001, { rewarded_quest_ids = { 301 }, accepted_quests = LONG_Q, quest_objectives = long(0) })
t = 2001
local credit = 0
while t < 3900 and last_state("q14") == "progress" do
  t = t + 60
  credit = credit + 1
  tick(t, { rewarded_quest_ids = { 301 }, accepted_quests = LONG_Q, quest_objectives = long(credit) })
end
check(last_state("q14") == "done" and t > 3800 and t <= 3870 and
  receipts():find('"key":"q14"[^\n]-"state":"done"[^\n]-turned in 1 quest this request ' ..
  '%(301%); stopped: request window of 1800s ended'),
  "the original request window bounds a chain")

-- Failed persistence must not acknowledge a reward in memory or emit a
-- receipt that a reload would emit again. Only active.json replacement
-- fails here; receipts and the previously committed job remain available.
local SAVE_Q = { { quest_id = 600, title = "Synthetic Save", level = 4, failed = false } }
start("q15", 4000, { accepted_quests = SAVE_Q, quest_objectives = {} })
local rename = os.rename
os.rename = function(from, to)
  if to == dir .. "/active.json" then return nil, "synthetic replacement failure" end
  return rename(from, to)
end
tick(4001, { rewarded_quest_ids = { 600 }, accepted_quests = {}, quest_objectives = {} })
tick(4002, { rewarded_quest_ids = { 600 }, accepted_quests = {}, quest_objectives = {} })
os.rename = rename
check(active_field("rewarded") == "" and rs.active and not rs.active.rewarded,
  "an unwritten reward acknowledgement changes neither disk nor memory")
check(count('"key":"q15"[^\n]-turned in quest 600') == 0,
  "an unwritten acknowledgement emits no duplicate-prone reward receipt")
check(not receipts():find('"key":"q15"[^\n]-left the log without a reward witness'),
  "a server-rewarded quest is not misreported as abandoned when saving fails")
fresh = requests.new(dir)
for k in pairs(rs) do rs[k] = nil end
for k, val in pairs(fresh) do rs[k] = val end
tick(4003, { rewarded_quest_ids = { 600 }, accepted_quests = ACCEPTED,
  quest_objectives = cull(0) })
tick(4004, { rewarded_quest_ids = { 600 }, accepted_quests = ACCEPTED,
  quest_objectives = cull(0) })
check(active_field("rewarded") == "600" and
  count('"key":"q15"[^\n]-turned in quest 600') == 1,
  "after reload and storage recovery the server witness is acknowledged exactly once")

start("q16", 4100, { accepted_quests = SAVE_Q, quest_objectives = {} })
os.rename = function(from, to)
  if to == dir .. "/active.json" then return nil, "synthetic replacement failure" end
  return rename(from, to)
end
tick(4101, { rewarded_quest_ids = { 600 }, accepted_quests = {}, quest_objectives = {} })
tick(4200, { rewarded_quest_ids = { 600 }, accepted_quests = {}, quest_objectives = {} })
os.rename = rename
check(last_state("q16") == "failed" and receipts():find(
  '"key":"q16"[^\n]-could not save observed server turn%-in evidence'),
  "a persistent storage failure ends boundedly with its actual blocker")

-- A client without the turn-in witness is refused, never guessed.
start("q11", 1500, { rewarded_quest_ids = false })
check(last_state("q11") == "failed" and receipts():find('"key":"q11".-no quest turn%-in witness'),
  "no reward witness means an explicit failure")

-- 0151: an owner's quest request walks to an unfinished objective's area
-- before an unrelated fresh pull. Quest 200's synthetic guide puts its
-- droppers 300 yards east at (400, 100); a level 3 boar that pays nothing
-- (not gray to a level 4 seat) stands 10 yards off. Each scenario starts
-- from its own spot so earlier standing still cannot trip the unstick
-- reflex. Cases print and count instead of aborting so old and new sources
-- can be compared whole.
local p151, f151 = 0, 0
local function case(cond, name, intent)
  if cond then
    p151 = p151 + 1
    print("PASS 0151 " .. name)
  else
    f151 = f151 + 1
    print(string.format("FAIL 0151 %s  [%s %s %s]", name, tostring(intent and intent.kind),
      tostring(intent and intent.reason), tostring(intent and intent.guid)))
  end
end
local function travels(intent)
  return intent ~= nil and intent.kind == "navigate" and
    tostring(intent.reason):find("^objective_area") ~= nil
end
local function attacks(intent, guid)
  return intent ~= nil and intent.kind == "attack" and intent.guid == guid
end
local spot = 100
-- The scenario's world: the seat at a fresh spot, the drop quest in the log.
local function world(extra)
  local w = { location = at(100, spot), accepted_quests = DROP_Q, quest_objectives = DROP }
  for k, v in pairs(extra or {}) do w[k] = v end
  return w
end
local function scene() spot = spot + 5 end

-- Default control: with no request, a solo seat still pulls the filler, and
-- the accelerated brain called as an entry (one argument) does too.
home.reset()
grind.reset()
scene()
local SOLO = { in_group = false, leader_guid = 0, leader_name = "", invite_pending = false,
  invite_from = "", members = {} }
i = tick(4900, world({ murist_unseen = true, party = SOLO, units = { boar(912) } }))
case(rs.active == nil, "control precondition: no active request", i)
case(attacks(i, 912) and i.status.mode ~= "request",
  "default solo path without a request still pulls the filler", i)
grind.reset()
scene()
clock = 4901
i = grind.decide(view(world({ murist_unseen = true, party = SOLO, units = { boar(913) } })))
case(attacks(i, 913), "accelerated entry decide(view) is unchanged", i)

-- Decisive: the request walks the guide instead of pulling the boar, and
-- real travel (1 yd/s, never reaching the 35 yd swept radius) keeps it
-- alive past the 90 s idle bound with the boar always in reach.
scene()
i = start("p1", 5000, world({ units = { boar(901) } }))
case(travels(i) and i.x == 400 and i.y == 100 and i.status.mode == "request",
  "request prefers the objective area over a nearby nongray filler pull", i)
t, x = 5000, 100
local pulled = false
while t < 5120 do
  t, x = t + 1, x + 1
  local step = tick(t, world({ location = at(x, spot),
    units = { boar(901, { location = at(x + 10, spot) }) } }))
  if attacks(step, 901) then pulled = true end
end
case(not pulled and last_state("p1") == "progress",
  "walking the objective keeps the request alive past the idle bound")

-- An engaged fight is never abandoned for the route.
scene()
start("p2", 5200, world({ units = { boar(902) } }))
i = tick(5201, world({ in_combat = true, auto_attack_guid = 902,
  units = { boar(902, { target_guid_known = true, target_guid = SEAT, health = 30 }) } }))
case(attacks(i, 902), "an engaged fight in combat is kept", i)
-- Our own auto-attack before the server's combat bit arrives.
i = tick(5202, world({ auto_attack_guid = 902, units = { boar(902, { health = 30 }) } }))
case(attacks(i, 902), "our own auto-attack on a nongray mob is kept", i)
-- A hostile known to be targeting the seat, combat bit not yet set.
scene()
local aggro = { units = { boar(903, { target_guid_known = true, target_guid = SEAT }) } }
start("p3", 5300, world(aggro))
i = tick(5301, world(aggro))
case(attacks(i, 903), "a hostile known to target the seat is fought, not walked from", i)
-- A retained target GUID without target_guid_known is not hostility.
scene()
local stale = { units = { boar(904, { target_guid_known = false, target_guid = SEAT }) } }
start("p4", 5400, world(stale))
i = tick(5401, world(stale))
case(travels(i), "an unknown target flag does not hold the seat on filler", i)

-- A mob that pays the objective is still pulled.
scene()
local pays = { units = { boar(905), mob(906, { entry = 8101, name = "Synthetic Hound" }) } }
start("p5", 5500, world(pays))
i = tick(5501, world(pays))
case(attacks(i, 906), "an objective-paying mob is pulled", i)

-- No guide for the unfinished objective: the old grind stands.
scene()
local noguide = { units = { boar(907) },
  accepted_quests = { { quest_id = 210, title = "Synthetic Fangs", level = 4, failed = false } },
  quest_objectives = { { quest_id = 210, entry = 0, item_id = 7201, text = "Synthetic Fang",
    current = 0, required = 6, complete = false } } }
start("p6", 5600, world(noguide))
i = tick(5601, world(noguide))
case(attacks(i, 907), "without a guide the filler pull is unchanged", i)
-- A failed quest's guide is not walked.
scene()
local failedq = { units = { boar(908) },
  accepted_quests = { { quest_id = 200, title = "Synthetic Pelts", level = 4, failed = true } } }
start("p7", 5700, world(failedq))
i = tick(5701, world(failedq))
case(attacks(i, 908), "a failed quest's area is not walked", i)
-- No position: nothing to route from.
scene()
start("p8", 5800, world({ location_known = false, units = { boar(909) } }))
i = tick(5801, world({ location_known = false, units = { boar(909) } }))
case(i and i.kind == "hold" and not travels(i), "no position holds, never routes", i)
-- Recovery first: a hurt seat out of combat still recovers.
scene()
start("p9", 5900, world({ health = 50, units = { boar(910) } }))
i = tick(5901, world({ health = 50, units = { boar(910) } }))
case(i and i.reason == "recover_walk", "a hurt seat recovers before routing", i)
-- Survival: a dying seat in a fight flees.
i = tick(5902, world({ health = 10, in_combat = true, auto_attack_guid = 910,
  units = { boar(910, { target_guid_known = true, target_guid = SEAT }) } }))
case(i and i.reason == "survive_flee", "a dying seat flees", i)
-- The owner's stop still wins over the route.
scene()
start("p10", 6000, world({ units = { boar(911) } }))
rs.last_poll = nil
write(dir .. "/inbox.json", job("h10", "hold_here"))
i = tick(6001, world({ units = { boar(911) } }))
case(last_state("p10") == "superseded" and i and
  (i.reason == "request_hold" or i.reason == "request_hold_return"),
  "stop and stay supersedes the route", i)
print(string.format("0151 cases: passed=%d failed=%d", p151, f151))
if f151 > 0 then
  os.execute("rm -rf " .. dir)
  os.exit(1)
end

os.execute("rm -rf " .. dir)
print(string.format("test_quest_request: %d checks passed", passed))
