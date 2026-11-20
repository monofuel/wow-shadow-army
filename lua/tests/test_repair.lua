-- Original synthetic maintenance facts. These fixtures never repair a realm.
require("tests.lifecycle_fixture")
_G.wow = { log = function() end, time = function() return 0 end }
local life = require("tools.lifecycle")
local requests = require("tools.requests")
local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local function view(extra)
  local v = { repair_supported = true, repair_quote_supported = true,
    equipped_durability_known = true, copper_known = true, copper = 20,
    location = { map_id = 0, position = { x = 0, y = 0, z = 0 } },
    units = { { guid = 9001, services = { "vendor", "repair" }, distance = 10,
      health_known = true, health = 50, location = { map_id = 0, position = { x = 10, y = 0, z = 0 } } } },
    equipment_items = { { item_guid = 11, durability_known = true,
      max_durability_known = true, durability = 0, max_durability = 20 } } }
  for k, value in pairs(extra or {}) do v[k] = value end
  return v
end
local function opened(extra)
  local v = view(extra)
  v.merchant_open, v.merchant_guid, v.merchant_can_repair = true, 9001, true
  v.repair_all_cost_known, v.repair_all_cost = true, 7
  return v
end
local function fixed(copper)
  local v = opened({ copper = copper })
  v.equipment_items[1].durability = 20
  return v
end

local st = life.new_state()
check(life.repair_needed(view(), true), "known broken equipment is critical")
local worn = view(); worn.equipment_items[1].durability = 10
check(not life.repair_needed(worn, true) and life.repair_needed(worn, false),
  "ordinary wear is not an automatic broken-gear trip")
local go = life.repair_step(view(), st, 0, false)
check(go.kind == "interact" and go.guid == 9001, "walk to the observed repair service")
go = life.repair_step(opened(), st, 1, false)
check(go.kind == "repair_all" and go.guid == 9001, "repair only the exact open vendor")
go = life.repair_step(opened(), st, 2, false)
check(go.kind == "hold", "one submitted repair waits for an actual effect")
local _, outcome = life.repair_step(fixed(13), st, 3, false)
check(outcome.result == "complete" and outcome.paid == 7, "same items restored and normal payment confirmed")

st = life.new_state()
life.repair_step(opened(), st, 0, false)
_, outcome = life.repair_step(fixed(20), st, 7, false)
check(outcome.result == "incomplete", "durability alone does not prove expected payment")
st = life.new_state()
life.repair_step(opened(), st, 0, false)
_, outcome = life.repair_step(opened(), st, 7, false)
check(outcome.result == "incomplete", "unchanged items and input success do not prove repair")

st = life.new_state()
local unknown = view(); unknown.equipped_durability_known = false
_, outcome = life.repair_step(unknown, st, 0, false)
check(outcome.result == "blocked", "unknown durability is not healthy gear")
unknown = opened(); unknown.repair_all_cost_known = false
go = life.repair_step(unknown, st, 0, false)
check(go.kind == "hold", "unknown quote is never free")
_, outcome = life.repair_step(unknown, st, 11, false)
check(outcome.result == "blocked", "unknown quote wait is bounded")
st = life.new_state()
_, outcome = life.repair_step(opened({ copper = 6 }), st, 0, false)
check(outcome.result == "blocked", "cannot spend money the character does not have")
st = life.new_state()
local other = opened(); other.merchant_guid = 9002
check(life.repair_step(other, st, 0, false).kind == "interact", "a different open merchant is not used")
st = life.new_state()
check(life.repair_step(view({ in_combat = true }), st, 0, false) == nil, "combat is not interrupted")
check(life.repair_step(view({ active_channel_spell_id = 9010 }), st, 0, false) == nil,
  "an actual channel is not walked off")

-- Grace for a quote or repair capability starts at the first matching open
-- window, not at the start of a long walk.
st = life.new_state()
check(life.repair_step(view(), st, 0, false).kind == "interact", "long walk starts")
local slow = opened(); slow.repair_all_cost_known = false
check(life.repair_step(slow, st, 30, false).kind == "hold", "first open frame after a long walk still waits")
check(life.repair_step(slow, st, 39, false).kind == "hold", "quote wait counts from the open window")
_, outcome = life.repair_step(slow, st, 41, false)
check(outcome.result == "blocked", "quote wait after the window opened is bounded")
st = life.new_state()
life.repair_step(view(), st, 0, false)
local flag = opened(); flag.merchant_can_repair = false
check(life.repair_step(flag, st, 20, false).kind == "hold", "a briefly false repair flag is tolerated")
check(life.repair_step(opened(), st, 22, false).kind == "repair_all", "the flag settling allows the repair")
st = life.new_state()
life.repair_step(view(), st, 0, false)
life.repair_step(flag, st, 20, false)
_, outcome = life.repair_step(flag, st, 31, false)
check(outcome.result == "blocked", "a vendor that never offers repair is a bounded blocker")

-- A submitted repair settles before the generic visit timeout.
st = life.new_state()
life.repair_step(view(), st, 0, false)
check(life.repair_step(opened(), st, 88, false).kind == "repair_all", "repair submitted late in the visit")
_, outcome = life.repair_step(fixed(13), st, 92, false)
check(outcome.result == "complete" and outcome.paid == 7, "late payment is confirmed, not timed out")

-- An explicit repair after a stop mid-travel starts a fresh visit.
st = life.new_state()
life.repair_step(view(), st, 0, false)
life.request_repair(st, 200)
check(st.repair_visit == nil, "an unsent travel visit is not inherited")
check(life.repair_step(view(), st, 200, false).kind == "interact", "new request walks again")
check(life.repair_step(opened(), st, 250, false).kind == "repair_all", "new visit is timed from the new request")

-- A submitted repair is reconciled by the next request, never paid twice.
st = life.new_state()
life.repair_step(opened(), st, 1, false)
life.request_repair(st, 3)
check(life.repair_step(opened(), st, 3, false).kind == "hold", "a settling repair is adopted, not resent")
_, outcome = life.repair_step(fixed(13), st, 4, false)
check(outcome.result == "complete" and outcome.paid == 7, "adopted pending repair confirms its payment")
st = life.new_state()
life.repair_step(opened(), st, 1, false)
life.request_repair(st, 100)
_, outcome = life.repair_step(fixed(13), st, 100, false)
check(outcome.result == "complete" and outcome.paid == 7, "an old submitted repair that took effect is credited")
st = life.new_state()
life.repair_step(opened(), st, 1, false)
life.request_repair(st, 100)
go, outcome = life.repair_step(fixed(20), st, 100, false)
check(go == nil and outcome.result == "incomplete", "restored gear without the expected payment is not repaid")
st = life.new_state()
life.repair_step(opened(), st, 1, false)
life.request_repair(st, 100)
go = life.repair_step(opened(), st, 100, false)
check(go.kind == "repair_all" and st.repair_visit.since == 100,
  "an earlier submission with no effect on items or copper is replaced by a fresh visit")
st = life.new_state()
life.repair_step(opened(), st, 1, false)
life.request_repair(st, 100)
_, outcome = life.repair_step(opened({ copper = 15 }), st, 100, false)
check(outcome.result == "incomplete", "unexplained copper movement is never treated as unpaid")

-- Host repair results. nav_progress reports how the previous decide's intent
-- ended; perf.decision_count says which decide that was.
local plain_wow = _G.wow
local host = { decision = 0, nav = "idle" }
_G.wow = { log = function() end, time = function() return 0 end,
  perf = function() return { decision_count = host.decision } end,
  nav_progress = function() return { state = host.nav } end }
local function host_ends(nav) host.decision, host.nav = host.decision + 1, nav end

-- A repair right after a sale or equip is held by the host's item verb window.
st = life.new_state()
check(life.repair_step(opened(), st, 1, false).kind == "repair_all", "first ask after a recent item verb")
host_ends("repair_verb_deferred")
go = life.repair_step(opened({ copper = 20 }), st, 1.1, false)
check(go.kind == "repair_all" and st.repair_visit.submitted == 1.1,
  "a deferred ask sent nothing, so the window asks again")
host_ends("repair_verb_issued")
check(life.repair_step(opened(), st, 1.2, false).kind == "hold", "an issued ask waits for an effect")
host_ends("held")
_, outcome = life.repair_step(fixed(13), st, 2, false)
check(outcome.result == "complete" and outcome.paid == 7, "the retried repair is paid once and confirmed")

-- An issued ask with no effect is not success.
st = life.new_state()
life.repair_step(opened(), st, 0, false)
host_ends("repair_verb_issued")
check(life.repair_step(opened(), st, 0.1, false).kind == "hold", "issued is not completion")
_, outcome = life.repair_step(opened(), st, 7, false)
check(outcome.result == "incomplete", "an issued verb without durability or payment is incomplete")

-- A host without repair results keeps the ask submitted and unproven.
st = life.new_state()
life.repair_step(opened(), st, 0, false)
host_ends("repair")
check(life.repair_step(opened(), st, 0.1, false).kind == "hold", "an unknown result is not retracted")
_, outcome = life.repair_step(opened(), st, 7, false)
check(outcome.result == "incomplete", "an unknown result never becomes success")

-- A deferral read later than the next decide may describe another intent.
st = life.new_state()
life.repair_step(opened(), st, 0, false)
host.decision, host.nav = host.decision + 2, "repair_verb_deferred"
check(life.repair_step(opened(), st, 0.2, false).kind == "hold", "a stale deferral is not trusted")

-- Without the decision count the result cannot be tied to the ask.
st = life.new_state()
_G.wow.perf = nil
life.repair_step(opened(), st, 0, false)
host_ends("repair_verb_deferred")
check(life.repair_step(opened(), st, 0.1, false).kind == "hold", "an unattributable deferral stays submitted")
_G.wow.perf = function() return { decision_count = host.decision } end

-- A deferred ask whose merchant window closed walks back without a submission.
st = life.new_state()
life.repair_step(opened(), st, 0, false)
host_ends("repair_verb_deferred")
check(life.repair_step(view(), st, 0.1, false).kind == "interact", "a closed window reopens first")
check(st.repair_visit.submitted == nil, "a deferred ask records no submission")
life.request_repair(st, 0.2)
check(st.repair_visit == nil, "a new request drops a visit that never sent a repair")

-- Fast decides keep asking through the host's whole hold window; the number
-- of held asks is not itself a failure.
st = life.new_state()
local asks = 0
go = life.repair_step(opened(), st, 0, false)
for tick = 1, 200 do
  if go.kind == "repair_all" then asks = asks + 1 end
  host_ends(tick * 0.005 < 0.6 and "repair_verb_deferred" or "repair_verb_issued")
  go = life.repair_step(opened(), st, tick * 0.005, false)
  if go.kind == "hold" then break end
end
check(go.kind == "hold" and asks > 100, "a fast seat outlasts the hold window by asking again")
host_ends("held")
_, outcome = life.repair_step(fixed(13), st, 1, false)
check(outcome.result == "complete" and outcome.paid == 7, "the repair issued after many held asks is paid once")

-- A window that never opens ends at the visit deadline with nothing spent.
st = life.new_state()
local now, reasked = 0, true
go, outcome = life.repair_step(opened(), st, now, false)
while go do
  reasked = reasked and go.kind == "repair_all"
  host_ends("repair_verb_deferred")
  now = now + 0.1
  go, outcome = life.repair_step(opened(), st, now, false)
end
check(reasked, "every held ask asks again")
check(outcome.result == "incomplete" and outcome.why == "repair visit timed out" and
  outcome.paid == nil and now > 90 and now < 90.2,
  "a permanently deferred repair stops at the visit deadline")
_G.wow = plain_wow

local dir = os.tmpname(); os.remove(dir); assert(os.execute("mkdir -p " .. dir))
local function write_job(key, choice)
  local f = assert(io.open(dir .. "/inbox.json", "w"))
  f:write('{"protocol":"wow_shadow_army.private_request.v1","key":"' .. key ..
    '","origin":"operator","actor":"operator","intent":"action","choice":"' .. choice .. '"}')
  f:close()
end
st = life.new_state()
local rs = requests.new(dir)
local ctx = { life = life, lstate = st, fighting = false }
write_job("repair1", "repair_gear")
check(requests.step(view(), rs, 0, ctx).kind == "interact", "durable repair request uses the shared lifecycle")
check(requests.step(opened(), rs, 2, ctx).kind == "repair_all", "request issues an ordinary repair")
requests.step(fixed(13), rs, 4, ctx)
local f = assert(io.open(dir .. "/receipts.jsonl")); local body = f:read("*a"); f:close()
check(body:find('"state":"done"', 1, true) and body:find('"paid":"7"', 1, true),
  "done receipt requires changed items and payment")
write_job("stay1", "hold_here")
check(requests.step(view(), rs, 6, ctx).reason == "request_hold", "owner stay still wins over maintenance")
write_job("repair2", "repair_gear")
check(requests.step(view(), rs, 10, ctx).kind == "interact", "second repair request walks")
write_job("stay2", "hold_here")
check(requests.step(view(), rs, 12, ctx).reason == "request_hold", "stay replaces a repair mid-travel")
write_job("repair3", "repair_gear")
check(requests.step(view(), rs, 300, ctx).kind == "interact",
  "a repair after stay mid-travel does not inherit the stale visit")
check(requests.step(opened(), rs, 302, ctx).kind == "repair_all", "the new request still repairs")
requests.step(fixed(13), rs, 304, ctx)
f = assert(io.open(dir .. "/receipts.jsonl")); body = f:read("*a"); f:close()
check(body:find('"key":"repair3","choice":"repair_gear","origin":"operator","actor":"operator","state":"done"', 1, true) and
  not body:find('"key":"repair3","choice":"repair_gear","origin":"operator","actor":"operator","state":"failed"', 1, true),
  "the new request completes instead of failing on the old visit")
os.execute("rm -rf " .. dir)
print("test_repair: " .. checks .. " checks passed")
