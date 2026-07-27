-- warlock_imp_quest: named-intent path for undead warlock quest 1470
-- "Piercing the Veil" → teaches Summon Imp (RewSpellCast 7763).
--
-- Frame shape (projected / synthetic for unit tests)::
--
--   {
--     self_unit = { class_id = 9, x?, y? },
--     quest = {
--       -- Masked offers (accept ready)
--       offers = { { id = 1470, entity_id = N } },
--       -- Active log
--       active = { { id = 1470, complete = bool, item_count = 0..3 } },
--       -- Turn-in ready
--       turn_ins = { { id = 1470, entity_id = N } },
--     },
--     combat = {
--       in_combat, attackable = { { id, guid, x?, y? } },
--       casts = { { target, spell, name, spell_id } },
--       focus_guid, auto_attack_guid, focus_id,
--     },
--     -- Optional: summon already learned (spell on self mask)
--     abilities = { summon_imp = { spell = S } },
--   }
--
-- Priority:
--   1. Cast Summon Imp when the ability is masked (quest reward learned)
--   2. Turn in 1470 when turn_in is offered
--   3. Accept 1470 when offer is masked
--   4. Active incomplete: combat on focus / nearest attackable (skull grind)
--   5. Active incomplete, no hostiles: interact with questgiver if offered
--   6. hold with reason stating missing masks / progress
--
-- Does NOT invent world coordinates as truth. Movement to Venya is upstream
-- (nav goal / human lead / escort). If accept/turn_in masks are empty,
-- decide returns hold:quest_masks_unavailable (documented upstream gap).

local registry = require("registry")

local QUEST_PIERCING_THE_VEIL = 1470
local SKULLS_NEEDED = 3
local CLASS_WARLOCK = 9
local MELEE_RANGE = 5.5
local MELEE_RANGE2 = MELEE_RANGE * MELEE_RANGE

local function is_warlock(me, args)
  local c = (me and me.class_id) or (args and args.class_id) or 0
  return tonumber(c) == CLASS_WARLOCK
end

local function lower(s)
  return tostring(s or ""):lower()
end

local function name_matches(spell_name, want)
  local n = lower(spell_name)
  local w = lower(want)
  return n == w or n:find(w, 1, true) ~= nil
end

local function find_quest_row(list, quest_id)
  if not list then return nil end
  for i = 1, #list do
    local q = list[i]
    if q and tonumber(q.id) == quest_id then
      return q
    end
  end
  return nil
end

local function pick_summon_imp(casts, abilities)
  if abilities and abilities.summon_imp and abilities.summon_imp.spell then
    return {
      kind = "cast_spell",
      unit_id = 0,
      spell = abilities.summon_imp.spell,
      reason = "summon_imp",
    }
  end
  if not casts then return nil end
  for i = 1, #casts do
    local c = casts[i]
    if c and (c.target or 0) == 0 and name_matches(c.name, "summon imp") then
      return {
        kind = "cast_spell",
        unit_id = 0,
        spell = c.spell,
        reason = "summon_imp",
      }
    end
  end
  return nil
end

local function pick_offensive(casts, target_id)
  if not casts or not target_id then return nil end
  local priority = {
    "curse of agony",
    "corruption",
    "immolate",
    "shadow bolt",
    "shoot",
  }
  for pi = 1, #priority do
    local want = priority[pi]
    for i = 1, #casts do
      local c = casts[i]
      if c and c.target == target_id and name_matches(c.name, want) then
        return c
      end
    end
  end
  for i = 1, #casts do
    local c = casts[i]
    if c and c.target == target_id then
      return c
    end
  end
  return nil
end

local function nearest_attackable(me, attackable)
  if not attackable then return nil, nil end
  local best, best_d2 = nil, nil
  for i = 1, #attackable do
    local u = attackable[i]
    if u and u.id and u.id > 0 and not u.lootable then
      if me and me.x and u.x and me.y and u.y then
        local dx, dy = u.x - me.x, u.y - me.y
        local d2 = dx * dx + dy * dy
        if best_d2 == nil or d2 < best_d2 then
          best, best_d2 = u, d2
        end
      elseif best == nil then
        best = u
      end
    end
  end
  return best, best_d2
end

local function guid_nonzero(g)
  if g == nil then return false end
  local s = tostring(g)
  return s ~= "" and s ~= "0"
end

return registry.register({
  name = "warlock_imp_quest",
  when = "Undead warlock: accept/progress/turn-in Piercing the Veil (1470) and summon imp when trained.",
  decide = function(frame, args)
    args = args or {}
    local me = frame.self_unit
    if not is_warlock(me, args) then
      return { kind = "hold", reason = "not_warlock" }
    end

    local quest = frame.quest or {}
    local combat = frame.combat or {}
    local casts = combat.casts or {}
    local abilities = frame.abilities or {}
    local quest_id = tonumber(args.quest_id) or QUEST_PIERCING_THE_VEIL

    -- 1. Ability unlocked: summon the imp.
    local summon = pick_summon_imp(casts, abilities)
    if summon then
      return summon
    end

    -- 2. Turn in when ready (mask + entity).
    local turn = find_quest_row(quest.turn_ins, quest_id)
    if not turn and quest.turn_ins and #quest.turn_ins > 0 then
      -- Dialog open: any turn_in row (id may be 0 or 1470).
      turn = quest.turn_ins[1]
    end
    if turn then
      return {
        kind = "turn_in_quest",
        quest_id = quest_id,
        quest_factor = turn.quest_factor or 0,
        unit_id = turn.entity_id or turn.unit_id or 0,
        reason = "turn_in_piercing_the_veil",
      }
    end

    -- 3. Accept when offered.
    local offer = find_quest_row(quest.offers, quest_id)
    if offer then
      return {
        kind = "accept_quest",
        quest_id = quest_id,
        quest_factor = offer.quest_factor or 0,
        unit_id = offer.entity_id or offer.unit_id or 0,
        reason = "accept_piercing_the_veil",
      }
    end

    local active = find_quest_row(quest.active, quest_id)
    if active then
      if active.complete then
        -- Complete: open questgiver dialog via nearest interactable unit.
        if active.entity_id and active.entity_id > 0 then
          return {
            kind = "interact_unit",
            unit_id = active.entity_id,
            reason = "interact_turnin_npc",
          }
        end
        local best, best_d2 = nil, nil
        for i = 1, #(quest.interactables or {}) do
          local u = quest.interactables[i]
          if u and u.id and u.id > 0 and u.kind ~= "object" then
            if me and me.x and u.x and me.y and u.y then
              local dx, dy = u.x - me.x, u.y - me.y
              local d2 = dx * dx + dy * dy
              if best_d2 == nil or d2 < best_d2 then
                best, best_d2 = u, d2
              end
            elseif best == nil then
              best = u
            end
          end
        end
        if best then
          -- Approach if beyond interact range (~5y), else interact.
          if best_d2 ~= nil and best_d2 > (5.5 * 5.5) and best.x and best.y then
            return {
              kind = "move_to_unit",
              unit_id = best.id,
              map_id = best.map_id or (me and me.map_id) or 0,
              x = best.x, y = best.y, z = best.z or (me and me.z) or 0,
              reason = "approach_turnin_npc",
            }
          end
          return {
            kind = "interact_unit",
            unit_id = best.id,
            reason = "interact_turnin_npc",
          }
        end
        return { kind = "hold", reason = "quest_complete_awaiting_turnin_mask" }
      end

      -- 4. Loot first (Rattlecage Skull 6281 only drops on loot).
      local lootables = combat.lootable or frame.lootable or {}
      if type(lootables) == "table" then
        for i = 1, #lootables do
          local u = lootables[i]
          if u and u.id and u.id > 0 then
            return { kind = "interact_unit", unit_id = u.id, reason = "loot_skull" }
          end
        end
      end
      for i = 1, #(combat.attackable or {}) do
        local u = combat.attackable[i]
        if u and u.lootable and u.id and u.id > 0 then
          return { kind = "loot_unit", unit_id = u.id, reason = "loot_skull_corpse" }
        end
      end

      -- 5. Grind skulls: nearest hostile (not stale far focus).
      local focused, d2 = nearest_attackable(me, combat.attackable)
      local target_id = focused and focused.id or nil
      if (not target_id or target_id == 0) and combat.focus_id and combat.focus_id > 0 then
        target_id = combat.focus_id
        for i = 1, #(combat.attackable or {}) do
          local u = combat.attackable[i]
          if u and u.id == target_id then focused = u break end
        end
      end

      if target_id and target_id > 0 then
        if d2 ~= nil and d2 > MELEE_RANGE2 and focused and focused.x and focused.y then
          return {
            kind = "move_to_unit",
            unit_id = target_id,
            map_id = focused.map_id or (me and me.map_id) or 0,
            x = focused.x,
            y = focused.y,
            z = focused.z or (me and me.z) or 0,
            reason = "approach_skull_mob",
          }
        end
        local cast = pick_offensive(casts, target_id)
        if cast then
          return {
            kind = "cast_spell",
            unit_id = cast.target,
            spell = cast.spell,
            reason = "imp_quest_grind:" .. lower(cast.name),
          }
        end
        return {
          kind = "attack_unit",
          unit_id = target_id,
          reason = "imp_quest_grind_melee",
        }
      end

      -- No hostiles: ask for interact with giver/ender if entity known.
      if active.entity_id and active.entity_id > 0 then
        return {
          kind = "interact_unit",
          unit_id = active.entity_id,
          reason = "interact_quest_npc",
        }
      end

      local have = tonumber(active.item_count) or 0
      return {
        kind = "hold",
        reason = "imp_quest_need_mobs:" .. tostring(have) .. "/" .. tostring(SKULLS_NEEDED),
      }
    end

    -- No offer / active / turn_in in projection: masks or nav not ready.
    if quest.masks_empty then
      return { kind = "hold", reason = "quest_masks_unavailable" }
    end
    return { kind = "hold", reason = "imp_quest_idle" }
  end,
})
