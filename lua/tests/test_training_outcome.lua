-- Training outcomes are settled by the world: an exact trainer frame with no
-- affordable level-legal offer left and the offered spells in known_spells.
-- Startup, an absent trainer, a timeout or a lost frame settle nothing and
-- are retried a bounded number of times. Views carry only the fields the
-- lua-bot view projects (trainer_open/trainer_guid/trainer_offers rows,
-- known_spells, copper/copper_known); positions are the synthetic fixture.

local failures = {}
local function check(cond, name)
  if not cond then error(name, 0) end
end

local logs = {}
_G.wow = { log = function(line) logs[#logs + 1] = line end, time = function() return 0 end }

require("tests.lifecycle_fixture")
local life = require("tools.lifecycle")
local requests = require("tools.requests")

local TRAINER_GUID = 88
local AT = { map_id = 0, position = { x = 1100.0, y = 96.0, z = 10, o = 0 } }
local FAR = { map_id = 0, position = { x = 0, y = 0, z = 10, o = 0 } }

local function trainer_unit()
  return { guid = TRAINER_GUID, entry = 2126, distance = 4, death_known = true,
    is_dead = false, health_known = true, health = 100, player_can_attack = false }
end

local function offer(taught, state, cost, required, pending)
  return { service_spell_id = taught + 100000, taught_spell_id = taught, state = state,
    cost = cost, required_level = required, pending = pending or false,
    selected = false, list_index = 1 }
end

-- A level-6 warlock at the home trainer. `open` adds the exact trainer frame.
local function seat(extra)
  local v = {
    player_guid = 4242, class_id = 9, level = 6, in_combat = false,
    location = AT, units = { trainer_unit() }, known_spells = { 686, 688 },
    copper_known = true, copper = 500, trainer_open = false, trainer_guid = 0,
    gossip_open = false, gossip_guid = 0, trainer_offers = {},
    active_cast_spell_id = 0, active_channel_spell_id = 0,
  }
  for k, val in pairs(extra or {}) do v[k] = val end
  return v
end

local function open(extra)
  local v = seat(extra)
  v.trainer_open, v.trainer_guid = true, TRAINER_GUID
  return v
end

local cases = {}
local function case(name, fn) cases[#cases + 1] = { name = name, fn = fn } end

case("cold start at a level with unbought training visits the trainer", function()
  local st = life.new_state()
  local go = life.train_step(seat(), st, 0, false)
  check(go and go.kind == "interact" and go.guid == TRAINER_GUID,
    "first sight after a restart must not assume the level is trained")
end)

case("an absent trainer does not mark the level trained", function()
  local st = life.new_state()
  check(life.train_step(seat({ location = FAR }), st, 0, false) == nil, "nothing to walk to")
  local go = life.train_step(seat(), st, 1, false)
  check(go and go.kind == "interact", "a trainer back in reach is still visited at that level")
end)

case("a timeout is retried at the same level after the pause, not settled", function()
  local st = life.new_state()
  life.train_step(seat(), st, 0, false)
  check(life.train_step(seat(), st, 100, false) == nil, "the visit times out")
  check(st.trained_level ~= 6, "a timeout is not a trained level")
  check(life.train_step(seat(), st, 101, false) == nil, "no immediate re-walk after a failure")
  local again = life.train_step(seat(), st, 100 + 301, false)
  check(again and again.kind == "interact", "the same level is retried after the pause")
end)

case("retries per level are bounded", function()
  local st = life.new_state()
  local t = 0
  for _ = 1, 3 do
    check(life.train_step(seat(), st, t, false) ~= nil, "attempt starts")
    life.train_step(seat(), st, t + 91, false)
    t = t + 91 + 301
  end
  check(life.train_step(seat(), st, t, false) == nil, "a fourth attempt at the level is refused")
  check(life.train_step(seat({ level = 7 }), st, t + 1, false) ~= nil, "a new level resets the budget")
end)

case("a frame closed with affordable offers left is partial, not trained", function()
  local st = life.new_state()
  life.train_step(seat(), st, 0, false)
  life.train_step(open({ trainer_offers = { offer(695, 0, 100, 6), offer(1454, 0, 100, 6) } }),
    st, 1, false)
  life.train_step(open({ known_spells = { 686, 688, 695 }, copper = 400,
    trainer_offers = { offer(695, 2, 100, 6), offer(1454, 0, 100, 6) } }), st, 2, false)
  life.train_step(seat({ known_spells = { 686, 688, 695 }, copper = 400 }), st, 3, false)
  check(st.train_outcome and st.train_outcome.result == "partial", "outcome is partial")
  check(st.trained_spells == 1, "the one learned rank is counted by spell id")
  check(st.trained_level ~= 6, "a level with affordable training left is not settled")
end)

case("learned is the offered spells now known, not spellbook growth", function()
  local st = life.new_state()
  life.train_step(seat(), st, 0, false)
  life.train_step(open({ trainer_offers = { offer(695, 0, 100, 6) } }), st, 1, false)
  -- A passive or item spell appears; the offered rank was not bought.
  life.train_step(seat({ known_spells = { 686, 688, 20577 } }), st, 2, false)
  check(st.trained_spells == 0, "an unrelated new spell is not training")
  check(st.train_outcome.result == "incomplete", "nothing offered was learned")
end)

case("an exact complete frame settles the level and keeps unaffordable offers", function()
  local st = life.new_state()
  life.train_step(seat(), st, 0, false)
  life.train_step(open({ copper = 150, trainer_offers = { offer(695, 0, 100, 6),
    offer(1454, 0, 900, 6), offer(5782, 1, 300, 8) } }), st, 1, false)
  life.train_step(open({ copper = 50, known_spells = { 686, 688, 695 },
    trainer_offers = { offer(695, 2, 100, 6), offer(1454, 0, 900, 6),
      offer(5782, 1, 300, 8) } }), st, 2, false)
  life.train_step(seat({ copper = 50, known_spells = { 686, 688, 695 } }), st, 3, false)
  check(st.train_outcome.result == "complete" and st.trained_level == 6, "level settled")
  check(st.train_outcome.unaffordable == 1, "the unaffordable rank is reported")
  check(life.train_step(seat({ copper = 500, known_spells = { 686, 688, 695 } }), st, 4,
    false) == nil, "settled until copper covers the cheapest blocked offer")
  local back = life.train_step(seat({ copper = 950, known_spells = { 686, 688, 695 } }), st, 5,
    false)
  check(back and back.kind == "interact", "more money reopens the same level")
end)

case("unknown copper or a pending purchase does not prove completion", function()
  local st = life.new_state()
  life.train_step(seat(), st, 0, false)
  life.train_step(open({ copper_known = false, copper = 0,
    trainer_offers = { offer(695, 0, 100, 6) } }), st, 1, false)
  life.train_step(seat(), st, 2, false)
  check(st.trained_level ~= 6, "unknown copper settles nothing")
  local st2 = life.new_state()
  life.train_step(seat(), st2, 0, false)
  life.train_step(open({ trainer_offers = { offer(695, 0, 100, 6, true) } }), st2, 1, false)
  life.train_step(seat(), st2, 2, false)
  check(st2.trained_level ~= 6, "a pending purchase settles nothing")
end)

case("gossip closing before the trainer list keeps the visit", function()
  local st = life.new_state()
  life.train_step(seat(), st, 0, false)
  life.train_step(seat({ gossip_open = true, gossip_guid = TRAINER_GUID }), st, 1, false)
  local again = life.train_step(seat(), st, 2, false)
  check(again and again.kind == "interact", "the trainer is approached again")
  check(st.train_since ~= nil, "the visit is still open")
end)

case("combat and an own cast pause the visit without ending it", function()
  local st = life.new_state()
  check(life.train_step(seat({ active_channel_spell_id = 5138 }), st, 0, false) == nil,
    "no visit starts during a channel")
  life.train_step(seat(), st, 1, false)
  check(life.train_step(seat({ in_combat = true }), st, 2, false) == nil, "combat pauses")
  check(life.train_step(seat({ active_cast_spell_id = 686 }), st, 3, false) == nil and
    st.train_since ~= nil, "an own cast is not walked off and the visit stays open")
  local resume = life.train_step(seat(), st, 4, false)
  check(resume and resume.kind == "interact" and st.train_outcome == nil,
    "the visit resumes after the interruption with no outcome yet")
end)

-- copper_known is a real bool in the projected view; only `true` is known.
case("missing or false copper_known never proves a complete frame", function()
  for _, known in ipairs({ "missing", false, true }) do
    local st = life.new_state()
    life.train_step(seat(), st, 0, false)
    local frame = open({ trainer_offers = {} })
    if known == "missing" then frame.copper_known = nil else frame.copper_known = known end
    life.train_step(frame, st, 1, false)
    life.train_step(seat(), st, 2, false)
    local settled = st.trained_level == 6
    check(settled == (known == true), "copper_known=" .. tostring(known) ..
      (known == true and " settles the empty frame" or " settles nothing"))
  end
end)

-- Measurement below is source-only: synthetic view fixtures driven through
-- train_step, not a live trainer.

local function failed_visit(st, t)
  local go = life.train_step(seat(), st, t, false)
  check(go and go.kind == "interact", "a visit starts at t=" .. t)
  check(life.train_step(seat(), st, t + 91, false) == nil and st.train_since == nil,
    "the visit at t=" .. t .. " times out")
  return t + 91
end

local function no_visit(v, st, t, why)
  check(life.train_step(v, st, t, false) == nil and st.train_since == nil,
    "no visit at t=" .. t .. ": " .. why)
end

case("after the attempt cap the same level retries once per long cooldown", function()
  local st = life.new_state()
  local t = failed_visit(st, 0)
  t = failed_visit(st, t + 300)
  t = failed_visit(st, t + 300)
  check(st.train_attempts == 3 and st.train_retry_at == t + 1800, "three failures arm the long cooldown")
  no_visit(seat(), st, t + 301, "the short pause does not apply after the cap")
  check(st.train_blocked == "attempts exhausted", "status names the cap")
  no_visit(seat(), st, t + 1799, "still inside the long cooldown")
  local back = failed_visit(st, t + 1800)
  check(st.train_attempts == 4 and st.train_retry_at == back + 1800, "failing again re-arms it")
  no_visit(seat(), st, back + 301, "one attempt per long cooldown")
  local known = { 686, 688, 695 }
  local go = life.train_step(seat({ known_spells = known }), st, back + 1800, false)
  check(go and go.kind == "interact", "the next cooldown allows one more visit")
  life.train_step(open({ known_spells = known, trainer_offers = { offer(695, 2, 100, 6) } }),
    st, back + 1801, false)
  life.train_step(seat({ known_spells = known }), st, back + 1802, false)
  check(st.trained_level == 6 and st.train_attempts == 0 and st.train_retry_at == nil,
    "a complete frame settles the level and clears the budget")
  no_visit(seat({ known_spells = known }), st, back + 9000, "a settled level stays settled")
end)

case("lost frames and unknown copper spend the budget and never reset it", function()
  local st = life.new_state()
  local t = failed_visit(st, 0)
  t = failed_visit(st, t + 300)
  life.train_step(seat(), st, t + 300, false)
  life.train_step(open({ copper_known = false, copper = 0,
    trainer_offers = { offer(695, 0, 100, 6) } }), st, t + 301, false)
  life.train_step(seat(), st, t + 302, false)
  check(st.train_outcome.result == "incomplete" and st.train_attempts == 3,
    "an unknown-copper frame is a spent attempt")
  check(st.train_retry_at == t + 302 + 1800, "and it reaches the long cooldown")
  t = t + 302 + 1800
  life.train_step(seat(), st, t, false)
  life.train_step(open({ trainer_offers = { offer(695, 0, 100, 6) } }), st, t + 1, false)
  life.train_step(seat(), st, t + 2, false)
  check(st.train_attempts == 4 and st.train_retry_at == t + 2 + 1800,
    "a lost frame after the cap adds to the budget instead of resetting it")
end)

case("partial progress and more copper do not bypass the cooldown", function()
  local st = life.new_state()
  local known = { 686, 688 }
  local t = 0
  for _, spell in ipairs({ 695, 1454, 5782 }) do
    local go = life.train_step(seat({ known_spells = known }), st, t, false)
    check(go and go.kind == "interact", "partial visit starts at t=" .. t)
    life.train_step(open({ known_spells = known,
      trainer_offers = { offer(spell, 0, 100, 6), offer(980, 0, 100, 6) } }), st, t + 1, false)
    local now_known = { table.unpack(known) }
    now_known[#now_known + 1] = spell
    life.train_step(open({ known_spells = now_known,
      trainer_offers = { offer(spell, 2, 100, 6), offer(980, 0, 100, 6) } }), st, t + 2, false)
    life.train_step(seat({ known_spells = now_known }), st, t + 3, false)
    check(st.train_outcome.result == "partial", "visit with an affordable rank left is partial")
    known = now_known
    t = t + 3 + 300
  end
  local capped_at = t - 300
  check(st.trained_spells == 3 and st.train_attempts == 3, "three partial visits learned three")
  no_visit(seat({ known_spells = known, copper = 5000 }), st, capped_at + 10,
    "more copper inside the cooldown")
  local done = { table.unpack(known) }
  done[#done + 1] = 980
  local go = life.train_step(seat({ known_spells = known }), st, capped_at + 1800, false)
  check(go and go.kind == "interact", "the level is retried after the cooldown")
  life.train_step(open({ known_spells = known, trainer_offers = { offer(980, 0, 100, 6) } }),
    st, capped_at + 1801, false)
  life.train_step(open({ known_spells = done, trainer_offers = { offer(980, 2, 100, 6) } }),
    st, capped_at + 1802, false)
  life.train_step(seat({ known_spells = done }), st, capped_at + 1803, false)
  check(st.train_outcome.result == "complete" and st.trained_level == 6 and
    st.trained_spells == 4, "the post-cooldown visit finishes the level")
end)

-- Objective-first quest request (quest_first) --------------------------------

-- Out in the field, 296 yd from the home trainer: in reach, not in view.
local FIELD = { map_id = 0, position = { x = 1100.0, y = 400.0, z = 10, o = 0 } }
local LOG = { { quest_id = 100, title = "Synthetic Cull", level = 6, failed = false } }

local function field(extra)
  local v = seat({ location = FIELD, units = {}, accepted_quests = LOG })
  for k, val in pairs(extra or {}) do v[k] = val end
  return v
end

local function retry_due()
  local st = life.new_state()
  return st, failed_visit(st, 0) + 300
end

case("a quest request's retry waits for the trainer in view and stays pending", function()
  local st, t = retry_due()
  check(life.train_step(field(), st, t, false, true) == nil and st.train_since == nil,
    "the retry does not walk off the quest")
  local status = life.training_status(st)
  check(status.blocked == "retry waits for trainer in view during quest" and
    status.state == "incomplete" and status.attempts == 1 and st.train_retry_at == t and
    st.trained_level == nil, "pending, unsettled, attempt budget untouched")
  local near = life.train_step(field({ location = AT, units = { trainer_unit() } }), st, t + 30,
    false, true)
  check(near and near.kind == "interact" and near.reason == "class_trainer",
    "the trainer in view is the checkpoint: the retry starts")
end)

case("the deferral needs an objective-first request and a live quest", function()
  local st, t = retry_due()
  local go = life.train_step(field(), st, t, false)
  check(go and go.reason == "class_trainer_walk", "autonomous play retries as before")
  for _, log in ipairs({ {}, { { quest_id = 100, title = "", failed = true } } }) do
    st, t = retry_due()
    go = life.train_step(field({ accepted_quests = log }), st, t, false, true)
    check(go and go.reason == "class_trainer_walk",
      "no live quest in the log (" .. #log .. " failed rows): the retry walks")
  end
end)

case("a first visit, a new level and an explicit request still walk during a quest", function()
  local st = life.new_state()
  local go = life.train_step(field(), st, 0, false, true)
  check(go and go.reason == "class_trainer_walk", "cold start is not proof of training")
  st = retry_due()
  go = life.train_step(field({ level = 7 }), st, 400, false, true)
  check(go and go.reason == "class_trainer_walk", "a level earned mid-quest is eligible")
  local t
  st, t = retry_due()
  life.request_training(field(), st)
  go = life.train_step(field(), st, t - 200, false, true)
  check(go and go.reason == "class_trainer_walk", "an explicit request forces the visit")
end)

case("a visit under way is not cut by a quest and the cap still applies", function()
  local st = life.new_state()
  life.train_step(field(), st, 0, false, true)
  local go = life.train_step(field(), st, 30, false, true)
  check(go and go.reason == "class_trainer_walk" and st.train_since == 0,
    "the open visit keeps walking")
  check(life.train_step(field(), st, 91, false, true) == nil and st.train_attempts == 1,
    "and still times out unsettled")
  local t = failed_visit(st, 391)
  t = failed_visit(st, t + 300)
  check(st.train_attempts == 3 and st.train_retry_at == t + 1800, "cap reached as before")
  check(life.train_step(field(), st, t + 1800, false, true) == nil and st.train_since == nil and
    st.train_attempts == 3, "no visit")
  check(st.train_blocked == "retry waits for trainer in view during quest" and
    st.train_retry_at == t + 1800, "after the long cooldown the retry still waits for view")
end)

-- Request job ----------------------------------------------------------------

local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p " .. dir)

local function write(path, body)
  local f = assert(io.open(path, "w")) f:write(body) f:close()
end
local function read(path)
  local f = io.open(path, "r") if not f then return nil end
  local b = f:read("*a") f:close() return b
end

local function train_job(key)
  return string.format('{"key":"%s","origin":"whisper","actor":"Murist",' ..
    '"actor_guid":"1000007","choice":"train","intent":"action","reply":"",' ..
    '"x":0,"y":0,"z":10,"map_id":0}\n', key)
end

local function last_receipt(key)
  local found
  for line in (read(dir .. "/receipts.jsonl") or ""):gmatch("[^\n]+") do
    if line:find('"key":"' .. key .. '"', 1, true) then found = line end
  end
  return found or ""
end

case("a train request with no trainer in reach fails with that reason", function()
  local st = life.new_state()
  local rs = requests.new(dir)
  write(dir .. "/inbox.json", train_job("t1"))
  requests.step(seat({ location = FAR }), rs, 1, { life = life, lstate = st, fighting = false })
  local r = last_receipt("t1")
  check(r:find('"state":"failed"', 1, true) and r:find("no class trainer in reach", 1, true),
    "failed with the real reason")
  check(st.trained_level ~= 6, "the request did not mark the level trained")
end)

case("a train request on a settled level visits and acknowledges by spell id", function()
  local st = life.new_state()
  st.trained_level = 6
  local rs = requests.new(dir)
  local ctx = { life = life, lstate = st, fighting = false }
  write(dir .. "/inbox.json", train_job("t2"))
  local go = requests.step(seat(), rs, 10, ctx)
  check(go and go.kind == "interact", "the request walks to the trainer")
  requests.step(open({ trainer_offers = { offer(695, 0, 100, 6) } }), rs, 11, ctx)
  requests.step(open({ copper = 400, known_spells = { 686, 688, 695 },
    trainer_offers = { offer(695, 2, 100, 6) } }), rs, 12, ctx)
  requests.step(seat({ copper = 400, known_spells = { 686, 688, 695 } }), rs, 13, ctx)
  local r = last_receipt("t2")
  check(r:find('"state":"done"', 1, true) and r:find('"learned":"1"', 1, true),
    "done with one learned spell")
end)

case("a train request whose frame is lost fails and leaves a bounded retry", function()
  local st = life.new_state()
  local rs = requests.new(dir)
  local ctx = { life = life, lstate = st, fighting = false }
  write(dir .. "/inbox.json", train_job("t3"))
  requests.step(seat(), rs, 20, ctx)
  requests.step(open({ trainer_offers = { offer(695, 0, 100, 6) } }), rs, 21, ctx)
  requests.step(seat(), rs, 22, ctx)
  local r = last_receipt("t3")
  check(r:find('"state":"failed"', 1, true) and r:find("incomplete", 1, true),
    "a lost frame is a failed request")
  check(st.trained_level ~= 6 and st.train_retry_at ~= nil, "the level stays owed with a retry")
end)

case("a new real server rejection ends buying without settling the level", function()
  for _, code in ipairs({ 0, 1, 2 }) do
    local st = life.new_state()
    life.train_step(seat(), st, 0, false)
    local frame = open({ trainer_offers = { offer(695, 0, 100, 6) },
      trainer_failure_sequence = 1, trainer_failure_guid = TRAINER_GUID,
      trainer_failure_spell_id = 9001, trainer_failure_code = code })
    check(life.train_step(frame, st, 1, false) == nil, "no repeated rejected buy")
    check(st.train_outcome.result == "incomplete" and st.trained_level ~= 6,
      "rejected training is not completion")
    check(st.train_outcome.failure_code == code and st.train_outcome.failed_spell == 9001,
      "actual zero error and failed service identity survive")
    check(life.train_step(frame, st, 2, false) == nil, "bounded retry wait applies")
  end
end)

case("unknown, old and other-provider rejections do not cancel a visit", function()
  local st = life.new_state()
  local frame = open({ trainer_offers = { offer(695, 0, 100, 6) },
    trainer_failure_sequence = 2, trainer_failure_guid = TRAINER_GUID,
    trainer_failure_spell_id = 9001, trainer_failure_code = 0 })
  check(life.train_step(frame, st, 0, false).kind == "train", "old reply is baseline")
  check(life.train_step(frame, st, 1, false).kind == "train", "same old reply ignored")
  frame.trainer_failure_sequence, frame.trainer_failure_guid = 3, TRAINER_GUID + 1
  check(life.train_step(frame, st, 2, false).kind == "train", "other provider ignored")
  frame.trainer_failure_sequence, frame.trainer_failure_guid = 0, TRAINER_GUID
  check(life.train_step(frame, st, 3, false).kind == "train", "zero sequence is unknown")
  frame.trainer_failure_sequence = 4
  check(life.train_step(frame, st, 4, false) == nil and st.train_outcome.result == "incomplete",
    "new matching reply ends the visit")
  life.request_training(frame, st)
  check(life.train_step(frame, st, 5, false).kind == "train",
    "explicit retry can start with a retained old rejection")
end)

case("a rejection cannot settle an apparently complete stale frame", function()
  local st = life.new_state()
  life.train_step(seat(), st, 0, false)
  life.train_step(open({ trainer_offers = {}, trainer_failure_sequence = 1,
    trainer_failure_guid = TRAINER_GUID, trainer_failure_code = 0 }), st, 1, false)
  check(st.train_outcome.result == "incomplete" and st.trained_level ~= 6,
    "real rejection outranks an empty offer list")
end)

for _, c in ipairs(cases) do
  logs = {}
  local ok, err = pcall(c.fn)
  if not ok then failures[#failures + 1] = c.name .. ": " .. tostring(err) end
end
os.execute("rm -rf " .. dir)
if #failures > 0 then
  for _, f in ipairs(failures) do io.stderr:write("FAIL: " .. f .. "\n") end
  os.exit(1)
end
