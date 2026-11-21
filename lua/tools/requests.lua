-- requests: run the player's accepted requests as durable seat jobs.
--
-- The host broker (tools/bot_requests.nim) interprets addressed chat and
-- leaves at most one job in <seat>/jobs/inbox.json. This module takes it
-- exactly once (its key is recorded in receipts.jsonl), keeps it in
-- active.json so a restarted seat resumes it, runs it through the same
-- ordinary verbs the autonomous brain uses, and appends every state change
-- with the world evidence that decided it. A newer request supersedes the
-- running one; "resume" ends it. Fights are never pre-empted: a job waits,
-- except that a quest job keeps the pull it started itself.

local M = {}

local HOLD_SECONDS = 600.0
local HOLD_LEASH_YARDS = 3.0
local COME_ARRIVED_YARDS = 6.0
local COME_SECONDS = 180.0
local FOLLOW_SECONDS = 600.0
local FOLLOW_LOST_SECONDS = 30.0
local FOLLOW_STOP_YARDS = 4.0
local SUMMON_SECONDS = 60.0
local GEAR_SECONDS = 60.0
local TRAIN_SECONDS = 150.0
-- do_quests: the whole request window, the longest stretch without any
-- server quest witness, and the longest stretch the quest stack may only
-- roam or rest before the request is refused as having no quest work here.
local QUEST_SECONDS = 1800.0
local QUEST_STALL_SECONDS = 420.0
local QUEST_IDLE_SECONDS = 90.0
local POLL_SECONDS = 1.0
local TERMINAL = { done = true, failed = true, superseded = true, cancelled = true }

local function field(body, name)
  local s = body:match('"' .. name .. '"%s*:%s*"([^"]*)"')
  if s then return s end
  return body:match('"' .. name .. '"%s*:%s*(-?[%d%.eE+-]+)')
end

local function read_file(path)
  local handle = io.open(path, "r")
  if not handle then return nil end
  local body = handle:read("*a")
  handle:close()
  return body
end

-- Whole-file replace through a sibling temp file, so a crash leaves either
-- the old or the new body and never a torn one.
local function write_file(path, body)
  local tmp = path .. ".tmp"
  local handle = io.open(tmp, "w")
  if not handle then return false end
  handle:write(body)
  handle:close()
  return os.rename(tmp, path) and true or false
end

local function esc(value)
  return (tostring(value or ""):gsub('[%c"\\]', " "))
end

local function count_ids(text)
  local n = 0
  for _ in tostring(text or ""):gmatch("%S+") do n = n + 1 end
  return n
end

local function position(view)
  local loc = view.location
  return loc and loc.position
end

local function dist2d(a, b)
  if not a or not b then return math.huge end
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function unit_by_guid(view, guid)
  for _, unit in ipairs(view.units or {}) do
    if tostring(unit.guid) == tostring(guid) then return unit end
  end
  return nil
end

local function parse_job(body)
  local job = {
    key = field(body, "key"), origin = field(body, "origin"),
    actor = field(body, "actor"), actor_guid = field(body, "actor_guid"),
    choice = field(body, "choice"), intent = field(body, "intent"),
    reply = field(body, "reply") or "",
    x = tonumber(field(body, "x")), y = tonumber(field(body, "y")),
    z = tonumber(field(body, "z")), map_id = tonumber(field(body, "map_id")),
    started_wall = tonumber(field(body, "started_wall")),
    level0 = tonumber(field(body, "level0")),
    resumes = tonumber(field(body, "resumes")) or 0,
    rewarded0 = field(body, "rewarded0"), rewarded = field(body, "rewarded"),
    xp0 = tonumber(field(body, "xp0")), copper0 = tonumber(field(body, "copper0")),
  }
  local ax, ay, az = tonumber(field(body, "anchor_x")), tonumber(field(body, "anchor_y")),
    tonumber(field(body, "anchor_z"))
  if ax and ay and az then job.anchor = { x = ax, y = ay, z = az } end
  if not job.key or not job.choice then return nil end
  return job
end

-- The active job as accepted: request identity, the requester position
-- (come_here), and the seat's own goal state (hold anchor, wall-clock start
-- for the deadline, level at acceptance) so a restart continues the same goal.
local function job_body(job)
  local anchor = ""
  if job.anchor then
    anchor = string.format(',"anchor_x":%.3f,"anchor_y":%.3f,"anchor_z":%.3f',
      job.anchor.x, job.anchor.y, job.anchor.z)
  end
  -- A quest job's baseline (turn-ins the session had already witnessed when
  -- the job began) and the turn-ins it has acknowledged since, so a restart
  -- counts neither again.
  if job.rewarded0 then
    anchor = anchor .. string.format(',"rewarded0":"%s","rewarded":"%s","xp0":%d,"copper0":%d',
      esc(job.rewarded0), esc(job.rewarded or ""), job.xp0 or 0, job.copper0 or 0)
  end
  return string.format(
    '{"key":"%s","origin":"%s","actor":"%s","actor_guid":"%s","choice":"%s",' ..
    '"intent":"%s","reply":"%s","x":%s,"y":%s,"z":%s,"map_id":%s,"replied":%s,' ..
    '"started_wall":%d,"level0":%d,"resumes":%d%s}\n',
    esc(job.key), esc(job.origin), esc(job.actor), esc(job.actor_guid), esc(job.choice),
    esc(job.intent), esc(job.reply), tostring(job.x or 0), tostring(job.y or 0),
    tostring(job.z or 0), tostring(job.map_id or 0), tostring(job.replied and true or false),
    job.started_wall or 0, job.level0 or 0, job.resumes or 0, anchor)
end

--- A request runner bound to one seat directory, or a disabled one when the
--- seat has none (league and test launches).
function M.new(dir)
  return { dir = dir, seen = nil, active = nil, last_poll = nil }
end

--- Wall clock for job deadlines that survive a restart (tests replace it).
M.clock = os.time

function M.from_env()
  local dir = os.getenv("SHADOW_SEAT_DIR")
  if not dir or dir == "" then return M.new(nil) end
  return M.new(dir .. "/jobs")
end

local function receipt(rs, job, state, now, detail, evidence)
  job.state = state
  local extra = ""
  for k, v in pairs(evidence or {}) do
    extra = extra .. string.format(',"%s":"%s"', esc(k), esc(v))
  end
  local line = string.format(
    '{"key":"%s","choice":"%s","origin":"%s","actor":"%s","state":"%s","at":%.3f,' ..
    '"wall":%d,"detail":"%s"%s}\n',
    esc(job.key), esc(job.choice), esc(job.origin), esc(job.actor), state, now or 0,
    os.time(), esc(detail), extra)
  local handle = io.open(rs.dir .. "/receipts.jsonl", "a")
  if handle then handle:write(line) handle:close() end
  wow.log(string.format("request %s %s %s: %s", tostring(job.key), tostring(job.choice),
    state, tostring(detail)))
end

-- Rebuild the exactly-once ledger from receipts.jsonl: every key ever
-- accepted, each key's last recorded state, and answers that were accepted
-- (with their reply text) but never delivered before the seat stopped.
local function load_seen(rs)
  rs.seen, rs.last_state, rs.meta = {}, {}, {}
  local order = {}
  local body = read_file(rs.dir .. "/receipts.jsonl") or ""
  for line in body:gmatch("[^\n]+") do
    local key = field(line, "key")
    if key then
      if not rs.seen[key] then
        order[#order + 1] = key
        rs.meta[key] = { key = key, choice = field(line, "choice"), origin = field(line, "origin"),
          actor = field(line, "actor"), reply = field(line, "reply") }
      end
      rs.seen[key] = true
      rs.last_state[key] = field(line, "state")
    end
  end
  for _, key in ipairs(order) do
    local meta = rs.meta[key]
    if meta.choice == "none" and rs.last_state[key] == "accepted" and meta.reply then
      rs.replies = rs.replies or {}
      rs.replies[#rs.replies + 1] = meta
    end
  end
end

local function finish(rs, job, state, now, detail, evidence)
  receipt(rs, job, state, now, detail, evidence)
  if rs.last_state then rs.last_state[job.key] = state end
  if rs.active == job then
    rs.active = nil
    os.remove(rs.dir .. "/active.json")
  end
end

-- Make `job` the seat's active job. The new active.json replaces the old one
-- in a single rename before any receipt, so a crash at any point leaves the
-- inbox job either still undelivered or durably active.
local function start(rs, job, view, now)
  local old = rs.active
  job.started_at = now
  job.started_wall = M.clock()
  local pos = position(view)
  if pos then job.anchor = { x = pos.x, y = pos.y, z = pos.z } end
  job.level0 = view.level
  if not write_file(rs.dir .. "/active.json", job_body(job)) then return false end
  rs.active = job
  if old and not TERMINAL[old.state] then
    local turned = old.rewarded and old.rewarded ~= "" and
      { rewarded = old.rewarded, rewards = tostring(count_ids(old.rewarded)) } or nil
    receipt(rs, old, "superseded", now, "replaced by " .. job.key, turned)
    rs.last_state[old.key] = "superseded"
  end
  receipt(rs, job, "accepted", now, "from " .. tostring(job.origin) .. " " .. tostring(job.actor),
    { x = pos and string.format("%.1f", pos.x) or "", y = pos and string.format("%.1f", pos.y) or "" })
  return true
end

-- Take the broker's one-slot inbox. The inbox is removed only after the job
-- is durable here (active.json and/or its accepted receipt), so a crash in
-- between redelivers it and the receipt ledger keeps the delivery exactly-once.
local function take_inbox(rs, view, now)
  local path = rs.dir .. "/inbox.json"
  local body = read_file(path)
  if not body then return end
  local job = parse_job(body)
  if not job then
    -- Keep the unreadable body as evidence and free the slot for the queue.
    os.rename(path, string.format("%s/inbox.unreadable-%d.json", rs.dir, M.clock()))
    wow.log("request inbox unreadable; set aside")
    return
  end
  if rs.seen[job.key] then
    os.remove(path)
    return
  end
  if job.choice == "none" then
    -- A question or a refusal only answers; it never replaces the task the
    -- player already gave this seat. The reply rides in the receipt so an
    -- answer accepted just before a restart is still delivered.
    receipt(rs, job, "accepted", now, "answer only; current task kept: " ..
      tostring(rs.active and rs.active.choice or "none"), { reply = job.reply })
    rs.seen[job.key] = true
    rs.last_state[job.key] = "accepted"
    rs.replies = rs.replies or {}
    rs.replies[#rs.replies + 1] = job
    os.remove(path)
    return
  end
  if not start(rs, job, view, now) then
    wow.log("request active.json not writable; inbox kept")
    return
  end
  rs.seen[job.key] = true
  rs.last_state[job.key] = "accepted"
  os.remove(path)
end

-- Continue the job a previous seat process left in active.json: the same
-- key, anchor and wall-clock deadline, not a fresh request. A job whose last
-- receipt is already terminal was finished just before the restart and is
-- cleared instead of run again. Older non-terminal jobs that are not the
-- active one can only have been replaced by it.
local function resume_active(rs, view, now)
  local path = rs.dir .. "/active.json"
  local body = read_file(path)
  local job = body and parse_job(body)
  if body and not job then
    os.rename(path, string.format("%s/active.unreadable-%d.json", rs.dir, M.clock()))
    wow.log("request active.json unreadable; set aside")
  end
  if job and TERMINAL[rs.last_state[job.key] or ""] then
    os.remove(path)
    job = nil
  end
  for key, state in pairs(rs.last_state) do
    local meta = rs.meta[key]
    if not TERMINAL[state] and meta.choice ~= "none" and (not job or key ~= job.key) then
      local ended = job and "superseded" or "failed"
      receipt(rs, meta, ended, now, job and ("replaced by " .. job.key .. " before a restart") or
        "seat restarted without this job active")
      rs.last_state[key] = ended
    end
  end
  if not job then return end
  job.replied = body:find('"replied":true') ~= nil
  local detail
  if job.started_wall and job.started_wall > 0 then
    local held = math.max(0, M.clock() - job.started_wall)
    job.started_at = now - held
    detail = string.format("seat restarted; job continues %ds after acceptance", held)
  else
    job.started_at = now
    job.started_wall = M.clock()
    detail = "seat restarted; legacy active file had no start time, deadline restarted"
  end
  if not job.anchor then
    local pos = position(view)
    if pos then job.anchor = { x = pos.x, y = pos.y, z = pos.z } end
    detail = detail .. "; no stored anchor, using the current position"
  end
  job.resumes = (job.resumes or 0) + 1
  write_file(path, job_body(job))
  rs.seen[job.key] = true
  if not rs.last_state[job.key] then
    receipt(rs, job, "accepted", now, "recovered from active.json after a restart")
  end
  rs.active = job
  receipt(rs, job, "resumed", now, detail, job.anchor and {
    anchor_x = string.format("%.1f", job.anchor.x), anchor_y = string.format("%.1f", job.anchor.y),
    resumes = tostring(job.resumes) } or nil)
  rs.last_state[job.key] = "resumed"
end

local function reply_intent(job)
  if job.replied or job.reply == "" then return nil end
  job.replied = true
  if job.origin == "whisper" and job.actor and job.actor ~= "" then
    return { kind = "chat", channel = "whisper", to = job.actor, text = job.reply,
      reason = "request_reply" }
  end
  if job.origin == "party" or job.origin == "say" then
    return { kind = "chat", channel = job.origin, text = job.reply, reason = "request_reply" }
  end
  return nil
end

-- do_quests runs the seat's own production quest pipeline, which the entry
-- hands in as `ctx.quest` (home: emergency heal, survival, talents,
-- progression, then the accelerated quest stack with its road, unstick and
-- attack wrappers), and judges it only by what the world shows. A turn-in
-- is a quest id newly in rewarded_quest_ids, which the client records from
-- the server's quest-complete message. Objective credit, objectives
-- finished, a new accept or a quest leaving the log are progress, never a
-- turn-in. A turn-in is progress too: the job keeps running the same
-- pipeline, which takes up whatever the server offers next, until the
-- request's bounds end it. It then ends done with the turn-ins it achieved
-- and what stopped it, or failed if it achieved none.
local QUEST_TRAVEL_YARDS = 3.0
-- The stock corpse reclaim radius (fork client_state/constants.nim
-- CorpseReclaimRadius = 39.0). A ghost inside it is where the reclaim
-- happens; only the server's reclaim delay can still hold it there.
local CORPSE_RECLAIM_YARDS = 39.0
local accelerated = nil

local function credits_objective(view, unit)
  if not unit then return false end
  if not accelerated then accelerated = require("accelerated") end
  return accelerated.credits_objective(view, unit) == true
end

local function id_text(list)
  local ids = {}
  for _, id in ipairs(list or {}) do ids[#ids + 1] = tostring(id) end
  return table.concat(ids, " ")
end

local function id_set(text)
  local set = {}
  for id in tostring(text or ""):gmatch("%S+") do set[id] = true end
  return set
end

-- Live objective rows keyed by quest and requirement, not by row position:
-- a quest leaving the log shifts every later row.
local function objective_marks(view)
  local marks = {}
  for _, row in ipairs(view.quest_objectives or {}) do
    local key = string.format("%s:%s:%s:%s", tostring(row.quest_id), tostring(row.entry or 0),
      tostring(row.item_id or 0), tostring(row.text or ""))
    marks[key] = { quest = row.quest_id, current = row.current or 0,
      required = row.required or 0, text = row.text or "" }
  end
  return marks
end

local function accepted_titles(view)
  local titles = {}
  for _, quest in ipairs(view.accepted_quests or {}) do
    local id = type(quest) == "table" and quest.quest_id or quest
    if id then
      titles[tostring(id)] = type(quest) == "table" and
        { title = quest.title or "", failed = quest.failed == true } or
        { title = "", failed = false }
    end
  end
  return titles
end

local function alive_unit(view, guid)
  local unit = guid and unit_by_guid(view, guid)
  if not unit then return nil end
  if unit.death_known and unit.is_dead then return nil end
  if unit.health_known and (unit.health or 0) <= 0 then return nil end
  return unit
end

-- Legs that never count as quest work however far they move the seat. A
-- walk to a corpse is loot, not quest travel: a drop that pays an objective
-- shows up as server credit.
local function wander_step(reason)
  return reason:sub(1, 5) == "roam_" or reason:sub(1, 5) == "loot_" or
    reason:find("unstick", 1, true) ~= nil or
    reason == "survive_flee" or reason == "retreat" or reason == "recover_walk"
end

-- A living hostile whose target is this seat or its pet: a fight the seat
-- cannot walk away from without being hit.
local function under_attack(view)
  local me = tostring(view.player_guid or 0)
  local pet = tostring(view.pet and view.pet.guid or 0)
  for _, unit in ipairs(view.units or {}) do
    local target = tostring(unit.target_guid or 0)
    if unit.target_guid_known == true and target ~= "0" and (target == me or target == pet) and
        unit.player_can_attack == true and alive_unit(view, unit.guid) then
      return true
    end
  end
  return false
end

-- Whether this frame shows the pipeline's step working in the world: the
-- seat closer than ever to the goal of a walk or an interact, or closer to
-- or damaging a mob that pays an objective (kill or drop). Re-issuing the
-- same intent at the same spot, fights that pay nothing, loot, dialog
-- presses and holds are not work; the server witnesses they lead to are.
local function quest_effect(view, q, intent)
  local kind = intent.kind
  if kind ~= "navigate" and kind ~= "interact" and kind ~= "attack" then return false end
  if wander_step(tostring(intent.reason or "")) then return false end
  local unit = intent.guid and unit_by_guid(view, intent.guid)
  if kind == "attack" and not credits_objective(view, unit) then return false end
  local goal = (intent.x and intent.y) and { x = intent.x, y = intent.y } or
    (unit and unit.location and unit.location.position)
  local key = intent.guid and ("guid:" .. tostring(intent.guid)) or
    (goal and string.format("at:%.0f:%.0f", goal.x, goal.y))
  if not key then return false end
  local mine = view.location_known and position(view)
  local d = (mine and goal) and dist2d(mine, goal) or nil
  local hp = unit and unit.health_known and unit.health or nil
  local track = q.tracks[key]
  if not track then
    q.tracks[key] = { best = d, hp = hp }
    return false
  end
  local worked = false
  if d and (not track.best or d <= track.best - QUEST_TRAVEL_YARDS) then
    worked = track.best ~= nil
    track.best = d
  end
  if hp and track.hp and hp < track.hp then worked = true end
  track.hp = hp or track.hp
  return worked
end

local function quest_baseline(rs, job, view, now)
  if not job.rewarded0 then
    job.rewarded0 = id_text(view.rewarded_quest_ids)
    job.xp0, job.copper0 = view.xp or 0, view.copper or 0
    write_file(rs.dir .. "/active.json", job_body(job))
  end
  job.q = { marks = objective_marks(view), quests = accepted_titles(view),
    finished = id_set(id_text(view.completed_quest_ids)), progress_at = now, work_at = now,
    events = 0, blocked = {}, tracks = {} }
  local n = 0
  for _ in pairs(job.q.quests) do n = n + 1 end
  receipt(rs, job, "progress", now, string.format("quest baseline: %d in log, %d objectives done",
    n, #(view.completed_quest_ids or {})), { quests = id_text(view.completed_quest_ids) })
end

-- Record every server quest change since the last frame as a progress
-- receipt. A quest id newly in rewarded_quest_ids, outside the job's
-- baseline and the turn-ins it already acknowledged, is a turn-in: it is
-- made durable in active.json before its receipt, so a restart never counts
-- it twice.
local function quest_witness(rs, job, view, now)
  local q = job.q
  local function note(detail, evidence)
    q.events = q.events + 1
    q.progress_at, q.work_at = now, now
    receipt(rs, job, "progress", now, detail, evidence)
  end
  local base, acked = id_set(job.rewarded0), id_set(job.rewarded)
  for _, raw in ipairs(view.rewarded_quest_ids or {}) do
    local id = tostring(raw)
    if not base[id] and not acked[id] then
      local previous = job.rewarded
      job.rewarded = (previous and previous ~= "") and (previous .. " " .. id) or id
      if not write_file(rs.dir .. "/active.json", job_body(job)) then
        job.rewarded = previous
        if not q.persist_warned then
          wow.log("request active.json not writable; reward acknowledgement pending")
          q.persist_warned = true
        end
      else
        acked[id] = true
        q.persist_warned = nil
        local n = count_ids(job.rewarded)
        local title = (q.quests[id] or {}).title or ""
        note(string.format("turned in quest %s%s (server reward witness, %d this request)", id,
          title ~= "" and (" " .. title) or "", n),
          { quest = id, rewards = tostring(n), rewarded = job.rewarded,
            level = tostring(view.level), level0 = tostring(job.level0),
            xp = tostring(view.xp), xp0 = tostring(job.xp0),
            copper_gain = tostring((view.copper or 0) - (job.copper0 or 0)) })
      end
    end
  end
  local marks = objective_marks(view)
  for key, mark in pairs(marks) do
    local old = q.marks[key]
    if old and mark.current > old.current then
      note(string.format("objective credit quest %s: %s %d/%d", tostring(mark.quest),
        mark.text, mark.current, mark.required),
        { quest = tostring(mark.quest), current = tostring(mark.current),
          required = tostring(mark.required) })
    end
  end
  q.marks = marks
  local quests = accepted_titles(view)
  for id, quest in pairs(quests) do
    if not q.quests[id] then
      note("accepted quest " .. id .. " " .. quest.title .. " (accepted, not completed)",
        { quest = id })
    elseif quest.failed and not q.quests[id].failed then
      note("quest " .. id .. " failed", { quest = id })
    end
  end
  local observed_rewards = id_set(id_text(view.rewarded_quest_ids))
  for id, quest in pairs(q.quests) do
    if not quests[id] and not acked[id] and not observed_rewards[id] then
      note("quest " .. id .. " " .. quest.title .. " left the log without a reward witness",
        { quest = id })
    end
  end
  q.quests = quests
  local finished = id_set(id_text(view.completed_quest_ids))
  for id in pairs(finished) do
    if not q.finished[id] then
      note("objectives done for quest " .. id .. "; turn-in pending", { quest = id })
    end
  end
  q.finished = finished
end

-- End the job at one of its bounds: done with the turn-ins it achieved and
-- what stopped it, or failed with that reason when it achieved none.
local function quest_end(rs, job, view, now, why)
  local n = count_ids(job.rewarded)
  if n == 0 then
    if job.q and job.q.persist_warned then
      why = "could not save observed server turn-in evidence; stopped: " .. why
    end
    finish(rs, job, "failed", now, why)
    return
  end
  local remaining = {}
  for id in pairs(accepted_titles(view)) do remaining[#remaining + 1] = id end
  table.sort(remaining)
  finish(rs, job, "done", now, string.format("turned in %d quest%s this request (%s); stopped: %s",
    n, n == 1 and "" or "s", job.rewarded, why),
    { rewards = tostring(n), rewarded = job.rewarded, level = tostring(view.level),
      level0 = tostring(job.level0), xp = tostring(view.xp), xp0 = tostring(job.xp0),
      copper_gain = tostring((view.copper or 0) - (job.copper0 or 0)),
      next = table.concat(remaining, " ") })
end

-- Death and the corpse run belong to the entry's own recovery; the job only
-- keeps its bounds here. A dead or ghost client's quest lists are not read
-- as accepts, abandons or turn-ins, and no baseline is taken from them.
-- Entering recovery starts one ordinary idle allowance; after that only the
-- ghost closing on its known corpse is work -- or the ghost already inside
-- the reclaim radius of that corpse while the client reports a positive
-- reclaim delay (corpse_reclaim_delay_known, corpse_reclaim_delay_ms > 0,
-- can_reclaim_corpse false): the server, not the seat, is holding it there.
-- A ghost that stands still anywhere else comes back alive already idle, and
-- one that never comes back ends at the stall bound or the request window.
local function quest_recovery(rs, job, view, now)
  if now - (job.started_at or now) > QUEST_SECONDS then
    quest_end(rs, job, view, now, string.format(
      "request window of %.0fs ended during death recovery", QUEST_SECONDS))
    return
  end
  local q = job.q
  if not q then return end
  if now - q.progress_at > QUEST_STALL_SECONDS then
    quest_end(rs, job, view, now, string.format(
      "no server quest progress for %.0fs (during death recovery)", now - q.progress_at))
    return
  end
  if not q.recovery then
    q.recovery = {}
    q.work_at = now
  end
  q.last_reason = view.is_ghost and "corpse_run" or "dead"
  local corpse = view.corpse_known == true and view.corpse_location
  local mine = view.is_ghost and view.location_known and position(view)
  if corpse and corpse.position and mine and view.location and
      corpse.map_id == view.location.map_id then
    local d = dist2d(mine, corpse.position)
    local best = q.recovery.best
    if not best or d <= best - QUEST_TRAVEL_YARDS then
      if best then q.work_at = now end
      q.recovery.best = d
    end
    if d <= CORPSE_RECLAIM_YARDS and view.can_reclaim_corpse ~= true and
        view.corpse_reclaim_delay_known == true and
        (tonumber(view.corpse_reclaim_delay_ms) or 0) > 0 then
      q.work_at = now
      q.last_reason = "corpse_reclaim_delay"
    end
  end
end

local function quest_step(rs, job, view, now, ctx)
  if not view.rewarded_quest_ids then
    quest_end(rs, job, view, now, "this client view reports no quest turn-in witness")
    return nil
  end
  if type(ctx.quest) ~= "function" then
    quest_end(rs, job, view, now, "this seat has no quest pipeline to run")
    return nil
  end
  if not job.q then quest_baseline(rs, job, view, now) end
  local q = job.q
  q.recovery = nil
  quest_witness(rs, job, view, now)
  local elapsed = now - (job.started_at or now)
  if elapsed > QUEST_SECONDS then
    quest_end(rs, job, view, now, string.format(count_ids(job.rewarded) == 0 and
      "no turn-in within %.0fs after %d progress events" or
      "request window of %.0fs ended after %d progress events", QUEST_SECONDS, q.events))
    return nil
  end
  if now - q.progress_at > QUEST_STALL_SECONDS then
    quest_end(rs, job, view, now, string.format("no server quest progress for %.0fs (last step %s)",
      now - q.progress_at, tostring(q.last_reason)))
    return nil
  end
  -- Idle is judged between fights: failing while a hostile is hitting the
  -- seat would hand it to the escort brain, which walks back to the owner
  -- under the blows. Combat still adds to idle time, and the stall and job
  -- deadlines above bound a fight that never ends.
  if now - q.work_at > QUEST_IDLE_SECONDS and not under_attack(view) then
    quest_end(rs, job, view, now, string.format(
      "no reachable quest work: no quest travel, objective fight or server quest change " ..
      "for %.0fs (last step %s)", now - q.work_at, tostring(q.last_reason)))
    return nil
  end
  local intent = ctx.quest()
  if type(intent) ~= "table" then return nil end
  q.last_reason = intent.reason
  if quest_effect(view, q, intent) then q.work_at = now end
  if (intent.reason == "reward_blocked" or intent.reason == "log_full") and
      not q.blocked[intent.reason] then
    q.blocked[intent.reason] = true
    receipt(rs, job, "progress", now, intent.reason == "log_full" and
      "blocked: quest log full, offered quest declined" or
      "blocked: reward refused repeatedly (bags full?), freeing a slot",
      { quest = tostring((view.quest_frame or {}).quest_id or 0) })
  end
  return intent
end

--- Run the active request job, if any. `ctx` carries the shared lifecycle
--- (`life`, `lstate`), whether the seat is in a fight, and `quest`: the
--- entry's own quest pipeline as a zero-argument function returning this
--- frame's intent. Returns an intent or nil; nil lets the autonomous brain
--- act this frame.
function M.step(view, rs, now, ctx)
  if not rs.dir then return nil end
  if not rs.seen then
    load_seen(rs)
    resume_active(rs, view, now)
  end
  -- A request that arrives during death waits in the inbox for the living
  -- seat: its anchor and baseline must come from where the seat stands then.
  local recovering = view.is_dead or view.is_ghost
  if not recovering and (not rs.last_poll or now - rs.last_poll >= POLL_SECONDS) then
    rs.last_poll = now
    take_inbox(rs, view, now)
  end
  if recovering or ctx.fighting then
    local job = rs.active
    local quest = job and job.choice == "do_quests"
    -- A quest job's seat is usually far from its owner, so every fight it
    -- meets alive (its pull, an add, mid-walk aggro, lingering combat) runs
    -- the quest pipeline, which puts emergency heals and survival first;
    -- the escort brain would walk back to the owner mid-fight. Combat that
    -- pays no objective is still not quest work.
    if quest and not recovering then
      return quest_step(rs, job, view, now, ctx)
    end
    if quest then quest_recovery(rs, job, view, now) end
    return nil
  end
  local answer = rs.replies and rs.replies[1]
  if answer then
    local say = reply_intent(answer)
    table.remove(rs.replies, 1)
    finish(rs, answer, "done", now, "answered: " .. tostring(answer.reply))
    if say then return say end
  end
  local job = rs.active
  if not job then return nil end
  local say = reply_intent(job)
  if say then
    write_file(rs.dir .. "/active.json", job_body(job))
    receipt(rs, job, "replied", now, job.reply)
    if job.choice == "none" then finish(rs, job, "done", now, "answered") end
    return say
  end
  local pos = position(view)
  local elapsed = now - (job.started_at or now)
  local life, lstate = ctx.life, ctx.lstate
  local choice = job.choice
  if choice == "none" then
    finish(rs, job, "done", now, "answered")
    return nil
  elseif choice == "resume" then
    finish(rs, job, "done", now, "back to leveling")
    return nil
  elseif choice == "hold_here" then
    if elapsed > HOLD_SECONDS then
      finish(rs, job, "done", now, string.format("held %.0fs", elapsed),
        { drift = string.format("%.1f", dist2d(pos, job.anchor)) })
      return nil
    end
    if job.anchor and dist2d(pos, job.anchor) > HOLD_LEASH_YARDS then
      return { kind = "navigate", x = job.anchor.x, y = job.anchor.y, z = job.anchor.z,
        map_id = math.floor(view.location.map_id or 0), stop_distance = 1.5,
        route_profile = "prefer_ground", reason = "request_hold_return" }
    end
    return { kind = "hold", reason = "request_hold" }
  elseif choice == "come_here" then
    local target = job.x and { x = job.x, y = job.y, z = job.z }
    if not target then
      finish(rs, job, "failed", now, "no requester position")
      return nil
    end
    local d = dist2d(pos, target)
    if d <= COME_ARRIVED_YARDS then
      finish(rs, job, "done", now, "arrived",
        { distance = string.format("%.1f", d),
          x = string.format("%.1f", pos.x), y = string.format("%.1f", pos.y) })
      return nil
    end
    if elapsed > COME_SECONDS then
      finish(rs, job, "failed", now, "did not arrive", { distance = string.format("%.1f", d) })
      return nil
    end
    return { kind = "navigate", x = target.x, y = target.y, z = target.z,
      map_id = job.map_id or 0, stop_distance = 4.0, route_profile = "prefer_ground",
      reason = "request_come" }
  elseif choice == "follow_me" then
    local leader = unit_by_guid(view, job.actor_guid)
    if leader then job.seen_at = now end
    if elapsed > FOLLOW_SECONDS then
      finish(rs, job, "done", now, string.format("followed %.0fs", elapsed))
      return nil
    end
    if not leader then
      if now - (job.seen_at or job.started_at) > FOLLOW_LOST_SECONDS then
        finish(rs, job, "failed", now, "lost sight of the requester")
      end
      return nil
    end
    local lp = leader.location
    if lp and dist2d(pos, lp) > FOLLOW_STOP_YARDS then
      return { kind = "navigate", x = lp.x or lp.position.x, y = lp.y or lp.position.y,
        z = lp.z or lp.position.z, map_id = lp.map_id or 0, stop_distance = FOLLOW_STOP_YARDS,
        route_profile = "prefer_ground", reason = "request_follow" }
    end
    return { kind = "hold", reason = "request_follow_close" }
  elseif choice == "summon_pet" then
    local pet = life.own_pet(view)
    if pet then
      finish(rs, job, "done", now, "pet out", { pet_guid = tostring(pet.guid) })
      return nil
    end
    if elapsed > SUMMON_SECONDS then
      finish(rs, job, "failed", now, "no pet link after summon attempts")
      return nil
    end
    return life.pet_step(view, lstate, now, false) or { kind = "hold", reason = "request_summon_wait" }
  elseif choice == "wear_upgrades" then
    job.equipped0 = job.equipped0 or lstate.equipped
    local gear = life.gear_step(view, lstate, now, false)
    if gear then return gear end
    if not life.pick_upgrade(view, lstate) or elapsed > GEAR_SECONDS then
      finish(rs, job, "done", now, "upgrades worn",
        { equipped = tostring(lstate.equipped - job.equipped0) })
    end
    return nil
  elseif choice == "repair_gear" then
    if not job.repair_started then
      life.request_repair(lstate, now)
      job.repair_started = true
    end
    local repair, outcome = life.repair_step(view, lstate, now, false)
    if outcome then
      finish(rs, job, outcome.result == "complete" and "done" or "failed", now,
        outcome.why, { paid = outcome.paid and tostring(outcome.paid) or "unknown" })
    elseif elapsed > life.REPAIR_REQUEST_SECONDS then
      finish(rs, job, "failed", now, "repair did not settle before the request deadline")
    end
    return repair
  elseif choice == "train" then
    -- Done only when the first trainer visit to end after this job began
    -- (one it started, or an autonomous visit already in progress that it
    -- adopts) ended on an exact complete trainer frame; a visit that never
    -- started, timed out or lost the frame fails with that reason, and the
    -- autonomous retry stays in charge.
    if not job.train_started then
      job.train_started = true
      job.visits0 = lstate.train_visits
      if not lstate.train_since then life.request_training(view, lstate) end
    end
    local train = life.train_step(view, lstate, now, false)
    if train then return train end
    local outcome = lstate.train_outcome
    if lstate.train_visits > job.visits0 and outcome then
      finish(rs, job, outcome.result == "complete" and "done" or "failed", now,
        "trainer visit " .. outcome.result .. " (" .. tostring(outcome.why) .. ")",
        { learned = tostring(outcome.learned), level = tostring(outcome.level),
          affordable_left = tostring(outcome.affordable),
          unaffordable = tostring(outcome.unaffordable) })
    elseif lstate.train_since == nil and lstate.train_blocked ~= "busy" then
      lstate.train_forced = nil
      finish(rs, job, "failed", now, "no trainer visit: " .. tostring(lstate.train_blocked))
    elseif elapsed > TRAIN_SECONDS then
      if not lstate.train_since then lstate.train_forced = nil end
      finish(rs, job, "failed", now, lstate.train_since and "trainer visit still open at deadline"
        or "no trainer visit: " .. tostring(lstate.train_blocked))
    end
    return nil
  elseif choice == "do_quests" then
    -- Runs to its bounds; only server turn-in witnesses make it done. See quest_step.
    return quest_step(rs, job, view, now, ctx)
  end
  finish(rs, job, "failed", now, "unknown choice " .. tostring(choice))
  return nil
end

return M
