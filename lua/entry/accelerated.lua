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
-- How far a giver may be and still be worth walking to. 60 was a scored-episode
-- number; it is too short to ever leave a grinding field and go back to town,
-- which is where every Deathknell giver is. All of this code is behind the
-- QUESTS flag, which the scored lanes keep off, so the trade here is the home
-- lane's alone: quests finished beats kills per minute.
local QUESTGIVER_YARDS = 120.0
-- Rank-2 scout (unmarked friendly) is only for NPCs we can already talk to.
-- Walking 90yd to a Deathguard (Bellion, 2026-08-16) wedges on a guard that
-- never has a quest; real givers are reached via generated starters.
local SCOUT_YARDS = 35.0
-- Empty-log walk to a generated starter. Sarvis is ~141yd from the
-- Deathknell zombie field; keep this above that and below a zone hop.
local STARTER_HUB_YARDS = 220.0
-- A giver that will not open its dialog is worth less than the mobs we are
-- not killing while we stand there.
local QUESTGIVER_PATIENCE = 75.0
-- Hard cap on continuous quest travel/interact so a stuck giver cannot eat
-- the whole episode even if patience is reset by marker noise.
local QUEST_BUDGET_SECONDS = 60.0
-- Failed walks get a cooldown, not a session-long blacklist: exhausting a
-- giver we never reached strands every Deathknell turn-in behind a wall.
local QUEST_APPROACH_COOLDOWN = 45.0
-- Questgiver memory. Marker status only exists for units the client can see,
-- so a seat that grinds its way out of town loses every giver at once: no unit
-- row, no marker, nothing to want. Roaming is a random walk and does not come
-- back. Remembering where givers stood — earned purely from having stood there
-- — is what lets a finished objective be walked back to.
local HUB_ARRIVE_YARDS = 25.0
local HUB_BUDGET_SECONDS = 120.0
-- Long enough that a failed walk does not immediately retry the same hub.
local HUB_COOLDOWN_SECONDS = 240.0
-- A reward that cannot be granted (full bags) is refused server-side and the
-- panel simply re-opens, so the press can never succeed. Give a real turn-in
-- a few frames of grace, then stop paying for it.
local REWARD_COMPLETE_ATTEMPTS = 12
-- Stop close enough that /interact can open the panel (default nav stop is wider).
local QUEST_INTERACT_STOP = 3.5
-- Inside this range /interact needs no route; beyond it a giver the route
-- engine cannot serve (navmesh gaps around town are real, ticket 0048) is
-- approached with a local-steer leg instead of stalling on "unavailable".
local QUEST_WALK_FALLBACK_YARDS = 8.0
-- Do not walk to *new* quests until we have a kill's worth of level progress.
local QUEST_TRAVEL_MIN_LEVEL = 2

-- Looting. The lua-bot boundary has no loot verb and the view carries no loot
-- state, so this reaches the loot pipeline through the two surfaces it does
-- have: `/interact` on a lootable corpse, which the client lowers to
-- ClientActionLootTarget (client_state/target.nim
-- defaultInteractionActionKindForUnitObject), and the stock LootFrame slot
-- buttons, which arrive as presented ui_nodes referenced "loot-slot:<guid>:<n>"
-- and "loot-money:<guid>" (ui/loot_frame.nim). Only one loot window can be
-- open, so the prefix is enough identity — the guid in the reference is a
-- uint64 that Lua would see as a negative int64, and must never be compared.
-- Wedge escape. Every Deathknell questgiver stands inside the church, and a
-- seat that walks in there reports nav_progress "following" while displacing
-- zero yards for minutes: a roam leg is a straight line ROAM_YARDS long, which
-- from inside a WMO points through a wall, and the route engine keeps happily
-- re-planning a route it cannot walk. Upstream's own answer to "holding
-- forward and grinding a wall" is the slide/jump reflex, but it only arms for
-- water goals and `navigation_mode = "local_steer"` legs (pilot.nim), never for
-- a plain routed navigate. So the escape leg asks for local_steer explicitly:
-- short, bearing-only, jump allowed, rotating a new bearing each attempt.
-- A chat sequence takes two or three frames end to end; a box still open a
-- few seconds later was abandoned mid-command and will never close itself.
local CHAT_STUCK_SECONDS = 4.0
local UNSTICK_STILL_SECONDS = 14.0
-- Wall-clock alone is not evidence: decide runs at simulation cadence, so a
-- wedge is only real when many consecutive frames also saw no displacement.
local UNSTICK_STILL_FRAMES = 40
local UNSTICK_YARDS = 2.0
local UNSTICK_LEG_YARDS = 22.0
local UNSTICK_SECONDS = 6.0
-- One compass. A church/WMO clip that returns the same pose on every
-- local_steer bearing is not a wall the next heading will beat; spinning
-- it forever owns decide and the seat never grinds again.
local UNSTICK_BEARINGS = 8

local LOOT_PREFIX_SLOT = "loot-slot:"
local LOOT_PREFIX_MONEY = "loot-money:"
local LOOT_STOP = 3.0
-- A corpse that never opens is not worth more than the next pull. Plenty of
-- low-level kills leave nothing, and a non-lootable corpse answers /interact
-- with a plain target select, so this budget is paid on every empty kill.
local LOOT_OPEN_SECONDS = 6.0
-- The take is asynchronous: the button goes disabled while the slot is pending,
-- so an empty frame is not proof the corpse is empty.
local LOOT_EMPTY_FRAMES = 8

-- Per-class ability on the attack intent, highest rank first. Casters open
-- with this; melee uses it as an in-melee filler after the host closes.
local NUKES_BY_CLASS = {
  [11] = { 5177, 5176 }, -- druid: Wrath r2/r1
  [7] = { 529, 403 },    -- shaman: Lightning Bolt r2/r1
  [9] = { 695, 686 },    -- warlock: Shadow Bolt r2/r1
  [5] = { 591, 585 },    -- priest: Smite r2/r1
  [8] = { 2136, 145, 143, 133 }, -- mage: Fire Blast r1, Fireball r3/r2/r1
  [1] = { 285, 284, 78 },   -- warrior: Heroic Strike r3/r2/r1
  [4] = { 1758, 1757, 1752 }, -- rogue: Sinister Strike r3/r2/r1
}

-- Gap closer, not a filler: 0 rage, out of combat, 8-25 yd. Bypasses the
-- mana/rage floor so a fresh warrior pull is a Charge, not a walk.
local CHARGE_BY_CLASS = {
  [1] = { 11578, 6178, 100 }, -- warrior: Charge r3/r2/r1
}
local CHARGE_MIN_YARDS = 8.0
local CHARGE_MAX_YARDS = 25.0

-- Buff once per life: cheap, and a level 1 character has almost no stats.
-- Tables are highest rank first; first usable on the action bar wins.
local BUFFS_BY_CLASS = {
  [11] = { 1126 },       -- druid: Mark of the Wild
  [9] = { 696, 687 },    -- warlock: Demon Skin r2/r1
  [8] = { 7302, 168 },   -- mage: Ice Armor r1, Frost Armor r1
  [1] = { 6673 },        -- warrior: Battle Shout r1
}

-- Casters stand at spell range. Fireball (35yd) cannot start while the
-- host is walking to ENGAGE_YARDS (movement_inhibits_cast_start), so a
-- 4yd stop turns a mage into a staff-swinging corpse.
local CASTER_STOP_YARDS = 22.0
local CASTER_CLASS = {
  [5] = true, [7] = true, [8] = true, [9] = true, [11] = true,
}

local ENGAGE_YARDS = 4.0
local SEARCH_YARDS = 40.0        -- a starting field is sparser than a road
-- Item-drop quests (The Damned, A New Plague) report entry=0. Their
-- droppers sit past a starting-field SEARCH, so the seat never leaves
-- leftover trash (Kamish, 376 0/6 0/6 while grinding churchyard zombies).
local OBJECTIVE_SEARCH_YARDS = 100.0
-- Name fragment of the creature that drops the quest item. entry is 0 on
-- those objective rows, so the creature-id match never fires.
local ITEM_DROPPER = {
  [3265] = "Scavenger", -- Scavenger Paws (376)
  [3264] = "Duskbat",   -- Duskbat Wings (376)
  [2858] = "Darkhound", -- Darkhound Blood (367)
  [2834] = "Gnoll",     -- Embalming Ichor (Rot Hide)
}
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
-- When combat interrupted a pursuit (nil = not paused). Fights en route must
-- not count against the budget: a turn-in 20yd short of Sarvis was abandoned
-- because two zombies jumped the courier (2026-08-16, live).
local questPausedAt = nil
-- Corpse we still owe a loot to, and how the attempt is going.
local lootGuid = nil
local lootSince = nil
local lootOpened = false
local lootEmptyFrames = 0
-- Corpses we already armed once. combat_kill_events replays the retained
-- combat-log ring every frame, so without this the newest death line re-arms
-- the same corpse each tick, resets the loot clock, and pins the seat on a
-- loot that will never finish.
local lootSeen = {}
local lootSeenCount = 0
-- Wedge watchdog: where we were, and since when, while out of combat.
-- Where we have seen questgivers: guid -> { x, y, z, map_id, name }.
local questHubs = {}
-- Either a unit guid (a giver we have SEEN) or the string key "quest:<id>"
-- (a generated turn-in position we have never laid eyes on).
local hubGuid = nil
local hubSince = nil
local hubCooldown = {}
-- Consecutive Complete presses on the same reward panel that did not close it.
local rewardAttempts = 0
local rewardQuestId = nil
local rewardNpcGuid = nil
-- After a refused reward (live: "Inventory is full"), consume a use-item
-- stack from the action bar so the next Complete can store the reward.
-- The lua view does not project bags, so the action bar is the only lever.
local needBagSlot = false
local bagUseSettleUntil = nil
local bagBlockedNpc = nil
local bagBlockedQuest = nil
local BAG_USE_SETTLE_SECONDS = 1.2

-- Generated quest-giver world positions, lazily loaded and injectable.
--
-- questHubs above is memory: it only ever holds givers this seat has stood
-- next to, and it dies on every reload. A seat that grinds a field with no
-- NPC in it therefore has nothing to walk back to, and a completed quest sits
-- unbanked forever (Kargalgan, quest 364, 2026-08-16). The generated table is
-- the missing half: quest id -> where the starter and ender actually stand.
--
-- Fair play: this is the same class of knowledge as RoadData and QuestData —
-- static world data a player reads off a quest guide before logging in, not
-- server state the client was never told. The gen_* precedent in AGENTS.md
-- sanctions host-side generators; the no-Python rule is about the bot
-- RUNTIME, and what ships here is a plain Lua table.
--
-- Runtime require path quirk: modules under lua/data load as "data.<name>"
-- (same as home.lua's road_data). A deploy missing the file must still play,
-- so the require is guarded — no data simply means the old seen-givers-only
-- behavior.
local questHubData = nil
local questHubLoaded = false

-- nil restores the generated file; a table (including {}) replaces it. Tests
-- inject this way so they never depend on a generated artifact.
function M.set_quest_hubs(data)
  questHubData = data
  questHubLoaded = data ~= nil
end

local function quest_hub_data()
  if not questHubLoaded then
    questHubLoaded = true
    local ok, data = pcall(require, "data.bot_quest_hubs")
    if ok and type(data) == "table" then
      questHubData = data
      local n = 0
      for _ in pairs(data) do n = n + 1 end
      wow.log("quest hub data loaded: " .. n .. " quests")
    else
      questHubData = nil
      wow.log("quest hub data unavailable: " .. tostring(data))
    end
  end
  return questHubData
end
-- TEMP (0065): last emit of the accept-leg telemetry probes.
local questProbeAt = nil
local travelProbeAt = nil
-- When the chat edit box first became visible (nil = closed).
local chatOpenSince = nil
local stillAnchor = nil
local stillSince = nil
local stillFrames = 0
local unstickUntil = nil
local unstickBearing = 0
local unstickTried = 0

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
local function huntable(view, unit, freshPull, reach)
  if not unit.player_can_attack then return false end
  if unit.death_known and unit.is_dead then return false end
  if unit.health_known and unit.health <= 0 then return false end
  if unit.creature_rank_known and unit.creature_rank ~= 0 then return false end
  if unit.creature_type_known and unit.creature_type == 8 then return false end
  if unit.is_tapped and not unit.tapped_by_player then return false end
  if unit.summoner_guid and unit.summoner_guid ~= 0 then return false end
  if unit_distance(unit) > (reach or SEARCH_YARDS) then return false end
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
    if objective.complete then
    elseif objective.entry ~= 0 and objective.entry == unit.entry then
      return true
    elseif (objective.item_id or 0) ~= 0 then
      local needle = ITEM_DROPPER[objective.item_id]
      local name = unit.name or ""
      if needle and name:find(needle, 1, true) then
        return true
      end
    end
  end
  return false
end

local function pick_target(view, freshPull)
  local best, bestScore = nil, nil
  local credit, creditScore = nil, nil
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    local pays = QUESTS and credits_objective(view, unit)
    local reach = pays and OBJECTIVE_SEARCH_YARDS or SEARCH_YARDS
    if huntable(view, unit, freshPull, reach) then
      local score = unit_distance(unit)
      if pays then
        if not creditScore or score < creditScore then
          credit, creditScore = unit, score
        end
      elseif not bestScore or score < bestScore then
        best, bestScore = unit, score
      end
    end
  end
  -- A dropper on an unfinished item/kill row outranks leftover trash even
  -- when the trash is in melee. The old 25yd bonus still lost to a 1yd
  -- zombie against an 80yd scavenger.
  return credit or best
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

local function pick_charge(view, target)
  if view.in_combat then return nil end
  local prio = CHARGE_BY_CLASS[view.class_id or 0]
  if not prio or not target then return nil end
  local dist = unit_distance(target)
  for i = 1, #prio do
    local id = prio[i]
    for j = 1, #(view.action_buttons or {}) do
      local button = view.action_buttons[j]
      if button.spell_id == id then
        if button.usable_known and not button.usable then break end
        if button.not_enough_mana then break end
        if button.in_range_known and not button.in_range then break end
        local rmin = button.range_min or CHARGE_MIN_YARDS
        local rmax = button.range_max or CHARGE_MAX_YARDS
        if dist >= rmin and dist <= rmax then return id end
        break
      end
    end
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

-- A reward panel that offers a choice will not take a bare /questreward: the
-- client answers "Choose a quest reward first" and sends nothing, so the panel
-- stays open forever (quests/updates_and_commands.nim questRewardCommand). The
-- choice buttons are presented controls, so select one first and let the plain
-- verb read frame.selected_choice. Nearly every Deathknell reward quest has a
-- choice, which is why only choice-free quests ever turned in.
local function reward_choice_reference(view)
  local frame = view.quest_frame or {}
  local choices = frame.choice_items or {}
  if #choices == 0 then return nil end
  local selected = frame.selected_choice or 0
  if selected >= 1 and selected <= #choices then return nil end
  -- Choice buttons are QuestRewardItem1..N in choice order (ui/quest_frame.nim
  -- draws reward.choiceItems from sourceStart 1); fixed rewards start after.
  for index = 1, #choices do
    local reference = control_for(view, "quest-reward:" .. index)
    if reference then return reference end
  end
  return nil
end

local function use_item_button(view)
  for i = 1, #(view.action_buttons or {}) do
    local button = view.action_buttons[i]
    local slot = button.slot or 0
    if button.kind == "use-item" and slot >= 1 and slot <= 12 and
        (button.spell_id or 0) ~= 8690 then
      return button
    end
  end
  return nil
end

local function bag_slot_cleared()
  if bagBlockedNpc then
    exhausted[bagBlockedNpc] = nil
    hubCooldown[bagBlockedNpc] = nil
  end
  if bagBlockedQuest and bagBlockedQuest ~= 0 then
    hubCooldown["quest:" .. bagBlockedQuest] = nil
  end
  needBagSlot = false
  bagUseSettleUntil = nil
  bagBlockedNpc = nil
  bagBlockedQuest = nil
end

-- Reward Complete that does not close the panel is almost always a full bag
-- (Legia, quest 376, "The Damned failed: Inventory is full."). Consume one
-- action-bar use-item stack to free a slot, then un-exhaust the giver.
local function bag_slot_step(view)
  if not needBagSlot then return nil end
  if dialog_open(view) then
    local frame = view.quest_frame or {}
    local q = frame.quest_id or 0
    if frame.open and frame.panel == "reward" and
        bagBlockedQuest and q ~= 0 and q ~= bagBlockedQuest then
      bag_slot_cleared()
      return nil
    end
    return { kind = "ui_press", control = "QuestFrameCancelButton",
      reason = "reward_blocked" }
  end
  if view.eating or view.drinking then
    return { kind = "hold", reason = "bag_slot_consume" }
  end
  local button = use_item_button(view)
  if not button then
    bag_slot_cleared()
    return nil
  end
  local now = wow.time()
  if bagUseSettleUntil and now < bagUseSettleUntil then
    return { kind = "hold", reason = "bag_slot_settle" }
  end
  bagUseSettleUntil = now + BAG_USE_SETTLE_SECONDS
  return {
    kind = "ui_press",
    control = "ActionButton" .. tostring(button.slot),
    reason = "bag_slot_use",
  }
end

-- Answer whatever dialog is open, then (optionally) look for a giver to walk to.
-- The two travel gates are separate on purpose: a turn-in is finished work
-- waiting to be banked (XP, log space, the chain successor), so it outranks
-- the next pull, while walking off to a *new* accept is the trade the
-- 2026-08-10 A/B lost on and keeps its "nothing huntable nearby" gate.
-- Collapsing them is what stranded objective-complete quests: every Deathknell
-- giver has mobs inside the 40yd hunt radius, so the seat could never walk back.
--
-- allowScout adds a third, lowest rank: friendly NPCs with NO marker. The
-- stock client paints ! markers by querying giver status for every unit in
-- view; the nim runtime never sends that query, so a bot's world is
-- markerless until it opens a dialog (the client synthesizes the marker from
-- the gossip/greeting rows). With an idle log and nothing marked, asking the
-- nearest untried NPC is the only way to find work.
local function quest_step(view, allowTurnInTravel, allowAcceptTravel, allowScout)
  local frame = view.quest_frame or {}
  if not (frame.open and frame.panel == "reward") then
    rewardAttempts, rewardQuestId, rewardNpcGuid = 0, nil, nil
  end
  if frame.open then
    questBudgetSince = nil
    -- Dialog answers go by BUTTON, never by slash command: the /quest*
    -- commands are chat-driven, and a bricked edit box (five clients today,
    -- one of them 3yd from Sarvis with the reward panel open and the choice
    -- already selected) blocks them forever — while ui_press clicks keep
    -- working on the same client. The stock panel buttons are presented
    -- controls (quests/model_and_dialog.nim QuestFramePanelDescriptors).
    if frame.panel == "reward" then
      local choice = reward_choice_reference(view)
      if choice then
        return { kind = "ui_press", reference = choice, reason = "reward_choice" }
      end
      -- Choice buttons are not in every snapshot. Complete without a valid
      -- selection is refused ("You must choose a reward.") and the panel
      -- stays open, so hold until the next frame presents the control.
      local choices = frame.choice_items or {}
      local selected = frame.selected_choice or 0
      local needsChoice = #choices > 0 and not (selected >= 1 and selected <= #choices)
      if needsChoice then
        return { kind = "hold", reason = "reward_choice_wait" }
      end
      local questId = frame.quest_id or 0
      local npcGuid = frame.npc_guid or 0
      if rewardQuestId ~= questId or rewardNpcGuid ~= npcGuid then
        rewardAttempts, rewardQuestId, rewardNpcGuid = 0, questId, npcGuid
      end
      if rewardAttempts >= REWARD_COMPLETE_ATTEMPTS then
        wow.log(string.format(
          "reward refused %d times for quest %s - likely full bags; closing panel and moving on",
          rewardAttempts, tostring(questId)))
        local now = wow.time()
        if npcGuid ~= 0 then
          hubCooldown[npcGuid] = now + HUB_COOLDOWN_SECONDS
        end
        if questId ~= 0 then
          hubCooldown["quest:" .. questId] = now + HUB_COOLDOWN_SECONDS
        end
        if hubGuid == npcGuid or
            (questId ~= 0 and hubGuid == "quest:" .. questId) then
          hubGuid, hubSince = nil, nil
        end
        exhausted[npcGuid] = true
        needBagSlot = true
        bagBlockedNpc = npcGuid
        bagBlockedQuest = questId
        bagUseSettleUntil = nil
        return { kind = "ui_press", control = "QuestFrameCancelButton",
          reason = "reward_blocked" }
      end
      rewardAttempts = rewardAttempts + 1
      return { kind = "ui_press", control = "QuestFrameCompleteQuestButton",
        reason = "turn_in" }
    end
    if frame.panel == "progress" then
      if frame.can_complete then
        return { kind = "ui_press", control = "QuestFrameCompleteButton",
          reason = "complete" }
      end
      return { kind = "ui_press", control = "QuestFrameGoodbyeButton",
        reason = "unfinished" }
    end
    if frame.panel == "details" then
      if #(view.accepted_quests or {}) >= QUEST_LOG_LIMIT then
        return { kind = "ui_press", control = "QuestFrameDeclineButton",
          reason = "log_full" }
      end
      return { kind = "ui_press", control = "QuestFrameAcceptButton",
        reason = "accept" }
    end
    if frame.panel == "greeting" then
      local questId = greeting_row(view)
      local reference = questId and control_for(view, "quest-greeting:" .. questId)
      if reference then
        return { kind = "ui_press", reference = reference, reason = "greeting_row" }
      end
      -- An empty greeting leaves no marker behind, so without this the scout
      -- rank would walk right back to the same NPC forever.
      exhausted[frame.npc_guid or 0] = true
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

  if not allowTurnInTravel and not allowAcceptTravel then
    pursuing, pursuingSince, questBudgetSince = nil, nil, nil
    return nil
  end

  local now = wow.time()
  -- Prefer turn-in (reward) markers over new accepts when ranking givers.
  local best, bestDistance, bestRank = nil, nil, nil
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    local status = marker_status(view, unit.guid)
    local rank = nil
    if MARKER_REWARD[status] and allowTurnInTravel then
      rank = 0
    elseif status == MARKER_AVAILABLE and allowAcceptTravel and
        #(view.accepted_quests or {}) < QUEST_LOG_LIMIT then
      rank = 1
    elseif allowScout and status == 0 and
        unit.player_can_attack_known and not unit.player_can_attack and
        unit.object_kind ~= "player" then
      -- Players are friendly and markerless too, but they have no dialog to
      -- give — the army was scouting its own soldiers. NPCs only.
      -- No log-limit gate here: a full-but-finished log still wants its
      -- unmarked enders found, and the details panel declines on its own.
      rank = 2
    end
    if rank and not exhausted[unit.guid] and
        not (hubCooldown[unit.guid] and now < hubCooldown[unit.guid]) and
        not (unit.death_known and unit.is_dead) then
      local d = unit_distance(unit)
      local maxD = rank == 2 and SCOUT_YARDS or QUESTGIVER_YARDS
      if d <= maxD and
          (not best or rank < bestRank or (rank == bestRank and d < bestDistance)) then
        best, bestDistance, bestRank = unit, d, rank
      end
    end
  end
  -- TEMP probe (0065): what the travel scan concluded. Remove with fix.
  do
    if not travelProbeAt or now - travelProbeAt > 15 then
      travelProbeAt = now
      wow.log(string.format("travel best=%s rank=%s tin=%s acc=%s scout=%s",
        (best and best.name) or "-", tostring(bestRank),
        tostring(allowTurnInTravel), tostring(allowAcceptTravel),
        tostring(allowScout)))
    end
  end
  if best then
    if pursuing ~= best.guid then
      pursuing, pursuingSince = best.guid, now
      questBudgetSince = now
    end
    local timedOut = (questBudgetSince and
        now - questBudgetSince > QUEST_BUDGET_SECONDS) or
      (pursuingSince and now - pursuingSince > QUESTGIVER_PATIENCE)
    if timedOut then
      local closeMsg = (questBudgetSince and
          now - questBudgetSince > QUEST_BUDGET_SECONDS) and
        "quest budget exhausted on " or "gave up on questgiver "
      pursuing, pursuingSince, questBudgetSince = nil, nil, nil
      if bestDistance > QUEST_WALK_FALLBACK_YARDS then
        hubCooldown[best.guid] = now + QUEST_APPROACH_COOLDOWN
        wow.log(string.format("quest approach timed out on %s (%.0fyd)",
          best.name or "?", bestDistance))
      else
        exhausted[best.guid] = true
        wow.log(closeMsg .. (best.name or "?"))
      end
      return nil
    end
    local scouting = bestRank == 2
    wow.set_status((scouting and "scouting " or "questgiver ")
      .. (best.name or "?"))
    -- The interact verb needs the route engine to carry it most of the way;
    -- where routing has no answer, steer at the giver directly and interact
    -- once the last-yards route is trivial.
    local position = best.location and best.location.position
    if position and bestDistance > QUEST_WALK_FALLBACK_YARDS and
        wow.nav_progress().state == "unavailable" then
      return {
        kind = "navigate",
        x = position.x, y = position.y, z = position.z,
        map_id = math.floor((best.location.map_id or 0)),
        stop_distance = QUEST_INTERACT_STOP,
        navigation_mode = "local_steer",
        allow_jump = true,
        reason = scouting and "scout_walk" or "questgiver_walk",
      }
    end
    return {
      kind = "interact",
      guid = best.guid,
      stop_distance = QUEST_INTERACT_STOP,
      route_profile = "prefer_ground",
      reason = scouting and "scout_npc" or "questgiver",
    }
  end
  pursuing, pursuingSince, questBudgetSince = nil, nil, nil
  return nil
end

-- Loot. Item objectives are only satisfied by taking the drop, so a quest run
-- that never loots can accept and kill forever and still never complete
-- A New Plague, The Damned, or Scavenging Deathknell.
local function loot_reference(view, prefix)
  for i = 1, #(view.ui_nodes or {}) do
    local node = view.ui_nodes[i]
    local reference = node.reference_id or ""
    if node.enabled and node.hit_testable and
        reference:sub(1, #prefix) == prefix then
      return reference
    end
  end
  return nil
end

local function unit_by_guid(view, guid)
  for i = 1, #(view.units or {}) do
    if view.units[i].guid == guid then return view.units[i] end
  end
  return nil
end

local function forget_loot()
  lootGuid, lootSince, lootOpened, lootEmptyFrames = nil, nil, false, 0
end

-- Arm the loot attempt from the kill feed rather than from the engaged unit:
-- by the frame the kill event lands, `engaged_unit` has usually already
-- dropped the target (it filters dead units), so keying off it misses most
-- kills. Only our own kills are ours to loot.
local function note_kills(view)
  local player = view.player_guid
  for i = 1, #(view.combat_kill_events or {}) do
    local event = view.combat_kill_events[i]
    local target = event.target_guid or 0
    if target ~= 0 and (player == nil or event.source_guid == player) and
        not lootSeen[target] then
      lootSeen[target] = true
      lootSeenCount = lootSeenCount + 1
      if lootSeenCount > 256 then
        -- The log ring only retains recent lines; a rare one-time re-arm of
        -- a long-gone corpse costs one 6s window, unbounded growth costs more.
        lootSeen, lootSeenCount = { [target] = true }, 1
      end
      lootGuid, lootSince, lootOpened, lootEmptyFrames = target, nil, false, 0
    end
  end
end

local function loot_step(view)
  if not lootGuid then return nil end
  -- An open quest dialog swallows /interact (pilot.nim returns early while a
  -- dialog is ours), so answering the panel first is the only way forward.
  if dialog_open(view) then return nil end
  local now = wow.time()
  if not lootSince then lootSince = now end
  -- Wall-clock cap ahead of the reference branch: a slot that stays enabled
  -- while every take fails (bags full, unique/BoP reject) would otherwise be
  -- pressed forever, with the unstick watchdog disabled by busy.
  if now - lootSince > LOOT_OPEN_SECONDS * 3 then
    forget_loot()
    return nil
  end

  local reference = loot_reference(view, LOOT_PREFIX_SLOT) or
    loot_reference(view, LOOT_PREFIX_MONEY)
  if reference then
    if not lootOpened then wow.log("loot window open: " .. reference) end
    lootOpened, lootEmptyFrames = true, 0
    wow.set_status("looting")
    return { kind = "ui_press", reference = reference, reason = "loot_take" }
  end

  if lootOpened then
    -- A take is asynchronous; the button is disabled while it is pending.
    lootEmptyFrames = lootEmptyFrames + 1
    if lootEmptyFrames < LOOT_EMPTY_FRAMES then
      return { kind = "hold", reason = "loot_settling" }
    end
    forget_loot()
    return nil
  end

  if now - lootSince > LOOT_OPEN_SECONDS then
    local names = {}
    for i = 1, #(view.ui_nodes or {}) do
      local name = tostring(view.ui_nodes[i].source_name)
      if name:find("Loot") then names[#names + 1] = name end
    end
    wow.log(string.format("loot window never opened (nodes=%d loot=%s)",
      #(view.ui_nodes or {}), table.concat(names, "/")))
    forget_loot()
    return nil
  end
  local corpse = unit_by_guid(view, lootGuid)
  if not corpse then
    forget_loot()
    return nil
  end
  -- The client lowers /interact on a lootable corpse to ClientActionLootTarget.
  return {
    kind = "interact",
    guid = lootGuid,
    stop_distance = LOOT_STOP,
    route_profile = "prefer_ground",
    reason = "loot_corpse",
  }
end

-- Returns an escape leg when the seat has stopped displacing out of combat,
-- and nil otherwise. Anchor bookkeeping happens here so decide has one call.
local function unstick_step(view, pos, engaged, busy)
  local now = wow.time()
  local pinned = view.movement_allowed == false or view.rooted
  -- Standing still on purpose is not a wedge: a loot take, an open dialog and
  -- an in-flight chat command all hold position by design, and cancelling them
  -- to "escape" is how the escape reflex started eating its own loot.
  if busy or view.in_combat or engaged or pinned then
    stillAnchor, stillSince, stillFrames = { x = pos.x, y = pos.y }, now, 0
    unstickTried = 0
    if unstickUntil and now >= unstickUntil then unstickUntil = nil end
    return nil
  end
  if not stillAnchor or not stillSince then
    stillAnchor, stillSince, stillFrames = { x = pos.x, y = pos.y }, now, 0
    return nil
  end
  if distance2d(pos.x, pos.y, stillAnchor.x, stillAnchor.y) >= UNSTICK_YARDS then
    stillAnchor, stillSince, stillFrames = { x = pos.x, y = pos.y }, now, 0
    unstickUntil = nil
    unstickTried = 0
    return nil
  end
  stillFrames = stillFrames + 1

  if unstickUntil and now < unstickUntil then
    -- keep the current bearing until the window closes
  elseif now - stillSince > UNSTICK_STILL_SECONDS and
      stillFrames >= UNSTICK_STILL_FRAMES then
    unstickTried = unstickTried + 1
    if unstickTried > UNSTICK_BEARINGS then
      wow.log(string.format(
        "unstick spin gave up at %.1f,%.1f after %d bearings",
        pos.x, pos.y, UNSTICK_BEARINGS))
      unstickTried = 0
      unstickUntil = nil
      stillAnchor, stillSince, stillFrames = { x = pos.x, y = pos.y }, now, 0
      return nil
    end
    unstickBearing = (unstickBearing + 1) % 8
    unstickUntil = now + UNSTICK_SECONDS
    wow.log(string.format(
      "unstick bearing %d at %.1f,%.1f mode=%s moving=%s allowed=%s rooted=%s " ..
      "chat=%s/%q dialog=%s gossip=%s",
      unstickBearing, pos.x, pos.y,
      tostring(view.movement_mode), tostring(view.is_moving),
      tostring(view.movement_allowed), tostring(view.rooted),
      tostring(view.chat_input_visible), tostring(view.chat_input_text or ""),
      tostring((view.quest_frame or {}).open), tostring(view.gossip_open)))
  else
    return nil
  end

  local angle = unstickBearing * math.pi / 4.0
  wow.set_status("unstick")
  return {
    kind = "navigate",
    x = pos.x + math.cos(angle) * UNSTICK_LEG_YARDS,
    y = pos.y + math.sin(angle) * UNSTICK_LEG_YARDS,
    z = pos.z,
    map_id = math.floor(view.location.map_id or 0),
    stop_distance = ENGAGE_YARDS,
    navigation_mode = "local_steer",
    allow_jump = true,
    reason = "unstick",
  }
end

-- Record every giver we can currently see, at the position we see it in.
local function remember_hubs(view)
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    local position = unit.location and unit.location.position
    if position and marker_status(view, unit.guid) ~= 0 then
      questHubs[unit.guid] = {
        x = position.x, y = position.y, z = position.z,
        map_id = math.floor((unit.location.map_id or 0)),
        name = unit.name or "?",
      }
    end
  end
end

-- True when at least one accepted quest is finished and only needs handing
-- in. A single finished counter (376 wings 6/6, paws still 2/6) is field
-- work, not banked work.
local function objective_complete(view)
  local byQuest = {}
  for i = 1, #(view.quest_objectives or {}) do
    local o = view.quest_objectives[i]
    local q = o.quest_id or 0
    local st = byQuest[q]
    if not st then
      st = { all = true }
      byQuest[q] = st
    end
    if not o.complete then st.all = false end
  end
  for _, st in pairs(byQuest) do
    if st.all then return true end
  end
  return false
end

-- The quest id of one accepted-quest row. The view hands these out as tables
-- ({quest_id, title, level, failed} — bots/lua_bot/view.nim); older fixtures
-- pass bare ids, so both are read.
local function accepted_quest_id(entry)
  if type(entry) == "table" then return entry.quest_id end
  if type(entry) == "number" then return entry end
  return nil
end

-- True when THIS quest is finished and only needs handing in: it has
-- objective rows and every one of them is complete. A quest with no objective
-- rows at all (pure talk-to-someone) is not claimed either way — nothing in
-- the view says it is done, so it is left to the ordinary marker path.
local function quest_banked(view, questId)
  local seen = false
  for i = 1, #(view.quest_objectives or {}) do
    local objective = view.quest_objectives[i]
    if objective.quest_id == questId then
      if not objective.complete then return false end
      seen = true
    end
  end
  return seen
end

-- Walk to the GENERATED turn-in of a completed quest. This is the fallback
-- for the case the seen-givers table structurally cannot cover: an ender we
-- have never had in view. Same intent shape, stop distance, budget and
-- cooldown as the remembered-hub leg — only the source of the position
-- differs.
local function generated_hub_step(view, pos, now)
  local data = quest_hub_data()
  if not data then return nil end
  local map = math.floor(view.location.map_id or 0)
  -- Log order: the first banked quest we can actually reach wins, and the
  -- budget/cooldown above retires it to the next one if the walk fails.
  for i = 1, #(view.accepted_quests or {}) do
    local questId = accepted_quest_id(view.accepted_quests[i])
    local hub = questId and data[questId]
    local ender = hub and hub.ender
    if ender and questId and quest_banked(view, questId) then
      local key = "quest:" .. questId
      if math.floor(ender[1] or 0) == map and
          not (hubCooldown[key] and now < hubCooldown[key]) then
        local d = distance2d(pos.x, pos.y, ender[2], ender[3])
        -- Inside QUESTGIVER_YARDS the visible-marker path already owns this.
        if d > QUESTGIVER_YARDS then
          if hubGuid ~= key then hubGuid, hubSince = key, now end
          wow.set_status(string.format("walking to turn-in %s (quest %d)",
            tostring(ender[5] or "?"), questId))
          return {
            kind = "navigate",
            x = ender[2], y = ender[3], z = ender[4],
            map_id = map,
            stop_distance = HUB_ARRIVE_YARDS,
            route_profile = "safe_ground",
            reason = "quest_hub",
          }
        end
      end
    end
  end
  return nil
end

-- Empty log, no remembered giver: walk to the nearest generated starter
-- on this map. Rank-2 scout only covers NPCs already in SCOUT_YARDS, so
-- without this a Deathknell seat grinds the zombie field forever and never
-- reaches Sarvis (Bellion, 2026-08-16, accepted=0, 141yd from the chapel).
local function generated_starter_step(view, pos, now)
  if #(view.accepted_quests or {}) > 0 then return nil end
  local data = quest_hub_data()
  if not data then return nil end
  local map = math.floor(view.location.map_id or 0)
  local done = {}
  for i = 1, #(view.completed_quest_ids or {}) do
    done[view.completed_quest_ids[i]] = true
  end
  for i = 1, #(view.rewarded_quest_ids or {}) do
    done[view.rewarded_quest_ids[i]] = true
  end
  local best, bestD, bestKey, bestName = nil, nil, nil, nil
  for questId, hub in pairs(data) do
    local starter = hub and hub.starter
    if starter and not done[questId] and math.floor(starter[1] or 0) == map then
      local d = distance2d(pos.x, pos.y, starter[2], starter[3])
      if d > HUB_ARRIVE_YARDS and d <= STARTER_HUB_YARDS then
        local key = string.format("start:%.0f:%.0f", starter[2], starter[3])
        if not (hubCooldown[key] and now < hubCooldown[key]) then
          if not bestD or d < bestD then
            best, bestD, bestKey, bestName = starter, d, key, starter[5]
          end
        end
      end
    end
  end
  if not best then return nil end
  if hubGuid ~= bestKey then hubGuid, hubSince = bestKey, now end
  wow.set_status("walking to starter " .. tostring(bestName or "?"))
  return {
    kind = "navigate",
    x = best[2], y = best[3], z = best[4],
    map_id = map,
    stop_distance = HUB_ARRIVE_YARDS,
    route_profile = "safe_ground",
    reason = "quest_hub",
  }
end

-- True when nothing in the log still needs field work: an empty log, or one
-- where every objective is finished. Grinding in that state is wasted XP, so
-- quest travel (and scouting for unmarked givers) outranks the next pull —
-- the same rationale that made turn-in travel unconditional.
local function quest_log_idle(view)
  if #(view.accepted_quests or {}) == 0 then return true end
  for i = 1, #(view.quest_objectives or {}) do
    if not view.quest_objectives[i].complete then return false end
  end
  return true
end

-- Walk back to a remembered giver when there is business to do there and none
-- is in sight: a finished objective to bank, or an empty quest log to fill.
local function hub_step(view, pos)
  local wanted = objective_complete(view) or
    #(view.accepted_quests or {}) == 0
  if not wanted then
    hubGuid, hubSince = nil, nil
    return nil
  end
  local now = wow.time()
  if hubGuid and hubSince and now - hubSince > HUB_BUDGET_SECONDS then
    hubCooldown[hubGuid] = now + HUB_COOLDOWN_SECONDS
    wow.log("gave up walking to hub " ..
      tostring((questHubs[hubGuid] or {}).name or hubGuid))
    hubGuid, hubSince = nil, nil
  end

  local best, bestDistance = nil, nil
  for guid, hub in pairs(questHubs) do
    if hub.map_id == math.floor(view.location.map_id or 0) and
        not (hubCooldown[guid] and now < hubCooldown[guid]) then
      local d = distance2d(pos.x, pos.y, hub.x, hub.y)
      -- Inside QUESTGIVER_YARDS the visible-marker path already owns this.
      if d > QUESTGIVER_YARDS and (not bestDistance or d < bestDistance) then
        best, bestDistance = guid, d
      end
    end
  end
  if not best then
    -- Nothing remembered is reachable. A banked quest still has a known
    -- turn-in in the generated table, even though we have never seen it.
    local generated = generated_hub_step(view, pos, now)
    if generated then return generated end
    generated = generated_starter_step(view, pos, now)
    if generated then return generated end
    hubGuid, hubSince = nil, nil
    return nil
  end
  if hubGuid ~= best then hubGuid, hubSince = best, now end

  local hub = questHubs[best]
  wow.set_status("walking back to " .. hub.name)
  return {
    kind = "navigate",
    x = hub.x, y = hub.y, z = hub.z,
    map_id = hub.map_id,
    stop_distance = HUB_ARRIVE_YARDS,
    route_profile = "safe_ground",
    reason = "quest_hub",
  }
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

function M.reset()
  rewardAttempts = 0
  rewardQuestId = nil
  rewardNpcGuid = nil
  needBagSlot = false
  bagUseSettleUntil = nil
  bagBlockedNpc = nil
  bagBlockedQuest = nil
  exhausted = {}
  hubCooldown = {}
  pursuing, pursuingSince, questBudgetSince, questPausedAt = nil, nil, nil, nil
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

  -- A chat sequence in flight owns the keyboard. The host drives one slash
  -- command over several frames (open the box, type, submit) and only advances
  -- it while the SAME chat-driven intent keeps coming back; switch intent
  -- mid-sequence and the edit box is stranded open, where it eats every
  -- movement key for the rest of the session. That is what froze this seat
  -- solid at the Deathknell church: the questgiver budget expired while
  -- `/interact` was still being typed, decide fell through to roam, and the
  -- character never moved again — nav reported "following" the whole time.
  -- Re-driving any chat command clears it: an empty box gets typed into and
  -- submitted, a box holding a different partial command gets Escape.
  -- Only a *stranded* box is a problem: an in-flight sequence needs its own
  -- intent to come back frame after frame, so flushing on sight would cancel
  -- every command the brain issues (and did, until this was time-gated).
  -- INVARIANT: CHAT_STUCK_SECONDS (4s) must stay under the client's form-cast
  -- chat timeout (ChatCastTimeoutSeconds = 10s) headroom in the OTHER
  -- direction — if any entry ever drives form casts through the edit box,
  -- this flush will kill casts slower than CHAT_STUCK_SECONDS.
  local chatNow = wow.time()
  if QUESTS and view.chat_input_visible then
    if not chatOpenSince then chatOpenSince = chatNow end
    if chatNow - chatOpenSince > CHAT_STUCK_SECONDS and not dialog_open(view) then
      chatOpenSince = chatNow
      wow.set_status("closing chat box")
      return { kind = "quest_cmd", command = "/gossip", reason = "close_chat_box" }
    end
  else
    chatOpenSince = nil
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

  -- A wedged seat cannot grind, quest, or loot; nothing below matters until
  -- it is displacing again.
  if QUESTS then
    local busy = dialog_open(view) or view.chat_input_visible or lootGuid ~= nil
    local unstick = unstick_step(view, pos, engaged, busy)
    if unstick then
      unstick.status = progress_status(view)
      return unstick
    end
  end

  -- The kill is where a lootable corpse is born. (The quest block below never
  -- runs while `engaged` is set, so moving this above it is behaviour-neutral
  -- for the grind-only path.)
  if QUESTS then note_kills(view) end
  if engaged and killed_target(view, engaged.guid) then
    holdsAfterKill = POST_KILL_HOLDS
    return { kind = "hold", reason = "target_died", status = progress_status(view) }
  end

  if QUESTS then
    remember_hubs(view)
    -- TEMP probe (0065): one line every 15s on why the accept leg did or
    -- did not arm. Surfaces in status.json logs + /status. Remove with fix.
    do
      local now = wow.time()
      if not questProbeAt or now - questProbeAt > 15 then
        questProbeAt = now
        local units, markers, availName, availD = 0, 0, nil, nil
        for i = 1, #(view.units or {}) do
          local unit = view.units[i]
          units = units + 1
          local st = marker_status(view, unit.guid)
          if st ~= 0 then markers = markers + 1 end
          if st == MARKER_AVAILABLE then
            local d = unit_distance(unit)
            if not availD or d < availD then
              availName, availD = unit.name or "?", d
            end
          end
        end
        local hunt = pick_target(view, true)
        local hubs = 0
        for _ in pairs(questHubs) do hubs = hubs + 1 end
        local npcs = ""
        local npcCount = 0
        for i = 1, #(view.units or {}) do
          local unit = view.units[i]
          if unit.player_can_attack_known and not unit.player_can_attack and
              not (unit.death_known and unit.is_dead) then
            npcCount = npcCount + 1
            if npcCount <= 3 then
              npcs = npcs .. string.format(" %s@%d",
                unit.name or "?", math.floor(unit_distance(unit)))
            end
          end
        end
        local frame = view.quest_frame or {}
        wow.log(string.format(
          "probe units=%d markers=%d avail=%s@%d hunt=%s accepted=%d hubs=%d npcs=%d%s eng=%s cbt=%s chat=%s/%q dlg=%s/%s gossip=%s",
          units, markers, availName or "-", math.floor(availD or -1),
          (hunt and hunt.name) or "-",
          #(view.accepted_quests or {}), hubs, npcCount, npcs,
          engaged and "y" or "n", view.in_combat and "y" or "n",
          view.chat_input_visible and "y" or "n",
          tostring(view.chat_input_text or ""),
          frame.open and "y" or "n", tostring(frame.panel or "-"),
          view.gossip_open and "y" or "n"))
      end
    end
    local signature = quest_signature(view)
    if signature ~= questSignature then
      -- Our quest state moved, so a giver we gave up on may have new work.
      exhausted = {}
      questSignature = signature
    end
    if not engaged and not view.in_combat then
      -- Combat time was not travel time: shift the pursuit clocks forward by
      -- however long the fight held the quest block hostage.
      if questPausedAt then
        local pause = wow.time() - questPausedAt
        if pursuingSince then pursuingSince = pursuingSince + pause end
        if questBudgetSince then questBudgetSince = questBudgetSince + pause end
        questPausedAt = nil
      end
      -- Loot before anything else: the window is open on the corpse we are
      -- standing on, and a new pull or a walk to a giver abandons it.
      local loot = loot_step(view)
      if loot then
        loot.status = progress_status(view)
        return loot
      end
      local bagStep = bag_slot_step(view)
      if bagStep then
        bagStep.status = progress_status(view)
        return bagStep
      end
      -- Always finish an open dialog (free XP / log space). Walking to a new
      -- accept still yields to a nearby pull — unless the log is idle, when
      -- the next pull is the thing being overvalued; banking a turn-in never
      -- yields. Scouting (rank 2) only ever runs on an idle log.
      local nearbyHunt = pick_target(view, true)
      local idleLog = quest_log_idle(view)
      -- Banked work still walks to turn-in markers (allowTurnInTravel) and
      -- generated hubs. Rank-1 accepts do not: one finished talk-quest must
      -- not pull us onto a new giver while unfinished work has a hunt.
      local allowAccept = (view.level or 1) >= QUEST_TRAVEL_MIN_LEVEL and
        (idleLog or not nearbyHunt)
      local allowScout = allowAccept and idleLog
      local step = quest_step(view, true, allowAccept, allowScout)
      if step then
        step.status = progress_status(view)
        return step
      end
      -- Nothing in sight. If there is business waiting at a giver we have
      -- stood next to before, walking back beats another random roam leg.
      -- Banked work outranks the next pull (the Failure-2 rule), and that
      -- applies to the WALK BACK too: a completed quest in the log arms the
      -- hub return even in a mob field, or 364 sits finished-unbanked until
      -- every other quest drains (Kargalgan, 2026-08-16).
      if idleLog or objective_complete(view) or not nearbyHunt then
        local hub = hub_step(view, pos)
        if hub then
          hub.status = progress_status(view)
          return hub
        end
      end
    elseif pursuing then
      questPausedAt = questPausedAt or wow.time()
    end
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
    local spell = pick_charge(view, target)
    local stop = ENGAGE_YARDS
    if spell then
      stop = CHARGE_MAX_YARDS
    elseif mana >= NUKE_MANA_FLOOR_PCT then
      spell = pick_nuke(view)
      if spell and CASTER_CLASS[view.class_id or 0] then
        stop = CASTER_STOP_YARDS
      end
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
      stop_distance = stop,
      route_profile = "prefer_ground",
      reason = spell and stop == CHARGE_MAX_YARDS and "charge" or "grind",
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

-- Loot machinery, exported for the escort brain: party kills deserve the
-- same corpse handling as solo kills, and sharing the functions keeps ONE
-- loot state machine (lootGuid/lootSeen live here) instead of two arguing.
M.note_kills = note_kills
M.loot_step = loot_step

return M
