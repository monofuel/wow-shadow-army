-- escort_leader: stay near the party leader and aid combat as a *caster*.
--
-- Warlocks: ranged DPS (DoTs → Shadow Bolt → wand). Dagger auto-attack is
-- last resort only when truly out of mana and Shoot is not offered.
--
-- Priority (each decide):
--   1. Life Tap when mana is critical and HP allows.
--   2. Combat target: warlock rotation from cast mask (never skip cast for
--      rejoin if we can cast on focus).
--   3. Any Shadow Bolt / offensive cast offered on any hostile.
--   4. Assist leader if we still have no focus.
--   5. Rejoin formation only when not mid-cast-cycle on a focus.
--   6. OOM: Shoot, then dagger only if still no ranged option.
--   7. OOC: Demon Skin / Demon Armor.
--
-- Cast list from projection combat.casts (masked only). Coupling isolation:
-- field names owned by brain/frame_projection.py.

local registry = require("registry")

local DEFAULT_NEAR = 8.0
local DEFAULT_FAR = 30.0
-- Stay looser while fighting so we don't walk instead of bolting.
local COMBAT_REJOIN = 28.0
local LIFE_TAP_MANA = 18.0
local LIFE_TAP_MIN_HP = 40.0
-- Below this: prefer wand/dagger over spending for SB.
local OOM_MANA = 8.0

local DOT_PRIORITY = {
  "curse of agony",
  "corruption",
  "immolate",
}
local FILLER_PRIORITY = {
  "shadow bolt",
}
local WAND_PRIORITY = {
  "shoot",
}
local BUFF_PRIORITY = {
  "demon skin",
  "demon armor",
}

local function dist2(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

local function has_z(u)
  return u and u.z ~= nil
end

-- Same floor: stock `follow` (unit-tracking). Destination `move` freezes a
-- world point from the decision frame, so bots chase where the leader *was*
-- (~cadence lag). Only pin x/y/z when floors diverge — stock follow fails
-- there with "client terrain floor diverges"; navmesh destination works.
local VERTICAL_DEST_DZ = 2.5

local function rejoin_intent(leader, me, near, far, d2, reason)
  local urgent = d2 > far * far
  local intent = {
    kind = "move_to_unit",
    unit_id = leader.id,
    stop_range = near,
    urgent = urgent,
    reason = reason or "rejoin_formation",
  }
  local need_dest = false
  if has_z(leader) and me and has_z(me) then
    local dz = leader.z - me.z
    if dz < 0 then dz = -dz end
    need_dest = dz > VERTICAL_DEST_DZ
  end
  if need_dest then
    intent.x = leader.x
    intent.y = leader.y
    intent.z = leader.z
    if leader.map_id ~= nil then
      intent.map_id = leader.map_id
    elseif me.map_id ~= nil then
      intent.map_id = me.map_id
    else
      intent.map_id = 0
    end
    intent.reason = (reason or "rejoin_formation") .. "_vertical"
  end
  return intent
end

local function guid_nonzero(g)
  if g == nil then return false end
  local s = tostring(g)
  return s ~= "" and s ~= "0"
end

local function lower(s)
  return tostring(s or ""):lower()
end

local function name_matches(spell_name, want)
  local n = lower(spell_name)
  local w = lower(want)
  return n == w or n:find(w, 1, true) ~= nil
end

local function find_attackable_by_guid(attackable, guid)
  if not attackable or not guid_nonzero(guid) then return nil end
  local want = tostring(guid)
  for i = 1, #attackable do
    local u = attackable[i]
    if u and tostring(u.guid) == want then
      return u
    end
  end
  return nil
end

local function pick_cast(casts, target_id, priority)
  if not casts then return nil end
  for pi = 1, #priority do
    local want = priority[pi]
    for i = 1, #casts do
      local c = casts[i]
      if c and c.target == target_id and name_matches(c.name, want) then
        return c
      end
    end
  end
  return nil
end

local function pick_self_cast(casts, priority)
  return pick_cast(casts, 0, priority)
end

local function is_offensive_cast(c)
  if not c or not c.target or c.target <= 0 then return false end
  local n = lower(c.name)
  if name_matches(n, "shadow bolt") then return true end
  if name_matches(n, "corruption") then return true end
  if name_matches(n, "immolate") then return true end
  if name_matches(n, "curse of agony") then return true end
  if name_matches(n, "shoot") then return true end
  if name_matches(n, "drain") then return true end
  if name_matches(n, "searing pain") then return true end
  return false
end

local function warlock_rotation(casts, target_id, mana_pct)
  if (mana_pct or 100) < OOM_MANA then
    local wand = pick_cast(casts, target_id, WAND_PRIORITY)
    if wand then return wand, "wand_oom" end
    return nil, nil
  end
  local dot = pick_cast(casts, target_id, DOT_PRIORITY)
  if dot then return dot, "apply_dot" end
  local bolt = pick_cast(casts, target_id, FILLER_PRIORITY)
  if bolt then return bolt, "shadow_bolt" end
  local wand = pick_cast(casts, target_id, WAND_PRIORITY)
  if wand then return wand, "wand" end
  return nil, nil
end

local function cast_intent(c, why)
  return {
    kind = "cast_spell",
    unit_id = c.target,
    spell = c.spell,
    reason = (why or "cast") .. ":" .. lower(c.name),
  }
end

local function any_offensive_on_target(casts, target_id)
  for i = 1, #casts do
    local c = casts[i]
    if c and c.target == target_id and is_offensive_cast(c) then
      return c
    end
  end
  return nil
end

local function any_shadow_bolt(casts)
  for i = 1, #casts do
    local c = casts[i]
    if c and c.target and c.target > 0 and name_matches(c.name, "shadow bolt") then
      return c
    end
  end
  return nil
end

local function any_offensive(casts)
  for i = 1, #casts do
    local c = casts[i]
    if is_offensive_cast(c) then
      return c
    end
  end
  return nil
end

return registry.register({
  name = "escort_leader",
  when = "In party with a human leader: keep formation and ranged-DPS their target.",
  decide = function(frame, args)
    args = args or {}
    local near = args.near or DEFAULT_NEAR
    local far = args.far or DEFAULT_FAR
    local me = frame.self_unit
    local leader = frame.party and frame.party.leader_unit
    local combat = frame.combat or {}
    local casts = combat.casts or {}
    local mana = combat.mana_pct or 100
    local hp = combat.health_pct or 100

    if not me then return nil end
    if not leader or not leader.visible then
      return { kind = "hold", reason = "leader_not_visible" }
    end

    -- Resolve combat target early so we can cast before walking.
    -- Only trust focus_id when we still have casts or attack mask on it
    -- (stale focus after a kill was freezing us on wait_cast_mask forever).
    local prefer = combat.auto_attack_guid
    if not guid_nonzero(prefer) then
      prefer = combat.focus_guid
    end
    local focused = find_attackable_by_guid(combat.attackable, prefer)
    local target_id = focused and focused.id or nil
    if (not target_id or target_id == 0) and combat.focus_id and combat.focus_id > 0 then
      local fid = combat.focus_id
      local has_cast = any_offensive_on_target(casts, fid) ~= nil
      local still_attackable = false
      for i = 1, #(combat.attackable or {}) do
        local u = combat.attackable[i]
        if u and u.id == fid then
          still_attackable = true
          break
        end
      end
      if has_cast or still_attackable or combat.in_combat then
        target_id = fid
      end
    end

    -- Life Tap before everything else when dry (not a dagger problem).
    if mana < LIFE_TAP_MANA and hp >= LIFE_TAP_MIN_HP then
      local tap = pick_self_cast(casts, { "life tap" })
      if tap then
        return cast_intent(tap, "life_tap")
      end
    end

    -- === Ranged DPS first (this is the warlock job) ===
    if target_id and target_id > 0 then
      local cast, why = warlock_rotation(casts, target_id, mana)
      if cast then
        return cast_intent(cast, why)
      end
      local any = any_offensive_on_target(casts, target_id)
      if any then
        return cast_intent(any, "cast_any")
      end
    end

    -- NO free-fire on random hostiles (shadow_bolt_any pulled rats).
    -- Only leader-mirrored focus / auto-attack target above.

    -- No cast this frame but we have mana: re-acquire target, do NOT dagger.
    if mana >= OOM_MANA then
      local d2 = dist2(me, leader)
      local fighting = combat.in_combat or (target_id and target_id > 0)
      local rejoin_limit = fighting and COMBAT_REJOIN or near
      -- Vertical separation counts as "far" even when 2D is small (crypt).
      local dz = 0
      if has_z(me) and has_z(leader) then
        dz = leader.z - me.z
        if dz < 0 then dz = -dz end
      end
      if d2 > rejoin_limit * rejoin_limit or dz > 2.5 then
        return rejoin_intent(leader, me, near, far, d2, "rejoin_formation")
      end
      if d2 > near * near then
        return rejoin_intent(leader, me, near, far, d2, "rejoin_formation")
      end
      -- Focus/GCD with no cast: re-assist to refresh target, never freeze.
      if target_id and target_id > 0 and leader.assistable then
        return {
          kind = "assist_unit",
          unit_id = leader.id,
          reason = "refresh_target",
        }
      end
      if not combat.in_combat then
        local buff = pick_self_cast(casts, BUFF_PRIORITY)
        if buff then
          return cast_intent(buff, "self_buff")
        end
      end
      if (not target_id or target_id == 0) and leader.assistable then
        return {
          kind = "assist_unit",
          unit_id = leader.id,
          reason = "mirror_leader_target",
        }
      end
      return { kind = "hold", reason = "in_formation" }
    end

    -- === Truly OOM: wand on focus only, then dagger only ===
    if target_id and target_id > 0 then
      local wand = pick_cast(casts, target_id, WAND_PRIORITY)
      if wand then
        return cast_intent(wand, "wand_oom")
      end
      if focused then
        return {
          kind = "attack_unit",
          unit_id = focused.id,
          reason = "dagger_oom_only",
        }
      end
    end

    if leader.assistable then
      return {
        kind = "assist_unit",
        unit_id = leader.id,
        reason = "mirror_leader_target",
      }
    end

    if not combat.in_combat then
      local buff = pick_self_cast(casts, BUFF_PRIORITY)
      if buff then
        return cast_intent(buff, "self_buff")
      end
    end

    local d2 = dist2(me, leader)
    local dz = 0
    if has_z(me) and has_z(leader) then
      dz = leader.z - me.z
      if dz < 0 then dz = -dz end
    end
    if d2 > near * near or dz > 2.5 then
      return rejoin_intent(leader, me, near, far, d2, "rejoin_formation")
    end

    return { kind = "hold", reason = "in_formation" }
  end,
})
