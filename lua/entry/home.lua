-- Home army: Murist escort with class roles and a solo-leveling fallback.
-- Runs in the fork's embedded lua-bot against the raw Observation mirror.

local solo = require("accelerated")
-- Dotted, like traverse's config.* requires: the lua-bot's package.path is the
-- repo's lua/ and lua/entry/, so a bare "road_route" does not resolve at
-- runtime even though the test harness puts lua/tools on LUA_PATH.
local road_route = require("tools.road_route")
local disposition = require("tools.item_disposition")
-- Home is the dogfood pen, not a scored league: run the soft-quest path here
-- so the new quest stack gets exercised where monofuel can watch. Scored
-- leagues stay grind-only until a rerun A/B beats the 4.791 baseline.
solo.set_quests(true)

local M = {}

local MURIST = "murist"
local NEAR_YARDS = 8.0
local HARD_LEASH_YARDS = 18.0
local HEAL_RANGE_YARDS = 30.0
local RES_WAIT_SECONDS = 20.0
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

local dead_since = nil
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
local wand_pressed_at = nil
local wand_pressed_guid = nil
local last_shout_at = nil
-- Vanilla AFK is ~5 min with no movement. Formation hold is silent.
local FIDGET_SECONDS = 90.0
local fidget_at = nil
-- Formation range is a stop, not a park. A leader still moving inside
-- NEAR_YARDS has to stay a follow or the seat stands while he runs off.
local LEAD_RUN_YDS = 1.5
local LEAD_STILL_YDS = 0.5
local LEAD_STILL_SECONDS = 0.4
local last_lead = nil

local AURA_FAMILIES = {
  ["curse of agony"] = { 980, 1014, 6217, 11711, 11712, 11713 },
  ["corruption"] = { 172, 6222, 6223, 7648, 11671, 11672 },
  ["immolate"] = { 348, 707, 1094, 2941, 11665, 11667, 11668 },
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
function road_waypoint(mine, goal, map_id)
  local graph = road_graph(map_id)
  if not graph then return nil end
  local pts, meta = road_route.route(graph, mine, goal)
  if meta.straight then return nil end
  local x, y, z, i = road_route.nextPoint(pts, mine.x, mine.y,
    ROAD_LOOKAHEAD_YARDS)
  if not x or not i or i >= #pts then return nil end
  local wp = { x = x, y = y, z = z }
  -- closer_on_plane: a waypoint farther from the goal than we already are
  -- is pavement behind us. Walk at the goal instead.
  if not closer_on_plane(mine, wp, goal) then return nil end
  return wp
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

local function spell_ready(spell)
  if not spell or spell.passive or spell.from_item then return false end
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
  if #facts > 0 then return facts end
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
local function pick_spell(view, priorities, prefer_low_rank)
  for _, wanted in ipairs(priorities) do
    local want = normalized(wanted)
    local best = nil
    for _, spell in ipairs(spell_candidates(view)) do
      local name = normalized(spell.name)
      local better = not best or (prefer_low_rank
        and (spell.rank or 0) < (best.rank or 0)
        or not prefer_low_rank and (spell.rank or 0) > (best.rank or 0))
      if spell.name_known ~= false and spell_ready(spell) and
          (name == want or name:find(want, 1, true)) and better then
        best = spell
      end
    end
    if best then return best, want end
  end
  return nil, nil
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
local VENDOR_SELL_GAP_SECONDS = 0.6
local vendor_last_sell_at = nil
local vendor_merchant = nil
local vendor_sold = {}
local vendor_reported = false
local vendor_gap_logged = false

local function vendor_forget()
  vendor_merchant = nil
  vendor_sold = {}
  vendor_reported = false
end

local function vendor_sell_step(view, now)
  if not view.merchant_open then
    vendor_forget()
    return nil
  end
  local merchant = tostring(view.merchant_guid or "0")
  if merchant ~= vendor_merchant then
    vendor_merchant = merchant
    vendor_sold = {}
    vendor_reported = false
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
  if vendor_last_sell_at and now - vendor_last_sell_at < VENDOR_SELL_GAP_SECONDS then
    return nil
  end
  for i = 1, #plan.sell do
    local row = plan.sell[i]
    local guid = tostring(row.item_guid or "0")
    if guid ~= "0" and not vendor_sold[guid] then
      vendor_sold[guid] = true
      vendor_last_sell_at = now
      wow.log(string.format("vendor: selling %s x%d — %s",
        tostring(row.name), row.count, row.reason))
      return { kind = "sell_item", guid = view.merchant_guid,
        item_guid = row.item_guid, count = row.count,
        reason = "vendor_sell_" .. tostring(row.tag):lower() }
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
-- Live 2026-08-16: first-frame `interact` open_vendor freezes decide the
-- same way 0074 equip_item does (Baran/Kargalgan status stuck sequence=1).
-- Flip this when interact no longer kills the pilot.
local VENDOR_SEEK_EMIT = false

local function unit_has_service(unit, name)
  for i = 1, #(unit.services or {}) do
    if unit.services[i] == name then return true end
  end
  return false
end

local function nearest_vendor(view)
  local best, best_d = nil, nil
  local pure, pure_d = nil, nil
  for _, unit in ipairs(view.units or {}) do
    if unit_has_service(unit, "vendor") and
        not (unit.death_known and unit.is_dead) and
        unit.object_kind ~= "player" then
      local d = tonumber(unit.distance) or 1e9
      if not best_d or d < best_d then best, best_d = unit, d end
      -- A questgiver-vendor opens the quest panel, not the merchant
      -- (Baran vs Joshua Kien, 2026-08-16). Prefer a pure vendor.
      if not unit_has_service(unit, "questgiver") then
        if not pure_d or d < pure_d then pure, pure_d = unit, d end
      end
    end
  end
  if pure then return pure, pure_d end
  return best, best_d
end

local function vendor_seek_step(view)
  if not VENDOR_SEEK_EMIT then return nil end
  if view.in_combat or view.is_dead or view.is_ghost then return nil end
  if view.merchant_open then return nil end
  if not view.sell_supported then return nil end
  if party_member(view, MURIST) then return nil end
  if not view.bag_space_known then return nil end
  local free = tonumber(view.free_bag_slots)
  if free == nil or free > VENDOR_SEEK_FREE_SLOTS then return nil end
  local items = view.inventory_items
  if type(items) ~= "table" then return nil end
  local plan = disposition.evaluate({
    items = items,
    equipment = view.equipment_items,
    player = { class_id = view.class_id, level = view.level },
  })
  if #plan.sell == 0 then return nil end
  local vendor, vendor_d = nearest_vendor(view)
  if not vendor then return nil end
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
    -- CMSG_REPOP_REQUEST drops the world session on this host. A corpse
    -- can still take a rez; ghost reclaim does not teleport the session.
    return { kind = "hold", reason = "skip_release" }, "waiting_for_rez"
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
    local shield = pick_spell(view, { "Power Word: Shield" })
    if shield and not aura_present(auras, "power word shield", shield.spell_id) then
      return cast(shield, "shield_tank", row.guid)
    end
  end
  if hp < TANK_RENEW_PCT and mana_pct(view) >= CONSERVE_MANA_PCT then
    local renew = pick_spell(view, { "Renew" })
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
    local shield = pick_spell(view, { "Power Word: Shield" })
    if shield and not aura_present(auras, "power word shield", shield.spell_id) and
        not aura_present(auras, "weakened soul") then
      return cast(shield, "shield_low_party_member", row.guid)
    end
  end
  local heal = nil
  if hp < 20 then
    heal = pick_spell(view, { "Flash Heal", "Heal", "Lesser Heal" })
  elseif hp < 45 then
    heal = pick_spell(view, { "Heal", "Lesser Heal", "Flash Heal" })
  elseif hp < 70 then
    -- Shallow deficit: the cheapest rank that exists covers it, and a renew
    -- that is already ticking covers it for free.
    if row.active_auras_known ~= false then
      local renew = pick_spell(view, { "Renew" })
      if renew and not aura_present(auras, "renew", renew.spell_id) then
        return cast(renew, "renew_party_member", row.guid)
      end
    end
    heal = pick_spell(view, { "Heal", "Lesser Heal", "Flash Heal" }, true)
  elseif hp < 90 and row.active_auras_known ~= false then
    local renew = pick_spell(view, { "Renew" })
    if renew and not aura_present(auras, "renew", renew.spell_id) then
      return cast(renew, "renew_party_member", row.guid)
    end
  end
  return cast(heal, "heal_party_member", row.guid)
end

local function resurrection_action(view)
  if view.in_combat then return nil end
  local spell = pick_spell(view, { "Resurrection" })
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

local function warlock_action(view, target)
  if mana_pct(view) < 18 and self_health_pct(view) >= 40 then
    local tap = pick_spell(view, { "Life Tap" })
    if tap then return cast(tap, "life_tap") end
  end
  local auras = target.active_aura_spell_ids or {}
  for _, name in ipairs({ "Curse of Agony", "Corruption", "Immolate" }) do
    local spell, family = pick_spell(view, { name })
    if spell and not aura_present(auras, family, spell.spell_id) then
      return { kind = "attack", guid = target.guid, spell = spell.spell_id,
        stop_distance = 22.0, reason = "warlock_" .. family:gsub(" ", "_") }
    end
  end
  local filler = pick_spell(view, { "Shadow Bolt", "Shoot" })
  return { kind = "attack", guid = target.guid,
    spell = filler and filler.spell_id or nil,
    stop_distance = filler and 22.0 or 4.0,
    reason = filler and "warlock_filler" or "warlock_melee_fallback" }
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
      (not last_shout_at or now - last_shout_at >= SHOUT_RETRY_SECONDS) then
    last_shout_at = now
    return cast(shout, "tank_battle_shout")
  end
  -- Debuffs before the dump, aura-gated so a DoT is applied once per mob
  -- instead of clipping itself with a refresh every tick.
  local auras = target.active_aura_spell_ids or {}
  for _, name in ipairs({ "Rend", "Demoralizing Shout" }) do
    local spell, family = pick_spell(view, { name })
    if spell and not aura_present(auras, family, spell.spell_id) then
      return { kind = "attack", guid = target.guid, spell = spell.spell_id,
        stop_distance = 4.0, reason = "tank_" .. family:gsub(" ", "_") }
    end
  end
  -- Threat filler in rage-cost order, not damage order: Revenge is nearly
  -- free off a block, Sunder is the threat-per-rage king, and Heroic Strike
  -- is the DUMP -- last, because it is what a tank presses with rage left
  -- over, not what he opens with.
  local threat = pick_spell(view, {
    "Revenge", "Sunder Armor", "Thunder Clap", "Heroic Strike",
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

-- The wand: free damage, and the one button a healer must never press twice.
-- See WAND_REPRESS_SECONDS. Returns the "keep firing, touch nothing" intent
-- while the shot train is alive, and only asks for the button when the client
-- says the wand is idle AND we have not just pressed it ourselves.
local function wand_intent(view, target)
  local wand = pick_spell(view, { "Shoot" })
  if not wand then return nil end
  local now = tonumber(view.simulation_time) or 0
  local just_pressed = wand_pressed_at ~= nil and
    guid_equal(wand_pressed_guid, target.guid) and
    (now - wand_pressed_at) < WAND_REPRESS_SECONDS
  if wand.active == true or just_pressed then
    return { kind = "attack", guid = target.guid, stop_distance = 22.0,
      reason = "healer_wanding" }
  end
  wand_pressed_at, wand_pressed_guid = now, target.guid
  return { kind = "attack", guid = target.guid, spell = wand.spell_id,
    stop_distance = 22.0, reason = "healer_wand" }
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
  local auras = target.active_aura_spell_ids or {}
  local pain, family = pick_spell(view, { "Shadow Word: Pain" })
  if pain and mana >= DOT_MANA_PCT and
      not aura_present(auras, family, pain.spell_id) then
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
  local filler = pick_spell(view, { "Fireball", "Frostbolt", "Shoot" })
  return { kind = "attack", guid = target.guid,
    spell = filler and filler.spell_id or nil,
    stop_distance = filler and 22.0 or 4.0,
    reason = filler and "mage_nuke" or "mage_melee_fallback" }
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
        self_health_pct(view) >= SUMMON_LIFE_TAP_MIN_HEALTH_PCT then
      local tap = pick_spell(view, { "Life Tap" })
      if tap then return cast(tap, "life_tap_for_summon") end
    end
    return nil
  end
  return cast(spell, "summon_imp")
end

local function fortitude_action(view)
  local spell = pick_spell(view, { "Power Word: Fortitude" })
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
  dead_since = nil
  last_promote_at = nil
  forget_stuck()
  stuckSeenAt = nil
  stuckBearing = 0
  chatOpenSince = nil
  chat_last_poll_at = nil
  chat_last_sent_at = nil
  chat_pending = nil
  vendor_forget()
  vendor_last_sell_at = nil
  equip_last_at = nil
  equip_tried = {}
  equip_attempts = 0
  equip_gave_up = false
  wand_pressed_at = nil
  wand_pressed_guid = nil
  last_shout_at = nil
  fidget_at = nil
  last_lead = nil
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

  local seek = vendor_seek_step(view)
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
    -- Murist is on the roster but not in visual range: walk to where the
    -- roster says he is instead of shrugging into the solo brain.
    local rejoin = rejoin_leader(view, murist_member)
    if rejoin then
      local escape = stuck_step(view, now, rejoin_busy(view), "rejoin_unstick")
      if escape then return finish(escape, view, "rejoin", role) end
      return finish(rejoin, view, "rejoin", role)
    end
    -- In Murist's party we never fall through to solo.decide.
    local fidget = formation_fidget(view, now)
    if fidget then return finish(fidget, view, "escort", role) end
    return finish({ kind = "hold", reason = "hold_for_murist" },
      view, "escort", role)
  end
  if not party.in_group or not murist_member then
    local flee = survive_step(view)
    if flee then return finish(flee, view, "solo", role) end
    if (view.active_cast_spell_id or 0) ~= 0 or
        (view.active_channel_spell_id or 0) ~= 0 then
      return finish({ kind = "hold", reason = "finish_active_cast" },
        view, "solo", role)
    end
    if not view.in_combat then
      local pet = summon_demon(view, role)
      if pet then return finish(pet, view, "solo", role) end
    end
    local intent = solo.decide(view)
    return finish(intent, view, "solo", role)
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
    local action = role == "tank" and warrior_action(view, target)
      or role == "healer" and priest_damage(view, target)
      or view.class_id == CLASS_MAGE and mage_action(view, target)
      or view.class_id == CLASS_ROGUE and rogue_action(view, target)
      or warlock_action(view, target)
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
    -- Pet before armor. Demon Skin is a cheap 30-minute rebuy, Summon Imp is
    -- most of a low-level lock's bar, and after every wipe the seat came back
    -- with a partial pool: buffing first spent exactly the mana the summon
    -- needed and the imp never arrived (Igris, 2026-08-16).
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
