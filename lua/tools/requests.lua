-- requests: run the player's accepted requests as durable seat jobs.
--
-- The host broker (tools/bot_requests.nim) interprets addressed chat and
-- leaves at most one job in <seat>/jobs/inbox.json. This module takes it
-- exactly once (its key is recorded in receipts.jsonl), keeps it in
-- active.json so a restarted seat resumes it, runs it through the same
-- ordinary verbs the autonomous brain uses, and appends every state change
-- with the world evidence that decided it. A newer request supersedes the
-- running one; "resume" ends it. Fights are never pre-empted: a job waits.

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
    receipt(rs, old, "superseded", now, "replaced by " .. job.key)
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

--- Run the active request job, if any. `ctx` carries the shared lifecycle
--- (`life`, `lstate`) and whether the seat is in a fight. Returns an intent
--- or nil; nil lets the autonomous brain act this frame.
function M.step(view, rs, now, ctx)
  if not rs.dir then return nil end
  if not rs.seen then
    load_seen(rs)
    resume_active(rs, view, now)
  end
  if not rs.last_poll or now - rs.last_poll >= POLL_SECONDS then
    rs.last_poll = now
    take_inbox(rs, view, now)
  end
  if ctx.fighting or view.is_dead or view.is_ghost then return nil end
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
  elseif choice == "train" then
    if not job.train_started then
      job.train_started = true
      job.trained0 = lstate.trained_spells
      lstate.trained_level = (view.level or 1) - 1
    end
    local train = life.train_step(view, lstate, now, false)
    if train then return train end
    if lstate.train_since == nil or elapsed > TRAIN_SECONDS then
      finish(rs, job, lstate.trained_spells > job.trained0 and "done" or "failed", now,
        "trainer visit ended", { learned = tostring(lstate.trained_spells - job.trained0) })
    end
    return nil
  end
  finish(rs, job, "failed", now, "unknown choice " .. tostring(choice))
  return nil
end

return M
