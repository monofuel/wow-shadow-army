-- Earned talent progression for the home escort seats.
--
-- Contract (lua-bot host with view.learn_talent_supported == true):
--   view.talent_points_known / unspent_talent_points / talent_tabs (TalentTab
--   order 0,1,2) / talent_tab_points / talent_ranks / talent_choices.
--   talent_choices is the client's own learnability verdict: tier,
--   prerequisite and rank limit are already applied and are NOT observed
--   separately (view.talent_limits_known == false). This module never infers
--   eligibility; it only picks among observed choices.
--   {kind="learn_talent", talent_id, rank} names the zero-based current rank,
--   so repeating it after the rank moved clicks nothing.
--   wow.talent_progress() reports the host's last outcome and a reason.
--
-- Build targets come from a private local profile, indexed by tab position
-- and talent_index. They are not bundled with this original policy code.
-- The dominant observed tree preserves existing allocations; before any
-- point is spent, the party role selects the tree.

local M = {}

-- Retry a blocked/failed (talent, rank) no sooner than this; the host already
-- bounds its own clicks, this keeps the seat from re-asking every tick.
local BLOCKED_BACKOFF_SECONDS = 60
-- A request with no host progress for this long is abandoned and reported.
local PENDING_STALE_SECONDS = 45

-- Role default spec tab position (0-based), used only while no point is spent.
local ROLE_SPEC = {
  [1] = { tank = 2, dps = 0 },   -- warrior: Protection for the escort tank
  [5] = { healer = 1, dps = 2 }, -- priest: Holy
  [9] = { dps = 0 },             -- warlock: Affliction
}

-- Optional local data: BUILDS[class][spec position][tab position] contains
-- per-talent_index target ranks. Missing data banks points and reports a gap.
local builds_ok, BUILDS = pcall(require, "config.talent_builds_private")
if not builds_ok or type(BUILDS) ~= "table" then BUILDS = {} end

function M.new_state()
  return { pending = nil, backoff = {}, last = nil }
end

local function key(id, rank) return tostring(id) .. ":" .. tostring(rank) end

local function observed_rank(view, talent_id)
  for _, row in ipairs(view.talent_ranks or {}) do
    if row.talent_id == talent_id then return row.rank end
  end
  return 0
end

-- The spec tab position and how it was chosen, or nil and the gap.
function M.spec_tab(view, role)
  local points = view.talent_tab_points or {}
  if view.talent_tab_points_known ~= true or #points ~= 3 then
    return nil, "tab_points_unknown"
  end
  local best, total = 0, 0
  for i = 1, 3 do
    total = total + (points[i] or 0)
    if (points[i] or 0) > (points[best + 1] or 0) then best = i - 1 end
  end
  if total > 0 then return best, "observed_build" end
  local defaults = ROLE_SPEC[view.class_id]
  local tab = defaults and (defaults[role] or defaults.dps)
  if tab == nil then return nil, "no_plan_for_class" end
  return tab, "role_default"
end

-- The observed choice the plan wants next, or nil and the concrete gap.
function M.pick(view, role)
  if not builds_ok then return nil, "private_build_plan_unavailable" end
  local build = BUILDS[view.class_id]
  if not build then return nil, "no_plan_for_class" end
  local spec, why = M.spec_tab(view, role)
  if spec == nil then return nil, why end
  local targets = build[spec]
  if type(targets) ~= "table" then return nil, "no_plan_for_observed_tree" end
  local position = {}
  for i, tab in ipairs(view.talent_tabs or {}) do position[tab.tab_id] = i - 1 end
  local best, best_order
  for _, c in ipairs(view.talent_choices or {}) do
    local pos = position[c.tab_id]
    local plan = pos ~= nil and targets[pos + 1] or ""
    local want = tonumber(plan:sub(c.talent_index + 1, c.talent_index + 1)) or 0
    if want > c.rank then
      -- Spec tab first, then tier order (talent_index), then id.
      local order = { pos == spec and 0 or 1, c.talent_index, c.talent_id }
      local better = best == nil
      if not better then
        for i = 1, 3 do
          if order[i] ~= best_order[i] then better = order[i] < best_order[i]; break end
        end
      end
      if better then best, best_order = c, order end
    end
  end
  if best == nil then return nil, "no_planned_choice_observed" end
  return best, why
end

-- One talent intent, or nil to let the seat do its normal work. Callers run
-- it only where the seat is idle: out of combat, not dead, no active cast or
-- channel, not following a moving leader, after the owner's requests.
function M.step(view, state, now, role)
  if view.learn_talent_supported ~= true then return nil end
  if view.in_combat or view.is_dead or view.is_ghost or
      (view.active_cast_spell_id or 0) ~= 0 or
      (view.active_channel_spell_id or 0) ~= 0 then
    return nil
  end
  local progress = wow.talent_progress and wow.talent_progress() or { state = "idle" }
  local p = state.pending
  if p then
    if observed_rank(view, p.talent_id) > p.rank then
      -- Acknowledged by the observed rank, not by the click.
      state.last = { state = "learned", talent_id = p.talent_id, rank = p.rank }
      state.pending = nil
    elseif progress.talent_id == p.talent_id and progress.rank == p.rank and
        (progress.state == "blocked" or progress.state == "failed" or
          progress.state == "cancelled") then
      state.backoff[key(p.talent_id, p.rank)] = now + BLOCKED_BACKOFF_SECONDS
      state.last = { state = progress.state, reason = progress.reason,
        talent_id = p.talent_id, rank = p.rank }
      state.pending = nil
      return nil
    elseif now - p.since > PENDING_STALE_SECONDS then
      state.backoff[key(p.talent_id, p.rank)] = now + BLOCKED_BACKOFF_SECONDS
      state.last = { state = "stale", reason = "no acknowledgement",
        talent_id = p.talent_id, rank = p.rank }
      state.pending = nil
      return nil
    else
      return { kind = "learn_talent", talent_id = p.talent_id, rank = p.rank,
        reason = "talent_pending" }
    end
  end
  if view.talent_points_known ~= true then
    state.last = { state = "gap", reason = "talent_points_unknown" }
    return nil
  end
  if (view.unspent_talent_points or 0) == 0 then return nil end
  local choice, why = M.pick(view, role)
  if choice == nil then
    -- Bank the point and say why; never fall back to an unplanned spend.
    state.last = { state = "gap", reason = why }
    return nil
  end
  local until_at = state.backoff[key(choice.talent_id, choice.rank)]
  if until_at and now < until_at then return nil end
  state.pending = { talent_id = choice.talent_id, rank = choice.rank, since = now }
  return { kind = "learn_talent", talent_id = choice.talent_id,
    rank = choice.rank, reason = "talent_" .. why }
end

function M.status(view, state)
  local last = state.last or {}
  return {
    unspent = view.talent_points_known and view.unspent_talent_points or -1,
    state = state.pending and "pending" or (last.state or "idle"),
    reason = last.reason or "",
    talent_id = (state.pending or last).talent_id or 0,
  }
end

return M
