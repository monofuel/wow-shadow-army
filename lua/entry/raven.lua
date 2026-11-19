-- raven: persistent leveling. The 10x grinder (peregrine) still owns death,
-- the fight core and roaming; this entry adds what a character that lives
-- for days needs: the class quest that unlocks its pet, the pet itself sent
-- into every fight, the loot it kills for, the gear that loot becomes, the
-- ranks a trainer teaches, and the best rank it actually holds.
--
-- Order per decide: death stays with the grinder; an open dialog is the
-- class quest's or the trainer's; then (outside fights) summon, loot, equip,
-- train and class quest travel; then the grind, with the pet sent along,
-- gray pulls swapped for XP, and the nuke raised to the best ready rank.
-- Peregrine's QUESTS flag is never touched.

local core = require("peregrine")
local solo = require("accelerated")
local life = require("tools.lifecycle")

local M = {}

-- Peregrine's own fresh-pull gate; a nuke is only added where it would have
-- cast one itself.
local NUKE_MANA_FLOOR_PCT = 35.0

local state = life.new_state()

function M.reset()
  state = life.new_state()
end

function M.lifecycle_state()
  return state
end

local function mana_pct(view)
  local pools, maxima = view.powers, view.max_powers
  if not pools or not maxima or not maxima[1] or maxima[1] <= 0 then
    return 100.0
  end
  return (pools[1] or 0) * 100.0 / maxima[1]
end


local function quest_dialog_open(view)
  return (view.quest_frame and view.quest_frame.open) or view.gossip_open
end

local function log_gear(outcome)
  if outcome and outcome.equipped then
    local e = outcome.equipped
    wow.log(string.format(
      "raven: equipped %s (%s, score %s) into slot %d replacing item %s",
      tostring(e.name), tostring(e.item_id), tostring(e.score), e.slot,
      tostring(e.replaced)))
  elseif outcome and outcome.refused then
    wow.log(string.format("raven: equip of %s (%s) never reached slot %d; set aside",
      tostring(outcome.refused.name), tostring(outcome.refused.item_id),
      outcome.refused.slot))
  end
end

local function with_status(intent, view)
  if type(intent) == "table" and type(intent.status) == "table" then
    intent.status.pet_summons = state.pet_summons
    intent.status.pet_losses = state.pet_losses
    intent.status.pet_out = state.pet_guid ~= nil
    intent.status.equipped = state.equipped
    intent.status.trained_spells = state.trained_spells
    intent.status.class_quest = state.quest_phase or "none"
    intent.status.longest_no_progress = math.floor(state.longest_no_progress)
    intent.status.gray_swaps = state.gray_swaps
    intent.status.loot_armed = state.loot_armed or 0
  end
  return intent
end

local function grind(view)
  local intent = core.decide(view)
  intent = life.purposeful_target(view, state, intent)
  intent = life.avoid_evading(view, state, intent, wow.time(), solo.ignore)
  intent = life.with_pet(view, state, intent)
  return life.upgrade_attack(view, intent, mana_pct(view) >= NUKE_MANA_FLOOR_PCT)
end

local function decide(view)
  local now = wow.time()
  solo.note_kills(view)
  life.note_class_quest(view, state)

  if view.is_dead or view.is_ghost or not view.location_known or
      not view.location then
    return core.decide(view)
  end

  if state.train_since and (view.trainer_open or view.gossip_open) then
    local train = life.train_step(view, state, now, false)
    if train then return train end
  end
  if quest_dialog_open(view) then
    local answer = life.class_quest_dialog(view)
    if answer then return answer end
  end

  local busy = life.fighting(view)
  local pet = life.pet_step(view, state, now, busy)
  if pet then return pet end

  if busy then return grind(view) end

  -- Arm the shared loot taker from the corpse's lootable flag; it then
  -- opens, takes and settles exactly as on kill-event routes.
  local corpse = life.loot_corpse(view, state)
  if corpse then
    state.loot_tried[corpse.guid] = true
    state.loot_armed = (state.loot_armed or 0) + 1
    solo.note_kills({ player_guid = view.player_guid,
      combat_kill_events = { { target_guid = corpse.guid,
        source_guid = view.player_guid } } })
  end
  local loot = solo.loot_step(view)
  if loot then return loot end
  local gear, outcome = life.gear_step(view, state, now, busy)
  log_gear(outcome)
  if gear then return gear end
  local train = life.train_step(view, state, now, busy)
  if train then return train end
  local quest = life.class_quest_step(view, state)
  if quest then
    return life.with_pet(view, state, life.upgrade_attack(view, quest,
      mana_pct(view) >= NUKE_MANA_FLOOR_PCT))
  end
  return grind(view)
end

function M.decide(view)
  local intent = decide(view)
  life.note_progress(view, state, wow.time(), intent)
  return with_status(intent, view)
end

return M
