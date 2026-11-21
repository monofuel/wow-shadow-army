-- Home army: Murist escort with class roles and a solo-leveling fallback.
-- Runs in the fork's embedded lua-bot against the raw Observation mirror.

local solo = require("accelerated")
-- Dotted, like traverse's config.* requires: the lua-bot's package.path is the
-- repo's lua/ and lua/entry/, so a bare "road_route" does not resolve at
-- runtime even though the test harness puts lua/tools on LUA_PATH.
local road_route = require("tools.road_route")
local disposition = require("tools.item_disposition")
local life = require("tools.lifecycle")
local requests = require("tools.requests")
local talents = require("tools.talent_plan")
-- Home is the dogfood pen, not a scored league: run the soft-quest path here
-- so the new quest stack gets exercised where monofuel can watch. Scored
-- leagues stay grind-only until a rerun A/B beats the 4.791 baseline.
solo.set_quests(true)
solo.set_objective_travel(true)

local M = {}

local MURIST = "murist"
local NEAR_YARDS = 8.0
local HARD_LEASH_YARDS = 18.0
local HEAL_RANGE_YARDS = 30.0
local RES_WAIT_SECONDS = 20.0
-- A release asks the server to relocate the ghost; repeat it only if the
-- seat is still a corpse after this long.
local RELEASE_RETRY_SECONDS = 10.0
local PROMOTE_RETRY_SECONDS = 5.0
-- Cloth dies in two hits from what Murist pulls. Below this, stop
-- swinging and step out so the healer has a target instead of a corpse.
local FLEE_HP_PCT = 35.0
local FLEE_YARDS = 18.0

-- The healer's mana IS the party's health bar. Smite is 15-30 mana a cast and
-- the wand is free, so below the wand floor every point is worth more as the
-- next heal than as one more Smite tick; below the conserve floor the seat
-- stops spending mana on damage at all. Shadow Word: Pain is the efficient
-- middle ground and keeps its own floor. Measured on Beru (priest 8, ~250
-- mana): a Smite-only filler empties the bar in about nine casts, which is
-- one add away from a party wipe.
local WAND_MANA_PCT = 70.0
local DOT_MANA_PCT = 40.0
local CONSERVE_MANA_PCT = 20.0
-- Under the conserve floor the pool is triage only: topping a scratch off at
-- 85% is exactly what leaves a healer empty for the pull that matters.
local CONSERVE_HEAL_PCT = 60.0
-- Shoot is an auto-repeat TOGGLE, not a cast. Re-pressing it while the wand
-- is firing cancels it (fork environment/client/client_actions_gameplay.nim:
-- isActiveAutoRepeatSpell -> clearAutoRepeatSpell, on the wire as
-- CMSG_CANCEL_AUTO_REPEAT_SPELL), and the pilot has no guard of its own -- it
-- presses ACTIONBUTTON<n> for any intent spell on a 0.4s throttle, so a brain
-- that asks for 5019 every tick strobes the wand and never lands a shot. The
-- button's own `active` flag is the client's auto-repeat state for that spell
-- and is authoritative, but it only latches on the NEXT observation, so the
-- seat also remembers its own press to cover the gap.
local WAND_REPRESS_SECONDS = 3.0
-- Power Word: Shield absorbs; it has to be up BEFORE the swing lands to be
-- worth its mana. Waiting for the tank to hit the 50% emergency line means
-- the shield races the hit that takes him to 35 -- and loses. Renew is 15
-- mana ticking over 15 seconds against a 30 mana Lesser Heal that arrives
-- 1.5s after the damage, so on a tank who is actively being hit it is upkeep,
-- not a top-off.
local TANK_SHIELD_PCT = 60.0
local TANK_RENEW_PCT = 95.0
-- Battle Shout is aura-gated, but if a seat's own aura list ever lags the
-- gate opens every tick and the shout becomes the rage sink instead of the
-- rotation. The floor bounds that failure to one wasted global per interval.
local SHOUT_RETRY_SECONDS = 5.0
-- A mob past this is not peelable whatever its target field says (the same
-- cap the escort's stale-target scan already uses).
local PEEL_RANGE_YARDS = 50.0
-- The roster carries no role field and every home seat is rolled by hand, so
-- the two seats the tank and the healer care about are named, exactly the way
-- Murist is.
local HEALER_NAME = "beru"
local TANK_NAME = "tusk"

-- Long rejoins go by ROAD. Under this the crow line is the right answer: the
-- detour to reach pavement costs more than the walk it saves, and the router
-- says so itself (short-hop). Over it, a straight line through open country is
-- an aggro chain and a corpse run, and the road is a freeway.
local ROAD_MIN_YARDS = 80.0
-- A bank this tall next to the road is how a 17yd follow grinds z=39 while
-- Murist stands on z=43. Six yards was too generous for Tirisfal terraces.
local ROAD_CLIFF_Z = 3.0
-- Walk at the route point this far ahead rather than at the leader, so the
-- pilot's own navmesh routing stays ON the road between waypoints. About one
-- decimation step of lua/data/bot_roads.lua.
local ROAD_LOOKAHEAD_YARDS = 20.0
-- Waypoints are handholds, not destinations: stop short and the next decide()
-- has already moved the target up the road.
local ROAD_WAYPOINT_STOP = 10.0

-- Wedge escape for the long legs the escort walks blind: the corpse run and
-- the off-screen rejoin. Both hand a far goal to the route engine and then
-- trust nav_progress, which happily reports "following" while the seat grinds
-- a cliff face for minutes (Igris, ghost at Undercity 1780,221 with his corpse
-- 440yd north, zero displacement, 2026-08-16). The solo brain has had this
-- watchdog since the Deathknell church wedge; recovery and rejoin never ran
-- it, because decide() returns out of those branches before solo.decide is
-- ever reached. Same shape as accelerated's unstick_step: short local_steer
-- legs, jump allowed (upstream only arms the slide/jump reflex for
-- local_steer goals), a fresh bearing per attempt.
local STUCK_STILL_SECONDS = 8.0
local STUCK_YARDS = 3.0
-- Wall-clock alone is not evidence: decide runs at simulation cadence (~12 Hz
-- on the home seats), so a wedge is only real when several consecutive frames
-- also saw no displacement.
local STUCK_STILL_FRAMES = 4
local STUCK_LEG_YARDS = 22.0
local STUCK_SECONDS = 6.0
-- A gap this long between watchdog calls means the seat left the recovery or
-- rejoin leg entirely; the old anchor is stale and must not be resumed.
local STUCK_GAP_SECONDS = 2.0

local CLASS_WARRIOR = 1
local CLASS_ROGUE = 4
local CLASS_PRIEST = 5
local CLASS_MAGE = 8
local CLASS_WARLOCK = 9

-- Life Tap paid out of combat to fund a pet summon. Higher floor than the
-- in-combat tap (18% mana / 40% health) because nothing is threatening us
-- here and the health has to survive the leader's next pull.
local SUMMON_LIFE_TAP_MIN_HEALTH_PCT = 65.0
-- A solo pull only gains a nuke above this mana (the grinder's own floor).
local SOLO_NUKE_MANA_PCT = 35.0

-- Stranded chat box (the 0057 Failure-4 gap): every lifecycle verb —
-- /reclaim, /acceptgroup, /interact — drives the chat edit box, and an
-- interrupted sequence leaves it open eating every later keypress. The solo
-- brain has had this flush since 0057; the party brain did NOT, which is how
-- Igris stood on his corpse looping a /reclaim that never landed.
local CHAT_STUCK_SECONDS = 4.0

-- Party banter. The line itself is written host-side by the local LLM and
-- left in the seat's outbox; the brain only decides WHEN a seat may speak.
-- Speaking is an idle-only luxury: it borrows the same edit box every
-- lifecycle verb needs, so it never starts while there is a fight to run.
local CHAT_POLL_SECONDS = 1.0
local CHAT_MIN_GAP_SECONDS = 20.0
-- Under the stranded-box flush window, so a sequence that cannot finish is
-- abandoned by its owner rather than swept up as wreckage.
local CHAT_SEND_TIMEOUT = 3.0
local CHAT_MAX_TEXT = 120
-- A seat that was away answers nothing: the mailbox survives a reload and a
-- relaunch, and a reply to a question asked an hour ago reads as a ghost.
local CHAT_STALE_SECONDS = 60.0

-- Persistent progression state (lua/tools/lifecycle.lua): pet, binding,
-- gear, training and class-quest bookkeeping for this seat.
local lstate = life.new_state()
-- The player's accepted requests (tools/bot_requests.nim on the host) are
-- durable jobs in this seat's directory; they survive reload and restart.
local rstate = requests.from_env()
-- One learn_talent at a time, acknowledged by the observed rank.
local tstate = talents.new_state()
local dead_since = nil
local release_sent_at = nil
local last_promote_at = nil
local stuckAnchor = nil
local stuckSince = nil
local stuckFrames = 0
local stuckSeenAt = nil
local stuckUntil = nil
local stuckBearing = 0
local chatOpenSince = nil
local chat_outbox = nil
local chat_last_poll_at = nil
local chat_last_sent_at = nil
local chat_pending = nil
-- Class-tactic memory in one table (the main chunk sits at Lua's 200-local
-- limit): the seat's own last wand press (WAND_REPRESS_SECONDS), its last
-- Battle Shout, its own target-debuff requests per mob (see debuff_due), and
-- its own Fear request, the Fear tries spent on each mob this fight and the
-- escape leg a landed Fear started (see warlock_fear and fear_escape in
-- decide).
local tactic = { wand_at = nil, wand_guid = nil, shout_at = nil, debuffs = {},
  fear = nil, fear_tries = {}, escape = nil }
-- Vanilla AFK is ~5 min with no movement. Formation hold is silent.
local FIDGET_SECONDS = 90.0
local fidget_at = nil
-- Formation range is a stop, not a park. A leader still moving inside
-- NEAR_YARDS has to stay a follow or the seat stands while he runs off.
local LEAD_RUN_YDS = 1.5
local LEAD_STILL_YDS = 0.5
local LEAD_STILL_SECONDS = 0.4
-- Re-engage distance for a seat stopped at a moving leader's heels; the
-- 2yd follow stop below it is the hysteresis band.
local TRAIL_RESUME_YARDS = 4.0
local last_lead = nil

local AURA_FAMILIES = {
  ["curse of agony"] = { 980, 1014, 6217, 11711, 11712, 11713 },
  ["corruption"] = { 172, 6222, 6223, 7648, 11671, 11672 },
  ["immolate"] = { 348, 707, 1094, 2941, 11665, 11667, 11668 },
  ["fear"] = { 5782, 6213, 6215 },
  ["demon skin"] = { 687, 696 },
  ["demon armor"] = { 706, 1086, 11733, 11734, 11735 },
  ["battle shout"] = { 6673, 5242, 6192, 11549, 11550, 11551, 25289 },
  ["rend"] = { 772, 6546, 6547, 6548, 11572, 11573, 11574 },
  ["demoralizing shout"] = { 1160, 6190, 11554, 11555, 11556 },
  ["power word shield"] = { 17, 592, 600, 3747, 6065, 6066, 10898, 10899, 10900, 10901 },
  ["weakened soul"] = { 6788 },
  ["renew"] = { 139, 6074, 6075, 6076, 6077, 6078, 10927, 10928, 10929 },
  ["power word fortitude"] = { 1243, 1244, 1245, 2791, 10937, 10938 },
  ["inner fire"] = { 588, 7128, 602, 1006, 10951, 10952 },
  ["shadow word pain"] = { 589, 594, 970, 992, 2767, 10892, 10893, 10894 },
  ["frost armor"] = { 168, 7300, 7301 },
  ["ice armor"] = { 7302, 7320, 10219, 10220 },
  ["mage armor"] = { 6117, 22782, 22783 },
}

local function lower(value)
  return tostring(value or ""):lower()
end

local function normalized(value)
  return lower(value):gsub("[^%w]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function guid_equal(a, b)
  if a == nil or b == nil then return false end
  return tostring(a) == tostring(b) and tostring(a) ~= "0"
end

local function percent(current, maximum)
  maximum = tonumber(maximum) or 0
  if maximum <= 0 then return 100.0 end
  return (tonumber(current) or 0) * 100.0 / maximum
end

local function health_pct(row)
  if not row or row.health_known == false then return 100.0 end
  return percent(row.health, row.max_health)
end

local function self_health_pct(view)
  if view.health_known == false then return 100.0 end
  return percent(view.health, view.max_health)
end

local function mana_pct(view)
  local powers, maxima = view.powers or {}, view.max_powers or {}
  return percent(powers[1], maxima[1])
end

local function point(row)
  if not row then return nil end
  if row.location and row.location.position then return row.location.position end
  -- Roster rows and some live mirrors are flat {x,y,z}, not MapPosition.
  if row.location and row.location.x then return row.location end
  if row.position then return row.position end
  return nil
end

local function view_point(view)
  if not view or not view.location then return nil end
  if view.location.position then return view.location.position end
  if view.location.x then return view.location end
  return nil
end

local function distance(a, b)
  if not a or not b then return nil end
  local dx = (a.x or 0) - (b.x or 0)
  local dy = (a.y or 0) - (b.y or 0)
  local dz = (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- The router reports "following" while the client repeats the same pose
-- (Igris, 2448,445 z39 vs Murist at z43). Walkout / failed_here / same-pose
-- means the planned corridor is dead; hop, don't re-ask for the same route.
local function nav_pose_dead()
  local nav = wow.nav_progress() or {}
  if nav.failed_here then return true end
  if tostring(nav.state or "") == "walkout" then return true end
  local err = tostring(nav.error or "")
  return string.find(err, "same pose", 1, true) ~= nil
end

local function apply_nav_fallback(intent)
  local nav = wow.nav_progress() or {}
  if tostring(nav.state or "") == "unavailable" or nav_pose_dead() then
    intent.route_profile = nil
    intent.navigation_mode = "local_steer"
    if nav_pose_dead() then intent.allow_jump = true end
  end
  return intent
end

-- True when `wp` is closer to `goal` than `mine` is, in the XY plane.
-- A road hop that fails this is how a follow walks AWAY from Murist.
local function closer_on_plane(mine, wp, goal)
  if not mine or not wp or not goal then return false end
  local function d2(a, b)
    local dx = (a.x or 0) - (b.x or 0)
    local dy = (a.y or 0) - (b.y or 0)
    return dx * dx + dy * dy
  end
  return d2(wp, goal) + 1.0 < d2(mine, goal)
end

-- The intent boundary has no follow or assist verb (intent.nim knows
-- navigate/attack/interact/...); emitting one parked the seat in bad_intent
-- holds while mobs beat on it. Following IS navigating to where the leader
-- stands, at formation distance, steering locally so town navmesh gaps
-- cannot stall the escort.
local road_waypoint
local function follow_leader(view, leader, reason, moving)
  local p = point(leader)
  if not p then return { kind = "hold", reason = "leader_position_unknown" } end
  -- No allow_jump: local_steer reads it as a license to hop continuously
  -- while closing, and a formation follow on open ground never needs it.
  -- safe_ground, not prefer_ground: the latter will walk a hillside that
  -- "is ground" (Shadowfel, 2491,-441,z85 over Murist at z77).
  -- stop_distance 6 on a runner is "reached" while he is still pulling away.
  local intent = {
    kind = "navigate",
    x = p.x, y = p.y, z = p.z,
    stop_distance = moving and 2.0 or (NEAR_YARDS * 0.75),
    route_profile = "safe_ground",
    reason = reason,
  }
  if leader.location and leader.location.map_id then
    intent.map_id = math.floor(leader.location.map_id)
  end
  -- Roads when the crow line is a long walk OR a cliff: height gap at
  -- hard-leash range is how a seat climbs the bank next to the road.
  local mine = view_point(view)
  local d2 = nil
  local dz = 0
  if mine then
    local dx = (mine.x or 0) - (p.x or 0)
    local dy = (mine.y or 0) - (p.y or 0)
    d2 = math.sqrt(dx * dx + dy * dy)
    dz = math.abs((mine.z or 0) - (p.z or 0))
  end
  -- A height gap used to force a road even at 20yd — that waypoint can sit
  -- AWAY from Murist (Shadowfel ran 2812,491 while Murist was at 2655,456).
  -- Only take pavement that is strictly closer to the leader in the plane.
  if mine and intent.map_id and d2 and d2 > ROAD_MIN_YARDS then
    local wp = road_waypoint(mine, p, intent.map_id)
    if wp and closer_on_plane(mine, wp, p) then
      intent.x, intent.y, intent.z = wp.x, wp.y, wp.z
      intent.stop_distance = ROAD_WAYPOINT_STOP
      intent.reason = reason .. "_road"
    end
  end
  -- Inside one road-step of Murist, walk AT him. safe_ground navmesh at
  -- 20-40yd is how Shadowfel "follows" by touring Agamand.
  if d2 and d2 <= ROAD_MIN_YARDS then
    intent.route_profile = nil
    intent.navigation_mode = "local_steer"
  elseif wow.nav_progress().state == "unavailable" then
    intent.route_profile = nil
    intent.navigation_mode = "local_steer"
  end
  -- Running straight at a runner settles the seat exactly on the edge of
  -- its stop ball, so each turn or easing-off drops it inside and the pilot
  -- releases forward: stop-go-stop at his heels. A seat already stopped in
  -- the ball stays stopped until he is TRAIL_RESUME_YARDS clear, then runs
  -- a gap that absorbs the next turn instead of chattering on the edge.
  if moving and d2 and d2 <= TRAIL_RESUME_YARDS and
      tostring(wow.nav_progress().state or "") == "reached" then
    intent.stop_distance = TRAIL_RESUME_YARDS
  end
  return intent
end

-- Roster rows carry a flat WorldPoint ({map_id,x,y,z,o}) precisely so the
-- group stays locatable when the member's player object is not in `units` —
-- the escort used to go solo the moment Murist left visual range, which read
-- as "the bots refuse to come to me".
local function member_point(member)
  if member and member.location_known and member.location then
    return member.location
  end
  return nil
end

-- Road network, lazily loaded and injectable. The generated table is a plain
-- module (tools/gen_bot_road_data.py), but a seat whose deploy is missing it
-- must still walk, so the require is guarded: no data simply means every
-- rejoin is the crow line it was before.
local road_segments = nil
local road_loaded = false
local road_graphs = {}

-- nil restores the generated file; a table (including {}) replaces it. Tests
-- inject synthetic maps this way so they never depend on a baked artifact.
function M.set_roads(segments)
  road_segments = segments
  road_loaded = segments ~= nil
  road_graphs = {}
end

local function road_data()
  if not road_loaded then
    road_loaded = true
    local ok, data = pcall(require, "data.bot_roads")
    if ok and type(data) == "table" then
      road_segments = data
    else
      road_segments = nil
      wow.log("road data unavailable: " .. tostring(data))
    end
  end
  return road_segments
end

-- One graph per continent map, built once and kept: the build is the only
-- expensive call in road_route (~10 ms for a continent), a route over it is
-- half a millisecond, so the per-tick cost of re-routing is noise.
local function road_graph(map_id)
  local data = road_data()
  if not data then return nil end
  local segments = data[map_id]
  if not segments then return nil end
  local graph = road_graphs[map_id]
  if not graph then
    graph = road_route.build(segments)
    road_graphs[map_id] = graph
  end
  return graph
end

-- The world point to actually walk at for a long rejoin, or nil to keep
-- walking at the leader. nil covers every road bail (no data, a hole in the
-- bake, a road that would not help) AND the last leg, where the next route
-- point IS the leader and the plain rejoin intent already says it better.
-- `opts` goes to road_route.route unchanged; nil is the router's defaults.
-- The route and the waypoint's index in it come back too, for a caller that
-- keeps walking one route instead of re-asking every frame.
function road_waypoint(mine, goal, map_id, opts)
  local graph = road_graph(map_id)
  if not graph then return nil end
  local pts, meta = road_route.route(graph, mine, goal, opts)
  if meta.straight then return nil end
  local x, y, z, i = road_route.nextPoint(pts, mine.x, mine.y,
    ROAD_LOOKAHEAD_YARDS)
  if not x or not i or i >= #pts then return nil end
  local wp = { x = x, y = y, z = z }
  -- closer_on_plane: a waypoint farther from the goal than we already are
  -- is pavement behind us. Walk at the goal instead.
  if not closer_on_plane(mine, wp, goal) then return nil end
  return wp, pts, i
end

-- Height is not evidence of progress here: a seat wedged against the
-- Undercity entrance ramp slides up and down it while going nowhere.
local function distance2d(a, b)
  if not a or not b then return nil end
  local dx = (a.x or 0) - (b.x or 0)
  local dy = (a.y or 0) - (b.y or 0)
  return math.sqrt(dx * dx + dy * dy)
end

local function forget_stuck()
  stuckAnchor, stuckSince, stuckFrames, stuckUntil = nil, nil, 0, nil
end

-- True while something is holding the seat still on purpose. Cancelling those
-- to "escape" is how an escape reflex starts eating its own loot.
local function rejoin_busy(view)
  if view.in_combat then return true end
  if view.chat_input_visible then return true end
  if (view.quest_frame or {}).open or view.gossip_open then return true end
  if (view.active_cast_spell_id or 0) ~= 0 then return true end
  if (view.active_channel_spell_id or 0) ~= 0 then return true end
  for _, node in ipairs(view.ui_nodes or {}) do
    local reference = tostring(node.reference or "")
    if reference:sub(1, 10) == "loot-slot:" or
        reference:sub(1, 11) == "loot-money:" then
      return true
    end
  end
  return false
end

-- Returns an escape leg when a recovery or rejoin walk has stopped displacing,
-- and nil otherwise. Anchor bookkeeping happens here so each call site has one
-- call. `busy` is always false on the ghost path: a ghost cannot be attacked,
-- looted or talked to, so nothing can legitimately pin it.
local function stuck_step(view, now, busy, reason)
  local pos = view_point(view)
  if not pos or not view.location then
    forget_stuck()
    stuckSeenAt = now
    return nil
  end
  -- A leg the seat was not walking last tick says nothing about this one.
  if stuckSeenAt and now - stuckSeenAt > STUCK_GAP_SECONDS then forget_stuck() end
  stuckSeenAt = now

  local pinned = view.movement_allowed == false or view.rooted
  if busy or pinned then
    stuckAnchor, stuckSince, stuckFrames = { x = pos.x, y = pos.y }, now, 0
    if stuckUntil and now >= stuckUntil then stuckUntil = nil end
    return nil
  end
  if not stuckAnchor or not stuckSince then
    stuckAnchor, stuckSince, stuckFrames = { x = pos.x, y = pos.y }, now, 0
    return nil
  end
  if distance2d(pos, stuckAnchor) >= STUCK_YARDS then
    -- Real displacement: the leg is working, and any open escape window is
    -- over the moment it did its job.
    stuckAnchor, stuckSince, stuckFrames = { x = pos.x, y = pos.y }, now, 0
    stuckUntil = nil
    return nil
  end
  stuckFrames = stuckFrames + 1

  if stuckUntil and now < stuckUntil then
    -- keep the current bearing until the window closes
  elseif now - stuckSince > STUCK_STILL_SECONDS and
      stuckFrames >= STUCK_STILL_FRAMES then
    stuckBearing = (stuckBearing + 1) % 8
    stuckUntil = now + STUCK_SECONDS
    wow.log(string.format(
      "unstick %s bearing %d at %.1f,%.1f allowed=%s rooted=%s nav=%s",
      tostring(reason), stuckBearing, pos.x, pos.y,
      tostring(view.movement_allowed), tostring(view.rooted),
      tostring(wow.nav_progress().state)))
  else
    return nil
  end

  local angle = stuckBearing * math.pi / 4.0
  return {
    kind = "navigate",
    x = pos.x + math.cos(angle) * STUCK_LEG_YARDS,
    y = pos.y + math.sin(angle) * STUCK_LEG_YARDS,
    z = pos.z,
    map_id = math.floor(view.location.map_id or 0),
    stop_distance = NEAR_YARDS,
    navigation_mode = "local_steer",
    allow_jump = true,
    reason = reason or "unstick",
  }
end

local function rejoin_leader(view, member)
  local p = member_point(member)
  if not p then return nil end
  local mine = view_point(view)
  if mine and view.location and p.map_id and
      math.floor(view.location.map_id or -1) ~= math.floor(p.map_id) then
    return nil -- cross-map rejoin is a taxi problem, not a walk
  end
  -- Off-screen roster rows carry NO height: vanilla writes
  -- GROUP_UPDATE_FLAG_POSITION as int16 x + int16 y only, so the projection
  -- fills z = 0.0 and says so with elevation_known = false. Taken literally
  -- that walks the seat at a point tens of yards under the world — the router
  -- re-plans every tick and the seat crawls (Igris, 1.1 yd/s vs 4 yd/s on a
  -- corpse run with a real z, 2026-08-16) until something kills it. Our own
  -- z is the best ground guess available, and the leash has to be flat or
  -- our own height alone can exceed it while we stand on the leader.
  local flat = member.elevation_known ~= true
  if flat and mine then
    p = { map_id = p.map_id, x = p.x, y = p.y, z = mine.z }
  end
  local d = flat and distance2d(mine, p) or distance(mine, p)
  if not d or d <= NEAR_YARDS then return nil end
  local intent = {
    kind = "navigate",
    x = p.x, y = p.y, z = p.z,
    stop_distance = NEAR_YARDS,
    route_profile = "safe_ground",
    reason = "rejoin_murist_far",
  }
  intent.map_id = math.floor(p.map_id)
  -- Roads are freeways. Past ROAD_MIN_YARDS the crow line is a tour of every
  -- mob field between here and the leader, so hand the walk to the road router
  -- and chase the next waypoint instead; the leader keeps moving, so this is
  -- re-decided from scratch every tick rather than committed to a plan.
  if d > ROAD_MIN_YARDS and mine then
    local wp = road_waypoint(mine, p, intent.map_id)
    if wp and closer_on_plane(mine, wp, p) then
      intent.x, intent.y, intent.z = wp.x, wp.y, wp.z
      intent.stop_distance = ROAD_WAYPOINT_STOP
      intent.reason = "rejoin_murist_road"
    end
  end
  -- Same story as the quest pursuits: town navmesh holes report
  -- "unavailable", and a stalled route beats no movement not at all —
  -- steer at the position directly until the router has an answer.
  if wow.nav_progress().state == "unavailable" then
    intent.route_profile = nil
    intent.navigation_mode = "local_steer"
  end
  return intent
end

local function party_member(view, name)
  local wanted = lower(name)
  for _, member in ipairs((view.party and view.party.members) or {}) do
    if lower(member.name) == wanted then return member end
  end
  return nil
end

local function party_member_by_guid(view, guid)
  for _, member in ipairs((view.party and view.party.members) or {}) do
    if guid_equal(member.guid, guid) then return member end
  end
  return nil
end

local function visible_unit(view, guid)
  for _, unit in ipairs(view.units or {}) do
    if guid_equal(unit.guid, guid) then return unit end
  end
  return nil
end

-- "Is this guid the party's business" -- one of us, a member, or a unit
-- somebody in the party summoned. The escort's threat scan, the tank's peel
-- scan and the taunt gate all resolve it here so they cannot disagree about
-- whose fight this is.
local function is_party_property(view, guid)
  if guid_equal(guid, view.player_guid) then return true end
  if party_member_by_guid(view, guid) then return true end
  local u = visible_unit(view, guid)
  if u and (u.summoner_guid or 0) ~= 0 then
    return guid_equal(u.summoner_guid, view.player_guid) or
      party_member_by_guid(view, u.summoner_guid) ~= nil
  end
  return false
end

local function visible_player_by_name(view, name)
  local member = party_member(view, name)
  if member and member.guid then
    local by_guid = visible_unit(view, member.guid)
    if by_guid then return by_guid end
  end
  local wanted = lower(name)
  for _, unit in ipairs(view.units or {}) do
    if lower(unit.name) == wanted and unit.is_player_controlled ~= false then
      return unit
    end
  end
  return nil
end

local function hostile(unit)
  if not unit or unit.player_can_attack ~= true then return false end
  if unit.death_known and unit.is_dead then return false end
  if unit.health_known and (unit.health or 0) <= 0 then return false end
  return true
end

local function spell_ready(spell, friendly)
  if not spell or spell.passive or spell.from_item then return false end
  -- A friendly cast addressed by target_guid is judged on the host's
  -- target-independent readiness (learned, cooldown, mana, reagents,
  -- equipment, aura state): with a mob selected, stock usable reports every
  -- heal unusable. Only hosts that honor target_guid export it.
  if friendly and spell.readiness ~= nil then return spell.readiness == "ready" end
  if spell.usable_known and not spell.usable then return false end
  if spell.not_enough_mana then return false end
  if (spell.cooldown_ms or 0) > 0 then return false end
  if spell.reagents_available == false then return false end
  if spell.requires_equipped_item and spell.equipped_item_requirement_known and
      not spell.equipped_item_requirement_met then return false end
  if spell.requires_caster_aura_state and
      spell.caster_aura_state_requirement_known and
      not spell.caster_aura_state_requirement_met then return false end
  return true
end

-- spell_facts arrives EMPTY on live seats (the spellbook fact pipeline needs
-- catalog definitions the embedded client never requests — 2026-08-16, found
-- when every escort cast fell through to melee). The action bars carry the
-- same fields for everything placed on them, which for a rolled seat is its
-- whole kit; facts win whenever they do exist.
local function spell_candidates(view)
  local facts = view.spell_facts or {}
  if #facts > 0 then
    -- The host says which learned spells the seat has an ordinary input for
    -- (a keyed bar button or its spellbook entry). A higher rank it cannot
    -- cast would otherwise win every pick and never fire.
    local out = {}
    for _, fact in ipairs(facts) do
      if fact.execution ~= "unavailable" then out[#out + 1] = fact end
    end
    return out
  end
  local out = {}
  for _, button in ipairs(view.action_buttons or {}) do
    if (button.spell_id or 0) ~= 0 then
      out[#out + 1] = {
        spell_id = button.spell_id,
        name = button.spell_name,
        name_known = (button.spell_name or "") ~= "",
        rank = 0,
        usable_known = button.usable_known,
        usable = button.usable,
        not_enough_mana = button.not_enough_mana,
        cooldown_ms = button.cooldown_ms,
        reagents_available = true,
        -- The client's toggle state for this button (fork
        -- client_state/spells.nim ActionButtonModel.checked): true while the
        -- spell is the live auto-repeat (Shoot), the queued next-swing
        -- (Heroic Strike), an in-flight cast, or an aura already on us.
        -- Pressing an already-active modal turns it OFF, so the rotations
        -- read this before re-pressing anything.
        active = button.active,
      }
    end
  end
  return out
end

-- Same match as pick_spell, but for the one spell that is ready EXCEPT that
-- the seat cannot pay for it. The client sets notEnoughMana only from
-- `powers[mana] < powerCost` (fork environment/client/spell_usability.nim
-- resultFor / SpellInsufficientResource), so this is a real empty bar, not a
-- projection quirk -- and it drags `usable` false with it, which is why
-- spell_ready rejects the candidate outright.
local function mana_blocked_spell(view, wanted)
  local want = normalized(wanted)
  for _, spell in ipairs(spell_candidates(view)) do
    local name = normalized(spell.name)
    if spell.name_known ~= false and not spell.passive and not spell.from_item and
        spell.not_enough_mana and (spell.cooldown_ms or 0) <= 0 and
        spell.reagents_available ~= false and
        (name == want or name:find(want, 1, true)) then
      return spell
    end
  end
  return nil
end

-- prefer_low_rank picks the CHEAPEST rank instead of the strongest one, which
-- is what a small deficit wants: rank 3 Lesser Heal on a 12% scratch is most
-- of the cast overhealed and all of the mana spent. Bar-derived candidates all
-- report rank 0, so on a live seat this is a no-op tiebreak until the ranks
-- come from real facts.
local function pick_spell(view, priorities, prefer_low_rank, friendly)
  for _, wanted in ipairs(priorities) do
    local want = normalized(wanted)
    local best = nil
    for _, spell in ipairs(spell_candidates(view)) do
      local name = normalized(spell.name)
      local better = not best or (prefer_low_rank
        and (spell.rank or 0) < (best.rank or 0)
        or not prefer_low_rank and (spell.rank or 0) > (best.rank or 0))
      if spell.name_known ~= false and spell_ready(spell, friendly) and
          (name == want or name:find(want, 1, true)) and better then
        best = spell
      end
    end
    if best then return best, want end
  end
  return nil, nil
end

-- A spell cast on a teammate by target_guid. On a host that drops
-- target_guid the cast lands on the current selection, so its stock
-- selection-relative usability still has to gate it there.
local function pick_friendly_spell(view, priorities, prefer_low_rank)
  return pick_spell(view, priorities, prefer_low_rank,
    view.cast_target_supported == true)
end

local function aura_present(ids, family, selected_spell_id)
  local wanted = {}
  for _, id in ipairs(AURA_FAMILIES[family] or {}) do wanted[id] = true end
  if selected_spell_id then wanted[selected_spell_id] = true end
  for _, id in ipairs(ids or {}) do
    if wanted[id] then return true end
  end
  return false
end

-- Group loot. A live roll puts a GroupLootFrame1..4 prompt on every seat and
-- the drop stays locked until all of them answer or the timer runs out, so a
-- silent bot holds the party's loot hostage for the full window. The three
-- buttons arrive as presented ui_nodes referenced
-- "loot-roll:<target>:<slot>:need|greed|pass" (client ui/loot_frame.nim
-- drawLootRollArtButton), all enabled while the roll is active and the seat's
-- choice is still unknown. The target is a uint64 the reference spells as
-- unsigned decimal while Lua sees guids as negative int64, so match on the
-- prefix and the choice suffix only and never on the guid itself.
local ROLL_PREFIX = "loot-roll:"

local function roll_reference(view, choice)
  local suffix = ":" .. choice
  for i = 1, #(view.ui_nodes or {}) do
    local node = view.ui_nodes[i]
    local reference = node.reference_id or ""
    if node.enabled and node.hit_testable and
        reference:sub(1, #ROLL_PREFIX) == ROLL_PREFIX and
        reference:sub(-#suffix) == suffix then
      return reference
    end
  end
  return nil
end

-- Greed, or pass when greed is not on offer. Need is never pressed: these
-- seats exist to escort Murist, not to roll his drops away from him.
-- TEMP probe (2026-08-16): live rolls are not being answered; show what the
-- seat actually sees whenever anything roll-shaped is in ui_nodes.
local rollProbeAt = nil

local function loot_roll_step(view)
  do
    local now = tonumber(view.simulation_time) or 0
    if not rollProbeAt or now - rollProbeAt > 5 then
      local lines = ""
      for i = 1, #(view.ui_nodes or {}) do
        local node = view.ui_nodes[i]
        local ref = tostring(node.reference_id or "")
        local src = tostring(node.source_name or "")
        if ref:find("roll", 1, true) or src:find("GroupLoot", 1, true) then
          lines = lines .. string.format(" [%s|%s|en=%s|hit=%s]",
            src, ref, tostring(node.enabled), tostring(node.hit_testable))
        end
      end
      if lines ~= "" then
        rollProbeAt = now
        wow.log("roll probe:" .. lines)
      end
    end
  end
  local reference = roll_reference(view, "greed")
  if reference then
    return { kind = "ui_press", reference = reference, reason = "group_loot_greed" }
  end
  reference = roll_reference(view, "pass")
  if reference then
    return { kind = "ui_press", reference = reference, reason = "group_loot_pass" }
  end
  return nil
end

-- Vendor sell (monofuel, 2026-08-16: "if our bot has gear that it can't
-- equip, it should sell"). The disposition table is pure and lives in
-- lua/tools/item_disposition.lua; this is only the WHEN and the throttle.
--
-- FEATURE-DETECTED, AND TODAY IT DETECTS NOTHING. The fork's Observation
-- carries every fact this needs — inventory_items rows with class/subclass/
-- quality/container_slots, equipment_items with the four carried-bag slots,
-- merchant_open/merchant_guid — but bots/lua_bot/view.nim projects none of
-- them into the Lua view, and the ui_press intent only ever left-clicks
-- (selling a bag item is a RIGHT click: environment/client/ui/
-- inventory_item_button.nim:352). So a live seat takes the first `return nil`
-- below every time and this costs one table lookup per tick. Ticket
-- tickets/open/0073 is the fork half. Same idiom as view.chat_send_supported:
-- a host that cannot carry the verb simply leaves the flag unset.
--
-- The middle state is the useful one while 0073 is open: as soon as the view
-- carries the rows, the seat LOGS the shortlist it would sell at every vendor
-- it opens, so monofuel can read the policy's judgement out of wow.log before
-- any item actually moves.
-- One sale at a time, owned until the bags prove it. The host shares one
-- 0.6 s item-verb floor between `interact` and `sell_item` (bots/lua_bot/
-- pilot.nim ItemVerbCooldownSeconds) and refuses an early sale silently, and
-- the merchant usually opens inside that floor — so the first sale of every
-- visit is throttled. The pending sale is therefore re-sent every tick (the
-- host floor decides when it actually leaves) and only counts as sold once
-- the carried row disappears or shrinks. Returning an intent every tick also
-- keeps the merchant ours: a nil here falls through to the quest stack, which
-- closes any merchant it did not open.
local VENDOR_SALE_TIMEOUT_SECONDS = 4.0
-- Consecutive unconfirmed sales before the visit stops; the walk back then
-- waits VENDOR_RETRY_SECONDS so a host that cannot finish a sale costs one
-- visit per window instead of an open/close loop.
local VENDOR_MAX_UNCONFIRMED = 3
local VENDOR_RETRY_SECONDS = 300.0
local vendor_merchant = nil
local vendor_sold = {}
local vendor_reported = false
local vendor_gap_logged = false
local vendor_pending = nil
local vendor_unconfirmed = 0
local vendor_seek_after = nil

local function vendor_forget()
  vendor_merchant = nil
  vendor_sold = {}
  vendor_reported = false
  vendor_pending = nil
  vendor_unconfirmed = 0
end

local function carried_row(items, guid)
  for i = 1, #items do
    if tostring(items[i].item_guid or "0") == guid then return items[i] end
  end
  return nil
end

local function vendor_settle(view, items, now)
  -- Resolve the pending sale from the bags. Returns true while it still owns
  -- the merchant (the caller re-sends it), false once it is settled.
  local p = vendor_pending
  local row = carried_row(items, p.guid)
  local left = row and (tonumber(row.count) or 0) or 0
  if left < p.count_before then
    vendor_sold[p.guid] = true
    vendor_pending = nil
    vendor_unconfirmed = 0
    local copper = tonumber(view.copper)
    wow.log(string.format(
      "vendor: sold %s x%d (carried %d->%d) copper %s->%s free %s->%s",
      p.name, p.count_before - left, p.count_before, left,
      tostring(p.copper_before), view.copper_known and tostring(copper) or "?",
      tostring(p.free_before), tostring(view.free_bag_slots)))
    return false
  end
  if now - p.sent_at > VENDOR_SALE_TIMEOUT_SECONDS then
    vendor_sold[p.guid] = "unconfirmed"
    vendor_pending = nil
    vendor_unconfirmed = vendor_unconfirmed + 1
    wow.log(string.format(
      "vendor: sale of %s unconfirmed after %.1fs (still carried x%d)",
      p.name, VENDOR_SALE_TIMEOUT_SECONDS, left))
    if vendor_unconfirmed >= VENDOR_MAX_UNCONFIRMED then
      vendor_seek_after = now + VENDOR_RETRY_SECONDS
      wow.log(string.format(
        "vendor: %d sales in a row unconfirmed — leaving the merchant, " ..
        "next vendor walk in %.0fs", vendor_unconfirmed, VENDOR_RETRY_SECONDS))
    end
    return false
  end
  return true
end

local function vendor_sell_step(view, now)
  if not view.merchant_open then
    vendor_forget()
    return nil
  end
  local merchant = tostring(view.merchant_guid or "0")
  if merchant ~= vendor_merchant then
    vendor_forget()
    vendor_merchant = merchant
  end

  local items = view.inventory_items
  if type(items) ~= "table" then
    if not vendor_gap_logged then
      vendor_gap_logged = true
      wow.log("vendor: bags not projected into the lua view " ..
        "(fork gap, tickets/open/0073) — nothing to sell from here")
    end
    return nil
  end

  local plan = disposition.evaluate({
    items = items,
    keep_item_ids = require("tools.quest_material").objective_item_ids(view),
    equipment = view.equipment_items,
    player = { class_id = view.class_id, level = view.level },
  })

  if not vendor_reported then
    vendor_reported = true
    local names = {}
    for i = 1, #plan.sell do
      names[i] = string.format("%s(%s)", tostring(plan.sell[i].name),
        tostring(plan.sell[i].reason))
    end
    wow.log(string.format("vendor: %d/%d bag items to sell for %dc — %s",
      #plan.sell, #plan.items, plan.sell_copper,
      #names > 0 and table.concat(names, ", ") or "nothing"))
  end

  -- Everything above is observation and is safe on any host. Only this last
  -- step moves an item, and only a host that says it can.
  if not view.sell_supported then return nil end
  -- A fight outranks a sale; the merchant closes and the visit restarts later.
  if view.in_combat then return nil end
  if vendor_unconfirmed >= VENDOR_MAX_UNCONFIRMED then return nil end
  if vendor_pending and vendor_settle(view, items, now) then
    local p = vendor_pending
    return { kind = "sell_item", guid = view.merchant_guid,
      item_guid = p.item_guid, count = p.count_before,
      reason = p.reason }
  end
  if vendor_unconfirmed >= VENDOR_MAX_UNCONFIRMED then return nil end
  for i = 1, #plan.sell do
    local row = plan.sell[i]
    local guid = tostring(row.item_guid or "0")
    if guid ~= "0" and not vendor_sold[guid] then
      vendor_pending = {
        guid = guid, item_guid = row.item_guid, name = tostring(row.name),
        count_before = tonumber(row.count) or 1, sent_at = now,
        copper_before = view.copper_known and tonumber(view.copper) or "?",
        free_before = view.free_bag_slots,
        reason = "vendor_sell_" .. tostring(row.tag):lower(),
      }
      wow.log(string.format("vendor: selling %s x%d — %s",
        tostring(row.name), row.count, row.reason))
      return { kind = "sell_item", guid = view.merchant_guid,
        item_guid = row.item_guid, count = row.count,
        reason = vendor_pending.reason }
    end
  end
  return nil
end

-- Equip carried bags (tickets/open/0073's own closing note: "the *first* order
-- fix there is EQUIP, not sell"). This is the half that actually unwedges a
-- full-bag seat, and unlike selling it needs no vendor, no travel, and no
-- money: the seat is already carrying the pouches, it just never wore them.
-- Full bags hard-block quest turn-ins — vanilla refuses an item reward with
-- zero free slots — so every tick a spare bag stays in the backpack is a
-- turn-in the seat cannot complete.
--
-- Deliberately narrow. It ONLY fills an EMPTY carried-bag slot (equipment
-- slots 19..22). Swapping a worn bag for a roomier one means moving the
-- contents of the old bag first, which nothing here can do, and getting it
-- wrong drops items on the floor. `item_disposition` already draws the same
-- line from the other side: with a free slot it refuses to sell any bag
-- ("free bag slot — equip it"), and it only starts selling spares once all
-- four slots are full. The two halves meet exactly, with no window where a
-- bag is both equip-able and sell-able.
--
-- FEATURE-DETECTED like the sell half: a host that cannot carry the verb
-- leaves `equip_supported` unset and this costs one table lookup per tick.
local EQUIP_GAP_SECONDS = 3.0
-- Give up after this many attempts that did not raise the worn-bag count.
-- Measured 2026-08-16: the fork accepts `equip_item` for a container and the
-- seat emits it happily, but the bag never lands — 68 attempts across seven
-- seats, `character_inventory` slots 19..22 still empty on every bot, and
-- `equipment_items` still reporting zero worn bags. Until that fork gap is
-- closed, an unbounded retry burns a tick every 3s on a live seat forever and
-- buries the log. Three tries is enough to prove the verb is not landing.
local EQUIP_MAX_ATTEMPTS = 3
-- 0074 live: the FIRST accepted equip_item freezes the lua-bot pilot
-- (no later decide, status dies). The attempt budget never runs on a
-- real seat. Flip this when the fork lands bags in slots 19-22.
local EQUIP_EMIT = false
local equip_last_at = nil
local equip_tried = {}
local equip_attempts = 0
local equip_gave_up = false

local function equip_bags_step(view, now)
  if not EQUIP_EMIT then
    if not equip_gave_up then
      equip_gave_up = true
      wow.log("bags: skipping equip_item — 0074 host freeze; standing down")
    end
    return nil
  end
  if not view.equip_supported then return nil end
  if equip_gave_up then return nil end
  -- The verb rejects in combat host-side (bots/lua_bot/pilot.nim), and a
  -- corpse cannot rummage through its own backpack. Refusing here keeps the
  -- rejection out of the status line.
  if view.in_combat or view.is_dead or view.is_ghost then return nil end
  local items = view.inventory_items
  if type(items) ~= "table" then return nil end

  -- An empty carried-bag slot is the whole precondition. `equipped_bags`
  -- counts the filled ones; four means there is nothing to fill and the
  -- spare is the sell path's problem, not ours.
  local bags = disposition.equipped_bags(view.equipment_items)
  if bags.count >= disposition.BAG_SLOT_COUNT then return nil end

  -- A bag that actually landed raises bags.count, which both retires the slot
  -- and resets the patience. Attempts that change nothing are the fork gap
  -- above, and past the budget the seat stops asking rather than spending a
  -- tick every 3s on a verb this host cannot finish.
  if bags.count > 0 then equip_attempts = 0 end
  if equip_attempts >= EQUIP_MAX_ATTEMPTS then
    equip_gave_up = true
    wow.log(string.format(
      "bags: %d equip attempts changed nothing (still %d/%d worn) — " ..
      "host accepts equip_item but the bag never lands; standing down",
      equip_attempts, bags.count, disposition.BAG_SLOT_COUNT))
    return nil
  end

  if equip_last_at and now - equip_last_at < EQUIP_GAP_SECONDS then
    return nil
  end

  -- Largest first: with N free slots and more bags than that, the seat should
  -- end up wearing the roomiest ones. Ties break on the row order the
  -- Observation gave us, so the choice is stable across ticks.
  local best, best_slots = nil, 0
  for i = 1, #items do
    local row = items[i] or {}
    local guid = tostring(row.item_guid or "0")
    local slots = tonumber(row.container_slots) or 0
    if guid ~= "0" and not equip_tried[guid] and
        tonumber(row.item_class_id) == disposition.CLASS_CONTAINER and
        slots > 0 and row.definition_known ~= false and
        not disposition.NEVER_SELL_ITEM_IDS[tonumber(row.item_id) or 0] and
        -- A bag with something in it is someone else's decision: equipping it
        -- is safe, but the seat has no way to know why it is packed.
        (tonumber(row.container_item_count) or 0) == 0 then
      if slots > best_slots then best, best_slots = row, slots end
    end
  end
  if not best then return nil end

  local guid = tostring(best.item_guid)
  equip_tried[guid] = true
  equip_last_at = now
  equip_attempts = equip_attempts + 1
  wow.log(string.format(
    "bags: equipping %s (%d slots) into free bag slot %d/%d",
    tostring(best.name), best_slots, bags.count + 1,
    disposition.BAG_SLOT_COUNT))
  return { kind = "equip_item", item_guid = best.item_guid,
    reason = "equip_bag" }
end

-- Sell only works with an open merchant. A solo seat with 0 free slots and
-- a backpack of grey junk never opens one, so turn-ins stay refused forever
-- (Legia, quest 376, 2026-08-16). Walk to the nearest unit advertising
-- vendor and interact; vendor_sell_step takes the next ticks.
local VENDOR_SEEK_FREE_SLOTS = 2
local VENDOR_INTERACT_STOP = 3.5
local VENDOR_STEER_YARDS = 8
-- The August first-frame interact freeze did not recur: a live vendor
-- interact opens the merchant and decide keeps running. Sales stalled only
-- because nothing owned the merchant through the item-verb floor, which
-- vendor_sell_step now does.
local VENDOR_SEEK_EMIT = true

local function unit_has_service(unit, name)
  for i = 1, #(unit.services or {}) do
    if unit.services[i] == name then return true end
  end
  return false
end

-- Last pure vendor this seat actually saw (guid, position, map). Visible
-- units stop near 100 yd, so a full-bag seat grinding outside the village
-- would otherwise never seek; it walks back to where it last saw one.
local vendor_seen = nil

-- With no vendor ever seen, head for the nearest turn-in of an accepted quest
-- from the generated hub table (lua/data/bot_quest_hubs.lua, private and
-- ignored). Starter villages keep their vendors beside the givers, so the
-- vendor comes into view on the way; arriving without one ends the attempt
-- for the retry window.
local VENDOR_HUB_ARRIVE = 15
local vendor_hubs_loaded, vendor_hubs = false, nil

local function vendor_hub(view)
  if not vendor_hubs_loaded then
    vendor_hubs_loaded = true
    local ok, data = pcall(require, "data.bot_quest_hubs")
    vendor_hubs = ok and type(data) == "table" and data or nil
  end
  local me = view_point(view)
  if not vendor_hubs or not me or not me.x then return nil end
  local map = math.floor((view.location or {}).map_id or 0)
  local best, best_d = nil, nil
  for _, q in ipairs(view.accepted_quests or {}) do
    local hub = vendor_hubs[tonumber(type(q) == "table" and q.quest_id or q) or 0]
    local e = hub and hub.ender
    if e and math.floor(e[1] or -1) == map then
      local d = math.sqrt((e[2] - me.x) ^ 2 + (e[3] - me.y) ^ 2)
      if not best_d or d < best_d then best, best_d = e, d end
    end
  end
  return best, best_d
end

-- A vendor the seat walked toward for VENDOR_TARGET_PATIENCE without the
-- merchant opening is skipped for VENDOR_RETRY_SECONDS, so a fenced-off
-- approach rotates to the next vendor in view instead of looping unstick.
local VENDOR_TARGET_PATIENCE = 25.0
local vendor_skip = {}
local vendor_target, vendor_target_since = nil, nil
-- Unreached vendors in a row before the whole attempt waits out the retry
-- window (Beru in Brill: indoor vendors, router stuck planning, ten in view).
local VENDOR_MAX_UNREACHED = 3
local vendor_unreached = 0

local function nearest_vendor(view)
  local best, best_d = nil, nil
  local pure, pure_d = nil, nil
  for _, unit in ipairs(view.units or {}) do
    if unit_has_service(unit, "vendor") and
        not (unit.death_known and unit.is_dead) and
        not (vendor_skip[tostring(unit.guid)] and
          (view.simulation_time or 0) < vendor_skip[tostring(unit.guid)]) and
        unit.object_kind ~= "player" then
      local d = tonumber(unit.distance) or 1e9
      if not best_d or d < best_d then best, best_d = unit, d end
      -- A questgiver-vendor opens the quest panel, not the merchant
      -- (Baran vs Joshua Kien, 2026-08-16). Prefer a pure vendor.
      if not unit_has_service(unit, "questgiver") then
        if not pure_d or d < pure_d then pure, pure_d = unit, d end
        local pos = point(unit)
        if pos and pos.x then
          vendor_seen = { guid = unit.guid, name = unit.name,
            x = pos.x, y = pos.y, z = pos.z,
            map_id = unit.location and unit.location.map_id }
        end
      end
    end
  end
  if pure then return pure, pure_d end
  return best, best_d
end

local function vendor_seek_step(view, now)
  if not VENDOR_SEEK_EMIT then return nil end
  -- Every tick, so the position is known before the bags fill.
  nearest_vendor(view)
  if vendor_seek_after and now < vendor_seek_after then return nil end
  if view.in_combat or view.is_dead or view.is_ghost then return nil end
  if view.merchant_open then vendor_target = nil; vendor_unreached = 0; return nil end
  if not view.sell_supported then return nil end
  if party_member(view, MURIST) then return nil end
  if not view.bag_space_known then return nil end
  local free = tonumber(view.free_bag_slots)
  if free == nil or free > VENDOR_SEEK_FREE_SLOTS then return nil end
  local items = view.inventory_items
  if type(items) ~= "table" then return nil end
  local plan = disposition.evaluate({
    items = items,
    keep_item_ids = require("tools.quest_material").objective_item_ids(view),
    equipment = view.equipment_items,
    player = { class_id = view.class_id, level = view.level },
  })
  if #plan.sell == 0 then return nil end
  local vendor, vendor_d = nearest_vendor(view)
  if vendor then
    local key = tostring(vendor.guid)
    if vendor_target ~= key then
      vendor_target, vendor_target_since = key, now
    elseif now - vendor_target_since > VENDOR_TARGET_PATIENCE then
      vendor_skip[key] = now + VENDOR_RETRY_SECONDS
      wow.log(string.format("vendor: %s not reached in %.0fs — trying the next vendor",
        tostring(vendor.name), VENDOR_TARGET_PATIENCE))
      vendor_target = nil
      vendor_unreached = vendor_unreached + 1
      if vendor_unreached >= VENDOR_MAX_UNREACHED then
        vendor_unreached = 0
        vendor_seek_after = now + VENDOR_RETRY_SECONDS
        wow.log(string.format("vendor: %d vendors unreachable — next vendor walk in %.0fs",
          VENDOR_MAX_UNREACHED, VENDOR_RETRY_SECONDS))
        return nil
      end
      vendor, vendor_d = nearest_vendor(view)
    end
  end
  if not vendor and not vendor_seen then
    local hub, hub_d = vendor_hub(view)
    if not hub then return nil end
    if hub_d <= VENDOR_HUB_ARRIVE then
      vendor_seek_after = now + VENDOR_RETRY_SECONDS
      wow.log(string.format("vendor: no vendor in view at %s — next vendor walk in %.0fs",
        tostring(hub[5]), VENDOR_RETRY_SECONDS))
      return nil
    end
    return {
      kind = "navigate", x = hub[2], y = hub[3], z = hub[4],
      map_id = math.floor(hub[1]), stop_distance = VENDOR_HUB_ARRIVE - 5,
      route_profile = "prefer_ground", reason = "vendor_walk_hub",
    }
  end
  if not vendor then
    local here = view.location or {}
    if not vendor_seen or (here.map_id and vendor_seen.map_id and
        math.floor(here.map_id) ~= math.floor(vendor_seen.map_id)) then
      return nil
    end
    local me = view_point(view)
    if me and me.x and math.abs(me.x - vendor_seen.x) + math.abs(me.y - vendor_seen.y) < 10 then
      -- Standing where it was and it is not in view: it moved or died.
      vendor_seen = nil
      return nil
    end
    return {
      kind = "navigate",
      x = vendor_seen.x, y = vendor_seen.y, z = vendor_seen.z,
      map_id = vendor_seen.map_id and math.floor(vendor_seen.map_id),
      stop_distance = VENDOR_INTERACT_STOP,
      route_profile = "prefer_ground",
      reason = "vendor_walk_remembered",
    }
  end
  if (view.quest_frame or {}).open or view.gossip_open then
    if free > 0 then return nil end
    return { kind = "ui_press", control = "QuestFrameCancelButton",
      reason = "vendor_clear_dialog" }
  end
  -- Routed interact stalls at nav=planning on short chapel hops (Baran,
  -- Joshua at 7.6yd, zero displacement). Steer the last yards, then click.
  local pos = point(vendor)
  local d = tonumber(vendor_d) or tonumber(vendor.distance) or 1e9
  local nav = wow.nav_progress()
  local nav_state = nav and nav.state or ""
  -- Beyond the last few yards a planning stall gets the router, not a
  -- straight steer: steering from the wrong side of the chapel fence
  -- (Vulcan) only grinds into it.
  if pos and d > VENDOR_STEER_YARDS and
      (nav_state == "unavailable" or nav_state == "planning") then
    return {
      kind = "navigate",
      x = pos.x, y = pos.y, z = pos.z,
      map_id = vendor.location and math.floor(vendor.location.map_id or 0),
      stop_distance = VENDOR_INTERACT_STOP,
      route_profile = "prefer_ground",
      reason = "open_vendor_route",
    }
  end
  if pos and d > VENDOR_INTERACT_STOP and
      (nav_state == "unavailable" or nav_state == "planning") then
    return {
      kind = "navigate",
      x = pos.x, y = pos.y, z = pos.z,
      map_id = vendor.location and math.floor(vendor.location.map_id or 0),
      stop_distance = VENDOR_INTERACT_STOP,
      navigation_mode = "local_steer",
      allow_jump = true,
      reason = "open_vendor_walk",
    }
  end
  return {
    kind = "interact",
    guid = vendor.guid,
    stop_distance = VENDOR_INTERACT_STOP,
    route_profile = "prefer_ground",
    reason = "open_vendor",
  }
end

-- Quest materials at a merchant the seat already has open. An accepted
-- quest's incomplete item objective that the open merchant lists at a known
-- price buys the smallest legal bundle count once. The pilot answers on the
-- next tick: deferred queued nothing and may be asked again; refused queued
-- nothing; issued may have bought. An issued buy is proven only when the
-- carried count reaches the baseline plus the full delivered count. Anything
-- else (timeout, partial delivery, window closed or another merchant, no
-- readback) leaves that ITEM blocked, on any merchant, until the bags prove it
-- or the window lapses; the pilot keeps its own guard, which also survives a
-- Lua reload, so a lapsed window is answered with a refusal, never a second
-- purchase. There is no retry and no vendor search here.
-- One local: the main chunk sits at Lua's 200-local ceiling.
local mat = {
  lib = require("tools.quest_material"),
  SETTLE_SECONDS = 4.0, WINDOW = 600.0,
  pending = nil, -- the one buy awaiting its readback or its bag proof
  blocked = {}, -- item id -> { until_t, have_before?, items? }
  logged = {},
}

function mat.reset()
  mat.pending, mat.blocked, mat.logged = nil, {}, {}
end

function mat.log_once(key, msg)
  if mat.logged[key] then return end
  mat.logged[key] = true
  wow.log(msg)
end

-- An issued buy without its proof blocks the item with no deadline; only the
-- bags end it.
function mat.block(p, why)
  mat.blocked[p.item_id] = { have_before = p.have_before, items = p.items }
  wow.log(string.format("material: buy of item %d unconfirmed (%s); item blocked",
    p.item_id, why))
end

-- Bookkeeping for every tick the step is reached, before anything may yield:
-- late bag proof of a blocked buy, the pilot's answer to the last ask, and the
-- bag proof of an issued buy. A need for the item again soon after a proven
-- purchase means something took the bought items away; buying straight back
-- would loop, so a proven item waits out the window.
function mat.observe(view, now)
  for item_id, b in pairs(mat.blocked) do
    if b.items and mat.lib.carried(view, item_id) >= b.have_before + b.items then
      wow.log(string.format("material: late bag proof for item %d", item_id))
      mat.blocked[item_id] = { until_t = now + mat.WINDOW }
    elseif b.until_t and now >= b.until_t then
      mat.blocked[item_id] = nil
    end
  end
  local p = mat.pending
  if p and p.stage == "sent" then
    local nav = tostring((wow.nav_progress() or {}).state or "")
    if nav == "buy_verb_issued" then
      p.stage, p.issued_at = "issued", now
    elseif nav == "buy_verb_deferred" then
      mat.pending = nil
    elseif nav == "buy_verb_refused" then
      mat.blocked[p.item_id] = { until_t = now + mat.WINDOW }
      wow.log(string.format("material: buy of item %d refused by the pilot", p.item_id))
      mat.pending = nil
    else
      mat.block(p, "no buy readback: " .. nav)
      mat.pending = nil
    end
  end
  p = mat.pending
  if p and p.stage == "issued" then
    local have = mat.lib.carried(view, p.item_id)
    if have >= p.have_before + p.items then
      wow.log(string.format(
        "material: bought item %d for quest %d (carried %d->%d) copper %s->%s",
        p.item_id, p.quest_id, p.have_before, have, tostring(p.copper_before),
        tostring(view.copper_known and view.copper or "?")))
      mat.blocked[p.item_id] = { until_t = now + mat.WINDOW }
      mat.pending = nil
    elseif not view.merchant_open or tostring(view.merchant_guid) ~= p.merchant then
      mat.block(p, "merchant window closed or changed")
      mat.pending = nil
    elseif now - p.issued_at > mat.SETTLE_SECONDS then
      mat.block(p, string.format("carried %d, wanted %d", have,
        p.have_before + p.items))
      mat.pending = nil
    end
  end
end

-- Fights, death, a line being typed, an owner request other than questing,
-- and the escort's follow all outrank a purchase.
function mat.yields(view)
  if view.in_combat or life.fighting(view) or view.is_dead or view.is_ghost or
      chat_pending then
    return true
  end
  local job = rstate and rstate.active
  if job then return job.choice ~= "do_quests" end
  return party_member(view, MURIST) ~= nil
end

function mat.buy_step(view, now)
  mat.observe(view, now)
  if not view.merchant_open or not view.buy_supported or mat.yields(view) then
    return nil
  end
  if mat.pending then return { kind = "hold", reason = "material_buy_settle" } end
  local merchant = tostring(view.merchant_guid or "0")
  for _, need in ipairs(mat.lib.needs(view)) do
    if not mat.blocked[need.item_id] then
      local plan, why = mat.lib.plan(view, need)
      if plan then
        mat.pending = {
          stage = "sent", merchant = merchant, item_id = need.item_id,
          quest_id = need.quest_id, items = plan.items,
          have_before = mat.lib.carried(view, need.item_id),
          copper_before = tonumber(view.copper),
        }
        wow.log(string.format(
          "material: buying item %d x%d (%d bundles) for quest %d, need %d/%d, cost %dc",
          need.item_id, plan.items, plan.bundles, need.quest_id, need.have,
          need.required, plan.cost))
        return { kind = "buy_item", guid = view.merchant_guid,
          item_id = need.item_id, count = plan.bundles,
          expected_price = plan.price, reason = "quest_material_buy" }
      elseif why ~= "not_listed" then
        mat.log_once(merchant .. ":" .. need.item_id .. ":" .. why, string.format(
          "material: item %d listed here but not bought: %s", need.item_id, why))
      end
    end
  end
  return nil
end

local function role_for(view)
  if view.class_id == CLASS_WARRIOR then return "tank" end
  if view.class_id == CLASS_PRIEST then return "healer" end
  if view.class_id == CLASS_WARLOCK then return "dps" end
  return "dps"
end

local function status_for(view, mode, role, leader, target, recovery)
  return {
    mode = mode,
    role = role,
    party_leader = (view.party and view.party.leader_name) or "",
    murist_visible = leader ~= nil,
    target_guid = target and target.guid or 0,
    recovery = recovery or "",
    -- Surfaced so /status answers "why has Beru stopped casting" without a
    -- log dive: the seat is holding what is left of the bar for heals.
    conserving = (role == "healer" and mana_pct(view) < CONSERVE_MANA_PCT)
      or false,
    talent = talents.status(view, tstate),
    training = life.training_status(lstate),
    repair = life.repair_status(view, lstate),
  }
end

local function finish(intent, view, mode, role, leader, target, recovery)
  intent = intent or { kind = "hold", reason = "no_intent" }
  intent.status = status_for(view, mode, role, leader, target, recovery)
  return intent
end

local function cast(spell, reason, target_guid)
  if not spell then return nil end
  local result = { kind = "cast_spell", spell = spell.spell_id, reason = reason }
  if target_guid then result.target_guid = target_guid end
  return result
end

local function nearest_hostile(view)
  local best, best_distance = nil, nil
  for _, unit in ipairs(view.units or {}) do
    if hostile(unit) then
      local d = unit.combat_distance_known and unit.combat_distance or unit.distance or 1e9
      if not best_distance or d < best_distance then
        best, best_distance = unit, d
      end
    end
  end
  return best
end

local function current_hostile(view)
  local target = visible_unit(view, view.auto_attack_guid)
  if hostile(target) then return target end
  target = visible_unit(view, view.selected_target_guid)
  -- A stale far selection (leashed mob still targeted) keeps escorts fixated forever.
  if hostile(target) then
    local d = target.combat_distance_known and target.combat_distance or target.distance or 1e9
    if d <= 50.0 then return target end
  end
  if view.in_combat then return nearest_hostile(view) end
  return nil
end

-- Range to a ROSTER row, which is the same heightless-z trap the long rejoin
-- walks into: a row the projection has not vouched for carries z = 0.0 and
-- elevation_known = false, so a 3D distance from any hill is mostly our own
-- altitude. At z = 26 that quietly shrinks the 30yd heal range to 15yd of
-- ground, and above z = 30 the healer decides nobody is reachable while
-- standing on top of them. Flat range is the honest answer until the row
-- carries a real height.
local function member_range(view, row)
  local mine = view_point(view)
  local p = row and row.location
  if not mine or not p then return nil end
  if row.elevation_known ~= true then return distance2d(mine, p) end
  return distance(mine, { x = p.x, y = p.y, z = p.z })
end

local function beru_can_resurrect(view)
  local beru = party_member(view, "Beru")
  if not beru or not beru.level_known or (beru.level or 0) < 10 then return false end
  if not beru.death_state_known or beru.is_dead or beru.is_ghost then return false end
  if not beru.location_known or not view.location_known then return false end
  local d = member_range(view, beru)
  return d ~= nil and d <= HEAL_RANGE_YARDS
end

local function death_intent(view, now)
  if (view.resurrect_offer_guid or 0) ~= 0 then
    return { kind = "accept_rez", reason = "accept_resurrection" }, "accept_rez"
  end
  if view.is_dead and not view.is_ghost then
    if not dead_since then dead_since = now end
    if beru_can_resurrect(view) and now - dead_since < RES_WAIT_SECONDS then
      return { kind = "hold", reason = "wait_for_beru_resurrection" }, "waiting_for_beru"
    end
    -- A corpse keeps a short window for a resurrection offer, then releases
    -- like a player and walks back as a ghost.
    if now - dead_since < RES_WAIT_SECONDS then
      return { kind = "hold", reason = "wait_for_resurrection" }, "waiting_for_rez"
    end
    if release_sent_at and now - release_sent_at < RELEASE_RETRY_SECONDS then
      return { kind = "hold", reason = "release_pending" }, "releasing"
    end
    release_sent_at = now
    return { kind = "release", reason = "release_spirit" }, "releasing"
  end
  if view.is_ghost then
    if view.can_reclaim_corpse then
      return { kind = "reclaim", reason = "reclaim_corpse" }, "reclaiming"
    end
    if view.corpse_known and view.corpse_location and view.corpse_location.position then
      local corpse = view.corpse_location.position
      local intent = {
        kind = "navigate",
        x = corpse.x,
        y = corpse.y,
        z = corpse.z,
        map_id = view.corpse_location.map_id,
        stop_distance = 30.0,
        route_profile = "safe_ground",
        reason = "corpse_run",
      }
      -- A ghost run is the longest walk this brain ever does, and a crow line
      -- from the graveyard finds every cliff between here and the corpse.
      -- Same layering as the long rejoin: road waypoints past ROAD_MIN_YARDS,
      -- direct steering only when the router has no answer at all.
      local mine = view_point(view)
      local d = distance(mine, corpse)
      if mine and d and d > ROAD_MIN_YARDS and intent.map_id then
        local wp = road_waypoint(mine, corpse, math.floor(intent.map_id))
        if wp and closer_on_plane(mine, wp, corpse) then
          intent.x, intent.y, intent.z = wp.x, wp.y, wp.z
          intent.stop_distance = ROAD_WAYPOINT_STOP
          intent.reason = "corpse_run_road"
        end
      end
      if wow.nav_progress().state == "unavailable" then
        intent.route_profile = nil
        intent.navigation_mode = "local_steer"
      end
      return intent, "corpse_run"
    end
    return { kind = "hold", reason = "ghost_without_known_corpse" }, "corpse_unknown"
  end
  dead_since = nil
  release_sent_at = nil
  return nil, nil
end

local function heal_candidate(view)
  local best = nil
  local function consider(row, is_self)
    if row.death_state_known and (row.is_dead or row.is_ghost) then return end
    if row.health_known == false or (row.max_health or 0) <= 0 then return end
    if not is_self then
      if not row.location_known or not view.location_known then return end
      local d = member_range(view, row)
      if not d or d > HEAL_RANGE_YARDS or row.line_of_sight_blocked then return end
    end
    local hp = health_pct(row)
    if hp < 90 and (not best or hp < best.hp or
        (hp == best.hp and tostring(row.guid) < tostring(best.row.guid))) then
      best = { row = row, hp = hp, self_target = is_self }
    end
  end
  consider({
    guid = view.player_guid,
    health_known = view.health_known,
    health = view.health,
    max_health = view.max_health,
    active_auras_known = true,
    active_aura_spell_ids = view.active_aura_spell_ids or {},
  }, true)
  for _, member in ipairs((view.party and view.party.members) or {}) do
    if not guid_equal(member.guid, view.player_guid) then consider(member, false) end
  end
  return best
end

-- The roster row for the seat that is holding the mobs, if it is alive, in
-- range and reachable. Proactive upkeep goes here first: the tank is the only
-- member taking SCHEDULED damage, so a mitigation placed before the swing is
-- worth more than a heal chasing it afterwards.
local function tank_row(view)
  for _, member in ipairs((view.party and view.party.members) or {}) do
    if lower(member.name) == TANK_NAME and
        not guid_equal(member.guid, view.player_guid) and
        member.death_state_known and not member.is_dead and not member.is_ghost and
        member.location_known and view.location_known and
        not member.line_of_sight_blocked and
        member.active_auras_known ~= false then
      local d = member_range(view, member)
      if d and d <= HEAL_RANGE_YARDS then return member end
    end
  end
  return nil
end

local function tank_upkeep(view)
  if not view.in_combat then return nil end
  local row = tank_row(view)
  if not row then return nil end
  local auras = row.active_aura_spell_ids or {}
  local hp = health_pct(row)
  if hp < TANK_SHIELD_PCT and not aura_present(auras, "weakened soul") then
    local shield = pick_friendly_spell(view, { "Power Word: Shield" })
    if shield and not aura_present(auras, "power word shield", shield.spell_id) then
      return cast(shield, "shield_tank", row.guid)
    end
  end
  if hp < TANK_RENEW_PCT and mana_pct(view) >= CONSERVE_MANA_PCT then
    local renew = pick_friendly_spell(view, { "Renew" })
    if renew and not aura_present(auras, "renew", renew.spell_id) then
      return cast(renew, "renew_tank", row.guid)
    end
  end
  return nil
end

local function healer_action(view, emergency_only)
  local candidate = heal_candidate(view)
  if emergency_only and (not candidate or candidate.hp >= 50) then return nil end
  if not emergency_only and (not candidate or candidate.hp >= 30) then
    -- Nobody is falling, so spend the window on the tank instead of topping
    -- someone off: the shield and the renew are both already working by the
    -- time the next swing lands, and neither is a 1.5s cast he has to
    -- survive first.
    local upkeep = tank_upkeep(view)
    if upkeep then return upkeep end
  end
  if not candidate then return nil end
  local row, hp = candidate.row, candidate.hp
  -- Mana discipline. Under the conserve floor a scratch is not worth a cast.
  if mana_pct(view) < CONSERVE_MANA_PCT and hp >= CONSERVE_HEAL_PCT then
    return nil
  end
  local auras = row.active_aura_spell_ids or {}
  if hp < 50 and row.active_auras_known ~= false then
    local shield = pick_friendly_spell(view, { "Power Word: Shield" })
    if shield and not aura_present(auras, "power word shield", shield.spell_id) and
        not aura_present(auras, "weakened soul") then
      return cast(shield, "shield_low_party_member", row.guid)
    end
  end
  local heal = nil
  if hp < 20 then
    heal = pick_friendly_spell(view, { "Flash Heal", "Heal", "Lesser Heal" })
  elseif hp < 45 then
    heal = pick_friendly_spell(view, { "Heal", "Lesser Heal", "Flash Heal" })
  elseif hp < 70 then
    -- Shallow deficit: the cheapest rank that exists covers it, and a renew
    -- that is already ticking covers it for free.
    if row.active_auras_known ~= false then
      local renew = pick_friendly_spell(view, { "Renew" })
      if renew and not aura_present(auras, "renew", renew.spell_id) then
        return cast(renew, "renew_party_member", row.guid)
      end
    end
    heal = pick_friendly_spell(view, { "Heal", "Lesser Heal", "Flash Heal" }, true)
  elseif hp < 90 and row.active_auras_known ~= false then
    local renew = pick_friendly_spell(view, { "Renew" })
    if renew and not aura_present(auras, "renew", renew.spell_id) then
      return cast(renew, "renew_party_member", row.guid)
    end
  end
  return cast(heal, "heal_party_member", row.guid)
end

local function resurrection_action(view)
  if view.in_combat then return nil end
  local spell = pick_friendly_spell(view, { "Resurrection" })
  if not spell then return nil end
  local candidates = {}
  for _, member in ipairs((view.party and view.party.members) or {}) do
    if not guid_equal(member.guid, view.player_guid) and member.death_state_known and
        (member.is_dead or member.is_ghost) and member.location_known and
        view.location_known then
      local d = member_range(view, member)
      if d and d <= HEAL_RANGE_YARDS and not member.line_of_sight_blocked then
        candidates[#candidates + 1] = member
      end
    end
  end
  table.sort(candidates, function(a, b) return tostring(a.guid) < tostring(b.guid) end)
  if candidates[1] then
    return cast(spell, "resurrect_party_member", candidates[1].guid)
  end
  return nil
end

-- The wand: free damage, and the one button a healer must never press twice.
-- See WAND_REPRESS_SECONDS. Returns the "keep firing, touch nothing" intent
-- while the shot train is alive, and only asks for the button when the client
-- says the wand is idle AND we have not just pressed it ourselves.
-- Every class that shoots goes through here (`who` names the reason: the
-- healer's by default, "warlock"/"mage" for their fillers), so no rotation
-- presses Shoot a second time and toggles its own wand off.
-- "Running" is judged before readiness: while the shot train is alive the
-- button can read a cooldown or unusable for a frame, and that must not drop
-- the seat into a 4yd melee close that stops the wand. Running needs a Shoot
-- the host still offers (learned with an ordinary input, so bound) whose
-- equipped-item requirement is not known to be unmet; an unbound or
-- unequipped wand is never held. pick_spell gates only a NEW press.
local function wand_intent(view, target, who)
  who = who or "healer"
  local want = normalized("Shoot")
  local shoot = nil
  for _, spell in ipairs(spell_candidates(view)) do
    local name = normalized(spell.name)
    if spell.name_known ~= false and not spell.passive and not spell.from_item and
        (name == want or name:find(want, 1, true)) and
        not (spell.requires_equipped_item and spell.equipped_item_requirement_known and
          not spell.equipped_item_requirement_met) and
        (not shoot or spell.active == true) then
      shoot = spell
    end
  end
  if not shoot then return nil end
  local now = tonumber(view.simulation_time) or 0
  local just_pressed = tactic.wand_at ~= nil and
    guid_equal(tactic.wand_guid, target.guid) and
    (now - tactic.wand_at) < WAND_REPRESS_SECONDS
  if shoot.active == true or just_pressed then
    return { kind = "attack", guid = target.guid, stop_distance = 22.0,
      reason = who .. "_wanding" }
  end
  local wand = pick_spell(view, { "Shoot" })
  if not wand then return nil end
  tactic.wand_at, tactic.wand_guid = now, target.guid
  return { kind = "attack", guid = target.guid, spell = wand.spell_id,
    stop_distance = 22.0, reason = who .. "_wand" }
end

-- Target debuffs -- Rend, Sunder Armor, Demoralizing Shout, Shadow Word:
-- Pain, the warlock's curse and DoTs -- are requested per mob, never as a
-- blind refresh every global cooldown. A unit row carrying
-- `active_aura_spell_ids` (the fork's unit aura export; an empty list means
-- no aura is shown on the unit) that shows the debuff means it is up: never
-- refreshed. Otherwise the seat requests it: the request starts on the first
-- frame the pilot could press it -- the mob selected and engaged, the spell
-- not out of range, the seat at its stop distance -- stays due for 1.5s of
-- pilot presses (0.4s throttle, then the spell's own GCD), and is then not
-- due again until it is forgotten. A row that shows auras forgets it after
-- 10s: an immune or resisting mob costs one press window in ten seconds and
-- the rest of the rotation keeps its damage, while a dodged or fallen-off
-- debuff comes back. A row WITHOUT the field (a native view that does not
-- export unit auras) cannot show the debuff landing and forgets after 60s, so
-- a long fight or a respawn under the same guid gets one more. A request is
-- an attempt, not a landed aura. Stack counts are not in the Lua view either
-- way, so Sunder Armor is one application, not five.
local function debuff_due(view, target, spell, family, stop_distance)
  local ids = target.active_aura_spell_ids
  if ids ~= nil and aura_present(ids, family, spell.spell_id) then return false end
  local forget = ids ~= nil and 10.0 or 60.0
  local now = tonumber(view.simulation_time) or 0
  local key = tostring(target.guid) .. ":" .. family
  local asked = tactic.debuffs[key]
  if asked and now - asked >= forget then
    asked = nil
    tactic.debuffs[key] = nil
  end
  if asked then return now - asked < 1.5 end
  local d = target.combat_distance_known and target.combat_distance
    or target.distance
  if guid_equal(view.selected_target_guid, target.guid) and
      guid_equal(view.auto_attack_guid, target.guid) and
      not (spell.in_range_known and spell.in_range == false) and
      d and d <= stop_distance then
    -- One entry per mob and debuff; past the longest forget time an entry
    -- can no longer gate anything, so dead mobs do not accumulate.
    for k, at in pairs(tactic.debuffs) do
      if now - at >= 60.0 then tactic.debuffs[k] = nil end
    end
    tactic.debuffs[key] = now
  end
  return true
end

-- Life Tap spends health, so it needs health the client actually reports:
-- the projection sends health_known=false with zeroed health/max_health, and
-- the percent helpers read that as a full bar. An unknown bar never taps;
-- the rest of the rotation (DoTs, an affordable bolt, the wand, the stack's
-- melee) still answers.
local function warlock_action(view, target)
  if mana_pct(view) < 18 and view.health_known == true and
      self_health_pct(view) >= 40 then
    local tap = pick_spell(view, { "Life Tap" })
    if tap then return cast(tap, "life_tap") end
  end
  for _, name in ipairs({ "Curse of Agony", "Corruption", "Immolate" }) do
    local spell, family = pick_spell(view, { name })
    if spell and debuff_due(view, target, spell, family, 22.0) then
      return { kind = "attack", guid = target.guid, spell = spell.spell_id,
        stop_distance = 22.0, reason = "warlock_" .. family:gsub(" ", "_") }
    end
  end
  local bolt = pick_spell(view, { "Shadow Bolt" })
  if bolt then
    return { kind = "attack", guid = target.guid, spell = bolt.spell_id,
      stop_distance = 22.0, reason = "warlock_filler" }
  end
  local wand = wand_intent(view, target, "warlock")
  if wand then return wand end
  return { kind = "attack", guid = target.guid, stop_distance = 4.0,
    reason = "warlock_melee_fallback" }
end

-- How badly a mob needs peeling, low number first. A mob already on the tank
-- scores nothing: it is exactly where a tank wants it and needs no peel. Beru
-- outranks everyone -- a level 8 priest in cloth dies to two hits from
-- anything Murist is willing to pull, and the healer that dies ends the fight
-- for the whole party. Murist himself is last of the players because he is
-- the one member who chose to be hit.
local function peel_rank(view, unit)
  local guid = unit.target_guid
  if (guid or 0) == 0 or guid_equal(guid, view.player_guid) then return nil end
  local member = party_member_by_guid(view, guid)
  if member then
    if lower(member.name) == HEALER_NAME then return 1 end
    if lower(member.name) ~= MURIST then return 2 end
    return 3
  end
  if is_party_property(view, guid) then return 4 end
  return nil
end

local function tank_peel_target(view)
  local best, best_rank, best_d = nil, nil, nil
  for _, unit in ipairs(view.units or {}) do
    if hostile(unit) and unit.target_guid_known then
      local rank = peel_rank(view, unit)
      local d = unit.combat_distance_known and unit.combat_distance
        or unit.distance or 1e9
      if rank and d <= PEEL_RANGE_YARDS and
          (not best_rank or rank < best_rank or
            (rank == best_rank and d < best_d)) then
        best, best_rank, best_d = unit, rank, d
      end
    end
  end
  local current = visible_unit(view, view.auto_attack_guid)
  local engaged = hostile(current) and current.target_guid_known
  -- A mob that is already on US is a peel that WORKED. peel_rank deliberately
  -- scores it nil -- it needs no peel -- so without this the tank hands the
  -- mob it just pulled straight back to the party to go fetch the next one,
  -- and the one it dropped walks back to Beru. Only the healer is worth
  -- breaking off an established pull for.
  if engaged and guid_equal(current.target_guid, view.player_guid) then
    if not best or best_rank > 1 then return current end
    return best
  end
  if not best then return nil end
  -- Sticky between equals. Two adds on the healer trade places in the
  -- distance sort every tick, and a tank that re-selects on every tie walks
  -- between them without ever landing a swing.
  if engaged then
    local rank = peel_rank(view, current)
    if rank and rank <= best_rank then return current end
  end
  return best
end

local function warrior_action(view, target)
  -- Taunt is a 30s cooldown and one mob's worth of threat. Spend it only on a
  -- mob that is on somebody ELSE -- a mob already chewing on the tank is
  -- where it belongs, and taunting it buys nothing. Pets count: the escort's
  -- threat scan already treats them as the party's business.
  if target.target_guid_known and
      not guid_equal(target.target_guid, view.player_guid) and
      is_party_property(view, target.target_guid) then
    local taunt = pick_spell(view, { "Taunt" })
    if taunt then
      return { kind = "attack", guid = target.guid, spell = taunt.spell_id,
        stop_distance = 4.0, reason = "tank_taunt_party_attacker" }
    end
  end
  -- Hamstring is for the mob already in this fight that turns and runs:
  -- swung at, selected, and flagged fleeing (is_fleeing is true only when
  -- the unit flags are known, so plain movement never counts). A runner
  -- drags the fight into whatever it reaches. Requested once per mob
  -- (debuff_due). A queued Heroic Strike does not hold it back: Hamstring
  -- is a separate instant and leaves the next-swing queue alone. Stance,
  -- rage and cooldown arrive in the fact's own usability, which pick_spell
  -- already requires.
  if view.in_combat and target.is_fleeing == true and
      guid_equal(view.auto_attack_guid, target.guid) and
      guid_equal(view.selected_target_guid, target.guid) then
    local hamstring, family = pick_spell(view, { "Hamstring" })
    if hamstring and debuff_due(view, target, hamstring, family, 4.0) then
      return { kind = "attack", guid = target.guid, spell = hamstring.spell_id,
        stop_distance = 4.0, reason = "warrior_hamstring_fleeing" }
    end
  end
  if not view.in_combat then
    local d = target.combat_distance_known and target.combat_distance
      or target.distance
    local charge = pick_spell(view, { "Charge" })
    if charge and d and d >= 8.0 and d <= 25.0 then
      return { kind = "attack", guid = target.guid, spell = charge.spell_id,
        stop_distance = 25.0, reason = "warrior_charge" }
    end
  end
  -- Battle Shout is party-wide attack power for 10 rage and it falls off in
  -- the middle of a pull, so it is upkeep IN combat and not just an idle
  -- buff. Aura-gated AND floored, because it used to sit at the bottom of the
  -- blind filler list -- which is exactly where a tank whose rage cannot pay
  -- for anything else lands, so it became the rage sink.
  local now = tonumber(view.simulation_time) or 0
  local shout, shout_family = pick_spell(view, { "Battle Shout" })
  if shout and
      not aura_present(view.active_aura_spell_ids, shout_family, shout.spell_id) and
      (not tactic.shout_at or now - tactic.shout_at >= SHOUT_RETRY_SECONDS) then
    tactic.shout_at = now
    return cast(shout, "tank_battle_shout")
  end
  -- Debuffs before the dump, once per mob (debuff_due): Sunder Armor is a
  -- debuff ON the mob, so it belongs here and not in the filler, where a
  -- warrior with 15 rage pressed it every global cooldown and never reached
  -- Heroic Strike again. One application per mob is the bounded rule; the
  -- view carries no stack count, so stacking Sunder to five is not done.
  for _, name in ipairs({ "Rend", "Sunder Armor", "Demoralizing Shout" }) do
    local spell, family = pick_spell(view, { name })
    if spell and debuff_due(view, target, spell, family, 4.0) then
      return { kind = "attack", guid = target.guid, spell = spell.spell_id,
        stop_distance = 4.0, reason = "tank_" .. family:gsub(" ", "_") }
    end
  end
  -- Threat filler in rage-cost order, not damage order: Revenge is nearly
  -- free off a block, and Heroic Strike is the DUMP -- last, because it is
  -- what a tank presses with rage left over, not what he opens with.
  local threat = pick_spell(view, {
    "Revenge", "Thunder Clap", "Heroic Strike",
  })
  -- Heroic Strike is queued on the NEXT swing, and the client reports the
  -- queue as the button being active. Pressing it again cancels the queue,
  -- so a tank whose only ability is Heroic Strike (Tusk, level 8) spends the
  -- whole fight strobing it and landing nothing. Hold and let the swing land.
  if threat and threat.active == true then
    return { kind = "attack", guid = target.guid, stop_distance = 4.0,
      reason = "tank_swing_queued" }
  end
  return { kind = "attack", guid = target.guid,
    spell = threat and threat.spell_id or nil,
    stop_distance = 4.0,
    reason = threat and "tank_threat" or "tank_melee" }
end

local function priest_damage(view, target)
  local mana = mana_pct(view)
  -- Conserve floor: what is left belongs to the next heal. The seat stops
  -- PRESSING rather than switching to something cheaper, because a press is
  -- the one thing that can toggle a running wand back off -- and a wand that
  -- keeps firing for free is the entire point of conserving.
  if mana < CONSERVE_MANA_PCT then
    return { kind = "attack", guid = target.guid, stop_distance = 22.0,
      reason = "healer_conserve_mana" }
  end
  local pain, family = pick_spell(view, { "Shadow Word: Pain" })
  if pain and mana >= DOT_MANA_PCT and
      debuff_due(view, target, pain, family, 22.0) then
    return { kind = "attack", guid = target.guid, spell = pain.spell_id,
      stop_distance = 22.0, reason = "priest_shadow_word_pain" }
  end
  if mana < WAND_MANA_PCT then
    local wand = wand_intent(view, target)
    if wand then return wand end
  end
  local spell = pick_spell(view, { "Mind Blast", "Smite" })
  if spell then
    return { kind = "attack", guid = target.guid, spell = spell.spell_id,
      stop_distance = 22.0, reason = "priest_damage" }
  end
  local wand = wand_intent(view, target)
  if wand then return wand end
  return { kind = "attack", guid = target.guid, stop_distance = 4.0,
    reason = "priest_melee" }
end

local function mage_action(view, target)
  local blast = pick_spell(view, { "Fire Blast" })
  if blast then
    return { kind = "attack", guid = target.guid, spell = blast.spell_id,
      stop_distance = 22.0, reason = "mage_fire_blast" }
  end
  local filler = pick_spell(view, { "Fireball", "Frostbolt" })
  if filler then
    return { kind = "attack", guid = target.guid, spell = filler.spell_id,
      stop_distance = 22.0, reason = "mage_nuke" }
  end
  local wand = wand_intent(view, target, "mage")
  if wand then return wand end
  return { kind = "attack", guid = target.guid, stop_distance = 4.0,
    reason = "mage_melee_fallback" }
end

local function rogue_action(view, target)
  local strike = pick_spell(view, { "Sinister Strike" })
  if strike then
    return { kind = "attack", guid = target.guid, spell = strike.spell_id,
      stop_distance = 4.0, reason = "rogue_sinister_strike" }
  end
  return { kind = "attack", guid = target.guid, stop_distance = 4.0,
    reason = "rogue_melee" }
end

local function self_buff(view, role)
  local priorities = role == "tank" and { "Battle Shout" }
    or role == "healer" and { "Inner Fire" }
    or view.class_id == CLASS_MAGE and { "Ice Armor", "Frost Armor", "Mage Armor" }
    or { "Demon Armor", "Demon Skin" }
  for _, name in ipairs(priorities) do
    local spell, family = pick_spell(view, { name })
    if spell and not aura_present(view.active_aura_spell_ids, family, spell.spell_id) then
      return cast(spell, "self_buff")
    end
  end
  return nil
end

-- A petless warlock is half a warlock. Own pet state comes off our own
-- roster row (pet_guid 0 = nothing summoned); the 10s cast is protected by
-- the finish_active_cast hold like any other cast.
local function summon_demon(view, role)
  if role ~= "dps" or view.class_id ~= CLASS_WARLOCK then return nil end
  -- The view has no first-person pet field and SMSG_GROUP_LIST rosters only
  -- the OTHER members, so our own demon is found the way anyone finds it: a
  -- living unit we are the summoner of. Imps heel, so "not in units" is
  -- "not summoned" in practice.
  for _, unit in ipairs(view.units or {}) do
    if guid_equal(unit.summoner_guid, view.player_guid) and
        not (unit.death_known and unit.is_dead) then
      return nil
    end
  end
  local spell = pick_spell(view, { "Summon Imp" })
  if not spell then
    -- Measured live on Igris (2026-08-16):
    --   candidate: "Summon Imp" id=688 ready=false known=true usable=true/false
    --              mana_short=true cd=0 reagents=true
    -- The bar name and the cooldown were fine the whole time; the seat simply
    -- never had the mana. Escort mode chain-pulls behind Murist and has no
    -- rest step, so passive regen never reaches the summon's cost. Life Tap
    -- is the warlock's own funding mechanism -- out of combat the health is
    -- idle capital, so trade it for the imp instead of standing there broke.
    if not view.in_combat and mana_blocked_spell(view, "Summon Imp") and
        view.health_known == true and
        self_health_pct(view) >= SUMMON_LIFE_TAP_MIN_HEALTH_PCT then
      local tap = pick_spell(view, { "Life Tap" })
      if tap then return cast(tap, "life_tap_for_summon") end
    end
    return nil
  end
  return cast(spell, "summon_imp")
end

local function fortitude_action(view)
  local spell = pick_friendly_spell(view, { "Power Word: Fortitude" })
  if not spell then return nil end
  for _, member in ipairs((view.party and view.party.members) or {}) do
    -- SMSG_GROUP_LIST rosters players only, so pets never reach this loop and
    -- need no skip of their own. The RANGE is what was missing: an unbuffed
    -- member across the zone made the healer cast into nothing every idle
    -- tick instead of buffing the four people standing next to it.
    if member.death_state_known and not member.is_dead and not member.is_ghost and
        member.active_auras_known and
        not aura_present(member.active_aura_spell_ids, "power word fortitude", spell.spell_id) and
        (guid_equal(member.guid, view.player_guid) or
          (member.location_known and view.location_known and
            not member.line_of_sight_blocked and
            (member_range(view, member) or 1e9) <= HEAL_RANGE_YARDS)) then
      return cast(spell, "fortitude_party_member", member.guid)
    end
  end
  return nil
end

local function log_gear(outcome)
  if outcome and outcome.equipped then
    local e = outcome.equipped
    wow.log(string.format("home: equipped %s (%s, score %s) into slot %d replacing item %s",
      tostring(e.name), tostring(e.item_id), tostring(e.score), e.slot,
      tostring(e.replaced)))
  elseif outcome and outcome.refused then
    wow.log(string.format("home: equip of %s (%s) never reached slot %d; set aside",
      tostring(outcome.refused.name), tostring(outcome.refused.item_id),
      outcome.refused.slot))
  end
end

-- An open dialog belongs to the class quest only when it is Venya's or
-- already shows quest 1470; every other dialog stays with the quest stack.
local function class_quest_dialog_open(view)
  local frame = view.quest_frame or {}
  if frame.open and frame.quest_id == life.QUEST_PIERCING_THE_VEIL then return true end
  local npc = (frame.open and frame.npc_guid) or
    (view.gossip_open and view.gossip_guid) or 0
  if npc == 0 then return false end
  local unit = visible_unit(view, npc)
  return unit ~= nil and unit.entry == life.CREATURE_VENYA_MARTHAND
end

-- What a character that lives for days does between fights, ahead of the
-- quest/grind brain: train a rank it leveled into, answer its class quest,
-- bind newly learned spells, keep its imp out, loot its own corpses, wear
-- legal upgrades and walk its class quest. Every outcome is judged by the
-- world (lua/tools/lifecycle.lua).
local function progression_step(view, now, policy)
  life.note_class_quest(view, lstate)
  if lstate.train_since and (view.trainer_open or view.gossip_open) then
    local train = life.train_step(view, lstate, now, false)
    if train then return train end
  end
  if life.class_quest_phase(view) and class_quest_dialog_open(view) then
    local answer = life.class_quest_dialog(view)
    if answer then return answer end
  end
  local busy = life.fighting(view)
  local bind = life.bind_step(view, lstate, now, busy)
  if bind then return bind end
  local pet = life.pet_step(view, lstate, now, busy)
  if pet then return pet end
  if busy then return nil end
  -- Kill events are not on every route; the corpse's own lootable flag arms
  -- the shared loot taker instead.
  local corpse = life.loot_corpse(view, lstate)
  if corpse then
    lstate.loot_tried[corpse.guid] = true
    lstate.loot_armed = (lstate.loot_armed or 0) + 1
    solo.note_kills({ player_guid = view.player_guid,
      combat_kill_events = { { target_guid = corpse.guid,
        source_guid = view.player_guid } } })
  end
  local loot = solo.loot_step(view)
  if loot then return loot end
  local gear, outcome = life.gear_step(view, lstate, now, busy)
  log_gear(outcome)
  if gear then return gear end
  -- Known broken worn gear is repaired before the next trainer, quest or
  -- grinding leg. Only this solo pipeline reaches here, never a follow in
  -- Murist's party; a blocked attempt keeps its obstacle and retry time.
  if life.repair_needed(view, true) then
    local repair, fixed = life.repair_step(view, lstate, now, busy)
    if fixed and fixed.why ~= lstate.repair_logged then
      lstate.repair_logged = fixed.why
      wow.log(string.format("home: broken gear repair %s (%s)",
        tostring(fixed.result), tostring(fixed.why)))
    end
    if repair then return repair end
  end
  local train = life.train_step(view, lstate, now, busy,
    policy ~= nil and policy.objective_first == true)
  if train then return train end
  local quest = life.class_quest_step(view, lstate)
  if quest then return life.with_pet(view, lstate, quest) end
  return nil
end

local function chat_outbox_path()
  if chat_outbox ~= nil then
    if chat_outbox == false then return nil end
    return chat_outbox
  end
  -- The launcher hands every seat its own control directory; the sibling
  -- chat directory is this seat's private mailbox from the host.
  local dir = os.getenv("VANILLA_WOW_LUA_DEBUG_DIR")
  if not dir or dir == "" then
    chat_outbox = false
    return nil
  end
  chat_outbox = dir:gsub("[/\\]*$", ""):gsub("[/\\]control$", "") ..
    "/chat/outbox.json"
  return chat_outbox
end

local function chat_silenced()
  local off = os.getenv("SHADOW_CHAT_QWEN_OFF")
  return off ~= nil and off ~= "" and off ~= "0"
end

local function chat_take_line()
  local path = chat_outbox_path()
  if not path then return nil end
  local handle = io.open(path, "r")
  if not handle then return nil end
  local body = handle:read("*a") or ""
  handle:close()
  -- Consume unconditionally: a line we cannot read is a line we must not
  -- retry, and the host only refills an empty mailbox.
  os.remove(path)
  local written = tonumber(body:match('"created_at_unix_seconds"%s*:%s*([%d%.]+)'))
  if written and os.time() - written > CHAT_STALE_SECONDS then return nil end
  local text = body:match('"text"%s*:%s*"([^"]*)"')
  if not text or text == "" then return nil end
  if #text > CHAT_MAX_TEXT then return nil end
  if text:find("[^\32-\126]") then return nil end
  if text:sub(1, 1) == "/" then return nil end
  return text
end

local function chat_poll(view, now)
  if chat_pending or chat_silenced() then return end
  if chat_last_sent_at and now - chat_last_sent_at < CHAT_MIN_GAP_SECONDS then
    return
  end
  if chat_last_poll_at and now - chat_last_poll_at < CHAT_POLL_SECONDS then
    return
  end
  chat_last_poll_at = now
  local text = chat_take_line()
  if not text then return end
  chat_pending = { text = text, started_at = now, saw_box = false }
  wow.log("chat: queued " .. text)
end

local function chat_step(view, now)
  -- One in-flight line owns the edit box until the client closes it. Giving
  -- up mid-sequence is what strands the box for every later verb, so the
  -- only exits are "the box closed" and "we waited too long".
  if not chat_pending then return nil end
  if view.in_combat or view.is_dead or view.is_ghost then
    -- Banter loses to every emergency. The box, if it is open, belongs to
    -- the stranded-box flush now.
    wow.log("chat: dropped " .. chat_pending.text)
    chat_pending = nil
    chat_last_sent_at = now
    return nil
  end
  -- 0066 transport: the chat intent goes straight to the command queue and
  -- the edit box NEVER opens, so "saw the box close" can't complete a send —
  -- waiting for it re-queued every line until the timeout, ~2 sends per
  -- banter (rollout executor's finding). One emission IS the send now: the
  -- pilot's queue + 0.6s floor own delivery. The box-watch path stays only
  -- for a pre-0066 host, where the box still appears.
  if view.chat_input_visible then chat_pending.saw_box = true end
  if not chat_pending.emitted then
    chat_pending.emitted = true
    return { kind = "chat", channel = "party", text = chat_pending.text,
      reason = "party_banter" }
  end
  local finished = (chat_pending.saw_box and not view.chat_input_visible)
    or not view.chat_input_visible
  local expired = now - chat_pending.started_at > CHAT_SEND_TIMEOUT
  if finished or expired then
    wow.log("chat: " .. (finished and "sent " or "gave up on ") ..
      chat_pending.text)
    chat_pending = nil
    chat_last_sent_at = now
    return nil
  end
  return { kind = "chat", channel = "party", text = chat_pending.text,
    reason = "party_banter" }
end

local function leader_moving(p, now)
  if not p then
    last_lead = nil
    return false
  end
  if not last_lead then
    last_lead = { x = p.x, y = p.y, t = now, moving = false, still_at = now }
    return false
  end
  local dt = now - last_lead.t
  if dt > 0 then
    local dx = (p.x or 0) - last_lead.x
    local dy = (p.y or 0) - last_lead.y
    local speed = math.sqrt(dx * dx + dy * dy) / dt
    if speed >= LEAD_RUN_YDS then
      last_lead.moving = true
      last_lead.still_at = nil
    elseif speed < LEAD_STILL_YDS then
      if not last_lead.still_at then last_lead.still_at = now end
      if now - last_lead.still_at >= LEAD_STILL_SECONDS then
        last_lead.moving = false
      end
    else
      last_lead.still_at = nil
    end
    last_lead.x, last_lead.y, last_lead.t = p.x, p.y, now
  end
  return last_lead.moving
end

local function fight_on(view, leader)
  if view.in_combat then return true end
  if leader and leader.is_in_combat then return true end
  for _, unit in ipairs(view.units or {}) do
    if hostile(unit) and is_party_property(view, unit.target_guid) then
      local d = unit.combat_distance_known and unit.combat_distance
        or unit.distance or 1e9
      if d <= PEEL_RANGE_YARDS then return true end
    end
  end
  return false
end

-- Whether the party is already fighting this hostile, so the imp may join.
-- A hostile that is merely selected must never be pet-pulled. Engaged means
-- its target is the party's (combat flags on other units latch lazily, so
-- this needs none), or it is in combat and is Murist's target, from either
-- his visible unit row or his roster row.
local function party_engaged(view, leader, target)
  if not target then return false end
  if (target.target_guid or 0) ~= 0 and
      is_party_property(view, target.target_guid) then
    return true
  end
  if not (target.combat_known and target.is_in_combat) then return false end
  if leader and guid_equal(leader.target_guid, target.guid) then return true end
  local row = party_member(view, MURIST)
  return row ~= nil and row.target_guid_known == true and
    guid_equal(row.target_guid, target.guid)
end

-- The nearest hostile whose current target is authoritatively one of the
-- party's (self, a member, or a party pet), within peel range. A mob that is
-- merely selected, or whose target field is unknown or stale, is not a fight
-- the party is in.
local function engaged_threat(view)
  local best, best_d = nil, nil
  for _, unit in ipairs(view.units or {}) do
    if hostile(unit) and unit.target_guid_known == true and
        (unit.target_guid or 0) ~= 0 and
        is_party_property(view, unit.target_guid) then
      local d = unit.combat_distance_known and unit.combat_distance
        or unit.distance or 1e9
      if d <= PEEL_RANGE_YARDS and (not best_d or d < best_d) then
        best, best_d = unit, d
      end
    end
  end
  return best
end

-- The role's answer to one hostile: tank threat, healer damage, or the
-- class's own nuke/melee line.
local function role_action(view, role, target)
  return role == "tank" and warrior_action(view, target)
    or role == "healer" and priest_damage(view, target)
    or view.class_id == CLASS_MAGE and mage_action(view, target)
    or view.class_id == CLASS_ROGUE and rogue_action(view, target)
    or warlock_action(view, target)
end

-- Step off the mob that is about to finish us. A hold at 20% is a corpse.
local function survive_step(view)
  if view.is_dead or view.is_ghost then return nil end
  if self_health_pct(view) >= FLEE_HP_PCT then return nil end
  local mine = view_point(view)
  if not mine then return nil end
  local nearest, nd = nil, nil
  for _, unit in ipairs(view.units or {}) do
    if hostile(unit) then
      local d = unit.combat_distance_known and unit.combat_distance
        or unit.distance or 1e9
      if not nd or d < nd then nearest, nd = unit, d end
    end
  end
  if not nearest or not nd or nd > 12 then return nil end
  local p = point(nearest)
  if not p then return nil end
  local dx, dy = mine.x - p.x, mine.y - p.y
  local mag = math.sqrt(dx * dx + dy * dy)
  if mag < 0.5 then dx, dy, mag = 1, 0, 1 end
  return {
    kind = "navigate",
    x = mine.x + dx / mag * FLEE_YARDS,
    y = mine.y + dy / mag * FLEE_YARDS,
    z = mine.z,
    map_id = math.floor((view.location and view.location.map_id) or 0),
    stop_distance = 2.0,
    navigation_mode = "local_steer",
    allow_jump = true,
    reason = "survive_flee",
  }
end

local function formation_fidget(view, now)
  local pos = view_point(view)
  if not pos or not view.location then return nil end
  if fidget_at and now - fidget_at < FIDGET_SECONDS then return nil end
  fidget_at = now
  return {
    kind = "navigate",
    x = pos.x + 1.5,
    y = pos.y,
    z = pos.z,
    map_id = math.floor(view.location.map_id or 0),
    stop_distance = 0.5,
    navigation_mode = "local_steer",
    allow_jump = true,
    reason = "formation_fidget",
  }
end

function M.reset()
  lstate = life.new_state()
  tstate = talents.new_state()
  dead_since = nil
  release_sent_at = nil
  last_promote_at = nil
  forget_stuck()
  stuckSeenAt = nil
  stuckBearing = 0
  chatOpenSince = nil
  chat_last_poll_at = nil
  chat_last_sent_at = nil
  chat_pending = nil
  vendor_forget()
  vendor_seek_after = nil
  vendor_seen = nil
  vendor_hubs_loaded = false
  vendor_skip = {}
  vendor_target, vendor_target_since = nil, nil
  vendor_unreached = 0
  equip_last_at = nil
  equip_tried = {}
  equip_attempts = 0
  equip_gave_up = false
  tactic.wand_at, tactic.wand_guid, tactic.shout_at = nil, nil, nil
  tactic.debuffs = {}
  tactic.fear, tactic.fear_tries, tactic.escape = nil, {}, nil
  fidget_at = nil
  last_lead = nil
  mat.reset()
end

function M.decide(view)
  view = view or {}
  local now = tonumber(view.simulation_time) or 0
  local role = role_for(view)
  -- Ahead of everything, including recovery and the solo fallback: the prompt
  -- shows up on bot-only groups too, one press costs a single frame, and a
  -- corpse run or a follow leg loses nothing by resuming next tick.
  local roll = loot_roll_step(view)
  if roll then return finish(roll, view, "loot_roll", role) end

  -- Standing at an open merchant is the only moment a sale is possible, and
  -- it ends the instant anything else moves the seat — so it runs before the
  -- escort, the same way the loot roll does. Inert until the fork projects
  -- bags into the view (tickets/open/0073).
  local sale = vendor_sell_step(view, now)
  if sale then return finish(sale, view, "vendor", role) end

  -- The same open window, after the sale: selling first frees bags and copper.
  local buy = mat.buy_step(view, now)
  if buy then return finish(buy, view, "vendor", role) end

  -- Wearing a carried bag costs one tick and needs no vendor, so it runs
  -- right behind the sale and ahead of the escort: a seat with zero free
  -- slots cannot accept a quest reward, and every bag it is carrying instead
  -- of wearing is six slots it already owns. Self-limiting — at most four
  -- bags exist to equip, and the step goes quiet once the slots are full.
  -- Never equip while Murist is in the party. The host accepts equip_item
  -- then freezes decide (0074) — Igris/Shadowfel read as offline after
  -- "bags: equipping". Solo seats still try. Ticket 0082 buys; 0074 must
  -- land before escort equips again.
  if not party_member(view, MURIST) then
    local wear = equip_bags_step(view, now)
    if wear then return finish(wear, view, "vendor", role) end
  end

  local seek = vendor_seek_step(view, now)
  if seek then
    -- interact has no navigation_mode, so a 90yd chapel walk that wedges
    -- at planning (Vulcan, 2026-08-16) never reaches stuck_step otherwise.
    if seek.kind == "navigate" or seek.kind == "interact" then
      local escape = stuck_step(view, now, false, "vendor_unstick")
      if escape then
        return finish(escape, view, "vendor", role)
      end
    else
      forget_stuck()
    end
    return finish(seek, view, "vendor", role)
  end

  -- Flush a STRANDED chat box before any state machine runs — recovery
  -- included, since /reclaim is itself chat-driven and types into the same
  -- fouled box. Time-gated exactly like the solo flush so an in-flight
  -- sequence (2-3 frames) is never cancelled; only when no dialog owns input.
  if view.chat_input_visible then
    if not chatOpenSince then chatOpenSince = now end
    if now - chatOpenSince > CHAT_STUCK_SECONDS and
        not (view.quest_frame or {}).open and not view.gossip_open then
      chatOpenSince = now
      return finish({ kind = "quest_cmd", command = "/gossip",
        reason = "close_chat_box" }, view, "chat_flush", role)
    end
  else
    chatOpenSince = nil
  end

  -- A line already being typed finishes before anything else looks at the
  -- world: the half-typed box is the one state no other verb can survive.
  if chat_pending then
    local speak = chat_step(view, now)
    if speak then return finish(speak, view, "escort", role) end
  end

  local death, recovery = death_intent(view, now)
  if death then
    -- The owner's request keeps its identity and bounds through death; the
    -- request runner returns no intent for a dead or ghost seat, so the
    -- physical recovery below still owns every frame.
    if view.is_dead or view.is_ghost then
      requests.step(view, rstate, now, { life = life, lstate = lstate, fighting = false })
    end
    -- Only the walking legs of recovery can wedge; a hold or a /reclaim is
    -- standing still because it was told to.
    if death.kind == "navigate" then
      local escape = stuck_step(view, now, false, "corpse_run_unstick")
      if escape then
        return finish(escape, view, "recovery", role, nil, nil, recovery)
      end
    else
      forget_stuck()
    end
    return finish(death, view, "recovery", role, nil, nil, recovery)
  end

  -- The solo leveling pipeline: survival, the active cast, banked talents,
  -- progression legs, then the accelerated quest stack with its road, pet
  -- and attack wrappers. The owner's do_quests request runs exactly this
  -- pipeline with an objective-first policy; a local of decide because the
  -- chunk is at Lua's local limit.
  --
  -- The class tactics the escort fights with, on the very hostile the solo
  -- stack chose: the warrior's, priest's and warlock's own rotations, target
  -- debuffs once per mob (debuff_due). Other classes keep the stack's attack
  -- (role_action's warlock fallback is not their rotation). A spell-less
  -- answer is adopted only when it protects a queued swing or a running
  -- wand; plain melee leaves the stack's intent as it was.
  local function class_tactic(intent)
    if intent.kind ~= "attack" or not (view.class_id == CLASS_WARRIOR or
        view.class_id == CLASS_PRIEST or view.class_id == CLASS_WARLOCK) then
      return nil
    end
    local target = visible_unit(view, intent.guid)
    if not hostile(target) then return nil end
    local action = role_action(view, role, target)
    if type(action) ~= "table" then return nil end
    -- Under the conserve floor the escort healer stands at 22 yards pressing
    -- nothing. Solo, that stand only makes sense while a wand fires: keep a
    -- running wand (or start an equipped, idle one) through wand_intent's
    -- no-repress guard; with no ready wand the stack's melee stays.
    if action.reason == "healer_conserve_mana" then
      action = wand_intent(view, target)
      if not action then return nil end
    end
    if action.kind == "attack" then
      if not guid_equal(action.guid, target.guid) then return nil end
      if not action.spell and action.reason ~= "tank_swing_queued" and
          not tostring(action.reason):find("_wanding$") then
        return nil
      end
      action.route_profile = intent.route_profile
      return action
    end
    if action.kind == "cast_spell" and action.target_guid == nil then return action end
    return nil
  end

  -- A long catalogued repair walk rides the roads like an objective walk,
  -- but decides road or crow line ONCE per anchor and owning job, and keeps
  -- that journey on the lifecycle's walk record. The record lasts through
  -- fights and position gaps and is gone at arrival, failure, a visible
  -- provider or a new repair request; a different owning job (or none) on
  -- the same record replans from where the seat stands. Re-deciding from
  -- every pose can alternate the goal between a road waypoint and the anchor
  -- while the seat makes no useful progress; one decision per journey
  -- removes that per-frame choice. A tank with a known broken weapon
  -- fights poorly, so its plan weighs off-road yards double and accepts a
  -- longer known road.
  local function repair_road(intent)
    if not intent or intent.kind ~= "navigate" or intent.reason ~= "repair_destination" then
      return intent
    end
    local travel, mine = lstate.repair_travel, view_point(view)
    if not travel then return intent end
    local owner = rstate and rstate.active and rstate.active.key or false
    local trip = travel.road
    if not trip or trip.owner ~= owner or trip.hub_id ~= travel.hub_id or
        trip.map_id ~= intent.map_id or trip.x ~= intent.x or trip.y ~= intent.y then
      if not mine then return intent end
      trip = { owner = owner, hub_id = travel.hub_id, map_id = intent.map_id,
        x = intent.x, y = intent.y }
      travel.road = trip
      if distance2d(mine, trip) > ROAD_MIN_YARDS then
        local _
        _, trip.pts, trip.i = road_waypoint(mine, trip, intent.map_id,
          role == "tank" and life.broken_main_hand(view) and
          { penalty = 2 * road_route.offRoadPenalty } or nil)
      end
    end
    local pts = trip.pts
    if pts and mine then
      -- Forward only: the farthest unfinished route point the seat is
      -- standing at is reached, and the next handhold is a lookahead past it.
      -- An unreached point stays the target however the pose wanders.
      local reached = nil
      for j = trip.i, #pts - 1 do
        if distance2d(mine, pts[j]) <= ROAD_WAYPOINT_STOP then reached = j end
      end
      if reached then
        local i, run = reached + 1, 0
        while i < #pts do
          run = run + distance2d(pts[i - 1], pts[i])
          if run > ROAD_LOOKAHEAD_YARDS then break end
          i = i + 1
        end
        trip.i = i
      end
      -- The last leg, or inside one road step of the anchor: the plain walk
      -- at the anchor finishes the journey and the road is not resumed.
      if trip.i >= #pts or distance2d(mine, trip) <= ROAD_MIN_YARDS then
        trip.pts, pts = nil, nil
      end
    end
    if pts then
      local wp = pts[trip.i]
      intent.x, intent.y, intent.z = wp.x, wp.y, wp.z
      intent.stop_distance = ROAD_WAYPOINT_STOP
      intent.reason = "repair_destination_road"
    end
    return intent
  end

  -- A mob under Fear: the aura is the only lasting truth. A mob fleeing at
  -- low health on its own has no aura and is still worth killing.
  local function feared(unit)
    return unit ~= nil and aura_present(unit.active_aura_spell_ids, "fear")
  end

  -- A live hostile that is not known to be on this seat, a party member or
  -- their pets, within pack_yards of the seat or of the mob to be feared. A
  -- mob whose target or position is unknown counts. Critters do not.
  local function unengaged_near(target, pack_yards)
    local there = point(target)
    for _, unit in ipairs(view.units or {}) do
      if hostile(unit) and not guid_equal(unit.guid, target.guid) and
          not (unit.creature_type_known and unit.creature_type == 8) and
          not (unit.target_guid_known == true and
            is_party_property(view, unit.target_guid)) then
        local here = point(unit)
        local apart = here and there and distance(here, there)
        if not here or not there or (unit.distance or 0) <= pack_yards or
            apart <= pack_yards then
          return true
        end
      end
    end
    return false
  end

  -- Grouped, a seat can still be questing by itself. It is on its own only
  -- when every other roster row is a member the roster reports offline
  -- with no known position, or one placed somewhere known and far: on
  -- another map, or more than alone_yards away on this one. A known
  -- position outranks the offline bit, so an offline row placed near still
  -- blocks. No party player or party pet may be visible nearer either way.
  -- A row whose online bit is unknown is not offline, so it needs a far
  -- position like an online one. A roster row without a position, a seat
  -- without one, or a roster with no other row is not alone. Remote rows
  -- are the server's party-stats position.
  local function alone(alone_yards)
    local party = view.party
    if not party or party.in_group ~= true then return true end
    local mine, map = view_point(view), view.location and view.location.map_id
    if not mine or not map then return false end
    local others = 0
    for _, member in ipairs(party.members or {}) do
      if not guid_equal(member.guid, view.player_guid) then
        others = others + 1
        local there = member_point(member)
        if not (member.online_known == true and member.online == false and not there) then
          if not there or not there.map_id then return false end
          if there.map_id == map and (distance2d(mine, there) or 0) <= alone_yards then
            return false
          end
        end
      end
    end
    if others == 0 then return false end
    for _, unit in ipairs(view.units or {}) do
      local owner = (unit.summoner_guid or 0) ~= 0 and unit.summoner_guid or unit.guid
      if not guid_equal(owner, view.player_guid) and party_member_by_guid(view, owner) and
          (unit.distance or 0) <= alone_yards then
        return false
      end
    end
    return true
  end

  -- Fear, the warlock's answer to the mob that is about to finish it. It
  -- runs ahead of survive_step, whose walk away from a melee mob keeps the
  -- mob swinging at the seat's back and would cancel the 1.5s cast. Only a
  -- warlock on its own (see alone) in combat whose reported health is under
  -- FLEE_HP_PCT asks, for a live hostile whose current target is
  -- authoritatively the seat, inside the spell's own range, in sight and
  -- not already fleeing, and only with no unengaged mob near either of
  -- them. An attacker the seat's own swing is not on is preferred.
  --
  -- The intent is attack with control=true, which only a host reporting
  -- attack_control_supported carries: an older one starts a swing on the
  -- mob and casts with the wand running. The pilot stops the seat's own
  -- swing and wand and casts without starting a swing; those stops have to
  -- be ready here, from the pilot's own verdicts, or the existing defense
  -- stays. The seat's own pet has to be known absent or dead: a living pet
  -- can attack a mob that is hitting its owner, under Follow too, and its
  -- damage breaks the Fear. A request lasts press_seconds, or through the
  -- Fear cast it started, and ends early when a gate above fails or a stop
  -- it still needs is no longer ready. Every request that ends is one try
  -- on its mob, landed or not, and its outcome is logged: a mob that keeps
  -- coming back is feared at most max_tries times this fight, then the
  -- existing defense stays. The request is kept after it ends, so the hold
  -- and the escape still know which mob is feared.
  local function warlock_fear()
    if view.attack_control_supported ~= true then return nil end
    if view.class_id ~= CLASS_WARLOCK then return nil end
    local press_seconds, landing_seconds, max_tries = 4.0, 1.0, 3
    local pack_yards, alone_yards = 25.0, 100.0
    local casting = view.active_cast_spell_id or 0
    if not view.in_combat and casting == 0 then
      tactic.fear, tactic.fear_tries, tactic.escape = nil, {}, nil
      return nil
    end
    local asked = tactic.fear
    local function conclude(outcome)
      local key = tostring(asked.guid)
      asked.done, asked.outcome = true, outcome
      if outcome == "landed" then asked.landed_at = now end
      tactic.fear_tries[key] = (tactic.fear_tries[key] or 0) + 1
      wow.log(string.format("warlock fear %s on %s (try %d of %d)", outcome, key,
        tactic.fear_tries[key], max_tries))
    end
    local pet = view.pet
    if type(pet) ~= "table" or pet.guid_known ~= true or
        ((pet.guid or 0) ~= 0 and pet.dead ~= true) or not alone(alone_yards) then
      if asked and not asked.done then conclude("gated") end
      return nil
    end
    if asked and not asked.done then
      local unit = visible_unit(view, asked.guid)
      local ours = casting ~= 0 and aura_present({ casting }, "fear")
      if ours then asked.cast_seen = true end
      if feared(unit) then
        conclude("landed")
      elseif not asked.cast_seen and (((view.auto_attack_guid or 0) ~= 0 and
            view.attack_stop_ready ~= true) or
          ((view.auto_repeat_spell_id or 0) ~= 0 and
            view.auto_repeat_stop_ready ~= true)) then
        conclude("stop_not_ready")
      elseif ours or (not asked.cast_seen and hostile(unit) and
          (unit.distance or 1e9) <= asked.intent.stop_distance and
          now - asked.at < press_seconds) then
        return asked.intent
      else
        -- The aura can arrive a frame after the cast ends; the fleeing flag
        -- inside that grace only acknowledges the landing.
        asked.ended_at = asked.ended_at or now
        if asked.cast_seen and unit and unit.is_fleeing == true and
            now - asked.ended_at < landing_seconds then
          conclude("landed")
        elseif not asked.cast_seen or not hostile(unit) or
            now - asked.ended_at >= landing_seconds then
          conclude("missed")
        else
          return nil
        end
      end
    end
    if casting ~= 0 or (view.active_channel_spell_id or 0) ~= 0 then return nil end
    -- Fear holds one target at a time: a second cast frees the first.
    if asked and feared(visible_unit(view, asked.guid)) then return nil end
    if not (view.health_known == true and (view.max_health or 0) > 0 and
        self_health_pct(view) < FLEE_HP_PCT) then
      return nil
    end
    local fear = pick_spell(view, { "Fear" })
    if not fear or fear.readiness ~= "ready" or fear.range_known ~= true or
        (fear.range_max or 0) <= 0 then
      return nil
    end
    -- The seat's own running attacks have to be stoppable.
    if (view.auto_attack_guid or 0) ~= 0 and view.attack_stop_ready ~= true then
      return nil
    end
    if (view.auto_repeat_spell_id or 0) ~= 0 and view.auto_repeat_stop_ready ~= true then
      return nil
    end
    local best, best_free = nil, false
    for _, unit in ipairs(view.units or {}) do
      local d = unit.distance
      if hostile(unit) and unit.target_guid_known == true and
          guid_equal(unit.target_guid, view.player_guid) and
          unit.is_fleeing ~= true and not feared(unit) and
          unit.line_of_sight_blocked ~= true and d and d <= fear.range_max and
          (tactic.fear_tries[tostring(unit.guid)] or 0) < max_tries and
          not (guid_equal(view.selected_target_guid, unit.guid) and
            fear.in_range_known and fear.in_range == false) then
        local free = not guid_equal(view.auto_attack_guid, unit.guid)
        if not unengaged_near(unit, pack_yards) and
            (not best or (free and not best_free) or
              (free == best_free and d < best.distance)) then
          best, best_free = unit, free
        end
      end
    end
    if not best then return nil end
    local intent = { kind = "attack", guid = best.guid, spell = fear.spell_id,
      stop_distance = fear.range_max, control = true, reason = "warlock_fear" }
    tactic.fear = { guid = best.guid, at = now, intent = intent }
    return intent
  end

  -- Damage can break Fear, a direct hit far more often than a periodic tick.
  -- While a mob shows Fear, the stack's attack on it becomes a hold, and so
  -- does any attack while the seat's own feared mob is out, unless its
  -- target is a hostile already on the seat or its party: no fresh pull
  -- starts behind the fear. survive_step runs first and still moves the seat.
  local function fear_guard(intent)
    if intent.kind ~= "attack" or view.class_id ~= CLASS_WARLOCK then return intent end
    local hold = { kind = "hold", reason = "warlock_fear_hold" }
    local target = visible_unit(view, intent.guid)
    if feared(target) then return hold end
    local ours = tactic.fear and visible_unit(view, tactic.fear.guid)
    if hostile(ours) and feared(ours) and not (hostile(target) and
        target.target_guid_known == true and
        is_party_property(view, target.target_guid)) then
      return hold
    end
    return intent
  end

  -- A landed Fear at low health is time to leave, not to stand beside the
  -- feared mob: the seat walks one leg away from it while the Fear holds.
  -- The leg's goal is chosen once, when the Fear lands, and kept however
  -- the mob runs: the nearest generated turn-in of an accepted quest on
  -- this map, when walking at it moves away from the mob (real height,
  -- routed on safe ground), else a point escape_yards straight away from
  -- the mob, steered locally like survive_step's step. Only a seat on its
  -- own (see alone) with no other hostile on it or within flee range
  -- starts one. The leg ends on arrival; when the Fear is gone, another
  -- hostile reaches the seat, combat ends (the ordinary recovery and hub
  -- walks take over) or escape_seconds pass; and when the seat stops
  -- displacing or, on a routed leg, the navigator reports a failure at this
  -- pose. A routed leg that fails falls back once to the local step; a
  -- local step that fails ends the escape. After arrival or a blocked leg
  -- the seat holds where it is while that Fear lasts in combat and nothing
  -- else is on it, rather than roam into a fresh pull.
  -- An ended leg is not rebuilt until another Fear lands.
  local function fear_escape()
    if view.class_id ~= CLASS_WARLOCK then return nil end
    local escape_yards, escape_seconds, stall_seconds, stall_yards = 30.0, 25.0, 3.0, 2.0
    local near_yards, alone_yards = 12.0, 100.0
    local asked = tactic.fear
    if not asked or asked.outcome ~= "landed" then return nil end
    local leg = tactic.escape
    if leg and leg.landed_at ~= asked.landed_at then leg = nil end
    local mob = visible_unit(view, asked.guid)
    local mine, map = view_point(view), view.location and view.location.map_id
    local function away_point(from)
      local there = point(mob)
      if not there or not from then return nil end
      local dx, dy = from.x - there.x, from.y - there.y
      local mag = math.sqrt(dx * dx + dy * dy)
      if mag < 0.5 then dx, dy, mag = 1, 0, 1 end
      return { x = from.x + dx / mag * escape_yards, y = from.y + dy / mag * escape_yards,
        z = from.z, stop = 2.0, routed = false, reason = "warlock_fear_escape" }
    end
    local function threatened()
      for _, unit in ipairs(view.units or {}) do
        if hostile(unit) and not guid_equal(unit.guid, asked.guid) and not feared(unit) then
          local d = unit.combat_distance_known and unit.combat_distance or unit.distance or 1e9
          if d <= near_yards or (unit.target_guid_known == true and
              guid_equal(unit.target_guid, view.player_guid)) then
            return true
          end
        end
      end
      return false
    end
    local function after()
      if (leg.ended == "arrived" or leg.ended == "blocked") and view.in_combat and
          feared(mob) and not threatened() then
        return { kind = "hold", reason = "warlock_fear_hold" }
      end
      return nil
    end
    if leg and leg.ended then return after() end
    local function stop(why)
      leg.ended = why
      wow.log(string.format("warlock fear escape %s ended: %s", leg.goal.reason, why))
      return after()
    end
    if not leg then
      if not view.in_combat or view.is_dead or view.is_ghost or not mine or not map or
          not feared(mob) or not (view.health_known == true and
            (view.max_health or 0) > 0 and self_health_pct(view) < FLEE_HP_PCT) or
          threatened() or not alone(alone_yards) then
        return nil
      end
      local goal = away_point(mine)
      if not goal then return nil end
      local hub = vendor_hub(view)
      local there = point(mob)
      if hub and hub[4] and ((hub[2] - mine.x) * (there.x - mine.x) +
          (hub[3] - mine.y) * (there.y - mine.y)) < 0 then
        goal = { x = hub[2], y = hub[3], z = hub[4], stop = VENDOR_HUB_ARRIVE,
          routed = true, reason = "warlock_fear_escape_turnin" }
      end
      leg = { landed_at = asked.landed_at, goal = goal, since = now,
        map_id = math.floor(map), anchor = { x = mine.x, y = mine.y }, anchor_at = now }
      tactic.escape = leg
      wow.log(string.format("warlock fear escape %s to %.1f,%.1f", goal.reason, goal.x, goal.y))
    else
      if view.is_dead or view.is_ghost then return stop("dead") end
      if not view.in_combat then return stop("out_of_combat") end
      if not feared(mob) then return stop("fear_ended") end
      if threatened() then return stop("attacked") end
      if now - leg.since >= escape_seconds then return stop("timeout") end
      if not mine or not map or math.floor(map) ~= leg.map_id then return stop("left_map") end
      if (distance2d(mine, leg.goal) or 0) <= leg.goal.stop then return stop("arrived") end
      local nav = wow.nav_progress()
      local failed = leg.issued and leg.goal.routed and
        (nav.failed_here == true or nav.state == "unavailable")
      if view.movement_allowed == false or view.rooted then
        leg.anchor, leg.anchor_at = { x = mine.x, y = mine.y }, now
      elseif (distance2d(mine, leg.anchor) or 0) >= stall_yards then
        leg.anchor, leg.anchor_at = { x = mine.x, y = mine.y }, now
      elseif now - leg.anchor_at >= stall_seconds then
        failed = true
      end
      if failed then
        local fallback = leg.goal.routed and away_point(mine)
        if not fallback then return stop("blocked") end
        wow.log(string.format("warlock fear escape %s blocked; local step to %.1f,%.1f",
          leg.goal.reason, fallback.x, fallback.y))
        leg.goal, leg.issued = fallback, false
        leg.anchor, leg.anchor_at = { x = mine.x, y = mine.y }, now
      end
    end
    leg.issued = true
    local goal = leg.goal
    local intent = { kind = "navigate", x = goal.x, y = goal.y, z = goal.z,
      map_id = leg.map_id, stop_distance = goal.stop, reason = goal.reason }
    if goal.routed then
      intent.route_profile = "safe_ground"
    else
      intent.navigation_mode, intent.allow_jump = "local_steer", true
    end
    return intent
  end

  local function solo_step(policy)
    local fear = warlock_fear()
    if fear then return fear end
    local escape = fear_escape()
    if escape then return escape end
    local flee = survive_step(view)
    if flee then return flee end
    if (view.active_cast_spell_id or 0) ~= 0 or
        (view.active_channel_spell_id or 0) ~= 0 then
      return { kind = "hold", reason = "finish_active_cast" }
    end
    -- A banked talent point is one idle frame or two of stock input; it runs
    -- after the owner's requests and survival, before the leveling legs.
    local talent = talents.step(view, tstate, now, role)
    if talent then return talent end
    local progress = repair_road(progression_step(view, now, policy))
    if progress then
      -- Class-quest, trainer and loot legs walk through the same route engine
      -- as a rejoin and wedge the same way (Vulcan, 2026-11-19: a dropper
      -- attack from his Deathknell logout spot returned to one pose).
      if not view.in_combat and (progress.kind == "navigate" or
          progress.kind == "interact" or progress.kind == "attack") then
        local escape = stuck_step(view, now, false, "progress_unstick")
        if escape then
          life.note_progress(view, lstate, now, escape)
          return escape
        end
      else
        forget_stuck()
      end
      life.note_progress(view, lstate, now, progress)
      return progress
    end
    local intent = life.avoid_evading(view, lstate, solo.decide(view, policy), now,
      solo.ignore)
    -- A long walk to an objective area rides the roads like a far rejoin.
    if intent.kind == "navigate" and intent.reason == "objective_area" then
      local mine, goal = view_point(view), { x = intent.x, y = intent.y }
      if mine and distance2d(mine, goal) > ROAD_MIN_YARDS then
        local wp = road_waypoint(mine, goal, intent.map_id)
        if wp then
          intent.x, intent.y, intent.z = wp.x, wp.y, wp.z
          intent.stop_distance = ROAD_WAYPOINT_STOP
          intent.reason = "objective_area_road"
        end
      end
    end
    -- A tank with a known broken weapon starts no fresh fight; one already
    -- under way is still answered, and the repair retry keeps running.
    if intent.kind == "attack" and role == "tank" and not view.in_combat and
        not life.fighting(view) and life.broken_main_hand(view) then
      intent = { kind = "hold", reason = "broken_weapon_no_fresh_pull" }
    end
    intent = fear_guard(intent)
    local tactic_intent = class_tactic(intent)
    if tactic_intent then
      intent = life.with_pet(view, lstate, tactic_intent)
      local ranks = life.NUKE_RANKS[view.class_id] or {}
      local mine, best = nil, nil
      local nuke = intent.kind == "attack" and intent.spell and life.best_nuke(view)
      for i, id in ipairs(ranks) do
        if id == intent.spell then mine = i end
        if id == nuke then best = i end
      end
      -- Only a lower rank of the class nuke itself is raised; any other
      -- class ability the tactic chose stays as chosen.
      if mine and best and best < mine then
        intent = life.upgrade_attack(view, intent, true)
      end
    else
      intent = life.with_pet(view, lstate, intent)
      intent = life.upgrade_attack(view, intent, mana_pct(view) >= SOLO_NUKE_MANA_PCT)
    end
    life.note_progress(view, lstate, now, intent)
    return intent
  end

  -- An accepted request from the player outranks autonomous play, never
  -- survival: the death branch above and any fight below still come first.
  -- A quest request runs the solo pipeline itself, behind the healer's
  -- emergency heal so a party member falling still outranks its pull.
  local req = requests.step(view, rstate, now, { life = life, lstate = lstate,
    fighting = view.in_combat or life.fighting(view),
    quest = function()
      if role == "healer" then
        local emergency = healer_action(view, true)
        if emergency then return emergency end
      end
      return solo_step({ objective_first = true })
    end })
  if req then return finish(repair_road(req), view, "request", role) end

  local party = view.party or {}
  if party.invite_pending and lower(party.invite_from) == MURIST then
    return finish({ kind = "accept_party", reason = "accept_murist_invite" },
      view, "party_forming", role)
  end

  local murist_member = party_member(view, "Murist")
  -- A home-seat group without Murist is always wrong (the escort exists FOR
  -- him), and a grouped client auto-declines his invites. Leave so he can
  -- invite; accept_party above re-forms the party the intended way.
  if party.in_group and not murist_member then
    return finish({ kind = "leave_party", reason = "no_murist_in_group" },
      view, "party_forming", role)
  end
  if party.in_group and murist_member and
      guid_equal(party.leader_guid, view.player_guid) then
    if not last_promote_at or now - last_promote_at >= PROMOTE_RETRY_SECONDS then
      last_promote_at = now
      return finish({ kind = "promote_party", guid = murist_member.guid,
        reason = "promote_murist" }, view, "party_forming", role)
    end
  end

  local leader = murist_member and visible_player_by_name(view, "Murist") or nil
  if party.in_group and murist_member and not leader then
    if (view.active_cast_spell_id or 0) ~= 0 or
        (view.active_channel_spell_id or 0) ~= 0 then
      return finish({ kind = "hold", reason = "finish_active_cast" },
        view, "rejoin", role)
    end
    if not view.in_combat then
      local pet = summon_demon(view, role)
      if pet then return finish(pet, view, "rejoin", role) end
    end
    -- Murist is on the roster but not in visual range: walk to where the
    -- roster says he is instead of shrugging into the solo brain.
    local rejoin = rejoin_leader(view, murist_member)
    if rejoin then
      local escape = stuck_step(view, now, rejoin_busy(view), "rejoin_unstick")
      if escape then return finish(escape, view, "rejoin", role) end
      return finish(rejoin, view, "rejoin", role)
    end
    -- Murist unseen is no reason to stand in a fight the party is already
    -- in. Same order as the escort: emergency heal, flee, heal, then the
    -- role's attack, with the pet only on that engaged hostile.
    local threat = engaged_threat(view)
    if threat then
      if role == "healer" then
        local emergency = healer_action(view, true)
        if emergency then return finish(emergency, view, "escort", role, nil, threat) end
      end
      local flee = survive_step(view)
      if flee then return finish(flee, view, "escort", role, nil, threat) end
      if role == "healer" then
        local heal = healer_action(view, false)
        if heal then return finish(heal, view, "escort", role, nil, threat) end
      end
      local action = role_action(view, role, threat)
      if action and action.kind == "attack" and party_engaged(view, nil, threat) then
        action = life.with_pet(view, lstate, action)
      end
      return finish(action, view, "escort", role, nil, threat)
    end
    -- In Murist's party we never fall through to solo.decide.
    local fidget = formation_fidget(view, now)
    if fidget then return finish(fidget, view, "escort", role) end
    -- Murist is out of sight or offline and nothing above moves the seat:
    -- a banked talent point is idle work here, never a reason to walk.
    local talent = talents.step(view, tstate, now, role)
    if talent then return finish(talent, view, "escort", role) end
    return finish({ kind = "hold", reason = "hold_for_murist" },
      view, "escort", role)
  end
  if not party.in_group or not murist_member then
    return finish(solo_step(), view, "solo", role)
  end

  if (view.active_cast_spell_id or 0) ~= 0 or
      (view.active_channel_spell_id or 0) ~= 0 then
    return finish({ kind = "hold", reason = "finish_active_cast" },
      view, "escort", role, leader)
  end

  if role == "healer" then
    local emergency = healer_action(view, true)
    if emergency then return finish(emergency, view, "escort", role, leader) end
  end
  local flee = survive_step(view)
  if flee then return finish(flee, view, "escort", role, leader) end

  -- Party kills arm the shared loot machinery (state lives in accelerated;
  -- lootSeen dedupe makes the extra call idempotent for solo ticks).
  solo.note_kills(view)

  local leader_p = point(leader)
  local leader_distance = distance2d(view_point(view), leader_p)
  if not leader_distance then
    leader_distance = distance(view_point(view), leader_p)
  end
  if not leader_distance then
    leader_distance = tonumber(leader.distance)
  end
  local moving = leader_moving(leader_p, now)
  local fighting = fight_on(view, leader)
  -- Imp before follow. A petless lock glued to hard_rejoin never reached
  -- the idle buff window (Shadowfel/Igris live 2026-08-16).
  if not fighting then
    local pet = summon_demon(view, role)
    if pet then return finish(pet, view, "escort", role, leader) end
  end
  -- Out of combat, glue to Murist. IN a fight, stay on heals/peels/swings
  -- unless he is past the hard leash (2026-08-16 party wipe: 12yd follow
  -- beat Beru's heal and Tusk's peel, then everyone released).
  local trail = moving and not fighting
  local chase = (not fighting and (not leader_distance or
      leader_distance > NEAR_YARDS or trail))
    or (fighting and leader_distance and leader_distance > HARD_LEASH_YARDS)
  if chase then
    if not leader_distance or leader_distance > HARD_LEASH_YARDS then
      local escape = stuck_step(view, now, rejoin_busy(view), "escort_unstick")
      if escape then return finish(escape, view, "escort", role, leader) end
    else
      forget_stuck()
    end
    local reason = (not leader_distance or leader_distance > HARD_LEASH_YARDS)
      and "hard_rejoin_murist" or "follow_murist"
    return finish(follow_leader(view, leader, reason, moving),
      view, "escort", role, leader)
  end

  local target = nil
  -- Peel BEFORE assisting. "Hit whatever Murist is hitting" is the right
  -- default right up until something walks past the tank and starts eating
  -- Beru; see tank_peel_target for the ordering.
  if role == "tank" then target = tank_peel_target(view) end
  if not target and leader.is_in_combat and leader.target_guid_known then
    local candidate = visible_unit(view, leader.target_guid)
    if hostile(candidate) then target = candidate end
  end
  if not target then target = current_hostile(view) end
  if not target then
    -- Combat flags for OTHER units propagate lazily, so "Murist is being hit
    -- and Tusk stands there in formation" is real: neither leader.is_in_combat
    -- nor our own view.in_combat had latched. A hostile whose target IS the
    -- party — or a party member's summoned pet — is the escort's business
    -- regardless of any combat flag.
    -- One definition of "the party's business", shared with the tank's peel
    -- scan and taunt gate so they cannot disagree about whose fight this is.
    -- The leader is on the roster on this branch, so is_party_property covers
    -- him and his pet without a special case.
    local function party_property(guid)
      return is_party_property(view, guid)
    end
    -- Range-capped and nearest-first: a leashed mob a kilometer away keeps
    -- its stale party target set (Igris fixated on a Scarlet Zealot at
    -- 1273yd, never swinging, never idling, never summoning). Beyond
    -- engageable range it is not our fight, whatever its target field says.
    local bestThreat, bestThreatD = nil, nil
    for _, unit in ipairs(view.units or {}) do
      if hostile(unit) and (unit.target_guid or 0) ~= 0 and
          party_property(unit.target_guid) then
        local d = unit.combat_distance_known and unit.combat_distance
          or unit.distance or 1e9
        if d <= 50.0 and (not bestThreatD or d < bestThreatD) then
          bestThreat, bestThreatD = unit, d
        end
      end
    end
    target = bestThreat
  end

  if role == "healer" then
    local heal = healer_action(view, false)
    if heal then return finish(heal, view, "escort", role, leader, target) end
    local rez = resurrection_action(view)
    if rez then return finish(rez, view, "escort", role, leader, target) end
  end

  if target then
    local action = role_action(view, role, target)
    if action and action.kind == "attack" and party_engaged(view, leader, target) then
      action = life.with_pet(view, lstate, action)
    end
    return finish(action, view, "escort", role, leader, target)
  end

  if leader.is_in_combat then
    -- No assist verb either; the useful translation of "assist" with no
    -- visible hostile is closing on the leader until their target is.
    return finish(follow_leader(view, leader, "assist_murist_close", moving),
      view, "escort", role, leader)
  end

  if not view.in_combat then
    -- Loot the party's corpses before idle work: the window is short-lived
    -- and standing on the corpse is exactly where the fight ended anyway.
    local loot = solo.loot_step(view)
    if loot then return finish(loot, view, "escort", role, leader) end
    -- Spend a point only while Murist stands still: the talent frame never
    -- costs a follow leg, and a fight or a moving leader pauses the plan.
    if not moving then
      local talent = talents.step(view, tstate, now, role)
      if talent then return finish(talent, view, "escort", role, leader) end
    end
    -- Pet before armor. Demon Skin is a cheap 30-minute rebuy, Summon Imp is
    -- most of a low-level lock's bar, and after every wipe the seat came back
    -- with a partial pool: buffing first spent exactly the mana the summon
    -- needed and the imp never arrived (Igris, 2026-08-16).
    local bind = life.bind_step(view, lstate, now, false)
    if bind then return finish(bind, view, "escort", role, leader) end
    local buff = role == "healer" and fortitude_action(view) or nil
    if not buff then buff = summon_demon(view, role) end
    if not buff then buff = self_buff(view, role) end
    if buff then return finish(buff, view, "escort", role, leader) end
    -- Formation is the only place a seat opens its mouth: nothing is
    -- pending, the leash is short, and a host that cannot carry the words
    -- leaves chat_send_supported unset.
    if view.chat_send_supported then
      chat_poll(view, now)
      local speak = chat_step(view, now)
      if speak then return finish(speak, view, "escort", role, leader) end
    end
  end

  -- Vanilla flags AFK after ~5 min with no input. A hold in formation is
  -- exactly that, so Beru showed <AFK> while glued to Murist. A short
  -- hop every FIDGET_SECONDS is a movement packet; it also clears an
  -- already-set AFK.
  if moving then
    return finish(follow_leader(view, leader, "follow_murist", true),
      view, "escort", role, leader)
  end
  local fidget = formation_fidget(view, now)
  if fidget then return finish(fidget, view, "escort", role, leader) end

  return finish({ kind = "hold", reason = "in_formation" },
    view, "escort", role, leader)
end

return M
