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
-- Rank-2 scout is last-yards, questgiver-flagged, and only when no !/? is
-- already visible. Friendly vendors/guards have no quest (Bellion, 2026-08-16).
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
  [8] = {
    10199, 10197, 8413, 8412, 2138, 2137, 2136, -- Fire Blast r7-r1
    25306, 10151, 10150, 10149, 10148, 8402, 8401, 8400, 3140, 145, 143, 133, -- Fireball
    25304, 10181, 10180, 10179, 8408, 8407, 8406, 7322, 837, 205, 116, -- Frostbolt
  },
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
local CLASS_MAGE = 8
local SHOOT_WAND = 5019
local WAND_REPRESS_SECONDS = 3.0
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
-- Staff range is ~5yd. A mage standing there with a Fireball that never
-- lands (LOS through a WMO, facing, a select the death bit missed) is
-- not in a fight. Ignore that guid so pick_target can take the next mob.
local STALE_SWING_SECONDS = 8.0
local STALE_SWING_FRAMES = 8
local STALE_IGNORE_SECONDS = 45.0

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
local wandPressedAt = nil
local wandPressedGuid = nil
-- Questgivers with nothing left for us, forgotten again whenever our quest
-- state changes and they might have something new. "rows" marks a provider
-- left only because dialogRows remembers every offered row unfinished; it
-- lasts exactly as long as that memory (see dialogRows.reopen).
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
-- When the view projects bags, a free slot is read from capacity, not inferred.
local needBagSlot = false
local bagUseSettleUntil = nil
local bagBlockedNpc = nil
local bagBlockedQuest = nil
local BAG_USE_SETTLE_SECONDS = 1.2
-- Free bag slots observed when the reward was refused (nil when the view
-- does not project bag space). More free slots than this means the reward
-- may fit now, whatever freed them.
local bagBlockedFree = nil
-- Presses spent on the current refusal, the last press awaiting its outcome,
-- and items whose press did not reduce the carried count. A use-item button
-- outlives its stack, so pressing it again consumes nothing.
local bagUsePresses = 0
local bagUseLast = nil
local bagUseSpent = {}
local BAG_USE_MAX_PRESSES = 12

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

-- Generated objective areas: quest id -> {level, objectives = {{kind, from,
-- spots = {{map,x,y},...}}, ...}} in the quest guide's objective order. Same
-- class of static guide knowledge as the hub table above. Off unless a brain
-- opts in, so lanes that never call set_objective_travel keep old behavior.
local OBJECTIVE_TRAVEL = false
local objectiveAreaData = nil
local objectiveAreaLoaded = false

function M.set_objective_travel(on)
  OBJECTIVE_TRAVEL = not not on
end

-- nil restores the generated file; a table (including {}) replaces it.
function M.set_objective_areas(data)
  objectiveAreaData = data
  objectiveAreaLoaded = data ~= nil
end

local function objective_area_data()
  if not objectiveAreaLoaded then
    objectiveAreaLoaded = true
    local ok, data = pcall(require, "data.bot_objective_areas")
    if ok and type(data) == "table" then
      objectiveAreaData = data
    else
      objectiveAreaData = nil
      wow.log("objective area data unavailable: " .. tostring(data))
    end
  end
  return objectiveAreaData
end

-- Objective class of a guide objective (has `kind`) or a live row. Live
-- game-object rows carry their entry with the high bit set and never pair.
local function objective_class(t)
  if t.kind then
    if t.kind == "mob" then return "kill" end
    if t.kind == "item" or t.kind == "object" then return "item" end
    return nil
  end
  local entry = t.entry or 0
  if entry ~= 0 then
    return (entry > 0 and entry < 2147483648) and "kill" or nil
  end
  if (t.item_id or 0) ~= 0 then return "item" end
  return nil
end

-- Scoped so the helpers add no main-chunk locals (Lua caps those at 200).
local area_objective
do
-- Typed identity a generated guide objective carries (gen_objective_areas
-- --objective-ids): "entry" for a creature, "object_entry" for a game
-- object, "item_id" for an item. Returns nil when it carries none, false
-- when what it carries is malformed or disagrees with its kind.
local GUIDE_ID_KINDS = {
  entry = { mob = true },
  object_entry = { object = true },
  item_id = { item = true, object = true },
}
local function guide_identity(g)
  local field, id = nil, nil
  for name in pairs(GUIDE_ID_KINDS) do
    if g[name] ~= nil then
      if field then return false end
      field, id = name, g[name]
    end
  end
  if not field then return nil end
  if type(id) ~= "number" or id <= 0 or id ~= math.floor(id) or
      not GUIDE_ID_KINDS[field][g.kind] then
    return false
  end
  return field, id
end

-- Identity pairing: the guide objective carrying the live row's own typed
-- id. Game-object credit rows never pair (as in class pairing). A live id
-- shared by two rows, or matched by zero or two guide objectives, is unknown.
local function area_objective_by_id(rows, index, quest)
  local row = rows[index]
  local field, id
  if objective_class(row) == "kill" then
    field, id = "entry", row.entry
  else
    field, id = "item_id", row.item_id
  end
  for i = 1, #rows do
    if i ~= index and rows[i].quest_id == row.quest_id and
        objective_class(rows[i]) == objective_class(row) and
        ((field == "entry" and rows[i].entry == id) or
         (field == "item_id" and rows[i].item_id == id)) then
      return nil
    end
  end
  local guide, position = nil, nil
  for g = 1, #quest.objectives do
    local gField, gId = guide_identity(quest.objectives[g])
    if gField == field and gId == id then
      if guide then return nil end
      guide, position = quest.objectives[g], g
    end
  end
  if not guide then return nil end
  return guide, quest, position
end

-- The guide objective behind live objective row `index`, its quest-local
-- guide position, and the quest, or nil when the pairing is not certain.
-- Live row order is not the definition order (a credit update can arrive
-- before the definition), so rows never pair by position. When every guide
-- objective of the quest carries its typed id, the row pairs by its own
-- id. A guide carrying ids on some objectives only, or a malformed id,
-- pairs nothing. A guide without ids pairs by class: only the sole live row
-- of its class in its quest pairs with the sole guide objective of that
-- class. Equal counts alone prove nothing.
function area_objective(view, index)
  if not OBJECTIVE_TRAVEL then return nil end
  local data = objective_area_data()
  local rows = view.quest_objectives or {}
  local row = rows[index]
  local quest = row and data and data[row.quest_id]
  if not quest then return nil end
  local class = objective_class(row)
  if not class then return nil end
  local typed, untyped = 0, 0
  for g = 1, #quest.objectives do
    local field = guide_identity(quest.objectives[g])
    if field == false then return nil end
    if field then typed = typed + 1 else untyped = untyped + 1 end
  end
  if typed > 0 then
    if untyped > 0 then return nil end
    return area_objective_by_id(rows, index, quest)
  end
  for i = 1, #rows do
    if i ~= index and rows[i].quest_id == row.quest_id and
        objective_class(rows[i]) == class then
      return nil
    end
  end
  local guide, position = nil, nil
  for g = 1, #quest.objectives do
    if objective_class(quest.objectives[g]) == class then
      if guide then return nil end
      guide, position = quest.objectives[g], g
    end
  end
  if not guide then return nil end
  return guide, quest, position
end
end

-- Field work we can honestly travel for: a kill row, or an item row whose
-- guide names the creatures that drop it. Gathered objects and unpaired rows
-- are left to the old behavior.
local function area_travelable(guide)
  if guide.kind == "mob" then return true end
  return guide.kind == "item" and #(guide.from or {}) > 0
end

local function area_drops_from(guide, name)
  if not guide or guide.kind ~= "item" or not name then return false end
  for i = 1, #(guide.from or {}) do
    if guide.from[i] == name then return true end
  end
  return false
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
local ignoreUntil = {}
local swingGuid = nil
local swingHp = nil
local swingSince = nil
local swingFrames = 0
local swingX, swingY = nil, nil

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

local function ignored(guid)
  if not guid or guid == 0 then return false end
  local deadline = ignoreUntil[guid]
  return deadline ~= nil and wow.time() < deadline
end

local function note_swing(target, pos, now)
  local hp = target.health_known and target.health or nil
  local same = swingGuid == target.guid and swingHp == hp
  local still = swingX and
    distance2d(pos.x, pos.y, swingX, swingY) < UNSTICK_YARDS
  if same and still then
    swingFrames = swingFrames + 1
    if swingSince and now - swingSince >= STALE_SWING_SECONDS and
        swingFrames >= STALE_SWING_FRAMES then
      ignoreUntil[target.guid] = now + STALE_IGNORE_SECONDS
      swingGuid, swingHp, swingSince, swingX, swingY = nil, nil, nil, nil, nil
      swingFrames = 0
      return true
    end
    return false
  end
  swingGuid, swingHp, swingSince = target.guid, hp, now
  swingX, swingY = pos.x, pos.y
  swingFrames = 1
  return false
end

-- Mirrors upstream's actionable-target rule: the mobs that are safe to fight
-- and actually pay us.
local function huntable(view, unit, freshPull, reach)
  if ignored(unit.guid) then return false end
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
  if guid == 0 or ignored(guid) then return nil end
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    if unit.guid == guid and not (unit.death_known and unit.is_dead) then
      return unit
    end
  end
  return nil
end

-- A live attackable unit whose current target is known to be this seat or
-- its pet. A retained target GUID without target_guid_known is not proof.
local function targeted_by_hostile(view)
  local me = view.player_guid or 0
  local pet = view.pet and view.pet.guid or 0
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    local target = unit.target_guid or 0
    if unit.target_guid_known == true and target ~= 0 and
        (target == me or target == pet) and unit.player_can_attack == true and
        not (unit.death_known and unit.is_dead) then
      return true
    end
  end
  return false
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
      if area_drops_from(area_objective(view, i), unit.name) then
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

local function button_for(view, spellId)
  for i = 1, #(view.action_buttons or {}) do
    local button = view.action_buttons[i]
    if button.spell_id == spellId then return button end
  end
  return nil
end

local function nuke_affordable(view)
  local prio = NUKES_BY_CLASS[view.class_id or 0]
  if not prio then return nil end
  for i = 1, #prio do
    local button = button_for(view, prio[i])
    if button and not button.not_enough_mana then return prio[i] end
  end
  return nil
end

local function pick_wand(view, target)
  local button = button_for(view, SHOOT_WAND)
  if not button then return nil, false end
  if button.usable_known and not button.usable and not button.active then
    return nil, false
  end
  if button.not_enough_mana then return nil, false end
  local now = wow.time()
  local guid = target and target.guid
  local justPressed = wandPressedAt ~= nil and guid ~= nil and
    wandPressedGuid == guid and (now - wandPressedAt) < WAND_REPRESS_SECONDS
  if button.active or justPressed then return nil, true end
  wandPressedAt, wandPressedGuid = now, guid
  return SHOOT_WAND, true
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

local function has_service(unit, name)
  for i = 1, #(unit.services or {}) do
    if unit.services[i] == name then return true end
  end
  return false
end

local function is_questgiver(unit)
  if not unit then return false end
  if unit.is_questgiver then return true end
  return has_service(unit, "questgiver")
end

local function marked_giver_visible(view)
  for i = 1, #(view.units or {}) do
    local status = marker_status(view, view.units[i].guid)
    if status == MARKER_AVAILABLE or MARKER_REWARD[status] then
      return true
    end
  end
  return false
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

-- Quests whose objectives are done while still in the log.
local function ready_to_turn_in(view)
  local ready = {}
  for i = 1, #(view.completed_quest_ids or {}) do
    ready[view.completed_quest_ids[i]] = true
  end
  return ready
end

-- Quest ids a new accept could actually take: the log has room, and the
-- client reported both its log and its completion facts. Without those facts
-- an active row might still be a turn-in, so nil keeps the old order.
local function new_quest_room(view)
  local accepted = view.accepted_quests
  if not accepted or not view.completed_quest_ids or
      #accepted >= QUEST_LOG_LIMIT then
    return nil
  end
  local inLog = {}
  for i = 1, #accepted do inLog[accepted[i].quest_id] = true end
  return inLog
end

-- Active rows a provider showed unfinished (progress panel, Complete not
-- offered), so the next visit tries the rows after them. One entry per
-- provider, dropped whenever the quest log, objective counts, completion or
-- reward facts or that provider's offered rows change, and after
-- HUB_COOLDOWN_SECONDS regardless, so a quest that became ready is asked again.
-- `pick` is the row last pressed at a provider with that provider's
-- offered-row key. Row selection lives in this table too: the module is at
-- Lua's 200-local limit.
local dialogRows = { LIMIT = 8, by_npc = {}, count = 0, pick = nil }

function dialogRows.state_key(view)
  local parts = {}
  for i = 1, #(view.accepted_quests or {}) do
    local quest = view.accepted_quests[i]
    parts[#parts + 1] = string.format("a%d%s", quest.quest_id or 0,
      quest.failed and "f" or "")
  end
  for i = 1, #(view.quest_objectives or {}) do
    local o = view.quest_objectives[i]
    parts[#parts + 1] = string.format("o%d.%d=%d%s", o.quest_id or 0,
      o.entry or 0, o.current or 0, o.complete and "c" or "")
  end
  for i = 1, #(view.completed_quest_ids or {}) do
    parts[#parts + 1] = "c" .. tostring(view.completed_quest_ids[i])
  end
  for i = 1, #(view.rewarded_quest_ids or {}) do
    parts[#parts + 1] = "r" .. tostring(view.rewarded_quest_ids[i])
  end
  return table.concat(parts, ",")
end

function dialogRows.greeting_key(rows)
  local parts = {}
  for i = 1, #rows do
    parts[i] = tostring(rows[i].quest_id) .. (rows[i].active and "a" or "n")
  end
  return table.concat(parts, ",")
end

function dialogRows.gossip_key(offers, guid)
  local parts = {}
  for i = 1, #offers do
    if offers[i].questgiver_guid == guid then
      parts[#parts + 1] = tostring(offers[i].quest_id)
    end
  end
  return table.concat(parts, ",")
end

function dialogRows.forget(guid)
  if dialogRows.by_npc[guid] then
    dialogRows.by_npc[guid] = nil
    dialogRows.count = dialogRows.count - 1
  end
end

-- Still-valid entry for this provider, or nil. `rowsKey` is the offered rows
-- now on screen; nil when no row list is visible (progress panel).
function dialogRows.entry(view, guid, rowsKey)
  local entry = dialogRows.by_npc[guid]
  if not entry then return nil end
  if entry.state ~= dialogRows.state_key(view) or wow.time() >= entry.expires or
      (rowsKey and entry.rows and entry.rows ~= rowsKey) then
    dialogRows.forget(guid)
    return nil
  end
  return entry
end

function dialogRows.unfinished(view, guid, rowsKey)
  local entry = guid ~= 0 and dialogRows.entry(view, guid, rowsKey)
  return entry and entry.quests or {}
end

function dialogRows.remember(view, guid, questId)
  if guid == 0 or questId == 0 then return end
  local entry = dialogRows.entry(view, guid, nil)
  if not entry then
    if dialogRows.count >= dialogRows.LIMIT then
      dialogRows.by_npc, dialogRows.count = {}, 0
    end
    entry = {
      state = dialogRows.state_key(view),
      rows = dialogRows.pick and dialogRows.pick.npc == guid and dialogRows.pick.rows or nil,
      expires = wow.time() + HUB_COOLDOWN_SECONDS,
      quests = {},
    }
    dialogRows.by_npc[guid] = entry
    dialogRows.count = dialogRows.count + 1
  end
  if not entry.quests[questId] then
    entry.quests[questId] = true
    wow.log(string.format("quest dialog: %s unfinished at %s; next visit tries other rows",
      tostring(questId), tostring(guid)))
  end
end

-- Reopen providers left as "rows" whose remembered rows no longer hold:
-- changed quest facts or HUB_COOLDOWN_SECONDS elapsed. Each lapse allows one
-- more visit; nothing here says any row became ready.
function dialogRows.reopen(view)
  for guid, why in pairs(exhausted) do
    if why == "rows" and not dialogRows.entry(view, guid, nil) then
      exhausted[guid] = nil
    end
  end
end

-- How to mark a provider whose offered rows yield nothing to press: "rows"
-- while the memory of its current rows stands behind that, else for good.
function dialogRows.exhaustion(view, guid, rowsKey)
  if rowsKey ~= "" and guid ~= 0 and dialogRows.entry(view, guid, rowsKey) then
    return "rows"
  end
  return true
end

function dialogRows.greeting_row(view)
  local rows = view.quest_frame and view.quest_frame.greeting_rows or {}
  -- A turn-in is worth more than a new quest, so answer active rows first.
  -- Active also covers unfinished quests; a row known ready to turn in goes
  -- ahead of them, or an earlier unfinished row is reopened forever.
  local ready = ready_to_turn_in(view)
  for i = 1, #rows do
    local questId = rows[i].quest_id
    if rows[i].active and ready[questId] and
        control_for(view, "quest-greeting:" .. questId) then
      return questId
    end
  end
  -- Reopening a known-unfinished quest only says goodbye again, so a new
  -- quest offered beside it is taken first.
  local inLog = new_quest_room(view)
  if inLog then
    for i = 1, #rows do
      local questId = rows[i].quest_id
      if not rows[i].active and not inLog[questId] and
          control_for(view, "quest-greeting:" .. questId) then
        return questId
      end
    end
  end
  -- Completion facts only ever name quests known ready; a quest without
  -- objective rows can be ready and still be missing there. Probe each
  -- active row in turn, skipping ones this provider just showed unfinished,
  -- and leave once every offered active row has said goodbye.
  local probed = dialogRows.unfinished(view, (view.quest_frame or {}).npc_guid or 0,
    dialogRows.greeting_key(rows))
  local anyActive = false
  for i = 1, #rows do
    local questId = rows[i].quest_id
    if rows[i].active then
      anyActive = true
      if not probed[questId] and
          control_for(view, "quest-greeting:" .. questId) then
        return questId
      end
    end
  end
  if anyActive then return nil end
  if rows[1] then return rows[1].quest_id end
  return nil
end

function dialogRows.gossip_row(view)
  local offers = view.quest_offers or {}
  local guid = view.gossip_guid or 0
  local ready = ready_to_turn_in(view)
  for i = 1, #offers do
    local questId = offers[i].quest_id
    if offers[i].questgiver_guid == guid and ready[questId] and
        control_for(view, "gossip-quest:" .. questId) then
      return questId
    end
  end
  local inLog = new_quest_room(view)
  if inLog then
    for i = 1, #offers do
      local questId = offers[i].quest_id
      if offers[i].questgiver_guid == guid and not inLog[questId] and
          control_for(view, "gossip-quest:" .. questId) then
        return questId
      end
    end
  end
  local probed = dialogRows.unfinished(view, guid, dialogRows.gossip_key(offers, guid))
  for i = 1, #offers do
    local questId = offers[i].quest_id
    if offers[i].questgiver_guid == guid and not probed[questId] and
        control_for(view, "gossip-quest:" .. questId) then
      return questId
    end
  end
  return nil
end

local function dialog_open(view)
  local frame = view.quest_frame or {}
  if frame.open then return true end
  if view.gossip_open then return true end
  if view.merchant_open then return true end
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

-- Total carried count of an item, or nil when the view projects no bags.
local function carried_count(view, itemId)
  local items = view.inventory_items
  if type(items) ~= "table" or not itemId then return nil end
  local total = 0
  for i = 1, #items do
    if items[i].item_id == itemId then
      total = total + (tonumber(items[i].count) or 1)
    end
  end
  return total
end

local function known_free_slots(view)
  if not view.bag_space_known then return nil end
  return tonumber(view.free_bag_slots)
end

-- The carried use-item with the fewest left frees a slot in the fewest
-- presses; buttons whose stack is known to be gone are skipped.
local function use_item_button(view)
  local best, bestCount = nil, nil
  for i = 1, #(view.action_buttons or {}) do
    local button = view.action_buttons[i]
    local slot = button.slot or 0
    local itemId = button.item_id
    local count = carried_count(view, itemId)
    if button.kind == "use-item" and slot >= 1 and slot <= 12 and
        (button.spell_id or 0) ~= 8690 and
        not (itemId and bagUseSpent[itemId]) and count ~= 0 then
      if not best or (count and (not bestCount or count < bestCount)) then
        best, bestCount = button, count
      end
    end
  end
  return best
end

local function bag_use_reset()
  bagBlockedFree = nil
  bagUsePresses = 0
  bagUseLast = nil
  bagUseSpent = {}
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
  bag_use_reset()
end

-- Nothing on the bar can free a slot. Stop pressing, but keep the giver's
-- cooldown so the seat does other work instead of re-running the refusal.
local function bag_slot_gave_up(reason)
  wow.log(string.format("bags: quest %s reward still blocked (%s); retry after cooldown",
    tostring(bagBlockedQuest), reason))
  needBagSlot = false
  bagUseSettleUntil = nil
  bagBlockedNpc = nil
  bagBlockedQuest = nil
  bag_use_reset()
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
  local free = known_free_slots(view)
  if free and bagBlockedFree and free > bagBlockedFree then
    wow.log(string.format("bags: %d free slot(s), refused at %d; retrying quest %s turn-in",
      free, bagBlockedFree, tostring(bagBlockedQuest)))
    bag_slot_cleared()
    return nil
  end
  local button = use_item_button(view)
  if not button then
    -- Without projected bags, a vanished button is the only sign its stack
    -- (and so a slot) is gone. With projected bags, capacity decides above.
    if free and bagBlockedFree then
      bag_slot_gave_up("no consumable left to free a slot")
    else
      bag_slot_cleared()
    end
    return nil
  end
  local now = wow.time()
  if bagUseSettleUntil and now < bagUseSettleUntil then
    return { kind = "hold", reason = "bag_slot_settle" }
  end
  if bagUseLast then
    local count = carried_count(view, bagUseLast.item_id)
    if count and bagUseLast.count and count >= bagUseLast.count then
      bagUseSpent[bagUseLast.item_id] = true
      button = use_item_button(view)
    end
    bagUseLast = nil
  end
  if not button then
    bag_slot_gave_up("pressing the consumable freed nothing")
    return nil
  end
  if bagUsePresses >= BAG_USE_MAX_PRESSES then
    bag_slot_gave_up("consumable press budget spent")
    return nil
  end
  bagUsePresses = bagUsePresses + 1
  bagUseLast = { item_id = button.item_id,
    count = carried_count(view, button.item_id) }
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
        bag_use_reset()
        bagBlockedFree = known_free_slots(view)
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
      local npcGuid = frame.npc_guid or 0
      local questId = frame.quest_id or 0
      if dialogRows.pick and (npcGuid == 0 or npcGuid == dialogRows.pick.npc) then
        if npcGuid == 0 then npcGuid = dialogRows.pick.npc end
        if questId == 0 then questId = dialogRows.pick.quest end
      end
      dialogRows.remember(view, npcGuid, questId)
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
      local questId = dialogRows.greeting_row(view)
      local reference = questId and control_for(view, "quest-greeting:" .. questId)
      if reference then
        dialogRows.pick = { npc = frame.npc_guid or 0, quest = questId,
          rows = dialogRows.greeting_key(frame.greeting_rows or {}) }
        return { kind = "ui_press", reference = reference, reason = "greeting_row" }
      end
      -- An empty greeting leaves no marker behind, so without this the scout
      -- rank would walk right back to the same NPC forever.
      exhausted[frame.npc_guid or 0] = dialogRows.exhaustion(view,
        frame.npc_guid or 0, dialogRows.greeting_key(frame.greeting_rows or {}))
      return { kind = "ui_press", control = "QuestFrameGreetingGoodbyeButton",
        reason = "nothing_offered" }
    end
  end
  if view.gossip_open then
    questBudgetSince = nil
    local questId = dialogRows.gossip_row(view)
    local reference = questId and control_for(view, "gossip-quest:" .. questId)
    if reference then
      local guid = view.gossip_guid or 0
      dialogRows.pick = { npc = guid, quest = questId,
        rows = dialogRows.gossip_key(view.quest_offers or {}, guid) }
      return { kind = "ui_press", reference = reference, reason = "gossip_row" }
    end
    exhausted[view.gossip_guid or 0] = dialogRows.exhaustion(view,
      view.gossip_guid or 0,
      dialogRows.gossip_key(view.quest_offers or {}, view.gossip_guid or 0))
    return { kind = "ui_press", control = "GossipFrameGreetingGoodbyeButton",
      reason = "gossip_done" }
  end
  if view.merchant_open then
    questBudgetSince = nil
    exhausted[view.merchant_guid or 0] = true
    return { kind = "ui_press", control = "MerchantFrameCloseButton",
      reason = "merchant_not_quest" }
  end

  if not allowTurnInTravel and not allowAcceptTravel then
    pursuing, pursuingSince, questBudgetSince = nil, nil, nil
    return nil
  end

  local now = wow.time()
  -- Prefer turn-in (reward) markers over new accepts when ranking givers.
  -- Scout is the markerless fallback only: a visible !/? means we already
  -- have work, so do not walk Deathguards / vendors (Bellion, 2026-08-16).
  local allowUnmarked = allowScout and not marked_giver_visible(view)
  dialogRows.reopen(view)
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
    elseif allowUnmarked and status == 0 and
        unit.player_can_attack_known and not unit.player_can_attack and
        unit.object_kind ~= "player" and is_questgiver(unit) then
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
-- An accepted quest whose requirement rows ask for no kill, object or item
-- ("Speak to Dark Cleric Beryl in Brill") is finished the moment it is
-- accepted; only the walk to its ender remains. Such quests publish no
-- objective rows (kill and item quests always do), so without this they are
-- never banked and the turn-in walk never fires (Metus, L9 in gray
-- Deathknell holding 5651). The Lua view carries no requirement rows, so
-- the absence of objective rows is the live signal; requirement rows, when
-- a host provides them, must also be empty.
local function talk_only(view, entry)
  if type(entry) ~= "table" or entry.failed then return false end
  -- The client fills in the quest level and its objective rows only once the
  -- quest definition arrives; level 0 (after a login or reconnect) means the
  -- requirements are still unknown, not empty.
  if (tonumber(entry.level) or 0) <= 0 then return false end
  local id = entry.quest_id
  for i = 1, #(view.quest_objectives or {}) do
    if view.quest_objectives[i].quest_id == id then return false end
  end
  if type(entry.requirements) ~= "table" then return id ~= nil end
  for i = 1, #entry.requirements do
    local r = entry.requirements[i]
    if (tonumber(r.object_count) or 0) ~= 0 or (tonumber(r.item_count) or 0) ~= 0 then
      return false
    end
  end
  return true
end

local function quest_banked(view, questId)
  local seen = false
  for i = 1, #(view.quest_objectives or {}) do
    local objective = view.quest_objectives[i]
    if objective.quest_id == questId then
      if not objective.complete then return false end
      seen = true
    end
  end
  if seen then return true end
  for i = 1, #(view.accepted_quests or {}) do
    local entry = view.accepted_quests[i]
    if accepted_quest_id(entry) == questId then return talk_only(view, entry) end
  end
  return false
end

-- Vanilla gray level: kills at or below it give no XP.
local function gray_level(level)
  level = tonumber(level) or 1
  if level <= 5 then return 0 end
  if level <= 39 then return level - math.floor(level / 10) - 5 end
  if level <= 59 then return level - math.floor(level / 5) - 1 end
  return level - 9
end

local function talk_quest_pending(view)
  for i = 1, #(view.accepted_quests or {}) do
    if talk_only(view, view.accepted_quests[i]) then return true end
  end
  return false
end

-- Objective-area travel. A seat whose only fresh pull is gray (or nothing)
-- while an accepted quest still needs kills or drops elsewhere walks to the
-- guide's spots for that objective instead of farming the starter field.
-- Patience is measured against real progress only: level, XP, finished rows
-- and carried quest items. Walking, statuses and new targets do not reset it.
local AREA_ARRIVE_YARDS = 35.0     -- inside this a spot counts as swept
local AREA_STOP_YARDS = 12.0
local AREA_MAX_YARDS = 600.0       -- local field work, not a cross-zone trip
local AREA_LEVEL_MARGIN = 2        -- same ceiling as a fresh pull
local AREA_PATIENCE_SECONDS = 180.0
local AREA_COOLDOWN_SECONDS = 600.0
local AREA_SPOT_REST_SECONDS = 120.0
local areaKey, areaSince, areaMark = nil, nil, nil
local areaCooldown = {}
-- key -> {strikes = fruitless retirements, credit = own credit at the last}
local areaFailed = {}
local areaSpotRest = {}
-- Stable quest/entry/item identity -> last known own credit. Missing or
-- reordered objective rows retain the same mark while metadata recovers.
local areaLastCredit = {}

local function area_progress_mark(view)
  local parts = { tostring(view.level or 0), tostring(view.xp or 0) }
  local rows = view.quest_objectives or {}
  for i = 1, #rows do
    local row = rows[i]
    local q = row.quest_id or 0
    local key = q .. ":" .. (row.entry or 0) .. ":" .. (row.item_id or 0)
    local credit
    if (row.item_id or 0) ~= 0 then
      if view.bag_space_known == true then
        credit = carried_count(view, row.item_id)
      end
    else
      credit = tonumber(row.current)
    end
    if credit ~= nil then
      areaLastCredit[key] = tostring(credit) .. ":" .. (row.complete and "1" or "0")
    end
  end
  local keys = {}
  for key in pairs(areaLastCredit) do keys[#keys + 1] = key end
  table.sort(keys)
  for i = 1, #keys do
    parts[#parts + 1] = keys[i] .. "=" .. areaLastCredit[keys[i]]
  end
  return table.concat(parts, ":")
end

local function objective_area_step(view, pos, now)
  if not OBJECTIVE_TRAVEL or not objective_area_data() then return nil end
  local rows = view.quest_objectives or {}
  -- Keys are quest id + guide objective position, independent of where the
  -- quest sits in the log. A key whose quest left the log starts over.
  -- `present` holds each paired objective's own credit when known: its kill
  -- count or the carried item count (nil while bags are unknown).
  local keyed, present = {}, {}
  for i = 1, #rows do
    local guide, _, position = area_objective(view, i)
    if guide then
      local row = rows[i]
      keyed[i] = row.quest_id .. ":" .. position
      local credit
      if (row.item_id or 0) ~= 0 then
        -- The actual SDK always supplies an inventory table, even while
        -- carried-bag observations are incomplete. Empty is not known zero.
        if view.bag_space_known == true then
          credit = carried_count(view, row.item_id)
        end
      else
        credit = row.current
      end
      present[keyed[i]] = credit ~= nil and tostring(credit) or nil
    end
  end
  local inLog
  if type(view.accepted_quests) == "table" then
    inLog = {}
    for _, q in ipairs(view.accepted_quests) do
      local id = accepted_quest_id(q)
      if id then inLog[id] = true end
    end
  end
  for key, fail in pairs(areaFailed) do
    -- Only a known quest removal or a known change of that objective's own
    -- credit clears its failures. XP from other pulls, an unpaired row or
    -- unknown bags do not; an unknown stored credit adopts the first known.
    local credit = present[key]
    if inLog and not inLog[tonumber(key:match("^(%-?%d+):"))] then
      areaFailed[key], areaCooldown[key] = nil, nil
    elseif credit ~= nil then
      if fail.credit == nil then
        fail.credit = credit
      elseif credit ~= fail.credit then
        areaFailed[key], areaCooldown[key] = nil, nil
      end
    end
  end
  local mark = area_progress_mark(view)
  if mark ~= areaMark then areaMark, areaSince = mark, now end
  if areaKey and areaSince and now - areaSince > AREA_PATIENCE_SECONDS then
    local prior = areaFailed[areaKey] or { strikes = 0 }
    local strikes = prior.strikes + 1
    areaFailed[areaKey] = { strikes = strikes,
      credit = present[areaKey] or prior.credit }
    -- A second fruitless retirement drops the objective until its own
    -- credit moves or the quest leaves the log.
    areaCooldown[areaKey] = strikes >= 2 and math.huge or
      now + AREA_COOLDOWN_SECONDS
    wow.log("objective area " .. areaKey .. ": no XP or credit, retiring (" ..
      strikes .. ")")
    areaKey, areaSince = nil, now
  end
  local map = math.floor(view.location.map_id or 0)
  -- Quests the log marks failed are skipped; an unknown flag is kept.
  local failed = {}
  for _, q in ipairs(view.accepted_quests or {}) do
    if type(q) == "table" and q.failed == true then failed[q.quest_id] = true end
  end
  local best, bestD, bestKey, bestQuest = nil, nil, nil, nil
  for i = 1, #rows do
    local row = rows[i]
    local guide, quest = area_objective(view, i)
    local key = keyed[i]
    if guide and not row.complete and not row.failed and
        not failed[row.quest_id] and area_travelable(guide) and
        (quest.level or 0) <= (view.level or 1) + AREA_LEVEL_MARGIN and
        not (areaCooldown[key] and now < areaCooldown[key]) then
      for s = 1, #(guide.spots or {}) do
        local spot = guide.spots[s]
        local spotKey = key .. ":" .. s
        if math.floor(spot[1]) == map and
            not (areaSpotRest[spotKey] and now < areaSpotRest[spotKey]) then
          local d = distance2d(pos.x, pos.y, spot[2], spot[3])
          if d <= AREA_ARRIVE_YARDS then
            areaSpotRest[spotKey] = now + AREA_SPOT_REST_SECONDS
          elseif d <= AREA_MAX_YARDS then
            -- Stay on the objective already being worked; a nearer spot of
            -- another one would otherwise flip the walk every tick.
            local score = key == areaKey and d * 0.5 or d
            if not bestD or score < bestD then
              best, bestD, bestKey, bestQuest = spot, score, key, row.quest_id
            end
          end
        end
      end
    end
  end
  if not best then return nil end
  if bestKey ~= areaKey then areaKey, areaSince = bestKey, now end
  wow.set_status(string.format("objective area quest %d", bestQuest))
  return {
    kind = "navigate",
    x = best[2], y = best[3], z = pos.z,
    map_id = map,
    stop_distance = AREA_STOP_YARDS,
    route_profile = "safe_ground",
    reason = "objective_area",
  }
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
  -- The nearest reachable ender wins, so a far one earlier in the log does
  -- not pull the seat away from a nearby turn-in. The leg already walking
  -- stays chosen while it is still eligible, so log reordering or proximity
  -- changes cannot flip it; the budget/cooldown above retires a failed walk.
  local best, bestD, bestId, bestKey = nil, nil, nil, nil
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
          if key == hubGuid then
            best, bestD, bestId, bestKey = ender, d, questId, key
            break
          end
          if not bestD or d < bestD then
            best, bestD, bestId, bestKey = ender, d, questId, key
          end
        end
      end
    end
  end
  if not best then return nil end
  if hubGuid ~= bestKey then hubGuid, hubSince = bestKey, now end
  wow.set_status(string.format("walking to turn-in %s (quest %d)",
    tostring(best[5] or "?"), bestId))
  return {
    kind = "navigate",
    x = best[2], y = best[3], z = best[4],
    map_id = map,
    stop_distance = HUB_ARRIVE_YARDS,
    route_profile = "safe_ground",
    reason = "quest_hub",
  }
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
    talk_quest_pending(view) or
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

  -- A banked quest whose ender the generated table names goes there before
  -- any remembered hub (5651 points from Deathknell to Brill).
  local generated = generated_hub_step(view, pos, now)
  if generated then return generated end

  -- A remembered giver is business only for an empty log or a banked quest
  -- nobody names an ender for. One whose ender is known (here, elsewhere, or
  -- on cooldown) is not a reason to walk back to whichever giver is nearest.
  local accepted = #(view.accepted_quests or {})
  local unbound = accepted == 0
  if not unbound then
    local data = quest_hub_data() or {}
    local done = {}
    for i = 1, #(view.quest_objectives or {}) do
      local o = view.quest_objectives[i]
      local q = o.quest_id or 0
      done[q] = done[q] ~= false and (o.complete and true or false)
    end
    for q, all in pairs(done) do
      if all and not (data[q] and data[q].ender) then unbound = true end
    end
    for i = 1, accepted do
      local entry = view.accepted_quests[i]
      local q = accepted_quest_id(entry)
      if talk_only(view, entry) and not (data[q] and data[q].ender) then
        unbound = true
      end
    end
  end

  -- Exhausted givers (truthy: true or "rows") have nothing for us; "rows"
  -- marks lapse with their row memory first.
  dialogRows.reopen(view)
  local best, bestDistance = nil, nil
  for guid, hub in pairs(unbound and questHubs or {}) do
    if hub.map_id == math.floor(view.location.map_id or 0) and
        not exhausted[guid] and
        not (hubCooldown[guid] and now < hubCooldown[guid]) then
      local d = distance2d(pos.x, pos.y, hub.x, hub.y)
      -- Inside QUESTGIVER_YARDS the visible-marker path already owns this.
      if d > QUESTGIVER_YARDS and (not bestDistance or d < bestDistance) then
        best, bestDistance = guid, d
      end
    end
  end
  if not best then
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
  bag_use_reset()
  exhausted = {}
  hubCooldown = {}
  dialogRows.by_npc, dialogRows.count, dialogRows.pick = {}, 0, nil
  pursuing, pursuingSince, questBudgetSince, questPausedAt = nil, nil, nil, nil
  wandPressedAt = nil
  wandPressedGuid = nil
  ignoreUntil = {}
  swingGuid, swingHp, swingSince, swingX, swingY = nil, nil, nil, nil, nil
  swingFrames = 0
  areaKey, areaSince, areaMark = nil, nil, nil
  areaCooldown = {}
  areaFailed = {}
  areaLastCredit = {}
  areaSpotRest = {}
end

--- One frame's intent. `policy` is optional and nil for every host-driven
--- entry; `policy.objective_first` makes a reachable unfinished objective
--- area outrank a fresh pull that pays no objective (an owner's quest
--- request). An engaged or known-hostile fight is never left for it.
function M.decide(view, policy)
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
      if idleLog or objective_complete(view) or
          (talk_quest_pending(view) and not (nearbyHunt and
            ((nearbyHunt.level or 0) > gray_level(view.level) or
              credits_objective(view, nearbyHunt)))) or
          not nearbyHunt then
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

  -- A gray pull that pays nothing is not progress while an accepted quest
  -- still needs kills or drops somewhere else. Out of combat that includes
  -- our own auto-attack on one: nothing is hitting us yet. Under an
  -- objective-first policy any fresh pull that pays nothing yields too.
  local filler = target and not engaged and policy and
    policy.objective_first == true and not credits_objective(view, target) and
    not targeted_by_hostile(view)
  if not view.in_combat and (not target or filler or
      (target.level_known and target.level <= gray_level(view.level) and
        not credits_objective(view, target))) then
    local area = objective_area_step(view, pos, wow.time())
    if area then
      area.status = progress_status(view)
      return area
    end
  end

  if target and note_swing(target, pos, wow.time()) then
    target = pick_target(view, true)
  end

  if target then
    local spell = pick_charge(view, target)
    local stop = ENGAGE_YARDS
    local reason = "grind"
    if spell then
      stop = CHARGE_MAX_YARDS
      reason = "charge"
    elseif (view.class_id or 0) == CLASS_MAGE then
      stop = CASTER_STOP_YARDS
      spell = pick_nuke(view)
      if spell then
        reason = "mage_nuke"
      elseif nuke_affordable(view) then
        reason = "mage_hold_range"
      else
        local wand, wanding = pick_wand(view, target)
        if wand then
          spell = wand
          reason = "mage_wand"
        elseif wanding then
          reason = "mage_wanding"
        end
      end
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
      reason = reason,
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
--- Skip a unit for `seconds` in every target pick (same table as the stale
--- swing guard).
function M.ignore(guid, seconds)
  if guid and guid ~= 0 then ignoreUntil[guid] = wow.time() + seconds end
end
M.loot_step = loot_step
--- Whether killing `unit` can pay an unfinished objective: a kill objective
--- naming its entry, or an item objective it is known to drop.
M.credits_objective = credits_objective

return M
