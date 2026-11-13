-- ShadowArmy — advisor v0.1: draggable HUD panel (grind stats + target
-- intel + action buttons) on top of the hello-world plumbing.
-- 1.12 (Lua 5.0) addon: no protected functions, vararg via arg table,
-- event args via global event/arg1/arg2. Keep everything addon-local
-- except the single ShadowArmy root.

ShadowArmy = ShadowArmy or {}

-- Pure live quest checklist + optional waypoint enrichment. This lives in
-- the already-loaded core file because vanilla caches the TOC file list for
-- the whole client session; adding a new Lua filename would require a client
-- restart instead of the advisor's automatic ReloadUI path.
local QuestModel = {}

-- Lua 5.0 has table.getn but no # operator; Lua 5.3 tests have # but removed
-- table.getn. Walking dense arrays is valid in both.
local function questGetn(t)
  local n = 0
  while t[n + 1] ~= nil do n = n + 1 end
  return n
end

QuestModel.colors = {
  {0.85, 0.40, 1.00}, {0.20, 0.90, 1.00},
  {1.00, 0.55, 0.12}, {1.00, 0.88, 0.20},
  {1.00, 0.40, 0.65}, {0.35, 0.65, 1.00},
  {0.35, 1.00, 0.50}, {1.00, 0.40, 0.35},
}

local function questLower(s) return string.lower(s or "") end

local function questMatchObjective(objectives, board, idx)
  if not objectives then return nil end
  local text = questLower(board and board.text)
  local i = 1
  while i <= questGetn(objectives) do
    local label = objectives[i].label
    if label and string.find(text, questLower(label), 1, true) then
      return objectives[i]
    end
    i = i + 1
  end
  return objectives[idx]
end

local function questZoneHere(q, spotZone, header, currentZone, zoneNames)
  if currentZone == "" then return false end
  if spotZone and zoneNames and zoneNames[spotZone] == currentZone then
    return true
  end
  if header == currentZone and q then
    return (not spotZone) or spotZone == q.zone
  end
  return false
end

-- WorldMapArea (map 0). mx=(L-wy)/(L-R)*100  my=(T-wx)/(T-B)*100
-- wy=L-mx/100*(L-R)  wx=T-my/100*(T-B)
local QUEST_WMA = {
  [85] = { L = 3033.3, R = -1485.4, T = 3837.5, B = 825.0 },
  [1497] = { L = 873.2, R = -86.2, T = 1877.9, B = 1237.8 },
}

local QUEST_CITY_PARENT = {
  [1497] = 85,
}

local function questOverlayLinked(a, b)
  return a and b and (QUEST_CITY_PARENT[a] == b or QUEST_CITY_PARENT[b] == a)
end

local function questZoneIdByName(name, zoneNames)
  if not name or name == "" or not zoneNames then return nil end
  local found = nil
  for id, n in pairs(zoneNames) do
    if n == name and ((not found) or id < found) then
      found = id
    end
  end
  return found
end

local function questOverlayPercent(fromZone, x, y, toZone)
  if not fromZone or not toZone or fromZone == toZone then return nil end
  if not questOverlayLinked(fromZone, toZone) then return nil end
  if not x or not y then return nil end
  local src, dst = QUEST_WMA[fromZone], QUEST_WMA[toZone]
  if not src or not dst then return nil end
  local wy = src.L - (x / 100) * (src.L - src.R)
  local wx = src.T - (y / 100) * (src.T - src.B)
  local mx = (dst.L - wy) / (dst.L - dst.R) * 100
  local my = (dst.T - wx) / (dst.T - dst.B) * 100
  if mx >= 0 and mx <= 100 and my >= 0 and my <= 100 then
    return mx, my
  end
  return nil
end

local function questLocalSpot(q, spotZone, x, y, header, currentZone, zoneNames)
  if not x or not y then return nil end
  local hereId = questZoneIdByName(currentZone, zoneNames)
  if spotZone and hereId and spotZone ~= hereId then
    local mx, my = questOverlayPercent(spotZone, x, y, hereId)
    if mx then return mx, my end
  end
  if questZoneHere(q, spotZone, header, currentZone, zoneNames) then
    return x, y
  end
  return nil
end

local function questDistance(x, y, px, py, yardsX, yardsY)
  local dx = x - px
  local dy = y - py
  local ux = dx / 100 * yardsX
  local uy = dy / 100 * yardsY
  return math.sqrt(ux * ux + uy * uy), dx, dy
end

local function questModelListCmp(a, b)
  if a.tracked ~= b.tracked then return a.tracked end
  if a.minDist ~= b.minDist then return a.minDist < b.minDist end
  return a.logOrder < b.logOrder
end

local function questModelCandCmp(a, b)
  if a.dist ~= b.dist then return a.dist < b.dist end
  if a.qNum ~= b.qNum then return a.qNum < b.qNum end
  return a.seq < b.seq
end

-- Injected API keeps collapsed-header and selection restoration testable
-- without loading the WoW UI.
function QuestModel.readLog(api)
  local selectedIndex = api.selection and api.selection() or 0
  local selectedTitle = nil
  if selectedIndex > 0 then
    local title, _, _, isHeader = api.title(selectedIndex)
    if not isHeader then selectedTitle = title end
  end

  local collapsed = {}
  if api.expand then
    local i = 1
    while i <= (api.numEntries() or 0) do
      local title, _, _, isHeader, isCollapsed = api.title(i)
      if isHeader and isCollapsed then
        title = title or ""
        collapsed[title] = (collapsed[title] or 0) + 1
        api.expand(i)
      end
      i = i + 1
    end
  end

  local live, sig = {}, ""
  local ok, err = pcall(function()
    local watched = api.watched and api.watched() or {}
    local header = ""
    local i = 1
    while i <= (api.numEntries() or 0) do
      local title, _, _, isHeader, _, isComplete = api.title(i)
      if isHeader then
        header = title or ""
      elseif title then
        local boards, nb = api.boards(i)
        local objectives = {}
        local bi = 1
        while bi <= nb do
          objectives[bi] = boards[bi]
          sig = sig .. ":" .. (boards[bi].text or "")
          bi = bi + 1
        end
        live[questGetn(live) + 1] = {
          key = i, title = title, header = header,
          tracked = watched[i] and true or false,
          complete = isComplete == 1,
          failed = isComplete == -1,
          objectives = objectives,
        }
        local state = isComplete == 1 and "!" or (isComplete == -1 and "x" or "-")
        sig = sig .. "|" .. title .. state
      end
      i = i + 1
    end
  end)

  if api.collapse then
    local i = api.numEntries() or 0
    while i >= 1 do
      local title, _, _, isHeader = api.title(i)
      if isHeader and collapsed[title or ""] and collapsed[title or ""] > 0 then
        collapsed[title or ""] = collapsed[title or ""] - 1
        api.collapse(i)
      end
      i = i - 1
    end
  end
  if api.select then
    local restored = false
    if selectedTitle and selectedTitle ~= "" then
      local i = 1
      while i <= (api.numEntries() or 0) do
        local title, _, _, isHeader = api.title(i)
        if not isHeader and title == selectedTitle then
          api.select(i)
          restored = true
          break
        end
        i = i + 1
      end
    end
    if not restored and selectedIndex > 0 and selectedIndex <= (api.numEntries() or 0) then
      api.select(selectedIndex)
    end
  end
  if not ok then error(err) end
  return live, sig
end

-- Vanilla reuses quest TITLES across chain steps ("Fields of Grief" is both
-- the pumpkin gathering and the tavern delivery that follows it), and 1.12
-- never exposes quest ids to addons — so the generated data carries every
-- same-title variant (primary + alts) and the live leaderboard labels decide
-- which variant a log entry actually is. A variant earns points for each of
-- its objective labels found in the live board text and loses one for each
-- label the log does not show; boards keep their labels after completion, so
-- a ready-to-turn-in part 2 still resolves away from part 1's turn-in NPC.
local function questVariantScore(v, boards, nb)
  local objs = v.objectives or {}
  local nObj = questGetn(objs)
  local score = 0
  local oi = 1
  while oi <= nObj do
    local label = objs[oi].label
    local hit = false
    if label then
      local want = string.lower(label)
      local bi = 1
      while bi <= nb do
        if string.find(string.lower(boards[bi].text or ""), want, 1, true) then
          hit = true
          break
        end
        bi = bi + 1
      end
    end
    if hit then score = score + 2 else score = score - 1 end
    oi = oi + 1
  end
  return score
end

-- Identity gating (ticket 0045). Labels cannot separate the big alt groups:
-- L60 faction/city mirrors (donation quests x8 cities, commendation signets,
-- Deliana/Mokvar pairs) share a title AND an empty objective set, so the
-- label score is a tie and the primary wins by default — which is how a
-- turn-in marker ends up pointing at the other faction's city. The game
-- itself gates those on race/class, so the player's own identity is the
-- discriminator the labels never had.
--
-- The generator emits per-variant `races` / `classes` bitmasks from
-- quest_template RequiredRaces / RequiredClasses (bit = 1 << (id - 1),
-- documented in docs/world-db-queries.md) and OMITS the field when the
-- column is 0 = "anyone". So an absent mask is not "no data", it is "no
-- gate": a maskless variant always survives the filter.
--
-- Lua 5.0 has no bitwise operators and no `%` operator, and 5.3 dropped
-- math.mod, so every mask test below is plain float arithmetic both hosts
-- agree on.
QuestModel.CLASS_ID = {
  WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5,
  SHAMAN = 7, MAGE = 8, WARLOCK = 9, DRUID = 11,
}

-- 1.12 UnitRace gives the localized name on this build; the CamelCase token
-- (2.0+) is accepted too so the same table serves both. "Undead" and
-- "Scourge" are the same race id.
QuestModel.RACE_ID = {
  Human = 1, Orc = 2, Dwarf = 3, NightElf = 4, Scourge = 5,
  Tauren = 6, Gnome = 7, Troll = 8, Undead = 5,
}

-- These three hang off QuestModel rather than being file locals on purpose:
-- the main chunk's register peak is the scarce resource in this file (see the
-- 200-locals note further down), and none of them is on a per-frame path.
function QuestModel.maskBit(id)
  if not id or id < 1 then return nil end
  local bit, i = 1, 1
  while i < id do
    bit = bit * 2
    i = i + 1
  end
  return bit
end

-- Does this gate let the player through? An absent / 0 / -1 mask is
-- "anyone"; an UNKNOWN player bit also passes, because a filter that cannot
-- see the player must not throw variants away.
function QuestModel.maskAllows(mask, bit)
  if not mask or mask <= 0 then return true end
  if not bit then return true end
  local shifted = math.floor(mask / bit)
  return math.floor(shifted / 2) * 2 ~= shifted
end

function QuestModel.variantAllowed(v, ident)
  if not v then return false end
  if not ident then return true end
  return QuestModel.maskAllows(v.races, ident.race)
    and QuestModel.maskAllows(v.classes, ident.class)
end

-- Tokens in, mask bits out. UnitRace/UnitClass are read in the UI half and
-- the result is passed into the model, so resolve stays pure and lua/tests
-- can drive any identity it likes. nil when neither token is recognized —
-- which makes resolve behave exactly as it did before identity existed.
function QuestModel.identity(raceToken, classToken)
  local rid, cid = nil, nil
  if raceToken then
    rid = QuestModel.RACE_ID[raceToken]
    if not rid then
      local squashed = string.gsub(raceToken, " ", "")
      rid = QuestModel.RACE_ID[squashed]
    end
  end
  if classToken then
    cid = QuestModel.CLASS_ID[string.upper(classToken)]
  end
  if not rid and not cid then return nil end
  return { race = QuestModel.maskBit(rid), class = QuestModel.maskBit(cid) }
end

-- identity = { race = <player race bit>, class = <player class bit> } or nil.
-- Order: identity filter -> lone survivor wins outright -> label score over
-- the survivors -> tie keeps the primary (the survivor list preserves
-- primary-first order and only a STRICTLY better score displaces it).
function QuestModel.resolve(q, boards, identity)
  if not q or not q.alts then return q end
  boards = boards or {}
  local nb = questGetn(boards)
  local variants, n = { q }, 1
  local nAlts = questGetn(q.alts)
  local ai = 1
  while ai <= nAlts do
    n = n + 1
    variants[n] = q.alts[ai]
    ai = ai + 1
  end

  if identity then
    local kept, nk = {}, 0
    local i = 1
    while i <= n do
      if QuestModel.variantAllowed(variants[i], identity) then
        nk = nk + 1
        kept[nk] = variants[i]
      end
      i = i + 1
    end
    -- Masks that exclude EVERY variant mean the data is wrong about this
    -- player, not that the quest is unanswerable: keep the unfiltered list
    -- and let the labels decide, same as before identity existed.
    if nk > 0 then
      variants, n = kept, nk
      if n == 1 then return variants[1] end
    end
  end

  local best = variants[1]
  local bestScore = questVariantScore(best, boards, nb)
  local vi = 2
  while vi <= n do
    local score = questVariantScore(variants[vi], boards, nb)
    if score > bestScore then best, bestScore = variants[vi], score end
    vi = vi + 1
  end
  return best
end

function QuestModel.build(opts)
  opts = opts or {}
  local live = opts.quests or {}
  local data = opts.data or {}
  local zoneNames = opts.zoneNames
  local currentZone = opts.currentZone or ""
  local pos = opts.pos
  local yardsX = opts.yardsX or 3500
  local yardsY = opts.yardsY or 2333
  local palette = opts.colors or QuestModel.colors
  -- { race = bit, class = bit } from QuestModel.identity; nil = no filtering.
  local identity = opts.identity
  local nColors = questGetn(palette)
  local list, candidates = {}, {}
  local seq = 0

  local qi = 1
  while qi <= questGetn(live) do
    local lq = live[qi]
    local color = palette[((qi - 1) - math.floor((qi - 1) / nColors) * nColors) + 1]
    local entry = {
      key = lq.key or qi, num = qi, title = lq.title or "?",
      tracked = lq.tracked and true or false,
      complete = lq.complete and true or false,
      failed = lq.failed and true or false,
      logOrder = qi, r = color[1], g = color[2], b = color[3],
      minDist = 1e9, objs = {},
    }
    local q = QuestModel.resolve(data[entry.title], lq.objectives, identity)

    if entry.complete then
      local obj = {
        label = "Ready to turn in", text = "Ready to turn in",
        done = true, turnIn = true,
      }
      local w = q and q.turnIn
      if w then
        obj.label = w.label or obj.label
        obj.text = "Turn in: " .. obj.label
        obj.zoneName = zoneNames and w.zone and zoneNames[w.zone] or nil
        local lx, ly = questLocalSpot(
          q, w.zone, w.x, w.y, lq.header or "", currentZone, zoneNames)
        if pos and lx then
          obj.zoneName = currentZone
          obj.dist, obj.dx, obj.dy = questDistance(
            lx, ly, pos.x, pos.y, yardsX, yardsY)
          entry.minDist = obj.dist
          seq = seq + 1
          candidates[questGetn(candidates) + 1] = {
            questKey = entry.key, title = entry.title, label = obj.label,
            x = lx, y = ly, dx = obj.dx, dy = obj.dy, dist = obj.dist,
            turnIn = true, tracked = entry.tracked, seq = seq,
          }
        end
      end
      entry.objs[1] = obj
    else
      local boards = lq.objectives or {}
      local bi = 1
      local nBoards = questGetn(boards)
      while bi <= nBoards do
        local board = boards[bi]
        local generated = q and questMatchObjective(q.objectives, board, bi) or nil
        local obj = {
          label = (generated and generated.label) or board.text or "Objective",
          text = board.text or (generated and generated.label) or "Objective",
          have = board.have, need = board.need,
          done = board.done and true or false, turnIn = false,
        }
        -- Who drops this item. QuestData emits `from` alphabetically (picked
        -- by spawn density, not drop rate) — never rank it. A finished
        -- objective needs no hunt hint.
        if generated and generated.from and not obj.done then
          obj.from = generated.from
        end
        local spots = generated and generated.spots
        if spots and questGetn(spots) > 0 then
          local first = spots[1]
          obj.zoneName = zoneNames and first.zone and zoneNames[first.zone] or nil
          if pos and not obj.done and not entry.failed then
            local si = 1
            while si <= questGetn(spots) do
              local s = spots[si]
              local lx, ly = questLocalSpot(
                q, s.zone, s.x, s.y, lq.header or "", currentZone, zoneNames)
              if lx then
                local dist, dx, dy = questDistance(
                  lx, ly, pos.x, pos.y, yardsX, yardsY)
                if not obj.dist or dist < obj.dist then
                  obj.dist, obj.dx, obj.dy = dist, dx, dy
                end
                seq = seq + 1
                obj.zoneName = currentZone
                candidates[questGetn(candidates) + 1] = {
                  questKey = entry.key, title = entry.title, label = obj.label,
                  have = obj.have, need = obj.need,
                  x = lx, y = ly, dx = dx, dy = dy, dist = dist,
                  turnIn = false, tracked = entry.tracked, seq = seq,
                }
              end
              si = si + 1
            end
          end
        end
        if obj.dist and obj.dist < entry.minDist then entry.minDist = obj.dist end
        entry.objs[bi] = obj
        bi = bi + 1
      end
      -- r54 (monofuel's Brill log, 2026-08-16): the ender is a map answer for
      -- EVERY accepted quest, not only the ones the client has already flagged
      -- complete. Two of his four quests ("Speak with Sevren", "Delivery to
      -- Silverpine Forest") carry no objectives at all, so the loop above had
      -- nothing to emit and the map came up empty while the turn-in NPC sat
      -- 40 yards away in QuestData. Silence there was a choice, not a limit.
      local w = q and q.turnIn
      local delivered = false
      if w and not entry.failed then
        local dobj = {
          label = w.label or "Turn in",
          text = "Deliver: " .. (w.label or "Turn in"),
          turnIn = true, delivery = true, done = false,
        }
        dobj.zoneName = zoneNames and w.zone and zoneNames[w.zone] or nil
        -- `pending` = objectives are still open, so this pin means "this is
        -- where it ends up", not "go here now". It draws; it never takes the
        -- route line off a live objective (see QuestModel.pickTarget), and the
        -- 8-line panel leaves it to the map.
        local pending = nBoards > 0
        dobj.pending = pending
        local lx, ly = questLocalSpot(
          q, w.zone, w.x, w.y, lq.header or "", currentZone, zoneNames)
        if pos and lx then
          dobj.zoneName = currentZone
          dobj.dist, dobj.dx, dobj.dy = questDistance(
            lx, ly, pos.x, pos.y, yardsX, yardsY)
          seq = seq + 1
          candidates[questGetn(candidates) + 1] = {
            questKey = entry.key, title = entry.title, label = dobj.label,
            x = lx, y = ly, dx = dobj.dx, dy = dobj.dy, dist = dobj.dist,
            turnIn = true, delivery = true, pending = pending,
            tracked = entry.tracked, seq = seq,
          }
          -- Only a quest with nothing else to do sorts by its delivery: a
          -- half-finished kill list must not jump the checklist just because
          -- the turn-in NPC happens to be standing underfoot.
          if (not pending) and dobj.dist < entry.minDist then
            entry.minDist = dobj.dist
          end
        end
        entry.objs[nBoards + 1] = dobj
        delivered = true
      end
      if entry.failed then
        entry.status = "Failed"
      elseif nBoards == 0 and not delivered then
        entry.status = "In progress"
      end
    end
    list[qi] = entry
    qi = qi + 1
  end

  if questGetn(list) > 1 then table.sort(list, questModelListCmp) end
  local byKey = {}
  qi = 1
  while qi <= questGetn(list) do
    list[qi].num = qi
    byKey[list[qi].key] = list[qi]
    qi = qi + 1
  end

  local kept = {}
  local ci = 1
  while ci <= questGetn(candidates) do
    local c = candidates[ci]
    local entry = byKey[c.questKey]
    if entry then
      c.qNum, c.r, c.g, c.b = entry.num, entry.r, entry.g, entry.b
      kept[questGetn(kept) + 1] = c
    end
    ci = ci + 1
  end
  if questGetn(kept) > 1 then table.sort(kept, questModelCandCmp) end
  return { list = list, candidates = kept }
end

-- Which waypoint the route line and the ">>" row serve (r54). Candidates
-- arrive sorted by distance, so "first" always means "nearest".
--
-- Rule: the TOP of the checklist wins when it has a waypoint at all;
-- otherwise the nearest quest that does. The old rule was "first tracked
-- candidate, else candidates[1]" — which is nil the moment the quests that
-- COULD be routed produce no candidate, and nil is exactly what wiped
-- monofuel's map: cross-zone quests contribute nothing, so a log can look
-- full and route to nowhere. A pending delivery is the last resort: it is a
-- pin, not a destination.
function QuestModel.pickTarget(list, cands, n)
  cands = cands or {}
  n = n or questGetn(cands)
  local topTitle = list and list[1] and list[1].title or nil
  local firstOpen, firstPending, topPending = nil, nil, nil
  local i = 1
  while i <= n do
    local c = cands[i]
    if c then
      if c.pending then
        if not firstPending then firstPending = c end
        if topTitle and c.title == topTitle and not topPending then
          topPending = c
        end
      else
        if topTitle and c.title == topTitle then return c end
        if not firstOpen then firstOpen = c end
      end
    end
    i = i + 1
  end
  if firstOpen then return firstOpen end
  if topPending then return topPending end
  return firstPending
end

-- Cross-zone honesty (r54). A quest whose known waypoints all live in another
-- zone gets no pin — correctly: we will not invent a coordinate for a map we
-- are not looking at. But drawing nothing reads as "the advisor lost my
-- quest", which is the half of monofuel's report the pins alone cannot fix.
-- So the destination ZONE NAME, straight out of the data, gets said out loud.
QuestModel.awayMax = 6

function QuestModel.awayRows(list, currentZone, maxN)
  local out = {}
  maxN = maxN or QuestModel.awayMax
  local nList = questGetn(list or {})
  local qi = 1
  while qi <= nList and questGetn(out) < maxN do
    local e = list[qi]
    local objs = e.objs or {}
    local nObj = questGetn(objs)
    local here, away = false, nil
    local oi = 1
    while oi <= nObj do
      local o = objs[oi]
      -- A distance exists only for a waypoint in the zone we are standing in,
      -- so one is enough to make this quest a map quest, not a breadcrumb.
      if o.dist then here = true end
      if o.zoneName and o.zoneName ~= currentZone then
        -- The ender is the better breadcrumb than an objective: it is where
        -- the quest ENDS, which is what "deliver in X" has to mean.
        if (not away) or o.turnIn then away = o end
      end
      oi = oi + 1
    end
    if (not here) and away then
      out[questGetn(out) + 1] = {
        num = e.num, title = e.title, zoneName = away.zoneName,
        label = away.label, turnIn = away.turnIn and true or false,
        r = e.r, g = e.g, b = e.b,
      }
    end
    qi = qi + 1
  end
  return out
end

-- "who do I hunt for this item" hint (ticket 0047). The window has room to
-- spell two names out; the 210px advisor PANEL does not, and monofuel reads
-- objectives on the panel — "Notched Rib 0/5" with no mention of Cracked
-- Skull Soldier is the bug. So the join lives here, in the pure model, with
-- an optional character budget: names are dropped (never wrapped, never
-- clipped mid-word) until the rendered string fits.
--
-- Names arrive alphabetical, so the first is not the "best" one — the cap is
-- line width, nothing more, which is why the dropped ones still show as +N.
QuestModel.fromMaxNames = 2

local function questFromJoin(from, k, n, more)
  local out, i = nil, 1
  while i <= k do
    out = out and (out .. ", " .. from[i]) or from[i]
    i = i + 1
  end
  if not out then return nil end
  if n > k then out = out .. " +" .. (n - k) .. (more or "") end
  return out
end

-- from      array of source names ({} / nil -> nil, "say nothing")
-- maxNames  how many get spelled out at most (default 2)
-- maxChars  optional hard budget for the WHOLE string
-- more      suffix after the "+N" count (" more" for the window, "" for the panel)
function QuestModel.fromText(from, maxNames, maxChars, more)
  -- questGetn indexes its argument unguarded (every other caller feeds it a
  -- built list); this one is reached straight off a live objective, where the
  -- field is simply absent on anything that is not an item objective.
  if not from then return nil end
  local n = questGetn(from)
  if n == 0 then return nil end
  maxNames = maxNames or QuestModel.fromMaxNames
  if maxNames > n then maxNames = n end
  if maxNames < 1 then maxNames = 1 end
  local k = maxNames
  local s = questFromJoin(from, k, n, more)
  while maxChars and k > 1 and string.len(s) > maxChars do
    k = k - 1
    s = questFromJoin(from, k, n, more)
  end
  if maxChars and string.len(s) > maxChars then
    -- One name alone still overflows: hard-clip with the trailing "+" the
    -- rest of the panel uses for a shortened string (see F.questShort).
    if maxChars < 2 then return nil end
    s = string.sub(s, 1, maxChars - 1) .. "+"
  end
  return s
end

QuestModel.overlayPercent = questOverlayPercent
ShadowArmy.questModel = QuestModel

--------------------------------------------------------------------------
-- Pure route model (r45): google-maps pathing over the generated road
-- polylines (RoadData.lua, tools/gen_road_data.py). Roads are freeways —
-- fewer patrols, fewer adds, fewer corpse runs — so a road yard is CHEAPER
-- than an off-road yard and the search happily walks extra distance to use
-- one. Everything here is percent-space arithmetic over plain tables: no WoW
-- API, no frames, no globals, so lua/tests exercises it on host Lua and the
-- bots can reuse the same primitive for quest pathing later.
--
-- Coordinates are zone-normalized percent, the space GetPlayerMapPosition
-- and QuestData already speak. Distances are therefore percent-space
-- euclidean, not yards: a vanilla zone is wider than it is tall (~3:2), so a
-- percent of x is more yards than a percent of y. Every comparison in here is
-- between two numbers in that same space, so the anisotropy cancels out of
-- the decisions and only shows up as a mild preference for north-south road
-- legs — cheap to live with, and it keeps the model unit-free.
--------------------------------------------------------------------------

-- Scoped so its private helpers release their slots at `end`: Lua 5.0 caps a
-- function (the addon file itself counts) at 200 live locals, and this file
-- is a long way down that budget already.
do
  local RouteModel = {}

  -- Same Lua 5.0/5.3 dance as questGetn.
  local function routeGetn(t)
    local n = 0
    while t[n + 1] ~= nil do n = n + 1 end
    return n
  end

  -- Points from DIFFERENT polylines closer than this are the same junction. The
  -- bake cuts a road wherever the mask breaks (bridges, crossings, zone borders),
  -- so without this the network is a pile of disconnected sticks.
  RouteModel.junctionDist = 1.5
  -- Off-road yards cost this much more than road yards. 1.0 would make roads
  -- irrelevant; the higher it goes the more detour the router accepts to reach
  -- one.
  RouteModel.offRoadPenalty = 1.6
  -- Dijkstra settle cap. A zone graph is a few hundred nodes, so hitting this
  -- means something is wrong with the data, and a stuck advisor is worse than a
  -- straight line.
  RouteModel.nodeBudget = 3000
  -- "The road is further away than the thing I want" — skip routing entirely.
  RouteModel.shortHopFactor = 1.25
  -- Lookahead for the "go" bearing: the first route point this far ahead.
  RouteModel.leadPct = 1.0
  -- Two waypoints closer than this are one waypoint.
  RouteModel.epsilon = 0.05

  local function routeDist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
  end

  local function routeKey(cx, cy)
    return cx .. ":" .. cy
  end

  local function routeEdge(graph, a, b)
    local w = routeDist(graph.nodes[a].x, graph.nodes[a].y,
                        graph.nodes[b].x, graph.nodes[b].y)
    local la = graph.adj[a]
    la[routeGetn(la) + 1] = { to = b, w = w }
    local lb = graph.adj[b]
    lb[routeGetn(lb) + 1] = { to = a, w = w }
  end

  -- zoneSegments is one zone's entry from ShadowArmyRoadData: an array of flat
  -- {x1,y1,x2,y2,...} polylines. The result is a plain adjacency graph; build it
  -- once per zone and cache it, because this is the only expensive call here.
  function RouteModel.build(zoneSegments, opts)
    opts = opts or {}
    local join = opts.junctionDist or RouteModel.junctionDist
    local graph = { nodes = {}, adj = {}, n = 0, cell = join, grid = {} }
    if not zoneSegments then return graph end

    local nodes, adj, grid = graph.nodes, graph.adj, graph.grid
    local nn = 0
    local si = 1
    local nSeg = routeGetn(zoneSegments)
    while si <= nSeg do
      local flat = zoneSegments[si]
      local nf = routeGetn(flat)
      local prev = nil
      local fi = 1
      while fi + 1 <= nf do
        local x, y = flat[fi], flat[fi + 1]
        nn = nn + 1
        nodes[nn] = { x = x, y = y, seg = si }
        adj[nn] = {}
        local key = routeKey(math.floor(x / join), math.floor(y / join))
        local bucket = grid[key]
        if not bucket then bucket = {}; grid[key] = bucket end
        bucket[routeGetn(bucket) + 1] = nn
        graph.n = nn
        if prev then routeEdge(graph, prev, nn) end
        prev = nn
        fi = fi + 2
      end
      si = si + 1
    end

    -- Junction pass. The spatial hash keeps this linear-ish: only the 3x3 cell
    -- neighbourhood can hold a point within `join`, so a dense zone does not
    -- turn a zone change into a visible hitch.
    local i = 1
    while i <= nn do
      local a = nodes[i]
      local cx = math.floor(a.x / join)
      local cy = math.floor(a.y / join)
      local ox = -1
      while ox <= 1 do
        local oy = -1
        while oy <= 1 do
          local bucket = grid[routeKey(cx + ox, cy + oy)]
          if bucket then
            local bi = 1
            local nb = routeGetn(bucket)
            while bi <= nb do
              local j = bucket[bi]
              -- j > i emits each pair once; different seg only, because points
              -- inside one polyline are already chained.
              if j > i and nodes[j].seg ~= a.seg
                  and routeDist(a.x, a.y, nodes[j].x, nodes[j].y) <= join then
                routeEdge(graph, i, j)
              end
              bi = bi + 1
            end
          end
          oy = oy + 1
        end
        ox = ox + 1
      end
      i = i + 1
    end
    return graph
  end

  -- Nearest graph node to a point. A zone tops out around 300 nodes, so the
  -- straight scan is both faster and more predictable than a ring search, and it
  -- always returns the lowest index on a tie (determinism).
  local function routeNearest(graph, x, y)
    local best, bestD = nil, nil
    local i = 1
    while i <= graph.n do
      local nd = graph.nodes[i]
      local d = routeDist(x, y, nd.x, nd.y)
      if bestD == nil or d < bestD then best, bestD = i, d end
      i = i + 1
    end
    return best, bestD
  end

  -- Binary min-heap over node indices. Ties break on the lower node index so two
  -- equal-cost paths always resolve the same way.
  local function routeHeapLess(h, a, b)
    if h.cost[a] ~= h.cost[b] then return h.cost[a] < h.cost[b] end
    return h.node[a] < h.node[b]
  end

  local function routeHeapPush(h, node, cost)
    local n = h.n + 1
    h.n = n
    h.node[n] = node
    h.cost[n] = cost
    while n > 1 do
      local p = math.floor(n / 2)
      if not routeHeapLess(h, n, p) then break end
      h.node[p], h.node[n] = h.node[n], h.node[p]
      h.cost[p], h.cost[n] = h.cost[n], h.cost[p]
      n = p
    end
  end

  local function routeHeapPop(h)
    if h.n == 0 then return nil end
    local top = h.node[1]
    h.node[1], h.cost[1] = h.node[h.n], h.cost[h.n]
    h.node[h.n], h.cost[h.n] = nil, nil
    h.n = h.n - 1
    local i = 1
    local stop = false
    while not stop do
      local l, r = i * 2, i * 2 + 1
      local best = i
      if l <= h.n and routeHeapLess(h, l, best) then best = l end
      if r <= h.n and routeHeapLess(h, r, best) then best = r end
      if best == i then
        stop = true
      else
        h.node[best], h.node[i] = h.node[i], h.node[best]
        h.cost[best], h.cost[i] = h.cost[i], h.cost[best]
        i = best
      end
    end
    return top
  end

  local function routeAppend(pts, x, y, eps)
    local n = routeGetn(pts)
    if n > 0 and routeDist(pts[n].x, pts[n].y, x, y) < eps then return end
    pts[n + 1] = { x = x, y = y }
  end

  -- route(graph, start, goal) -> waypoints, meta
  --   waypoints : { {x=,y=}, ... } always at least start and goal
  --   meta      : { straight = bool, reason = string, cost, length, nodes }
  -- Never errors and never returns nil: every failure mode (no data, budget
  -- overflow, disconnected road network, a road that would not actually help)
  -- degrades to the two-point straight line the advisor drew before roads
  -- existed.
  function RouteModel.route(graph, start, goal, opts)
    opts = opts or {}
    local penalty = opts.penalty or RouteModel.offRoadPenalty
    local budget = opts.nodeBudget or RouteModel.nodeBudget
    local shortHop = opts.shortHopFactor or RouteModel.shortHopFactor
    local eps = opts.epsilon or RouteModel.epsilon
    local sx, sy = start.x, start.y
    local gx, gy = goal.x, goal.y
    local straightLen = routeDist(sx, sy, gx, gy)

    local function bail(reason)
      local pts = {}
      routeAppend(pts, sx, sy, eps)
      routeAppend(pts, gx, gy, eps)
      return pts, {
        straight = true, reason = reason,
        length = straightLen, cost = straightLen * penalty, nodes = 0,
      }
    end

    if not graph or (graph.n or 0) < 2 then return bail("no-roads") end
    local entry, dEntry = routeNearest(graph, sx, sy)
    local goalNode, dExit = routeNearest(graph, gx, gy)
    if not entry or not goalNode then return bail("no-roads") end
    -- The goal is closer than the nearest tarmac: walking to a road to walk back
    -- is exactly the detour nobody wants.
    if straightLen <= dEntry * shortHop then return bail("short-hop") end
    -- Even a free road cannot beat the straight line once both off-road legs
    -- already cost more than the whole trip.
    if straightLen <= dEntry + dExit then return bail("short-hop") end

    local dist, prev, done = {}, {}, {}
    local h = { n = 0, node = {}, cost = {} }
    dist[entry] = 0
    routeHeapPush(h, entry, 0)
    local settled, reached, overflow = 0, false, false
    while h.n > 0 and not reached and not overflow do
      local u = routeHeapPop(h)
      if not done[u] then
        done[u] = true
        settled = settled + 1
        if settled > budget then
          overflow = true
        elseif u == goalNode then
          reached = true
        else
          local es = graph.adj[u]
          local ei = 1
          local ne = routeGetn(es)
          while ei <= ne do
            local e = es[ei]
            local nd = dist[u] + e.w
            if dist[e.to] == nil or nd < dist[e.to] then
              dist[e.to] = nd
              prev[e.to] = u
              routeHeapPush(h, e.to, nd)
            end
            ei = ei + 1
          end
        end
      end
    end
    if overflow then return bail("budget") end
    if not reached then return bail("disconnected") end

    local roadCost = dist[goalNode]
    local total = (dEntry + dExit) * penalty + roadCost
    if total >= straightLen * penalty then return bail("straight-cheaper") end

    -- Walk prev back to the entry node; the guard is belt-and-braces against a
    -- malformed graph, since Dijkstra's tree cannot contain a cycle.
    local back, nb = {}, 0
    local u = goalNode
    while u and nb <= graph.n do
      nb = nb + 1
      back[nb] = u
      if u == entry then u = nil else u = prev[u] end
    end
    if back[nb] ~= entry then return bail("no-path") end

    local pts = {}
    routeAppend(pts, sx, sy, eps)
    local i = nb
    while i >= 1 do
      local nd = graph.nodes[back[i]]
      routeAppend(pts, nd.x, nd.y, eps)
      i = i - 1
    end
    routeAppend(pts, gx, gy, eps)

    local length = 0
    i = 2
    local np = routeGetn(pts)
    while i <= np do
      length = length + routeDist(pts[i - 1].x, pts[i - 1].y, pts[i].x, pts[i].y)
      i = i + 1
    end
    return pts, {
      straight = false, reason = "road",
      length = length, cost = total, nodes = settled,
    }
  end

  -- The point to actually face right now: snap to the nearest route point, then
  -- walk FORWARD along the path until `lead` percent of route is behind us.
  -- Measuring progress along the route rather than as-the-crow-flies is what
  -- stops a player standing just past a waypoint from being told to turn around
  -- and walk back to it.
  function RouteModel.nextPoint(pts, x, y, lead)
    if not pts then return nil end
    local n = routeGetn(pts)
    if n < 2 then return nil end
    lead = lead or RouteModel.leadPct
    local near, nearD = 1, nil
    local i = 1
    while i <= n do
      local d = routeDist(x, y, pts[i].x, pts[i].y)
      if nearD == nil or d < nearD then near, nearD = i, d end
      i = i + 1
    end
    local acc = 0
    i = near + 1
    while i <= n do
      acc = acc + routeDist(pts[i - 1].x, pts[i - 1].y, pts[i].x, pts[i].y)
      if acc > lead then return pts[i].x, pts[i].y, i end
      i = i + 1
    end
    return pts[n].x, pts[n].y, n
  end

  -- Every point of every segment of one zone, thinned to `budget` points for
  -- the world-map road layer. That layer exists so a human can say "that road
  -- isn't in the data", so a segment DISAPPEARING is the one unacceptable
  -- outcome: each segment keeps its two endpoints whenever the budget can seat
  -- them all, and only the leftover is shared out in proportion to length.
  -- A zone whose points already fit is drawn whole.
  -- -> a dense array of { x=, y= }, and its count (percent coordinates, the
  -- same space build() and route() speak)
  function RouteModel.sample(zoneSegments, budget)
    local out, np = {}, 0
    if not zoneSegments then return out, 0 end
    budget = budget or 180
    if budget < 1 then return out, 0 end
    local nSeg = routeGetn(zoneSegments)
    local total = 0
    local si = 1
    while si <= nSeg do
      total = total + math.floor(routeGetn(zoneSegments[si]) / 2)
      si = si + 1
    end
    if total < 1 then return out, 0 end
    -- Endpoint floor per segment, dropped entirely when there are more
    -- segments than the budget can even give two dots each.
    local base = 2
    if nSeg * base > budget then base = 0 end
    local extra = budget - base * nSeg
    local spare = total - base * nSeg
    if spare < 1 then spare = 1 end
    si = 1
    while si <= nSeg and np < budget do
      local flat = zoneSegments[si]
      local cnt = math.floor(routeGetn(flat) / 2)
      local take
      if total <= budget then
        take = cnt
      else
        take = base + math.floor((cnt - base) * extra / spare)
        if take < 1 then take = 1 end
        if take > cnt then take = cnt end
      end
      if take > budget - np then take = budget - np end
      if take >= cnt then
        local fi = 1
        while fi + 1 <= cnt * 2 do
          np = np + 1
          out[np] = { x = flat[fi], y = flat[fi + 1] }
          fi = fi + 2
        end
      elseif take == 1 then
        np = np + 1
        out[np] = { x = flat[1], y = flat[2] }
      elseif take > 1 then
        -- Evenly spaced along the polyline, both endpoints always included.
        local k = 0
        while k < take do
          local idx = math.floor(k * (cnt - 1) / (take - 1) + 0.5) + 1
          np = np + 1
          out[np] = { x = flat[idx * 2 - 1], y = flat[idx * 2] }
          k = k + 1
        end
      end
      si = si + 1
    end
    return out, np
  end

  ShadowArmy.routeModel = RouteModel
end

--------------------------------------------------------------------------
-- Pure HUD-guidance model (r56): the geometry behind the on-screen arrow.
--
-- Why this exists: every navigation surface the advisor had drew on the
-- FULLSCREEN WORLD MAP (dots, pins, the route trail). monofuel plays in the
-- 3D world with the map CLOSED, so from where he sits the addon had no
-- pathing at all — three revisions of routing he never saw. This model is
-- the half of the fix that can be tested without a client: percent-delta in,
-- screen-space arrow out.
--
-- Two 1.12 questions had to be settled against the CLIENT, not the docs. Both
-- were answered by reading build 5875 itself (WoW.exe method tables + the
-- extracted FrameXML), and both answers are recorded in
-- docs/vanilla-addons/client-quirks.md:
--
-- 1. ROTATION: `Texture:SetRotation` does NOT exist on 5875 (it is a
--    DressUpModel method there) — but the 8-argument SetTexCoord DOES. The
--    engine's own usage string spells the arbitrary-quad form out, and stock
--    FrameXML rotates with it in TaxiFrame.lua's DrawRouteLine (the flight-
--    path line). So HudModel.texCoords does the standard UV rotation and the
--    arrowhead is a real, smoothly rotating picture — no spritesheet needed.
--    The shaft is still a line of square pips positioned with SetPoint,
--    because pips cannot be silently ignored: if the art ever fails to load
--    the direction is still unmistakable on screen.
--
-- 2. FACING: there is none. `GetPlayerFacing` is absent from the 5875 binary,
--    the Minimap widget has no facing/rotation method, `MiniMapCompassRing`
--    is a post-1.12 frame that does not exist here, and the string
--    `rotateMinimap` appears nowhere in the client — vanilla's minimap is
--    unconditionally north-up, so there is no compass model to read a facing
--    off either. The arrow is therefore NORTH-UP: a compass, not a
--    windshield. That is still fully usable — it is exactly how the minimap
--    blips have always read — and it is the honest answer for this build.
--    The ladder in HudModel.facingSource still probes for a facing API first,
--    because this is a private-server FORK and a core may add one; the day it
--    does, the arrow rotates into player space with no other change.
--
-- Screen space here is SetPoint space: +x right, +y UP. Map space is +x east,
-- +y SOUTH, in percent of a zone that is not square in yards — so both
-- conversions happen in aim() or the arrow points somewhere plausible and
-- wrong, which is the one failure mode a guidance arrow may not have.
--------------------------------------------------------------------------

do
  local HudModel = {}

  -- 16-point compass. Decided by comparing the two legs against tangents
  -- rather than calling atan2, for the same reason F.questBearing does it:
  -- one less assumption about the 5.0 math library this client ships.
  local HUD_TAN1125 = 0.19891  -- tan(11.25 deg)
  local HUD_TAN3375 = 0.66818  -- tan(33.75 deg)

  -- dx, dy are MAP percent deltas (target minus player), so dy < 0 is north.
  -- The yard scales matter: a percent step north is not a percent step east.
  function HudModel.bearing(dx, dy, yardsX, yardsY)
    local e = dx / 100 * (yardsX or 100)
    local n = -(dy / 100 * (yardsY or 100))
    local ae = e >= 0 and e or -e
    local an = n >= 0 and n or -n
    if ae == 0 and an == 0 then return nil end
    local ns = (n >= 0) and "N" or "S"
    local ew = (e >= 0) and "E" or "W"
    if ae <= an * HUD_TAN1125 then return ns end
    if an <= ae * HUD_TAN1125 then return ew end
    if ae <= an * HUD_TAN3375 then return ns .. ns .. ew end
    if an <= ae * HUD_TAN3375 then return ew .. ns .. ew end
    return ns .. ew
  end

  -- The arrow's direction as a UNIT vector in screen space, or nil when the
  -- player is standing on the target (no direction exists, and inventing one
  -- would spin the needle at 4 Hz).
  --
  -- facing: radians CLOCKWISE from north, or nil for a north-up arrow.
  -- sign:   +1 / -1. The two facing sources below disagree about which way
  --         their angle grows and neither is documented for this build, so
  --         the sign is data, flippable live (/sa arrow flip) instead of a
  --         constant we would have to guess right on the first try.
  function HudModel.aim(dx, dy, yardsX, yardsY, facing, sign)
    local e = dx / 100 * (yardsX or 100)
    local n = -(dy / 100 * (yardsY or 100))
    local m = math.sqrt(e * e + n * n)
    if not (m > 0) then return nil end
    local ux, uy = e / m, n / m
    if facing then
      local f = facing * (sign or 1)
      local c, s = math.cos(f), math.sin(f)
      -- Rotate the world vector INTO player space: a target at angle t
      -- clockwise from north must appear at t - f from screen-up.
      ux, uy = ux * c - uy * s, ux * s + uy * c
    end
    return ux, uy
  end

  -- Player-space plain English. Only meaningful once aim() has rotated, so
  -- the live half calls it in player mode only.
  local HUD_AHEAD = 0.7071  -- cos(45 deg): the four quadrants, evenly split
  function HudModel.relative(ux, uy)
    if not ux then return nil end
    if uy >= HUD_AHEAD then return "ahead" end
    if uy <= -HUD_AHEAD then return "behind" end
    if ux >= 0 then return "right" end
    return "left"
  end

  -- Needle shape. Radii are pixels from the frame centre; the taper (small
  -- pips at the tail, fat ones near the head) is what makes a dotted line
  -- read as an arrow instead of as a string of beads.
  --
  -- Default preset: shaft ONLY. The rotating arrow texture is the head, and a
  -- pip arrowhead underneath it would just be clutter. `tip`/`barbR` are nil
  -- here and honoured when present — that is the `noArt` preset below, which
  -- /sa arrow art switches to so the needle can stand entirely on its own.
  HudModel.needle = {
    shaft = 8,      -- pips along the shaft
    r0 = 9,         -- first shaft pip, px from centre
    r1 = 30,        -- last shaft pip
    size0 = 3,      -- px, tail
    size1 = 5.5,    -- px, shaft end
    glyph = 44,     -- where the arrow TEXTURE is centred, px from centre
    glyphSize = 34, -- px; the art is a triangle inside a padded 32x32 square
  }

  HudModel.needleNoArt = {
    shaft = 9,
    r0 = 9,
    r1 = 36,
    size0 = 3,
    size1 = 5,
    tip = 45,       -- head pip radius
    tipSize = 8,
    barbR = 33,     -- the two barbs sit BEHIND the head, off to each side
    barbOff = 9,
    barbSize = 5,
  }

  -- Returns pips, count. Each pip is { x, y, size, head }, x/y in screen
  -- offsets from the arrow's centre. Allocation happens per call; the caller
  -- runs this at 4 Hz on a dozen pips, which is nothing next to the quest
  -- scan it already runs at 2 Hz.
  function HudModel.needlePips(ux, uy, cfg)
    if not ux then return {}, 0 end
    cfg = cfg or HudModel.needle
    local out, n = {}, 0
    local shaft = cfg.shaft
    local i = 1
    while i <= shaft do
      local t = 0
      if shaft > 1 then t = (i - 1) / (shaft - 1) end
      local r = cfg.r0 + (cfg.r1 - cfg.r0) * t
      n = n + 1
      out[n] = {
        x = ux * r, y = uy * r,
        size = cfg.size0 + (cfg.size1 - cfg.size0) * t,
        head = false,
      }
      i = i + 1
    end
    if cfg.tip then
      n = n + 1
      out[n] = { x = ux * cfg.tip, y = uy * cfg.tip,
                 size = cfg.tipSize, head = true }
    end
    if cfg.barbR then
      -- Perpendicular in screen space (left of the direction of travel).
      local px, py = -uy, ux
      n = n + 1
      out[n] = { x = ux * cfg.barbR + px * cfg.barbOff,
                 y = uy * cfg.barbR + py * cfg.barbOff,
                 size = cfg.barbSize, head = true }
      n = n + 1
      out[n] = { x = ux * cfg.barbR - px * cfg.barbOff,
                 y = uy * cfg.barbR - py * cfg.barbOff,
                 size = cfg.barbSize, head = true }
    end
    return out, n
  end

  -- UV rotation for the arrowhead, in the 8-argument SetTexCoord order
  -- (ULx, ULy, LLx, LLy, URx, URy, LRx, LRy). Stock art points UP in the
  -- texture, so the mapping is: screen offset s of a quad corner samples
  -- texture offset R(-angle)*s, converted to UV space where v grows DOWN.
  -- Written in terms of the unit vector rather than an angle, so no atan2
  -- and no second trig call — (ux, uy) already IS (sin, cos) of the heading.
  --
  -- The corners run to 0.707 from centre at 45 degrees, i.e. outside [0,1].
  -- That is deliberate and safe HERE: ROTATING-MINIMAPARROW.blp is a 32x32
  -- triangle whose ink stops at radius ~12 of 16, so every out-of-range
  -- sample lands in the transparent border. Cropping the quad to the
  -- inscribed square instead (the TaxiFrame trick) would clip the arrow's
  -- own point, which is the one pixel that has to be there.
  function HudModel.texCoords(ux, uy)
    if not ux then return 0, 0, 0, 1, 1, 0, 1, 1 end
    local ax, ay = 0.5 * ux, 0.5 * uy
    -- corner(sx, sy) with sx/sy in {-1, +1}, screen y UP.
    local ULx, ULy = 0.5 - ay - ax, 0.5 - ay + ax
    local LLx, LLy = 0.5 - ay + ax, 0.5 + ay + ax
    local URx, URy = 0.5 + ay - ax, 0.5 - ay - ax
    local LRx, LRy = 0.5 + ay + ax, 0.5 + ay - ax
    return ULx, ULy, LLx, LLy, URx, URy, LRx, LRy
  end

  -- The facing ladder, as a pure decision so it can be tested without a
  -- client. env is what the live half found on the globals table:
  --   api     a facing function exists and returned a number. Not stock 5875
  --           (verified absent from the binary) — this rung is here because
  --           the server is a fork and a core CAN add one.
  --   model   a Model widget was handed to us that reports a live facing.
  --           Kept as a rung because Model:GetFacing IS in the 5875 method
  --           table; what 1.12 lacks is any STOCK model the client spins with
  --           the player (no compass ring, no minimap rotation), so nothing
  --           fills it today.
  --   none    north-up. The honest answer on a stock 5875 client.
  function HudModel.facingSource(env)
    env = env or {}
    if env.api then return "api" end
    if env.model then return "model" end
    return "none"
  end

  ShadowArmy.hudModel = HudModel
end

--------------------------------------------------------------------------
-- Pure combat-coach model. Like QuestModel, this stays above the WoW UI
-- guard so ordinary Lua tests can exercise priorities and error handling.
-- The live adapter below supplies only facts exposed by the 1.12 API.
--------------------------------------------------------------------------

local CombatModel = {}

CombatModel.actions = {
  WARLOCK = {
    { id = "drainlife", label = "Drain Life", kind = "spell", spell = "Drain Life", target = "hostile", cast = true, debuff = true },
    { id = "fear", label = "Fear", kind = "spell", spell = "Fear", target = "hostile", cast = true, debuff = true },
    { id = "lifetap", label = "Life Tap", kind = "spell", spell = "Life Tap", target = "self" },
    { id = "corruption", label = "Corruption", kind = "spell", spell = "Corruption", target = "hostile", debuff = true },
    { id = "agony", label = "Curse of Agony", kind = "spell", spell = "Curse of Agony", target = "hostile", debuff = true },
    { id = "immolate", label = "Immolate", kind = "spell", spell = "Immolate", target = "hostile", cast = true, debuff = true },
    { id = "shadowbolt", label = "Shadow Bolt", kind = "spell", spell = "Shadow Bolt", target = "hostile", cast = true },
    { id = "shoot", label = "Shoot", kind = "spell", spell = "Shoot", target = "hostile" },
    { id = "melee", label = "Melee Attack", kind = "melee", target = "hostile" },
  },
  DRUID = {
    { id = "healingtouch", label = "Healing Touch", kind = "spell", spell = "Healing Touch", target = "self", selfCast = true, cast = true },
    { id = "rejuvenation", label = "Rejuvenation", kind = "spell", spell = "Rejuvenation", target = "self", selfCast = true, buff = true },
    { id = "moonfire", label = "Moonfire", kind = "spell", spell = "Moonfire", target = "hostile", debuff = true },
    { id = "faeriefire", label = "Faerie Fire", kind = "spell", spell = "Faerie Fire", target = "hostile", debuff = true },
    { id = "wrath", label = "Wrath", kind = "spell", spell = "Wrath", target = "hostile", cast = true },
    { id = "catform", label = "Cat Form", kind = "spell", spell = "Cat Form", target = "self", setsForm = "cat" },
    { id = "bearform", label = "Bear Form", kind = "spell", spell = "Bear Form", target = "self", setsForm = "bear" },
    { id = "rip", label = "Rip", kind = "spell", spell = "Rip", target = "hostile", form = "cat", debuff = true },
    { id = "rake", label = "Rake", kind = "spell", spell = "Rake", target = "hostile", form = "cat", debuff = true },
    { id = "claw", label = "Claw", kind = "spell", spell = "Claw", target = "hostile", form = "cat" },
    { id = "tigersfury", label = "Tiger's Fury", kind = "spell", spell = "Tiger's Fury", target = "self", form = "cat", buff = true },
    { id = "demoroar", label = "Demoralizing Roar", kind = "spell", spell = "Demoralizing Roar", target = "hostile", form = "bear", debuff = true },
    { id = "maul", label = "Maul", kind = "spell", spell = "Maul", target = "hostile", form = "bear" },
    { id = "melee", label = "Melee Attack", kind = "melee", target = "hostile" },
  },
}

local function combatGetn(t)
  local n = 0
  while t and t[n + 1] ~= nil do n = n + 1 end
  return n
end

local function combatDefs(classToken)
  return CombatModel.actions[classToken or ""] or {}
end

function CombatModel.action(classToken, id)
  local defs = combatDefs(classToken)
  local i = 1
  while i <= combatGetn(defs) do
    if defs[i].id == id then return defs[i] end
    i = i + 1
  end
  return nil
end

local function combatTargetBlock(snapshot, def)
  if def.target ~= "hostile" then return nil end
  if not snapshot.hostile then
    if snapshot.targetDead then return "target dead" end
    if snapshot.hasTarget then return "not hostile" end
    return "need target"
  end
  return nil
end

local function combatAdd(snapshot, result, id, want, idleReason)
  local def = CombatModel.action(snapshot.classToken, id)
  if not def then return nil end
  local state = snapshot.actions and snapshot.actions[id] or nil
  if not state or not state.known then return nil end

  local row = {
    id = id, label = def.label, spell = def.spell, kind = def.kind,
    target = def.target, texture = state.texture, slot = state.slot,
    range = state.range or "na", cooldown = state.cooldown or 0,
    gcd = state.gcd and true or false,
    exact = state.slot and true or false, usable = true, ready = false,
  }
  local reason = combatTargetBlock(snapshot, def)
  if snapshot.playerDead then reason = "player dead" end
  if not reason and def.form and snapshot.form ~= def.form then
    reason = "wrong form"
  end
  if not reason and state.active then reason = state.activeReason or "active" end
  if not reason and def.cast and snapshot.moving then reason = "stand still" end
  if not reason and row.cooldown > 0.1 and not row.gcd then
    reason = string.format("cooldown %.1fs", row.cooldown)
  end
  if not reason and state.noResource then reason = state.resourceReason or "resource low" end
  if not reason and state.usable == false then reason = state.unusableReason or "unavailable" end
  if not reason and state.range == "out" then reason = "out of range" end

  if reason then
    row.usable = false
    row.reason = reason
  elseif want then
    row.ready = true
    row.reason = idleReason or "ready"
    if not result.nextId then result.nextId = id end
  else
    row.reason = idleReason or "ready"
  end
  result.rows[combatGetn(result.rows) + 1] = row
  return row
end

-- r46 (ticket 0041): resource policy is denominated in CASTS, not percent.
-- The old percent gates opened a dead band — at 272 max mana, "bolt only above
-- 35%" is ~95 mana against a 40-mana Shadow Bolt, so 20-35% mana neither bolted
-- ("save mana") nor tapped ("mana OK") and the coach fell through to melee.
-- The band widens as max mana grows, so the constants cannot be retuned; the
-- gates must read actual cost.
--
-- CONSTRAINT: these percent numbers are the FALLBACK ONLY. `snapshot.costs` is
-- built from spellbook tooltips (F.spellCost), which can legitimately come back
-- empty — a tooltip that will not populate, a spell the sweep has not seen yet.
-- When a cost (or `snapshot.power`) is missing, the affected gate degrades to
-- exactly the pre-r46 percent behavior below. It must never degrade to
-- "always recommend": suggesting an unaffordable cast every tick is a worse
-- failure than the dead band this ticket closes.
CombatModel.percentGates = {
  shadowbolt = 35,
  immolate = 45,
  lifetap = 20,
  wrath = 30,
}

-- Mana cost of an action id, or nil when cost data is unavailable.
local function combatCost(snapshot, id)
  local costs = snapshot.costs
  local cost = costs and costs[id] or nil
  if type(cost) ~= "number" then return nil end
  return cost
end

-- true/false when castability is known, nil when it is not (caller falls back).
local function combatCanAfford(snapshot, id)
  local cost = combatCost(snapshot, id)
  if cost == nil then return nil end
  if type(snapshot.power) ~= "number" then return nil end
  return snapshot.power >= cost
end

local function combatWarlock(snapshot, result)
  local hp = snapshot.hpPct or 100
  local mana = snapshot.powerPct or 100
  local targetHp = snapshot.targetHpPct or 100
  local actions = snapshot.actions or {}
  local gates = CombatModel.percentGates

  -- Shadow Bolt is the unit of account: it is the filler, so "can I still
  -- bolt?" is what decides both the nuke gate and when tapping starts.
  local boltOK = combatCanAfford(snapshot, "shadowbolt")
  local boltWant, boltReason
  if boltOK ~= nil then
    boltWant = boltOK
    if boltOK then boltReason = "nuke" else boltReason = "not enough mana" end
  else
    boltWant = mana > gates.shadowbolt
    if boltWant then boltReason = "nuke" else boltReason = "save mana" end
  end

  -- Immolate keeps one bolt in reserve so a long cast cannot strand the
  -- rotation with no filler left.
  local boltCost, immoCost = combatCost(snapshot, "shadowbolt"), combatCost(snapshot, "immolate")
  local immoAfford, immoBlocked
  if boltCost and immoCost and type(snapshot.power) == "number" then
    immoAfford = snapshot.power >= immoCost + boltCost
    immoBlocked = "bolt reserve"
  else
    immoAfford = mana > gates.immolate
    immoBlocked = "mana reserve"
  end

  -- Life Tap turns on exactly where bolting turns off: no gap, no overlap.
  local tapNeeded
  if boltOK ~= nil then tapNeeded = not boltOK else tapNeeded = mana < gates.lifetap end

  combatAdd(snapshot, result, "drainlife", hp <= 45, hp <= 45 and "recover health" or "health OK")
  combatAdd(snapshot, result, "fear", snapshot.danger and hp < 50,
    snapshot.danger and "defensive option" or "defensive")
  combatAdd(snapshot, result, "lifetap",
    snapshot.hostile and tapNeeded and hp > 65,
    (hp <= 65 and tapNeeded) and "health too low" or "mana OK")
  combatAdd(snapshot, result, "corruption",
    snapshot.hostile and not (actions.corruption and actions.corruption.debuff),
    (actions.corruption and actions.corruption.debuff) and "already up" or "DoT")
  combatAdd(snapshot, result, "agony",
    snapshot.hostile and targetHp > 50 and not (actions.agony and actions.agony.debuff),
    targetHp <= 50 and "target low" or ((actions.agony and actions.agony.debuff) and "already up" or "curse"))
  combatAdd(snapshot, result, "immolate",
    snapshot.hostile and targetHp > 65 and immoAfford
      and not (actions.immolate and actions.immolate.debuff),
    targetHp <= 65 and "target low" or ((actions.immolate and actions.immolate.debuff) and "already up"
      or (immoAfford and "DoT" or immoBlocked)))
  combatAdd(snapshot, result, "shadowbolt", snapshot.hostile and boltWant, boltReason)
  combatAdd(snapshot, result, "shoot", snapshot.hostile and snapshot.hasWand,
    snapshot.shooting and "firing" or (snapshot.hasWand and "wand" or "no wand"))
  combatAdd(snapshot, result, "melee", snapshot.hostile,
    snapshot.melee and "swinging" or "last resort")
end

local function combatDruidHumanoid(snapshot, result)
  local hp = snapshot.hpPct or 100
  local mana = snapshot.powerPct or 100
  local targetHp = snapshot.targetHpPct or 100
  local actions = snapshot.actions or {}
  combatAdd(snapshot, result, "healingtouch", hp < 45, hp < 45 and "emergency heal" or "health OK")
  combatAdd(snapshot, result, "rejuvenation",
    hp < 70 and not (actions.rejuvenation and actions.rejuvenation.buff),
    (actions.rejuvenation and actions.rejuvenation.buff) and "already up" or "health OK")
  combatAdd(snapshot, result, "moonfire",
    snapshot.hostile and targetHp > 35 and not (actions.moonfire and actions.moonfire.debuff),
    targetHp <= 35 and "target low" or ((actions.moonfire and actions.moonfire.debuff) and "already up" or "DoT"))
  combatAdd(snapshot, result, "faeriefire",
    snapshot.hostile and snapshot.danger and not (actions.faeriefire and actions.faeriefire.debuff),
    (actions.faeriefire and actions.faeriefire.debuff) and "already up" or "elite armor")
  -- Same cast-denominated gate as the Warlock filler (r46, ticket 0041), with
  -- the same fall back to the old percent constant when cost data is missing.
  local wrathOK = combatCanAfford(snapshot, "wrath")
  local wrathWant, wrathReason
  if wrathOK ~= nil then
    wrathWant = wrathOK
    if wrathOK then wrathReason = "nuke" else wrathReason = "not enough mana" end
  else
    wrathWant = mana > CombatModel.percentGates.wrath
    if wrathWant then wrathReason = "nuke" else wrathReason = "save mana" end
  end
  combatAdd(snapshot, result, "wrath", snapshot.hostile and wrathWant, wrathReason)
  combatAdd(snapshot, result, "catform", false, "form option")
  combatAdd(snapshot, result, "bearform", false, "form option")
  combatAdd(snapshot, result, "melee", snapshot.hostile, "fallback")
end

local function combatDruidCat(snapshot, result)
  local actions = snapshot.actions or {}
  local combo = snapshot.combo or 0
  combatAdd(snapshot, result, "rip",
    snapshot.hostile and combo >= 4 and not (actions.rip and actions.rip.debuff),
    (actions.rip and actions.rip.debuff) and "already up" or (combo < 4 and (tostring(combo) .. " combo") or "finisher"))
  combatAdd(snapshot, result, "rake",
    snapshot.hostile and not (actions.rake and actions.rake.debuff),
    (actions.rake and actions.rake.debuff) and "already up" or "bleed")
  combatAdd(snapshot, result, "claw", snapshot.hostile, "builder")
  combatAdd(snapshot, result, "tigersfury", false,
    (actions.tigersfury and actions.tigersfury.buff) and "already up" or "damage boost")
  combatAdd(snapshot, result, "bearform", false, "form option")
  combatAdd(snapshot, result, "melee", snapshot.hostile, "auto attack")
  if (snapshot.hpPct or 100) < 30 then result.warning = "low health — leave form to heal" end
end

local function combatDruidBear(snapshot, result)
  local actions = snapshot.actions or {}
  combatAdd(snapshot, result, "demoroar",
    snapshot.hostile and not (actions.demoroar and actions.demoroar.debuff),
    (actions.demoroar and actions.demoroar.debuff) and "already up" or "reduce damage")
  combatAdd(snapshot, result, "maul", snapshot.hostile, "rage attack")
  combatAdd(snapshot, result, "catform", false, "form option")
  combatAdd(snapshot, result, "melee", snapshot.hostile, "auto attack")
  if (snapshot.hpPct or 100) < 30 then result.warning = "low health — leave form to heal" end
end

-- The coach is a recommendation display, so the current recommendation owns
-- row one. Everything else keeps its class-profile order. Transient cast/GCD
-- state is deliberately excluded from nextId selection, which prevents the
-- table from shuffling away and snapping back while an action completes.
local function combatPromoteNext(result)
  if not result.nextId then return end
  local found = nil
  local i = 1
  while i <= combatGetn(result.rows) do
    if result.rows[i].id == result.nextId then found = i; break end
    i = i + 1
  end
  if not found or found == 1 then return end
  local nextRow = result.rows[found]
  i = found
  while i > 1 do
    result.rows[i] = result.rows[i - 1]
    i = i - 1
  end
  result.rows[1] = nextRow
end

function CombatModel.evaluate(snapshot)
  snapshot = snapshot or {}
  local result = { rows = {}, nextId = nil, warning = nil }
  if snapshot.classToken == "WARLOCK" then
    combatWarlock(snapshot, result)
  elseif snapshot.classToken == "DRUID" then
    if snapshot.form == "cat" then
      combatDruidCat(snapshot, result)
    elseif snapshot.form == "bear" then
      combatDruidBear(snapshot, result)
    else
      combatDruidHumanoid(snapshot, result)
    end
  else
    result.warning = "no combat profile for this class"
  end
  combatPromoteNext(result)
  return result
end

CombatModel.failureLabels = {
  facing = "turn to face target",
  los = "move into line of sight",
  range = "move into range",
  moving = "stand still",
  mana = "not enough mana",
  rage = "not enough rage",
  energy = "not enough energy",
  cooldown = "ability not ready",
  target = "invalid target",
}

function CombatModel.classifyFailure(message, messageCodes)
  local code = messageCodes and messageCodes[message or ""] or nil
  if not code then return nil end
  return { code = code, label = CombatModel.failureLabels[code] or code }
end

ShadowArmy.combatModel = CombatModel

--------------------------------------------------------------------------
-- Pure passive-upkeep model (r42): given the watched self-buffs, the pet
-- state and the class, decide which one-click buttons the panel shows and
-- which lines stay plain text.
--
-- r49 (ticket 0058, monofuel live report): the original rule was "anything
-- the advisor auto-casts stays a note, never a button" — which produced
-- "armor: auto (Demon Skin)" in green next to a buff that was MISSING, with
-- no way to fix it by hand. AUTOCAST ARMED IS NOT AUTOCAST FIRED: the armor
-- watch has verify windows, GCD/cast-failure gates and a texture capture
-- that can still be in progress (docs/vanilla-addons/client-quirks.md:
-- buff textures must be captured, never guessed), so `auto` says a machine
-- is trying, not that the buff is up. A missing/expiring TRAINED buff now
-- always yields the button; the auto state degrades to secondary info (the
-- same green note as before, plus a tooltip line on the button itself).
-- Double-casting is already impossible — F.passiveClick returns early while
-- auto.casting is set — so no new guard belongs here.
--------------------------------------------------------------------------

local PassiveModel = {}

-- Class summons. A class with no entry simply never gets a summon button.
PassiveModel.summons = {
  WARLOCK = "Summon Imp",
}

local function passiveGetn(t)
  local n = 0
  while t and t[n + 1] ~= nil do n = n + 1 end
  return n
end

function PassiveModel.evaluate(snapshot)
  local result = { buttons = {}, notes = {}, ok = true }
  local nb, nn = 0, 0
  local buffs = snapshot.buffs or {}
  local i = 1
  while i <= passiveGetn(buffs) do
    local buff = buffs[i]
    if buff.missing or buff.expiring then
      if buff.spell and not snapshot.dead then
        -- The button comes FIRST now, autocast or not (ticket 0058).
        nb = nb + 1
        result.buttons[nb] = {
          id = "buff:" .. (buff.id or buff.label),
          label = buff.spell, spell = buff.spell, selfCast = true,
          auto = buff.auto and true or false,
        }
        if buff.auto then
          -- Secondary, and deliberately still tone "ok": the panel nags in
          -- chat for every note that is NOT ok, and nagging about something
          -- the human can now fix with one click is the regression this
          -- ticket is the other half of.
          nn = nn + 1
          result.notes[nn] = {
            tone = "ok",
            text = string.format("%s: auto (%s)",
              buff.autoLabel or buff.label, buff.spell),
          }
        end
      elseif buff.auto then
        -- No castable rank (or dead): there is no button to offer, so the
        -- auto note is all there is — unchanged from r42.
        nn = nn + 1
        result.notes[nn] = {
          tone = "ok",
          text = string.format("%s: auto (%s)",
            buff.autoLabel or buff.label, buff.spell or "untrained"),
        }
      elseif buff.missing then
        nn = nn + 1
        result.notes[nn] = { tone = "bad", text = buff.label .. " MISSING" }
      else
        nn = nn + 1
        result.notes[nn] = {
          tone = "warn",
          text = string.format("%s %dm left", buff.label, buff.minutes or 0),
        }
      end
    end
    i = i + 1
  end
  -- r55 (monofuel live, Murist): the summon used to be suppressed by
  -- `not snapshot.inCombat`, and THAT is the "buffs stuck on OK" latch.
  -- The imp dies in a fight — the one moment a warlock needs the button —
  -- and the model answers with nothing pending, so `result.ok` goes true and
  -- the section paints "buffs OK" over a dead minion until combat drops.
  -- Suppressing the BUTTON was never the right way to express "this is a
  -- 10s cast you probably do not want mid-pull": the panel's job is to
  -- report state honestly, and pressing it is the human's call. So the
  -- button always appears when the minion is genuinely gone, and combat
  -- degrades to a flag the tooltip explains (same shape as r49's `auto`).
  local summon = PassiveModel.summons[snapshot.classToken or ""]
  if summon and not snapshot.hasPet
      and not snapshot.dead
      and snapshot.known and snapshot.known[string.lower(summon)] then
    nb = nb + 1
    result.buttons[nb] = {
      id = "summon", label = summon, spell = summon,
      inCombat = snapshot.inCombat and true or false,
    }
  end
  result.ok = (nb == 0 and nn == 0)
  return result
end

ShadowArmy.passiveModel = PassiveModel

-- Buff watch: warn when a tracked self-buff is missing or expiring.
-- 1.12 API quirk: GetPlayerBuff/GetPlayerBuffTimeLeft give remaining time,
-- but buff NAMES aren't exposed directly — identify by texture instead
-- (stable across ranks). Demon Skin and Demon Armor share the watch slot:
-- either one counts as "armored".
-- Lives above the UI guard (r44) so unit tests bind the REAL table: the bar
-- model's managed set is derived from it, and a rename here must break tests
-- rather than silently un-manage a spell.
local ARMOR_WATCH = {
  id = "armor",
  label = "Demon Skin",
  autoLabel = "armor",
  -- Preference order; Demon Armor supersedes Demon Skin at 20+.
  spells = { "Demon Armor", "Demon Skin" },
  textures = {
    "Interface\\Icons\\Spell_Shadow_RagingScream",  -- Demon Skin
    "Interface\\Icons\\Spell_Shadow_SpectralSight", -- Demon Armor (lvl 20+)
  },
  warnBelow = 300, -- seconds; warn under 5 minutes
  autoCast = true, -- r12: the advisor keeps this one up itself (see F.armorTick)
}

local WATCHED_BUFFS = { ARMOR_WATCH }

ShadowArmy.watchedBuffs = WATCHED_BUFFS

--------------------------------------------------------------------------
-- Pure action-bar sweep model (r43): the advisor owns its managed abilities
-- (combat-coach spells, passive-upkeep buffs, the class summon) and casts
-- them itself, so a bar copy is dead weight the human can mis-click.
-- monofuel authorized clobbering the bar. This half only decides WHICH
-- slots go; the UI half reads slot names and does the removal.
--
-- r44 telemetry shelf: the combat coach reads EXACT usability and range off
-- an action slot that holds the spell (F.combatActionState). Sweeping every
-- copy would pin it to usable=true plus a CheckInteractDistance guess for the
-- rest of the session, so the sweep now keeps one copy per managed spell in
-- the last bonus bank — a bank no key can reach on a stance-less class.
--------------------------------------------------------------------------

local BarModel = {}

local function barGetn(t)
  local n = 0
  while t and t[n + 1] ~= nil do n = n + 1 end
  return n
end

BarModel.maxSlot = 120 -- 1.12: 10 pages x 12 buttons, no more
-- 1-72 are the six pressable pages — the only slots a human can mis-click.
-- 73-120 are the stance/bonus banks (a druid's form bars live there), so the
-- sweep stops at 72 and form bars survive untouched.
BarModel.sweepMax = 72
-- The last bonus bank is the telemetry shelf. Assumes a stance-less class:
-- bonus offset 4 (druid Travel Form) renders these very slots as the live
-- bar, so the shelf must move before the sweep ships for druids.
BarModel.shelfFirst = 109
BarModel.shelfLast = 120

-- Managed names in shelf priority order, lowercase: 1.12 tooltips carry the
-- client's capitalisation, not ours. Coach spells come first because they are
-- the ones that consume exact slot telemetry; `watches` is the passive
-- buff-watch list, whose every RANK counts (Demon Skin and Demon Armor share
-- one watch); the class summon trails.
function BarModel.managedOrder(classToken, watches)
  local out, n, seen = {}, 0, {}
  local function add(name)
    if not name then return end
    local key = string.lower(name)
    if seen[key] then return end
    seen[key] = true
    n = n + 1
    out[n] = key
  end
  local defs = CombatModel.actions[classToken or ""] or {}
  local i = 1
  while i <= barGetn(defs) do
    add(defs[i].spell)
    i = i + 1
  end
  local wi = 1
  while wi <= barGetn(watches) do
    local spells = watches[wi].spells or {}
    local si = 1
    while si <= barGetn(spells) do
      add(spells[si])
      si = si + 1
    end
    wi = wi + 1
  end
  add(PassiveModel.summons[classToken or ""])
  return out
end

-- Set form of the same list, for O(1) slot matching.
function BarModel.managedNames(classToken, watches)
  local names = {}
  local order = BarModel.managedOrder(classToken, watches)
  local i = 1
  while i <= barGetn(order) do
    names[order[i]] = true
    i = i + 1
  end
  return names
end

-- slotNames is { [slot] = tooltip line 1 } and is sparse (empty slots are
-- absent), so walk the slot range rather than the table.
function BarModel.sweep(slotNames, managed, maxSlot)
  local out, n = {}, 0
  slotNames = slotNames or {}
  managed = managed or {}
  local slot = 1
  local last = maxSlot or BarModel.maxSlot
  while slot <= last do
    local name = slotNames[slot]
    if name and managed[string.lower(name)] then
      n = n + 1
      out[n] = slot
    end
    slot = slot + 1
  end
  return out
end

-- The whole decision, so the UI half only executes. Returns
--   { remove = { slot, ... },                    -- pressable slots to clear
--     place  = { { name = <lowercase>, slot = n }, ... }, -- shelf refills
--     shelfFull = bool }                         -- some spell got no shelf
-- opts:
--   order      ordered managed names (BarModel.managedOrder); no order, no
--              placement — a hash set has no stable order to fill a shelf in
--   trained    set/map keyed lowercase of spells the player actually knows
--              (auto.spells works directly); nil means "all of them"
--   occupied   set of slots holding SOMETHING, macros and slots whose tooltip
--              would not read included — those are never overwritten
--   sweepMax / shelfFirst / shelfLast / maxSlot   range overrides
function BarModel.plan(slotNames, managed, opts)
  slotNames, managed, opts = slotNames or {}, managed or {}, opts or {}
  local sweepMax = opts.sweepMax or BarModel.sweepMax
  local shelfFirst = opts.shelfFirst or BarModel.shelfFirst
  local shelfLast = opts.shelfLast or BarModel.shelfLast
  local maxSlot = opts.maxSlot or BarModel.maxSlot
  local occupied = opts.occupied or {}
  local out = { remove = BarModel.sweep(slotNames, managed, sweepMax),
    place = {}, shelfFull = false }
  -- Anything already parked in the untouched banks still feeds the coach, so
  -- it needs no shelf copy. `kept` is a SET, so the duplicate shelf copies a
  -- broken sweep may have left behind (r44's unreadable-bar bug) collapse to
  -- one entry: the name is simply never placed again. Nothing removes them —
  -- removal stops at sweepMax and a spare copy on the shelf is harmless.
  local kept = {}
  local slot = sweepMax + 1
  while slot <= maxSlot do
    local name = slotNames[slot]
    if name then kept[string.lower(name)] = true end
    slot = slot + 1
  end
  local free, fn = {}, 0
  slot = shelfFirst
  while slot <= shelfLast do
    if not occupied[slot] and not slotNames[slot] then
      fn = fn + 1
      free[fn] = slot
    end
    slot = slot + 1
  end
  local order, trained = opts.order or {}, opts.trained
  local pn, i = 0, 1
  while i <= barGetn(order) do
    local name = string.lower(order[i])
    if not kept[name] and (not trained or trained[name]) then
      kept[name] = true
      if pn < fn then
        pn = pn + 1
        out.place[pn] = { name = name, slot = free[pn] }
      else
        -- Shelf is out of room: the coach falls back to approximate range
        -- and usable=true for whatever is left over.
        out.shelfFull = true
      end
    end
    i = i + 1
  end
  return out
end

ShadowArmy.barModel = BarModel

--------------------------------------------------------------------------
-- Pure bag disposition model (r47, ticket 0039 phase 2): "a bot picked up
-- 12 random items — what should it do with them?" Tags every bag item the
-- human sees first and the bots consume later.
--
-- THE DATA CONTRACT IS THE WHOLE TRAP (docs/item-data.md; the phase-1 review
-- called this exact footgun out): ItemData OMITS every field that equals its
-- default, so an absent `class` means 0 = Consumable and an absent `q` means
-- 0 = Poor. Reading `row.class` raw turns every consumable into "no class"
-- and every gray into "unknown quality". Every field read here goes through
-- BagModel.field() and nothing else may read a row directly.
--
-- A missing ROW is a different thing entirely: `ShadowArmyItemData[id] == nil`
-- means this patch's dump never saw the item, and the only honest answer is
-- HOLD "unknown item". Do not fold that into the defaulting.
--
-- Pure: no WoW API, no frames, no globals — lua/tests drives it on host Lua.
--------------------------------------------------------------------------

local BagModel = {}

local function bagGetn(t)
  local n = 0
  while t and t[n + 1] ~= nil do n = n + 1 end
  return n
end

BagModel.SELL = "SELL"
BagModel.EQUIP = "EQUIP"
BagModel.KEEP_QUEST = "KEEP_QUEST"
BagModel.HOLD = "HOLD"
-- Declared so the UI can colour it, NEVER returned by v1. Deciding "drink
-- this / eat this / this is a bandage" needs `spellid_1` + `flags` out of
-- item_template, which phase 1 did not emit (ticket 0039 note 2026-08-14).
-- Consumables land on HOLD with a reason that says so, rather than a guess
-- that heals nothing.
BagModel.USE = "USE"
BagModel.useImplemented = false

BagModel.CLASS_CONSUMABLE = 0
BagModel.CLASS_WEAPON = 2
BagModel.CLASS_ARMOR = 4
BagModel.CLASS_QUEST = 12

BagModel.ARMOR_MISC = 0  -- necks, rings, trinkets, held-in-off-hand
BagModel.ARMOR_CLOTH = 1

-- `slot` is inventory_type. These are the SINGLE-position slots we are
-- willing to compare by item level. FINGER (11) and TRINKET (12) have two
-- positions each, and weapons are not comparable by item level at all (a
-- wand and a one-hand sword share `lvl` and nothing else) — those punt to
-- MANUAL_SLOT. ROBE (20) is a chest piece; warlock gear is full of them.
BagModel.EQUIP_SLOT = {
  [1] = "head", [2] = "neck", [3] = "shoulder", [5] = "chest",
  [6] = "waist", [7] = "legs", [8] = "feet", [9] = "wrist",
  [10] = "hands", [16] = "back", [20] = "chest", [23] = "off-hand",
}

-- Equippable, but the call is the human's this rev. The reason text names
-- the slot so the bag window explains itself instead of just saying "hold".
BagModel.MANUAL_SLOT = {
  [4] = "shirt", [11] = "ring", [12] = "trinket", [13] = "weapon",
  [14] = "shield", [15] = "ranged", [17] = "two-hander", [19] = "tabard",
  [21] = "main hand", [22] = "off hand", [25] = "thrown",
  [26] = "ranged", [28] = "relic",
}

-- Cloth casters wear cloth (armor subclass 1) plus the Misc pieces every
-- class can wear (subclass 0: necks, rings, trinkets, held-in-off-hand).
BagModel.CLOTH_CLASSES = { WARLOCK = true, MAGE = true, PRIEST = true }

-- THE defaulting accessor. Absent == the column's default, never "unknown".
function BagModel.field(row, key)
  if not row then return 0 end
  local v = row[key]
  if v == nil then return 0 end
  return v
end

-- true / false / nil, where nil is "we have no proficiency rule for this
-- class yet" and the caller must punt rather than guess.
function BagModel.canEquip(classToken, class, sub)
  if class ~= BagModel.CLASS_ARMOR then return nil end
  if classToken and BagModel.CLOTH_CLASSES[classToken] then
    return (sub == BagModel.ARMOR_CLOTH or sub == BagModel.ARMOR_MISC)
  end
  return nil
end

-- One item -> { tag, reason, sell, equipSlot? }. ORDER MATTERS; first match
-- wins. Keep the order comment honest, it is the spec.
function BagModel.decide(item, level, classToken, equipped)
  item = item or {}
  equipped = equipped or {}
  local row = item.data
  if not row then
    return { tag = BagModel.HOLD, reason = "unknown item", sell = 0 }
  end
  local f = BagModel.field
  local class = f(row, "class")
  local sub = f(row, "sub")
  local q = f(row, "q")
  local sell = f(row, "sell")
  local req = f(row, "req")
  local ilvl = f(row, "lvl")
  local slot = f(row, "slot")

  -- 1. Quest items are never sold and never dropped, whatever they are
  --    worth. This sits FIRST precisely so a high sell price cannot reach
  --    the gray rule below and vendor away a quest chain.
  if class == BagModel.CLASS_QUEST then
    return { tag = BagModel.KEEP_QUEST, reason = "quest item", sell = sell }
  end

  -- 2. Gray with a vendor price: the reason to walk to a merchant at all.
  if q == 0 and sell > 0 then
    return { tag = BagModel.SELL, reason = "gray", sell = sell }
  end

  -- 3. Equippable upgrade. A miss here does not end the decision — it
  --    records WHY it missed and falls through to the HOLD rules, so the
  --    window can say "needs level 20" instead of a bare "hold".
  local equipHold = nil
  local slotKey = BagModel.EQUIP_SLOT[slot]
  if slotKey then
    local wearable = BagModel.canEquip(classToken, class, sub)
    if wearable == nil then
      equipHold = "equippable — no proficiency rule"
    elseif not wearable then
      equipHold = "not your armor type"
    elseif req > level then
      equipHold = "needs level " .. req
    else
      local cur = equipped[slotKey]
      if not cur then
        return { tag = BagModel.EQUIP, sell = sell, equipSlot = slotKey,
          reason = slotKey .. " slot is empty" }
      end
      local curLvl = f(cur, "lvl")
      if ilvl > curLvl then
        return { tag = BagModel.EQUIP, sell = sell, equipSlot = slotKey,
          reason = string.format("%s upgrade il%d>%d", slotKey, ilvl, curLvl) }
      end
      equipHold = string.format("%s il%d <= worn il%d", slotKey, ilvl, curLvl)
    end
  elseif BagModel.MANUAL_SLOT[slot] then
    equipHold = BagModel.MANUAL_SLOT[slot] .. " — your call"
  end

  -- 4. Gray with NO vendor price is NOT "sell it for nothing" — there is
  --    nothing to sell it FOR. It is the drop-when-bags-are-full pile, so it
  --    holds with a reason that says so and never sends anyone to a vendor.
  if q == 0 and sell == 0 then
    return { tag = BagModel.HOLD, reason = equipHold or "no value", sell = 0 }
  end

  if equipHold then
    return { tag = BagModel.HOLD, reason = equipHold, sell = sell }
  end

  -- 5. Everything else holds, with a reason. Consumables get the honest
  --    "USE is not built yet" instead of being lumped into "keep".
  if class == BagModel.CLASS_CONSUMABLE then
    return { tag = BagModel.HOLD, reason = "consumable — USE not implemented",
      sell = sell }
  end
  return { tag = BagModel.HOLD, reason = "keep", sell = sell }
end

-- snapshot = {
--   items  = { { id, count, name?, bag?, bagSlot?, data = <ItemData row or nil> } },
--   player = { level, classToken, equipped = { <slotKey> = <ItemData row> } },
-- }
-- `bag`/`bagSlot` are the container coordinates (deliberately NOT called
-- `slot` — in a row, `slot` is inventory_type, and one name for two numbers
-- is how a bag-slot index ends up compared against INVTYPE_HEAD).
-- -> { items = { { id, count, name, bag, bagSlot, tag, reason, sell } },
--      sellCopper, sellCount, unknown }
function BagModel.evaluate(snapshot)
  snapshot = snapshot or {}
  local player = snapshot.player or {}
  local level = player.level or 1
  local classToken = player.classToken
  local equipped = player.equipped or {}
  local items = snapshot.items or {}
  local out = { items = {}, sellCopper = 0, sellCount = 0, unknown = 0 }
  local i, n = 1, bagGetn(items)
  while i <= n do
    local it = items[i] or {}
    local d = BagModel.decide(it, level, classToken, equipped)
    d.id, d.name, d.bag, d.bagSlot = it.id, it.name, it.bag, it.bagSlot
    d.count = it.count or 1
    if d.tag == BagModel.SELL then
      out.sellCount = out.sellCount + 1
      out.sellCopper = out.sellCopper + (d.sell or 0) * d.count
    end
    if not it.data then out.unknown = out.unknown + 1 end
    out.items[i] = d
    i = i + 1
  end
  return out
end

ShadowArmy.bagModel = BagModel

--------------------------------------------------------------------------
-- Pure inventory-over-chat encoder (r49, ticket 0052). The realm DB only
-- learns about bags on its save interval — the staleness that killed the old
-- breadcrumbs poller — but the addon already owns a live outbound channel:
-- F.emit -> SendChatMessage(SAY) -> Chat.log -> The System's tail. So the
-- bags go out as plain ASCII over that same bus. No base64: a human reading
-- Chat.log has to be able to see what happened.
--
-- WIRE FORMAT (the System side parses exactly this):
--   <SA> inv  <seq>/<total> <id>:<count>,<id>:<count>,...   full snapshot
--   <SA> invd <seq>/<total> +<id>:<count>,-<id>,...          delta
-- `inv` REPLACES the known inventory once all <total> lines of a set are in
-- hand; a set with a missing line is incomplete and must not be applied
-- (these lines are DROPPABLE — see F.emit — so under queue pressure they are
-- exactly what gets thrown away, and never an err/loaded line).
-- `invd` PATCHES it: `+id:count` sets that id's new TOTAL count (not a
-- difference — an absolute set is idempotent and self-heals a lost line),
-- `-id` removes the id entirely. Counts are summed across bags 0-4, so one
-- id appears once per line-set however many stacks it occupies.
--
-- Pure: no WoW API, no frames, no globals — lua/tests drives it on host Lua,
-- and the bots inherit the same encoder for free.
--------------------------------------------------------------------------

local InvModel = {}

-- 1.12 chat accepts 255; 240 leaves room for the server's own decoration in
-- Chat.log and for a "99/99" header on a very full set.
InvModel.LINE_MAX = 240
InvModel.KIND_FULL = "inv"
InvModel.KIND_DELTA = "invd"
InvModel.HEADER_MAX = 6        -- "99/99 " — the widest header we can produce

-- The exact string F.emit puts on the wire, so tests measure the real thing.
function InvModel.chatLine(kind, text)
  return "<SA> " .. kind .. " " .. text
end

-- How many payload chars a single line of `kind` may carry.
function InvModel.budget(kind, lineMax)
  lineMax = lineMax or InvModel.LINE_MAX
  return lineMax - string.len(InvModel.chatLine(kind, "")) - InvModel.HEADER_MAX
end

-- rows = { { id = <item id>, count = <stack size> }, ... }, one per occupied
-- bag slot -> { [id] = total count }. A row with no id (a link we could not
-- parse) is dropped rather than reported as item nil.
function InvModel.aggregate(rows)
  local out = {}
  local i = 1
  while rows and rows[i] ~= nil do
    local r = rows[i]
    if r.id then
      out[r.id] = (out[r.id] or 0) + (r.count or 1)
    end
    i = i + 1
  end
  return out
end

-- Ids ascending keeps every line deterministic, which is what makes the 30s
-- identical-message dedupe in F.emit a feature (an unchanged bag re-encodes
-- to the same bytes) instead of a coin flip.
-- (On InvModel, not a file local: main-chunk registers are the scarce
-- resource here — same reason as QuestModel's mask helpers above.)
function InvModel.sortedIds(a, b)
  local ids, n = {}, 0
  for id in pairs(a or {}) do
    n = n + 1
    ids[n] = id
  end
  if b then
    for id in pairs(b) do
      if (a or {})[id] == nil then
        n = n + 1
        ids[n] = id
      end
    end
  end
  if n > 1 then table.sort(ids) end
  return ids, n
end

function InvModel.snapshotTokens(state)
  local ids, n = InvModel.sortedIds(state)
  local tokens = {}
  local i = 1
  while i <= n do
    tokens[i] = ids[i] .. ":" .. state[ids[i]]
    i = i + 1
  end
  return tokens, n
end

-- prev/cur are aggregate maps. Unchanged ids produce nothing at all, so an
-- idle player costs zero chat lines.
function InvModel.deltaTokens(prev, cur)
  prev = prev or {}
  cur = cur or {}
  local ids, n = InvModel.sortedIds(cur, prev)
  local tokens, nt = {}, 0
  local i = 1
  while i <= n do
    local id = ids[i]
    local now, was = cur[id], prev[id]
    if now == nil then
      nt = nt + 1
      tokens[nt] = "-" .. id
    elseif now ~= was then
      nt = nt + 1
      tokens[nt] = "+" .. id .. ":" .. now
    end
    i = i + 1
  end
  return tokens, nt
end

-- Greedy pack: tokens joined with "," until the next one would overflow.
function InvModel.pack(tokens, n, budget)
  local parts, np, cur = {}, 0, nil
  local i = 1
  while i <= n do
    local t = tokens[i]
    if cur == nil then
      cur = t
    elseif string.len(cur) + 1 + string.len(t) <= budget then
      cur = cur .. "," .. t
    else
      np = np + 1
      parts[np] = cur
      cur = t
    end
    i = i + 1
  end
  if cur ~= nil then
    np = np + 1
    parts[np] = cur
  end
  return parts, np
end

-- tokens -> the `text` arguments for F.emit(kind, text), numbered. The header
-- is sized for the WORST case (HEADER_MAX) before the packing runs, so the
-- count of lines can never invalidate the budget the packing used.
function InvModel.lines(kind, tokens, n, lineMax)
  local parts, np = InvModel.pack(tokens, n, InvModel.budget(kind, lineMax))
  if np == 0 then
    -- Empty bags are a fact, not a non-event: "1/1" with no payload tells
    -- The System the inventory is empty instead of leaving stale items up.
    return { "1/1" }, 1
  end
  local out = {}
  local i = 1
  while i <= np do
    out[i] = string.format("%d/%d ", i, np) .. parts[i]
    i = i + 1
  end
  return out, np
end

function InvModel.snapshotLines(state, lineMax)
  local tokens, n = InvModel.snapshotTokens(state)
  return InvModel.lines(InvModel.KIND_FULL, tokens, n, lineMax)
end

-- Nothing changed -> no lines at all (n == 0), NOT an empty-set line.
function InvModel.deltaLines(prev, cur, lineMax)
  local tokens, n = InvModel.deltaTokens(prev, cur)
  if n == 0 then return {}, 0 end
  return InvModel.lines(InvModel.KIND_DELTA, tokens, n, lineMax)
end

ShadowArmy.invModel = InvModel

-- Unit tests load this file without the WoW UI and stop after the pure model.
if not CreateFrame then return end

-- Lua 5.0 hard limit: 200 locals per function. Helpers live on F.
local F = {}

-- Bump on every edit. The System watches Chat.log for "<SA> loaded rev=..."
-- after sending a reload — a new rev proves the edit actually loaded.
local REV = "r58"

-- Log window (r16): every F.say()/F.emit() line also lands here with a
-- timestamp, so errors survive chat scroll-off and can be reviewed in-game.
-- ScrollingMessageFrame is the same widget chat frames are built on —
-- free history, free scrolling. Forward-declared; UI built after the panel.
-- F.addLog assigned when log UI is built

function F.say(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cFF9482C9[ShadowArmy]|r " .. tostring(msg))
  if F.addLog then F.addLog("say", tostring(msg)) end
end

-- /say lands in the server's Chat.log; The System tails it. This is
-- the addon's only outbound channel.
-- r11 flood control (live incident): the trace firehose tripped the server's
-- chat throttle — "you must wait 4s before speaking again" — which blocked
-- the HUMAN's own chat too. So nothing is sent straight from the call site
-- any more. F.emit() queues; the driver's OnUpdate drains at most one line per
-- EMIT_GAP seconds. The queue is deliberately tiny and priority-aware: under
-- pressure we throw away chatter (traces) and never the lines The System
-- actually reads (loaded / reloading / reload-click / err / pong / status).
local EMIT_GAP = 2.0        -- seconds between ANY two sends
local EMIT_QUEUE_MAX = 5
-- r49: inventory lines (ticket 0052) join traces as droppable chatter. A
-- snapshot is re-sent every 5 minutes anyway, so losing one to queue pressure
-- costs nothing — crowding out an `err` would cost a debugging session.
local DROPPABLE = { trace = true, inv = true, invd = true }

local emitQueue = {}        -- FIFO of { msg = string, drop = bool }
local lastSendAt = 0
local lastEmitMsg, lastEmitTime = nil, 0 -- 30s identical-message dedupe

function F.emit(kind, text)
  local msg = "<SA> " .. kind .. " " .. text
  local now = GetTime()
  if msg == lastEmitMsg and (now - lastEmitTime) < 30 then
    return
  end
  lastEmitMsg = msg
  lastEmitTime = now
  if F.addLog then F.addLog(kind, text) end
  local droppable = DROPPABLE[kind] and true or false
  if table.getn(emitQueue) >= EMIT_QUEUE_MAX then
    -- Make room: evict the oldest droppable line first.
    local victim = nil
    local i = 1
    while i <= table.getn(emitQueue) do
      if emitQueue[i].drop then
        victim = i
        break
      end
      i = i + 1
    end
    if victim then
      table.remove(emitQueue, victim)
    elseif droppable then
      return -- queue is all must-send lines; this trace is what gives way
    else
      table.remove(emitQueue, 1) -- all must-send: sacrifice the stalest
    end
  end
  table.insert(emitQueue, { msg = msg, drop = droppable })
end

-- Called every frame by the driver; sends at most one queued line.
function F.emitDrain()
  if table.getn(emitQueue) == 0 then
    return
  end
  local now = GetTime()
  if now - lastSendAt < EMIT_GAP then
    return
  end
  lastSendAt = now
  local item = table.remove(emitQueue, 1)
  SendChatMessage(item.msg, "SAY")
end

-- Diagnosis mode (r7): trace every action attempt so the telemetry shows
-- WHERE each path dies. OFF by default since r11 — left on, the traces
-- tripped the server chat throttle and locked the human out of their own
-- /F.say. Opt in with `<SYS> debug on`, off again with `<SYS> debug off`.
local debugMode = false
function F.dtrace(text)
  if debugMode then
    F.emit("trace", text)
  end
end

--------------------------------------------------------------------------
-- Grind tracking: XP/hour + time-to-level from session deltas.
--------------------------------------------------------------------------

local grind = {
  startTime = nil,   -- GetTime() at session start (login/reload)
  startXP = nil,
  kills = 0,
}

function F.fmtDuration(seconds)
  if seconds ~= seconds or seconds < 0 or seconds > 359999 then
    return "--"
  end
  local h = math.floor(seconds / 3600)
  local m = math.floor(math.mod(seconds, 3600) / 60)
  if h > 0 then
    return string.format("%dh%02dm", h, m)
  end
  return string.format("%dm", m)
end

function F.grindStats()
  if not grind.startTime then
    return 0, "--"
  end
  local elapsed = GetTime() - grind.startTime
  if elapsed < 30 then
    return 0, "--" -- too early to extrapolate
  end
  local gained = UnitXP("player") - grind.startXP
  if gained <= 0 then
    return 0, "--"
  end
  local perHour = gained / (elapsed / 3600)
  local toLevel = UnitXPMax("player") - UnitXP("player")
  return math.floor(perHour), F.fmtDuration(toLevel / (perHour / 3600))
end

--------------------------------------------------------------------------
-- Advisor panel: draggable window with live lines + buttons.
--------------------------------------------------------------------------

-- r32: room for quest checklist under grind lines.
-- r47: +24 for a fourth button row (Bags). Buttons anchor to the panel BOTTOM
-- and the panel anchors by TOPRIGHT, so the extra row grows downward and the
-- checklist lines above it do not move.
local PANEL_BASE_HEIGHT = 324
-- r43: anchored by TOPRIGHT so the passive row growing the panel pushes only
-- downward. A RIGHT anchor grows from the center and shifts every line above
-- it too. Y keeps the top edge exactly where the old RIGHT/-40/60 anchor put
-- it at base height (60 + half the panel).
local PANEL_TOP_Y = 60 + PANEL_BASE_HEIGHT / 2
local panel = CreateFrame("Frame", "ShadowArmyPanel", UIParent)
panel:SetWidth(210)
panel:SetHeight(PANEL_BASE_HEIGHT)
panel:SetPoint("TOPRIGHT", UIParent, "RIGHT", -40, PANEL_TOP_Y)
panel:SetFrameStrata("HIGH")
panel:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
panel:SetBackdropColor(0.05, 0.02, 0.10, 0.85)
panel:EnableMouse(true)
panel:SetMovable(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", function() panel:StartMoving() end)
panel:SetScript("OnDragStop", function() panel:StopMovingOrSizing() end)
-- Start visible; /sa toggles. CreateFrame defaults are fine, but an explicit
-- Show() after strata/backdrop avoids "loaded but nowhere" on some clients.
panel:Show()

function F.panelShowReset()
  -- Recover from off-screen drag or a hide that left no way back.
  panel:ClearAllPoints()
  panel:SetPoint("TOPRIGHT", UIParent, "RIGHT", -40, PANEL_TOP_Y)
  panel:Show()
end

local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", panel, "TOP", 0, -8)
title:SetText("|cFF9482C9Shadow Advisor|r")

function F.makeLine(prev, offset)
  local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  fs:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, offset or -3)
  fs:SetJustifyH("LEFT")
  fs:SetText("")
  return fs
end

-- anchor the first line under the title, left-aligned to the panel
local line1 = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
line1:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -26)
line1:SetJustifyH("LEFT")
local line2 = F.makeLine(line1)
local line3 = F.makeLine(line2)
local line4 = F.makeLine(line3)
local line5 = F.makeLine(line4, -6) -- buff watch / warnings

-- r42: long-term passive upkeep buttons (missing self-buff, missing minion).
-- Frames are built once here and only shown/hidden on refresh. An idle row
-- still costs 5px (1px minimum height + its 4px gap), so the checklist below
-- sits 5px lower than it did in r41; from there it only moves when a button
-- actually appears, and r43's TOPRIGHT panel anchor keeps that growth
-- downward.
--
-- r46 (ticket 0042): they are ability icons now, not red text slabs — square
-- spell-texture buttons with a hover tooltip. Still two per row, still four
-- frames, so the row/panel height math below only needs the new step.
local PASSIVE_MAX_BUTTONS = 4
local PASSIVE_BTN_SIZE = 24
local PASSIVE_BTN_GAP = 4
local PASSIVE_BTN_STEP = PASSIVE_BTN_SIZE + PASSIVE_BTN_GAP
-- Used when the spell has no captured texture yet (scan has not run, or the
-- spell is not in the book). An icon button with no icon reads as broken.
local PASSIVE_ICON_FALLBACK = "Interface\\Icons\\INV_Misc_QuestionMark"
local passiveRow = CreateFrame("Frame", "ShadowArmyPassiveRow", panel)
passiveRow:SetPoint("TOPLEFT", line5, "BOTTOMLEFT", 0, -4)
passiveRow:SetWidth(194)
passiveRow:SetHeight(1)
local passiveBtns = {}
local _pbi = 1
while _pbi <= PASSIVE_MAX_BUTTONS do
  local b = CreateFrame("Button", "ShadowArmyPassiveBtn" .. _pbi, passiveRow)
  b:SetWidth(PASSIVE_BTN_SIZE)
  b:SetHeight(PASSIVE_BTN_SIZE)
  b:SetPoint("TOPLEFT", passiveRow, "TOPLEFT",
    math.mod(_pbi - 1, 2) * PASSIVE_BTN_STEP,
    -math.floor((_pbi - 1) / 2) * PASSIVE_BTN_STEP)
  local icon = b:CreateTexture("ShadowArmyPassiveBtn" .. _pbi .. "Icon", "BACKGROUND")
  icon:SetAllPoints(b)
  icon:SetTexture(PASSIVE_ICON_FALLBACK)
  b.icon = icon
  b:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
  -- Additive highlight is the stock icon-button look; the getter is guarded
  -- because this build's widget surface is not the reference one.
  if b.GetHighlightTexture then
    local hl = b:GetHighlightTexture()
    if hl and hl.SetBlendMode then hl:SetBlendMode("ADD") end
  end
  b:SetScript("OnClick", function()
    F.passiveClick(this.passiveSpell, this.passiveSelf)
  end)
  b:SetScript("OnEnter", function()
    if not this.passiveSpell then return end
    GameTooltip:SetOwner(this, "ANCHOR_LEFT")
    GameTooltip:SetText(this.passiveLabel or this.passiveSpell)
    if this.passiveRank then GameTooltip:AddLine(this.passiveRank, 0.8, 0.8, 0.8) end
    -- r49 (ticket 0058): the button shows even when the advisor is already
    -- trying to cast this itself, so the tooltip says why there are two
    -- things working on the same buff.
    if this.passiveAuto then
      GameTooltip:AddLine("autocast armed - click to force", 0.55, 0.75, 1.0)
    end
    -- r55: the button no longer hides itself in combat, so it says out loud
    -- that the timing is the human's decision rather than pretending the
    -- upkeep is fine (which is what hiding it amounted to).
    if this.passiveCombat then
      GameTooltip:AddLine("in combat - your call", 1.0, 0.82, 0.0)
    end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:Hide()
  passiveBtns[_pbi] = b
  _pbi = _pbi + 1
end

-- r32: multi-line quest checklist (quest identity + objectives). line6 is
-- slot 1 so corpse-run can still steal the first row while ghosting.
local QUEST_PANEL_LINES = 8
-- r47: character budget for the hunt-hint sub-line. The panel is 210px wide
-- with 194px of usable room, GameFontNormalSmall averages ~5.5px/char, so a
-- row holds roughly 35 characters; the sub-line spends 11 of them on its
-- "      from " prefix. QuestModel.fromText drops NAMES to fit this rather
-- than letting a FontString run off the panel edge (1.12 FontStrings with no
-- width neither wrap nor clip — they just overhang).
local QUEST_HINT_CHARS = 24
local questLines = {}
questLines[1] = F.makeLine(passiveRow, -6)
local _qli = 2
while _qli <= QUEST_PANEL_LINES do
  questLines[_qli] = F.makeLine(questLines[_qli - 1], -2)
  _qli = _qli + 1
end
local line6 = questLines[1]

-- (v0.1 had Nearest-foe/Attack buttons; removed — they duplicated Tab and
-- the T auto-attack keybind. Rule: a button earns its place only by doing
-- something the default UI can't. Full-auto combat qualifies.)

--------------------------------------------------------------------------
--------------------------------------------------------------------------
-- Combat coach (r38): recommendation-first advice table with the most exact
-- state the stock 1.12 API exposes. Range/usability/cooldown are exact when a spell is
-- on any action slot; fallbacks are explicitly approximate.
--------------------------------------------------------------------------

local auto = {
  casting = false, castingSince = 0, gcdUntil = 0, failUntil = 0,
  shooting = false, melee = false,
  known = {}, spells = {}, actionSlots = {},
  classToken = nil, classLabel = nil, failure = nil, lastAttempt = nil,
}

-- 1.12 has no IsMoving(); sample map position deltas for cast vs wand tips.
local move = { x = 0, y = 0, at = 0, moving = false }
function F.updateMoving()
  local x, y = GetPlayerMapPosition("player")
  if x and (x ~= 0 or y ~= 0) then
    if x ~= move.x or y ~= move.y then
      move.moving = true
      move.at = GetTime()
    elseif GetTime() - move.at > 0.3 then
      move.moving = false
    end
    move.x, move.y = x, y
  else
    move.moving = false
  end
end

function F.combatDefs()
  return CombatModel.actions[auto.classToken or ""] or {}
end

function F.scanCombatActions()
  auto.actionSlots = {}
  local defs = F.combatDefs()
  local slot = 1
  while slot <= 120 do
    if HasAction(slot) and (not IsConsumableAction or not IsConsumableAction(slot)) then
      local texture = GetActionTexture(slot)
      if texture then
        local i = 1
        while i <= table.getn(defs) do
          local def = defs[i]
          local book = def.spell and auto.spells[string.lower(def.spell)] or nil
          if book and book.texture == texture and not auto.actionSlots[string.lower(def.spell)] then
            auto.actionSlots[string.lower(def.spell)] = slot
          end
          i = i + 1
        end
      end
    end
    slot = slot + 1
  end
end

-- r46 (ticket 0041): the coach needs each spell's REAL mana cost, and 1.12 has
-- no GetSpellCost — the spellbook tooltip is the only source. One hidden
-- tooltip, built here at load and never per scan.
local bookTip = CreateFrame("GameTooltip", "ShadowArmyBookTip", UIParent,
  "GameTooltipTemplate")
bookTip:SetOwner(UIParent, "ANCHOR_NONE")

-- Cost lives in the tooltip's header block (line 2 in practice); a few lines of
-- slack covers reagent/requires lines without reaching the description, where a
-- sentence could otherwise look like a cost.
local BOOK_TIP_LINES = 6

-- Mana cost of spellbook entry `index`, or nil for a costless/non-mana spell
-- and for any read that did not populate.
--
-- CONSTRAINT (r46, docs/vanilla-addons/client-quirks.md): tooltip populate
-- calls on this wine 1.12 build return NO flag, so SetSpell's return value is
-- never consulted. Every line we are about to read is blanked FIRST, exactly
-- like F.barSlotName does for SetAction; text read back after SetSpell can then
-- only have come from this spell. A failed read yields nil, and the model falls
-- back to its percent gate rather than inventing a cost.
function F.spellCost(index)
  bookTip:SetOwner(UIParent, "ANCHOR_NONE")
  bookTip:ClearLines()
  local i = 1
  while i <= BOOK_TIP_LINES do
    local left = getglobal("ShadowArmyBookTipTextLeft" .. i)
    local right = getglobal("ShadowArmyBookTipTextRight" .. i)
    if left then left:SetText(nil) end
    if right then right:SetText(nil) end
    i = i + 1
  end
  if not pcall(bookTip.SetSpell, bookTip, index, "spell") then return nil end
  i = 1
  while i <= BOOK_TIP_LINES do
    local side = 1
    while side <= 2 do
      local name = "ShadowArmyBookTipText" .. (side == 1 and "Left" or "Right") .. i
      local fs = getglobal(name)
      local text = fs and fs:GetText()
      if text and text ~= "" then
        local _, _, cost = string.find(text, "^(%d+) Mana")
        if cost then return tonumber(cost) end
      end
      side = side + 1
    end
    i = i + 1
  end
  return nil
end

function F.scanSpellbook()
  auto.known, auto.spells = {}, {}
  local classLabel, classToken = UnitClass("player")
  auto.classLabel = classLabel or "Unknown"
  -- Vanilla's second return is the English class name, not guaranteed to
  -- be the uppercase token used by later clients.
  auto.classToken = string.upper(classToken or classLabel or "")
  local i = 1
  while true do
    local name, rank = GetSpellName(i, "spell")
    if not name then break end
    local key = string.lower(name)
    auto.known[key] = true
    -- Ranks are walked upward and overwrite, so `index` names the highest
    -- trained rank — `cost` is read from that same index and stays consistent
    -- with it.
    auto.spells[key] = {
      name = name, rank = rank, index = i,
      texture = GetSpellTexture(i, "spell"),
      cost = F.spellCost(i),
    }
    i = i + 1
  end
  F.scanCombatActions()
end

function F.unitHasTexture(unit, helpful, texture)
  if not texture then return false end
  local i = 1
  while i <= 32 do
    local tex
    if helpful then tex = UnitBuff(unit, i) else tex = UnitDebuff(unit, i) end
    if not tex then return false end
    if tex == texture then return true end
    i = i + 1
  end
  return false
end

function F.targetHasDebuff(texture)
  return F.unitHasTexture("target", false, texture)
end

function F.cooldownRemaining(start, duration, enable)
  if not start or not duration or duration <= 0 or enable == 0 then return 0 end
  local left = start + duration - GetTime()
  if left < 0 then return 0 end
  return left
end

function F.currentDruidForm()
  if auto.classToken ~= "DRUID" then return "humanoid" end
  local i = 1
  while i <= (GetNumShapeshiftForms() or 0) do
    local texture, name, active = GetShapeshiftFormInfo(i)
    if active then
      local lower = string.lower(name or texture or "")
      if string.find(lower, "cat", 1, true) then return "cat" end
      if string.find(lower, "bear", 1, true) then return "bear" end
      if string.find(lower, "moonkin", 1, true) then return "humanoid" end
      return "other"
    end
    i = i + 1
  end
  return "humanoid"
end

function F.combatActionState(def, snapshot)
  local state = { known = false, range = "na", cooldown = 0 }
  if def.kind == "melee" then
    state.known = true
    state.active = auto.melee
    state.activeReason = "swinging"
    if snapshot.hostile then
      state.range = CheckInteractDistance("target", 3) and "approx_in" or "approx_far"
    end
    return state
  end
  local key = string.lower(def.spell or "")
  local book = auto.spells[key]
  if not book then return state end
  state.known, state.texture = true, book.texture
  state.slot = auto.actionSlots[key]
  if state.slot then
    local usable, noResource = IsUsableAction(state.slot)
    state.usable = usable and true or false
    state.noResource = noResource and true or false
    local start, duration, enable = GetActionCooldown(state.slot)
    state.cooldown = F.cooldownRemaining(start, duration, enable)
    state.gcd = duration and duration > 0 and duration <= 1.6 and state.cooldown > 0
    if state.gcd then snapshot.gcd = true end
    state.active = (IsCurrentAction(state.slot) or IsAutoRepeatAction(state.slot)) and true or false
    if def.target == "hostile" and ActionHasRange(state.slot) then
      local inRange = IsActionInRange(state.slot)
      if inRange == 1 then state.range = "in"
      elseif inRange == 0 then state.range = "out"
      else state.range = "unknown" end
    end
  else
    state.usable = true
    local start, duration, enable = GetSpellCooldown(book.index, "spell")
    state.cooldown = F.cooldownRemaining(start, duration, enable)
    state.gcd = duration and duration > 0 and duration <= 1.6 and state.cooldown > 0
    if state.gcd then snapshot.gcd = true end
    if def.target == "hostile" and snapshot.hostile then
      state.range = CheckInteractDistance("target", 4) and "approx_in" or "approx_far"
    end
  end
  if def.id == "shoot" then
    state.active = auto.shooting
    state.activeReason = "firing"
    if not snapshot.hasWand then
      state.usable = false
      state.unusableReason = "no wand"
    end
  end
  if state.noResource then state.resourceReason = snapshot.resourceLowReason end
  if def.debuff and snapshot.hostile then state.debuff = F.targetHasDebuff(book.texture) end
  if def.buff then state.buff = F.unitHasTexture("player", true, book.texture) end
  if def.setsForm and snapshot.form == def.setsForm then
    state.active = true
    state.activeReason = "active form"
  end
  return state
end

function F.combatDanger()
  if not UnitExists("target") or not UnitCanAttack("player", "target") then return false, nil end
  local class = UnitClassification("target")
  if class == "worldboss" then return true, "BOSS" end
  if class == "elite" or class == "rareelite" then return true, "ELITE" end
  local level = UnitLevel("target") or 0
  if level < 0 then return true, "SKULL" end
  if level >= UnitLevel("player") + 3 then return true, "+3 LEVEL" end
  if UnitIsTapped("target") and not UnitIsTappedByPlayer("target") then return true, "TAPPED" end
  return false, nil
end

function F.combatSnapshot()
  local hasTarget = UnitExists("target") and true or false
  local targetDead = hasTarget and UnitIsDeadOrGhost("target") and true or false
  local hostile = hasTarget and not targetDead and UnitCanAttack("player", "target") and true or false
  local hpMax, powerMax = UnitHealthMax("player"), UnitManaMax("player")
  local powerType = UnitPowerType("player") or 0
  local resourceNames = { [0] = "mana", [1] = "rage", [3] = "energy" }
  local resourceName = resourceNames[powerType] or "power"
  local danger, dangerLabel = F.combatDanger()
  local snapshot = {
    classToken = auto.classToken, classLabel = auto.classLabel,
    form = F.currentDruidForm(),
    playerDead = UnitIsDeadOrGhost("player") and true or false,
    hpPct = hpMax > 0 and UnitHealth("player") / hpMax * 100 or 0,
    -- r46: POINTS are what the coach gates on (cost vs. pool). powerPct stays
    -- for display and for the percent fallback when cost data is missing.
    power = UnitMana("player") or 0,
    powerMax = powerMax or 0,
    powerPct = powerMax > 0 and UnitMana("player") / powerMax * 100 or 0,
    resourceName = resourceName, resourceLowReason = resourceName .. " low",
    moving = move.moving, casting = auto.casting,
    hasTarget = hasTarget, targetDead = targetDead, hostile = hostile,
    targetName = hasTarget and (UnitName("target") or "?") or nil,
    targetLevel = hasTarget and UnitLevel("target") or nil,
    targetHpPct = hasTarget and UnitHealthMax("target") > 0
      and UnitHealth("target") / UnitHealthMax("target") * 100 or 0,
    danger = danger, dangerLabel = dangerLabel,
    combo = GetComboPoints() or 0,
    hasWand = GetInventoryItemLink("player", 18) and true or false,
    shooting = auto.shooting, melee = auto.melee,
    actions = {}, costs = {},
  }
  local defs = F.combatDefs()
  local i = 1
  while i <= table.getn(defs) do
    local def = defs[i]
    snapshot.actions[def.id] = F.combatActionState(def, snapshot)
    -- Missing entry (untrained, non-mana, or an unreadable tooltip) is left
    -- absent on purpose: the model reads that as "no cost data" and falls back
    -- to its percent gate.
    local book = def.spell and auto.spells[string.lower(def.spell)] or nil
    if book and book.cost then snapshot.costs[def.id] = book.cost end
    i = i + 1
  end
  return snapshot
end

function F.combatFailureCodes()
  local codes = {}
  local function add(value, code) if value then codes[value] = code end end
  add(ERR_BADATTACKFACING, "facing")
  add(ERR_USE_BAD_ANGLE, "facing")
  add(ERR_WRONG_DIRECTION_FOR_ATTACK, "facing")
  add(SPELL_FAILED_NOT_INFRONT, "facing")
  add(SPELL_FAILED_UNIT_NOT_INFRONT, "facing")
  add(SPELL_FAILED_LINE_OF_SIGHT, "los")
  add(SPELL_FAILED_OUT_OF_RANGE, "range")
  add(ERR_BADATTACKPOS, "range")
  add(SPELL_FAILED_MOVING, "moving")
  add(ERR_OUT_OF_MANA, "mana")
  add(ERR_OUT_OF_RAGE, "rage")
  add(ERR_OUT_OF_ENERGY, "energy")
  add(SPELL_FAILED_NOT_READY, "cooldown")
  add(SPELL_FAILED_BAD_TARGETS, "target")
  add(SPELL_FAILED_TARGETS_DEAD, "target")
  return codes
end

function F.combatRecordFailure(message)
  local failure = CombatModel.classifyFailure(message, F.combatFailureCodes())
  if failure then
    failure.at = GetTime()
    failure.actionId = auto.lastAttempt and auto.lastAttempt.id or nil
    auto.failure = failure
    if F.addLog then F.addLog("combat", failure.label) end
  end
end

function F.combatFailure()
  if auto.failure and GetTime() - auto.failure.at <= 2.5 then return auto.failure end
  auto.failure = nil
  return nil
end

-- Shared by the combat buttons and the legacy armor path.
function F.castNow(spell, onSelf)
  F.dtrace("cast " .. spell)
  CastSpellByName(spell, onSelf)
  auto.gcdUntil = GetTime() + 1.6
end

function F.combatUse(id)
  if auto.casting then return end
  local def = CombatModel.action(auto.classToken, id)
  if not def then return end
  auto.lastAttempt = { id = id, at = GetTime(), target = UnitName("target") }
  if def.kind == "melee" then
    if UnitExists("target") and UnitCanAttack("player", "target")
        and not UnitIsDeadOrGhost("target") then AttackTarget() end
  elseif def.kind == "spell" and def.spell and auto.known[string.lower(def.spell)] then
    F.castNow(def.spell, def.selfCast and 1 or nil)
  end
end

local suggestedKeySeen = false

-- Called from the stock ACTIONBUTTON1 key-release path, which preserves the
-- real hardware event. Re-evaluate at press time instead of trusting the last
-- rendered row: target, range, resources, or recommendation may have changed.
function ShadowArmy.UseSuggested()
  if auto.casting then return end
  F.updateMoving()
  local snapshot = F.combatSnapshot()
  local result = CombatModel.evaluate(snapshot)
  if result.nextId then
    if not suggestedKeySeen then
      suggestedKeySeen = true
      F.emit("bindpress", "key=1 suggested=" .. result.nextId)
    end
    F.combatUse(result.nextId)
  end
end

-- r47 (ticket 0049): key 2 is the PASSIVE row, on the same hook as key 1.
--
-- The row's order IS the model's order — PassiveModel.evaluate emits the
-- buff buttons before the summon — so "first active button" is
-- `result.buttons[1]` and nothing here re-sorts it. The press re-evaluates
-- instead of reading the last painted row, for the same reason key 1 does:
-- a minion can die, a buff can drop, between the paint and the keypress.
local passiveKeySeen = false

-- The button key 2 would cast right now, or nil. No side effects, so the
-- key hook can ask "do I own this press?" before committing to it.
function F.passiveEvaluate()
  return PassiveModel.evaluate(F.passiveSnapshot())
end

function F.passiveKeyWant()
  if auto.casting then return nil end
  -- The SNAPSHOT is inside the pcall too: it reads UnitBuff, the spellbook
  -- scan and the pet, and this runs on a keypress. An error escaping here
  -- would take ActionButtonUp with it and the human's key 2 would just die.
  local ok, result = pcall(F.passiveEvaluate)
  if not ok or not result then return nil end
  local want = result.buttons and result.buttons[1] or nil
  if not want or not want.spell then return nil end
  return want
end

function ShadowArmy.UsePassive(want)
  want = want or F.passiveKeyWant()
  if not want then return false end
  if not passiveKeySeen then
    passiveKeySeen = true
    F.emit("bindpress", "key=2 passive=" .. tostring(want.id))
  end
  -- EXACTLY the path the on-screen button takes, guards included.
  F.passiveClick(want.spell, want.selfCast and 1 or nil)
  return true
end

local stockActionButtonDown = ActionButtonDown
local stockActionButtonUp = ActionButtonUp

-- Stock ActionButtonDown leaves the button depressed; whoever swallows the
-- release owes it the reset UseAction would otherwise have done.
function F.actionButtonClearPushed(id)
  local button
  if BonusActionBarFrame and BonusActionBarFrame:IsShown() then
    button = getglobal("BonusActionButton" .. id)
  else
    button = getglobal("ActionButton" .. id)
  end
  if button and button.GetButtonState and button:GetButtonState() == "PUSHED" then
    button:SetButtonState("NORMAL")
  end
end

function F.installSuggestedKeyHook()
  if not stockActionButtonDown or not stockActionButtonUp then
    F.emit("err", "bind ACTIONBUTTON1/2 hook unavailable")
    return false
  end
  -- Down remains stock so the action button visibly depresses. On key
  -- release, reset that visual without UseAction(slot), then use the coach.
  ActionButtonDown = function(id)
    stockActionButtonDown(id)
  end
  ActionButtonUp = function(id, onSelf)
    if id == 1 then
      F.actionButtonClearPushed(1)
      ShadowArmy.UseSuggested()
      return
    end
    if id == 2 and not (HasAction and HasAction(2)) then
      -- The advisor only OWNS key 2 while slot 2 is empty AND the passive
      -- row has something to cast. An action the human parked in slot 2
      -- always wins; a quiet row falls through to stock behaviour.
      local want = F.passiveKeyWant()
      if want then
        F.actionButtonClearPushed(2)
        ShadowArmy.UsePassive(want)
        return
      end
    end
    stockActionButtonUp(id, onSelf)
  end
  return true
end

function F.bindSuggestedKey()
  local command = "ACTIONBUTTON1"
  if not SetBinding or not SetBinding("1", command) then
    F.say("could not bind suggested ability to 1")
    F.emit("err", "bind key=1 failed")
    return false
  end
  if SaveBindings and GetCurrentBindingSet then
    SaveBindings(GetCurrentBindingSet())
  end
  F.say("1 = suggested ability")
  F.emit("bind", "key=1 action=" .. tostring(GetBindingAction and GetBindingAction("1"))
    .. " driver=advisor-hook")
  return true
end

-- Same binding path as key 1, one key over. ACTIONBUTTON2 is what the hook
-- above intercepts, so the binding and the interception cannot drift apart.
function F.bindPassiveKey()
  local command = "ACTIONBUTTON2"
  if not SetBinding or not SetBinding("2", command) then
    F.say("could not bind passive upkeep to 2")
    F.emit("err", "bind key=2 failed")
    return false
  end
  if SaveBindings and GetCurrentBindingSet then
    SaveBindings(GetCurrentBindingSet())
  end
  F.say("2 = passive upkeep (buff / summon)")
  F.emit("bind", "key=2 action=" .. tostring(GetBindingAction and GetBindingAction("2"))
    .. " driver=advisor-hook")
  return true
end

local combatFrame = CreateFrame("Frame", "ShadowArmyCombatFrame", UIParent)
combatFrame:SetWidth(340)
combatFrame:SetHeight(180)
combatFrame:SetPoint("CENTER", UIParent, "CENTER", 120, 20)
combatFrame:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
combatFrame:SetBackdropColor(0.08, 0.02, 0.10, 0.92)
combatFrame:EnableMouse(true)
combatFrame:SetMovable(true)
combatFrame:RegisterForDrag("LeftButton")
combatFrame:SetScript("OnDragStart", function() combatFrame:StartMoving() end)
combatFrame:SetScript("OnDragStop", function() combatFrame:StopMovingOrSizing() end)
-- r53: open by default (monofuel 2026-08-16) — the coach is the point of the
-- addon during combat. Escape (UISpecialFrames) and /sa combat still close it;
-- the ~4 Hz refresher populates it as soon as it has anything to say.
--
-- r54 (monofuel, third report of "still not open"): r53 delivered that by
-- DELETING the combatFrame:Hide() and leaning on CreateFrame's implicit shown
-- state — an invisible guarantee that any later Hide(), any load-order change,
-- and any restored UI state silently wins. Say it out loud instead, in three
-- places that cannot all be missed: here at creation, at the end of the load
-- (F.combatOpen below the event handler), and once on PLAYER_ENTERING_WORLD.
--
-- r56 — THE ACTUAL HIDER, found in the client's own FrameXML instead of
-- guessed at for a fourth time. `tinsert(UISpecialFrames, ...)` on the line
-- below is not just "Escape closes it". Stock UIParent.lua walks
-- UISpecialFrames in CloseWindows() and hides EVERY visible entry, and
-- CloseAllWindows() is called from:
--
--   * ShowUIPanel() for any panel with area == "full" — and
--     UIPanelWindows["WorldMapFrame"] = { area = "full" } (UIParent.lua:30).
--     OPENING THE WORLD MAP CLOSES THE COACH. That is the loop monofuel has
--     been living in: he opens the map to look for the route the advisor kept
--     claiming to draw, and the map takes the coach out on the way in.
--   * PLAYER_DEAD (UIParent.lua:239)
--   * PLAYER_CONTROL_LOST (UIParent.lua:478) — every fear, charm and mind
--     control, which for a levelling warlock is most fights
--   * ToggleGameMenu / Escape (UIParent.lua:1476, 1491)
--
-- None of those is "the human closed the coach", and r53/r54 both re-asserted
-- the OPEN state at load and at login where none of them had fired yet. So
-- r56 keeps the state instead of asserting it: a Hide the addon did not ask
-- for arms a restore (F.coachGuard, driven at 4 Hz), while the close button
-- and /sa combat set ShadowArmy.coachClosed and are obeyed for the session.
-- Escape now bounces — it shares CloseAllWindows with the map and cannot be
-- told apart from it — which is why the close button is the documented way
-- to put the coach away.
combatFrame:SetFrameStrata("HIGH") -- parity with every other advisor window
combatFrame:Show()
tinsert(UISpecialFrames, "ShadowArmyCombatFrame")

-- Fires for the human's close button, for Escape, and for CloseAllWindows
-- alike. Only the first sets coachClosed, so only the first sticks.
combatFrame:SetScript("OnHide", function()
  if ShadowArmy.coachClosed then return end
  ShadowArmy.coachRestore = true
end)

local combatTitle = combatFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
combatTitle:SetPoint("TOP", combatFrame, "TOP", 0, -8)
combatTitle:SetText("|cFF9482C9Combat coach|r")

local combatClose = CreateFrame("Button", nil, combatFrame, "UIPanelCloseButton")
combatClose:SetPoint("TOPRIGHT", combatFrame, "TOPRIGHT", -2, -2)

local combatStatus = combatFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
combatStatus:SetPoint("TOPLEFT", combatFrame, "TOPLEFT", 12, -28)
combatStatus:SetPoint("TOPRIGHT", combatFrame, "TOPRIGHT", -12, -28)
combatStatus:SetHeight(32)
combatStatus:SetJustifyH("LEFT")
combatStatus:SetJustifyV("TOP")
combatStatus:SetText("")

local combatAbilityHead = combatFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
combatAbilityHead:SetPoint("TOPLEFT", combatFrame, "TOPLEFT", 18, -64)
combatAbilityHead:SetText("|cFF777777ABILITY|r")
local combatRangeHead = combatFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
combatRangeHead:SetPoint("TOPLEFT", combatFrame, "TOPLEFT", 184, -64)
combatRangeHead:SetText("|cFF777777RANGE|r")
local combatStateHead = combatFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
combatStateHead:SetPoint("TOPLEFT", combatFrame, "TOPLEFT", 236, -64)
combatStateHead:SetText("|cFF777777STATE|r")

local COMBAT_MAX_ROWS = 10
local combatBtns = {}
local cbi = 1
while cbi <= COMBAT_MAX_ROWS do
  local b = CreateFrame("Button", "ShadowArmyCombatRow" .. cbi, combatFrame)
  b:SetWidth(316)
  b:SetHeight(22)
  b:SetPoint("TOP", combatFrame, "TOP", 0, -78 - (cbi - 1) * 23)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
  b.bg:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
  b.bg:SetTexture(0.10, 0.07, 0.12, 0.82)
  b.icon = b:CreateTexture(nil, "OVERLAY")
  b.icon:SetWidth(18)
  b.icon:SetHeight(18)
  b.icon:SetPoint("LEFT", b, "LEFT", 4, 0)
  b.nameText = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.nameText:SetPoint("LEFT", b, "LEFT", 27, 0)
  b.nameText:SetWidth(140)
  b.nameText:SetJustifyH("LEFT")
  b.rangeText = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.rangeText:SetPoint("LEFT", b, "LEFT", 170, 0)
  b.rangeText:SetWidth(50)
  b.rangeText:SetJustifyH("CENTER")
  b.stateText = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.stateText:SetPoint("LEFT", b, "LEFT", 224, 0)
  b.stateText:SetWidth(88)
  b.stateText:SetJustifyH("LEFT")
  b:SetScript("OnClick", function()
    if this.clickable and this.abilityId then F.combatUse(this.abilityId) end
  end)
  b:SetScript("OnEnter", function()
    if this.clickable then this.bg:SetTexture(0.20, 0.13, 0.24, 0.95) end
  end)
  b:SetScript("OnLeave", function()
    this.bg:SetTexture(this.bgR or 0.10, this.bgG or 0.07, this.bgB or 0.12, 0.82)
  end)
  b:Hide()
  combatBtns[cbi] = b
  cbi = cbi + 1
end

function F.combatRangeTag(range)
  if range == "in" then return "|cFF44FF44IN|r" end
  if range == "out" then return "|cFFFF4444OUT|r" end
  if range == "approx_in" then return "|cFFFFFF44~IN|r" end
  if range == "approx_far" then return "|cFFFFAA44~FAR|r" end
  if range == "unknown" then return "|cFF888888?|r" end
  return ""
end

function F.combatStatusText(snapshot, result)
  local form = snapshot.classToken == "DRUID" and (" " .. snapshot.form) or ""
  local line1 = string.format("%s%s  hp %d%%  %s %d%%",
    snapshot.classLabel or "?", form, math.floor(snapshot.hpPct),
    snapshot.resourceName, math.floor(snapshot.powerPct))
  local line2
  if snapshot.hasTarget then
    local level = snapshot.targetLevel and snapshot.targetLevel >= 0 and tostring(snapshot.targetLevel) or "??"
    line2 = string.format("%s lvl %s", snapshot.targetName or "?", level)
    if snapshot.dangerLabel then line2 = line2 .. "  |cFFFF6644" .. snapshot.dangerLabel .. "|r" end
  else
    line2 = "|cFF888888No target|r"
  end
  if snapshot.moving then line2 = line2 .. "  moving" end
  if snapshot.casting then line2 = line2 .. "  |cFFFFFF00casting|r" end
  if snapshot.gcd then line2 = line2 .. "  |cFFAAAAAAGCD|r" end
  local failure = F.combatFailure()
  if failure then line2 = "|cFFFF4444" .. failure.label .. "|r" end
  if result.warning then line2 = line2 .. "  |cFFFFAA00" .. result.warning .. "|r" end
  return line1 .. "\n" .. line2
end

local combatAcc = 0
function F.combatRefresh()
  if not combatFrame:IsShown() then return end
  local snapshot = F.combatSnapshot()
  local result = CombatModel.evaluate(snapshot)
  combatStatus:SetText(F.combatStatusText(snapshot, result))

  local n = table.getn(result.rows)
  local i = 1
  while i <= COMBAT_MAX_ROWS do
    local btn = combatBtns[i]
    local row = i <= n and result.rows[i] or nil
    if row then
      btn.abilityId = row.id
      btn.clickable = row.usable and true or false
      if row.id == result.nextId then
        btn.nameText:SetText("|cFF44FF44→ " .. row.label .. "|r")
        btn.bgR, btn.bgG, btn.bgB = 0.08, 0.20, 0.10
      elseif row.usable then
        btn.nameText:SetText("|cFFDDDDDD" .. row.label .. "|r")
        btn.bgR, btn.bgG, btn.bgB = 0.10, 0.07, 0.12
      else
        btn.nameText:SetText("|cFF888888" .. row.label .. "|r")
        btn.bgR, btn.bgG, btn.bgB = 0.07, 0.06, 0.08
      end
      btn.bg:SetTexture(btn.bgR, btn.bgG, btn.bgB, 0.82)
      btn.rangeText:SetText(F.combatRangeTag(row.range))
      btn.stateText:SetText(row.reason or "")
      if row.usable then btn.stateText:SetTextColor(0.72, 0.72, 0.72)
      else btn.stateText:SetTextColor(0.45, 0.45, 0.45) end
      if row.texture then btn.icon:SetTexture(row.texture); btn.icon:Show() else btn.icon:Hide() end
      btn:Show()
    else
      btn.abilityId = nil
      btn.clickable = false
      btn:Hide()
    end
    i = i + 1
  end
  combatFrame:SetHeight(88 + math.max(1, math.min(n, COMBAT_MAX_ROWS)) * 23)
end

function F.combatToggle()
  if combatFrame:IsShown() then
    -- Deliberate. This is the one close that outlives the next world map.
    ShadowArmy.coachClosed = true
    combatFrame:Hide()
  else
    ShadowArmy.coachClosed = false
    ShadowArmy.coachRestore = false
    combatFrame:Show()
    F.combatRefresh()
  end
end

-- r56: the coach's own watchdog, run from the 4 Hz driver. A Hide that the
-- addon did not ask for (world map, death, fear, Escape — see the note at the
-- frame) armed coachRestore; this puts the window back the moment nothing
-- fullscreen is claiming the screen. A fullscreen taker is respected WHILE it
-- is up: the coach reappearing on top of the world map would be its own bug.
function F.coachGuard()
  if ShadowArmy.coachClosed then return end
  if not ShadowArmy.coachRestore then return end
  if combatFrame:IsShown() then
    ShadowArmy.coachRestore = false
    return
  end
  if WorldMapFrame and WorldMapFrame:IsVisible() then return end
  if GameMenuFrame and GameMenuFrame:IsVisible() then return end
  ShadowArmy.coachRestore = false
  combatFrame:Show()
  pcall(F.combatRefresh)
  if not ShadowArmy.coachSaid then
    ShadowArmy.coachSaid = true
    F.emit("coach", "restored after CloseAllWindows() (world map / death / "
      .. "control loss / escape all call it) — close button or /sa combat to "
      .. "put it away for good")
  end
  F.dtrace("coach restored")
end

-- One-shot state dump ~10 s after login, so "the coach is not open" stops
-- being a report and becomes a reading. shown vs visible separates "we hid
-- it" from "a parent is hidden"; the centre and the UIParent size together
-- say whether it is simply off HIS screen.
function F.coachProbe()
  local cx, cy = combatFrame:GetCenter()
  local uw, uh = UIParent:GetWidth(), UIParent:GetHeight()
  F.emit("coach", "shown=" .. (combatFrame:IsShown() and "1" or "0")
    .. " visible=" .. (combatFrame:IsVisible() and "1" or "0")
    .. " parentshown=" .. (UIParent:IsShown() and "1" or "0")
    .. " x=" .. math.floor((cx or -1) + 0.5)
    .. " y=" .. math.floor((cy or -1) + 0.5)
    .. " ui=" .. math.floor((uw or 0) + 0.5) .. "x" .. math.floor((uh or 0) + 0.5)
    .. " alpha=" .. string.format("%.2f", combatFrame:GetAlpha() or 1)
    .. " strata=" .. tostring(combatFrame:GetFrameStrata())
    .. " closed=" .. (ShadowArmy.coachClosed and "1" or "0")
    .. " map=" .. ((WorldMapFrame and WorldMapFrame:IsVisible()) and "1" or "0"))
end

-- r54: every reload and every login opens the coach, whatever preceded it.
-- Escape, the close button and "/sa combat" still close it for the rest of
-- THIS session — the guarantee is about how a session STARTS, not about
-- overriding a human who closed it on purpose.
function F.combatOpen()
  ShadowArmy.coachClosed = false
  ShadowArmy.coachRestore = false
  combatFrame:Show()
  -- Called at LOAD time as well as on login, where the unit APIs the snapshot
  -- reads may not answer yet — so the refresh is protected, and so is the
  -- complaint about it. A failure here costs one frame of content: the 4 Hz
  -- refresher fills the window in as soon as the world exists.
  local ok, err = pcall(F.combatRefresh)
  if not ok then pcall(F.emit, "err", "combatRefresh: " .. tostring(err)) end
end

-- The close button is the DELIBERATE close (Escape no longer is — it shares
-- CloseAllWindows with the world map). It sticks for the session.
combatClose:SetScript("OnClick", function()
  ShadowArmy.coachClosed = true
  combatFrame:Hide()
end)

local combatBtn = CreateFrame("Button", "ShadowArmyCombatBtn", panel, "UIPanelButtonTemplate")
combatBtn:SetWidth(118)
combatBtn:SetHeight(20)
combatBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 80)
combatBtn:SetText("|cFF9482C9Combat|r")
combatBtn:SetScript("OnClick", function() F.combatToggle() end)
-- Remote-reload button: hidden until The System requests a reload. It must
-- be a click because this build ignores programmatic ReloadUI (see the
-- driver notes) — a mouse click is the hardware event that makes it legal.
local reloadBtn = CreateFrame("Button", "ShadowArmyReloadBtn", panel, "UIPanelButtonTemplate")
reloadBtn:SetWidth(68) -- 118 + 8 gap + 68 = 194 = panel width minus insets
reloadBtn:SetHeight(20)
reloadBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 80) -- top row, beside Combat
reloadBtn:SetText("|cFF44FF44Reload!|r")
reloadBtn:Hide()
reloadBtn:SetScript("OnClick", function()
  ReloadUI()
end)

-- Auto-reload (r14): when a reload is pending, piggyback the player's own
-- next action-bar press — that keypress IS a hardware event, so ReloadUI is
-- legal inside the hook. Out-of-combat only (a surprise 2s UI freeze
-- mid-fight could kill the character). The button stays as the visible
-- fallback; whichever fires first wins.
local reloadArmed = false
local origUseAction = UseAction
UseAction = function(slot, checkCursor, onSelf)
  if reloadArmed and not UnitAffectingCombat("player") then
    reloadArmed = false
    ReloadUI() -- if somehow still gated, fall through and act normally
  end
  origUseAction(slot, checkCursor, onSelf)
end

--------------------------------------------------------------------------
-- Log window (r16): scrollable history of everything the advisor said or
-- emitted, timestamped. /sa log toggles. ScrollingMessageFrame gives us
-- history + scrolling for free (it's what chat frames are made of).
--------------------------------------------------------------------------

local logFrame = CreateFrame("Frame", "ShadowArmyLogFrame", UIParent)
logFrame:SetWidth(380)
logFrame:SetHeight(220)
logFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -120)
logFrame:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
logFrame:SetBackdropColor(0.05, 0.02, 0.10, 0.9)
logFrame:EnableMouse(true)
logFrame:SetMovable(true)
logFrame:RegisterForDrag("LeftButton")
logFrame:SetScript("OnDragStart", function() logFrame:StartMoving() end)
logFrame:SetScript("OnDragStop", function() logFrame:StopMovingOrSizing() end)
logFrame:Hide()
tinsert(UISpecialFrames, "ShadowArmyLogFrame")

local logTitle = logFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
logTitle:SetPoint("TOP", logFrame, "TOP", 0, -8)
logTitle:SetText("|cFF9482C9Advisor Log|r")

local logClose = CreateFrame("Button", nil, logFrame, "UIPanelCloseButton")
logClose:SetPoint("TOPRIGHT", logFrame, "TOPRIGHT", -2, -2)

local logMsg = CreateFrame("ScrollingMessageFrame", "ShadowArmyLogMsg", logFrame)
logMsg:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 12, -28)
logMsg:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -12, 30)
logMsg:SetFontObject(GameFontNormalSmall)
logMsg:SetJustifyH("LEFT")
logMsg:SetMaxLines(250)
logMsg:SetFading(false)

function F.makeLogBtn(label, xOff, fn)
  local b = CreateFrame("Button", nil, logFrame, "UIPanelButtonTemplate")
  b:SetWidth(56)
  b:SetHeight(18)
  b:SetPoint("BOTTOMLEFT", logFrame, "BOTTOMLEFT", xOff, 7)
  b:SetText(label)
  b:SetScript("OnClick", fn)
  return b
end
F.makeLogBtn("Up", 12, function() logMsg:ScrollUp() end)
F.makeLogBtn("Down", 72, function() logMsg:ScrollDown() end)
F.makeLogBtn("Latest", 132, function() logMsg:ScrollToBottom() end)

-- kind -> color; errors pop, telemetry chatter stays muted
local LOG_COLORS = {
  err = { 1.0, 0.35, 0.35 },
  say = { 0.72, 0.62, 0.9 },
  trace = { 0.55, 0.55, 0.55 },
  loaded = { 0.35, 1.0, 0.35 },
  probe = { 0.4, 0.85, 1.0 },
  admin = { 1.0, 0.55, 0.25 },
}

local logErrCount = 0 -- unseen errors since the window was last opened

F.addLog = function(kind, text)
  local c = LOG_COLORS[kind] or { 0.8, 0.8, 0.8 }
  local tag = (kind == "say") and "" or ("[" .. kind .. "] ")
  logMsg:AddMessage(date("%H:%M:%S ") .. tag .. text, c[1], c[2], c[3])
  if kind == "err" and not logFrame:IsVisible() then
    logErrCount = logErrCount + 1
    if ShadowArmyLogBtn then
      -- badge the panel button so a silent error can't go unnoticed
      ShadowArmyLogBtn:SetText(string.format("|cFFFF4444Log (%d)|r", logErrCount))
    end
  end
end

-- Panel button (r17): the log is a window, so it gets a button — /sa log
-- stays as a fallback. Lives on its own row under Combat / Reload.
local logBtn = CreateFrame("Button", "ShadowArmyLogBtn", panel, "UIPanelButtonTemplate")
-- r18: half the bottom row; the Quests toggle takes the other half.
logBtn:SetWidth(93)
logBtn:SetHeight(20)
logBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 56) -- second row
logBtn:SetText("Log")
logBtn:SetScript("OnClick", function()
  if logFrame:IsVisible() then
    logFrame:Hide()
  else
    logFrame:Show()
    logMsg:ScrollToBottom()
    logErrCount = 0
    logBtn:SetText("Log")
  end
end)

--------------------------------------------------------------------------
-- Live refresh: event-driven where possible, plus a 0.5s tick for the
-- clock-ish lines. Range bucket via CheckInteractDistance (1.12 addons
-- get no world coordinates for other units — buckets are what we have).
--------------------------------------------------------------------------

function F.buffTimeLeftByTexture(textures)
  local i = 0
  while true do
    local buffIndex = GetPlayerBuff(i, "HELPFUL")
    if buffIndex < 0 then
      return nil
    end
    local tex = GetPlayerBuffTexture(buffIndex)
    if tex then
      for _, want in ipairs(textures) do
        if tex == want then
          return GetPlayerBuffTimeLeft(buffIndex)
        end
      end
    end
    i = i + 1
  end
end

--------------------------------------------------------------------------
-- r12: Demon Skin / Demon Armor AUTO-CAST — replaces the nag. It is an
-- instant self-buff, legal while moving and out of combat, so the driver
-- can simply keep it up instead of telling the human to.
--
-- SAFETY (this is the whole reason the code below is shaped like this): the
-- textures in WATCHED_BUFFS are UNVERIFIED GUESSES. A wrong guess means the
-- buff NEVER reads as present, and a naive "missing -> cast" loop would
-- recast every 5s forever, burning mana for nothing, with no error anywhere
-- (scriptErrors is off). So the first cast arms a verification window: if
-- the buff still does not READ AT ALL 10s after we cast it, auto-cast
-- switches itself off for the session and emits exactly ONE err line
-- carrying the player's real buff textures. That line is how The System
-- learns the correct texture — it is a diagnostic, not a complaint.
--------------------------------------------------------------------------

local ARMOR_RETRY_EVERY = 5    -- seconds between cast attempts
local ARMOR_VERIFY_AFTER = 10  -- seconds a cast gets to make the buff READ
local ARMOR_CHECK_EVERY = 1    -- buff scan cadence (driver ticks every frame)

local armorNextCheck = 0

-- Which spell to use for a watch. auto.known is the spellbook scan, so we
-- never CastSpellByName something untrained (that throws "you don't know
-- that spell" red text at the human).
function F.watchSpell(watch)
  local names = watch.spells or {}
  local i = 1
  while i <= table.getn(names) do
    if auto.known[string.lower(names[i])] then return names[i] end
    i = i + 1
  end
  return nil
end

function F.armorSpell()
  return F.watchSpell(ARMOR_WATCH)
end

--------------------------------------------------------------------------
-- r47 — TEXTURE CAPTURE, because the guess was wrong exactly as predicted.
--
-- Live 2026-08-15: `demon-skin autocast: buff never detected after cast —
-- texture guess likely wrong; captured=none`. Two separate facts hide in that
-- one line. The obvious one is the guessed icon path being wrong. The other
-- is `captured=none`: the diagnostic that was supposed to name the RIGHT
-- texture came back empty on a player who had just been buffed, because it
-- enumerated with GetPlayerBuff — so the instrument was blind in precisely
-- the situation it exists for.
--
-- So everything below reads UnitBuff("player", i) instead (the same call
-- F.unitHasTexture already relies on for target debuffs), and the addon stops
-- guessing entirely: it snapshots the buff textures immediately BEFORE a cast,
-- diffs them against the set ~1s after, and the single new texture IS the
-- buff's real icon. That texture is appended to the watch and used for
-- detection from then on, and a successful capture clears acDisabled.
--
-- Attribution is deliberately strict: exactly ONE new texture, or nothing is
-- learned. Zero means the cast produced no readable aura and the old
-- disable-and-report path stays in charge; two or more means something else
-- landed in the same second and picking one would be the same guess this code
-- exists to eliminate.
--
-- PERSISTENCE is session-only: the addon has no SavedVariables, and adding
-- one costs a full client restart (the TOC is scanned once per launch), which
-- is not worth spending mid-session. The capture is cheap — one cast — so it
-- simply happens again after a reload. Captures are mirrored onto
-- ShadowArmy.capturedBuffTextures so a live /script can read them out.
--------------------------------------------------------------------------

local ARMOR_CAPTURE_AFTER = 1.0 -- seconds a cast gets to put its aura up

-- Set of the player's current buff textures. Hard-bounded: a runaway
-- while-loop here would hang the client, not just the addon.
function F.playerBuffTextureSet()
  local set, n, i = {}, 0, 1
  while i <= 32 do
    local tex = UnitBuff("player", i)
    if not tex then break end
    if not set[tex] then
      set[tex] = true
      n = n + 1
    end
    i = i + 1
  end
  return set, n
end

-- Comma-separated list of the player's current buff icons with the
-- "Interface\Icons\" prefix stripped — the payload of the one diagnostic line.
function F.playerBuffTextureList(maxN)
  local out, n, i = nil, 0, 1
  while n < maxN and i <= 32 do
    local tex = UnitBuff("player", i)
    if not tex then break end
    -- Lua patterns: backslash is NOT special (only % is), so the path
    -- literal doubles as its own pattern.
    tex = string.gsub(tex, "Interface\\Icons\\", "")
    out = out and (out .. "," .. tex) or tex
    n = n + 1
    i = i + 1
  end
  return out or "none"
end

function F.watchHasTexture(watch, tex)
  if not tex then return false end
  for _, want in ipairs(watch.textures) do
    if want == tex then return true end
  end
  return false
end

-- Presence without a timer. GetPlayerBuffTimeLeft needs a GetPlayerBuff index
-- and that enumeration is the suspect, so "is it up at all" gets an
-- independent answer: an unknown remaining time is not a reason to recast.
function F.watchBuffPresent(watch)
  for _, tex in ipairs(watch.textures) do
    if F.unitHasTexture("player", true, tex) then return true end
  end
  return false
end

function F.armorCaptureDiff(watch)
  local before = watch.acBefore
  if not before then return end
  local after = F.playerBuffTextureSet()
  local found, extra = nil, 0
  for tex in pairs(after) do
    if not before[tex] then
      extra = extra + 1
      found = tex
    end
  end
  if extra ~= 1 or not found then
    F.dtrace("armor capture: " .. extra .. " new buff textures — no attribution")
    return
  end
  if F.watchHasTexture(watch, found) then
    -- The guess was right after all; nothing to learn, but the cast proved it.
    watch.acProven = true
    watch.acVerifyAt = nil
    return
  end
  watch.textures[table.getn(watch.textures) + 1] = found
  watch.acCaptured = found
  watch.acProven = true
  watch.acVerifyAt = nil
  watch.acDisabled = false
  ShadowArmy.capturedBuffTextures = ShadowArmy.capturedBuffTextures or {}
  ShadowArmy.capturedBuffTextures[watch.id] = found
  F.emit("buff-texture", watch.id .. " captured="
    .. string.gsub(found, "Interface\\Icons\\", ""))
end

-- Cast outcome for a capture that is in flight. Instant self-buffs on this
-- build do not reliably emit SPELLCAST_STOP, so ABSENCE OF A FAILURE is the
-- confirmation and STOP only records that it arrived; a SPELLCAST_FAILED /
-- SPELLCAST_INTERRUPTED inside the window throws the sample away, because a
-- cast that never happened cannot explain a new aura.
function F.armorNoteCast(ok)
  for _, watch in ipairs(WATCHED_BUFFS) do
    if watch.acCaptureAt then
      if ok then watch.acCastStopped = true else watch.acCastFailed = true end
    end
  end
end

function F.armorTick()
  local now = GetTime()
  if now < armorNextCheck then return end
  armorNextCheck = now + ARMOR_CHECK_EVERY
  for _, watch in ipairs(WATCHED_BUFFS) do
    if watch.autoCast then
      -- Capture first, and OUTSIDE the acDisabled gate: a successful capture
      -- is the one thing that can turn the watch back on.
      if watch.acCaptureAt and now >= watch.acCaptureAt then
        watch.acCaptureAt = nil
        if not watch.acCastFailed then F.armorCaptureDiff(watch) end
        watch.acBefore = nil
      end
    end
    if watch.autoCast and not watch.acDisabled then
      local left = F.buffTimeLeftByTexture(watch.textures)
      local present = left and true or F.watchBuffPresent(watch)
      if present then
        -- Texture CONFIRMED the first time the buff reads at all. From here
        -- the safety can never trip: a short timer is not a bad texture, and
        -- warnBelow refreshes must not look like failed casts.
        watch.acProven = true
        watch.acVerifyAt = nil
      elseif watch.acVerifyAt and now >= watch.acVerifyAt then
        watch.acDisabled = true
        F.emit("err", "demon-skin autocast: buff never detected after cast — "
          .. "capture found nothing; buffs=" .. F.playerBuffTextureList(8))
      end
      -- Cast when the buff is missing entirely OR inside the refresh window.
      -- `present` without `left` means "up, duration unreadable" — do not
      -- recast that, it is not a failure.
      if not watch.acDisabled and (not present or (left and left < watch.warnBelow)) then
        local spell = F.armorSpell()
        if spell and not auto.casting
            and now >= auto.gcdUntil and now >= auto.failUntil
            and now >= (watch.acNextTryAt or 0)
            and not UnitIsDeadOrGhost("player") then
          watch.acNextTryAt = now + ARMOR_RETRY_EVERY
          -- Only the FIRST pending cast arms the verify window — re-arming on
          -- every retry would push the deadline out forever and the safety
          -- would never fire.
          if not watch.acProven and not watch.acVerifyAt then
            watch.acVerifyAt = now + ARMOR_VERIFY_AFTER
          end
          -- The before-set is taken RIGHT HERE, one statement before the cast,
          -- so nothing can slip into the baseline.
          watch.acBefore = F.playerBuffTextureSet()
          watch.acCaptureAt = now + ARMOR_CAPTURE_AFTER
          watch.acCastFailed = false
          watch.acCastStopped = false
          F.castNow(spell) -- shared GCD bookkeeping + F.dtrace
        end
      end
    end
  end
end

--------------------------------------------------------------------------
-- r42: long-term passives are buttons, not nags. A missing self-buff the
-- advisor does NOT auto-cast, and a missing minion, become one-click panel
-- buttons; anything already handled (or untrained) stays a status line.
--------------------------------------------------------------------------

function F.passiveSnapshot()
  local buffs, n = {}, 0
  for _, watch in ipairs(WATCHED_BUFFS) do
    local left = F.buffTimeLeftByTexture(watch.textures)
    -- r47: same split as F.armorTick — a buff that is UP but whose remaining
    -- time this build will not hand over must not be painted as missing.
    local present = left and true or F.watchBuffPresent(watch)
    if not present or (left and left < watch.warnBelow) then
      n = n + 1
      buffs[n] = {
        id = watch.id, label = watch.label, autoLabel = watch.autoLabel,
        spell = F.watchSpell(watch),
        missing = (not present) and true or false,
        expiring = left and true or false,
        minutes = left and math.ceil(left / 60) or nil,
        auto = (watch.autoCast and not watch.acDisabled) and true or false,
      }
    end
  end
  return {
    classToken = auto.classToken,
    known = auto.known,
    buffs = buffs,
    -- A dead minion still exists as "pet" until it despawns, and a warlock
    -- pet can sit at 0 hp before the dead flag reads true; resummoning over
    -- the corpse is legal, so only a LIVING pet suppresses the button.
    hasPet = (UnitExists("pet") and not UnitIsDeadOrGhost("pet")
      and (UnitHealth("pet") or 0) > 0) and true or false,
    inCombat = UnitAffectingCombat("player") and true or false,
    dead = UnitIsDeadOrGhost("player") and true or false,
  }
end

function F.passiveClick(spell, onSelf)
  if not spell or auto.casting then return end
  F.castNow(spell, onSelf)
end

local PASSIVE_TONES = { ok = "|cFF44FF44", bad = "|cFFFF4444", warn = "|cFFFFAA00" }

local lastNag = 0
function F.passiveLine()
  local result = F.passiveEvaluate()
  local text, nags = nil, nil
  for _, note in ipairs(result.notes) do
    local painted = (PASSIVE_TONES[note.tone] or "|cFFFFAA00") .. note.text .. "|r"
    text = text and (text .. "  " .. painted) or painted
    if note.tone ~= "ok" then
      nags = nags and (nags .. "  " .. note.text) or note.text
    end
  end

  -- Clamp BEFORE the height math: the model may propose more upkeep than
  -- there are frames, and an unclamped count would inflate the panel by rows
  -- that can never be drawn.
  local shown = table.getn(result.buttons)
  if shown > PASSIVE_MAX_BUTTONS then shown = PASSIVE_MAX_BUTTONS end
  local i = 1
  while i <= PASSIVE_MAX_BUTTONS do
    local btn = passiveBtns[i]
    local want = i <= shown and result.buttons[i] or nil
    if want then
      -- r46: the button IS the spell icon. Texture and rank come from the same
      -- spellbook capture the coach and the bar sweep already use.
      local book = want.spell and auto.spells[string.lower(want.spell)] or nil
      btn.passiveSpell = want.spell
      btn.passiveSelf = want.selfCast and 1 or nil
      btn.passiveLabel = want.label
      btn.passiveRank = book and book.rank or nil
      btn.passiveAuto = want.auto and true or nil
      btn.passiveCombat = want.inCombat and true or nil
      btn.icon:SetTexture((book and book.texture) or PASSIVE_ICON_FALLBACK)
      btn:Show()
    else
      btn.passiveSpell = nil
      btn.passiveAuto = nil
      btn.passiveCombat = nil
      btn:Hide()
    end
    i = i + 1
  end
  local rows = math.ceil(shown / 2)
  passiveRow:SetHeight(rows > 0 and rows * PASSIVE_BTN_STEP or 1)
  panel:SetHeight(PANEL_BASE_HEIGHT + rows * PASSIVE_BTN_STEP)

  -- Nag only about things the human cannot fix with a click.
  if nags and (GetTime() - lastNag) > 60 then
    lastNag = GetTime()
    F.say("buff watch: " .. nags) -- chat nag at most once a minute
  end
  if text then return text end
  if shown > 0 then return "" end
  return "|cFF44FF44buffs OK|r"
end

-- r55: the whole passive section in one call, so exactly one clock owns it.
-- F.passiveLine already does the button/height work as a side effect; this
-- wrapper exists so the driver's OnUpdate has something to pcall that also
-- paints the line, and so the panel handler no longer has to.
function F.passiveRefresh()
  line5:SetText(F.passiveLine())
end

--------------------------------------------------------------------------
-- r43: advisor-managed spells come OFF the action bar (monofuel's call).
-- The advisor casts the coach rotation and the passive layer itself, so a
-- bar copy only invites a mis-click on an ability we already drive.
--
-- r44 narrows that to the PRESSABLE pages (1-72) and parks one copy of each
-- managed spell on the telemetry shelf (109-120, the last bonus bank — no key
-- reaches it on a stance-less class). F.combatActionState reads exact
-- usability/range off a slot; without the shelf the coach would be stuck on
-- usable=true and CheckInteractDistance guesses forever.
--
-- 1.12 has NO GetActionInfo: the only way to name a slot's contents is a
-- tooltip scan. One hidden GameTooltip is built here (never per tick) and
-- read through its name region's first line, which in 1.12 carries the base
-- spell name with no rank suffix — so an exact, case-insensitive match
-- against the managed set is safe.
--
-- Removal is PickupAction + ClearCursor: picking an action up leaves the
-- slot empty and dropping it on nothing discards it. Refilling the r44
-- telemetry shelf is PickupSpell + PlaceAction, the same pair the spellbook
-- drag uses.
--------------------------------------------------------------------------

local barTip = CreateFrame("GameTooltip", "ShadowArmyBarTip", UIParent,
  "GameTooltipTemplate")
barTip:SetOwner(UIParent, "ANCHOR_NONE")

local BAR_SWEEP_SETTLE = 2 -- seconds a trigger waits (login bars fill late)
local BAR_SWEEP_GAP = 5    -- seconds; SPELLS_CHANGED arrives in bursts
-- r44: seconds of no human bar edits before we are allowed to touch the bar.
-- A macro drag is invisible to CursorHasItem/CursorHasSpell, so this quiet
-- period is what keeps a mid-rearrange drag safe.
local BAR_SWEEP_QUIET = 5
-- Grace window in which an ACTIONBAR_SLOT_CHANGED is assumed to be OUR own
-- mutation echoing back, so the sweep cannot defer itself forever.
local BAR_SWEEP_OWN = 1
local barSweep = { pending = false, nextAt = 0, changedAt = 0, ownAt = 0 }

-- Tooltip line 1 of an action slot, or nil when the slot is empty, a macro,
-- or unreadable. Callers treat nil as "leave this slot alone".
function F.barSlotName(slot)
  if not HasAction(slot) then return nil end
  -- Macros are out of scope: a macro slot's tooltip carries the MACRO name,
  -- never the spell it wraps, so a managed spell inside one is invisible and
  -- an unrelated macro named "Shadow Bolt" would be a false positive.
  if GetActionText and GetActionText(slot) then return nil end
  barTip:SetOwner(UIParent, "ANCHOR_NONE")
  barTip:ClearLines()
  local fs = getglobal("ShadowArmyBarTipTextLeft1")
  -- CONSTRAINT (r45, live client): this wine 1.12 build's
  -- GameTooltip:SetAction returns NO populate flag, so blank-then-read is the
  -- reliable populate proof. r44 required that flag ("if not (ok and filled)")
  -- and therefore called EVERY slot unreadable: the sweep removed nothing
  -- (fail-safe, fine) but also could not see its own shelf, so every run
  -- re-placed the same spells until 109-120 filled up. Live evidence:
  -- "swept removed=0 shelved=6" followed by "shelf full".
  --
  -- ClearLines() alone can leave the FontString's stale text in place, so the
  -- name line is blanked explicitly first. Any text read back AFTER SetAction
  -- can then only have come from this slot, which is a strictly stronger
  -- guarantee than the flag was. NumLines() is deliberately not gated on
  -- either: another populate signal from the same widget on the same build is
  -- another way to fail closed for the whole bar.
  if fs then fs:SetText(nil) end
  if not pcall(barTip.SetAction, barTip, slot) then return nil end
  local text = fs and fs:GetText()
  if not text or text == "" then return nil end
  return text
end

-- Debounced request. Never sweeps inline: the caller may be an event handler
-- firing mid-login burst or mid-combat.
function F.barSweepRequest()
  barSweep.pending = true
  local at = GetTime() + BAR_SWEEP_SETTLE
  if at > barSweep.nextAt then barSweep.nextAt = at end
end

function F.barSweepRun()
  -- Stamped before AND after the mutations: every ACTIONBAR_SLOT_CHANGED this
  -- run causes is ours, and must not arm the quiet period against us.
  barSweep.ownAt = GetTime()
  local names, occupied = {}, {}
  local slot = 1
  while slot <= BarModel.maxSlot do
    -- HasAction is the occupancy truth: a macro or an unreadable slot names
    -- nothing yet must never be treated as free shelf space.
    if HasAction(slot) then occupied[slot] = true end
    names[slot] = F.barSlotName(slot)
    slot = slot + 1
  end
  barTip:Hide()
  local plan = BarModel.plan(names,
    BarModel.managedNames(auto.classToken, WATCHED_BUFFS),
    { order = BarModel.managedOrder(auto.classToken, WATCHED_BUFFS),
      -- auto.spells is keyed lowercase and holds the HIGHEST rank's book
      -- index (F.scanSpellbook overwrites as it walks ranks upward).
      trained = auto.spells, occupied = occupied })
  local n = table.getn(plan.remove)
  local i = 1
  while i <= n do
    pcall(PickupAction, plan.remove[i])
    pcall(ClearCursor) -- an action left on the cursor would ride the next click
    i = i + 1
  end
  -- Refill the telemetry shelf so the coach keeps exact IsUsableAction /
  -- IsActionInRange on every managed spell it can.
  local placed, pn = 0, table.getn(plan.place)
  i = 1
  while i <= pn do
    local entry = plan.place[i]
    local book = auto.spells[entry.name]
    local ok = false
    if book and book.index then
      if pcall(PickupSpell, book.index, "spell") then
        ok = pcall(PlaceAction, entry.slot)
      end
    end
    pcall(ClearCursor) -- covers a failed pickup AND a rejected placement
    if ok then placed = placed + 1 end
    i = i + 1
  end
  if plan.shelfFull then F.emit("bar", "shelf full") end
  if n > 0 or placed > 0 then
    F.emit("bar", "swept removed=" .. n .. " shelved=" .. placed)
    F.scanCombatActions() -- the coach's exact-slot map just went stale
  end
  -- Echoes land after this returns, so re-stamp: the sweep never defers
  -- itself into a loop.
  barSweep.ownAt = GetTime()
end

function F.barSweepTick()
  if not barSweep.pending then return end
  local now = GetTime()
  if now < barSweep.nextAt then return end
  -- Combat / dead / casting: hold the request; PLAYER_REGEN_ENABLED re-arms
  -- it and this tick retries once the window is clear.
  if UnitAffectingCombat("player") or UnitIsDeadOrGhost("player") then return end
  if auto.casting then return end
  -- r44 drag safety. Never yank an action onto a loaded cursor, and stay off
  -- the bar entirely while the human is mid-rearrange — a macro drag shows up
  -- in neither cursor query, only in the ACTIONBAR_SLOT_CHANGED quiet period.
  -- Checked once, HERE, at sweep start: F.barSweepRun's own mutations are
  -- stamped ownAt and never move changedAt.
  if (CursorHasItem and CursorHasItem())
    or (CursorHasSpell and CursorHasSpell())
    or (now - barSweep.changedAt) < BAR_SWEEP_QUIET then
    F.barSweepRequest() -- re-arm; retry once the bar settles
    return
  end
  barSweep.pending = false
  barSweep.nextAt = now + BAR_SWEEP_GAP
  F.barSweepRun()
end

-- ACTIONBAR_SLOT_CHANGED bookkeeping: only HUMAN edits arm the quiet period.
function F.barSweepNoteChange()
  local now = GetTime()
  if (now - barSweep.ownAt) <= BAR_SWEEP_OWN then return end
  barSweep.changedAt = now
end

--------------------------------------------------------------------------
-- Probe panel (r22): measure which APIs work from which call contexts.
-- Stops the "everything is a hardware event" guess — same call, three
-- contexts (click / next OnUpdate frame / delayed 0.5s), observable
-- before/after. See docs/advisor-autopilot.md "Client sandbox reality".
-- /sa debug toggles. Results stay local (advisor log + this window);
-- only final verdicts F.emit to Chat.log so we do not re-trip the throttle.
--------------------------------------------------------------------------

local probe = {
  mode = "click", -- "click" | "frame" | "delay"
  pending = nil,  -- { kind=, at=, ctx= } for frame/delay
  follow = nil,   -- deferred after-cast check
  recording = true,
  lastEvents = {}, -- ring of recent interesting events (strings)
  lastN = 0,
}

local probeLogMsg -- ScrollingMessageFrame; set when UI is built
local probeModeBtns = {}
local probeStatusLine

function F.probeLog(text)
  local line = tostring(text)
  if probeLogMsg then
    probeLogMsg:AddMessage(date("%H:%M:%S ") .. line, 0.4, 0.85, 1.0)
  end
  if F.addLog then F.addLog("probe", line) end
end

function F.probeEmitVerdict(text)
  -- One Chat.log line per finished probe — System can tail it.
  F.emit("probe", text)
  F.probeLog(text)
end

function F.probeNoteEvent(ev, detail)
  if not probe.recording then return end
  local s = ev
  if detail and detail ~= "" then
    s = ev .. " " .. detail
  end
  -- ring of 40
  if table.getn(probe.lastEvents) >= 40 then
    table.remove(probe.lastEvents, 1)
  end
  table.insert(probe.lastEvents, date("%H:%M:%S ") .. s)
  if probeLogMsg and probe.uiShown then
    probeLogMsg:AddMessage(date("%H:%M:%S ") .. "[ev] " .. s, 0.55, 0.55, 0.55)
  end
end

function F.probeCountLootItems()
  local n = GetNumLootItems()
  if not n or n == 0 then return 0, 0 end
  local left, i = 0, 1
  while i <= n do
    if GetLootSlotInfo(i) then left = left + 1 end
    i = i + 1
  end
  return n, left
end

function F.probeFindBagItem()
  local bag = 0
  while bag <= 4 do
    local slots = GetContainerNumSlots(bag)
    if slots and slots > 0 then
      local slot = 1
      while slot <= slots do
        local link = GetContainerItemLink(bag, slot)
        if link then return bag, slot, link end
        slot = slot + 1
      end
    end
    bag = bag + 1
  end
  return nil, nil, nil
end

function F.probeStatusDump()
  local n, left = F.probeCountLootItems()
  local spell = F.armorSpell() or "none"
  local mana = UnitMana("player") or 0
  local manaMax = UnitManaMax("player") or 0
  local cast = auto.casting and "yes" or "no"
  local shoot = auto.shooting and "yes" or "no"
  local move = move.moving and "yes" or "no"
  local cursor = (CursorHasItem and CursorHasItem()) and "item" or "empty"
  local tex = F.playerBuffTextureList(6)
  return string.format(
    "mode=%s lootSlots=%d lootItems=%d armor=%s mana=%d/%d casting=%s shoot=%s moving=%s cursor=%s buffs=%s",
    probe.mode, n, left, spell, mana, manaMax, cast, shoot, move, cursor, tex)
end

function F.probeRefreshStatus()
  if probeStatusLine then
    probeStatusLine:SetText(F.probeStatusDump())
  end
end

function F.probeRun(kind, ctx)
  -- kind: status | buffs | cast | pickup | reload
  if kind == "status" then
    F.probeEmitVerdict("status ctx=" .. ctx .. " " .. F.probeStatusDump())
    return
  end
  if kind == "buffs" then
    F.probeEmitVerdict("buffs ctx=" .. ctx .. " tex=" .. F.playerBuffTextureList(12))
    return
  end
  if kind == "cast" then
    local spell = F.armorSpell()
    if not spell then
      F.probeEmitVerdict("cast ctx=" .. ctx .. " FAIL no Demon Skin/Armor trained")
      return
    end
    local mana0 = UnitMana("player") or 0
    local left0 = F.buffTimeLeftByTexture(WATCHED_BUFFS[1].textures)
    local ok, err = pcall(CastSpellByName, spell)
    auto.gcdUntil = GetTime() + 1.6
    local msg = string.format(
      "cast ctx=%s spell=%s pcall=%s mana0=%d buff0=%s%s",
      ctx, spell, tostring(ok), mana0,
      left0 and string.format("%.0fs", left0) or "nil",
      (not ok and err) and (" err=" .. tostring(err)) or "")
    F.probeLog(msg)
    -- After 1.2s: did mana move, did buff appear, did SPELLCAST fire?
    probe.follow = {
      at = GetTime() + 1.2,
      kind = "castcheck",
      ctx = ctx,
      spell = spell,
      mana0 = mana0,
      buff0 = left0 and true or false,
    }
    return
  end
  if kind == "pickup" then
    if CursorHasItem and CursorHasItem() then
      F.probeEmitVerdict("pickup ctx=" .. ctx .. " FAIL cursor already holds item — drop it first")
      return
    end
    local bag, slot, link = F.probeFindBagItem()
    if not bag then
      F.probeEmitVerdict("pickup ctx=" .. ctx .. " FAIL bags empty")
      return
    end
    local ok, err = pcall(PickupContainerItem, bag, slot)
    local has = (CursorHasItem and CursorHasItem()) and true or false
    if has then
      -- put it back so we don't leave junk on the cursor
      pcall(PickupContainerItem, bag, slot)
    end
    local verdict = has and "OK" or "GATED"
    local short = link and string.gsub(link, "|c%x%x%x%x%x%x%x%x|Hitem:%d+:[^|]+|h%[(.-)%]|h|r", "%1") or "?"
    F.probeEmitVerdict(string.format(
      "pickup ctx=%s %s bag=%d slot=%d item=%s pcall=%s%s",
      ctx, verdict, bag, slot, short, tostring(ok),
      (not ok and err) and (" err=" .. tostring(err)) or ""))
    return
  end
  if kind == "reload" then
    -- Destructive if ungated. Log first so Chat.log has a line either way;
    -- if gated, you stay in-world and read GATED by still being here.
    F.probeEmitVerdict("reload ctx=" .. ctx .. " calling ReloadUI (if gated, nothing happens)")
    local ok, err = pcall(ReloadUI)
    if not ok then
      F.probeEmitVerdict("reload ctx=" .. ctx .. " pcall FAIL " .. tostring(err))
    else
      -- If we still execute, ReloadUI returned without reloading.
      F.probeEmitVerdict("reload ctx=" .. ctx .. " GATED (ReloadUI returned, UI still up)")
    end
    return
  end
  F.probeEmitVerdict("unknown probe kind=" .. tostring(kind) .. " ctx=" .. ctx)
end

function F.probeSchedule(kind)
  if probe.mode == "click" then
    F.probeRun(kind, "click")
  elseif probe.mode == "frame" then
    probe.pending = { kind = kind, at = 0, ctx = "frame" }
    F.probeLog("queued " .. kind .. " for next OnUpdate frame")
  else
    probe.pending = { kind = kind, at = GetTime() + 0.5, ctx = "delay0.5" }
    F.probeLog("queued " .. kind .. " for +0.5s (software timer)")
  end
  F.probeRefreshStatus()
end

function F.probeTick()
  local now = GetTime()
  if probe.pending and now >= (probe.pending.at or 0) then
    local p = probe.pending
    probe.pending = nil
    local ok, err = pcall(F.probeRun, p.kind, p.ctx)
    if not ok then
      F.probeEmitVerdict("probe error kind=" .. tostring(p.kind) .. " " .. tostring(err))
    end
  end
  if probe.follow and now >= probe.follow.at then
    local f = probe.follow
    probe.follow = nil
    if f.kind == "castcheck" then
      local mana1 = UnitMana("player") or 0
      local left1 = F.buffTimeLeftByTexture(WATCHED_BUFFS[1].textures)
      local buff1 = left1 and true or false
      local manaDrop = mana1 < f.mana0
      local buffNew = buff1 and not f.buff0
      local buffOk = buff1
      local verdict
      if buffNew or (buffOk and manaDrop) then
        verdict = "OK"
      elseif manaDrop or auto.casting then
        verdict = "FIRED_UNCONFIRMED" -- mana/cast moved; buff texture may be wrong
      else
        verdict = "GATED_OR_NOOP" -- no mana change, no buff — silent ignore or full
      end
      F.probeEmitVerdict(string.format(
        "castcheck ctx=%s %s spell=%s mana %d->%d buff=%s casting=%s",
        f.ctx, verdict, f.spell, f.mana0, mana1,
        buff1 and "yes" or "no", auto.casting and "yes" or "no"))
    end
  end
  if probe.uiShown then
    F.probeRefreshStatus()
  end
end

function F.probeSetMode(mode)
  probe.mode = mode
  local names = { "click", "frame", "delay" }
  local i = 1
  while i <= 3 do
    local m = names[i]
    local b = probeModeBtns[m]
    if b then
      if m == mode then
        b:SetText("|cFF44FF44" .. b.probeLabel .. "|r")
      else
        b:SetText("|cFF999999" .. b.probeLabel .. "|r")
      end
    end
    i = i + 1
  end
  F.probeLog("mode=" .. mode .. " (Click=hardware OnClick, Frame=next OnUpdate, Delay=+0.5s)")
  F.probeRefreshStatus()
end

-- UI
local probeFrame = CreateFrame("Frame", "ShadowArmyProbeFrame", UIParent)
probeFrame:SetWidth(420)
probeFrame:SetHeight(300)
probeFrame:SetPoint("CENTER", UIParent, "CENTER", 80, 40)
probeFrame:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
probeFrame:SetBackdropColor(0.02, 0.05, 0.08, 0.92)
probeFrame:EnableMouse(true)
probeFrame:SetMovable(true)
probeFrame:RegisterForDrag("LeftButton")
probeFrame:SetScript("OnDragStart", function() probeFrame:StartMoving() end)
probeFrame:SetScript("OnDragStop", function() probeFrame:StopMovingOrSizing() end)
probeFrame:Hide()
probe.uiShown = false
tinsert(UISpecialFrames, "ShadowArmyProbeFrame")

local probeTitle = probeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
probeTitle:SetPoint("TOP", probeFrame, "TOP", 0, -8)
probeTitle:SetText("|cFF66CCFFSA Probe|r  (context gates)")

local probeClose = CreateFrame("Button", nil, probeFrame, "UIPanelCloseButton")
probeClose:SetPoint("TOPRIGHT", probeFrame, "TOPRIGHT", -2, -2)
probeClose:SetScript("OnClick", function()
  probeFrame:Hide()
  probe.uiShown = false
end)

probeStatusLine = probeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
probeStatusLine:SetPoint("TOPLEFT", probeFrame, "TOPLEFT", 10, -26)
probeStatusLine:SetPoint("TOPRIGHT", probeFrame, "TOPRIGHT", -10, -26)
probeStatusLine:SetJustifyH("LEFT")
probeStatusLine:SetText("…")

function F.makeProbeBtn(label, x, y, w, fn)
  local b = CreateFrame("Button", nil, probeFrame, "UIPanelButtonTemplate")
  b:SetWidth(w or 64)
  b:SetHeight(18)
  b:SetPoint("TOPLEFT", probeFrame, "TOPLEFT", x, y)
  b:SetText(label)
  b:SetScript("OnClick", fn)
  return b
end

-- Mode row
local modeY = -48
local modeLbl = probeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
modeLbl:SetPoint("TOPLEFT", probeFrame, "TOPLEFT", 10, modeY - 2)
modeLbl:SetText("Mode")
local mb
mb = F.makeProbeBtn("Click", 48, modeY, 52, function() F.probeSetMode("click") end)
mb.probeLabel = "Click"
probeModeBtns.click = mb
mb = F.makeProbeBtn("Frame", 114, modeY, 52, function() F.probeSetMode("frame") end)
mb.probeLabel = "Frame"
probeModeBtns.frame = mb
mb = F.makeProbeBtn("Delay", 170, modeY, 52, function() F.probeSetMode("delay") end)
mb.probeLabel = "Delay"
probeModeBtns.delay = mb
F.makeProbeBtn("Status", 240, modeY, 56, function() F.probeSchedule("status") end)
F.makeProbeBtn("Buffs", 300, modeY, 52, function() F.probeSchedule("buffs") end)
F.makeProbeBtn("Help", 356, modeY, 48, function()
  F.probeLog("Mode = call context for the next probe button.")
  F.probeLog("  Click: runs inside this button OnClick (hardware).")
  F.probeLog("  Frame: runs on next driver OnUpdate (software).")
  F.probeLog("  Delay: runs after 0.5s timer (software).")
  F.probeLog("Cast: Demon Skin/Armor + 1.2s follow-up (mana/buff).")
  F.probeLog("Pickup: bag item on/off cursor; OK if cursor takes item.")
  F.probeLog("Reload: WILL reload UI if ungated — use last.")
  F.probeLog("Compare same probe under Click vs Frame vs Delay.")
end)

-- Action row
local actY = -70
F.makeProbeBtn("Cast armor", 10, actY, 80, function() F.probeSchedule("cast") end)
F.makeProbeBtn("Pickup", 94, actY, 60, function() F.probeSchedule("pickup") end)
F.makeProbeBtn("|cFFFF6644ReloadUI|r", 158, actY, 80, function() F.probeSchedule("reload") end)
F.makeProbeBtn("Clear", 242, actY, 48, function()
  if probeLogMsg then probeLogMsg:Clear() end
end)
F.makeProbeBtn("Rec", 294, actY, 36, function()
  probe.recording = not probe.recording
  F.probeLog("event recording " .. (probe.recording and "ON" or "OFF"))
end)

probeLogMsg = CreateFrame("ScrollingMessageFrame", "ShadowArmyProbeLog", probeFrame)
probeLogMsg:SetPoint("TOPLEFT", probeFrame, "TOPLEFT", 10, -96)
probeLogMsg:SetPoint("BOTTOMRIGHT", probeFrame, "BOTTOMRIGHT", -10, 10)
probeLogMsg:SetFontObject(GameFontNormalSmall)
probeLogMsg:SetJustifyH("LEFT")
probeLogMsg:SetMaxLines(200)
probeLogMsg:SetFading(false)
probeLogMsg:EnableMouseWheel(true)
probeLogMsg:SetScript("OnMouseWheel", function()
  if arg1 > 0 then
    probeLogMsg:ScrollUp()
  else
    probeLogMsg:ScrollDown()
  end
end)

function F.probeShow()
  probeFrame:Show()
  probe.uiShown = true
  F.probeSetMode(probe.mode)
  F.probeRefreshStatus()
  F.probeLog("probe panel open rev=" .. REV .. " — pick mode, run probes, compare contexts")
end

function F.probeHide()
  probeFrame:Hide()
  probe.uiShown = false
end

function F.probeToggle()
  if probeFrame:IsShown() then F.probeHide() else F.probeShow() end
end

-- Third row: Admin (System ops) + Probe (sandbox instrument). The bottom row
-- (y=8) belongs to the r47 Bags window.
local adminBtn = CreateFrame("Button", "ShadowArmyAdminBtn", panel, "UIPanelButtonTemplate")
adminBtn:SetWidth(93)
adminBtn:SetHeight(20)
adminBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 32)
adminBtn:SetText("|cFFFF8844Admin|r")

local probeBtn = CreateFrame("Button", "ShadowArmyProbeBtn", panel, "UIPanelButtonTemplate")
probeBtn:SetWidth(93)
probeBtn:SetHeight(20)
probeBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 32)
probeBtn:SetText("|cFF66CCFFProbe|r")
probeBtn:SetScript("OnClick", function()
  F.probeToggle()
end)

--------------------------------------------------------------------------
-- Admin panel (r24): same write actions as The System HTTP Admin + MCP.
-- 1.12 has no HTTP client — we /say "<SA> admin <action>" and the System
-- Chat.log tailer runs respawnShadowArmy() / reloadAddon() (Murist only).
-- NOT fair-play; local testing escape hatch only.
--------------------------------------------------------------------------

local adminSeq = 0
local adminFrame = CreateFrame("Frame", "ShadowArmyAdminFrame", UIParent)
adminFrame:SetWidth(280)
adminFrame:SetHeight(198)
adminFrame:SetPoint("CENTER", UIParent, "CENTER", -100, 40)
adminFrame:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
adminFrame:SetBackdropColor(0.12, 0.04, 0.02, 0.92)
adminFrame:EnableMouse(true)
adminFrame:SetMovable(true)
adminFrame:RegisterForDrag("LeftButton")
adminFrame:SetScript("OnDragStart", function() adminFrame:StartMoving() end)
adminFrame:SetScript("OnDragStop", function() adminFrame:StopMovingOrSizing() end)
adminFrame:Hide()
tinsert(UISpecialFrames, "ShadowArmyAdminFrame")

local adminTitle = adminFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
adminTitle:SetPoint("TOP", adminFrame, "TOP", 0, -8)
adminTitle:SetText("|cFFFF8844SA Admin|r  (The System)")

local adminClose = CreateFrame("Button", nil, adminFrame, "UIPanelCloseButton")
adminClose:SetPoint("TOPRIGHT", adminFrame, "TOPRIGHT", -2, -2)

local adminNote = adminFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
adminNote:SetPoint("TOPLEFT", adminFrame, "TOPLEFT", 12, -30)
adminNote:SetPoint("TOPRIGHT", adminFrame, "TOPRIGHT", -12, -30)
adminNote:SetJustifyH("LEFT")
adminNote:SetText(
  "Ops only — same as http://127.0.0.1:7777/admin\n" ..
  "Cast: Shadowfel, Igris, Tusk, Beru → Deathknell\n" ..
  "Not fair-play corpse recovery.")

function F.adminRequest(action)
  -- #N beats F.emit()'s 30s identical-message dedupe so a second click works.
  adminSeq = adminSeq + 1
  local payload = action .. " #" .. adminSeq
  F.emit("admin", payload)
  F.say("admin: requested " .. action .. " (The System must be running)")
end

function F.makeAdminBtn(label, y, r, g, b, fn)
  local b = CreateFrame("Button", nil, adminFrame, "UIPanelButtonTemplate")
  b:SetWidth(250)
  b:SetHeight(22)
  b:SetPoint("TOP", adminFrame, "TOP", 0, y)
  b:SetText(label)
  b:SetScript("OnClick", fn)
  return b
end

F.makeAdminBtn("|cFFFF6644Respawn army|r", -78, 1, 0.4, 0.2, function()
  F.adminRequest("respawn_shadow_army")
end)

F.makeAdminBtn("|cFFFFAA44Tele party to me|r", -108, 1, 0.7, 0.3, function()
  F.adminRequest("tele_party_to_murist")
end)

F.makeAdminBtn("Reload addon (via System)", -138, 0.5, 0.8, 0.5, function()
  F.adminRequest("reload_addon")
end)

function F.adminToggle()
  if adminFrame:IsShown() then
    adminFrame:Hide()
  else
    adminFrame:Show()
  end
end

adminBtn:SetScript("OnClick", function()
  F.adminToggle()
end)
adminClose:SetScript("OnClick", function()
  adminFrame:Hide()
end)

-- Event sniffer dedicated to the probe (does not own combat logic).
local probeEvents = CreateFrame("Frame", "ShadowArmyProbeEvents", UIParent)
probeEvents:RegisterEvent("CHAT_MSG_SYSTEM")
probeEvents:RegisterEvent("LOOT_OPENED")
probeEvents:RegisterEvent("LOOT_SLOT_CLEARED")
probeEvents:RegisterEvent("LOOT_CLOSED")
probeEvents:RegisterEvent("SPELLCAST_START")
probeEvents:RegisterEvent("SPELLCAST_STOP")
probeEvents:RegisterEvent("SPELLCAST_FAILED")
probeEvents:RegisterEvent("SPELLCAST_INTERRUPTED")
probeEvents:RegisterEvent("START_AUTOREPEAT_SPELL")
probeEvents:RegisterEvent("STOP_AUTOREPEAT_SPELL")
probeEvents:RegisterEvent("PLAYER_ENTER_COMBAT")
probeEvents:RegisterEvent("PLAYER_LEAVE_COMBAT")
probeEvents:RegisterEvent("PLAYER_AURAS_CHANGED")
probeEvents:RegisterEvent("UI_ERROR_MESSAGE")
probeEvents:SetScript("OnEvent", function()
  if not probe.recording then return end
  local detail = ""
  if event == "CHAT_MSG_SYSTEM" or event == "UI_ERROR_MESSAGE" or event == "SPELLCAST_START" then
    detail = tostring(arg1 or "")
    -- strip color codes for readability
    detail = string.gsub(detail, "|c%x%x%x%x%x%x%x%x", "")
    detail = string.gsub(detail, "|r", "")
    if string.len(detail) > 80 then
      detail = string.sub(detail, 1, 80) .. "…"
    end
  elseif event == "LOOT_OPENED" then
    local n, left = F.probeCountLootItems()
    detail = "slots=" .. n .. " items=" .. left
  end
  F.probeNoteEvent(event, detail)
end)

function F.targetSummary()
  if not UnitExists("target") then
    return "target: |cFF777777none|r", ""
  end
  local name = UnitName("target") or "?"
  local level = UnitLevel("target")
  local hp = UnitHealth("target")
  local hpMax = UnitHealthMax("target")
  local levelStr = (level and level > 0) and tostring(level) or "??"
  local range
  if CheckInteractDistance("target", 3) then       -- ~10yd
    range = "|cFF44FF44melee-ish (<10yd)|r"
  elseif CheckInteractDistance("target", 4) then   -- ~28yd
    range = "|cFFFFFF44casting range (<28yd)|r"
  else
    range = "|cFFFF6644far (>28yd)|r"
  end
  local hostile = UnitCanAttack("player", "target") and "" or " |cFF44AAFF(friendly)|r"
  return string.format("target: %s (lvl %s)%s", name, levelStr, hostile),
    string.format("  %d/%d hp, %s", hp, hpMax, range)
end

--------------------------------------------------------------------------
-- ShadowBags (r12): ONE window for bags 0..4, OneBag-style. The five
-- Blizzard ContainerFrames simply never open any more — every normal path
-- to them (the B key, the bag-bar buttons, merchants, the bank) funnels
-- through a handful of GLOBAL functions, so we save the originals and
-- replace them. That is exactly how OneBag did it in 1.12; there is no
-- hooksecurefunc in this client (that is a 2.0 API) and none is needed —
-- nothing here is protected.
--
-- Item MOVEMENT (PickupContainerItem/UseContainerItem) is called from a real
-- mouse OnClick, which IS hardware-event context — the same context that makes
-- the panel's Reload! button work where programmatic ReloadUI is a silent
-- no-op on this build.
-- r13 amends "never move items from OnUpdate" to "never move items from
-- OnUpdate UNMEASURED": the autosort engine below does exactly that, but it
-- fires its first swap from the click and then watches whether the OnUpdate
-- ones have any effect at all, so a gate shows up as telemetry instead of as a
-- button that mysteriously does nothing.
--
-- The buttons are PLAIN Buttons, NOT ContainerFrameItemButtonTemplate: that
-- template carries OnClick/OnEnter logic bound to a ContainerFrame parent
-- (it derives bag id from the parent frame's id), so reusing it outside one
-- misbehaves. Icon texture + count fontstring + our own click routing is the
-- whole widget.
--------------------------------------------------------------------------

local BAG_COLS = 8
local BAG_BTN_SIZE = 37
local BAG_BTN_PAD = 4
local BAG_MARGIN = 12
local BAG_HEADER = 30  -- vertical room for title + counts

-- 1.12 has ITEM_QUALITY_COLORS in FrameXML, but relying on a Blizzard global
-- that may or may not exist on a private-server build is a silent-nil risk;
-- the six numbers are cheaper than the dependency.
local BAG_QUALITY_COLOR = {
  [2] = { 0.12, 1.00, 0.00 }, -- uncommon
  [3] = { 0.00, 0.44, 0.87 }, -- rare
  [4] = { 0.64, 0.21, 0.93 }, -- epic
  [5] = { 1.00, 0.50, 0.00 }, -- legendary
  [6] = { 0.90, 0.80, 0.50 }, -- artifact
}

local bags = { buttons = {}, dirty = true }
-- Forward declaration: the button OnClick handlers (created below) close over
-- the refresh function, so the local has to EXIST before they are defined.
-- `function bagsUpdate()` later assigns into this local, not a new global.
local bagsUpdate

local bagsFrame = CreateFrame("Frame", "ShadowBagsFrame", UIParent)
bagsFrame:SetWidth(BAG_MARGIN * 2 + BAG_COLS * BAG_BTN_SIZE + (BAG_COLS - 1) * BAG_BTN_PAD)
bagsFrame:SetHeight(BAG_HEADER + 4 * (BAG_BTN_SIZE + BAG_BTN_PAD) + BAG_MARGIN)
bagsFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
bagsFrame:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
bagsFrame:SetBackdropColor(0.05, 0.02, 0.10, 0.92) -- same purple as the panel
bagsFrame:EnableMouse(true)
bagsFrame:SetMovable(true)
bagsFrame:SetFrameStrata("HIGH") -- above the world UI, below GameTooltip
bagsFrame:RegisterForDrag("LeftButton")
bagsFrame:SetScript("OnDragStart", function() bagsFrame:StartMoving() end)
bagsFrame:SetScript("OnDragStop", function() bagsFrame:StopMovingOrSizing() end)
bagsFrame:Hide()

local bagsTitle = bagsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
bagsTitle:SetPoint("TOPLEFT", bagsFrame, "TOPLEFT", BAG_MARGIN, -9)
bagsTitle:SetText("|cFF9482C9Shadow Bags|r")

local bagsCount = bagsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
bagsCount:SetPoint("TOPRIGHT", bagsFrame, "TOPRIGHT", -36, -11) -- clear of the close button
bagsCount:SetText("")

-- Money footer (r15): currencies live with the bags, like every bag addon
-- since the dawn of OneBag. Vanilla has exactly one currency — coin.
local bagsMoney = bagsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
bagsMoney:SetPoint("BOTTOMRIGHT", bagsFrame, "BOTTOMRIGHT", -10, 8)
bagsMoney:SetJustifyH("RIGHT")
bagsMoney:SetText("")

-- Colour-coded g/s/c for an arbitrary copper amount (r47: the bag window
-- prices a vendor run with it, so it can no longer read GetMoney itself).
function F.copperString(c)
  c = c or 0
  local gold = math.floor(c / 10000)
  local silver = math.floor(math.mod(c, 10000) / 100)
  local copper = math.mod(c, 100)
  if gold > 0 then
    return string.format("|cFFFFD700%dg|r |cFFC7C7CF%ds|r |cFFEDA55F%dc|r", gold, silver, copper)
  elseif silver > 0 then
    return string.format("|cFFC7C7CF%ds|r |cFFEDA55F%dc|r", silver, copper)
  end
  return string.format("|cFFEDA55F%dc|r", copper)
end

function F.moneyString()
  return F.copperString(GetMoney() or 0)
end

local bagsClose = CreateFrame("Button", nil, bagsFrame, "UIPanelCloseButton")
bagsClose:SetPoint("TOPRIGHT", bagsFrame, "TOPRIGHT", -2, -2)
-- The template's own OnClick calls HideParentFrame(); be explicit instead so
-- this does not depend on that helper existing on this build.
bagsClose:SetScript("OnClick", function() bagsFrame:Hide() end)

-- Buttons are created on demand and then REUSED forever (creating frames
-- every refresh would leak — 1.12 frames cannot be destroyed).
function F.bagButton(index)
  local btn = bags.buttons[index]
  if btn then return btn end
  btn = CreateFrame("Button", nil, bagsFrame)
  btn:SetWidth(BAG_BTN_SIZE)
  btn:SetHeight(BAG_BTN_SIZE)
  btn:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  btn.icon = btn:CreateTexture(nil, "ARTWORK")
  btn.icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 3, -3)
  btn.icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -3, 3)
  btn.count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  btn.count:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -4, 4)
  btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  -- Default is LeftButtonUp only; the right-click "use/equip/sell" path needs
  -- to be registered explicitly or the handler simply never fires.
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:SetScript("OnEnter", function()
    -- `this` is the button (1.12 passes script args as globals, no self).
    if not this.saBag or this.saEmpty then return end
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetBagItem(this.saBag, this.saSlot)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  btn:SetScript("OnClick", function()
    -- OnClick's `arg1` is the mouse button name.
    if not this.saBag then return end
    if arg1 == "RightButton" then
      -- use / equip / sell-to-merchant — the default game logic decides which
      UseContainerItem(this.saBag, this.saSlot)
    else
      -- pick up / drop / swap: whatever the cursor is holding, the client's
      -- own container logic sorts out. Shift+Left stack-splitting is NOT
      -- wired this rev (deliberate: SplitContainerItem with a bad count is a
      -- good way to lose a stack, and the default UI is not there to catch it).
      PickupContainerItem(this.saBag, this.saSlot)
    end
    -- ITEM_LOCK_CHANGED will refresh us anyway; refreshing now means the grid
    -- never renders one click behind the cursor.
    bagsUpdate()
  end)
  bags.buttons[index] = btn
  return btn
end

function bagsUpdate()
  -- OnUpdate/OnShow do not exist for a hidden frame's children either; skip
  -- the work and remember to catch up when we are shown again.
  if not bagsFrame:IsShown() then
    bags.dirty = true
    return
  end
  bags.dirty = false
  local index, used = 0, 0
  local bag = 0
  while bag <= 4 do
    local n = GetContainerNumSlots(bag)
    if n and n > 0 then
      local slot = 1
      while slot <= n do
        index = index + 1
        local btn = F.bagButton(index)
        -- 1.12 signature: texture, itemCount, locked, quality, readable
        local texture, itemCount, locked, quality = GetContainerItemInfo(bag, slot)
        btn.saBag, btn.saSlot = bag, slot
        btn.saEmpty = not texture
        if texture then
          used = used + 1
          btn.icon:SetTexture(texture)
          -- Texture:SetDesaturated is a 2.0 API — fade the icon instead to
          -- show "locked" (picked up / in flight).
          btn.icon:SetAlpha(locked and 0.35 or 1.0)
          btn.icon:Show()
          if itemCount and itemCount > 1 then
            btn.count:SetText(tostring(itemCount))
            btn.count:Show()
          else
            btn.count:Hide()
          end
          local c = quality and BAG_QUALITY_COLOR[quality]
          if c then
            btn:SetBackdropBorderColor(c[1], c[2], c[3], 1)
          else
            btn:SetBackdropBorderColor(0.40, 0.35, 0.50, 1)
          end
          btn:SetBackdropColor(0.10, 0.08, 0.16, 0.90)
        else
          btn.icon:Hide()
          btn.count:Hide()
          btn:SetBackdropBorderColor(0.22, 0.20, 0.30, 1) -- empty = dark socket
          btn:SetBackdropColor(0.02, 0.01, 0.05, 0.90)
        end
        -- ClearAllPoints first: SetPoint ACCUMULATES anchors in 1.12, so a
        -- re-layout after a bag swap would fight its own old anchor.
        local i0 = index - 1
        local col = math.mod(i0, BAG_COLS)
        local row = math.floor(i0 / BAG_COLS)
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", bagsFrame, "TOPLEFT",
          BAG_MARGIN + col * (BAG_BTN_SIZE + BAG_BTN_PAD),
          -(BAG_HEADER + row * (BAG_BTN_SIZE + BAG_BTN_PAD)))
        btn:Show()
        slot = slot + 1
      end
    end
    bag = bag + 1
  end
  -- Bag swapped for a smaller one: park the now-surplus buttons.
  local extra = index + 1
  while bags.buttons[extra] do
    bags.buttons[extra]:Hide()
    extra = extra + 1
  end
  local rows = math.ceil(index / BAG_COLS)
  if rows < 1 then rows = 1 end
  -- +16: money footer row under the grid
  bagsFrame:SetHeight(BAG_HEADER + rows * (BAG_BTN_SIZE + BAG_BTN_PAD) + BAG_MARGIN - BAG_BTN_PAD + 16)
  bagsCount:SetText(string.format("|cFFCCCCCC%d/%d used|r", used, index))
  bagsMoney:SetText(F.moneyString())
end

function F.bagsShow()
  bagsFrame:Show()
  bagsUpdate()
end

function F.bagsHide()
  bagsFrame:Hide()
end

function F.bagsToggle()
  if bagsFrame:IsShown() then F.bagsHide() else F.bagsShow() end
end

bagsFrame:SetScript("OnShow", function()
  if bags.dirty then bagsUpdate() end
end)

--------------------------------------------------------------------------
-- AUTOSORT (r13): a "Sort" button in the ShadowBags header that packs every
-- item in bags 0..4 to the front of the grid, grouped by type.
--
-- THE PLAN IS NEVER REPLAYED. Every step recomputes the next needed swap
-- from the CURRENT bag contents, because a swap moves two items at once and
-- any precomputed move list is stale the instant the first one lands. The
-- loop is: scan -> sort a copy -> find the first position whose occupant is
-- wrong -> swap the right item into it -> wait for the server -> repeat.
-- That converges (each completed swap fixes at least position i) and it is
-- immune to the human clicking things mid-sort: the next scan just sees the
-- new reality.
--
-- ASYNC IS THE WHOLE PROBLEM. PickupContainerItem does not move anything by
-- itself; it puts the item on the cursor, the second call asks the server to
-- place it, and BOTH slots read `locked` until the server answers. Firing the
-- next swap before that answer arrives moves phantoms. So exactly one swap is
-- in flight at a time and the driver polls for the locks to clear.
--
-- GATING PROBE (the reason the first swap is fired from the OnClick): this
-- client silently ignores ReloadUI outside hardware-event context (see the
-- driver notes) and the r11 loot work suggests LootSlot may be gated the same
-- way. If PickupContainerItem is also gated, OnUpdate swaps will produce no
-- lock and no content change at all. The engine measures exactly that: the
-- FIRST swap goes out inside the button's OnClick (hardware event, known-good
-- path), the rest from OnUpdate. Two consecutive no-effect OnUpdate swaps
-- after a click swap provably worked = gated, and we F.say so once and stop.
-- The fix for that world is a click-stepper button; NOT implemented here on
-- purpose — no point building it before the telemetry says we need it.
--------------------------------------------------------------------------

local SORT_TIMEOUT   = 3.0   -- seconds with no completed move -> abort
local SORT_SETTLE    = 0.35  -- seconds a fired swap gets to show ANY effect
local SORT_MAX_MOVES = 200   -- runaway guard; a full 5-bag sort is well under

local sort = {
  active = false,
  moves = 0,
  seq = 0,          -- like reloadSeq: keeps two identical results from being
                    -- swallowed by F.emit()'s 30s dedupe
  lastMoveAt = 0,
  pend = nil,       -- the single in-flight swap, or nil
  clickWorked = false,
  ctxFail = 0,      -- consecutive no-effect swaps fired from OnUpdate
  skipBag = {},     -- bags that rejected a placement (soul bag / quiver)
}

-- GetItemInfo is NOT reliably populated in 1.12: it answers nil until the
-- client has actually seen the item this session. Cache the answers we do get
-- and never cache the misses, so a later pass can still learn the type.
local sortTypeCache = {}

function F.cursorBusy()
  local ok, has = pcall(CursorHasItem)
  if not ok then return false end
  return has and true or false
end

-- ClearCursor RETURNS a held bag item to where it came from (it does not
-- destroy it). pcall because a missing global here would kill the driver.
function F.cursorDrop()
  pcall(ClearCursor)
end

-- "type/subtype", or "zz-unknown" so unidentified items sort to the end
-- instead of scattering through the grid.
function F.itemTypeKey(id)
  if not id then return "zz-unknown" end
  local cached = sortTypeCache[id]
  if cached then return cached end
  local ok, r1, r2, r3, r4, r5, r6, r7 = pcall(GetItemInfo, id)
  if not ok or not r1 then return "zz-unknown" end
  -- Return-order skepticism: 1.12 is
  --   name, link, quality, iLevel, TYPE, SUBTYPE, stack, equipLoc, texture
  -- while 2.0+ wedged itemMinLevel in at 5. Rather than trust either doc,
  -- discriminate on what is actually there: slot 5 is a string only in the
  -- 1.12 layout (it is a number in the newer one).
  local typ, sub
  if type(r5) == "string" then
    typ, sub = r5, r6
  else
    typ, sub = r6, r7
  end
  if type(typ) ~= "string" then return "zz-unknown" end
  local key = string.lower(typ) .. "/"
  if type(sub) == "string" then key = key .. string.lower(sub) end
  sortTypeCache[id] = key
  return key
end

-- Specialty containers (soul bag, quiver, ammo pouch) refuse ordinary items.
-- Dropping one in produces NO lock and NO content change — indistinguishable
-- from the gating we are probing for — so keep them out of the grid entirely.
-- 1.12's second return here is not something to bet on, hence the guard AND
-- the empirical fallback in the tick (a bag that rejects a placement gets
-- added to sort.skipBag for the rest of the run).
function F.bagIsNormal(bag)
  if sort.skipBag[bag] then return false end
  if bag == 0 then return true end -- backpack is never a specialty bag
  local ok, free, btype = pcall(GetContainerNumFreeSlots, bag)
  if not ok then return true end
  if type(btype) == "number" and btype ~= 0 then return false end
  return true
end

function F.slotLocked(bag, slot)
  local _, _, locked = GetContainerItemInfo(bag, slot)
  return locked and true or false
end

-- Content fingerprint of one slot. `locked` is deliberately NOT in here:
-- the lock flag is tracked separately as proof the client accepted the call,
-- and folding it in would make a lock flicker look like a completed move.
function F.slotSig(bag, slot)
  local tex, count = GetContainerItemInfo(bag, slot)
  return tostring(tex) .. "#" .. tostring(count)
end

-- Flat scan of every sortable slot, in bag/slot order. Index in this list IS
-- the position the sort reasons about; entry.tex nil = empty socket.
function F.sortScan()
  local list, n = {}, 0
  local bag = 0
  while bag <= 4 do -- NEVER -1/5+ (bank) and never -2 (keyring)
    if F.bagIsNormal(bag) then
      local slots = GetContainerNumSlots(bag)
      if slots and slots > 0 then
        local slot = 1
        while slot <= slots do
          n = n + 1
          local tex, count, locked, quality = GetContainerItemInfo(bag, slot)
          local e = {
            bag = bag, slot = slot, idx = n,
            locked = locked and true or false,
          }
          if tex then
            e.tex = tex
            e.count = count or 1
            e.quality = quality or 1
            -- GetContainerItemLink gives "|cff...|Hitem:2589:0:0:0|h[..]|h|r".
            -- string.find returns start, stop, THEN the captures.
            local okl, link = pcall(GetContainerItemLink, bag, slot)
            if okl and link then
              local _, _, idStr = string.find(link, "item:(%d+)")
              if idStr then e.id = tonumber(idStr) end
            end
            e.tkey = F.itemTypeKey(e.id)
          end
          list[n] = e
          slot = slot + 1
        end
      end
    end
    bag = bag + 1
  end
  return list, n
end

-- Strict TOTAL order — table.sort in 5.0 is not stable and will happily raise
-- "invalid order function" on a sloppy comparator. The trailing idx tiebreak
-- does double duty: it makes the order total, and it means items that compare
-- equal keep their current positions, so equal items never generate a swap.
function F.sortCmp(a, b)
  if a.tkey ~= b.tkey then return a.tkey < b.tkey end
  if a.quality ~= b.quality then return a.quality > b.quality end
  local ai, bi = a.id or 0, b.id or 0
  if ai ~= bi then return ai < bi end
  if a.count ~= b.count then return a.count > b.count end
  return a.idx < b.idx
end

-- Returns destinationIndex, sourceEntry for the next swap, or nil when the
-- grid already matches the desired arrangement.
function F.sortNextSwap(list, n)
  local occ, m = {}, 0
  local i = 1
  while i <= n do
    if list[i].tex then
      m = m + 1
      occ[m] = list[i]
    end
    i = i + 1
  end
  table.sort(occ, F.sortCmp)
  -- occ[i] is the entry that BELONGS at position i; entries are the very same
  -- tables the scan produced, so identity comparison is the whole test.
  i = 1
  while i <= n do
    local want = occ[i] -- nil past the packed run: position i should be empty
    if want then
      if list[i] ~= want then
        return i, want
      end
    end
    -- The mirror case (want nil but the slot is occupied) cannot be reached:
    -- there are exactly m items, so an item sitting past position m implies an
    -- empty slot at or before m, which mismatches at a LOWER i than this one.
    i = i + 1
  end
  return nil, nil
end

-- Created below; the label helper closes over the local, so it must exist
-- first (and the creation must ASSIGN, not re-declare).
local sortBtn

function F.sortSetLabel(active)
  if not sortBtn then return end
  sortBtn:SetText(active and "|cFFFFAA00Sorting...|r" or "|cFFCCCCCCSort|r")
end

function F.sortStop(reason)
  sort.active = false
  sort.pend = nil
  if F.cursorBusy() then F.cursorDrop() end
  F.sortSetLabel(false)
  F.dtrace("sort stop " .. tostring(reason) .. " moves=" .. sort.moves)
  bagsUpdate()
end

function F.sortFinish()
  local n = sort.moves
  F.sortStop("done")
  F.emit("sort", "done moves=" .. n .. " #" .. sort.seq)
end

function F.sortAbort(why)
  local n = sort.moves
  F.sortStop(why)
  if why == "stalled" then
    F.emit("err", "sort stalled at " .. n .. " moves #" .. sort.seq)
  elseif why == "runaway" then
    F.emit("err", "sort runaway at " .. n .. " moves #" .. sort.seq)
  end
end

-- Fire at most ONE swap. ctx is "click" (hardware event) or "onupdate".
function F.sortIssue(ctx)
  if sort.pend then return end
  if F.cursorBusy() then return end -- the human is carrying something; wait
  local list, n = F.sortScan()
  local dstIdx, src = F.sortNextSwap(list, n)
  if not dstIdx then
    F.sortFinish()
    return
  end
  local dst = list[dstIdx]
  -- Locked = a move we (or the human) already asked for is still in flight.
  -- Skip gracefully: no plan to invalidate, the next tick just re-scans.
  if src.locked or dst.locked then return end
  if sort.moves >= SORT_MAX_MOVES then
    F.sortAbort("runaway")
    return
  end
  local sig = F.slotSig(src.bag, src.slot) .. "|" .. F.slotSig(dst.bag, dst.slot)
  -- SOURCE FIRST, ALWAYS. The destination may be an empty socket, and
  -- picking up an empty slot is a no-op — doing it in the other order would
  -- leave the item stranded on the cursor.
  PickupContainerItem(src.bag, src.slot)
  PickupContainerItem(dst.bag, dst.slot)
  -- Same-item landmine: dropping a stack onto a PARTIAL stack of the same item
  -- tops it up and leaves the remainder on the cursor instead of swapping.
  -- Put the remainder back where it came from; the recompute then sees two
  -- re-balanced stacks (and this quietly consolidates stacks as a bonus).
  if F.cursorBusy() then
    PickupContainerItem(src.bag, src.slot)
  end
  sort.pend = {
    sbag = src.bag, sslot = src.slot,
    dbag = dst.bag, dslot = dst.slot,
    sig = sig, at = GetTime(), ctx = ctx, sawLock = false,
  }
  bagsUpdate() -- shared refresh path: the grid shows the locked (faded) icons
end

-- Driven from the driver's OnUpdate (see below). Never sends chat directly.
function F.sortTick()
  if not sort.active then return end
  local now = GetTime()
  local p = sort.pend
  if p then
    if F.slotLocked(p.sbag, p.sslot) or F.slotLocked(p.dbag, p.dslot) then
      p.sawLock = true -- the client ACCEPTED the call; this path is not gated
      return
    end
    local sigNow = F.slotSig(p.sbag, p.sslot) .. "|" .. F.slotSig(p.dbag, p.dslot)
    if sigNow ~= p.sig then
      sort.moves = sort.moves + 1
      sort.lastMoveAt = now
      sort.ctxFail = 0
      if p.ctx == "click" then sort.clickWorked = true end
      sort.pend = nil
      bagsUpdate()
    elseif (now - p.at) > SORT_SETTLE then
      -- No lock, no content change: that call did literally nothing.
      sort.pend = nil
      if F.cursorBusy() then F.cursorDrop() end
      if not p.sawLock and p.ctx == "onupdate" then
        sort.ctxFail = sort.ctxFail + 1
        if sort.ctxFail >= 2 then
          if sort.clickWorked then
            -- The one line that settles it: clicks move items, OnUpdate does
            -- not. Next rev = click-stepper.
            F.emit("sort", "gated ctx=onupdate")
          else
            -- No click swap ever landed either, so this is not proof of a
            -- context gate — F.say so rather than blame the wrong thing.
            F.emit("sort", "noeffect ctx=onupdate click=untested")
          end
          F.sortStop("gated")
          return
        end
      end
      -- Empirical specialty-bag detection: that destination bag refused the
      -- item. Drop it from the grid and carry on with the rest.
      if not sort.skipBag[p.dbag] then
        sort.skipBag[p.dbag] = true
        F.dtrace("sort skipping bag " .. p.dbag .. " (placement refused)")
      end
    else
      return -- still inside the settle window
    end
  end
  if not sort.active then return end
  if (now - sort.lastMoveAt) > SORT_TIMEOUT then
    F.sortAbort("stalled")
    return
  end
  F.sortIssue("onupdate")
end

function F.sortStart()
  sort.seq = sort.seq + 1
  sort.active = true
  sort.moves = 0
  sort.pend = nil
  sort.ctxFail = 0
  sort.clickWorked = false
  sort.skipBag = {}
  sort.lastMoveAt = GetTime()
  F.sortSetLabel(true)
  F.dtrace("sort start #" .. sort.seq)
  -- The first swap goes out RIGHT HERE, still inside the mouse click, so the
  -- known-good hardware-event path is exercised before OnUpdate is trusted.
  F.sortIssue("click")
end

sortBtn = CreateFrame("Button", "ShadowBagsSortBtn", bagsFrame, "UIPanelButtonTemplate")
sortBtn:SetWidth(64)
sortBtn:SetHeight(20)
sortBtn:SetPoint("LEFT", bagsTitle, "RIGHT", 14, 0)
sortBtn:SetText("|cFFCCCCCCSort|r")
sortBtn:SetScript("OnClick", function()
  if sort.active then
    F.sortStop("cancel") -- re-click = cancel, and the label snaps back
    return
  end
  -- pcall: an error in here would die silently (scriptErrors is off) and the
  -- button would just look broken.
  local ok, err = pcall(F.sortStart)
  if not ok then
    F.emit("err", "sort start: " .. tostring(err))
    F.sortStop("error")
  end
end)

-- Contents change while the window is closed too — track dirt, refresh live.
local bagsEvents = CreateFrame("Frame", "ShadowBagsEventFrame", UIParent)
bagsEvents:RegisterEvent("BAG_UPDATE")
bagsEvents:RegisterEvent("PLAYER_MONEY") -- money footer refresh
bagsEvents:RegisterEvent("ITEM_LOCK_CHANGED")
bagsEvents:RegisterEvent("BAG_UPDATE_COOLDOWN")
bagsEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
bagsEvents:SetScript("OnEvent", function()
  if bagsFrame:IsShown() then
    bagsUpdate()
  else
    bags.dirty = true
  end
end)

-- The takeover. B / the bag-bar buttons / merchants / the bank all reach the
-- ContainerFrames through these globals, so replacing them is enough — the
-- Blizzard frames are never asked to open. Originals are parked on the
-- ShadowArmy root so a future rev (or a live /script) can put them back
-- without a reload.
ShadowArmy.origBagFuncs = {
  ToggleBackpack = ToggleBackpack,
  ToggleBag = ToggleBag,
  OpenBackpack = OpenBackpack,
  CloseBackpack = CloseBackpack,
  OpenAllBags = OpenAllBags,
  CloseAllBags = CloseAllBags,
}

function ToggleBackpack()
  F.bagsToggle()
end

-- The bag id is irrelevant now: there is one window and it holds every bag.
function ToggleBag(id)
  F.bagsToggle()
end

function OpenBackpack()
  F.bagsShow()
end

function CloseBackpack()
  F.bagsHide()
end

-- Called with the requesting frame (merchant/bank/trade) in vanilla; we do not
-- need it, but the parameter stays so the signature matches what callers pass.
function OpenAllBags(frame)
  F.bagsShow()
end

function CloseAllBags()
  F.bagsHide()
end

-- ToggleKeyRing is deliberately NOT hooked: the keyring is bag -2 and is not
-- in this grid, so it keeps using the Blizzard frame. Bank frames are likewise
-- untouched this rev — opening the bank shows this window (via OpenAllBags),
-- which is enough to click items across.

-- Escape closes it, like every other UI panel. UISpecialFrames is a list of
-- frame NAMES resolved with getglobal(), which is why the frame is named.
tinsert(UISpecialFrames, "ShadowBagsFrame")

--------------------------------------------------------------------------
-- BAG DISPOSITION WINDOW (r47, ticket 0039 phase 3): the readable half of
-- BagModel. Every item in bags 0-4 gets a coloured tag chip and the reason
-- behind it, so "what do I do with these 12 drops" is one click, not twelve
-- tooltip reads.
--
-- WHY IT READS ITEMDATA AND NOT GetItemInfo: 1.12 answers nil for anything
-- the client has not cached this session, which is most of what a bot's bags
-- fill with, and it has no sell-price API at all (docs/item-data.md). The
-- generated table is keyed by item id and every bag slot yields a link, and
-- every link carries `item:ID` — so the id parse below is the join.
--
-- ItemData.lua is registered in the .toc but the TOC file list is cached for
-- the whole client session, so on a client that has not restarted since
-- ticket 0040 the global is simply absent. EVERY read goes through
-- F.bagTagRow and the window says so instead of erroring.
--------------------------------------------------------------------------

-- Scoped in a do-block for the Lua 5.0 200-locals-per-function budget, the
-- same reason RouteModel's UI half below is: the main chunk was at 174 of
-- them before r47 and a window costs a frame local per widget. Registers
-- are released at the `end`, so only the F.* entry points survive it.
do
  local BAGTAG_TICK = 1.0    -- seconds; BAG_UPDATE arrives in bursts while looting
  local BAGTAG_LINE = 14
  local BAGTAG_NAME_MAX = 22

  local BAGTAG_COLOR = {
    SELL       = "FFFFD100",
    EQUIP      = "FF44FF44",
    KEEP_QUEST = "FFCC66FF",
    USE        = "FF44CCFF",
    HOLD       = "FF999999",
  }

  -- Sort order: the two tags that ask for an action float to the top.
  local BAGTAG_RANK = { EQUIP = 1, SELL = 2, KEEP_QUEST = 3, USE = 4, HOLD = 5 }

  -- BagModel.EQUIP_SLOT values -> the 1.12 equipment slot id GetInventoryItemLink
  -- wants. These are INVSLOT ids (1 head .. 19 tabard), NOT inventory_type: the
  -- two enums overlap numerically and disagree, which is exactly why they are
  -- kept in separate tables with different key spaces.
  local BAGTAG_WORN_SLOT = {
    head = 1, neck = 2, shoulder = 3, chest = 5, waist = 6, legs = 7,
    feet = 8, wrist = 9, hands = 10, back = 15, ["off-hand"] = 17,
  }

  local bagTag = { nextAt = 0, dirty = true }

  -- The ONLY read of the generated table. Absent file -> nil everywhere, and
  -- BagModel already answers HOLD "unknown item" for that.
  function F.bagTagRow(id)
    if not id then return nil end
    if not ShadowArmyItemData then return nil end
    return ShadowArmyItemData[id]
  end

  function F.bagTagLinkId(link)
    if not link then return nil end
    local _, _, idStr = string.find(link, "item:(%d+)")
    if not idStr then return nil end
    return tonumber(idStr)
  end

  function F.bagTagLinkName(link)
    if not link then return nil end
    local _, _, name = string.find(link, "%[(.-)%]")
    return name
  end

  function F.bagTagItems()
    local items, n = {}, 0
    local bag = 0
    while bag <= 4 do
      local slots = GetContainerNumSlots(bag)
      if slots and slots > 0 then
        local slot = 1
        while slot <= slots do
          local link = GetContainerItemLink(bag, slot)
          if link then
            local id = F.bagTagLinkId(link)
            -- 1.12 signature: texture, itemCount, locked, quality, readable
            local _, count = GetContainerItemInfo(bag, slot)
            n = n + 1
            items[n] = {
              id = id,
              name = F.bagTagLinkName(link),
              count = count or 1,
              bag = bag, bagSlot = slot,
              data = F.bagTagRow(id),
            }
          end
          slot = slot + 1
        end
      end
      bag = bag + 1
    end
    return items
  end

  -- What is already worn, as ItemData rows keyed the way BagModel.EQUIP_SLOT
  -- names them. An equipped item with no row becomes an EMPTY row rather than
  -- nil: nil means "slot is empty" to the model, and calling a filled slot
  -- empty is the one wrong answer here. An empty row defaults `lvl` to 0, so
  -- the worst case is an over-eager upgrade hint on an item we cannot price.
  function F.bagTagWorn()
    local out = {}
    for key, slotId in pairs(BAGTAG_WORN_SLOT) do
      local link = GetInventoryItemLink("player", slotId)
      if link then
        out[key] = F.bagTagRow(F.bagTagLinkId(link)) or {}
      end
    end
    return out
  end

  function F.bagTagSnapshot()
    local _, classToken = UnitClass("player")
    return {
      items = F.bagTagItems(),
      player = {
        level = UnitLevel("player") or 1,
        classToken = classToken,
        equipped = F.bagTagWorn(),
      },
    }
  end

  local function bagTagCmp(a, b)
    local ra = BAGTAG_RANK[a.tag] or 9
    local rb = BAGTAG_RANK[b.tag] or 9
    if ra ~= rb then return ra < rb end
    local na, nb = a.name or "", b.name or ""
    if na ~= nb then return na < nb end
    return (a.id or 0) < (b.id or 0)
  end

  local bagTagFrame = CreateFrame("Frame", "ShadowArmyBagTagFrame", UIParent)
  bagTagFrame:SetWidth(430)
  bagTagFrame:SetHeight(360)
  bagTagFrame:SetPoint("CENTER", UIParent, "CENTER", -180, 0)
  bagTagFrame:SetFrameStrata("HIGH")
  bagTagFrame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  bagTagFrame:SetBackdropColor(0.05, 0.02, 0.10, 0.92)
  bagTagFrame:EnableMouse(true)
  bagTagFrame:SetMovable(true)
  bagTagFrame:RegisterForDrag("LeftButton")
  bagTagFrame:SetScript("OnDragStart", function() bagTagFrame:StartMoving() end)
  bagTagFrame:SetScript("OnDragStop", function() bagTagFrame:StopMovingOrSizing() end)
  bagTagFrame:Hide()
  tinsert(UISpecialFrames, "ShadowArmyBagTagFrame")

  local bagTagTitle = bagTagFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  bagTagTitle:SetPoint("TOP", bagTagFrame, "TOP", 0, -9)
  bagTagTitle:SetText("|cFF9482C9Shadow Bags — what to do with it|r")

  local bagTagClose = CreateFrame("Button", nil, bagTagFrame, "UIPanelCloseButton")
  bagTagClose:SetPoint("TOPRIGHT", bagTagFrame, "TOPRIGHT", -2, -2)
  bagTagClose:SetScript("OnClick", function() bagTagFrame:Hide() end)

  local bagTagSummary = bagTagFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  bagTagSummary:SetPoint("BOTTOMLEFT", bagTagFrame, "BOTTOMLEFT", 14, 14)
  bagTagSummary:SetJustifyH("LEFT")
  bagTagSummary:SetText("")

  local bagTagScroll = CreateFrame(
    "ScrollFrame", "ShadowArmyBagTagScroll", bagTagFrame, "UIPanelScrollFrameTemplate")
  bagTagScroll:SetPoint("TOPLEFT", bagTagFrame, "TOPLEFT", 12, -30)
  bagTagScroll:SetPoint("BOTTOMRIGHT", bagTagFrame, "BOTTOMRIGHT", -30, 34)

  local bagTagChild = CreateFrame("Frame", "ShadowArmyBagTagScrollChild", bagTagScroll)
  bagTagChild:SetWidth(376)
  bagTagChild:SetHeight(1)
  bagTagScroll:SetScrollChild(bagTagChild)

  -- Same rule as every other list in this file: FontStrings are created once and
  -- reused forever. 1.12 frames and regions cannot be destroyed.
  local bagTagLines = {}
  function F.bagTagLine(i)
    local line = bagTagLines[i]
    if line then return line end
    line = bagTagChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    line:SetWidth(370)
    line:SetHeight(BAGTAG_LINE)
    line:SetJustifyH("LEFT")
    line:SetPoint("TOPLEFT", bagTagChild, "TOPLEFT", 0, -((i - 1) * BAGTAG_LINE))
    line:SetText("")
    bagTagLines[i] = line
    return line
  end

  function F.bagTagRows()
    if not ShadowArmyItemData then
      return { "|cFFFFAA00item data not loaded yet (client restart pending)|r",
        "|cFF888888ItemData.lua is in the .toc, but 1.12 caches the TOC file|r",
        "|cFF888888list for the whole client session — it loads on next launch.|r" },
        nil
    end
    local result = BagModel.evaluate(F.bagTagSnapshot())
    local list, n = {}, 0
    local i = 1
    while result.items[i] do
      n = n + 1
      list[n] = result.items[i]
      i = i + 1
    end
    if n > 1 then table.sort(list, bagTagCmp) end
    local rows, nr = {}, 0
    i = 1
    while i <= n do
      local it = list[i]
      local hex = BAGTAG_COLOR[it.tag] or BAGTAG_COLOR.HOLD
      local stack = (it.count and it.count > 1) and ("x" .. it.count) or ""
      nr = nr + 1
      rows[nr] = string.format("|c%s[%s]|r |cFFDDDDDD%s|r |cFF777777%s|r  |cFF999999%s|r",
        hex, it.tag, F.questShort(it.name or ("item " .. tostring(it.id)), BAGTAG_NAME_MAX),
        stack, it.reason or "")
      i = i + 1
    end
    if nr == 0 then rows[1] = "|cFF777777bags are empty|r" end
    return rows, result
  end

  function F.bagTagRefresh()
    if not bagTagFrame:IsShown() then
      bagTag.dirty = true
      return
    end
    bagTag.dirty = false
    local rows, result = F.bagTagRows()
    local i = 1
    while rows[i] do
      F.bagTagLine(i):SetText(rows[i])
      i = i + 1
    end
    local painted = i - 1
    while bagTagLines[i] do
      bagTagLines[i]:SetText("")
      i = i + 1
    end
    local height = painted * BAGTAG_LINE
    if height < 1 then height = 1 end
    bagTagChild:SetHeight(height)
    if bagTagScroll.UpdateScrollChildRect then bagTagScroll:UpdateScrollChildRect() end
    if result then
      local summary = string.format("|cFFCCCCCC%d items|r", table.getn(result.items))
      if result.sellCount > 0 then
        summary = summary .. string.format("  |cFFFFD100%d to sell|r %s",
          result.sellCount, F.copperString(result.sellCopper))
      end
      if result.unknown > 0 then
        summary = summary .. string.format("  |cFF888888%d unknown|r", result.unknown)
      end
      bagTagSummary:SetText(summary)
    else
      bagTagSummary:SetText("")
    end
  end

  -- Debounced from the driver: BAG_UPDATE fires several times per loot, and the
  -- refresh walks every bag slot plus eleven equipped slots. Only ever runs
  -- while the window is actually up.
  function F.bagTagTick()
    if not bagTagFrame:IsShown() then return end
    if not bagTag.dirty then return end
    local now = GetTime()
    if now < bagTag.nextAt then return end
    bagTag.nextAt = now + BAGTAG_TICK
    F.bagTagRefresh()
  end

  function F.bagTagToggle()
    if bagTagFrame:IsShown() then
      bagTagFrame:Hide()
    else
      bagTagFrame:Show()
      F.bagTagRefresh()
    end
  end

  local bagTagEvents = CreateFrame("Frame", "ShadowArmyBagTagEvents", UIParent)
  bagTagEvents:RegisterEvent("BAG_UPDATE")
  bagTagEvents:SetScript("OnEvent", function()
    bagTag.dirty = true
  end)

  local bagTagBtn = CreateFrame("Button", "ShadowArmyBagTagBtn", panel, "UIPanelButtonTemplate")
  bagTagBtn:SetWidth(194) -- full inner width; bottom row is its own
  bagTagBtn:SetHeight(20)
  bagTagBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 8)
  bagTagBtn:SetText("|cFF9482C9Bags|r")
  bagTagBtn:SetScript("OnClick", function()
    local ok, err = pcall(F.bagTagToggle)
    if not ok then F.emit("err", "bagTag: " .. tostring(err)) end
  end)
end

--------------------------------------------------------------------------
-- Inventory over the chat bus (r49, ticket 0052). Fully automatic: no
-- button, no slash command, nothing for monofuel to remember. The System
-- gets Murist's bags within ~10s of a loot event and joins the ids against
-- the world DB on its side (names/prices are ITS job, not ours — sending
-- names would blow the 240-char line budget for no gain).
--
-- Encoding lives in InvModel (pure, host-tested). This half is only: walk
-- the bags, hand the model an aggregate, hand the model's lines to F.emit.
--
-- Cadence: full snapshot 5s after PLAYER_ENTERING_WORLD (bags read empty at
-- the instant the event fires) and every 5 minutes after; deltas 5s after
-- the last BAG_UPDATE, since looting fires that event in bursts.
--------------------------------------------------------------------------
do
  local inv = {
    fullEvery = 300,   -- seconds between unprompted full snapshots
    debounce = 5,      -- quiet seconds after the last BAG_UPDATE
    settle = 5,        -- grace after a loading screen before the first read
    armed = false,     -- nothing goes out before PLAYER_ENTERING_WORLD
    nextFull = 0,
    dirtyAt = 0,       -- 0 = no pending delta
    state = nil,       -- last aggregate we told The System about
  }

  -- bags 0-4 -> { [id] = total count }. Same link/id parse the bag window
  -- uses (F.bagTagLinkId); 1.12 GetContainerItemInfo answers
  -- texture, count, locked, quality, readable.
  function F.invScan()
    local rows, n = {}, 0
    local bag = 0
    while bag <= 4 do
      local slots = GetContainerNumSlots(bag)
      if slots and slots > 0 then
        local slot = 1
        while slot <= slots do
          local link = GetContainerItemLink(bag, slot)
          if link then
            local _, count = GetContainerItemInfo(bag, slot)
            n = n + 1
            rows[n] = { id = F.bagTagLinkId(link), count = count or 1 }
          end
          slot = slot + 1
        end
      end
      bag = bag + 1
    end
    return InvModel.aggregate(rows)
  end

  function F.invSend(kind, lines, n)
    local i = 1
    while i <= n do
      F.emit(kind, lines[i])
      i = i + 1
    end
  end

  function F.invSendFull()
    local state = F.invScan()
    local lines, n = InvModel.snapshotLines(state)
    inv.state = state
    inv.nextFull = GetTime() + inv.fullEvery
    inv.dirtyAt = 0
    F.invSend(InvModel.KIND_FULL, lines, n)
  end

  function F.invSendDelta()
    local state = F.invScan()
    local lines, n = InvModel.deltaLines(inv.state, state)
    inv.state = state
    inv.dirtyAt = 0
    if n > 0 then F.invSend(InvModel.KIND_DELTA, lines, n) end
  end

  -- Driven from the driver's OnUpdate; both paths are time-gated, so this is
  -- a pair of number compares on the frames where nothing is due.
  function F.invTick()
    if not inv.armed then return end
    local now = GetTime()
    if now >= inv.nextFull then
      F.invSendFull()
      return
    end
    if inv.dirtyAt > 0 and now >= inv.dirtyAt then
      F.invSendDelta()
    end
  end

  local invEvents = CreateFrame("Frame", "ShadowArmyInvEvents", UIParent)
  invEvents:RegisterEvent("BAG_UPDATE")
  invEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
  invEvents:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
      -- A loading screen can also mean "the client dropped item data": the
      -- next line-set is a FULL snapshot, never a delta against a stale map.
      inv.armed = true
      inv.state = nil
      inv.nextFull = GetTime() + inv.settle
      inv.dirtyAt = 0
    else
      inv.dirtyAt = GetTime() + inv.debounce
    end
  end)
end

--------------------------------------------------------------------------
-- QUEST HELPER (r18, r32 checklist): "where do I go next" — quest-identity
-- checklist in the advisor panel, color-matched dots on minimap + world map.
-- Everything here is driven by QuestData.lua (global ShadowArmyQuestData,
-- keyed by the EXACT quest title). 1.12 does not expose quest IDs to addons
-- at all, so the title STRING is the only join between the live quest log and
-- mined coordinates — that is why the data file is shaped the way it is, not
-- a stylistic choice.
--
-- r32 identity rule: one color + one number per QUEST (not per objective, not
-- kill-vs-turnin). Gold soup is gone. Panel lists quests with nested objective
-- progress; pins use that quest's color so multi-quest zones are readable.
--
-- If the data file is absent, accepted quests and live objectives still work;
-- only coordinate enrichment no-ops after one `err quest data missing` line.
--
-- The live quest log is authoritative. Generated QuestData can enrich a live
-- objective with coordinates, but missing data, a subzone quest-log header,
-- or an unavailable player map position must never hide the accepted quest.
-- ShadowArmyQuestZones is generated beside QuestData and maps its AreaTable
-- ids to the parent-zone names returned by GetRealZoneText(). This is what
-- makes a Red Cloud Mesa quest safely resolve to the Mulgore map.
--------------------------------------------------------------------------

local QUEST_TICK_EVERY = 0.5   -- recompute the nearest objective this often
local QUEST_MARKER_EVERY = 0.2 -- WORLD_MAP_UPDATE repaint throttle
local QUEST_MAX_CAND = 60      -- bound on waypoints considered per scan
local QUEST_MAX_BLIPS = 8      -- minimap dots (created once, reused forever)
local QUEST_MAX_MARKERS = 30   -- world map dots

-- Zone dimensions are NOT exposed in 1.12 (no zone size API, and no world
-- coordinates for anything but yourself), so a percentage delta cannot be
-- turned into a real distance — only into an estimate against a nominal
-- vanilla zone footprint. Hence every distance the UI prints carries a "~".
-- Tunable: vanilla zone maps are ~3:2, and most Eastern Kingdoms leveling
-- zones land within roughly 20% of these numbers.
local QUEST_ZONE_YARDS_X = 3500
local QUEST_ZONE_YARDS_Y = 2333

-- Minimap view RADIUS in yards per Minimap:GetZoom() level (0..5). These are
-- the outdoor numbers vanilla map addons converged on; approximate and
-- deliberately tunable. 1.12 has no dependable IsIndoors(), so indoors the
-- blips read slightly optimistic — they still point the right way, which is
-- the entire job of a dot on a rim.
local QUEST_MINIMAP_RADIUS = {
  [0] = 233.3, [1] = 200.0, [2] = 166.6,
  [3] = 133.3, [4] = 100.0, [5] = 66.6,
}

-- FRIZQT__.TTF (the 1.12 UI font) is not trusted to carry U+2192 / U+21A9;
-- a missing glyph renders as an empty box and the line reads as broken. ASCII
-- markers always render. Swap these two for "->" / "<-" arrows if you run a
-- font pack that has them.
local QUEST_MARK_GO = ">>"
local QUEST_MARK_TURNIN = "<<"

local COMPASS_TAN22 = 0.4142 -- tan(22.5 deg): the 8-point octant boundary

local quest = {
  markersEnabled = true,
  dataWarned = false,   -- the one-and-only "no data file" F.emit
  nextTickAt = 0,
  nextMarkerAt = 0,
  nextMapFix = 0,
  logSig = "",          -- change detector for the debug-only log trace
  target = nil,         -- nearest "go here" waypoint (tracked wins)
  spots = {},           -- drawable waypoints (blip-priority order)
  away = {},            -- r54: quests whose only waypoints are in other zones
  list = {},            -- complete live checklist from QuestModel
  status = nil,         -- idle/error reason string when list is empty
  zoneName = "",
  px = 0, py = 0, posOK = false,
  identity = nil,       -- lazily filled by F.questIdentity (false = no match)
}

local questBtn -- created below; opens the complete quest checklist window

function F.questData()
  if ShadowArmyQuestData then return ShadowArmyQuestData end
  if not quest.dataWarned then
    quest.dataWarned = true
    F.emit("err", "quest data missing")
  end
  return nil
end

-- GetPlayerMapPosition answers for whatever zone the WORLD MAP is currently
-- showing, so it reads 0,0 while the human browses another zone (and in
-- instances, which have no player dot at all). When the map is CLOSED we can
-- quietly put it back with SetMapToCurrentZone(); while it is OPEN we leave
-- the human's browsing alone and stop drawing instead. A stale sample is
-- never reused — that is how you end up with an arrow pointing at a spot in
-- the zone you left twenty minutes ago.
function F.questPosition()
  local x, y = GetPlayerMapPosition("player")
  if (not x) or (x == 0 and y == 0) then
    local now = GetTime()
    if now >= quest.nextMapFix
        and not (WorldMapFrame and WorldMapFrame:IsVisible()) then
      quest.nextMapFix = now + 2
      pcall(SetMapToCurrentZone)
      x, y = GetPlayerMapPosition("player")
    end
  end
  if (not x) or (x == 0 and y == 0) then
    quest.posOK = false
    return false
  end
  -- The data file is in percent; the API is in fractions.
  quest.px, quest.py, quest.posOK = x * 100, y * 100, true
  return true
end

function F.questLearn(id, name)
  if not id or not name or name == "" then return end
  local known = quest.learned[id]
  if known == nil then
    quest.learned[id] = name
  elseif known and known ~= name then
    quest.learned[id] = false -- two names for one id: never trust it again
  end
end

-- Rule (1) OR the learned-id fallback; see the section header.
function F.questSpotHere(q, spotZone, headerMatch, zone)
  if headerMatch and (not spotZone or spotZone == q.zone) then return true end
  local learned = spotZone and quest.learned[spotZone]
  if learned and learned == zone then return true end
  return false
end

-- Map space is +x east, +y SOUTH (screen down). The vanilla minimap is
-- north-up by default and GetPlayerFacing is not something to lean on in
-- 1.12, so no rotation enters any of this. Octants are decided by comparing
-- the two legs against tan(22.5) rather than calling atan2 — one less 5.0
-- math library assumption for the same answer.
function F.questBearing(dx, dy)
  local ax = dx >= 0 and dx or -dx
  local ay = dy >= 0 and dy or -dy
  local ns = (dy < 0) and "N" or "S"
  local ew = (dx >= 0) and "E" or "W"
  if ax < ay * COMPASS_TAN22 then return ns end
  if ay < ax * COMPASS_TAN22 then return ew end
  return ns .. ew
end

function F.questYards(dx, dy)
  local ux = dx / 100 * QUEST_ZONE_YARDS_X
  local uy = dy / 100 * QUEST_ZONE_YARDS_Y
  return math.sqrt(ux * ux + uy * uy)
end

-- Live objective progress only exists as leaderboard STRINGS ("Mindless
-- Zombie slain: 3/8"). SelectQuestLogEntry is global UI state — it moves the
-- human's selection in an open quest log — so the caller restores the old
-- selection once the whole scan is done, and the scan is skipped outright
-- while the log is on screen.
function F.questBoards(i)
  SelectQuestLogEntry(i)
  local out = {}
  local n = GetNumQuestLeaderBoards() or 0
  local j = 1
  while j <= n do
    local text, _, done = GetQuestLogLeaderBoard(j)
    local have, need
    if text then
      -- string.find returns start, stop, THEN the captures.
      local _, _, a, b = string.find(text, "(%d+)%s*/%s*(%d+)")
      have, need = tonumber(a), tonumber(b)
    end
    out[j] = {
      text = text or "", done = done and true or false,
      have = have, need = need,
    }
    j = j + 1
  end
  return out, n
end

-- Join a data objective to its live leaderboard line. Label substring first,
-- with string.find's PLAIN flag so a label containing "-" or "(" cannot blow
-- up as a Lua pattern. Positional fallback second: vanilla lists objectives
-- in the same order the database stores them, so index N usually is index N,
-- and a wrong count is better than no line at all here (the count is cosmetic
-- — the coordinates come from the data file either way).
function F.questMatchBoard(boards, nb, label, idx)
  if label then
    local want = string.lower(label)
    local j = 1
    while j <= nb do
      if string.find(string.lower(boards[j].text), want, 1, true) then
        return boards[j]
      end
      j = j + 1
    end
  end
  if idx and idx <= nb then return boards[idx] end
  return nil
end

-- Strict total order: table.sort in 5.0 is unstable and raises "invalid order
-- function" on a sloppy comparator (the same lesson the bag sort learned).
function F.questCandCmp(a, b)
  if a.dist ~= b.dist then return a.dist < b.dist end
  if a.qNum ~= b.qNum then return a.qNum < b.qNum end
  return a.idx < b.idx
end

function F.questListCmp(a, b)
  if a.tracked ~= b.tracked then return a.tracked end
  if a.minDist ~= b.minDist then return a.minDist < b.minDist end
  return a.num < b.num
end

function F.questObjCmp(a, b)
  if a.dist ~= b.dist then return a.dist < b.dist end
  return (a.label or "") < (b.label or "")
end

function F.questHex(r, g, b)
  local R = math.floor((r or 1) * 255 + 0.5)
  local G = math.floor((g or 1) * 255 + 0.5)
  local B = math.floor((b or 1) * 255 + 0.5)
  if R < 0 then R = 0 elseif R > 255 then R = 255 end
  if G < 0 then G = 0 elseif G > 255 then G = 255 end
  if B < 0 then B = 0 elseif B > 255 then B = 255 end
  return string.format("FF%02X%02X%02X", R, G, B)
end

function F.questShort(title, maxLen)
  maxLen = maxLen or 22
  if not title or title == "" then return "?" end
  if string.len(title) <= maxLen then return title end
  return string.sub(title, 1, maxLen - 1) .. "+"
end

-- Ensure a quest meta row exists; colors/numbers are stable for the scan.
function F.questMeta(byTitle, order, title, tracked)
  local m = byTitle[title]
  if m then
    if tracked then m.tracked = true end
    return m
  end
  local n = table.getn(order) + 1
  local col = QUEST_COLORS[((n - 1) - math.floor((n - 1) / QUEST_N_COLORS) * QUEST_N_COLORS) + 1]
  m = {
    num = n, title = title, tracked = tracked and true or false,
    r = col[1], g = col[2], b = col[3],
    minDist = 1e9, objs = {},
  }
  byTitle[title] = m
  order[n] = title
  return m
end

function F.questNoteObj(meta, label, have, need, turnIn, dist, dx, dy)
  local key = turnIn and ("<<:" .. (label or "?")) or (label or "?")
  local o = meta.objs[key]
  if not o then
    o = {
      label = label or "?", have = have, need = need,
      turnIn = turnIn and true or false,
      dist = dist, dx = dx, dy = dy, key = key,
    }
    meta.objs[key] = o
  elseif dist < o.dist then
    o.dist, o.dx, o.dy = dist, dx, dy
    o.have, o.need = have, need
  else
    if have then o.have = have end
    if need then o.need = need end
  end
  if dist < meta.minDist then meta.minDist = dist end
end

-- Prefer at least one pin per quest, then fill by distance.
function F.questPickSpots(cand, nc, maxN)
  local out, nOut = {}, 0
  local used = {}
  local seenQ = {}
  local k = 1
  while k <= nc and nOut < maxN do
    local c = cand[k]
    if c and not seenQ[c.qNum] then
      nOut = nOut + 1
      out[nOut] = c
      used[k] = true
      seenQ[c.qNum] = true
    end
    k = k + 1
  end
  k = 1
  while k <= nc and nOut < maxN do
    if not used[k] then
      nOut = nOut + 1
      out[nOut] = cand[k]
    end
    k = k + 1
  end
  return out
end

function F.questBuildList(byTitle, order)
  local tmp, nt = {}, 0
  local i = 1
  local nOrder = table.getn(order)
  while i <= nOrder do
    local m = byTitle[order[i]]
    if m then
      local objs, no = {}, 0
      local key, o = next(m.objs, nil)
      while key do
        no = no + 1
        objs[no] = o
        key, o = next(m.objs, key)
      end
      if no > 1 then table.sort(objs, F.questObjCmp) end
      if no > QUEST_MAX_OBJ_LINES then
        local cut = {}
        local j = 1
        while j <= QUEST_MAX_OBJ_LINES do
          cut[j] = objs[j]
          j = j + 1
        end
        objs, no = cut, QUEST_MAX_OBJ_LINES
      end
      if no > 0 then
        nt = nt + 1
        tmp[nt] = {
          num = m.num, title = m.title, tracked = m.tracked,
          r = m.r, g = m.g, b = m.b, minDist = m.minDist, objs = objs,
        }
      end
    end
    i = i + 1
  end
  if nt > 1 then table.sort(tmp, F.questListCmp) end
  if nt > QUEST_MAX_LIST then
    local cut = {}
    i = 1
    while i <= QUEST_MAX_LIST do
      cut[i] = tmp[i]
      i = i + 1
    end
    tmp, nt = cut, QUEST_MAX_LIST
  end
  -- Re-number 1..N in display order so checklist and map share the same ids.
  i = 1
  while i <= nt do
    tmp[i].num = i
    i = i + 1
  end
  return tmp
end

-- After list renumber, stamp qNum/color from display list onto every spot.
function F.questStampSpots(spots, list)
  local byTitle = {}
  local i = 1
  local nList = table.getn(list)
  while i <= nList do
    local e = list[i]
    byTitle[e.title] = e
    i = i + 1
  end
  i = 1
  local nSpots = table.getn(spots)
  while i <= nSpots do
    local s = spots[i]
    local e = byTitle[s.title]
    if e then
      s.qNum, s.r, s.g, s.b = e.num, e.r, e.g, e.b
    end
    i = i + 1
  end
end

-- Kept as a named historical implementation while r33 transitions the
-- scanner below to the live-log-first quest model.
function F.questScanMappedOnlyLegacy()
  local data = F.questData()
  local zone = GetRealZoneText() or ""
  quest.zoneName = zone
  if not data then
    quest.spots = {}
    quest.target = nil
    quest.list = {}
    quest.status = "quests: no data file"
    return
  end
  if not quest.posOK then
    quest.spots = {}
    quest.target = nil
    quest.list = {}
    quest.status = "quests: map is off-zone"
    return
  end
  -- Quest log open: keep the previous scan rather than reach into the
  -- selection under the human's cursor. Blips stay honest anyway because
  -- they are drawn against the live player position every tick.
  if QuestLogFrame and QuestLogFrame:IsVisible() then return end

  local sel = 0
  if GetQuestLogSelection then sel = GetQuestLogSelection() or 0 end

  -- Watched (tracked) quests win the "go" target when present.
  local watched = {}
  local nw = GetNumQuestWatches and GetNumQuestWatches() or 0
  local wi = 1
  while wi <= nw do
    local qi = GetQuestIndexForWatch(wi)
    if qi then watched[qi] = true end
    wi = wi + 1
  end

  local cand, nc = {}, 0
  local byTitle, order = {}, {}
  local sig = ""
  local header = ""
  local nEntries = GetNumQuestLogEntries()
  local i = 1
  while i <= nEntries and nc < QUEST_MAX_CAND do
    -- 1.12: title, level, questTag, isHeader, isCollapsed, isComplete.
    -- Headers carry the ZONE NAME as their title — that is rule (1)'s input.
    local title, _, _, isHeader, _, isComplete = GetQuestLogTitle(i)
    if isHeader then
      header = title or ""
    elseif title then
      local q = data[title]
      if q then
        local headerMatch = (header == zone)
        if headerMatch then F.questLearn(q.zone, zone) end
        local isTracked = watched[i] and true or false
        sig = sig .. title .. (isComplete and "!" or "-")
        if isComplete then
          -- Objectives are done: the only useful waypoint is the turn-in NPC.
          local w = q.turnIn
          if w and w.x and w.y and F.questSpotHere(q, w.zone, headerMatch, zone) then
            local meta = F.questMeta(byTitle, order, title, isTracked)
            local dx = w.x - quest.px
            local dy = w.y - quest.py
            local dist = F.questYards(dx, dy)
            nc = nc + 1
            cand[nc] = {
              title = title, label = w.label or title,
              x = w.x, y = w.y, dx = dx, dy = dy, dist = dist,
              turnIn = true, tracked = isTracked, idx = nc,
              qNum = meta.num, r = meta.r, g = meta.g, b = meta.b,
            }
            F.questNoteObj(meta, w.label or title, nil, nil, true, dist, dx, dy)
          end
        elseif q.objectives then
          local boards, nb = F.questBoards(i)
          local nObj = table.getn(q.objectives)
          local oi = 1
          local meta = nil
          while oi <= nObj and nc < QUEST_MAX_CAND do
            local obj = q.objectives[oi]
            local b = F.questMatchBoard(boards, nb, obj.label, oi)
            local have = (b and b.have) or 0
            local need = (b and b.need) or obj.count or 0
            local done = b and (b.done or (need > 0 and have >= need))
            if not done and obj.spots then
              if not meta then
                meta = F.questMeta(byTitle, order, title, isTracked)
              end
              sig = sig .. ":" .. have
              local nSpots = table.getn(obj.spots)
              local si = 1
              local bestDist, bestDx, bestDy = nil, 0, 0
              while si <= nSpots and nc < QUEST_MAX_CAND do
                local s = obj.spots[si]
                if s.x and s.y and F.questSpotHere(q, s.zone, headerMatch, zone) then
                  local dx = s.x - quest.px
                  local dy = s.y - quest.py
                  local dist = F.questYards(dx, dy)
                  nc = nc + 1
                  cand[nc] = {
                    title = title, label = obj.label or title,
                    have = have, need = need,
                    x = s.x, y = s.y, dx = dx, dy = dy, dist = dist,
                    turnIn = false, tracked = isTracked, idx = nc,
                    qNum = meta.num, r = meta.r, g = meta.g, b = meta.b,
                  }
                  if (not bestDist) or dist < bestDist then
                    bestDist, bestDx, bestDy = dist, dx, dy
                  end
                end
                si = si + 1
              end
              if bestDist then
                F.questNoteObj(meta, obj.label or title, have, need, false,
                  bestDist, bestDx, bestDy)
              end
            end
            oi = oi + 1
          end
        end
      end
    end
    i = i + 1
  end
  -- Put the human's selection back before anything can redraw the log.
  if sel > 0 then SelectQuestLogEntry(sel) end

  table.sort(cand, F.questCandCmp)

  local list = F.questBuildList(byTitle, order)
  F.questStampSpots(cand, list)

  -- Drop pins for quests that did not make the checklist (color ids would collide).
  local allow = {}
  local li = 1
  local nList = table.getn(list)
  while li <= nList do
    allow[list[li].title] = true
    li = li + 1
  end
  local kept, nk = {}, 0
  local k = 1
  while k <= nc do
    if allow[cand[k].title] then
      nk = nk + 1
      kept[nk] = cand[k]
    end
    k = k + 1
  end

  -- One nearest pin per quest first, then fill by distance.
  quest.spots = F.questPickSpots(kept, nk, QUEST_MAX_MARKERS)
  local pick = nil
  k = 1
  while k <= nk do
    if kept[k].tracked then
      pick = kept[k]
      break
    end
    k = k + 1
  end
  if not pick then pick = kept[1] end
  quest.target = pick
  quest.list = list
  if nk == 0 then
    quest.status = "quests: nothing mapped here"
  else
    quest.status = nil
  end

  if sig ~= quest.logSig then
    quest.logSig = sig
    F.dtrace("quest " .. nk .. " waypoint(s) / " .. nList
      .. " quest(s) in " .. zone)
  end
end

-- Expand hidden quest-log sections before reading them. Vanilla omits the
-- quests under a collapsed header from GetNumQuestLogEntries(), so failing to
-- do this makes accepted quests disappear based on a Blizzard UI preference.
function F.questExpandHeaders()
  local collapsed = {}
  if not ExpandQuestHeader then return collapsed end
  local i = 1
  while i <= (GetNumQuestLogEntries() or 0) do
    local title, _, _, isHeader, isCollapsed = GetQuestLogTitle(i)
    if isHeader and isCollapsed then
      title = title or ""
      collapsed[title] = (collapsed[title] or 0) + 1
      ExpandQuestHeader(i)
    end
    i = i + 1
  end
  return collapsed
end

function F.questRestoreLog(collapsed, selectedTitle, selectedIndex)
  if CollapseQuestHeader then
    local i = GetNumQuestLogEntries() or 0
    while i >= 1 do
      local title, _, _, isHeader = GetQuestLogTitle(i)
      if isHeader and collapsed[title or ""] and collapsed[title or ""] > 0 then
        collapsed[title or ""] = collapsed[title or ""] - 1
        CollapseQuestHeader(i)
      end
      i = i - 1
    end
  end
  if selectedTitle and selectedTitle ~= "" then
    local i = 1
    while i <= (GetNumQuestLogEntries() or 0) do
      local title, _, _, isHeader = GetQuestLogTitle(i)
      if not isHeader and title == selectedTitle then
        SelectQuestLogEntry(i)
        return
      end
      i = i + 1
    end
  end
  if selectedIndex and selectedIndex > 0
      and selectedIndex <= (GetNumQuestLogEntries() or 0) then
    SelectQuestLogEntry(selectedIndex)
  end
end

function F.questReadLiveLog()
  local model = ShadowArmy and ShadowArmy.questModel
  if not model then error("quest model unavailable") end
  return model.readLog({
    selection = function()
      return GetQuestLogSelection and GetQuestLogSelection() or 0
    end,
    numEntries = function() return GetNumQuestLogEntries() or 0 end,
    title = function(i) return GetQuestLogTitle(i) end,
    expand = ExpandQuestHeader and function(i) ExpandQuestHeader(i) end or nil,
    collapse = CollapseQuestHeader and function(i) CollapseQuestHeader(i) end or nil,
    select = function(i) SelectQuestLogEntry(i) end,
    boards = function(i) return F.questBoards(i) end,
    watched = function()
      local watched = {}
      local nw = GetNumQuestWatches and GetNumQuestWatches() or 0
      local wi = 1
      while wi <= nw do
        local index = GetQuestIndexForWatch(wi)
        if index then watched[index] = true end
        wi = wi + 1
      end
      return watched
    end,
  })
end

-- Race/class of the seat, as mask bits for the variant filter (ticket 0045).
-- Cached on the quest table: identity cannot change inside a session, and
-- questScan runs on the driver. Cached as `false` when the tokens are
-- unrecognized so a miss is not re-probed every tick.
function F.questIdentity()
  if quest.identity == nil then
    local model = ShadowArmy and ShadowArmy.questModel
    local race = UnitRace and UnitRace("player") or nil
    local _, classToken = UnitClass("player")
    quest.identity = (model and model.identity(race, classToken)) or false
  end
  if quest.identity == false then return nil end
  return quest.identity
end

-- r33 scanner: accepted quests and their live objectives always make the
-- checklist. Optional QuestData only contributes trusted, current-zone
-- waypoints to that model.
function F.questScan()
  local zone = GetRealZoneText() or ""
  quest.zoneName = zone

  -- Do not move the human's quest selection while the quest log is on screen.
  -- The previous complete scan remains visible until the window closes.
  if QuestLogFrame and QuestLogFrame:IsVisible() then return end

  local live, sig = F.questReadLiveLog()
  local model = ShadowArmy and ShadowArmy.questModel
  if not model then
    quest.spots, quest.target, quest.list, quest.away = {}, nil, {}, {}
    quest.status = "quests: model unavailable"
    return
  end

  local pos = nil
  if quest.posOK then pos = { x = quest.px, y = quest.py } end
  local built = model.build({
    quests = live,
    data = F.questData() or {},
    zoneNames = ShadowArmyQuestZones,
    currentZone = zone,
    pos = pos,
    yardsX = QUEST_ZONE_YARDS_X,
    yardsY = QUEST_ZONE_YARDS_Y,
    identity = F.questIdentity(),
  })

  local cand = {}
  local nc = table.getn(built.candidates)
  if nc > QUEST_MAX_CAND then nc = QUEST_MAX_CAND end
  local i = 1
  while i <= nc do
    cand[i] = built.candidates[i]
    i = i + 1
  end

  quest.list = built.list
  quest.spots = F.questPickSpots(cand, nc, QUEST_MAX_MARKERS)
  -- r54: top-of-checklist first, nearest routable quest as the fallback, and
  -- a pending delivery only when nothing else is offered. See pickTarget.
  quest.target = model.pickTarget(built.list, cand, nc)
  quest.away = model.awayRows(built.list, zone)
  quest.status = table.getn(quest.list) == 0 and "quests: none accepted" or nil

  if sig ~= quest.logSig then
    quest.logSig = sig
    F.dtrace("quest " .. nc .. " waypoint(s) / "
      .. table.getn(quest.list) .. " accepted quest(s) in " .. zone)
  end
end

--------------------------------------------------------------------------
-- Drawing. Textures are created once and parked (1.12 frames and their
-- regions cannot be destroyed), and SetTexture is called with COLOR numbers
-- rather than an art path — a solid dot cannot 404 on a private-server build
-- the way a guessed Interface\\ path can. Color = quest identity (r33).
--------------------------------------------------------------------------

local questBlips = {}
function F.questBlip(i)
  local t = questBlips[i]
  if t then return t end
  t = Minimap:CreateTexture(nil, "OVERLAY")
  t:SetWidth(8)
  t:SetHeight(8)
  t:Hide()
  questBlips[i] = t
  return t
end

function F.questDrawBlips()
  if not Minimap then return end
  local radius = QUEST_MINIMAP_RADIUS[Minimap:GetZoom() or 0] or 200.0
  local halfW = Minimap:GetWidth() / 2
  local halfH = Minimap:GetHeight() / 2
  local rim = halfW - 4
  local show = quest.markersEnabled and quest.posOK
  local i = 1
  while i <= QUEST_MAX_BLIPS do
    local s = quest.spots[i]
    local t = F.questBlip(i)
    if show and s then
      -- North-up: screen "up" is NEGATIVE map y, hence the sign flip.
      local ox = (s.x - quest.px) / 100 * QUEST_ZONE_YARDS_X / radius * halfW
      local oy = -((s.y - quest.py) / 100 * QUEST_ZONE_YARDS_Y) / radius * halfH
      local m = math.sqrt(ox * ox + oy * oy)
      if m > rim and m > 0 then
        -- Out of minimap range: pin to the rim. A dot on the edge still says
        -- "that way", which beats hiding it.
        ox, oy = ox / m * rim, oy / m * rim
      end
      t:ClearAllPoints() -- SetPoint ACCUMULATES anchors in 1.12
      t:SetPoint("CENTER", Minimap, "CENTER", ox, oy)
      local go = quest.target and s.x == quest.target.x and s.y == quest.target.y
        and s.title == quest.target.title
      local sz = go and 11 or (s.turnIn and 9 or 8)
      t:SetWidth(sz)
      t:SetHeight(sz)
      local a = s.turnIn and 1.0 or 0.92
      -- r54: a delivery pin for a quest whose objectives are still open is
      -- "where this ends", not "go here" — dimmer than anything actionable.
      if s.pending then a = 0.55 end
      t:SetTexture(s.r or 1, s.g or 0.82, s.b or 0, a)
      t:Show()
    else
      t:Hide()
    end
    i = i + 1
  end
end

local questMarkers = {}
function F.questMarker(i)
  local t = questMarkers[i]
  if t then return t end
  t = WorldMapDetailFrame:CreateTexture(nil, "OVERLAY")
  t:SetWidth(10)
  t:SetHeight(10)
  t:Hide()
  -- Number badge: same quest id as the checklist row.
  local fs = WorldMapDetailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  fs:SetText("")
  fs:Hide()
  t.label = fs
  questMarkers[i] = t
  return t
end

-- The map is only ever marked when it is showing the PLAYER'S OWN zone, and
-- the oracle for that is quest.posOK: GetPlayerMapPosition reads 0,0 the
-- moment the map is pointed anywhere else. No zone id lookup, no dropdown
-- index math, and it cannot be fooled into decorating the wrong continent.
function F.questDrawMarkers()
  if not WorldMapDetailFrame then return end
  local show = quest.markersEnabled and quest.posOK
    and WorldMapFrame and WorldMapFrame:IsVisible()
  local w = WorldMapDetailFrame:GetWidth()
  local h = WorldMapDetailFrame:GetHeight()
  local i = 1
  while i <= QUEST_MAX_MARKERS do
    local s = quest.spots[i]
    local t = F.questMarker(i)
    local fs = t.label
    if show and s then
      local px = s.x / 100 * w
      local py = -(s.y / 100 * h)
      t:ClearAllPoints()
      t:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT", px, py)
      local go = quest.target and s.x == quest.target.x and s.y == quest.target.y
        and s.title == quest.target.title
      local sz = go and 14 or (s.turnIn and 12 or 10)
      t:SetWidth(sz)
      t:SetHeight(sz)
      -- r54: same rule as the minimap blips — an unfinished quest's delivery
      -- pin is context, so it reads below its own objectives.
      t:SetTexture(s.r or 1, s.g or 0.82, s.b or 0, s.pending and 0.6 or 0.95)
      t:Show()
      if fs then
        fs:ClearAllPoints()
        fs:SetPoint("BOTTOMLEFT", WorldMapDetailFrame, "TOPLEFT", px + 4, py + 2)
        fs:SetText(tostring(s.qNum or "?"))
        fs:SetTextColor(s.r or 1, s.g or 1, s.b or 1)
        fs:Show()
      end
    else
      t:Hide()
      if fs then fs:Hide() end
    end
    i = i + 1
  end
end

--------------------------------------------------------------------------
-- AWAY LIST (r54): the quests THIS zone cannot pin. QuestData knows the
-- ending zone of a cross-zone quest ("Delivery to Silverpine Forest" ends at
-- Apothecary Renferrel in Silverpine, id 130) but it has no coordinate that
-- means anything on the map currently under the cursor — so no pin gets
-- invented. What gets said instead is the one true fact we hold: the zone.
--
-- Same guards as the pins: quest.posOK is the oracle for "the map is showing
-- the player's own zone", so this list can never annotate a zone the human is
-- merely browsing, and the markers toggle turns it off with everything else.
--
-- Scoped in do..end for the Lua 5.0 200-local budget, like ROUTE and ROAD.
--------------------------------------------------------------------------
do
  local AWAY_MAX_LINES = 6 -- QuestModel.awayMax; the pool is created once

  local awayLines = {}
  function F.questAwayLine(i)
    local fs = awayLines[i]
    if fs then return fs end
    fs = WorldMapDetailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetJustifyH("LEFT")
    fs:SetText("")
    fs:Hide()
    awayLines[i] = fs
    return fs
  end

  function F.questDrawAway()
    if not WorldMapDetailFrame then return end
    local show = quest.markersEnabled and quest.posOK
      and WorldMapFrame and WorldMapFrame:IsVisible()
    local rows = show and quest.away or nil
    local n = rows and table.getn(rows) or 0
    if n > AWAY_MAX_LINES then n = AWAY_MAX_LINES end
    local i = 1
    while i <= AWAY_MAX_LINES do
      local fs = F.questAwayLine(i)
      local row = i <= n and rows[i] or nil
      if row then
        local what = row.turnIn and ". deliver in " or ". objectives in "
        local text = tostring(row.num) .. what .. (row.zoneName or "?")
        if row.turnIn and row.label then
          text = text .. " |cFF999999(" .. row.label .. ")|r"
        end
        fs:ClearAllPoints() -- SetPoint ACCUMULATES anchors in 1.12
        -- Bottom-left of the map art, stacked upward so row 1 reads first.
        fs:SetPoint("BOTTOMLEFT", WorldMapDetailFrame, "BOTTOMLEFT",
          14, 14 + (n - i) * 13)
        fs:SetText(text)
        fs:SetTextColor(row.r or 1, row.g or 0.82, row.b or 0)
        fs:Show()
      else
        fs:Hide()
      end
      i = i + 1
    end
  end
end

--------------------------------------------------------------------------
-- ROUTE (r45): a road-following path from the player to the TOP quest's
-- nearest waypoint, drawn as a trail of small dots on the world map and used
-- as the "go" bearing on the panel. RouteModel does all the thinking; this
-- half only feeds it, caches the answer, and paints it.
--
-- Every read of the generated data is guarded, so a missing or unparsable
-- RoadData.lua costs exactly the route: quest.target still points straight at
-- the objective and the checklist reads exactly as it did in r44.
--
-- Zone ids come from ShadowArmyQuestZones (name -> id, reversed once). That
-- is the same bridge the quest waypoints already need, so a route can only
-- exist where the enrichment that produced quest.target exists anyway.
--------------------------------------------------------------------------

-- Scoped for the same Lua 5.0 200-local budget as RouteModel above; the F.*
-- entry points stay global to the addon, only the state does not.
do
  local ROUTE_MAX_DOTS = 40      -- world map dots (created once, reused forever)
  local ROUTE_TARGET_MOVE = 1.0  -- % target drift before the route is recomputed
  local ROUTE_PLAYER_MOVE = 2.0  -- % player drift before the route is recomputed
  local ROUTE_LEAD = 1.0         -- % lookahead for the "go" bearing
  -- Straight-guide look (r52). Same dot pool, deliberately weaker ink: the gap
  -- is wide enough to read as dashes, the swatch is pulled halfway to grey, and
  -- the dots are a pixel smaller than a road trail's. Road = follow this;
  -- straight = there is nothing to follow, walk it. Still a step ABOVE the r48
  -- road layer's field (3 px, 0.40) — guidance must outrank scenery.
  local ROUTE_STRAIGHT_GAP = 2.0  -- % of map between straight-guide dots
  local ROUTE_STRAIGHT_SIZE = 4   -- px; the road trail is 5
  local ROUTE_STRAIGHT_MIX = 0.45 -- 0 = quest colour, 1 = flat grey
  local ROUTE_STRAIGHT_A = 0.42   -- alpha; the road trail is 0.55

  local route = {
    zone = nil,        -- AreaTable id the cached graph was built for
    zoneName = nil,    -- GetRealZoneText the cached ROUTE was computed in
    graph = nil,
    zoneIds = nil,     -- zone NAME -> AreaTable id, reversed from QuestZones
    points = {},       -- RouteModel waypoints, percent
    n = 0,
    straight = true,   -- true = no road involved; dotted guide, bear as before
    reason = nil,      -- RouteModel meta.reason, verbatim, for the panel line
    noData = false,    -- no RoadData / no graph for this zone at all
    have = false,      -- a route has been computed for tx,ty from px,py
    tx = 0, ty = 0,
    px = 0, py = 0,
    r = 1, g = 0.82, b = 0,
  }

  function F.routeZoneId(zoneName)
    if not zoneName or zoneName == "" then return nil end
    if not route.zoneIds then
      if not ShadowArmyQuestZones then return nil end
      local ids = {}
      -- Lowest id wins a duplicate name so the reversal is order-independent
      -- (pairs() has no defined order).
      for id, name in pairs(ShadowArmyQuestZones) do
        if ids[name] == nil or id < ids[name] then ids[name] = id end
      end
      route.zoneIds = ids
    end
    return route.zoneIds[zoneName]
  end

  -- Built once per zone; a zone change is the only invalidation. Tirisfal is 94
  -- nodes / 0.3 ms on host Lua, and the worst zone in the file is under 1 ms.
  function F.routeGraph()
    local model = ShadowArmy and ShadowArmy.routeModel
    if not model or not ShadowArmyRoadData then return nil end
    local id = F.routeZoneId(quest.zoneName)
    if not id then return nil end
    if route.zone ~= id then
      route.zone = id
      route.graph = nil
      local segs = ShadowArmyRoadData[id]
      if segs then
        local ok, graph = pcall(model.build, segs)
        if ok then route.graph = graph end
      end
    end
    return route.graph
  end

  function F.routeClear()
    route.points, route.n, route.straight, route.have = {}, 0, true, false
    route.reason, route.noData = nil, false
  end

  function F.routeDrift(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
  end

  function F.routeUpdate()
    local t = quest.target
    if not (quest.posOK and t and t.x and t.y) then
      F.routeClear()
      return
    end
    local model = ShadowArmy and ShadowArmy.routeModel
    if not model then
      F.routeClear()
      return
    end
    route.r, route.g, route.b = t.r or 1, t.g or 0.82, t.b or 0
    -- Percent coordinates are per-zone, so a zone change makes every cached
    -- number mean something else. Crossing a border always moves the player
    -- far enough to invalidate on its own, but not by construction — say so.
    if route.zoneName ~= quest.zoneName then
      route.zoneName = quest.zoneName
      route.have = false
    end
    -- Recompute only on a real change: a fresh Dijkstra every half second for a
    -- target that has not moved is pure heat.
    if route.have
        and F.routeDrift(route.tx, route.ty, t.x, t.y) <= ROUTE_TARGET_MOVE
        and F.routeDrift(route.px, route.py, quest.px, quest.py) <= ROUTE_PLAYER_MOVE then
      return
    end
    -- Held in a local so the panel can say "no data" (nothing to route ON)
    -- instead of blaming the router for a bail it never got to make.
    local graph = F.routeGraph()
    local ok, pts, meta = pcall(model.route, graph,
      { x = quest.px, y = quest.py }, { x = t.x, y = t.y })
    if not ok or not pts then
      F.routeClear()
      return
    end
    route.points = pts
    route.n = table.getn(pts)
    route.straight = true
    if meta and not meta.straight then route.straight = false end
    route.reason = meta and meta.reason or nil
    route.noData = (graph == nil)
    route.have = true
    route.tx, route.ty = t.x, t.y
    route.px, route.py = quest.px, quest.py
  end

  -- Percent delta from the player to the next route waypoint, or nil when there
  -- is no road route to follow (caller then uses the straight-line delta).
  function F.routeNextDelta()
    if route.straight or route.n < 2 or not quest.posOK then return nil end
    local model = ShadowArmy and ShadowArmy.routeModel
    if not model then return nil end
    local wx, wy = model.nextPoint(route.points, quest.px, quest.py, ROUTE_LEAD)
    if not wx then return nil end
    return wx - quest.px, wy - quest.py
  end

  -- r52 (ticket 0059 fallout): monofuel reported "zero path guidance" in
  -- Tirisfal. The router was working — it bailed with "straight-cheaper" — but
  -- a silent bail is indistinguishable from a dead addon. So the panel always
  -- says which of the three answers it gave. nil only when there is no route
  -- at all (no target / no model), where the caller prints nothing.
  -- Short display labels (r53): the raw router reasons overhang the panel's
  -- ~35-char line budget — "straight-cheaper" is 38 with the indent (r52
  -- review LOW-1). Unmapped reasons fall through verbatim.
  local ROUTE_REASON_SHORT = {
    ["straight-cheaper"] = "road slower",
    ["disconnected"] = "no road link",
    ["short-hop"] = "too close",
    ["no-roads"] = "no roads",
    ["no-path"] = "no path",
    ["budget"] = "too far",
  }

  -- r54: the verdict also names WHICH quest the line serves. With the target
  -- now falling back past cross-zone quests, "the route is drawn" and "the
  -- route is drawn for the quest you think" are two different questions, and
  -- the checklist number answers the second one in three characters.
  function F.routeVerdict()
    if not route.have then return nil end
    local who = ""
    if quest.target and quest.target.qNum then
      who = " #" .. quest.target.qNum
    end
    if route.noData then return "route" .. who .. ": no data" end
    if not route.straight then return "route" .. who .. ": road" end
    local reason = route.reason or "?"
    return "route" .. who .. ": straight ("
      .. (ROUTE_REASON_SHORT[reason] or reason) .. ")"
  end

  local routeDots = {}
  function F.routeDot(i)
    local t = routeDots[i]
    if t then return t end
    -- ARTWORK, not OVERLAY: the trail passes UNDER the objective pins.
    -- MUST stay lazily created: 1.12 ignores SetDrawLayer's sublevel, so
    -- within ARTWORK only creation order puts this trail ABOVE the road
    -- layer's eagerly-built pool. Prebuild this at load and the trail sinks.
    t = WorldMapDetailFrame:CreateTexture(nil, "ARTWORK")
    t:SetWidth(5)
    t:SetHeight(5)
    t:Hide()
    routeDots[i] = t
    return t
  end

  -- Where the dots go this frame, in percent. Reused across calls so a repaint
  -- allocates nothing: this runs on every WORLD_MAP_UPDATE while the map is
  -- open, and 40 fresh tables a frame is exactly the garbage 1.12 hates.
  local drawX, drawY = {}, {}

  -- Same guards as F.questDrawMarkers: quest.posOK is the oracle for "the map is
  -- showing the player's own zone", so the trail can never decorate a zone the
  -- human is merely browsing.
  --
  -- r52: BOTH answers get drawn. A road route samples its waypoints; a
  -- straight/bailed route gets an evenly dotted line from the player to the
  -- target. Drawing nothing on a bail was the whole "zero path guidance"
  -- report — and with the Brill corridor still missing from RoadData (ticket
  -- 0059) bails are the common case in Tirisfal, not the exception.
  function F.routeDrawMarkers()
    if not WorldMapDetailFrame then return end
    local show = quest.markersEnabled and quest.posOK and route.n >= 2
      and WorldMapFrame and WorldMapFrame:IsVisible()
    local w = WorldMapDetailFrame:GetWidth()
    local h = WorldMapDetailFrame:GetHeight()
    local straight = route.straight
    local np = 0

    if show and not straight then
      -- A long route outruns the dot pool, so sample it evenly and always keep
      -- the last point: the trail must end at the pin it is pointing at.
      local step = 1
      if route.n > ROUTE_MAX_DOTS then
        step = math.ceil((route.n - 1) / (ROUTE_MAX_DOTS - 1))
      end
      local idx = 1
      while idx < route.n and np < ROUTE_MAX_DOTS - 1 do
        local p = route.points[idx]
        np = np + 1
        drawX[np], drawY[np] = p.x, p.y
        idx = idx + step
      end
      local last = route.points[route.n]
      np = np + 1
      drawX[np], drawY[np] = last.x, last.y
    elseif show then
      -- The bailed route IS the two-point straight line, so its own endpoints
      -- are the player and the target — no second read of quest.target needed,
      -- and they are the same (possibly one tick stale) numbers the road trail
      -- would have used.
      local a, b = route.points[1], route.points[route.n]
      if a and b and a.x and a.y and b.x and b.y then
        local dx, dy = b.x - a.x, b.y - a.y
        local want = math.floor(math.sqrt(dx * dx + dy * dy) / ROUTE_STRAIGHT_GAP) + 1
        if want < 2 then want = 2 end
        if want > ROUTE_MAX_DOTS then want = ROUTE_MAX_DOTS end
        while np < want do
          local f = np / (want - 1)
          np = np + 1
          drawX[np], drawY[np] = a.x + dx * f, a.y + dy * f
        end
      end
    end

    -- Quest colour, but smaller and dimmer than an objective pin: the trail is
    -- context, the pins are the answer. The straight guide steps down again on
    -- all three axes so the two kinds never read alike at a glance.
    local size, alpha = 5, 0.55
    local cr, cg, cb = route.r, route.g, route.b
    if straight then
      size, alpha = ROUTE_STRAIGHT_SIZE, ROUTE_STRAIGHT_A
      local keep = 1 - ROUTE_STRAIGHT_MIX
      cr = cr * keep + 0.5 * ROUTE_STRAIGHT_MIX
      cg = cg * keep + 0.5 * ROUTE_STRAIGHT_MIX
      cb = cb * keep + 0.5 * ROUTE_STRAIGHT_MIX
    end

    local i = 1
    while i <= ROUTE_MAX_DOTS do
      local t = F.routeDot(i)
      if i <= np then
        t:ClearAllPoints() -- SetPoint ACCUMULATES anchors in 1.12
        t:SetWidth(size)
        t:SetHeight(size)
        t:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT",
          drawX[i] / 100 * w, -(drawY[i] / 100 * h))
        t:SetTexture(cr, cg, cb, alpha)
        t:Show()
      else
        t:Hide()
      end
      i = i + 1
    end
  end
end

--------------------------------------------------------------------------
-- HUD GUIDANCE ARROW (r56): pathing you can see WITHOUT opening the map.
--
-- Everything above this section paints on the world map. monofuel plays with
-- the map closed, so for two days "pathing is not implemented" was a true
-- statement about his screen while three revisions of routing were shipping.
-- This is the same answer — QuestModel.pickTarget's target, RouteModel's next
-- waypoint — drawn where he is actually looking.
--
-- The arrow is a real rotating arrowhead — stock ROTATING-MINIMAPARROW art,
-- turned with the 8-argument SetTexCoord that build 5875's own TaxiFrame
-- rotates flight-path lines with (see HudModel for the evidence) — riding on
-- a shaft of square pips positioned with SetPoint. The pips are not
-- decoration: SetPoint cannot be silently ignored and a colour texture cannot
-- 404, so even if the art layer ever failed to draw, the direction on screen
-- would still be unmistakable. /sa arrow art proves that half on demand.
--
-- Mouse is OFF by default. An always-visible frame with EnableMouse(true)
-- sitting in the top middle of the screen eats world clicks — it would steal
-- targeting from the human it is trying to help. `/sa arrow move` unlocks it
-- for dragging and locks it again after.
--
-- Scoped in a do-block for the Lua 5.0 200-local budget, like the route and
-- road blocks below and above it.
--------------------------------------------------------------------------

do
  local HUD_W, HUD_H = 190, 164
  local HUD_TOP_Y = -52        -- top-center; keep the widget out of the world
  local HUD_PIP_MAX = 16       -- pool; the presets need 8 (art) and 12 (no art)
  local HUD_NORTH_R = 56       -- the "N" tick's radius, px

  local HUD_ARROW_ART = "Interface\\Minimap\\ROTATING-MINIMAPARROW"

  local hud = {
    on = true,
    mode = "auto",     -- "auto" = use a facing source when one exists
    sign = 1,          -- flippable: see HudModel.aim
    art = true,        -- draw the rotating arrowhead texture
    unlocked = false,  -- mouse enabled for dragging
    src = "none",      -- last facing source (HudModel.facingSource)
    facing = nil,      -- last raw facing value, for /sa arrow status
    reason = nil,      -- why the needle is not drawn; nil = it IS drawn
    probed = false,
  }

  local hudFrame = CreateFrame("Frame", "ShadowArmyHudFrame", UIParent)
  hudFrame:SetWidth(HUD_W)
  hudFrame:SetHeight(HUD_H)
  hudFrame:SetPoint("TOP", UIParent, "TOP", 0, HUD_TOP_Y)
  hudFrame:SetFrameStrata("MEDIUM")
  hudFrame:EnableMouse(false)
  hudFrame:SetMovable(true)
  hudFrame:RegisterForDrag("LeftButton")
  hudFrame:SetScript("OnDragStart", function() hudFrame:StartMoving() end)
  hudFrame:SetScript("OnDragStop", function() hudFrame:StopMovingOrSizing() end)
  hudFrame:Hide()

  -- The needle's origin. Sits above centre so the three text rows below it
  -- clear the tip even when the arrow points straight down.
  local HUD_CX, HUD_CY = 0, 14

  local hudPips = {}
  local function hudPip(i)
    local t = hudPips[i]
    if t then return t end
    t = hudFrame:CreateTexture(nil, "OVERLAY")
    t:Hide()
    hudPips[i] = t
    return t
  end

  -- The rotating arrowhead. ARTWORK so the pips (OVERLAY) stay readable over
  -- it if the two ever overlap.
  local hudArrow = hudFrame:CreateTexture(nil, "ARTWORK")
  hudArrow:SetTexture(HUD_ARROW_ART)
  hudArrow:Hide()

  local hudNorth = hudFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hudNorth:SetText("|cFF8888AAN|r")
  hudNorth:Hide()

  local hudQuestText = hudFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hudQuestText:SetPoint("BOTTOM", hudFrame, "BOTTOM", 0, 34)
  hudQuestText:SetWidth(HUD_W - 12)
  hudQuestText:SetJustifyH("CENTER")

  local hudDistText = hudFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hudDistText:SetPoint("BOTTOM", hudFrame, "BOTTOM", 0, 18)
  hudDistText:SetWidth(HUD_W - 12)
  hudDistText:SetJustifyH("CENTER")

  local hudNoteText = hudFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hudNoteText:SetPoint("BOTTOM", hudFrame, "BOTTOM", 0, 4)
  hudNoteText:SetWidth(HUD_W - 12)
  hudNoteText:SetJustifyH("CENTER")

  -- Scratch texture for the capability probe below: never shown, never a pip,
  -- so a client that DOES honour 8-arg SetTexCoord cannot leave a real pip
  -- wearing a test quad.
  local hudProbeTex = hudFrame:CreateTexture(nil, "BACKGROUND")
  hudProbeTex:Hide()

  -- Locked = click-through. The backdrop only exists while unlocked, because
  -- "where do I grab it" is a question you only ask while moving it.
  function F.hudLock(unlocked)
    hud.unlocked = unlocked and true or false
    hudFrame:EnableMouse(hud.unlocked)
    if hud.unlocked then
      hudFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
      })
      hudFrame:SetBackdropColor(0.05, 0.02, 0.10, 0.75)
    else
      hudFrame:SetBackdrop(nil)
    end
  end

  function F.hudReset()
    hudFrame:ClearAllPoints()
    hudFrame:SetPoint("TOP", UIParent, "TOP", 0, HUD_TOP_Y)
  end

  -- Why the needle is not on screen right now, or nil while it is. The panel
  -- prints this: an arrow that vanishes without a word is the exact failure
  -- that cost two days.
  function F.hudReason()
    return hud.reason
  end

  -- One line to Chat.log the first time the arrow runs, recording what this
  -- client actually offers. The offline read of build 5875 says: no facing
  -- API, no compass ring, 8-arg SetTexCoord supported. This line is the same
  -- claim made by the RUNNING client, which is the only kind that belongs in
  -- docs/vanilla-addons/client-quirks.md.
  function F.hudProbe()
    if hud.probed then return end
    hud.probed = true
    local tc = "rejected"
    local ok = pcall(hudProbeTex.SetTexCoord, hudProbeTex,
      0, 0, 0, 1, 1, 0, 1, 1)
    if ok then tc = "accepted" end
    pcall(hudProbeTex.SetTexCoord, hudProbeTex, 0, 1, 0, 1)
    F.emit("hud", "arrow src=" .. tostring(hud.src)
      .. " getPlayerFacing=" .. (GetPlayerFacing and "yes" or "no")
      .. " setRotation=" .. (hudProbeTex.SetRotation and "yes" or "no")
      .. " texcoord8=" .. tc)
  end

  -- Radians clockwise from north, or nil for a north-up arrow. Reads the
  -- environment every call (so /sa arrow status is never stale) even in north
  -- mode, where it returns nil regardless.
  --
  -- On stock 5875 this always lands on "none": GetPlayerFacing is not in the
  -- binary, the Minimap widget has no facing method, and there is no stock
  -- Model the client turns with the player. The rungs cost two nil checks and
  -- mean a core that adds a facing API flips the arrow to player-relative
  -- with no code change at all.
  function F.hudFacing()
    local model = ShadowArmy and ShadowArmy.hudModel
    local api, raw = nil, nil
    if GetPlayerFacing then
      local ok, v = pcall(GetPlayerFacing)
      if ok and type(v) == "number" then api, raw = true, v end
    end
    hud.src = model and model.facingSource({ api = api }) or "none"
    hud.facing = raw
    if hud.mode == "north" then return nil end
    if hud.src == "none" then return nil end
    return raw
  end

  local function hudBlank(reason)
    hud.reason = reason
    local i = 1
    while i <= HUD_PIP_MAX do
      if hudPips[i] then hudPips[i]:Hide() end
      i = i + 1
    end
    hudArrow:Hide()
    hudNorth:Hide()
    hudQuestText:SetText("")
    hudDistText:SetText("")
    hudNoteText:SetText("")
    hudFrame:Hide()
  end

  -- Places the "N" tick, so player-relative rotation is visible rather than
  -- merely claimed: in player mode this letter walks around the needle as you
  -- turn, and in north-up mode it sits still at the top.
  local function hudPlaceNorth(facing)
    local nx, ny = 0, 1
    if facing then
      -- World north (0,1) put through the same rotation aim() applies, so
      -- the letter and the needle can never disagree.
      local f = facing * hud.sign
      local c, s = math.cos(f), math.sin(f)
      nx, ny = -s, c
    end
    hudNorth:ClearAllPoints()
    hudNorth:SetPoint("CENTER", hudFrame, "CENTER",
      HUD_CX + nx * HUD_NORTH_R, HUD_CY + ny * HUD_NORTH_R)
    hudNorth:Show()
  end

  function F.hudRefresh()
    if not hud.on then
      hud.reason = "off — /sa arrow to bring it back"
      hudFrame:Hide()
      return
    end
    local model = ShadowArmy and ShadowArmy.hudModel
    if not model then
      hudBlank("hud model unavailable")
      return
    end
    -- The arrow samples position on ITS clock (4 Hz) rather than inheriting
    -- the quest scan's 2 Hz: this is the one readout a running human watches
    -- continuously, and F.questPosition is a map-position read with its own
    -- throttled SetMapToCurrentZone repair inside it.
    F.questPosition()
    local facing = F.hudFacing()
    F.hudProbe()
    if not quest.posOK then
      hudBlank("no position — world map showing another zone?")
      return
    end
    local t = quest.target
    if not t then
      local a = quest.away and quest.away[1]
      if a and a.zoneName then
        hudBlank("#" .. tostring(a.num) .. " is in " .. a.zoneName)
      else
        hudBlank(quest.status or "no quest waypoint in this zone")
      end
      return
    end
    -- Distance is the honest crow-flies number to the OBJECTIVE; the needle
    -- may be steering at the next road waypoint instead. Same split the "go"
    -- row on the panel has used since r52, and "via road" is what explains it.
    local tdx, tdy = t.x - quest.px, t.y - quest.py
    local dx, dy = tdx, tdy
    local viaRoad = false
    local rdx, rdy = F.routeNextDelta()
    if rdx then dx, dy, viaRoad = rdx, rdy, true end
    local ux, uy = model.aim(dx, dy, QUEST_ZONE_YARDS_X, QUEST_ZONE_YARDS_Y,
      facing, hud.sign)
    if not ux then
      hudBlank("standing on the objective")
      return
    end
    hud.reason = nil
    hudFrame:Show()
    local cfg = hud.art and model.needle or model.needleNoArt
    local pips, np = model.needlePips(ux, uy, cfg)
    local r, g, b = t.r or 1, t.g or 0.82, t.b or 0
    local i = 1
    while i <= HUD_PIP_MAX do
      local p = (i <= np) and pips[i] or nil
      local tex = hudPip(i)
      if p then
        tex:SetWidth(p.size)
        tex:SetHeight(p.size)
        tex:ClearAllPoints() -- SetPoint ACCUMULATES anchors in 1.12
        tex:SetPoint("CENTER", hudFrame, "CENTER", HUD_CX + p.x, HUD_CY + p.y)
        if p.head then
          -- Head pulled halfway to white so the point of the arrow reads as
          -- the point of the arrow at a glance, in any quest colour.
          tex:SetTexture(r + (1 - r) * 0.5, g + (1 - g) * 0.5,
            b + (1 - b) * 0.5, 1.0)
        else
          tex:SetTexture(r, g, b, 0.9)
        end
        tex:Show()
      else
        tex:Hide()
      end
      i = i + 1
    end
    if hud.art and cfg.glyph then
      hudArrow:SetWidth(cfg.glyphSize)
      hudArrow:SetHeight(cfg.glyphSize)
      hudArrow:ClearAllPoints()
      hudArrow:SetPoint("CENTER", hudFrame, "CENTER",
        HUD_CX + ux * cfg.glyph, HUD_CY + uy * cfg.glyph)
      hudArrow:SetVertexColor(r, g, b, 1.0)
      -- The one call this whole section was researched for.
      pcall(hudArrow.SetTexCoord, hudArrow, model.texCoords(ux, uy))
      hudArrow:Show()
    else
      hudArrow:Hide()
    end
    hudPlaceNorth(facing)

    local hex = F.questHex(r, g, b)
    local mark = t.turnIn and (QUEST_MARK_TURNIN .. " ") or ""
    hudQuestText:SetText(string.format("|c%s%s%d. %s|r", hex, mark,
      t.qNum or 0, F.questShort(t.title or "?", 24)))

    local yards = math.floor(F.questYards(tdx, tdy) + 0.5)
    -- Bearing describes the way the NEEDLE points (world-north relative even
    -- in player mode), which is what makes "SSW" and the arrow agree.
    local bear = model.bearing(dx, dy, QUEST_ZONE_YARDS_X, QUEST_ZONE_YARDS_Y)
      or "--"
    local road = viaRoad and "  |cFF66DD66via road|r" or ""
    hudDistText:SetText(string.format("|cFFFFFFFF%dy|r  |cFFAAAAAA%s|r%s",
      yards, bear, road))

    -- North-up is not a caveat to bury: the human has to know the arrow is a
    -- COMPASS (up = north) and not a windshield (up = where you are running),
    -- or he will trust it while facing south and walk the wrong way.
    local note = "north up"
    -- ASCII only in the HUD strings: this text is on screen every second of
    -- play, and a font that cannot draw a glyph draws a box forever.
    if facing then note = (model.relative(ux, uy) or "?") .. " - you-up" end
    hudNoteText:SetText("|cFF777777" .. note .. "|r")
  end

  -- /sa arrow …  — every knob the arrow has, because the first live minute
  -- decides whether the mode and the art are right, and a reload to change
  -- either of them is a minute of running the wrong way.
  function F.hudCommand(rest)
    if rest == "status" then
      F.say("arrow " .. (hud.on and "ON" or "OFF")
        .. " mode=" .. hud.mode .. " src=" .. tostring(hud.src)
        .. " sign=" .. hud.sign
        .. " art=" .. (hud.art and "on" or "off")
        .. " facing=" .. tostring(hud.facing))
      F.say("  " .. (hud.reason and ("hidden: " .. hud.reason) or "pointing"))
    elseif rest == "art" then
      hud.art = not hud.art
      F.say("arrow head: " .. (hud.art and "rotating texture"
        or "pips only (no art)"))
    elseif rest == "north" then
      hud.mode = "north"
      F.say("arrow: north-up (up = north, always)")
    elseif rest == "auto" then
      hud.mode = "auto"
      F.say("arrow: auto (player-relative whenever a facing source exists)")
    elseif rest == "flip" then
      hud.sign = -hud.sign
      F.say("arrow facing sign = " .. hud.sign)
    elseif rest == "move" then
      F.hudLock(not hud.unlocked)
      F.say("arrow " .. (hud.unlocked and "UNLOCKED — drag it, /sa arrow move to lock"
        or "locked (click-through again)"))
    elseif rest == "reset" then
      F.hudReset()
      F.say("arrow position reset")
    else
      hud.on = not hud.on
      if not hud.on then hudFrame:Hide() else F.hudReset() end
      F.say("arrow " .. (hud.on and "ON" or "OFF")
        .. " — /sa arrow status | move | art | north | auto | flip | reset")
    end
  end
end

--------------------------------------------------------------------------
-- ROAD LAYER (r48): the WHOLE baked road network of the zone the map is
-- showing, as a faint dot field under the route trail and the quest pins.
-- The route draws one path; this is the coverage view — the in-game twin of
-- the map-browser's road layer — so a human can point at the map and say
-- "that road isn't in the data".
--
-- Guards are the existing ones: quest.posOK is the oracle for "the map is
-- showing the player's OWN zone" (GetPlayerMapPosition reads 0,0 the moment
-- the map points anywhere else), so zone A's roads can never land on zone B's
-- map. Nothing happens while the map is closed, and a missing
-- ShadowArmyRoadData (pre-restart) costs exactly the dots — the toggle and
-- everything else still work.
--
-- Bridge segments are plain 2-point polylines in the data and render as a
-- sparse dot pair. That is the point: visible is criticizable.
--------------------------------------------------------------------------

-- Scoped like the route block above for the Lua 5.0 200-local budget.
do
  local ROAD_MAX_DOTS = 180 -- texture pool, created once, reused forever
  local ROAD_DOT = 3        -- px; deliberately smaller than a route dot (5)

  local road = {
    on = true,        -- session toggle; ON by default (coverage is the point)
    zone = nil,       -- AreaTable id the current sample was thinned for
    pts = {}, n = 0,  -- sampled points, percent
    anchored = false, -- dots currently positioned for zone/size below
    pw = 0, ph = 0,   -- detail-frame size those anchors were computed against
    live = 0,         -- dots currently shown
  }

  local roadDots = {}
  function F.roadDot(i)
    local t = roadDots[i]
    if t then return t end
    -- ARTWORK sublevel -1: under the route trail (ARTWORK 0) and well under
    -- the objective pins (OVERLAY). Old clients that ignore the sublevel
    -- argument still get the right order from the eager pool below, because
    -- within one layer 1.12 draws in creation order.
    t = WorldMapDetailFrame:CreateTexture(nil, "ARTWORK")
    if t.SetDrawLayer then pcall(t.SetDrawLayer, t, "ARTWORK", -1) end
    t:SetWidth(ROAD_DOT)
    t:SetHeight(ROAD_DOT)
    -- Dim neutral gray-tan: road, not quest. Set once — colour never varies.
    t:SetTexture(0.70, 0.64, 0.52, 0.40)
    t:Hide()
    roadDots[i] = t
    return t
  end

  -- Independent of the quest-marker toggle on purpose: "is the road data
  -- there" is a question you ask with the pins switched off too.
  function F.roadDrawLayer()
    if not WorldMapDetailFrame then return end
    local show = road.on and quest.posOK
      and WorldMapFrame and WorldMapFrame:IsVisible()
    if not show then
      if road.live > 0 then
        local i = 1
        while i <= ROAD_MAX_DOTS do
          F.roadDot(i):Hide()
          i = i + 1
        end
        road.live, road.anchored = 0, false
      end
      return
    end
    local id = F.routeZoneId(quest.zoneName)
    if id ~= road.zone then
      -- A zone change is the only invalidation: percent coordinates are
      -- per-zone, so every cached number means something else after it.
      road.zone, road.anchored = id, false
      road.pts, road.n = {}, 0
      local model = ShadowArmy and ShadowArmy.routeModel
      local segs = nil
      if id and ShadowArmyRoadData then segs = ShadowArmyRoadData[id] end
      if segs and model and model.sample then
        local ok, pts, np = pcall(model.sample, segs, ROAD_MAX_DOTS)
        if ok and pts then road.pts, road.n = pts, np or 0 end
      end
    end
    local w = WorldMapDetailFrame:GetWidth()
    local h = WorldMapDetailFrame:GetHeight()
    -- Anchors only move when the zone or the map surface changes, so
    -- repainting an already-painted zone costs three comparisons.
    if road.anchored and road.pw == w and road.ph == h then return end
    local i = 1
    while i <= ROAD_MAX_DOTS do
      local t = F.roadDot(i)
      local p = nil
      if i <= road.n then p = road.pts[i] end
      if p then
        t:ClearAllPoints() -- SetPoint ACCUMULATES anchors in 1.12
        t:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT",
          p.x / 100 * w, -(p.y / 100 * h))
        t:Show()
      else
        t:Hide()
      end
      i = i + 1
    end
    road.pw, road.ph, road.live, road.anchored = w, h, road.n, true
  end

  -- Toggle: a small button in the bottom-left corner of the map surface (the
  -- 1.12 map keeps its dropdowns up top and the zoom-out button bottom-right).
  -- Parented to the detail frame so it draws above the map tiles and hides
  -- with the map; session-only state, exactly like the marker button.
  local roadBtn = nil
  if WorldMapDetailFrame or WorldMapFrame then
    roadBtn = CreateFrame("Button", "ShadowArmyRoadBtn",
      WorldMapDetailFrame or WorldMapFrame, "UIPanelButtonTemplate")
    roadBtn:SetWidth(64)
    roadBtn:SetHeight(20)
    roadBtn:SetPoint("BOTTOMLEFT", roadBtn:GetParent(), "BOTTOMLEFT", 6, 6)
    roadBtn:SetScript("OnClick", function()
      F.roadToggle()
    end)
  end

  function F.roadSetLayer(on)
    road.on = on and true or false
    if roadBtn then
      roadBtn:SetText(road.on and "|cFF44FF44Roads|r" or "|cFF999999Roads|r")
    end
    pcall(F.roadDrawLayer) -- hide/show immediately, no waiting for the tick
  end

  function F.roadToggle()
    F.roadSetLayer(not road.on)
    F.say("road layer " .. (road.on and "ON" or "OFF")
      .. " — " .. road.n .. " dots of the zone's baked network")
  end

  F.roadSetLayer(true)

  -- Built once, at load. Within one draw layer 1.12 renders in CREATION
  -- order, so making the whole pool before the first route dot exists is what
  -- actually guarantees the trail stays on top of the network.
  if WorldMapDetailFrame then
    local i = 1
    while i <= ROAD_MAX_DOTS do
      F.roadDot(i)
      i = i + 1
    end
  end
end

-- Paint the multi-line quest checklist into questLines[]. Corpse compass
-- overrides the whole block while ghosting.
function F.questClearLines()
  local i = 1
  while i <= QUEST_PANEL_LINES do
    if questLines[i] then questLines[i]:SetText("") end
    i = i + 1
  end
end

function F.questPaintLines(rows)
  F.questClearLines()
  if not rows then return end
  local i = 1
  local n = table.getn(rows)
  while i <= n and i <= QUEST_PANEL_LINES do
    questLines[i]:SetText(rows[i] or "")
    i = i + 1
  end
end

-- r56: the on-screen arrow's silence always has a reason, and the panel says
-- it out loud. "Nothing is showing" cost two days once; it does not get to be
-- a silent state again. nil reason = the arrow is up and pointing, and this
-- row does not exist.
function F.questArrowRow(rows, nr)
  local why = F.hudReason and F.hudReason()
  if not why then return nr end
  if nr >= QUEST_PANEL_LINES then return nr end
  nr = nr + 1
  rows[nr] = "|cFF777777arrow: " .. F.questShort(why, 30) .. "|r"
  return nr
end

function F.questChecklistRows()
  local rows, nr = {}, 0
  if quest.status then
    rows[1] = "|cFF777777" .. quest.status .. "|r"
    F.questArrowRow(rows, 1)
    return rows
  end
  local list = quest.list
  local nList = table.getn(list)
  if nList == 0 then
    rows[1] = "|cFF777777quests: none accepted|r"
    F.questArrowRow(rows, 1)
    return rows
  end
  local goTitle = quest.target and quest.target.title
  local goLabel = quest.target and quest.target.label
  local goTurn = quest.target and quest.target.turnIn
  local qi = 1
  while qi <= nList and nr < QUEST_PANEL_LINES do
    local e = list[qi]
    local hex = F.questHex(e.r, e.g, e.b)
    nr = nr + 1
    local failed = e.failed and " [failed]" or ""
    rows[nr] = string.format("|c%s%d. %s%s|r", hex, e.num,
      F.questShort(e.title, e.failed and 13 or 22), failed)
    local oi = 1
    local nObj = table.getn(e.objs)
    while oi <= nObj and nr < QUEST_PANEL_LINES do
      local o = e.objs[oi]
      local isGo = (e.title == goTitle)
        and ((goTurn and o.turnIn) or ((not goTurn) and (not o.turnIn)
          and o.label == goLabel))
      -- The "go" row steers along the ROAD when one exists: the distance is
      -- still the honest crow-flies estimate to the objective, but the compass
      -- points at the next route waypoint, so following it keeps you on the
      -- freeway instead of walking into the woods between here and there.
      local dir = nil
      if o.dist then
        local rdx, rdy = nil, nil
        if isGo then rdx, rdy = F.routeNextDelta() end
        if rdx then
          dir = F.questBearing(rdx, rdy)
        else
          dir = F.questBearing(o.dx, o.dy)
        end
      end
      local yards = o.dist and math.floor(o.dist + 0.5) or nil
      local prog = ""
      if (not o.turnIn) and o.need and o.need > 0 then
        prog = string.format(" %d/%d", o.have or 0, o.need)
      end
      local lab = F.questShort(o.label, 16)
      if o.delivery and o.pending and not isGo then
        -- r54: the map pin already says where this quest ends up, and the
        -- objectives above it are what you actually do next. The 210px panel
        -- keeps its 8 lines for those; the checklist WINDOW still lists the
        -- delivery row for every quest.
      elseif o.turnIn and yards then
        -- mark is >>/<< only for the active "go" row; otherwise a space.
        local prefix = isGo and QUEST_MARK_TURNIN or ("  " .. QUEST_MARK_TURNIN)
        nr = nr + 1
        rows[nr] = string.format(
          "|c%s  %s %s|r |cFFAAAAAA~%dy %s|r",
          hex, prefix, lab, yards, dir)
      elseif yards then
        nr = nr + 1
        rows[nr] = string.format(
          "|c%s  %s%s%s|r |cFFAAAAAA~%dy %s|r",
          hex, isGo and (QUEST_MARK_GO .. " ") or "  ", lab, prog, yards, dir)
      elseif o.turnIn then
        -- r54: no distance on a turn-in row means the ender is in ANOTHER
        -- zone (or is unmapped). The zone name is the only honest answer and
        -- it is also the useful one — "in Silverpine Forest" beats an NPC
        -- name you cannot walk to from here.
        local dest = o.zoneName
        nr = nr + 1
        if dest and dest ~= quest.zoneName then
          rows[nr] = string.format("|c%s  %s %s|r", hex, QUEST_MARK_TURNIN,
            F.questShort("in " .. dest, 20))
        else
          rows[nr] = string.format("|c%s  %s %s|r", hex,
            QUEST_MARK_TURNIN, F.questShort(o.label or "Ready to turn in", 18))
        end
      else
        local mark = o.done and "[x] " or ""
        nr = nr + 1
        rows[nr] = string.format("|c%s  %s%s|r", hex, mark,
          F.questShort(o.text or o.label, 20))
      end
      -- r52: the "go" row's compass is either steering along a road or flying
      -- the crow line, and only the router knows which. One dim sub-line says
      -- so, right under the bearing it explains — "route: straight" is a real
      -- answer, and reading it beats guessing the addon died.
      if isGo and nr < QUEST_PANEL_LINES then
        local verdict = F.routeVerdict()
        if verdict then
          nr = nr + 1
          -- 4 spaces, not the hint line's 6: the longest verdict
          -- ("straight (straight-cheaper)") already runs a panel width.
          rows[nr] = "|cFF777777    " .. verdict .. "|r"
        end
      end
      -- r47 (ticket 0047): "Notched Rib 0/5" with no mention of Cracked Skull
      -- Soldier was a live complaint — monofuel reads objectives HERE, not in
      -- the checklist window, and the hunt hint only rendered there. The
      -- objective row is already ~35 characters wide with its distance and
      -- bearing, so the hint gets its own dim sub-line inside the SAME
      -- QUEST_PANEL_LINES budget (row heights are unchanged; a full panel
      -- simply shows fewer objectives, exactly as it already did).
      if o.from and not o.done and not o.turnIn and nr < QUEST_PANEL_LINES then
        local hint = QuestModel.fromText(o.from, 2, QUEST_HINT_CHARS, "")
        if hint then
          nr = nr + 1
          rows[nr] = "|cFF777777      from " .. hint .. "|r"
        end
      end
      oi = oi + 1
    end
    qi = qi + 1
  end
  nr = F.questArrowRow(rows, nr)
  return rows
end

function F.questRefreshPanel()
  local corpseLine = F.corpseLineText and F.corpseLineText() or nil
  if corpseLine then
    F.questPaintLines({ corpseLine })
    return
  end
  F.questPaintLines(F.questChecklistRows())
end

-- Complete scrollable quest checklist. The compact advisor panel remains an
-- at-a-glance summary; this window is the authoritative view of every live
-- quest and objective.
local questFrame = CreateFrame("Frame", "ShadowArmyQuestFrame", UIParent)
questFrame:SetWidth(430)
questFrame:SetHeight(360)
questFrame:SetPoint("CENTER", UIParent, "CENTER", 180, 0)
questFrame:SetFrameStrata("HIGH")
questFrame:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
questFrame:SetBackdropColor(0.05, 0.02, 0.10, 0.92)
questFrame:EnableMouse(true)
questFrame:SetMovable(true)
questFrame:RegisterForDrag("LeftButton")
questFrame:SetScript("OnDragStart", function() questFrame:StartMoving() end)
questFrame:SetScript("OnDragStop", function() questFrame:StopMovingOrSizing() end)
questFrame:Hide()
tinsert(UISpecialFrames, "ShadowArmyQuestFrame")

local questTitle = questFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
questTitle:SetPoint("TOP", questFrame, "TOP", 0, -9)
questTitle:SetText("|cFF9482C9Quest Advisor|r")

local questClose = CreateFrame("Button", nil, questFrame, "UIPanelCloseButton")
questClose:SetPoint("TOPRIGHT", questFrame, "TOPRIGHT", -2, -2)

local questScroll = CreateFrame(
  "ScrollFrame", "ShadowArmyQuestScroll", questFrame, "UIPanelScrollFrameTemplate")
questScroll:SetPoint("TOPLEFT", questFrame, "TOPLEFT", 12, -30)
questScroll:SetPoint("BOTTOMRIGHT", questFrame, "BOTTOMRIGHT", -30, 38)

local questScrollChild = CreateFrame("Frame", "ShadowArmyQuestScrollChild", questScroll)
questScrollChild:SetWidth(376)
questScrollChild:SetHeight(1)
questScroll:SetScrollChild(questScrollChild)

local questWindowLines = {}
function F.questWindowLine(i)
  local line = questWindowLines[i]
  if line then return line end
  line = questScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  line:SetWidth(370)
  line:SetHeight(14)
  line:SetJustifyH("LEFT")
  line:SetPoint("TOPLEFT", questScrollChild, "TOPLEFT", 0, -((i - 1) * 14))
  line:SetText("")
  questWindowLines[i] = line
  return line
end

-- "who do I hunt for this item" hint. Join + truncation live in QuestModel so
-- lua/tests can drive the width math (r47, ticket 0047); the window has room
-- for the wordy " more" tail, the panel below does not.
local QUEST_FROM_MAX = 2
function F.questFromText(from)
  return QuestModel.fromText(from, QUEST_FROM_MAX, nil, " more")
end

function F.questWindowRows()
  local rows = {}
  if quest.status then
    rows[1] = "|cFF777777" .. quest.status .. "|r"
    return rows
  end
  local list = quest.list or {}
  local qi = 1
  while qi <= table.getn(list) do
    local entry = list[qi]
    local hex = F.questHex(entry.r, entry.g, entry.b)
    local tracked = entry.tracked and " [tracked]" or ""
    local failed = entry.failed and " [failed]" or ""
    rows[table.getn(rows) + 1] = string.format(
      "|c%s%d. %s%s%s|r", hex, entry.num, entry.title, tracked, failed)
    local oi = 1
    while oi <= table.getn(entry.objs) do
      local obj = entry.objs[oi]
      local prefix = obj.turnIn and QUEST_MARK_TURNIN or (obj.done and "[x]" or "[ ]")
      local text = obj.text or obj.label or "Objective"
      local suffix = ""
      if obj.dist then
        suffix = string.format("  |cFFAAAAAA~%dy %s|r",
          math.floor(obj.dist + 0.5), F.questBearing(obj.dx, obj.dy))
      elseif obj.zoneName and obj.zoneName ~= quest.zoneName then
        suffix = "  |cFF888888" .. obj.zoneName .. "|r"
      end
      local hunt = ""
      if obj.from and not obj.done then
        local names = F.questFromText(obj.from)
        if names then hunt = " |cFF888888(" .. names .. ")|r" end
      end
      rows[table.getn(rows) + 1] = string.format(
        "|c%s  %s %s|r%s%s", hex, prefix, text, hunt, suffix)
      oi = oi + 1
    end
    if table.getn(entry.objs) == 0 then
      rows[table.getn(rows) + 1] = "|cFF999999  " .. (entry.status or "In progress") .. "|r"
    end
    qi = qi + 1
  end
  return rows
end

function F.questRefreshWindow()
  if not questFrame:IsShown() then return end
  local rows = F.questWindowRows()
  local i = 1
  while i <= table.getn(rows) do
    F.questWindowLine(i):SetText(rows[i])
    i = i + 1
  end
  while i <= table.getn(questWindowLines) do
    questWindowLines[i]:SetText("")
    i = i + 1
  end
  local height = table.getn(rows) * 14
  if height < 1 then height = 1 end
  questScrollChild:SetHeight(height)
  if questScroll.UpdateScrollChildRect then questScroll:UpdateScrollChildRect() end
end

local questMarkersBtn = CreateFrame("Button", nil, questFrame, "UIPanelButtonTemplate")
questMarkersBtn:SetWidth(120)
questMarkersBtn:SetHeight(20)
questMarkersBtn:SetPoint("BOTTOMLEFT", questFrame, "BOTTOMLEFT", 12, 10)

function F.questSetMarkers(on)
  quest.markersEnabled = on and true or false
  questMarkersBtn:SetText(quest.markersEnabled
    and "|cFF44FF44Markers on|r" or "|cFF999999Markers off|r")
  if quest.markersEnabled then
    quest.nextTickAt = 0
  else
    pcall(F.questDrawBlips)
    pcall(F.questDrawMarkers)
    pcall(F.questDrawAway)
    pcall(F.routeDrawMarkers)
  end
end
questMarkersBtn:SetScript("OnClick", function()
  F.questSetMarkers(not quest.markersEnabled)
end)
F.questSetMarkers(true)

function F.questTick()
  local now = GetTime()
  if now < quest.nextTickAt then return end
  quest.nextTickAt = now + QUEST_TICK_EVERY
  F.questPosition()
  F.questScan()
  F.routeUpdate()
  F.questDrawBlips()
  F.questDrawMarkers()
  F.questDrawAway()
  F.routeDrawMarkers()
  F.roadDrawLayer()
  F.questRefreshWindow()
end

questBtn = CreateFrame("Button", "ShadowArmyQuestBtn", panel, "UIPanelButtonTemplate")
questBtn:SetWidth(93) -- 8 + 93 + 8 + 93 + 8 = 210 = panel width
questBtn:SetHeight(20)
questBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 56) -- second row, right of Log
questBtn:SetText("|cFF9482C9Quests|r")
questBtn:SetScript("OnClick", function()
  if questFrame:IsShown() then
    questFrame:Hide()
  else
    questFrame:Show()
    F.questRefreshWindow()
  end
end)

-- WORLD_MAP_UPDATE fires on pan/zoom/zone-switch and can arrive every frame
-- while the map is open, so the repaint is throttled; the 0.5s tick repaints
-- anyway, this just keeps markers from lagging a zone change visibly.
-- ZONE_CHANGED_NEW_AREA forces an immediate rescan because waypoint
-- enrichment compares generated zone names against the player's parent zone.
local questEvents = CreateFrame("Frame", "ShadowArmyQuestEvents", UIParent)
questEvents:RegisterEvent("WORLD_MAP_UPDATE")
questEvents:RegisterEvent("ZONE_CHANGED_NEW_AREA")
questEvents:SetScript("OnEvent", function()
  if event == "ZONE_CHANGED_NEW_AREA" then
    quest.nextTickAt = 0
    return
  end
  local now = GetTime()
  if now < quest.nextMarkerAt then return end
  quest.nextMarkerAt = now + QUEST_MARKER_EVERY
  local ok, err = pcall(F.questDrawMarkers)
  if not ok then F.emit("err", "questMarkers: " .. tostring(err)) end
  local aok, aerr = pcall(F.questDrawAway)
  if not aok then F.emit("err", "questAway: " .. tostring(aerr)) end
  local rok, rerr = pcall(F.routeDrawMarkers)
  if not rok then F.emit("err", "routeMarkers: " .. tostring(rerr)) end
  local dok, derr = pcall(F.roadDrawLayer)
  if not dok then F.emit("err", "roadLayer: " .. tostring(derr)) end
end)

--------------------------------------------------------------------------
-- CREW / CORPSE BLIPS (r21): party members + own corpse on minimap + world
-- map. Independent of quest marker visibility — corpse runs still need a
-- compass when quest markers are toggled off.
--
-- APIs (vanilla 1.12):
--   GetPlayerMapPosition("party1".."party4") — unit map % (0,0 = unknown /
--     other zone / map pointed elsewhere). Same zone gate as quest.posOK.
--   GetCorpseMapPosition() — own corpse map % while a corpse exists; 0,0
--     when none / wrong map surface (same contract as FrameXML proof).
-- Party *corpses* while they ghost elsewhere are NOT exposed by the client;
-- their ghost unit position is, which is what you need to find them mid-run.
--------------------------------------------------------------------------

local CREW_TICK_EVERY = 0.25
local CREW_MAX_PARTY = 4

local crew = {
  enabled = true,
  nextTickAt = 0,
  nextMarkerAt = 0,
  px = 0, py = 0, posOK = false,
  spots = {}, -- { x, y, kind = "party"|"party_ghost"|"corpse", name? }
}

function F.crewPosition()
  -- Reuse quest map-fix so we never paint on a browsed foreign zone.
  if quest.posOK then
    crew.px, crew.py, crew.posOK = quest.px, quest.py, true
    return true
  end
  local x, y = GetPlayerMapPosition("player")
  if (not x) or (x == 0 and y == 0) then
    if not (WorldMapFrame and WorldMapFrame:IsVisible()) then
      pcall(SetMapToCurrentZone)
      x, y = GetPlayerMapPosition("player")
    end
  end
  if (not x) or (x == 0 and y == 0) then
    crew.posOK = false
    return false
  end
  crew.px, crew.py, crew.posOK = x * 100, y * 100, true
  return true
end

function F.crewScan()
  crew.spots = {}
  if not crew.posOK then return end
  local n = 0
  -- Own corpse first so it always wins a slot if we ever cap.
  if type(GetCorpseMapPosition) == "function" then
    local cx, cy = GetCorpseMapPosition()
    if cx and cy and not (cx == 0 and cy == 0) then
      n = n + 1
      crew.spots[n] = {
        x = cx * 100, y = cy * 100, kind = "corpse", name = "corpse",
      }
    end
  end
  local i = 1
  while i <= CREW_MAX_PARTY do
    local unit = "party" .. i
    if UnitExists and UnitExists(unit) then
      local ux, uy = GetPlayerMapPosition(unit)
      if ux and uy and not (ux == 0 and uy == 0) then
        local ghost = false
        if UnitIsGhost and UnitIsGhost(unit) then
          ghost = true
        elseif UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit) then
          ghost = true
        end
        n = n + 1
        crew.spots[n] = {
          x = ux * 100, y = uy * 100,
          kind = ghost and "party_ghost" or "party",
          name = (UnitName and UnitName(unit)) or unit,
        }
      end
    end
    i = i + 1
  end
end

function F.crewPlaceMinimap(t, sx, sy)
  if not Minimap then return false end
  local radius = QUEST_MINIMAP_RADIUS[Minimap:GetZoom() or 0] or 200.0
  local halfW = Minimap:GetWidth() / 2
  local halfH = Minimap:GetHeight() / 2
  local rim = halfW - 4
  local ox = (sx - crew.px) / 100 * QUEST_ZONE_YARDS_X / radius * halfW
  local oy = -((sy - crew.py) / 100 * QUEST_ZONE_YARDS_Y) / radius * halfH
  local m = math.sqrt(ox * ox + oy * oy)
  if m > rim and m > 0 then
    ox, oy = ox / m * rim, oy / m * rim
  end
  t:ClearAllPoints()
  t:SetPoint("CENTER", Minimap, "CENTER", ox, oy)
  return true
end

local crewBlips = {}
function F.crewBlip(i)
  local t = crewBlips[i]
  if t then return t end
  t = Minimap:CreateTexture(nil, "OVERLAY")
  t:SetWidth(8)
  t:SetHeight(8)
  t:Hide()
  crewBlips[i] = t
  return t
end

function F.crewDrawBlips()
  if not Minimap then return end
  local show = crew.enabled and crew.posOK
  local max = CREW_MAX_PARTY + 1 -- party + corpse
  local i = 1
  while i <= max do
    local s = crew.spots[i]
    local t = F.crewBlip(i)
    if show and s and F.crewPlaceMinimap(t, s.x, s.y) then
      if s.kind == "corpse" then
        t:SetWidth(10)
        t:SetHeight(10)
        t:SetTexture(0.85, 0.30, 1.00, 0.95) -- purple: body
      elseif s.kind == "party_ghost" then
        t:SetWidth(8)
        t:SetHeight(8)
        t:SetTexture(0.95, 0.95, 1.00, 0.95) -- white: ghost on corpse run
      else
        t:SetWidth(8)
        t:SetHeight(8)
        t:SetTexture(0.25, 0.85, 1.00, 0.95) -- cyan: living party
      end
      t:Show()
    else
      t:Hide()
    end
    i = i + 1
  end
end

local crewMarkers = {}
function F.crewMarker(i)
  local t = crewMarkers[i]
  if t then return t end
  t = WorldMapDetailFrame:CreateTexture(nil, "OVERLAY")
  t:SetWidth(12)
  t:SetHeight(12)
  t:Hide()
  crewMarkers[i] = t
  return t
end

function F.crewDrawMarkers()
  if not WorldMapDetailFrame then return end
  local show = crew.enabled and crew.posOK
    and WorldMapFrame and WorldMapFrame:IsVisible()
  local w = WorldMapDetailFrame:GetWidth()
  local h = WorldMapDetailFrame:GetHeight()
  local max = CREW_MAX_PARTY + 1
  local i = 1
  while i <= max do
    local s = crew.spots[i]
    local t = F.crewMarker(i)
    if show and s then
      t:ClearAllPoints()
      t:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT",
        s.x / 100 * w, -(s.y / 100 * h))
      if s.kind == "corpse" then
        t:SetTexture(0.85, 0.30, 1.00, 0.95)
      elseif s.kind == "party_ghost" then
        t:SetTexture(0.95, 0.95, 1.00, 0.95)
      else
        t:SetTexture(0.25, 0.85, 1.00, 0.95)
      end
      t:Show()
    else
      t:Hide()
    end
    i = i + 1
  end
end

-- Panel line when ghosting: bearing/yards to own corpse (quest line yields).
function F.corpseLineText()
  if not (UnitIsGhost and UnitIsGhost("player")) then return nil end
  if not crew.posOK then return "|cFFBB88FF corpse: map off-zone|r" end
  local s = nil
  local i = 1
  while crew.spots[i] do
    if crew.spots[i].kind == "corpse" then s = crew.spots[i] break end
    i = i + 1
  end
  if not s then return "|cFFBB88FF corpse: not on this map|r" end
  local dx = s.x - crew.px
  local dy = s.y - crew.py
  local dir = F.questBearing(dx, dy)
  local yards = math.floor(F.questYards(dx, dy) + 0.5)
  return string.format("|cFFD080FF>> CORPSE|r |cFFAAAAAA%s ~%dy %s|r",
    "\194\183", yards, dir)
end

function F.crewTick()
  if not crew.enabled then return end
  local now = GetTime()
  if now < crew.nextTickAt then return end
  crew.nextTickAt = now + CREW_TICK_EVERY
  -- Reuse the current-zone sample maintained by the always-live quest scan.
  if quest.posOK then
    crew.px, crew.py, crew.posOK = quest.px, quest.py, true
  else
    F.crewPosition()
  end
  F.crewScan()
  F.crewDrawBlips()
  F.crewDrawMarkers()
end

local crewEvents = CreateFrame("Frame", "ShadowArmyCrewEvents", UIParent)
crewEvents:RegisterEvent("WORLD_MAP_UPDATE")
crewEvents:RegisterEvent("PARTY_MEMBERS_CHANGED")
crewEvents:RegisterEvent("PLAYER_DEAD")
crewEvents:RegisterEvent("PLAYER_ALIVE")
crewEvents:RegisterEvent("PLAYER_UNGHOST")
crewEvents:SetScript("OnEvent", function()
  if not crew.enabled then return end
  crew.nextTickAt = 0
  if event == "WORLD_MAP_UPDATE" then
    local now = GetTime()
    if now < crew.nextMarkerAt then return end
    crew.nextMarkerAt = now + QUEST_MARKER_EVERY
    local ok, err = pcall(F.crewDrawMarkers)
    if not ok then F.emit("err", "crewMarkers: " .. tostring(err)) end
  end
end)


-- Rotation driver lives on its OWN always-shown frame — NOT the panel.
-- (OnUpdate only fires for visible frames; hiding the panel via /sa must
-- not kill auto-combat.) pcall so a rotation bug reports instead of
-- dying silently when scriptErrors is off.
-- Deferred remote reload: live findings — ReloadUI() and
-- ConsoleExec("reloadui") are both silently no-ops from a CHAT_MSG_SYSTEM
-- handler (r2) and from a deferred OnUpdate frame (r3/r4), while the same
-- call from the /sa slash handler works. Working theory: this client gates
-- programmatic UI reload on hardware-event context (the slash path starts
-- from a keypress). So: try the free paths, then light up the panel's
-- Reload! button — a mouse click IS a hardware event, so its OnClick works.
--
-- r43: auto-loot deleted. r11-r14 measured it end to end — LootSlot is a
-- no-op outside hardware-event context here, so the retry ladder only ever
-- produced `loot gated` / `loot result took=0` noise. Looting is the human's
-- click; do not rebuild this.
--------------------------------------------------------------------------

local pendingReload = 0 -- countdown of escalation steps; 0 = idle
-- r11: every request gets a number so the ladder is traceable end to end, and
-- two reloads within F.emit()'s 30s identical-message window can never collapse
-- into one line.
local reloadSeq = 0

local driver = CreateFrame("Frame", "ShadowArmyDriver", UIParent)
driver:SetScript("OnUpdate", function()
  -- Sample position EVERY frame for combat-coach move tips.
  F.updateMoving()
  F.emitDrain() -- paced outbound chat; see EMIT_GAP
  -- r22: deferred probe runs (Frame / Delay modes) + cast follow-ups.
  local pok, perr = pcall(F.probeTick)
  if not pok then F.emit("err", "probeTick: " .. tostring(perr)) end
  -- r12: Demon Skin/Armor keep-up attempt (cast is click-gated on this client;
  -- legacy path). pcall so a failure cannot kill the rest of OnUpdate.
  local aok, aerr = pcall(F.armorTick)
  if not aok then F.emit("err", "armorTick: " .. tostring(aerr)) end
  -- r43: debounced action-bar sweep of advisor-managed spells.
  local sbok, sberr = pcall(F.barSweepTick)
  if not sbok then F.emit("err", "barSweepTick: " .. tostring(sberr)) end
  -- r13: bag autosort (one swap in flight).
  if sort.active then
    local sok, serr = pcall(F.sortTick)
    if not sok then
      F.emit("err", "sortTick: " .. tostring(serr))
      pcall(F.sortStop, "error")
    end
  end
  -- r47: bag disposition list, 1s debounce, only while the window is open.
  local btok, bterr = pcall(F.bagTagTick)
  if not btok then F.emit("err", "bagTagTick: " .. tostring(bterr)) end
  -- r49: inventory snapshot/delta out to The System (ticket 0052).
  local ivok, iverr = pcall(F.invTick)
  if not ivok then F.emit("err", "invTick: " .. tostring(iverr)) end
  -- r33: the quest checklist is always live; markers have their own toggle.
  local qok, qerr = pcall(F.questTick)
  if not qok then F.emit("err", "questTick: " .. tostring(qerr)) end
  -- r21: party + corpse blips.
  if crew.enabled then
    local cok, cerr = pcall(F.crewTick)
    if not cok then F.emit("err", "crewTick: " .. tostring(cerr)) end
  end
  -- r55: passive upkeep refresh (~4 Hz, ALWAYS — combat included). This is
  -- the section's only driver now; see the note in the panel's OnUpdate.
  -- No IsShown() gate: the model's answer also decides what key 2 casts, so
  -- it must stay current even with the panel toggled off, and the row's
  -- Show/Hide on a hidden panel is free. Uses auto.passiveAcc rather than a
  -- new file-scope local — Lua 5.0 caps a chunk at 200 locals.
  auto.passiveAcc = (auto.passiveAcc or 0) + (arg1 or 0)
  if auto.passiveAcc >= 0.25 then
    auto.passiveAcc = 0
    local ppok, pperr = pcall(F.passiveRefresh)
    if not ppok then F.emit("err", "passiveRefresh: " .. tostring(pperr)) end
    -- r56: the on-screen guidance arrow shares this 4 Hz slot. It is the one
    -- readout a RUNNING human watches continuously, so it gets the fast clock
    -- and its own position sample rather than the quest scan's 2 Hz — and it
    -- is pcall'd here for the same reason the passive row moved: an unguarded
    -- throw upstream must not be able to freeze it mid-turn.
    local hdok, hderr = pcall(F.hudRefresh)
    if not hdok then F.emit("err", "hudRefresh: " .. tostring(hderr)) end
    -- r56: the coach's watchdog and its one-shot state dump share this slot.
    -- Both live on ShadowArmy.* rather than new file-scope locals (Lua 5.0
    -- caps a chunk at 200) — same reason auto.passiveAcc above does.
    local cgok, cgerr = pcall(F.coachGuard)
    if not cgok then F.emit("err", "coachGuard: " .. tostring(cgerr)) end
    if ShadowArmy.coachProbeAt and GetTime() >= ShadowArmy.coachProbeAt then
      ShadowArmy.coachProbeAt = nil
      local cpok, cperr = pcall(F.coachProbe)
      if not cpok then F.emit("err", "coachProbe: " .. tostring(cperr)) end
    end
  end
  -- r35: combat coach panel refresh (~4 Hz when open). Display only.
  if combatFrame:IsShown() then
    combatAcc = combatAcc + (arg1 or 0)
    if combatAcc >= 0.25 then
      combatAcc = 0
      local cok, cerr = pcall(F.combatRefresh)
      if not cok then F.emit("err", "combatRefresh: " .. tostring(cerr)) end
    end
  end
  if pendingReload > 0 then
    pendingReload = pendingReload - 1
    if pendingReload == 2 then
      F.dtrace("reload #" .. reloadSeq .. " step 1/3 ReloadUI()")
      local ok, err = pcall(ReloadUI)
      if not ok then F.emit("err", "ReloadUI: " .. tostring(err)) end
    elseif pendingReload == 1 then
      F.dtrace("reload #" .. reloadSeq .. " step 2/3 ConsoleExec(reloadui)")
      local ok, err = pcall(ConsoleExec, "reloadui")
      if not ok then F.emit("err", "ConsoleExec: " .. tostring(err)) end
    elseif pendingReload == 0 then
      F.emit("reload-click",
        "#" .. reloadSeq .. " auto paths no-op; button lit + next-press armed")
      panel:Show()
      reloadBtn:Show()
      reloadArmed = true
    end
  end
end)

local acc = 0
panel:SetScript("OnUpdate", function()
  acc = acc + arg1
  if acc < 0.5 then return end
  acc = 0
  local xph, tta = F.grindStats()
  line1:SetText(string.format("lvl %d  %d/%d xp",
    UnitLevel("player"), UnitXP("player"), UnitXPMax("player")))
  line2:SetText(string.format("%d xp/h  |  level up in %s", xph, tta))
  local t1, t2 = F.targetSummary()
  line3:SetText(t1)
  line4:SetText(t2)
  -- r55: line5 (buff watch / passive row) is NO LONGER refreshed from here.
  -- It moved to the driver's own 4 Hz slot below F.passiveRefresh, for two
  -- reasons. (1) Cadence: the coach re-reads at 4 Hz and the upkeep section
  -- is the other thing a human reacts to mid-fight, so it gets the same
  -- clock instead of this panel's 2 Hz. (2) Independence: everything above
  -- this comment runs UNPROTECTED, so one throw out of F.grindStats or
  -- F.targetSummary aborted the handler before line5 was ever assigned and
  -- left the section frozen on its last text — the exact failure mode
  -- monofuel described. On the driver it is pcall'd and cannot be starved.
  -- r32: multi-line quest checklist (corpse compass overrides while ghosting).
  local ok, err = pcall(F.questRefreshPanel)
  if not ok then
    line6:SetText("|cFFFF6666quest panel: " .. tostring(err) .. "|r")
  end
end)

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

-- Instant quest text, 1.12 style: there is no CVar for this (that arrived
-- post-vanilla). The quest/gossip text crawl is QuestFrame's type-out
-- effect; the classic fix is hooking the scroll frames' OnShow to call
-- the "text finished" path immediately. QuestFrameDetailPanel shows quest
-- description; QuestFrameProgressPanel the turn-in text.
function F.instantQuestText()
  -- The crawl is driven by the detail panel's OnUpdate revealing text over
  -- time; killing it + forcing alpha shows everything at once. Progress
  -- panel = quest turn-in text.
  if QuestFrameDetailPanel then
    QuestFrameDetailPanel:SetScript("OnUpdate", nil)
    QuestFrameDetailPanel:SetScript("OnShow", function()
      if QuestDetailScrollChildFrame then
        QuestDetailScrollChildFrame:SetAlpha(1)
      end
    end)
  end
  if QuestFrameProgressPanel then
    QuestFrameProgressPanel:SetScript("OnUpdate", nil)
  end
end

local frame = CreateFrame("Frame", "ShadowArmyFrame", UIParent)
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("LEARNED_SPELL_IN_TAB")
-- r43: managed-spell bar sweep triggers (debounced in F.barSweepRequest);
-- PLAYER_REGEN_ENABLED is where a combat-deferred sweep lands.
frame:RegisterEvent("SPELLS_CHANGED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
frame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
frame:RegisterEvent("PLAYER_AURAS_CHANGED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("UI_ERROR_MESSAGE")
-- cast-time spell window (Shadow Bolt): don't stack cast requests
frame:RegisterEvent("SPELLCAST_START")
frame:RegisterEvent("SPELLCAST_STOP")
frame:RegisterEvent("SPELLCAST_FAILED")
frame:RegisterEvent("SPELLCAST_INTERRUPTED")
-- wand auto-repeat state (casting Shoot again would TOGGLE it off)
frame:RegisterEvent("START_AUTOREPEAT_SPELL")
frame:RegisterEvent("STOP_AUTOREPEAT_SPELL")
-- melee swing loop state
frame:RegisterEvent("PLAYER_ENTER_COMBAT")
frame:RegisterEvent("PLAYER_LEAVE_COMBAT")
-- The System inbound: GM announce arrives as CHAT_MSG_SYSTEM
frame:RegisterEvent("CHAT_MSG_SYSTEM")

frame:SetScript("OnEvent", function()
  if event == "PLAYER_ENTERING_WORLD" then
    grind.startTime = GetTime()
    grind.startXP = UnitXP("player")
    F.scanSpellbook()
    F.installSuggestedKeyHook()
    F.bindSuggestedKey()
    F.bindPassiveKey()
    -- QoL defaults the advisor asserts on every login:
    -- F.instantQuestText() DISABLED (r14): prime remaining suspect for the
    -- reproducible crash+lockup on Complete Quest (it nils the quest
    -- panels' OnUpdate — exactly the surface involved in that click). The
    -- fanfare mute didn't take (music still played), so this is the next
    -- single-variable test. Re-enable only after turn-ins are proven safe.
    F.panelShowReset()
    -- r54: the coach opens once per session, on the first entering-world.
    -- Guarded by a flag so a later loading screen (instance, boat, hearth)
    -- cannot re-open a window the human closed on purpose.
    if not ShadowArmy.combatOpened then
      ShadowArmy.combatOpened = true
      F.combatOpen()
    end
    -- r56: report the coach's REAL state ten seconds in, once per login. By
    -- then every load-order effect, every restored frame and the first
    -- CloseAllWindows caller have all had their turn — which is exactly the
    -- window in which three revisions of "it should be open" went wrong.
    ShadowArmy.coachProbeAt = GetTime() + 10
    F.barSweepRequest()
    F.say("ARISE. Advisor online for " .. UnitName("player") .. " — /sa help (rev=" .. REV .. ")")
    F.emit("loaded", "rev=" .. REV)
    if not ShadowArmyQuestData then
      F.say("quest directions unavailable (QuestData.lua failed to load) — live objectives still work")
    end
  elseif event == "LEARNED_SPELL_IN_TAB" then
    F.scanSpellbook()
  elseif event == "SPELLS_CHANGED" then
    -- Respecs fire SPELLS_CHANGED without LEARNED_SPELL_IN_TAB; the sweep's
    -- PickupSpell indices come from auto.spells, so rescan before sweeping.
    F.scanSpellbook()
    F.barSweepRequest()
  elseif event == "PLAYER_REGEN_ENABLED" then
    -- Only re-arms a sweep the combat check already deferred.
    if barSweep.pending then F.barSweepRequest() end
  elseif event == "ACTIONBAR_SLOT_CHANGED" then
    -- r44: a slot edit is the only signal a macro drag leaves, so it arms the
    -- sweep's quiet period (F.barSweepNoteChange ignores our own mutations).
    F.barSweepNoteChange()
    F.scanCombatActions()
  elseif event == "ACTIONBAR_PAGE_CHANGED" then
    F.scanCombatActions()
  elseif event == "PLAYER_AURAS_CHANGED" then
    -- Druid forms page a different action-bar bank. Re-scan so exact range
    -- and usability follow the active form instead of the login bar.
    if auto.classToken == "DRUID" then F.scanCombatActions() end
  elseif event == "PLAYER_TARGET_CHANGED" then
    auto.failure = nil
    auto.lastAttempt = nil
  elseif event == "UI_ERROR_MESSAGE" then
    F.combatRecordFailure(arg1 or "")
  elseif event == "SPELLCAST_START" then
    auto.casting = true
    auto.castingSince = GetTime()
    auto.failure = nil
  elseif event == "SPELLCAST_STOP" then
    auto.casting = false
    F.armorNoteCast(true)
  elseif event == "SPELLCAST_FAILED" or event == "SPELLCAST_INTERRUPTED" then
    auto.casting = false
    -- r47: a failed cast cannot explain a new aura — drop the pending sample.
    F.armorNoteCast(false)
    -- brief backoff so a failing cast (moving/silenced/oom) can't retry
    -- every frame and starve the wand fallback
    auto.failUntil = GetTime() + 0.5
    F.dtrace("cast failed/interrupted — 0.5s backoff")
  elseif event == "START_AUTOREPEAT_SPELL" then
    auto.shooting = true
  elseif event == "STOP_AUTOREPEAT_SPELL" then
    auto.shooting = false
  elseif event == "PLAYER_ENTER_COMBAT" then
    auto.melee = true
  elseif event == "PLAYER_LEAVE_COMBAT" then
    auto.melee = false
  elseif event == "CHAT_MSG_SYSTEM" then
    -- The System speaks via GM `announce`, which arrives as CHAT_MSG_SYSTEM:
    -- "|cffff0000[System Message]: <SYS> reload|r". Strip color codes, look for
    -- the <SYS> marker, dispatch a WHITELISTED verb. Never eval arbitrary code.
    local msg = arg1 or ""
    msg = string.gsub(msg, "|c%x%x%x%x%x%x%x%x", "")
    msg = string.gsub(msg, "|r", "")
    local _, _, cmd = string.find(msg, "<SYS>%s*(.+)$")
    if not cmd then return end
    cmd = string.gsub(cmd, "%s+$", "")
    -- r11: marker matched. Trace it BEFORE the verb parse so a future
    -- "the addon ignored my command" can be told apart from "the announce
    -- never arrived" without guessing.
    F.dtrace("sys rx [" .. cmd .. "]")
    local _, _, verb, rest = string.find(cmd, "^(%S+)%s*(.*)$")
    if not verb then
      F.emit("err", "sys unparsed: [" .. cmd .. "]")
      return
    end
    verb = string.lower(verb)
    if verb == "reload" then
      -- NOTE for whoever reads this in Chat.log: rev= here is the rev that is
      -- CURRENTLY RUNNING — the one being replaced — because the addon cannot
      -- know what is on disk. The rev you pushed only ever appears on the
      -- following `loaded` line. Never grep `reloading rev=<the rev I just
      -- pushed>`; it can never match, and reading its absence as "reload is
      -- broken" is exactly the wrong turn taken on 2026-07-25.
      -- #N makes each request unique so F.emit()'s 30s dedupe can't swallow a
      -- retry, and pairs this line with its reload-click.
      reloadSeq = reloadSeq + 1
      F.emit("reloading", "#" .. reloadSeq .. " from-rev=" .. REV)
      pendingReload = 3 -- escalation ladder runs on the driver; see above
    elseif verb == "ping" then
      F.emit("pong", "rev=" .. REV)
    elseif verb == "debug" then
      debugMode = (rest ~= "off")
      F.emit("debug", debugMode and "on" or "off")
    elseif verb == "status" then
      local xph = F.grindStats()
      F.emit("status", string.format("lvl=%d hp=%d/%d zone=%s xph=%d",
        UnitLevel("player"), UnitHealth("player"), UnitHealthMax("player"),
        GetZoneText(), xph))
    elseif verb == "inv" or verb == "inv?" then
      -- ticket 0052: The System wants a fresh full snapshot right now (a
      -- dashboard tab just opened, or it decided its copy is stale). Both
      -- spellings accepted — the ticket writes `<SYS> inv?` and the verb
      -- parse keeps the "?" attached.
      local iok, ierr = pcall(F.invSendFull)
      if not iok then F.emit("err", "inv: " .. tostring(ierr)) end
    elseif verb == "say" then
      F.say(rest)
    elseif verb == "admin" then
      -- Feedback from The System after an admin action (respawn, etc.).
      -- Not an executable verb — display only so we do not F.emit "unknown".
      F.say("|cFFFF8844[System admin]|r " .. (rest ~= "" and rest or "ok"))
    else
      F.emit("err", "unknown sys command: " .. verb)
    end
  end
end)

--------------------------------------------------------------------------
-- /sa — toggle panel; /sa help — command list; /sa reload, status, …
--------------------------------------------------------------------------

function F.saHelp()
  -- Keep this list next to the slash handler so they cannot drift.
  F.say("ShadowArmy " .. REV .. " — commands:")
  F.say("  /sa            toggle advisor panel")
  F.say("  /sa show       show panel (reset position if off-screen)")
  F.say("  /sa help       this list")
  F.say("  /sa status     level, HP, zone, XP/h")
  F.say("  /sa log        toggle advisor log window")
  F.say("  /sa admin      toggle admin panel (The System ops)")
  F.say("  /sa combat     toggle combat coach (ability suggestions)")
  F.say("  /sa debug      toggle API probe panel (context gates)")
  F.say("  /sa bags       open ShadowBags")
  F.say("  /sa quests     toggle the complete quest window")
  F.say("  /sa crew       toggle party + corpse map blips")
  F.say("  /sa roads      toggle the zone road layer on the world map")
  F.say("  /sa arrow      toggle the on-screen guidance arrow")
  F.say("    arrow move|art|north|auto|flip|reset|status")
  F.say("  /sa reload     ReloadUI() — pick up disk edits")
end

SLASH_SHADOWARMY1 = "/sa"
SlashCmdList["SHADOWARMY"] = function(msg)
  msg = string.gsub(msg or "", "^%s+", "")
  msg = string.gsub(msg, "%s+$", "")
  msg = string.lower(msg)
  if msg == "help" or msg == "?" then
    F.saHelp()
    return
  end
  if msg == "show" then
    F.panelShowReset()
    F.say("panel shown (position reset)")
    return
  end
  if msg == "reload" then
    ReloadUI()
    return
  end
  -- Manual valve for the bag window: if the global takeover ever fails to
  -- take (another addon loading after us and re-replacing ToggleBackpack),
  -- this still opens it.
  if msg == "bags" then
    F.bagsToggle()
    return
  end
  if msg == "quests" then
    if questFrame:IsShown() then questFrame:Hide() else questFrame:Show() end
    F.questRefreshWindow()
    return
  end
  if msg == "crew" then
    crew.enabled = not crew.enabled
    if not crew.enabled then
      crew.spots = {}
      pcall(F.crewDrawBlips)
      pcall(F.crewDrawMarkers)
    else
      crew.nextTickAt = 0
    end
    F.say("crew blips " .. (crew.enabled and "ON" or "OFF")
      .. " (party cyan / ghost white / corpse purple)")
    return
  end
  -- Same valve as the map button, for when the map corner is covered.
  if msg == "roads" then
    F.roadToggle()
    return
  end
  -- r56: "arrow" plus an optional word. Prefix-matched rather than listed
  -- verb by verb so a new knob is one branch in F.hudCommand.
  if msg == "arrow" or string.sub(msg, 1, 6) == "arrow " then
    local rest = string.gsub(string.sub(msg, 7), "^%s+", "")
    F.hudCommand(rest)
    return
  end
  if msg == "log" then
    if logFrame:IsVisible() then logFrame:Hide() else logFrame:Show() end
    return
  end
  if msg == "debug" or msg == "probe" then
    F.probeToggle()
    return
  end
  if msg == "admin" then
    F.adminToggle()
    return
  end
  if msg == "combat" then
    F.combatToggle()
    return
  end
  if msg == "status" then
    local hp = UnitHealth("player")
    local hpMax = UnitHealthMax("player")
    local xph, tta = F.grindStats()
    F.say(string.format("%s — lvl %d, %d/%d hp, %s | %d xp/h, level in %s",
      UnitName("player"), UnitLevel("player"), hp, hpMax, GetZoneText(), xph, tta))
    return
  end
  if msg ~= "" then
    F.say("unknown /sa command — try /sa help")
    return
  end
  -- Toggle: prefer IsShown (local flag) over IsVisible (parent chain).
  if panel:IsShown() then
    panel:Hide()
  else
    F.panelShowReset()
  end
end

-- r54: last statement of the load. Nothing created above can leave the combat
-- coach hidden after this line, and a ReloadUI runs the whole file again — so
-- "the coach is open when the addon comes up" is now a property of the file's
-- final instruction rather than of a frame's default state.
F.combatOpen()
