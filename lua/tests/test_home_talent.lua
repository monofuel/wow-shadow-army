-- home.lua talent step while Murist is grouped but out of sight or offline.
-- Synthetic ids only (tabs 901-903, talents 9xxx); no real talent table.
local progress = { state = "idle" }
wow = {
  time = function() return 100 end,
  nav_progress = function() return { state = "idle" } end,
  log = function() end,
  set_status = function() end,
  talent_progress = function() return progress end,
}
package.preload["config.talent_builds_private"] = function()
  return { [1] = { [2] = { "30000", "", "50000" } } }
end

require("tests.lifecycle_fixture")
-- Owner requests run from a private temporary seat directory.
local requests = require("tools.requests")
local jobs = os.tmpname()
os.remove(jobs)
os.execute("mkdir -p " .. jobs)
requests.from_env = function() return requests.new(jobs) end
local home = require("home")
home.set_roads({})

local checks = 0
local function check(ok, label) assert(ok, label); checks = checks + 1 end

local function member(guid, name)
  return {
    guid = guid, name = name, health_known = true, health = 100,
    max_health = 100, level_known = true, level = 12,
    death_state_known = true, is_dead = false, is_ghost = false,
    active_auras_known = true, active_aura_spell_ids = {},
    location_known = false,
  }
end

-- A warrior seat grouped with an offline Murist and one banked point whose
-- observed build (tab position 2) wants talent 9301 raised past rank 1.
local function frame(extra)
  local murist = member(100, "Murist")
  murist.leader = true
  local v = {
    simulation_time = 100, player_guid = 200, class_id = 1, level = 12,
    location_known = true,
    location = { map_id = 0, position = { x = 0, y = 0, z = 0 } },
    health_known = true, health = 100, max_health = 100,
    powers = { 100, 0, 0, 0, 0 }, max_powers = { 100, 0, 0, 0, 0 },
    active_aura_spell_ids = {},
    is_dead = false, is_ghost = false, can_reclaim_corpse = false,
    resurrect_offer_guid = 0,
    in_combat = false, selected_target_guid = 0, auto_attack_guid = 0,
    active_cast_spell_id = 0, active_channel_spell_id = 0,
    party = {
      in_group = true, leader_guid = 100, leader_name = "Murist",
      invite_pending = false, invite_from = "",
      members = { member(200, "Shadowfel"), murist },
    },
    units = {}, spell_facts = {}, action_buttons = {}, quest_objectives = {},
    learn_talent_supported = true, talent_points_known = true,
    unspent_talent_points = 1, talent_tab_points_known = true,
    talent_tab_points = { 0, 0, 1 },
    talent_tabs = { { tab_id = 901 }, { tab_id = 902 }, { tab_id = 903 } },
    talent_ranks = { { talent_id = 9301, rank = 1 } },
    talent_choices = { { tab_id = 903, talent_id = 9301, talent_index = 0, rank = 1 } },
  }
  for k, val in pairs(extra or {}) do v[k] = val end
  return v
end

-- Decide `ticks` frames at one-second steps; returns every intent.
-- `drop` names a view field the host does not send at all.
local function run(extra, ticks, drop)
  home.reset()
  local out = {}
  for i = 1, ticks do
    local v = frame(extra)
    if drop then v[drop] = nil end
    v.simulation_time = 100 + i
    out[i] = home.decide(v)
  end
  return out
end

local function any_talent(out)
  for _, r in ipairs(out) do
    if r.kind == "learn_talent" then return true end
  end
  return false
end

-- Movement keeps precedence: the fidget leg first, then the banked point.
local out = run(nil, 3)
check(out[1].kind == "navigate" and out[1].reason == "formation_fidget",
  "the formation fidget still runs before any talent")
check(out[2].kind == "learn_talent" and out[2].talent_id == 9301 and
  out[2].rank == 1 and out[2].reason == "talent_observed_build",
  "an offline owner no longer banks a planned point forever")
check(out[2].status.mode == "escort" and out[2].status.murist_visible == false,
  "the talent leg reports the escort hold it replaced")
check(out[3].kind == "learn_talent" and out[3].talent_id == 9301,
  "the pending request repeats until the observed rank moves")

-- Old hosts stay inert: no capability, nil or false.
out = run({ learn_talent_supported = false }, 4)
check(not any_talent(out) and out[4].reason == "hold_for_murist",
  "a host reporting no capability keeps the plain offline-owner hold")
out = run(nil, 4, "learn_talent_supported")
check(not any_talent(out) and out[4].reason == "hold_for_murist",
  "an older host without the field keeps the plain offline-owner hold")

-- Nothing to spend, or nothing planned: hold and report why.
out = run({ unspent_talent_points = 0 }, 3)
check(not any_talent(out) and out[3].reason == "hold_for_murist",
  "zero banked points holds")
out = run({ talent_choices = { { tab_id = 903, talent_id = 9399,
  talent_index = 4, rank = 0 } } }, 3)
check(not any_talent(out) and out[3].reason == "hold_for_murist" and
  out[3].status.talent.reason == "no_planned_choice_observed",
  "an unplanned observed choice is never spent")
out = run({ talent_points_known = false }, 3)
check(not any_talent(out), "unknown points do nothing")

-- Casting, channelling and fighting all outrank the talent frame.
out = run({ active_channel_spell_id = 9902 }, 3)
check(not any_talent(out) and out[3].reason == "finish_active_cast",
  "an active channel is finished, not interrupted")
out = run({ active_cast_spell_id = 9901 }, 3)
check(not any_talent(out) and out[3].reason == "finish_active_cast",
  "an active cast is finished first")
out = run({ in_combat = true }, 3)
check(not any_talent(out), "combat never opens the talent frame")
out = run({ is_dead = true, health = 0 }, 3)
check(not any_talent(out), "a dead seat recovers instead")

-- A walkable roster position is a rejoin, never a talent stop.
local far = member(100, "Murist")
far.leader = true
far.location_known, far.elevation_known = true, true
far.location = { map_id = 0, x = 400, y = 0, z = 0, o = 0 }
out = run({ party = { in_group = true, leader_guid = 100, leader_name = "Murist",
  invite_pending = false, invite_from = "",
  members = { member(200, "Shadowfel"), far } } }, 3)
check(not any_talent(out) and out[3].kind == "navigate",
  "a reachable owner is rejoined before any point is spent")

-- The acknowledgement comes from the observed rank, then the seat holds.
home.reset()
local v = frame()
v.simulation_time = 101
home.decide(v)
v.simulation_time = 102
check(home.decide(v).kind == "learn_talent", "request sent while idle")
v = frame({ unspent_talent_points = 0, talent_tab_points = { 0, 0, 2 },
  talent_ranks = { { talent_id = 9301, rank = 2 } },
  talent_choices = { { tab_id = 903, talent_id = 9301, talent_index = 0, rank = 2 } } })
v.simulation_time = 103
local r = home.decide(v)
check(r.kind == "hold" and r.reason == "hold_for_murist" and
  r.status.talent.state == "learned", "observed rank acknowledges, then holds")

-- An accepted owner request outranks the idle talent step.
local f = assert(io.open(jobs .. "/inbox.json", "w"))
f:write('{"key":"t1","origin":"whisper","actor":"Murist","actor_guid":"100",' ..
  '"choice":"hold_here","intent":"action","reply":"","x":0,"y":0,"z":0,"map_id":0}\n')
f:close()
-- Later clock: the request inbox polls on its own interval.
home.reset()
out = {}
for i = 1, 3 do
  v = frame()
  v.simulation_time = 1000 + i
  out[i] = home.decide(v)
end
check(not any_talent(out) and out[3].kind == "hold" and out[3].reason == "request_hold",
  "an explicit hold request keeps precedence over a banked point")
os.execute("rm -rf " .. jobs)

print("test_home_talent: " .. checks .. " checks passed")
