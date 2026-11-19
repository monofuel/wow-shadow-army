-- lifecycle: the long-horizon goals a persistent character needs on top of a
-- grinder: the class quest that unlocks its pet, a real pet kept out and sent
-- into fights, the highest rank it has actually trained, trainer visits that
-- teach the next rank, legal gear upgrades from its own loot, and an account
-- of every stretch where nothing paid.
--
-- Pure decisions over the lua-bot view plus a state table the caller owns;
-- lua/tests drives every branch on host Lua with ordinary view rows.
--
-- Every success is judged by the world, not by the intent: a pet counts when
-- the authoritative pet link names a living imp we summoned, an equip counts
-- when the worn slot carries the item guid we asked for, training counts when
-- known_spells grows, the class quest counts when it is in the completed list
-- and its reward spell is known.

local M = {}

M.CLASS_WARRIOR, M.CLASS_ROGUE = 1, 4
M.CLASS_PRIEST, M.CLASS_SHAMAN, M.CLASS_MAGE = 5, 7, 8
M.CLASS_WARLOCK, M.CLASS_DRUID = 9, 11

-- Quest/creature/spell ids below match the VMaNGOS world DB (quest_template,
-- creature, creature_loot_template, spell_chain, playercreateinfo_spell).
M.SPELL_SUMMON_IMP = 688
M.CREATURE_IMP = 416
M.QUEST_PIERCING_THE_VEIL = 1470
M.ITEM_RATTLECAGE_SKULL = 6281
M.SKULLS_NEEDED = 3
M.CREATURE_RATTLECAGE_SKELETON = 1890
M.CREATURE_VENYA_MARTHAND = 5667

-- Every rank of the opening nuke, highest first (spell_chain). The client
-- replaces the action button on SMSG_SUPERCEDED_SPELL, so a list that stops
-- at rank 2 finds no button at all once rank 3 is trained.
M.NUKE_RANKS = {
  [M.CLASS_WARLOCK] = { 25307, 11661, 11660, 11659, 7641, 1106, 1088, 705, 695, 686 },
  [M.CLASS_DRUID] = { 9912, 8905, 6780, 5180, 5179, 5178, 5177, 5176 },
  [M.CLASS_PRIEST] = { 10934, 10933, 6060, 1004, 984, 598, 591, 585 },
  [M.CLASS_SHAMAN] = { 15208, 15207, 10392, 10391, 6041, 943, 915, 548, 529, 403 },
  [M.CLASS_MAGE] = { 25306, 10151, 10150, 10149, 10148, 8402, 8401, 8400,
    3140, 145, 143, 133 },
}

-- The class trainers a starting-zone character can walk to, by creature
-- entry: the home zone first, then the next town. Their positions come from
-- the private positions module; a trainer without one is never visited.
M.CLASS_TRAINERS = {
  [M.CLASS_WARRIOR] = { 2119, 2131 },
  [M.CLASS_ROGUE] = { 2122, 2130 },
  [M.CLASS_PRIEST] = { 2123, 2129 },
  [M.CLASS_MAGE] = { 2124, 2128 },
  [M.CLASS_WARLOCK] = { 2126, 2127 },
  [M.CLASS_DRUID] = { 3060 },
}

-- World positions are game data, so they live in the git-ignored
-- data.bot_lifecycle_positions module: { creatures = { [entry] = spot },
-- places = { skeleton_field = spot } } with spot = { map, x, y, z }. Without
-- it the travel that needs a position is skipped.
local function load_positions()
  local ok, data = pcall(require, "data.bot_lifecycle_positions")
  if not ok or type(data) ~= "table" then return {} end
  return data
end

local POSITIONS = load_positions()

local function creature_spot(entry)
  local spot = type(POSITIONS.creatures) == "table" and POSITIONS.creatures[entry]
  if type(spot) ~= "table" or not spot.x then return nil end
  return { entry = entry, map = spot.map, x = spot.x, y = spot.y, z = spot.z }
end

local function place_spot(name)
  local spot = type(POSITIONS.places) == "table" and POSITIONS.places[name]
  if type(spot) ~= "table" or not spot.x then return nil end
  return spot
end

local function ascending(ranks)
  local out = {}
  for i = #ranks, 1, -1 do out[#out + 1] = ranks[i] end
  return out
end

-- Spell families a seat should hold on its main bar, most useful first; each
-- lists every rank (spell_chain, or the trainer ranks for families the chain
-- table omits). The client replaces a bound rank with the next one itself
-- (SMSG_SUPERCEDED_SPELL), so a family only needs binding once. Ranks are
-- listed lowest first.
M.BIND_FAMILIES = {
  [M.CLASS_WARLOCK] = {
    { 688 },
    ascending(M.NUKE_RANKS[M.CLASS_WARLOCK]),
    { 172, 6222, 6223, 7648, 11671, 11672, 25311 },
    { 980, 1014, 6217, 11711, 11712, 11713 },
    { 348, 707, 1094, 2941, 11665, 11667, 11668, 25309 },
    { 1454, 1455, 1456, 11687, 11688, 11689 },
    { 706, 1086, 11733, 11734, 11735 },
    { 687, 696 },
  },
  [M.CLASS_PRIEST] = {
    ascending(M.NUKE_RANKS[M.CLASS_PRIEST]),
    { 2050, 2052, 2053 },
    { 589, 594, 970, 992, 2767, 10892, 10893, 10894 },
    { 17, 592, 600, 3747, 6065, 6066, 10898, 10899, 10900, 10901 },
    { 139, 6074, 6075, 6076, 6077, 6078, 10927, 10928, 10929, 25315 },
    { 8092, 8102, 8103, 8104, 8105, 8106, 10945, 10946, 10947 },
    { 1243, 1244, 1245, 2791, 10937, 10938 },
    { 588, 7128, 602, 1006, 10951, 10952 },
  },
  [M.CLASS_MAGE] = {
    ascending(M.NUKE_RANKS[M.CLASS_MAGE]),
    { 116, 205, 837, 7322, 8406, 8407, 8408, 10179, 10180, 10181, 25304 },
    { 2136, 2137, 2138, 8412, 8413, 10197, 10199 },
    { 168, 7300, 7301 },
    { 7302, 7320, 10219, 10220 },
  },
  [M.CLASS_WARRIOR] = {
    { 78, 284 }, { 772, 6546 }, { 6673, 5242 }, { 100, 6178 }, { 6343, 8198 },
  },
  [M.CLASS_ROGUE] = {
    { 1752, 1757, 1758 }, { 2098, 6760 },
  },
}

local MAIN_BAR_SLOTS = 12
local BIND_SETTLE_SECONDS = 40.0
local BIND_MAX_ATTEMPTS = 2

-- Where the 1470 quest giver and the skull droppers are, when known.
local VENYA = creature_spot(M.CREATURE_VENYA_MARTHAND)
local SKELETON_FIELD = place_spot("skeleton_field")
local SKELETON_FIELD_ARRIVED_YARDS = 30.0

local SUMMON_SETTLE_SECONDS = 14.0
local SUMMON_MAX_FAILURES = 3
local SUMMON_BACKOFF_SECONDS = 120.0

local EQUIP_SETTLE_SECONDS = 6.0
local EQUIP_GAP_SECONDS = 2.0
local EQUIP_MAX_TRIES = 2

local TRAINER_REACH_YARDS = 400.0
local TRAINER_INTERACT_STOP = 3.0
local TRAINER_VISIT_SECONDS = 90.0
local TRAINER_MIN_COPPER = 100

local QUESTGIVER_STOP = 3.0
local DROPPER_YARDS = 80.0
local GRAY_SWAP_YARDS = 60.0
-- An evading mob (leashed, or unreachable and returning home) regenerates to
-- full while it ignores our hits. Health climbing this far above its low
-- point while we keep attacking it is that reset, not a fight.
local EVADE_REGAIN_PCT = 30.0
local EVADE_AVOID_SECONDS = 120.0

-- A no-progress stretch is reported once it reaches this, then every period.
local DIAGNOSE_AFTER_SECONDS = 120.0
local DIAGNOSE_PERIOD_SECONDS = 60.0

local function num(value, fallback)
  local n = tonumber(value)
  if n == nil then return fallback end
  return n
end

local function dist2d(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return math.sqrt(dx * dx + dy * dy)
end

function M.new_state()
  return {
    pet_guid = nil, pet_summons = 0, pet_losses = 0, pet_orders = 0,
    summon_at = nil, summon_failures = 0, summon_backoff_until = nil,
    equip_pending = nil, equip_last_at = nil, equip_refused = {}, equip_tries = {},
    equipped = 0, equip_failures = 0,
    trained_level = nil, train_since = nil, train_known_before = nil,
    trained_spells = 0,
    quest_logged = {},
    progress_key = nil, progress_since = nil, longest_no_progress = 0,
    diagnosed_at = nil, gray_swaps = 0, attack_low = {}, avoid_until = {},
    evade_swaps = 0,
    bind_pending = nil, bind_attempts = {}, bound_spells = 0,
  }
end

function M.knows_spell(view, spellId)
  for i = 1, #(view.known_spells or {}) do
    if view.known_spells[i] == spellId then return true end
  end
  return false
end

local function button_for(view, spellId)
  for i = 1, #(view.action_buttons or {}) do
    local button = view.action_buttons[i]
    if button.spell_id == spellId then return button end
  end
  return nil
end

local function unit_by_guid(view, guid)
  for i = 1, #(view.units or {}) do
    if view.units[i].guid == guid then return view.units[i] end
  end
  return nil
end

local function unit_distance(unit)
  if unit.combat_distance_known then return unit.combat_distance end
  return unit.distance or math.huge
end

local function alive(unit)
  return not (unit.death_known and unit.is_dead) and
    not (unit.health_known and unit.health <= 0)
end

local function position(view)
  return view.location and view.location.position
end

local function far_from(view, spot, yards)
  local pos = position(view)
  if not pos or math.floor(num(view.location.map_id, -1)) ~= spot.map then
    return math.huge
  end
  return dist2d(pos.x, pos.y, spot.x, spot.y) > yards and
    dist2d(pos.x, pos.y, spot.x, spot.y) or 0
end

local function navigate_to(view, spot, stop, reason)
  return {
    kind = "navigate", x = spot.x, y = spot.y, z = spot.z,
    map_id = spot.map, stop_distance = stop,
    route_profile = "prefer_ground", reason = reason,
  }
end

local function visible_entry(view, entry)
  local best, bestDistance = nil, nil
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    if unit.entry == entry and alive(unit) then
      local d = unit_distance(unit)
      if not bestDistance or d < bestDistance then best, bestDistance = unit, d end
    end
  end
  return best
end

-- Pet --------------------------------------------------------------------

--- The seat's own living imp, or nil. Only the authoritative pet link counts:
--- a nonzero link that is not dead, and, when its unit row is visible, a row
--- whose summoner is this seat and whose entry is the imp. A summoned unit
--- that the link does not name is someone else's business.
function M.own_pet(view)
  local pet = view.pet
  if type(pet) ~= "table" or not pet.guid_known or pet.guid == 0 or pet.dead then
    return nil
  end
  local unit = unit_by_guid(view, pet.guid)
  if unit then
    if view.player_guid and view.player_guid ~= 0 and
        unit.summoner_guid ~= 0 and unit.summoner_guid ~= view.player_guid then
      return nil
    end
    if not alive(unit) then return nil end
  end
  return {
    guid = pet.guid,
    entry = unit and unit.entry or nil,
    target_guid = pet.target_guid_known and pet.target_guid or nil,
    health = pet.health_known and pet.health or nil,
    max_health = pet.health_known and pet.max_health or nil,
  }
end

--- Keep a warlock's imp out. Returns an intent or nil; counts summons and
--- losses from the pet link, never from the cast.
function M.pet_step(view, state, now, busy)
  if view.class_id ~= M.CLASS_WARLOCK then return nil end
  if not M.knows_spell(view, M.SPELL_SUMMON_IMP) then return nil end
  local pet = M.own_pet(view)
  if pet then
    if state.pet_guid ~= pet.guid then
      state.pet_summons = state.pet_summons + 1
      state.pet_guid = pet.guid
      wow.log(string.format("raven: pet %s entry %s out (summon #%d)",
        tostring(pet.guid), tostring(pet.entry), state.pet_summons))
    end
    state.summon_at, state.summon_failures = nil, 0
    return nil
  end
  if state.pet_guid then
    state.pet_losses = state.pet_losses + 1
    wow.log(string.format("raven: pet %s lost (loss #%d)",
      tostring(state.pet_guid), state.pet_losses))
    state.pet_guid = nil
  end
  if view.active_cast_spell_id == M.SPELL_SUMMON_IMP then
    return { kind = "hold", reason = "summon_casting" }
  end
  -- A fight owns the seat; a summon it interrupted is retried afterwards
  -- without being counted against the spell.
  if busy or view.in_combat or view.is_dead or view.is_ghost then
    if state.summon_at then state.summon_at = now end
    return nil
  end
  if state.summon_backoff_until and now < state.summon_backoff_until then
    return nil
  end
  if state.summon_at then
    if now - state.summon_at < SUMMON_SETTLE_SECONDS then
      return { kind = "hold", reason = "summon_settling" }
    end
    state.summon_at = nil
    state.summon_failures = state.summon_failures + 1
    wow.log(string.format("raven: summon attempt %d produced no pet link",
      state.summon_failures))
    if state.summon_failures >= SUMMON_MAX_FAILURES then
      state.summon_failures = 0
      state.summon_backoff_until = now + SUMMON_BACKOFF_SECONDS
      return nil
    end
  end
  -- Every cast is a bound button press; an unbound summon is bind_step's.
  local button = button_for(view, M.SPELL_SUMMON_IMP)
  if not button or button.not_enough_mana or
      (button.usable_known and not button.usable) then
    return nil
  end
  state.summon_at = now
  return { kind = "cast_spell", spell = M.SPELL_SUMMON_IMP, reason = "summon_imp" }
end

--- Send the pet with the seat: an attack intent gains pet_attack while a
--- living imp is out. The host presses PETATTACK only when the pet link shows
--- it is not already on that target.
function M.with_pet(view, state, intent)
  if type(intent) ~= "table" or intent.kind ~= "attack" then return intent end
  local pet = M.own_pet(view)
  if not pet then return intent end
  intent.pet_attack = true
  if pet.target_guid ~= intent.guid then state.pet_orders = state.pet_orders + 1 end
  return intent
end

-- Action bar ----------------------------------------------------------------

local function family_bound(view, family)
  for i = 1, #family do
    if button_for(view, family[i]) then return true end
  end
  return false
end

local function highest_known(view, family)
  for i = #family, 1, -1 do
    if M.knows_spell(view, family[i]) then return family[i] end
  end
  return nil
end

local function empty_main_slot(view)
  if not view.action_bar_known then return nil end
  local best = nil
  for i = 1, #(view.action_buttons or {}) do
    local button = view.action_buttons[i]
    local slot = num(button.slot, 0)
    if button.kind == "empty" and slot >= 1 and slot <= MAIN_BAR_SLOTS and
        (not best or slot < best) then
      best = slot
    end
  end
  return best
end

--- Drag a learned spell the class brains cast onto an empty main-bar slot.
--- A quest reward or trainer purchase leaves a new spell in the spellbook
--- only; casting needs a bound button. Success is the button appearing on
--- the bar, never the drag itself. Returns an intent or nil.
function M.bind_step(view, state, now, busy)
  local pending = state.bind_pending
  if pending then
    if button_for(view, pending.spell) then
      state.bound_spells = state.bound_spells + 1
      state.bind_pending = nil
      wow.log(string.format("raven: spell %d bound to action slot %d",
        pending.spell, pending.slot))
      return nil
    end
    if busy or view.in_combat or view.is_dead or view.is_ghost or
        now - pending.at > BIND_SETTLE_SECONDS then
      wow.log(string.format("raven: binding spell %d to slot %d did not land (%s)",
        pending.spell, pending.slot, (busy or view.in_combat) and "fight" or "timeout"))
      state.bind_pending = nil
      return nil
    end
    return { kind = "bind_spell", spell = pending.spell, slot = pending.slot,
      reason = "bind_learned_spell" }
  end
  if busy or view.in_combat or view.is_dead or view.is_ghost then return nil end
  if (view.quest_frame and view.quest_frame.open) or view.gossip_open or
      view.trainer_open or view.merchant_open then
    return nil
  end
  local families = M.BIND_FAMILIES[view.class_id or 0]
  if not families then return nil end
  for i = 1, #families do
    local spell = highest_known(view, families[i])
    if spell and not family_bound(view, families[i]) and
        (state.bind_attempts[spell] or 0) < BIND_MAX_ATTEMPTS then
      local slot = empty_main_slot(view)
      if not slot then return nil end
      state.bind_attempts[spell] = (state.bind_attempts[spell] or 0) + 1
      state.bind_pending = { spell = spell, slot = slot, at = now }
      wow.log(string.format("raven: binding learned spell %d to empty slot %d (attempt %d)",
        spell, slot, state.bind_attempts[spell]))
      return { kind = "bind_spell", spell = spell, slot = slot,
        reason = "bind_learned_spell" }
    end
  end
  return nil
end

-- Ranks -------------------------------------------------------------------

--- Highest rank of the class nuke the seat has learned, holds on its bar, and
--- can press now. nil when the class has no table or no rank qualifies.
function M.best_nuke(view)
  local ranks = M.NUKE_RANKS[view.class_id or 0]
  if not ranks then return nil end
  for i = 1, #ranks do
    local spell = ranks[i]
    if M.knows_spell(view, spell) then
      local button = button_for(view, spell)
      if button and not (button.usable_known and not button.usable) and
          not button.not_enough_mana and not button.on_cooldown then
        return spell
      end
    end
  end
  return nil
end

--- Raise the grinder's nuke to the best ready rank. Only an attack that
--- already carries a nuke is touched, or one without a nuke because the
--- grinder's table found no bound rank while its mana floor still allowed
--- one (`mana_ok`).
function M.upgrade_attack(view, intent, mana_ok)
  if type(intent) ~= "table" or intent.kind ~= "attack" then return intent end
  if intent.spell == nil and not mana_ok then return intent end
  local best = M.best_nuke(view)
  if best and best ~= intent.spell then
    intent.spell = best
    intent.reason = (intent.reason or "grind") .. ":rank"
  end
  return intent
end

-- Training ------------------------------------------------------------------

local function class_trainer(view)
  local entries = M.CLASS_TRAINERS[view.class_id or 0]
  if not entries then return nil end
  for i = 1, #entries do
    local spot = creature_spot(entries[i])
    if spot and far_from(view, spot, TRAINER_REACH_YARDS) == 0 then return spot end
  end
  return nil
end

--- Visit the class trainer once per level gained, buy what the SDK's trainer
--- action selects, and count only spells that actually appear in
--- known_spells. Returns an intent or nil.
function M.train_step(view, state, now, busy)
  local level = num(view.level, 1)
  if state.trained_level == nil then state.trained_level = level end
  local visiting = state.train_since ~= nil
  if not visiting then
    if busy or view.in_combat or level <= state.trained_level then return nil end
    if num(view.copper, 0) < TRAINER_MIN_COPPER then return nil end
    if not class_trainer(view) then
      state.trained_level = level
      return nil
    end
    state.train_since = now
    state.train_known_before = #(view.known_spells or {})
    wow.log(string.format("raven: level %d, visiting class trainer", level))
  end
  local function finish(why)
    local learned = #(view.known_spells or {}) - (state.train_known_before or 0)
    if learned > 0 then state.trained_spells = state.trained_spells + learned end
    wow.log(string.format("raven: trainer visit at level %d ended (%s), learned %d",
      level, why, learned))
    state.train_since, state.train_known_before = nil, nil
    state.trained_level = level
    return nil
  end
  if now - state.train_since > TRAINER_VISIT_SECONDS then return finish("timeout") end
  if view.in_combat then return nil end
  local spot = class_trainer(view)
  if not spot then return finish("out of reach") end
  local trainer = visible_entry(view, spot.entry)
  if (view.trainer_open or view.gossip_open) and trainer and
      (view.trainer_guid == trainer.guid or view.gossip_guid == trainer.guid) then
    state.trainer_frame_seen = true
    return { kind = "train", guid = trainer.guid, reason = "train_ranks" }
  end
  if state.trainer_frame_seen then
    state.trainer_frame_seen = nil
    return finish("frame closed")
  end
  if trainer then
    return { kind = "interact", guid = trainer.guid,
      stop_distance = TRAINER_INTERACT_STOP, route_profile = "prefer_ground",
      reason = "class_trainer" }
  end
  return navigate_to(view, spot, TRAINER_INTERACT_STOP, "class_trainer_walk")
end

-- Gear ---------------------------------------------------------------------

local function class_bit(classId)
  return 1 << ((classId or 1) - 1)
end

local function worn_in_slot(view, slot)
  for i = 1, #(view.equipment_items or {}) do
    local row = view.equipment_items[i]
    if num(row.equipment_slot, -1) == slot then return row end
  end
  return nil
end

--- Why `item` is not a legal SDK-scored upgrade, or nil when it is. The score
--- and target slot are the SDK's own comparison (armor, weapon, loadout, then
--- item level); this only adds the legality the seat can see.
function M.upgrade_refusal(view, item)
  if item.definition_known == false then return "unknown definition" end
  if num(item.upgrade_score, 0) <= 0 then return "not an upgrade" end
  if num(item.required_level, 0) > num(view.level, 1) then return "level" end
  local mask = num(item.allowable_class_mask, 0)
  if mask > 0 and mask ~= 0x7FFFFFFF and (mask & class_bit(view.class_id)) == 0 then
    return "class mask"
  end
  return nil
end

--- Best legal upgrade in the bags as (row, slot), by SDK score.
function M.pick_upgrade(view, state)
  local best, bestScore = nil, nil
  for i = 1, #(view.inventory_items or {}) do
    local item = view.inventory_items[i]
    local guid = item.item_guid
    if guid and guid ~= 0 and not state.equip_refused[guid] and
        M.upgrade_refusal(view, item) == nil then
      local score = num(item.upgrade_score, 0)
      if not bestScore or score > bestScore then best, bestScore = item, score end
    end
  end
  if not best then return nil, nil end
  return best, num(best.upgrade_slot, -1)
end

--- Equip one legal upgrade at a time and confirm it from the worn rows.
--- Returns (intent or nil, outcome or nil).
function M.gear_step(view, state, now, busy)
  local pending = state.equip_pending
  if pending then
    local worn = worn_in_slot(view, pending.slot)
    local landed = worn and worn.item_guid == pending.guid
    if not landed then
      for i = 1, #(view.equipment_items or {}) do
        if view.equipment_items[i].item_guid == pending.guid then landed = true end
      end
    end
    if landed then
      state.equipped = state.equipped + 1
      state.equip_pending = nil
      state.equip_last_at = now
      return nil, { equipped = pending }
    end
    -- The host refuses an equip in combat; a fight that starts mid-settle
    -- says nothing about the item, so it stays eligible.
    if view.in_combat or busy then
      state.equip_pending = nil
      return nil
    end
    if now - pending.at < EQUIP_SETTLE_SECONDS then
      return { kind = "hold", reason = "equip_settling" }
    end
    state.equip_tries[pending.guid] = (state.equip_tries[pending.guid] or 0) + 1
    state.equip_failures = state.equip_failures + 1
    state.equip_pending = nil
    if state.equip_tries[pending.guid] >= EQUIP_MAX_TRIES then
      state.equip_refused[pending.guid] = true
      return nil, { refused = pending }
    end
    return nil
  end
  if busy or not view.equip_supported then return nil end
  if view.in_combat or view.is_dead or view.is_ghost then return nil end
  if state.equip_last_at and now - state.equip_last_at < EQUIP_GAP_SECONDS then
    return nil
  end
  local item, slot = M.pick_upgrade(view, state)
  if not item then return nil end
  local before = worn_in_slot(view, slot)
  state.equip_pending = { guid = item.item_guid, slot = slot, at = now,
    name = item.name, item_id = item.item_id, score = item.upgrade_score,
    replaced = before and before.item_id or 0 }
  state.equip_last_at = now
  return { kind = "equip_item", item_guid = item.item_guid,
    reason = "equip_upgrade" }
end

-- Class quest -------------------------------------------------------------

local function listed(list, questId)
  for i = 1, #(list or {}) do
    if list[i] == questId then return true end
  end
  return false
end

local function accepted(view, questId)
  for i = 1, #(view.accepted_quests or {}) do
    if view.accepted_quests[i].quest_id == questId then return true end
  end
  return false
end

local function item_objective(view, questId, itemId)
  for i = 1, #(view.quest_objectives or {}) do
    local o = view.quest_objectives[i]
    if o.quest_id == questId and o.item_id == itemId then return o end
  end
  return nil
end

--- The warlock imp quest's phase from the quest log: nil when it does not
--- apply (other class, imp already known, or rewarded), else one of
--- "accept", "collect", "turn_in". `completed_quest_ids` lists quests whose
--- objectives are done while they are still in the log; only
--- `rewarded_quest_ids` (this session's turn-ins) or the reward spell itself
--- means the quest is over.
function M.class_quest_phase(view)
  local q = M.QUEST_PIERCING_THE_VEIL
  if view.class_id ~= M.CLASS_WARLOCK then return nil end
  if M.knows_spell(view, M.SPELL_SUMMON_IMP) then return nil end
  if not accepted(view, q) then
    if listed(view.rewarded_quest_ids, q) then return nil end
    return "accept"
  end
  local o = item_objective(view, q, M.ITEM_RATTLECAGE_SKULL)
  if listed(view.completed_quest_ids, q) or
      (o and (o.complete or num(o.current, 0) >= M.SKULLS_NEEDED)) then
    return "turn_in"
  end
  return "collect"
end

local function control_enabled(view, reference)
  for i = 1, #(view.ui_nodes or {}) do
    local node = view.ui_nodes[i]
    if node.reference_id == reference and node.enabled and node.hit_testable then
      return true
    end
  end
  return false
end

--- Answer an open quest or gossip dialog toward the class quest; other
--- quests are declined so the seat never stalls on a dialog it opened.
function M.class_quest_dialog(view)
  local want = M.QUEST_PIERCING_THE_VEIL
  local frame = view.quest_frame or {}
  if frame.open then
    local mine = frame.quest_id == want
    if frame.panel == "reward" and mine then
      return { kind = "quest_cmd", command = "/questreward", reason = "class_quest_reward" }
    end
    if frame.panel == "progress" and mine and frame.can_complete then
      return { kind = "quest_cmd", command = "/questcomplete", reason = "class_quest_complete" }
    end
    if frame.panel == "details" and mine then
      return { kind = "quest_cmd", command = "/questaccept", reason = "class_quest_accept" }
    end
    if frame.panel == "greeting" then
      if control_enabled(view, "quest-greeting:" .. want) then
        return { kind = "ui_press", reference = "quest-greeting:" .. want,
          reason = "class_quest_row" }
      end
      return { kind = "ui_press", control = "QuestFrameGreetingGoodbyeButton",
        reason = "class_quest_not_offered" }
    end
    if frame.panel == "details" then
      return { kind = "ui_press", control = "QuestFrameDeclineButton",
        reason = "not_class_quest" }
    end
    return { kind = "ui_press", control = "QuestFrameGoodbyeButton",
      reason = "class_quest_unfinished" }
  end
  if view.gossip_open then
    if control_enabled(view, "gossip-quest:" .. want) then
      return { kind = "ui_press", reference = "gossip-quest:" .. want,
        reason = "class_quest_gossip_row" }
    end
    return { kind = "ui_press", control = "GossipFrameGreetingGoodbyeButton",
      reason = "class_quest_gossip_done" }
  end
  return nil
end

--- The nearest attackable skull dropper, when the class quest still needs
--- skulls and one is in reach.
function M.class_quest_dropper(view)
  if M.class_quest_phase(view) ~= "collect" then return nil end
  local best, bestDistance = nil, nil
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    local d = unit_distance(unit)
    if unit.entry == M.CREATURE_RATTLECAGE_SKELETON and unit.player_can_attack and
        alive(unit) and not (unit.is_tapped and not unit.tapped_by_player) and
        d <= DROPPER_YARDS and (not bestDistance or d < bestDistance) then
      best, bestDistance = unit, d
    end
  end
  return best
end

--- Out-of-combat class quest travel: to Venya to accept or turn in, to the
--- skeleton field while skulls are missing and no dropper is visible. A
--- dialog with Venya is opened by interacting with her visible unit.
function M.class_quest_step(view, state)
  local phase = M.class_quest_phase(view)
  if phase ~= state.quest_phase then
    wow.log(string.format("raven: class quest %d phase %s -> %s",
      M.QUEST_PIERCING_THE_VEIL, tostring(state.quest_phase), tostring(phase)))
    state.quest_phase = phase
  end
  if not phase then return nil end
  if phase == "accept" or phase == "turn_in" then
    local venya = visible_entry(view, M.CREATURE_VENYA_MARTHAND)
    if venya and unit_distance(venya) <= 40.0 then
      return { kind = "interact", guid = venya.guid, stop_distance = QUESTGIVER_STOP,
        route_profile = "prefer_ground", reason = "class_quest_" .. phase }
    end
    if not VENYA then return nil end
    return navigate_to(view, VENYA, QUESTGIVER_STOP, "class_quest_walk_" .. phase)
  end
  local dropper = M.class_quest_dropper(view)
  if dropper then
    return { kind = "attack", guid = dropper.guid, stop_distance = 4.0,
      route_profile = "prefer_ground", reason = "class_quest_dropper" }
  end
  if SKELETON_FIELD and far_from(view, SKELETON_FIELD, SKELETON_FIELD_ARRIVED_YARDS) > 0 then
    return navigate_to(view, SKELETON_FIELD, 8.0, "class_quest_field")
  end
  return nil
end

--- Log the moment the quest's reward is real: completed and spell known.
function M.note_class_quest(view, state)
  if state.quest_logged.done then return end
  local q = M.QUEST_PIERCING_THE_VEIL
  if listed(view.rewarded_quest_ids, q) or
      (view.class_id == M.CLASS_WARLOCK and not accepted(view, q) and
        M.knows_spell(view, M.SPELL_SUMMON_IMP) and state.quest_phase ~= nil) then
    state.quest_logged.done = true
    wow.log(string.format("raven: quest %d rewarded; summon imp %s known",
      M.QUEST_PIERCING_THE_VEIL,
      M.knows_spell(view, M.SPELL_SUMMON_IMP) and "is" or "is NOT"))
  end
end

-- Loot ---------------------------------------------------------------------

local LOOT_REACH_YARDS = 40.0

--- The nearest corpse this seat tapped that the client marks lootable and
--- that has not been tried yet. Kill-event feeds are not on every route, so
--- the corpse's own dynamic flags are the trigger.
function M.loot_corpse(view, state)
  state.loot_tried = state.loot_tried or {}
  local best, bestDistance = nil, nil
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    local d = unit_distance(unit)
    if unit.death_known and unit.is_dead and unit.lootable_known and
        unit.is_lootable and unit.tapped_by_player and
        not state.loot_tried[unit.guid] and d <= LOOT_REACH_YARDS and
        (not bestDistance or d < bestDistance) then
      best, bestDistance = unit, d
    end
  end
  return best
end

--- Whether the seat is really in a fight: combat, a cast, or a swing at a
--- target that is still alive. A stale auto-attack guid on a corpse or an
--- out-of-sight unit is not a fight.
function M.fighting(view)
  if view.in_combat or (view.active_cast_spell_id or 0) ~= 0 then return true end
  local guid = view.auto_attack_guid or 0
  if guid == 0 then return false end
  local unit = unit_by_guid(view, guid)
  return unit ~= nil and alive(unit)
end

-- Targets ------------------------------------------------------------------

--- The level at or below which a mob gives no XP (vanilla gray level).
function M.gray_level(level)
  level = num(level, 1)
  if level <= 5 then return 0 end
  if level <= 39 then return level - math.floor(level / 10) - 5 end
  if level <= 59 then return level - math.floor(level / 5) - 1 end
  return level - 9
end

local function credits_item_objective(view, unit)
  for i = 1, #(view.quest_objectives or {}) do
    local o = view.quest_objectives[i]
    if not o.complete and o.entry ~= 0 and o.entry == unit.entry then return true end
  end
  if M.class_quest_phase(view) == "collect" and
      unit.entry == M.CREATURE_RATTLECAGE_SKELETON then
    return true
  end
  return false
end

--- A fresh pull of a gray mob earns nothing unless it drops a quest item we
--- still need. Swap it for the nearest XP-bearing attackable unit in reach;
--- leave it alone when nothing better is there (the grinder's own roaming
--- then moves on) or when we are already fighting it.
function M.purposeful_target(view, state, intent)
  if type(intent) ~= "table" or intent.kind ~= "attack" then return intent end
  if view.in_combat or view.auto_attack_guid == intent.guid then return intent end
  local target = unit_by_guid(view, intent.guid)
  if not target or not target.level_known then return intent end
  local gray = M.gray_level(view.level)
  if target.level > gray or credits_item_objective(view, target) then return intent end
  local best, bestDistance = nil, nil
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    local d = unit_distance(unit)
    if unit.guid ~= intent.guid and unit.player_can_attack and alive(unit) and
        unit.level_known and unit.level > gray and
        unit.level <= num(view.level, 1) + 2 and
        not (unit.is_tapped and not unit.tapped_by_player) and
        (unit.summoner_guid or 0) == 0 and
        d <= GRAY_SWAP_YARDS and (not bestDistance or d < bestDistance) then
      best, bestDistance = unit, d
    end
  end
  if not best then return intent end
  state.gray_swaps = state.gray_swaps + 1
  intent.guid = best.guid
  intent.spell = nil
  intent.reason = (intent.reason or "grind") .. ":not_gray"
  return intent
end

local function health_pct(unit)
  if not unit or not unit.health_known or num(unit.max_health, 0) <= 0 then return nil end
  return num(unit.health, 0) * 100.0 / num(unit.max_health, 1)
end

local function avoided(state, guid, now)
  local until_ = state.avoid_until[guid]
  return until_ ~= nil and now < until_
end

--- Steer an attack off a target that is resetting on us. Tracks the lowest
--- health each attacked target reached; once it regains EVADE_REGAIN_PCT
--- while we are still on it, that guid is avoided for a while and the
--- nearest other XP-bearing attackable unit is taken instead (or none: the
--- attack is dropped so the grinder roams on).
function M.avoid_evading(view, state, intent, now, ignore)
  if type(intent) ~= "table" or intent.kind ~= "attack" or not intent.guid then
    return intent
  end
  local guid = intent.guid
  local target = unit_by_guid(view, guid)
  local pct = health_pct(target)
  if pct and not avoided(state, guid, now) then
    local low = state.attack_low[guid]
    if not low or pct < low then state.attack_low[guid] = pct; low = pct end
    if pct - low >= EVADE_REGAIN_PCT then
      state.avoid_until[guid] = now + EVADE_AVOID_SECONDS
      state.attack_low[guid] = nil
      state.evade_swaps = state.evade_swaps + 1
      wow.log(string.format("raven: target %s (entry %s) regained %.0f%% while attacked; avoiding it",
        tostring(guid), tostring(target and target.entry), pct - low))
      -- The grinder's own pick then skips it too, so the stop below lasts a
      -- frame rather than the whole avoid window.
      if ignore then ignore(guid, EVADE_AVOID_SECONDS) end
    end
  end
  if not avoided(state, guid, now) then return intent end
  local gray = M.gray_level(view.level)
  local best, bestDistance = nil, nil
  for i = 1, #(view.units or {}) do
    local unit = view.units[i]
    local d = unit_distance(unit)
    if unit.guid ~= guid and not avoided(state, unit.guid, now) and
        unit.player_can_attack and alive(unit) and unit.level_known and
        unit.level > gray and unit.level <= num(view.level, 1) + 2 and
        not (unit.is_tapped and not unit.tapped_by_player) and
        (unit.summoner_guid or 0) == 0 and d <= GRAY_SWAP_YARDS and
        (not bestDistance or d < bestDistance) then
      best, bestDistance = unit, d
    end
  end
  if not best then
    return { kind = "hold", reason = "avoid_evading_target" }
  end
  intent.guid = best.guid
  intent.spell = nil
  intent.reason = (intent.reason or "grind") .. ":not_evading"
  return intent
end

-- Progress accounting -------------------------------------------------------

local function progress_key(view, state)
  local skulls = 0
  for i = 1, #(view.quest_objectives or {}) do
    skulls = skulls + num(view.quest_objectives[i].current, 0)
  end
  return table.concat({
    tostring(view.level), tostring(view.xp), tostring(view.copper),
    tostring(#(view.known_spells or {})), tostring(#(view.completed_quest_ids or {})),
    tostring(#(view.accepted_quests or {})), tostring(skulls),
    tostring(state.equipped), tostring(#(view.inventory_items or {})),
  }, ":")
end

--- Track the longest stretch without XP, money, items, quest, spell or gear
--- progress, and report what the seat was doing during one. This changes no
--- behavior: a stall is diagnosed from its log, then fixed where it starts.
function M.note_progress(view, state, now, intent)
  local key = progress_key(view, state)
  if key ~= state.progress_key then
    state.progress_key, state.progress_since, state.diagnosed_at = key, now, nil
    return
  end
  local span = now - (state.progress_since or now)
  if span > state.longest_no_progress then state.longest_no_progress = span end
  if span < DIAGNOSE_AFTER_SECONDS then return end
  if state.diagnosed_at and now - state.diagnosed_at < DIAGNOSE_PERIOD_SECONDS then
    return
  end
  state.diagnosed_at = now
  local target = intent and intent.guid and unit_by_guid(view, intent.guid)
  local pos = position(view) or { x = 0, y = 0 }
  wow.log(string.format(
    "raven: no progress %.0fs: intent=%s/%s combat=%s target=%s lvl=%s hp=%s/%s pos=%.1f,%.1f",
    span, tostring(intent and intent.kind), tostring(intent and intent.reason),
    tostring(view.in_combat), tostring(target and target.entry),
    tostring(target and target.level), tostring(target and target.health),
    tostring(target and target.max_health), pos.x, pos.y))
end

return M
