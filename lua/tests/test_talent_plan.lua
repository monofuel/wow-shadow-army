-- Synthetic ids only (tabs 901-903, talents 9xxx); no real talent table.
local progress = { state = "idle" }
wow = { talent_progress = function() return progress end }
-- Tiny synthetic preferences; no copied game/private build catalog.
package.preload["config.talent_builds_private"] = function()
  return { [1] = {
    [0] = { "35000", "", "" },
    [2] = { "30000", "", "50000" },
  } }
end
local plan = require("tools.talent_plan")

local checks = 0
local function check(ok, label) assert(ok, label); checks = checks + 1 end

local function view(o)
  local v = {
    learn_talent_supported = true, class_id = 1, in_combat = false,
    talent_points_known = true, unspent_talent_points = 1,
    talent_tab_points_known = true, talent_tab_points = { 0, 0, 0 },
    talent_tabs = { { tab_id = 901 }, { tab_id = 902 }, { tab_id = 903 } },
    talent_ranks = {},
    -- Synthetic Protection plan: index 0 wants 5, index 4 wants 0.
    talent_choices = {
      { tab_id = 901, talent_id = 9001, talent_index = 0, rank = 0 },
      { tab_id = 903, talent_id = 9304, talent_index = 4, rank = 0 },
      { tab_id = 903, talent_id = 9301, talent_index = 0, rank = 0 },
    },
  }
  for k, val in pairs(o or {}) do v[k] = val end
  return v
end

-- Tank role with no spent points: Protection (tab position 2), tier order.
local s = plan.new_state()
local i = plan.step(view(), s, 0, "tank")
check(i and i.kind == "learn_talent" and i.talent_id == 9301 and i.rank == 0,
  "tank picks the planned Protection choice, not an unplanned one")
-- Pending: same request repeats (idempotent) until the observed rank moves.
check(plan.step(view(), s, 1, "tank").talent_id == 9301, "pending request repeats")
-- Ack by observed rank, then the next point only once unspent is back.
local acked = view({ unspent_talent_points = 0,
  talent_ranks = { { talent_id = 9301, rank = 1 } }, talent_tab_points = { 0, 0, 1 } })
check(plan.step(acked, s, 2, "tank") == nil and plan.status(acked, s).state == "learned",
  "observed rank acknowledges; no banked-point loop at zero unspent")
-- A human Arms build wins over the tank default.
local human = plan.new_state()
local hv = view({ talent_tab_points = { 3, 0, 0 },
  talent_ranks = { { talent_id = 9001, rank = 3 } },
  -- Synthetic Arms plan: index 0 is complete at 3, index 1 wants 5.
  talent_choices = { { tab_id = 901, talent_id = 9001, talent_index = 0, rank = 3 },
    { tab_id = 901, talent_id = 9002, talent_index = 1, rank = 0 },
    { tab_id = 903, talent_id = 9301, talent_index = 0, rank = 0 } } })
local hi = plan.step(hv, human, 0, "tank")
check(hi and hi.talent_id == 9002 and hi.rank == 0, "an existing human build keeps its tree")
-- No planned choice observed: bank the point and report the gap.
local gap = plan.new_state()
check(plan.step(view({ talent_choices = { { tab_id = 903, talent_id = 9304,
  talent_index = 4, rank = 0 } } }), gap, 0, "tank") == nil and
  plan.status(view(), gap).reason == "no_planned_choice_observed",
  "an unplanned choice is never spent")
-- Unknown points and an old host stay inert.
check(plan.step(view({ talent_points_known = false }), plan.new_state(), 0, "tank") == nil,
  "unknown points do nothing")
check(plan.step(view({ learn_talent_supported = false }), plan.new_state(), 0, "tank") == nil,
  "an older host is untouched")
check(plan.step(view({ in_combat = true }), plan.new_state(), 0, "tank") == nil,
  "combat yields to the fight")
check(plan.step(view({ active_cast_spell_id = 9901 }), plan.new_state(), 0, "tank") == nil,
  "an active cast finishes first")
-- A channel must not be broken by the talent frame, pending request included.
local channel = plan.new_state()
plan.step(view(), channel, 0, "tank")
check(plan.step(view({ active_channel_spell_id = 9902 }), channel, 1, "tank") == nil and
  channel.pending ~= nil, "an active channel pauses even a pending request")
check(plan.step(view(), channel, 2, "tank").talent_id == 9301,
  "the pending request resumes once the channel ends")
local absent = view()
-- A valid partially allocated human tree may be absent from a local plan.
-- Preserve that build and bank the point rather than indexing a nil table.
local missing = plan.new_state()
local ok_missing, missing_intent = pcall(plan.step,
  view({ talent_tab_points = { 0, 1, 0 } }), missing, 0, "tank")
check(ok_missing and missing_intent == nil, "a missing observed-tree profile never crashes")
check(plan.status(view(), missing).reason == "no_plan_for_observed_tree",
  "a missing profile reports its gap without spending")
absent.learn_talent_supported = nil
check(plan.step(absent, plan.new_state(), 0, "tank") == nil,
  "a host without the capability field is untouched")
-- Host blocked: back off instead of re-asking every tick.
local blocked = plan.new_state()
plan.step(view(), blocked, 0, "tank")
progress = { state = "blocked", reason = "not an observed learnable talent choice",
  talent_id = 9301, rank = 0 }
check(plan.step(view(), blocked, 1, "tank") == nil and
  plan.status(view(), blocked).reason == "not an observed learnable talent choice",
  "a host refusal is reported, not marked spent")
check(plan.step(view(), blocked, 30, "tank") == nil, "the refused choice backs off")
progress = { state = "idle" }
check(plan.step(view(), blocked, 62, "tank").talent_id == 9301, "and is retried after the backoff")
-- No acknowledgement at all: abandoned as stale.
local stale = plan.new_state()
plan.step(view(), stale, 0, "tank")
check(plan.step(view(), stale, 50, "tank") == nil and
  plan.status(view(), stale).state == "stale", "a silent request goes stale")
-- A host retry wait needs the same intent again to re-evaluate its deadline.
progress = { state = "idle" }
local retry = plan.new_state()
plan.step(view(), retry, 0, "tank")
progress = { state = "retry_wait", talent_id = 9301, rank = 0 }
check(plan.step(view(), retry, 1, "tank").talent_id == 9301,
  "retry_wait re-polls the idempotent host instead of deadlocking")
check(plan.step(view(), retry, 50, "tank") == nil and
  plan.status(view(), retry).state == "stale", "retry_wait still has a stale bound")
print("test_talent_plan: " .. checks .. " checks passed")
