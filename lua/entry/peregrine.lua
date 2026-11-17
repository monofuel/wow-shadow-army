-- accelerated: grind low-level mobs for XP.
--
-- Scoring is level + xp/next_level_xp over a short episode, so every decision
-- serves kills per minute. A level 1-6 druid has about three Wraths worth of
-- mana, so auto-attack is the backbone and the nuke is an opener and a filler;
-- a brain that only casts spends most of each fight doing nothing.
--
-- Soft-quest code is present but off by default after measuring 2.009 < B0
-- 4.791. When enabled: budget/patience, no travel while huntables nearby,
-- no new accepts before lvl 2, lua-bot dialog verbs only (not RPB quest FSM).

local M = {}

-- Soft-quest gates measured 2026-08-10: score 2.009 < B0 4.791. Keep code;
-- leave off until a candidate beats grind-only. Tests flip via M.set_quests.
local QUESTS = false

function M.set_quests(on)
  QUESTS = not not on
end

-- Quest marker status as the server reports it.
local MARKER_AVAILABLE = 5
local MARKER_REWARD = { [6] = true, [7] = true }
local QUEST_LOG_LIMIT = 20
local QUESTGIVER_YARDS = 60.0
-- A giver that will not open its dialog is worth less than the mobs we are
-- not killing while we stand there.
local QUESTGIVER_PATIENCE = 45.0
-- Hard cap on continuous quest travel/interact so a stuck giver cannot eat
-- the whole 720s episode even if patience is reset by marker noise.
local QUEST_BUDGET_SECONDS = 25.0
-- Stop close enough that /interact can open the panel (default nav stop is wider).
local QUEST_INTERACT_STOP = 3.5
-- Do not walk to *new* quests until we have a kill's worth of level progress.
local QUEST_TRAVEL_MIN_LEVEL = 2

-- Opening nuke per class, highest rank first.
local NUKES_BY_CLASS = {
  [11] = { 5177, 5176 }, -- druid: Wrath r2/r1
  [7] = { 529, 403 },    -- shaman: Lightning Bolt r2/r1
  [9] = { 695, 686 },    -- warlock: Shadow Bolt r2/r1
  [5] = { 591, 585 },    -- priest: Smite r2/r1
  [8] = { 143, 133 },    -- mage: Fireball r2/r1
}

-- Buff once per life: cheap, and a level 1 character has almost no stats.
-- Tables are highest rank first; first usable on the action bar wins.
local BUFFS_BY_CLASS = {
  [11] = { 1126 },       -- druid: Mark of the Wild
  [9] = { 696, 687 },    -- warlock: Demon Skin r2/r1
}

local ENGAGE_YARDS = 4.0
local SEARCH_YARDS = 40.0        -- a starting field is sparser than a road
local ROAM_YARDS = 70.0          -- a leg long enough to reach new spawns
local CORPSE_STOP_YARDS = 30.0   -- the reclaim radius is 39; stop short of it
local STALL_SECONDS = 8.0
-- Rotating a leg restarts the route, so a leg has to be given time to work.
local LEG_MIN_SECONDS = 4.0
local PROGRESS_YARDS = 3.0
local POST_KILL_HOLDS = 2

-- Upstream's own recovery gates: below these, a fresh pull is a bad trade.
local RECOVERY_HEALTH_PCT = 75.0
local RECOVERY_MANA_PCT = 55.0
local RETREAT_HEALTH_PCT = 20.0
local FINISH_TARGET_HEALTH_PCT = 20.0
local NUKE_MANA_FLOOR_PCT = 35.0

-- Headings walked in turn. Legs start from wherever the seat is standing, so
-- clearing one patch of ground leads onto the next instead of pacing a box.
local HEADINGS = {
  { dx = 1.0, dy = 0.0 },
  { dx = 0.0, dy = 1.0 },
  { dx = -1.0, dy = 0.0 },
  { dx = 0.0, dy = -1.0 },
}

local heading = 1
local legTarget = nil
local legStartedAt = nil
local lastPos = nil
local lastProgressAt = nil
local holdsAfterKill = 0
local buffedAt = nil
-- Questgivers with nothing left for us, forgotten again whenever our quest
-- state changes and they might have something new.
local exhausted = {}
local questSignature = nil
local pursuing = nil
local pursuingSince = nil
-- Wall-clock start of the current continuous quest-travel streak (nil = idle).
local questBudgetSince = nil

local function distance2d(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return math.sqrt(dx * dx + dy * dy)
end

local function percent(current, maximum)
  if not maximum or maximum <= 0 then return 100.0 end
  return (current or 0) * 100.0 / maximum
end

local function health_pct(view)
  if not view.health_known then return 100.0 end
  return percent(view.health, view.max_health)
end

-- Mana stays visible in the power pools even when a form hides it.
local function mana_pct(view)
  local pools, maxima = view.powers, view.max_powers
  if not pools or not maxima or not maxima[1] or maxima[1] <= 0 then
    return 100.0
  end
  return percent(pools[1], maxima[1])
end

local function unit_distance(unit)
  if unit.combat_distance_known then return unit.combat_distance end
  return unit.distance or 1e9
end

-- Mirrors upstream's actionable-target rule: the mobs that are safe to fight
-- and actually pay us.
local function huntable(view, unit, freshPull)
  if not unit.player_can_attack then return false end
  if unit.death_known and unit.is_dead then return false end
  if unit.health_known and unit.health <= 0 then return false end
  if unit.creature_rank_known and unit.creature_rank ~= 0 then return false end
  if unit.creature_type_known and unit.creature_type == 8 then return false end
  if unit.is_tapped and not unit.tapped_by_player then return false end
  if unit.summoner_guid and unit.summoner_guid ~= 0 then return false end
  if unit_distance(unit) > SEARCH_YARDS then return false end
  if unit.level_known then
    local ceiling = (view.level or 1) + (freshPull and 2 or 5)
    if unit.level > ceiling then return false end
  end
  return true
end

local function engaged_unit(view)
  local guid = view.auto_attack_guid or 0
  if guid == 0 then return nil end
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    if unit.guid == guid and not (unit.death_known and unit.is_dead) then
      return unit
    end
  end
  return nil
end

-- A mob that pays an objective is worth more than an equally close one that
-- does not. Defined before pick_target so the local binding is visible.
local function credits_objective(view, unit)
  for i = 1, #(view.quest_objectives or {}) do
    local objective = view.quest_objectives[i]
    if not objective.complete and objective.entry ~= 0 and
        objective.entry == unit.entry then
      return true
    end
  end
  return false
end

local function pick_target(view, freshPull)
  local best, bestScore = nil, nil
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    if huntable(view, unit, freshPull) then
      -- Distance decides, but a mob on an active objective is worth a walk.
      local score = unit_distance(unit)
      if QUESTS and credits_objective(view, unit) then
        score = score - 25.0
      end
      if not bestScore or score < bestScore then
        best, bestScore = unit, score
      end
    end
  end
  return best
end

local function usable_spell(view, spellId)
  for i = 1, #(view.action_buttons or {}) do
    local button = view.action_buttons[i]
    if button.spell_id == spellId then
      if button.usable_known and not button.usable then return false end
      if button.not_enough_mana then return false end
      return true
    end
  end
  return false
end

local function pick_nuke(view)
  local prio = NUKES_BY_CLASS[view.class_id or 0]
  if not prio then return nil end
  for i = 1, #prio do
    if usable_spell(view, prio[i]) then return prio[i] end
  end
  return nil
end

local function killed_target(view, guid)
  for i = 1, #(view.combat_kill_events or {}) do
    if view.combat_kill_events[i].target_guid == guid then return true end
  end
  return false
end

local function start_leg(pos, now)
  local step = HEADINGS[heading]
  legTarget = {
    x = pos.x + step.dx * ROAM_YARDS,
    y = pos.y + step.dy * ROAM_YARDS,
  }
  legStartedAt = now
  lastPos, lastProgressAt = { x = pos.x, y = pos.y }, now
end

local function turn(pos, now)
  heading = heading % #HEADINGS + 1
  start_leg(pos, now)
end

-- Roam for fresh spawns: a cleared patch has nothing left to kill, so each
-- leg leaves from where the seat stands rather than pacing a fixed box.
local function roam_target(view, pos)
  local now = wow.time()
  local nav = wow.nav_progress()
  if not legTarget then start_leg(pos, now) end

  local moved = lastPos and
    distance2d(pos.x, pos.y, lastPos.x, lastPos.y) >= PROGRESS_YARDS
  if moved then
    lastPos, lastProgressAt = { x = pos.x, y = pos.y }, now
  end

  -- A pinned failure is not fixed by a different destination; the host takes
  -- a walkout step from this pose. Turn only once that is spent, only on a
  -- route the client reports it cannot serve right now, and never faster than
  -- the route engine can plan one. Movement we do not control is not a stall.
  local unavailable = nav.state == "unavailable" and not nav.walkout_available
  local controllable = view.movement_allowed and not view.rooted
  local stalled = controllable and lastProgressAt and
    now - lastProgressAt > STALL_SECONDS
  if (unavailable or stalled) and now - legStartedAt >= LEG_MIN_SECONDS then
    turn(pos, now)
  elseif distance2d(pos.x, pos.y, legTarget.x, legTarget.y) <= ENGAGE_YARDS then
    turn(pos, now)
  end
  return legTarget.x, legTarget.y
end

-- Quest work. Every step is a dialog panel answer or one interface control,
-- so none of it touches the world-click path.
local function quest_signature(view)
  return string.format("%d:%d:%d",
    view.level or 0,
    #(view.accepted_quests or {}),
    #(view.completed_quest_ids or {}))
end

local function marker_status(view, guid)
  for i = 1, #(view.quest_markers or {}) do
    local marker = view.quest_markers[i]
    if marker.questgiver_guid == guid then return marker.status end
  end
  return 0
end

local function greeting_row(view)
  local rows = view.quest_frame and view.quest_frame.greeting_rows or {}
  -- A turn-in is worth more than a new quest, so answer active rows first.
  for i = 1, #rows do
    if rows[i].active then return rows[i].quest_id end
  end
  if rows[1] then return rows[1].quest_id end
  return nil
end

local function gossip_row(view)
  local offers = view.quest_offers or {}
  local guid = view.gossip_guid or 0
  for i = 1, #offers do
    if offers[i].questgiver_guid == guid then return offers[i].quest_id end
  end
  return nil
end

local function control_for(view, reference)
  for i = 1, #(view.ui_nodes or {}) do
    local node = view.ui_nodes[i]
    if node.reference_id == reference and node.enabled and node.hit_testable then
      return reference
    end
  end
  return nil
end

local function dialog_open(view)
  local frame = view.quest_frame or {}
  if frame.open then return true end
  if view.gossip_open then return true end
  return false
end

local function has_reward_marker(view)
  for i = 1, #(view.quest_markers or {}) do
    local marker = view.quest_markers[i]
    if MARKER_REWARD[marker.status] then return true end
  end
  return false
end

-- Walk to givers only after we have some XP, unless a turn-in is waiting.
local function allow_quest_travel(view)
  if has_reward_marker(view) then return true end
  return (view.level or 1) >= QUEST_TRAVEL_MIN_LEVEL
end

-- Answer whatever dialog is open, then (optionally) look for a giver to walk to.
-- allowTravel=false keeps dialog answers but never starts a new approach.
local function quest_step(view, allowTravel)
  local frame = view.quest_frame or {}
  if frame.open then
    questBudgetSince = nil
    if frame.panel == "reward" then
      return { kind = "quest_cmd", command = "/questreward", reason = "turn_in" }
    end
    if frame.panel == "progress" then
      if frame.can_complete then
        return { kind = "quest_cmd", command = "/questcomplete", reason = "complete" }
      end
      return { kind = "ui_press", control = "QuestFrameGoodbyeButton",
        reason = "unfinished" }
    end
    if frame.panel == "details" then
      if #(view.accepted_quests or {}) >= QUEST_LOG_LIMIT then
        return { kind = "ui_press", control = "QuestFrameDeclineButton",
          reason = "log_full" }
      end
      return { kind = "quest_cmd", command = "/questaccept", reason = "accept" }
    end
    if frame.panel == "greeting" then
      local questId = greeting_row(view)
      local reference = questId and control_for(view, "quest-greeting:" .. questId)
      if reference then
        return { kind = "ui_press", reference = reference, reason = "greeting_row" }
      end
      return { kind = "ui_press", control = "QuestFrameGreetingGoodbyeButton",
        reason = "nothing_offered" }
    end
  end
  if view.gossip_open then
    questBudgetSince = nil
    local questId = gossip_row(view)
    local reference = questId and control_for(view, "gossip-quest:" .. questId)
    if reference then
      return { kind = "ui_press", reference = reference, reason = "gossip_row" }
    end
    exhausted[view.gossip_guid or 0] = true
    return { kind = "ui_press", control = "GossipFrameGreetingGoodbyeButton",
      reason = "gossip_done" }
  end

  if not allowTravel then
    pursuing, pursuingSince, questBudgetSince = nil, nil, nil
    return nil
  end

  -- Prefer turn-in (reward) markers over new accepts when ranking givers.
  local best, bestDistance, bestRank = nil, nil, nil
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    local status = marker_status(view, unit.guid)
    local rank = nil
    if MARKER_REWARD[status] then
      rank = 0
    elseif status == MARKER_AVAILABLE and
        #(view.accepted_quests or {}) < QUEST_LOG_LIMIT then
      rank = 1
    end
    if rank and not exhausted[unit.guid] and
        not (unit.death_known and unit.is_dead) then
      local d = unit_distance(unit)
      if d <= QUESTGIVER_YARDS and
          (not best or rank < bestRank or (rank == bestRank and d < bestDistance)) then
        best, bestDistance, bestRank = unit, d, rank
      end
    end
  end
  if best then
    local now = wow.time()
    if pursuing ~= best.guid then
      pursuing, pursuingSince = best.guid, now
      questBudgetSince = now
    end
    if questBudgetSince and now - questBudgetSince > QUEST_BUDGET_SECONDS then
      exhausted[best.guid] = true
      pursuing, pursuingSince, questBudgetSince = nil, nil, nil
      wow.log("quest budget exhausted on " .. (best.name or "?"))
      return nil
    end
    if now - pursuingSince > QUESTGIVER_PATIENCE then
      exhausted[best.guid] = true
      pursuing, pursuingSince, questBudgetSince = nil, nil, nil
      wow.log("gave up on questgiver " .. (best.name or "?"))
      return nil
    end
    wow.set_status("questgiver " .. (best.name or "?"))
    return {
      kind = "interact",
      guid = best.guid,
      stop_distance = QUEST_INTERACT_STOP,
      route_profile = "prefer_ground",
      reason = "questgiver",
    }
  end
  pursuing, pursuingSince, questBudgetSince = nil, nil, nil
  return nil
end

local function progress_status(view)
  return {
    level = view.level,
    xp = view.xp,
    next_level_xp = view.next_level_xp,
    health_pct = math.floor(health_pct(view)),
    mana_pct = math.floor(mana_pct(view)),
  }
end

function M.decide(view)
  -- Death first: everything else is unreachable from a corpse.
  if view.is_dead and not view.is_ghost then
    wow.set_status("dead: releasing")
    return { kind = "release", reason = "died", status = progress_status(view) }
  end
  if view.resurrect_offer_guid and view.resurrect_offer_guid ~= 0 then
    return { kind = "accept_rez", reason = "offered", status = progress_status(view) }
  end
  if view.is_ghost then
    buffedAt = nil
    if view.can_reclaim_corpse then
      wow.set_status("ghost: reclaiming")
      return { kind = "reclaim", reason = "at_corpse", status = progress_status(view) }
    end
    if view.corpse_known and view.corpse_location then
      local corpse = view.corpse_location.position
      wow.set_status("ghost: corpse run")
      return {
        kind = "navigate",
        x = corpse.x, y = corpse.y, z = corpse.z,
        map_id = math.floor(view.corpse_location.map_id or 0),
        stop_distance = CORPSE_STOP_YARDS,
        route_profile = "safe_ground",
        reason = "corpse_run",
        status = progress_status(view),
      }
    end
    return { kind = "hold", reason = "ghost_without_corpse", status = progress_status(view) }
  end

  if not view.location_known or not view.location then
    return { kind = "hold", reason = "no_position" }
  end
  local pos = view.location.position

  -- The server's combat bit lags a kill; re-acquiring into a corpse wastes
  -- the swing that would have started the next fight.
  if holdsAfterKill > 0 then
    holdsAfterKill = holdsAfterKill - 1
    return { kind = "hold", reason = "kill_settling", status = progress_status(view) }
  end

  local health = health_pct(view)
  local mana = mana_pct(view)
  local engaged = engaged_unit(view)

  if QUESTS then
    local signature = quest_signature(view)
    if signature ~= questSignature then
      -- Our quest state moved, so a giver we gave up on may have new work.
      exhausted = {}
      questSignature = signature
    end
    if not engaged and not view.in_combat then
      -- Always finish an open dialog (free XP / log space). Only *walk* to
      -- givers when nothing huntable is nearby and travel is allowed.
      local nearbyHunt = pick_target(view, true)
      local allowTravel = allow_quest_travel(view) and not nearbyHunt
      local step = quest_step(view, allowTravel)
      if step and not (step.kind == "interact" and not allowTravel) then
        step.status = progress_status(view)
        return step
      end
    end
  end

  if engaged and killed_target(view, engaged.guid) then
    holdsAfterKill = POST_KILL_HOLDS
    return { kind = "hold", reason = "target_died", status = progress_status(view) }
  end

  -- Break off a losing fight, unless the kill is one swing away.
  if engaged and health < RETREAT_HEALTH_PCT then
    local nearlyDead = engaged.health_known and
      percent(engaged.health, engaged.max_health) <= FINISH_TARGET_HEALTH_PCT
    if not nearlyDead then
      wow.set_status(string.format("retreat at %d%% hp", math.floor(health)))
      local step = HEADINGS[heading % #HEADINGS + 1]
      local tx = pos.x + step.dx * ROAM_YARDS * 0.25
      local ty = pos.y + step.dy * ROAM_YARDS * 0.25
      return {
        kind = "navigate",
        x = tx, y = ty, z = pos.z,
        map_id = math.floor(view.location.map_id or 0),
        stop_distance = ENGAGE_YARDS,
        route_profile = "safe_ground",
        reason = "retreat",
        status = progress_status(view),
      }
    end
  end

  -- One buff per life, while nothing is hitting us.
  local buffs = BUFFS_BY_CLASS[view.class_id or 0]
  if buffs and not engaged and not view.in_combat and buffedAt ~= view.level then
    for i = 1, #buffs do
      if usable_spell(view, buffs[i]) then
        buffedAt = view.level
        return {
          kind = "cast_spell",
          spell = buffs[i],
          reason = "buff",
          status = progress_status(view),
        }
      end
    end
  end

  -- Keep fighting what is already engaged; only fresh pulls face the gates.
  local target = engaged
  if not target then
    local rested = health >= RECOVERY_HEALTH_PCT and mana >= RECOVERY_MANA_PCT
    if not view.in_combat and not rested then
      -- Travel satisfies the five second rule, so walking to the next spawn
      -- regenerates for free where standing still would not.
      local tx, ty = roam_target(view, pos)
      wow.set_status(string.format("recover %d%% hp %d%% mana",
        math.floor(health), math.floor(mana)))
      return {
        kind = "navigate",
        x = tx, y = ty, z = pos.z,
        map_id = math.floor(view.location.map_id or 0),
        stop_distance = ENGAGE_YARDS,
        route_profile = "prefer_ground",
        reason = "recover_walk",
        status = progress_status(view),
      }
    end
    target = pick_target(view, true)
  end

  if target then
    local spell = nil
    if mana >= NUKE_MANA_FLOOR_PCT then
      spell = pick_nuke(view)
    end
    wow.set_status(string.format(
      "attack %s lvl %d (%.0fyd) %d%% hp",
      target.name or "?", target.level or 0, unit_distance(target),
      math.floor(health)
    ))
    return {
      kind = "attack",
      guid = target.guid,
      spell = spell,
      stop_distance = ENGAGE_YARDS,
      route_profile = "prefer_ground",
      reason = "grind",
      status = progress_status(view),
    }
  end

  local tx, ty = roam_target(view, pos)
  wow.set_status(string.format("roam heading %d", heading))
  return {
    kind = "navigate",
    x = tx, y = ty, z = pos.z,
    map_id = math.floor(view.location.map_id or 0),
    stop_distance = ENGAGE_YARDS,
    route_profile = "prefer_ground",
    reason = "roam_" .. heading,
    status = progress_status(view),
  }
end

return M
