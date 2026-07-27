-- grind_nearest: outdoor XP grind — approach + kill nearest hostile; cast if offered.
-- Used for army level floor (v2). No free-fire on party; no quest FSM here.
--
-- Footgun fixed: stale combat_focus at 20–30y caused endless out-of-range
-- melee selects with zero XP. Prefer nearest unit; move when beyond melee.

local registry = require("registry")

-- Beyond this: issue destination hop. Inside this: attack/cast so the client
-- combat pathing closes remaining yards (pure melee at 25y never connects;
-- pure approach often settles short of 5y and never swings).
local APPROACH_RANGE = 12.0
local APPROACH_RANGE2 = APPROACH_RANGE * APPROACH_RANGE

local function dist2(a, b)
  if not a or not b or not a.x or not b.x or not a.y or not b.y then
    return nil
  end
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

local function lower(s)
  return tostring(s or ""):lower()
end

local function name_matches(n, want)
  n, want = lower(n), lower(want)
  return n == want or n:find(want, 1, true) ~= nil
end

local function nearest(me, attackable)
  if not attackable then return nil end
  local best, best_d2 = nil, nil
  for i = 1, #attackable do
    local u = attackable[i]
    if u and u.id and u.id > 0 and not u.lootable then
      local d2 = dist2(me, u)
      if d2 ~= nil then
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

local function pick_cast(casts, tid)
  if not casts or not tid then return nil end
  local prio = {
    "curse of agony", "corruption", "immolate", "shadow bolt",
    "smite", "shadow word: pain", "heroic strike", "shoot",
  }
  for pi = 1, #prio do
    for i = 1, #casts do
      local c = casts[i]
      if c and c.target == tid and name_matches(c.name, prio[pi]) then
        return c
      end
    end
  end
  for i = 1, #casts do
    local c = casts[i]
    if c and c.target == tid then return c end
  end
  return nil
end

-- v2 frames carry no per-target cast mask — the tool owns the spell table.
-- One nuke family per class, highest known rank first, skipped on cooldown
-- or when mana is dry (melee still lands XP).
local NUKES_BY_CLASS = {
  [9] = { 705, 695, 686 }, -- warlock: Shadow Bolt r3/r2/r1
  [5] = { 591, 585 },      -- priest: Smite r2/r1
  [8] = { 143, 133 },      -- mage: Fireball r2/r1
}
local MIN_CAST_MANA_PCT = 10.0

local function pick_nuke(frame, tid)
  local class_id = frame.self_unit and frame.self_unit.class_id
  local prio = class_id and NUKES_BY_CLASS[class_id]
  if not prio then return nil end
  local sp = frame.spells or {}
  if (sp.mana_pct or 100.0) < MIN_CAST_MANA_PCT then return nil end
  local known, cooling = {}, {}
  for i = 1, #(sp.known or {}) do known[sp.known[i]] = true end
  for i = 1, #(sp.cooldowns or {}) do cooling[sp.cooldowns[i]] = true end
  for i = 1, #prio do
    local id = prio[i]
    if known[id] and not cooling[id] then
      return { kind = "cast_spell", unit_id = tid, spell = id,
               reason = "grind_cast:" .. id }
    end
  end
  return nil
end

return registry.register({
  name = "grind_nearest",
  when = "Solo outdoor grind: kill nearest attackable for XP.",
  decide = function(frame, args)
    args = args or {}
    local me = frame.self_unit
    local combat = frame.combat or {}
    local death = frame.death or {}
    if death.is_dead and not death.is_ghost then
      if death.can_release_spirit then
        return { kind = "release_spirit", reason = "release" }
      end
      return { kind = "hold", reason = "dead" }
    end
    if death.is_ghost then
      if death.can_reclaim_corpse and death.can_reclaim_action then
        return { kind = "reclaim_corpse", reason = "reclaim" }
      end
      if death.can_move and death.corpse then
        return {
          kind = "move_to_corpse",
          map_id = death.corpse.map_id or 0,
          x = death.corpse.x, y = death.corpse.y, z = death.corpse.z,
          reason = "corpse",
        }
      end
      return { kind = "hold", reason = "ghost" }
    end
    if not me then return nil end

    -- Loot before pulling the next (quest drops / XP packs). loot_unit maps
    -- to the executor's auto-loot flow; interact only opens the window and
    -- leaves the corpse lootable forever (live loop, 2026-07-27).
    local lootables = combat.lootable or frame.lootable or {}
    if type(lootables) == "table" then
      for i = 1, #lootables do
        local u = lootables[i]
        if u and u.id and u.id > 0 then
          return { kind = "loot_unit", unit_id = u.id, reason = "loot" }
        end
      end
    end
    for i = 1, #(combat.attackable or {}) do
      local u = combat.attackable[i]
      if u and u.lootable and u.id and u.id > 0 then
        return { kind = "loot_unit", unit_id = u.id, reason = "loot_corpse" }
      end
    end

    local casts = combat.casts or {}
    -- Always prefer nearest living hostile over a stale far focus.
    local focused, d2 = nearest(me, combat.attackable)
    if not focused then
      -- Fall back to focus only if projection has no coords.
      local target_id = combat.focus_id
      if target_id and target_id > 0 then
        for i = 1, #(combat.attackable or {}) do
          local u = combat.attackable[i]
          if u and u.id == target_id and not u.lootable then
            focused = u
            break
          end
        end
      end
    end
    if not focused or not focused.id or focused.id <= 0 then
      return { kind = "hold", reason = "no_hostile" }
    end
    local target_id = focused.id
    if d2 == nil then
      d2 = dist2(me, focused)
    end

    -- Far hostiles: hop closer first. Near: attack/cast (client paths in).
    local far = false
    if type(d2) == "number" and type(APPROACH_RANGE2) == "number" then
      far = d2 > APPROACH_RANGE2
    end
    if far and focused.x and focused.y then
      return {
        kind = "move_to_unit",
        unit_id = target_id,
        map_id = focused.map_id or me.map_id or 0,
        x = focused.x,
        y = focused.y,
        z = focused.z or me.z or 0,
        reason = "approach_hostile",
      }
    end

    local nuke = pick_nuke(frame, target_id)
    if nuke then return nuke end
    local cast = pick_cast(casts, target_id)
    if cast then
      return {
        kind = "cast_spell",
        unit_id = cast.target,
        spell = cast.spell,
        reason = "grind_cast:" .. lower(cast.name),
      }
    end
    return {
      kind = "attack_unit",
      unit_id = target_id,
      reason = "grind_melee",
    }
  end,
})
