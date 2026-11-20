-- Synthetic regression suite for ticket 0150 (quest dialog turn-in priority).
-- Views use only fields the Nim projection exports: greeting rows carry
-- quest_id/level/active; quest_offers carry questgiver_guid/quest_id/icon/
-- level/title; completed_quest_ids lists objective-done quests still in log.

package.path = "lua/entry/?.lua;lua/?.lua;lua/tools/?.lua;;"

local clock = 1000.0
local nav = { state = "following", failed_here = false, walkout_available = false }
_G.wow = {
  log = function() end,
  set_status = function() end,
  time = function() return clock end,
  nav_progress = function() return nav end,
}

-- A fresh module per scenario so exhausted/cooldown state cannot leak.
local function load()
  package.loaded["accelerated"] = nil
  local m = require("accelerated")
  m.set_quests(true)
  m.set_quest_hubs({})
  return m
end
local passed, failed = 0, 0
local function check(cond, name, detail)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. (detail and ("  [" .. detail .. "]") or ""))
  end
end

local GIVER = 910
local A, B, C, N = 1001, 1002, 1003, 2001

local function giver(guid)
  return {
    guid = guid, name = "Giver", distance = 2.0,
    level_known = true, level = 5,
    player_can_attack_known = true, player_can_attack = false,
    services = { "questgiver" },
    death_known = true, is_dead = false,
    health_known = true, health = 100, max_health = 100,
    location = { map_id = 1, position = { x = 0, y = 0, z = 50, o = 0 } },
  }
end

local function node(reference, enabled, hitTestable)
  if enabled == nil then enabled = true end
  if hitTestable == nil then hitTestable = true end
  return { reference_id = reference, enabled = enabled, hit_testable = hitTestable }
end

local function base_view(extra)
  local v = {
    location_known = true,
    location = { map_id = 1, position = { x = 0.0, y = 0.0, z = 50.0, o = 0.0 } },
    level = 5, class_id = 11,
    units = { giver(GIVER) },
    auto_attack_guid = 0, in_combat = false,
    is_dead = false, is_ghost = false, resurrect_offer_guid = 0,
    movement_allowed = true, rooted = false,
    health_known = true, health = 100, max_health = 100,
    powers = { 100 }, max_powers = { 100 },
    combat_kill_events = {},
    action_buttons = {
      { slot = 1, spell_id = 5176, usable = true, usable_known = true },
    },
    quest_markers = {},
    quest_frame = { open = false },
    accepted_quests = {
      { quest_id = A, title = "A", level = 5, failed = false },
      { quest_id = B, title = "B", level = 5, failed = false },
    },
    quest_objectives = {
      { quest_id = A, entry = 1, current = 0, required = 8, complete = false },
      { quest_id = B, entry = 2, current = 8, required = 8, complete = true },
    },
    completed_quest_ids = { B },
    rewarded_quest_ids = {},
    ui_nodes = {},
  }
  for k, val in pairs(extra or {}) do v[k] = val end
  return v
end

local function greeting(rows, nodes, extra)
  local e = {
    quest_frame = { open = true, panel = "greeting", npc_guid = GIVER,
      quest_id = 0, greeting_rows = rows, choice_items = {} },
    open_quest_dialog_guid = GIVER,
    ui_nodes = nodes,
  }
  for k, val in pairs(extra or {}) do e[k] = val end
  return base_view(e)
end

local function gossip(offers, nodes, extra)
  local e = {
    gossip_open = true, gossip_guid = GIVER,
    open_quest_dialog_guid = GIVER,
    quest_offers = offers,
    ui_nodes = nodes,
  }
  for k, val in pairs(extra or {}) do e[k] = val end
  return base_view(e)
end

local function row(id, active) return { quest_id = id, level = 5, active = active } end
local function offer(id, guid, icon)
  return { questgiver_guid = guid or GIVER, quest_id = id, icon = icon or 0,
    level = 5, title = "Q" .. id }
end
local function qg(id) return "quest-greeting:" .. id end
local function gq(id) return "gossip-quest:" .. id end

local function decide(v)
  clock = clock + 10.0
  return load().decide(v)
end

local function describe(step)
  if not step then return "nil" end
  return string.format("kind=%s reason=%s reference=%s control=%s",
    tostring(step.kind), tostring(step.reason), tostring(step.reference),
    tostring(step.control))
end

local function expect_press(v, reference, name)
  local step = decide(v)
  check(step and step.kind == "ui_press" and step.reference == reference,
    name, describe(step))
end

-- Greeting: decisive case. Unfinished A precedes ready B; both are offered
-- with usable controls. The legitimate answer is B.
local bothNodes = { node(qg(A)), node(qg(B)) }
expect_press(greeting({ row(A, true), row(B, true) }, bothNodes),
  qg(B), "greeting: ready B beats earlier unfinished A")

-- Greeting counterexamples: without a known ready row, behaviour is the
-- original first-active choice.
expect_press(greeting({ row(A, true), row(B, true) }, bothNodes,
  { completed_quest_ids = {} }),
  qg(A), "greeting: empty completion facts keep first active row")
do
  local v = greeting({ row(A, true), row(B, true) }, bothNodes)
  v.completed_quest_ids = nil
  expect_press(v, qg(A), "greeting: missing completion facts keep first active row")
end
expect_press(greeting({ row(A, true), row(B, true) }, bothNodes,
  { completed_quest_ids = { C } }),
  qg(A), "greeting: completed quest not offered here keeps first active row")
-- A completion fact is never a turn-in promise for an inactive row. With room
-- in the log that row is now taken as a new quest anyway, so an unknown log
-- (no new-quest pass) is what isolates the turn-in pass.
do
  local v = greeting({ row(N, false), row(A, true) },
    { node(qg(N)), node(qg(A)) }, { completed_quest_ids = { N } })
  v.accepted_quests = nil
  expect_press(v, qg(A),
    "greeting: completion fact on a new (inactive) row does not promote it")
end
expect_press(greeting({ row(N, false) }, { node(qg(N)) }),
  qg(N), "greeting: only a new quest row is still accepted")
expect_press(greeting({ row(B, true), row(A, true) }, bothNodes),
  qg(B), "greeting: ready row already first is unchanged")

-- Ready row with an unusable control: never press it; fall back to the
-- original choice rather than inventing a control.
expect_press(greeting({ row(A, true), row(B, true) }, { node(qg(A)) }),
  qg(A), "greeting: absent control for ready B falls back to A")
expect_press(greeting({ row(A, true), row(B, true) },
  { node(qg(A)), node(qg(B), false, true) }),
  qg(A), "greeting: disabled control for ready B falls back to A")
expect_press(greeting({ row(A, true), row(B, true) },
  { node(qg(A)), node(qg(B), true, false) }),
  qg(A), "greeting: non-hit-testable ready B falls back to A")
do
  local step = decide(greeting({ row(A, true), row(B, true) }, {}))
  check(step and step.kind == "ui_press" and step.reason == "nothing_offered",
    "greeting: no usable controls at all still says goodbye", describe(step))
end

-- Gossip: same shape through quest_offers for the open gossip giver.
local bothGossip = { node(gq(A)), node(gq(B)) }
expect_press(gossip({ offer(A), offer(B) }, bothGossip),
  gq(B), "gossip: ready B beats earlier unfinished A")
expect_press(gossip({ offer(A), offer(B) }, bothGossip,
  { completed_quest_ids = {} }),
  gq(A), "gossip: empty completion facts keep first offer")
expect_press(gossip({ offer(A), offer(C, 777) }, { node(gq(A)), node(gq(C)) },
  { completed_quest_ids = { C } }),
  gq(A), "gossip: ready quest offered by another giver is ignored")
expect_press(gossip({ offer(A), offer(B) }, { node(gq(A)) }),
  gq(A), "gossip: absent control for ready B falls back to A")

-- Available-new rows (ticket 0150 follow-up). Known-ready turn-in first, then
-- a genuinely new quest when the log has room, then the original first-active
-- fallback. An unfinished active row only reopens a progress panel that says
-- goodbye, so preferring it over a new row repeats forever.
local function full_log()
  local quests = {}
  for i = 1, 20 do
    quests[i] = { quest_id = 3000 + i, title = "F", level = 5, failed = false }
  end
  quests[1].quest_id = A
  return quests
end
local newNodes = { node(qg(A)), node(qg(N)) }

-- Corrected assumption: the tracked suite expected "active row still beats a
-- new quest row" (A). A is active but not in completed_quest_ids, i.e. known
-- unfinished; the legitimate progression is the new quest N.
expect_press(greeting({ row(N, false), row(A, true) },
  { node(qg(N)), node(qg(A)) }, { completed_quest_ids = {} }),
  qg(N), "greeting: new quest row beats a known-unfinished active row")
expect_press(greeting({ row(A, true), row(N, false) }, newNodes,
  { completed_quest_ids = {} }),
  qg(N), "available: unfinished A before new B -> new B")
expect_press(greeting({ row(A, true), row(N, false) }, newNodes),
  qg(N), "available: ready quest offered elsewhere does not block new B")
expect_press(greeting({ row(A, true), row(N, false), row(B, true) },
  { node(qg(A)), node(qg(N)), node(qg(B)) }),
  qg(B), "available: known-ready turn-in still beats new quest")
expect_press(greeting({ row(A, true), row(B, true), row(N, false) },
  { node(qg(A)), node(qg(B), false, true), node(qg(N)) }),
  qg(N), "available: unusable ready control -> new quest, not the dead control")

-- Full log keeps the original choice; the details panel still declines.
expect_press(greeting({ row(A, true), row(N, false) }, newNodes,
  { completed_quest_ids = {}, accepted_quests = full_log() }),
  qg(A), "available: full log keeps first active row")
do
  local v = base_view({ quest_frame = { open = true, panel = "details",
    npc_guid = GIVER, quest_id = N, greeting_rows = {}, choice_items = {} },
    accepted_quests = full_log(), completed_quest_ids = {} })
  local step = decide(v)
  check(step and step.control == "QuestFrameDeclineButton" and step.reason == "log_full",
    "available: full-log details still declines", describe(step))
  v.accepted_quests = { { quest_id = A, title = "A", level = 5, failed = false } }
  step = decide(v)
  check(step and step.control == "QuestFrameAcceptButton" and step.reason == "accept",
    "available: details with room accepts", describe(step))
end

-- Only offered, enabled, hit-testable controls.
expect_press(greeting({ row(A, true), row(N, false) }, { node(qg(A)) },
  { completed_quest_ids = {} }),
  qg(A), "available: absent new control falls back to A")
expect_press(greeting({ row(A, true), row(N, false) },
  { node(qg(A)), node(qg(N), false, true) }, { completed_quest_ids = {} }),
  qg(A), "available: disabled new control falls back to A")
expect_press(greeting({ row(A, true), row(N, false) },
  { node(qg(A)), node(qg(N), true, false) }, { completed_quest_ids = {} }),
  qg(A), "available: non-hit-testable new control falls back to A")
do
  local step = decide(greeting({ row(A, true), row(N, false) }, {},
    { completed_quest_ids = {} }))
  check(step and step.reason == "nothing_offered",
    "available: no usable controls still says goodbye", describe(step))
end

-- An inactive row already in the log is not new; a genuinely new one is.
expect_press(greeting({ row(A, true), row(C, false) },
  { node(qg(A)), node(qg(C)) },
  { completed_quest_ids = {}, accepted_quests = {
    { quest_id = A, title = "A", level = 5, failed = false },
    { quest_id = C, title = "C", level = 5, failed = false } } }),
  qg(A), "available: inactive row already accepted is not new")
expect_press(greeting({ row(A, true), row(C, false), row(N, false) },
  { node(qg(A)), node(qg(C)), node(qg(N)) },
  { completed_quest_ids = {}, accepted_quests = {
    { quest_id = A, title = "A", level = 5, failed = false },
    { quest_id = C, title = "C", level = 5, failed = false } } }),
  qg(N), "available: skips accepted inactive row for genuinely new one")

-- Unknown facts keep the original order (no false turn-in or capacity claim).
do
  local v = greeting({ row(A, true), row(N, false) }, newNodes)
  v.completed_quest_ids = nil
  expect_press(v, qg(A), "available: unknown completion keeps first active row")
  v = greeting({ row(A, true), row(N, false) }, newNodes,
    { completed_quest_ids = {} })
  v.accepted_quests = nil
  expect_press(v, qg(A), "available: unknown log keeps first active row")
end

-- Gossip: same distinction through accepted_quests identity (icons unused).
expect_press(gossip({ offer(A), offer(N) }, { node(gq(A)), node(gq(N)) },
  { completed_quest_ids = {} }),
  gq(N), "gossip: unfinished accepted A before new offer -> new")
expect_press(gossip({ offer(A), offer(N), offer(B) },
  { node(gq(A)), node(gq(N)), node(gq(B)) }),
  gq(B), "gossip: ready turn-in still beats new offer")
expect_press(gossip({ offer(A), offer(N) }, { node(gq(A)), node(gq(N)) },
  { completed_quest_ids = {}, accepted_quests = full_log() }),
  gq(A), "gossip: full log keeps first offer")
expect_press(gossip({ offer(A), offer(N) }, { node(gq(A)) },
  { completed_quest_ids = {} }),
  gq(A), "gossip: absent new control falls back to first offer")
expect_press(gossip({ offer(A), offer(N, 777) }, { node(gq(A)), node(gq(N)) },
  { completed_quest_ids = {} }),
  gq(A), "gossip: new offer from another giver is ignored")
do
  local v = gossip({ offer(A), offer(N) }, { node(gq(A)), node(gq(N)) })
  v.completed_quest_ids = nil
  expect_press(v, gq(A), "gossip: unknown completion keeps first offer")
end

-- Survival before a new-quest dialog too.
do
  local step = decide(greeting({ row(A, true), row(N, false) }, newNodes,
    { completed_quest_ids = {}, is_dead = true }))
  check(step and step.kind == "release",
    "available: death releases before new quest", describe(step))
end

-- Survival keeps precedence over any open dialog.
do
  local step = decide(greeting({ row(A, true), row(B, true) }, bothNodes,
    { is_dead = true }))
  check(step and step.kind == "release", "survival: death releases before dialog",
    describe(step))
  step = decide(greeting({ row(A, true), row(B, true) }, bothNodes,
    { resurrect_offer_guid = 55 }))
  check(step and step.kind == "accept_rez", "survival: rez offer before dialog",
    describe(step))
end

-- Unknown-ready rows (ticket 0154). completed_quest_ids names only quests
-- known ready; an accepted quest without objective rows (K) can be ready and
-- still absent there. Reopening the same first unfinished row forever hides
-- it, so a provider's progress panel without Complete moves the next visit on
-- to the following offered row. One module instance per scenario here, since
-- that memory is the behaviour under test.
local K, GIVER2 = 1004, 920
local function unknown_view(extra)
  local e = {
    accepted_quests = {
      { quest_id = A, title = "A", level = 5, failed = false },
      { quest_id = K, title = "K", level = 5, failed = false },
    },
    quest_objectives = {
      { quest_id = A, entry = 1, current = 5, required = 7, complete = false },
    },
    completed_quest_ids = {},
  }
  for k, val in pairs(extra or {}) do e[k] = val end
  return e
end
local function ugreeting(rows, nodes, extra, npc)
  local v = greeting(rows, nodes, unknown_view(extra))
  v.quest_frame.npc_guid = npc or GIVER
  v.open_quest_dialog_guid = npc or GIVER
  return v
end
local function panel(kind, questId, canComplete, extra, npc)
  local e = unknown_view(extra)
  e.quest_frame = { open = true, panel = kind, npc_guid = npc or GIVER,
    quest_id = questId, can_complete = canComplete, greeting_rows = {},
    choice_items = {} }
  e.open_quest_dialog_guid = npc or GIVER
  return base_view(e)
end
local function step_in(m, v)
  clock = clock + 1.0
  return m.decide(v)
end
local function press_in(m, v, reference, name)
  local step = step_in(m, v)
  check(step and step.kind == "ui_press" and step.reference == reference,
    name, describe(step))
  return step
end
local function control_in(m, v, control, name)
  local step = step_in(m, v)
  check(step and step.kind == "ui_press" and step.control == control,
    name, describe(step))
  return step
end
local AK = { row(A, true), row(K, true) }
local akNodes = { node(qg(A)), node(qg(K)) }
-- Probe A once at GIVER and see it unfinished.
local function probe_a(m, extra, npc)
  press_in(m, ugreeting(AK, akNodes, extra, npc), qg(A), "unknown: first visit opens A")
  control_in(m, panel("progress", A, false, extra, npc), "QuestFrameGoodbyeButton",
    "unknown: unfinished A says goodbye")
end

-- Decisive: unfinished A first, unknown-ready K second, then the real turn-in.
do
  local m = load()
  probe_a(m)
  press_in(m, ugreeting(AK, akNodes), qg(K),
    "unknown: after unfinished A the next visit opens K")
  control_in(m, panel("progress", K, true), "QuestFrameCompleteButton",
    "unknown: K progress with Complete offered completes")
  control_in(m, panel("reward", K, false), "QuestFrameCompleteQuestButton",
    "unknown: K reward panel turns in")
  -- The turn-in itself changes the facts, so A is asked again afterwards.
  press_in(m, ugreeting(AK, akNodes, { rewarded_quest_ids = { K } }), qg(A),
    "unknown: a reward fact reopens the provider's first row")
end
-- Same flow through gossip quest offers.
do
  local m = load()
  local offers = { offer(A), offer(K) }
  local nodes = { node(gq(A)), node(gq(K)) }
  local function gv() return gossip(offers, nodes, unknown_view()) end
  press_in(m, gv(), gq(A), "unknown gossip: first visit opens A")
  control_in(m, panel("progress", A, false), "QuestFrameGoodbyeButton",
    "unknown gossip: unfinished A says goodbye")
  press_in(m, gv(), gq(K), "unknown gossip: next visit opens K")
end
-- Progress panel without a projected quest id falls back to the row pressed.
do
  local m = load()
  press_in(m, ugreeting(AK, akNodes), qg(A), "unknown: press A (id-less panel)")
  control_in(m, panel("progress", 0, false), "QuestFrameGoodbyeButton",
    "unknown: id-less unfinished panel says goodbye")
  press_in(m, ugreeting(AK, akNodes), qg(K),
    "unknown: id-less panel still moves on to K")
end

-- Priorities are unchanged by the memory.
do
  local m = load()
  press_in(m, ugreeting(AK, akNodes, { completed_quest_ids = { K } }), qg(K),
    "unknown: known-ready K wins on the first visit")
end
do
  local m = load()
  probe_a(m)
  press_in(m, ugreeting({ row(A, true), row(K, true), row(N, false) },
    { node(qg(A)), node(qg(K)), node(qg(N)) }), qg(N),
    "unknown: a new quest still beats probing K")
end

-- Every offered active row unfinished: leave, and let normal work run.
do
  local m = load()
  probe_a(m)
  press_in(m, ugreeting(AK, akNodes), qg(K), "unknown: all-unready opens K")
  control_in(m, panel("progress", K, false), "QuestFrameGoodbyeButton",
    "unknown: unfinished K says goodbye")
  local step = step_in(m, ugreeting(AK, akNodes))
  check(step and step.kind == "ui_press" and
      step.control == "QuestFrameGreetingGoodbyeButton" and
      step.reason == "nothing_offered",
    "unknown: all rows unfinished leaves instead of reopening A", describe(step))
  -- The provider is exhausted: a reward marker does not pull the seat back.
  local closed = base_view(unknown_view({
    quest_markers = { { questgiver_guid = GIVER, status = 7 } } }))
  step = step_in(m, closed)
  check(not (step and step.kind == "interact" and step.guid == GIVER),
    "unknown: exhausted provider is not re-interacted", describe(step))
end
-- Full log: nothing new can be taken, so an unfinished A is not reopened.
do
  local m = load()
  local quests = full_log()
  quests[2] = { quest_id = K, title = "K", level = 5, failed = false }
  local extra = { accepted_quests = quests }
  local rows = { row(A, true), row(K, true), row(N, false) }
  local nodes = { node(qg(A)), node(qg(K)), node(qg(N)) }
  press_in(m, ugreeting(rows, nodes, extra), qg(A), "unknown: full log opens A first")
  control_in(m, panel("progress", A, false, extra), "QuestFrameGoodbyeButton",
    "unknown: full log unfinished A says goodbye")
  press_in(m, ugreeting(rows, nodes, extra), qg(K),
    "unknown: full log still probes K, never the new row")
  control_in(m, panel("progress", K, false, extra), "QuestFrameGoodbyeButton",
    "unknown: full log unfinished K says goodbye")
  local step = step_in(m, ugreeting(rows, nodes, extra))
  check(step and step.reason == "nothing_offered",
    "unknown: full log with every active row unfinished leaves", describe(step))
end

-- Memory is invalidated by real changes, never permanent.
do
  local m = load()
  probe_a(m)
  press_in(m, ugreeting(AK, akNodes, { quest_objectives = {
      { quest_id = A, entry = 1, current = 6, required = 7, complete = false } } }),
    qg(A), "unknown: objective progress reopens A")
end
do
  local m = load()
  probe_a(m)
  press_in(m, ugreeting(AK, akNodes, { completed_quest_ids = { A } }), qg(A),
    "unknown: A known ready reopens A")
end
do
  local m = load()
  probe_a(m)
  press_in(m, ugreeting({ row(A, true), row(K, true), row(C, true) },
    { node(qg(A)), node(qg(K)), node(qg(C)) }), qg(A),
    "unknown: changed offered rows reopen A")
end
do
  local m = load()
  probe_a(m)
  clock = clock + 241.0
  press_in(m, ugreeting(AK, akNodes), qg(A), "unknown: memory expires after the hub cooldown")
end
do
  local m = load()
  probe_a(m)
  press_in(m, ugreeting(AK, akNodes, nil, GIVER2), qg(A),
    "unknown: another provider is not affected")
  m.reset()
  press_in(m, ugreeting(AK, akNodes), qg(A), "unknown: reset forgets")
end

-- Controls stay truthful.
do
  local m = load()
  probe_a(m)
  local step = step_in(m, ugreeting(AK, { node(qg(A)), node(qg(K), false, true) }))
  check(step and step.control == "QuestFrameGreetingGoodbyeButton" and
      step.reason == "nothing_offered",
    "unknown: disabled K after unfinished A leaves, never presses either", describe(step))
  m = load()
  probe_a(m)
  step = step_in(m, ugreeting(AK, { node(qg(A)) }))
  check(step and step.control == "QuestFrameGreetingGoodbyeButton",
    "unknown: missing K control after unfinished A leaves", describe(step))
  m = load()
  press_in(m, ugreeting(AK, { node(qg(A), true, false), node(qg(K)) }), qg(K),
    "unknown: unusable A control on a fresh visit opens K")
  m = load()
  step = step_in(m, ugreeting(AK, {}))
  check(step and step.reason == "nothing_offered",
    "unknown: no controls at all still says goodbye", describe(step))
end
-- A details panel (new quest) is never remembered as unfinished.
do
  local m = load()
  control_in(m, panel("details", A, false), "QuestFrameAcceptButton",
    "unknown: details panel still accepts")
  press_in(m, ugreeting(AK, akNodes), qg(A), "unknown: details leaves no memory")
end
-- Quests disabled: the dialog code is not reached at all.
do
  package.loaded["accelerated"] = nil
  local m = require("accelerated")
  m.set_quests(false)
  m.set_quest_hubs({})
  local step = step_in(m, ugreeting(AK, akNodes))
  check(not (step and (step.reason == "greeting_row" or
      step.reason == "nothing_offered")),
    "unknown: quests disabled leaves the dialog to the default league path",
    describe(step))
end

print(string.format("test_dialog_priority: passed=%d failed=%d", passed, failed))
os.exit(failed == 0 and 0 or 1)
