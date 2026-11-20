-- Synthetic regression suite for ticket 0158: the walk back to a remembered
-- questgiver (hub_step via M.decide) needs relevant business there. Views use
-- only fields the Nim projection exports (units, quest_markers, quest_frame
-- greeting rows, accepted_quests, quest_objectives, completed/rewarded ids,
-- ui_nodes). Quest ids, GUIDs and positions are synthetic; nothing here says a
-- real ender exists anywhere or that any server credit or reward happens.

package.path = "lua/entry/?.lua;lua/?.lua;lua/tools/?.lua;;"

local clock = 1000.0
local nav = { state = "following", failed_here = false, walkout_available = false }
_G.wow = {
  log = function() end,
  set_status = function() end,
  time = function() return clock end,
  nav_progress = function() return nav end,
}

local passed, failed = 0, 0
local function check(cond, name, detail)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. (detail and ("  [" .. detail .. "]") or ""))
  end
end
local function describe(step)
  if not step then return "nil" end
  return string.format("kind=%s reason=%s x=%s y=%s guid=%s", tostring(step.kind),
    tostring(step.reason), tostring(step.x), tostring(step.y), tostring(step.guid))
end

local HUB = 950                 -- the remembered giver, standing at (0, 0)
local X, W, Y = 3001, 3002, 3003  -- banked / unfinished / banked-without-data
local A, K = 1001, 1004         -- greeting rows used for the "rows" mark
local ENDER = { 1, 600.0, 0.0, 50.0, "Synthetic Ender" }

-- A fresh module per scenario so exhausted/cooldown/hub memory cannot leak.
local function load(hubs)
  package.loaded["accelerated"] = nil
  local m = require("accelerated")
  m.set_quests(true)
  m.set_quest_hubs(hubs or {})
  return m
end

local function npc(guid, distance, x, extra)
  local u = {
    guid = guid, name = "Giver" .. guid, distance = distance,
    level_known = true, level = 5,
    player_can_attack_known = true, player_can_attack = false,
    services = { "questgiver" },
    death_known = true, is_dead = false,
    health_known = true, health = 100, max_health = 100,
    location = { map_id = 1, position = { x = x or 0.0, y = 0.0, z = 50.0, o = 0 } },
  }
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end
local function mob(guid, distance, x)
  return npc(guid, distance, x, { name = "mob" .. guid, services = {},
    player_can_attack = true, level = 5, creature_rank_known = true,
    creature_rank = 0, creature_type_known = true, creature_type = 1,
    is_tapped = false, tapped_by_player = false, summoner_guid = 0,
    health = 40, max_health = 40 })
end

-- `log` is the quest state; it stays identical across a scenario so the
-- quest signature (level, accepted count, completed count) never moves.
local function view(x, units, log, extra)
  local v = {
    location_known = true,
    location = { map_id = 1, position = { x = x, y = 0.0, z = 50.0, o = 0.0 } },
    level = 5, class_id = 11,
    units = units or {},
    auto_attack_guid = 0, in_combat = false,
    is_dead = false, is_ghost = false, resurrect_offer_guid = 0,
    movement_allowed = true, rooted = false,
    health_known = true, health = 100, max_health = 100,
    powers = { 100 }, max_powers = { 100 },
    combat_kill_events = {},
    action_buttons = {
      { slot = 1, spell_id = 5176, usable = true, usable_known = true },
      { slot = 2, spell_id = 1126, usable = false, usable_known = true },
    },
    quest_markers = {},
    quest_frame = { open = false },
    accepted_quests = log.accepted,
    quest_objectives = log.objectives,
    completed_quest_ids = log.completed or {},
    rewarded_quest_ids = {},
    ui_nodes = {},
  }
  for k, val in pairs(extra or {}) do v[k] = val end
  return v
end

local function step(m, v, dt)
  clock = clock + (dt or 1.0)
  return m.decide(v)
end

-- Stand beside HUB once while it shows a marker: remember_hubs records it.
local function see_hub(m, log, status)
  step(m, view(0.0, { npc(HUB, 2.0) }, log,
    { quest_markers = { { questgiver_guid = HUB, status = status or 5 } } }))
end

-- HUB opens an empty greeting: nothing offered, exhausted for good (true).
local function empty_greeting(m, log)
  local s = step(m, view(0.0, { npc(HUB, 2.0) }, log, {
    quest_frame = { open = true, panel = "greeting", npc_guid = HUB, quest_id = 0,
      greeting_rows = {}, choice_items = {} },
    open_quest_dialog_guid = HUB,
  }))
  check(s and s.reason == "nothing_offered", "setup: empty greeting leaves", describe(s))
end

local function to_hub(s)
  return s and s.reason == "quest_hub" and math.abs((s.x or 999) - 0.0) < 1.0
end
local function to_ender(s)
  return s and s.reason == "quest_hub" and math.abs((s.x or 0) - ENDER[2]) < 1.0
end

-- X: one objective row, complete (banked). W: unfinished field work.
local BANKED = {
  accepted = {
    { quest_id = X, title = "X", level = 5, failed = false },
    { quest_id = W, title = "W", level = 5, failed = false },
  },
  objectives = {
    { quest_id = X, entry = 11, current = 4, required = 4, complete = true },
    { quest_id = W, entry = 12, current = 0, required = 5, complete = false },
  },
  completed = { X },
}
local WITH_ENDER = { [X] = { starter = { 1, 0.0, 0.0, 50.0, "S" }, ender = ENDER } }

-- 1. Decisive: banked X names an ender elsewhere; HUB nearby has nothing.
--    Leaving HUB's 120yd ring must head for X's ender, not back to HUB.
do
  local m = load(WITH_ENDER)
  see_hub(m, BANKED)
  empty_greeting(m, BANKED)
  local s = step(m, view(130.0, {}, BANKED))
  check(to_ender(s), "exhausted hub + banked ender elsewhere: walks to the ender",
    describe(s))
  s = step(m, view(160.0, {}, BANKED))
  check(to_ender(s), "exhausted hub + banked ender elsewhere: keeps the ender leg",
    describe(s))
end

-- 2. Same, but HUB was never visited (merely remembered, not exhausted).
--    Banked work still goes to its named ender, not the nearest giver.
do
  local m = load(WITH_ENDER)
  see_hub(m, BANKED)
  local s = step(m, view(130.0, {}, BANKED))
  check(to_ender(s), "irrelevant remembered hub: banked quest walks to its ender",
    describe(s))
end

-- 3. Within 120yd of the named ender (the visible-marker path owns it) and
--    outside HUB's ring: no walk back to an unrelated giver.
do
  local near = { [X] = { ender = { 1, 250.0, 0.0, 50.0, "Synthetic Ender" } } }
  local m = load(near)
  see_hub(m, BANKED)
  empty_greeting(m, BANKED)
  local s = step(m, view(150.0, {}, BANKED))
  check(not (s and s.reason == "quest_hub"),
    "inside the ender's ring: no bounce to the exhausted hub", describe(s))
  m = load(near)
  see_hub(m, BANKED)
  s = step(m, view(150.0, {}, BANKED))
  check(not (s and s.reason == "quest_hub"),
    "inside the ender's ring: no bounce to a merely remembered hub", describe(s))
end

-- 4. No starvation: a fight that pays W's objective is not abandoned for a
--    walk to an irrelevant remembered giver while X's ender is out of reach.
do
  local near = { [X] = { ender = { 1, 250.0, 0.0, 50.0, "Synthetic Ender" } } }
  local m = load(near)
  see_hub(m, BANKED)
  local s = step(m, view(150.0, { mob(77, 8.0, 158.0) }, BANKED))
  check(s and s.reason ~= "quest_hub" and s.guid == 77,
    "objective work is not starved by irrelevant hub memory", describe(s))
end

-- 5. Controls. A banked quest the generated table does not cover (unknown or
--    no data) still walks back to a remembered, unexhausted giver.
do
  local m = load({})
  see_hub(m, BANKED)
  local s = step(m, view(130.0, {}, BANKED))
  check(to_hub(s), "control: no generated ender falls back to the remembered hub",
    describe(s))
  m = load({ [W] = { ender = ENDER } })
  see_hub(m, BANKED)
  s = step(m, view(130.0, {}, BANKED))
  check(to_hub(s), "control: an ender known for another quest does not bind X",
    describe(s))
end
-- An empty log still walks back to a fresh remembered giver.
local EMPTY = { accepted = {}, objectives = {} }
do
  local m = load({})
  see_hub(m, EMPTY)
  local s = step(m, view(130.0, {}, EMPTY))
  check(to_hub(s), "control: empty log walks back to a fresh remembered giver",
    describe(s))
end

-- 6. A truly questless giver stays skipped: empty log, empty greeting.
do
  local m = load({})
  see_hub(m, EMPTY)
  empty_greeting(m, EMPTY)
  local s = step(m, view(130.0, {}, EMPTY))
  check(not to_hub(s), "questless hub: empty log does not walk back", describe(s))
  s = step(m, view(160.0, {}, EMPTY), 500.0)
  check(not to_hub(s), "questless hub: still skipped after +500s", describe(s))
end
-- Same with banked work the table cannot place (no data): no bounce either.
do
  local m = load({})
  see_hub(m, BANKED)
  empty_greeting(m, BANKED)
  local s = step(m, view(130.0, {}, BANKED))
  check(not to_hub(s), "questless hub: unknown banked work does not bounce back",
    describe(s))
end

-- 7. "rows" marks from 0156 lapse with their memory in hub_step too: skipped
--    until HUB_COOLDOWN_SECONDS, then one walk back, never earlier.
--    K is talk-only (level 5, no objective rows) with no generated ender, so
--    the remembered hub is legitimate business once the memory lapses.
local ROWS = {
  accepted = {
    { quest_id = A, title = "A", level = 5, failed = false },
    { quest_id = K, title = "K", level = 5, failed = false },
  },
  objectives = {
    { quest_id = A, entry = 1, current = 5, required = 7, complete = false },
  },
}
local function qg(id) return "quest-greeting:" .. id end
local function rows_greeting()
  return view(0.0, { npc(HUB, 2.0) }, ROWS, {
    quest_frame = { open = true, panel = "greeting", npc_guid = HUB, quest_id = 0,
      greeting_rows = { { quest_id = A, level = 5, active = true },
        { quest_id = K, level = 5, active = true } }, choice_items = {} },
    open_quest_dialog_guid = HUB,
    ui_nodes = {
      { reference_id = qg(A), enabled = true, hit_testable = true },
      { reference_id = qg(K), enabled = true, hit_testable = true },
    },
  })
end
local function progress(questId)
  return view(0.0, { npc(HUB, 2.0) }, ROWS, {
    quest_frame = { open = true, panel = "progress", npc_guid = HUB,
      quest_id = questId, can_complete = false, greeting_rows = {},
      choice_items = {} },
    open_quest_dialog_guid = HUB,
  })
end
local function close_rows(m)
  local s = step(m, rows_greeting())
  check(s and s.reference == qg(A), "rows: opens A", describe(s))
  s = step(m, progress(A))
  check(s and s.control == "QuestFrameGoodbyeButton", "rows: A unfinished", describe(s))
  local t0 = clock  -- the row memory starts when A is seen unfinished
  s = step(m, rows_greeting())
  check(s and s.reference == qg(K), "rows: opens K", describe(s))
  s = step(m, progress(K))
  check(s and s.control == "QuestFrameGoodbyeButton", "rows: K unfinished", describe(s))
  s = step(m, rows_greeting())
  check(s and s.reason == "nothing_offered", "rows: all unfinished leaves", describe(s))
  return t0
end
do
  local m = load({})
  see_hub(m, ROWS)
  local t0 = close_rows(m)
  local early, x = 0, 130.0
  while clock + 5.0 < t0 + 239.0 do
    x = (x == 130.0) and 160.0 or 130.0
    if to_hub(step(m, view(x, {}, ROWS), 4.0)) then early = early + 1 end
  end
  check(early == 0, "rows: no walk back while the row memory holds", tostring(early))
  clock = t0 + 238.0
  x = (x == 130.0) and 160.0 or 130.0
  check(not to_hub(step(m, view(x, {}, ROWS))), "rows: 239s still skipped")
  x = (x == 130.0) and 160.0 or 130.0
  local s = step(m, view(x, {}, ROWS))
  check(to_hub(s), "rows: 240s lapse allows one walk back", describe(s))
end
-- Positive control for 7: without the dialog, the same ROWS log walks back.
do
  local m = load({})
  see_hub(m, ROWS)
  local s = step(m, view(130.0, {}, ROWS))
  check(to_hub(s), "rows control: unvisited hub is walked back to", describe(s))
end

-- 8. Generated starter fallback for an empty log is unchanged.
do
  local m = load({ [X] = { starter = { 1, 200.0, 0.0, 50.0, "S" }, ender = ENDER } })
  local s = step(m, view(0.0, {}, EMPTY))
  check(s and s.reason == "quest_hub" and math.abs(s.x - 200.0) < 1.0,
    "control: empty log with no memory walks to the generated starter", describe(s))
end

-- 9. Nearest named ender, not log order. FAR comes first in the log with its
--    ender 2000yd out; X's ender stands at HUB (0, 0). Leaving HUB's ring must
--    bank X nearby; FAR is delayed until X leaves the log, never dropped.
local FAR = 3004
local FAR_ENDER = { 1, 2000.0, 0.0, 50.0, "Synthetic Far Ender" }
local X_AT_HUB = { 1, 0.0, 0.0, 50.0, "Synthetic Hub Ender" }
local function banked(ids)
  local log = { accepted = {}, objectives = {}, completed = {} }
  for i = 1, #ids do
    log.accepted[i] = { quest_id = ids[i], title = tostring(ids[i]), level = 5,
      failed = false }
    log.objectives[i] = { quest_id = ids[i], entry = 20 + i, current = 3,
      required = 3, complete = true }
    log.completed[i] = ids[i]
  end
  return log
end
local function to_x(s, x)
  return s and s.reason == "quest_hub" and math.abs((s.x or 1e9) - x) < 1.0
end
do
  local m = load({ [FAR] = { ender = FAR_ENDER }, [X] = { ender = X_AT_HUB } })
  local both = banked({ FAR, X })
  see_hub(m, both)
  local s = step(m, view(130.0, {}, both))
  check(to_x(s, 0.0), "nearest ender: far earlier log entry does not preempt X",
    describe(s))
  s = step(m, view(160.0, {}, both))
  check(to_x(s, 0.0), "nearest ender: next tick keeps the X leg", describe(s))
  s = step(m, view(160.0, {}, banked({ FAR })))
  check(to_x(s, 2000.0), "nearest ender: FAR is walked once X leaves the log",
    describe(s))
end

-- 10. Leg stability. P's ender is at (600, 0), Q's at (-500, 0); no remembered
--     givers. The accepted Q leg survives log reordering and a proximity flip
--     while it stays eligible, and is released when it does not.
local P, Q = 3005, 3006
local PQ = { [P] = { ender = { 1, 600.0, 0.0, 50.0, "Synthetic P" } },
  [Q] = { ender = { 1, -500.0, 0.0, 50.0, "Synthetic Q" } } }
local function q_unfinished(ids)
  local log = banked(ids)
  for i = 1, #log.objectives do
    if log.objectives[i].quest_id == Q then
      log.objectives[i].current, log.objectives[i].complete = 1, false
    end
  end
  return log
end
do
  local m = load(PQ)
  local s = step(m, view(0.0, {}, banked({ P, Q })))
  check(to_x(s, -500.0), "leg: nearest ender Q chosen first", describe(s))
  s = step(m, view(100.0, {}, banked({ Q, P })))
  check(to_x(s, -500.0), "leg: reorder + P now nearer keeps Q", describe(s))
  s = step(m, view(100.0, {}, banked({ P, Q })))
  check(to_x(s, -500.0), "leg: original order, P nearer, keeps Q", describe(s))
  s = step(m, view(100.0, {}, q_unfinished({ P, Q })))
  check(to_x(s, 600.0), "leg: Q no longer banked releases it to P", describe(s))
end
do
  local m = load(PQ)
  local s = step(m, view(100.0, {}, banked({ Q, P })))
  check(to_x(s, 600.0), "leg control: with no leg, P is nearest from x=100",
    describe(s))
end
do
  local m = load(PQ)
  local s = step(m, view(0.0, {}, banked({ P, Q })))
  check(to_x(s, -500.0), "leg: Q chosen before it leaves the log", describe(s))
  s = step(m, view(100.0, {}, banked({ P })))
  check(to_x(s, 600.0), "leg: Q leaving the log releases it to P", describe(s))
end
do
  local m = load(PQ)
  local s = step(m, view(0.0, {}, banked({ P, Q })))
  check(to_x(s, -500.0), "leg: Q chosen before its budget runs", describe(s))
  s = step(m, view(100.0, {}, banked({ P, Q })), 60.0)
  check(to_x(s, -500.0), "leg: Q kept at +60s", describe(s))
  -- 121s after the leg started: keeping it must not have reset its budget.
  s = step(m, view(100.0, {}, banked({ P, Q })), 61.0)
  check(to_x(s, 600.0), "leg: Q budget expiry (no clock extension) goes to P",
    describe(s))
  s = step(m, view(100.0, {}, banked({ Q, P })), 1.0)
  check(to_x(s, 600.0), "leg: Q on cooldown is not re-chosen", describe(s))
end

print(string.format("test_hub_relevance: passed=%d failed=%d", passed, failed))
os.exit(failed == 0 and 0 or 1)
