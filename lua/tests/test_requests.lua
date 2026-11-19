-- Unit tests for tools/requests.lua: durable, exactly-once request jobs.

local passed = 0
local function check(cond, name)
  if not cond then
    io.stderr:write("FAIL: " .. name .. "\n")
    os.exit(1)
  end
  passed = passed + 1
end

local logs = {}
_G.wow = { log = function(line) logs[#logs + 1] = line end, time = function() return 0 end }

require("tests.lifecycle_fixture")
local life = require("tools.lifecycle")
local requests = require("tools.requests")

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
local function count(body, pattern)
  local n = 0
  for _ in (body or ""):gmatch(pattern) do n = n + 1 end
  return n
end

local function view(extra)
  local v = {
    player_guid = 1000027, class_id = 9, level = 5, in_combat = false,
    location = { map_id = 0, position = { x = 100, y = 100, z = 10 } },
    units = {}, known_spells = { 686, 688 }, action_buttons = {}, pet = { guid_known = true, guid = 0 },
    inventory_items = {}, equipment_items = {},
  }
  for k, val in pairs(extra or {}) do v[k] = val end
  return v
end

local function job(key, choice, extra)
  return string.format('{"key":"%s","origin":"%s","actor":"Murist","actor_guid":"1000007",' ..
    '"choice":"%s","intent":"%s","reply":"%s","x":%s,"y":%s,"z":10,"map_id":0}\n',
    key, (extra and extra.origin) or "whisper", choice,
    choice == "none" and "question" or "action", (extra and extra.reply) or "",
    (extra and extra.x) or 0, (extra and extra.y) or 0)
end

local lstate = life.new_state()
local rs = requests.new(dir)
local ctx = { life = life, lstate = lstate, fighting = false }

-- hold_here: accepted once, holds, walks back when pushed off its spot.
write(dir .. "/inbox.json", job("k1", "hold_here"))
local i = requests.step(view(), rs, 1, ctx)
check(i and i.kind == "hold" and i.reason == "request_hold", "hold job holds")
check(read(dir .. "/inbox.json") == nil and read(dir .. "/active.json"), "inbox taken into active")
i = requests.step(view({ location = { map_id = 0, position = { x = 110, y = 100, z = 10 } } }), rs, 2, ctx)
check(i and i.kind == "navigate" and i.reason == "request_hold_return", "pushed off the spot it walks back")

-- The same key delivered again is not run twice.
write(dir .. "/inbox.json", job("k1", "hold_here"))
requests.step(view(), rs, 3, ctx)
check(count(read(dir .. "/receipts.jsonl"), '"state":"accepted"') == 1, "a repeated key is accepted once")

-- A fight pauses the job without ending it.
ctx.fighting = true
check(requests.step(view(), rs, 4, ctx) == nil, "a fight is never pre-empted")
ctx.fighting = false

-- A new request supersedes the running one; come_here walks to the
-- captured requester position and finishes on arrival.
write(dir .. "/inbox.json", job("k2", "come_here", { x = 140, y = 100 }))
i = requests.step(view(), rs, 5, ctx)
check(i and i.kind == "navigate" and i.reason == "request_come" and i.x == 140, "come walks to the requester")
check(read(dir .. "/receipts.jsonl"):find('"key":"k1","choice":"hold_here","origin":"whisper","actor":"Murist","state":"superseded"', 1, true),
  "the earlier hold is superseded, with its identity kept")
i = requests.step(view({ location = { map_id = 0, position = { x = 137, y = 100, z = 10 } } }), rs, 6, ctx)
check(i == nil and read(dir .. "/receipts.jsonl"):find('"key":"k2".-"state":"done"'), "arrival completes the job")

-- A restarted seat resumes an active job instead of dropping it.
write(dir .. "/inbox.json", job("k3", "hold_here"))
requests.step(view(), rs, 7, ctx)
local rs2 = requests.new(dir)
i = requests.step(view(), rs2, 8, ctx)
check(i and i.reason == "request_hold", "a restarted seat resumes the active job")
check(read(dir .. "/receipts.jsonl"):find('"key":"k3".-"state":"resumed"'), "and records it")

-- A question while a task runs answers without replacing the task.
write(dir .. "/inbox.json", job("k3q", "none", { reply = "Level 5, imp out." }))
rs2.last_poll = nil
i = requests.step(view(), rs2, 8.5, ctx)
check(i and i.kind == "chat" and i.channel == "whisper", "the question is answered")
i = requests.step(view(), rs2, 8.6, ctx)
check(i and i.reason == "request_hold", "and the hold the player gave keeps running")

-- resume ends the running job; a question only replies, by whisper, once.
write(dir .. "/inbox.json", job("k4", "resume"))
rs2.last_poll = nil
check(requests.step(view(), rs2, 9, ctx) == nil, "resume returns control")
check(read(dir .. "/active.json") == nil, "no active job left")
write(dir .. "/inbox.json", job("k5", "none", { reply = "I am level 5." }))
i = requests.step(view(), rs2, 10, ctx)
check(i and i.kind == "chat" and i.channel == "whisper" and i.to == "Murist" and
  i.text == "I am level 5.", "a whispered question is answered by whisper to the asker")
check(requests.step(view(), rs2, 11, ctx) == nil, "and only once")

-- An operator request never speaks in game.
write(dir .. "/inbox.json", job("k6", "none", { origin = "operator", reply = "level 5" }))
check(requests.step(view(), rs2, 12, ctx) == nil, "operator replies stay in the receipt")

-- summon_pet ends on the authoritative pet link.
write(dir .. "/inbox.json", job("k7", "summon_pet"))
local warlock = view({ action_buttons = { { slot = 5, kind = "spell", spell_id = 688,
  usable_known = true, usable = true } } })
i = requests.step(warlock, rs2, 13, ctx)
check(i and i.kind == "cast_spell" and i.spell == 688, "summon request casts the bound summon")
local withPet = view({ pet = { guid_known = true, guid = 77 } })
requests.step(withPet, rs2, 14, ctx)
check(read(dir .. "/receipts.jsonl"):find('"key":"k7".-"state":"done".-"pet_guid":"77"'), "done only with the pet link")

-- Restart keeps the accepted goal: the original hold anchor and the
-- wall-clock deadline, not the restarted seat's position and a fresh timer.
local wall = 5000
requests.clock = function() return wall end
local function receipts() return read(dir .. "/receipts.jsonl") or "" end
write(dir .. "/inbox.json", job("h1", "hold_here"))
rs2.last_poll = nil
requests.step(view({ location = { map_id = 0, position = { x = 300.5, y = 80.25, z = 10 } } }), rs2, 20, ctx)
local active = read(dir .. "/active.json") or ""
check(active:find('"anchor_x":300.500', 1, true) and active:find('"anchor_y":80.250', 1, true) and
  active:find('"started_wall":5000', 1, true), "active.json stores the hold anchor and start")
wall = 5030
local rs3 = requests.new(dir)
local moved = view({ location = { map_id = 0, position = { x = 325, y = 80.25, z = 10 } } })
i = requests.step(moved, rs3, 1, ctx)
check(i and i.kind == "navigate" and i.reason == "request_hold_return" and
  math.abs(i.x - 300.5) < 0.01, "a restarted hold walks back to its original spot")
check(receipts():find('"key":"h1".-"state":"resumed".-continues 30s after acceptance'),
  "the resume is recorded as the same job 30 s in, not a new request")
check(count(receipts(), '"key":"h1","choice":"hold_here","origin":"whisper","actor":"Murist","state":"accepted"') == 1,
  "a resumed job is not accepted twice")
wall = 5000 + 601
local rs4 = requests.new(dir)
check(requests.step(moved, rs4, 2, ctx) == nil and receipts():find('"key":"h1".-"state":"done"'),
  "the original deadline still ends the hold after a restart")
check(read(dir .. "/active.json") == nil, "and clears the active job")

-- Crash after the active job was written but before its receipt and the
-- inbox removal: the restart recovers it once and frees the inbox.
write(dir .. "/inbox.json", job("c1", "hold_here"))
write(dir .. "/active.json", '{"key":"c1","origin":"whisper","actor":"Murist","actor_guid":"1000007",' ..
  '"choice":"hold_here","intent":"action","reply":"","x":0,"y":0,"z":0,"map_id":0,"replied":false,' ..
  '"started_wall":5601,"level0":5,"resumes":0,"anchor_x":100.000,"anchor_y":100.000,"anchor_z":10.000}\n')
local rs5 = requests.new(dir)
i = requests.step(view(), rs5, 3, ctx)
check(i and i.reason == "request_hold", "the crashed-in job runs")
check(read(dir .. "/inbox.json") == nil, "its redelivered inbox copy is consumed")
check(count(receipts(), '"key":"c1","choice":"hold_here","origin":"whisper","actor":"Murist","state":"accepted"') == 1,
  "and accepted exactly once")

-- Crash after a finished job's terminal receipt but before active.json was
-- removed: the finished job is not run again.
finish_line = '{"key":"c1","choice":"hold_here","origin":"whisper","actor":"Murist","state":"done",' ..
  '"at":4,"wall":5602,"detail":"held"}\n'
local f = assert(io.open(dir .. "/receipts.jsonl", "a")) f:write(finish_line) f:close()
local rs6 = requests.new(dir)
check(requests.step(view(), rs6, 4, ctx) == nil and read(dir .. "/active.json") == nil,
  "a job already done before the restart is cleared, not resumed")

-- Crash after a question was accepted but before its answer went out: the
-- reply comes back from the receipt, once.
write(dir .. "/inbox.json", job("q1", "none", { reply = "I am level 5." }))
f = assert(io.open(dir .. "/receipts.jsonl", "a"))
f:write('{"key":"q1","choice":"none","origin":"whisper","actor":"Murist","state":"accepted",' ..
  '"at":5,"wall":5603,"detail":"answer only","reply":"I am level 5."}\n')
f:close()
local rs7 = requests.new(dir)
i = requests.step(view(), rs7, 5, ctx)
check(i and i.kind == "chat" and i.to == "Murist" and i.text == "I am level 5.",
  "an accepted but undelivered answer is delivered after a restart")
check(read(dir .. "/inbox.json") == nil and requests.step(view(), rs7, 6, ctx) == nil, "only once")
check(requests.step(view(), requests.new(dir), 7, ctx) == nil, "and not again on the next restart")

-- A job left non-terminal by a crash in the supersede window is closed out
-- against the job that actually replaced it.
f = assert(io.open(dir .. "/receipts.jsonl", "a"))
f:write('{"key":"s1","choice":"come_here","origin":"whisper","actor":"Murist","state":"accepted",' ..
  '"at":8,"wall":5604,"detail":"from whisper Murist"}\n')
f:close()
write(dir .. "/active.json", '{"key":"s2","origin":"whisper","actor":"Murist","actor_guid":"1000007",' ..
  '"choice":"hold_here","intent":"action","reply":"","x":0,"y":0,"z":0,"map_id":0,"replied":false,' ..
  '"started_wall":5604,"level0":5,"resumes":0,"anchor_x":100.000,"anchor_y":100.000,"anchor_z":10.000}\n')
requests.step(view(), requests.new(dir), 8, ctx)
check(receipts():find('"key":"s1".-"state":"superseded".-replaced by s2 before a restart'),
  "the dangling job is recorded as superseded by the active one")

-- An unreadable inbox is set aside as evidence, not deleted.
write(dir .. "/inbox.json", "{not json\n")
local rs8 = requests.new(dir)
requests.step(view(), rs8, 9, ctx)
local aside = io.popen("ls " .. dir .. " | grep -c inbox.unreadable"):read("*l")
check(read(dir .. "/inbox.json") == nil and aside == "1", "an unreadable inbox is kept aside")

-- If the active job cannot be made durable the inbox is left for a retry.
write(dir .. "/inbox.json", job("w1", "hold_here"))
-- Block the temporary write for every effective UID, including CI's root.
-- Directory permissions alone do not make writes fail for root.
os.execute("mkdir " .. dir .. "/active.json.tmp")
check(io.open(dir .. "/active.json.tmp", "w") == nil, "the durable-write obstruction is in place")
rs8.last_poll = nil
requests.step(view(), rs8, 10, ctx)
os.execute("rmdir " .. dir .. "/active.json.tmp")
check(read(dir .. "/inbox.json") and not receipts():find('"key":"w1"'),
  "a failed durable active-job write keeps the inbox and records no acceptance")
rs8.last_poll = nil
requests.step(view(), rs8, 11, ctx)
check(read(dir .. "/inbox.json") == nil and receipts():find('"key":"w1".-"state":"accepted"'),
  "and the retry accepts it")
requests.clock = os.time

-- A seat without a directory runs no requests.
check(requests.step(view(), requests.new(nil), 1, ctx) == nil, "no seat dir, no jobs")

os.execute("rm -rf " .. dir)
print(string.format("test_requests: %d checks passed", passed))
