-- ShadowArmy — advisor v0.1: draggable HUD panel (grind stats + target
-- intel + action buttons) on top of the hello-world plumbing.
-- 1.12 (Lua 5.0) addon: no protected functions, vararg via arg table,
-- event args via global event/arg1/arg2. Keep everything addon-local
-- except the single ShadowArmy root.

ShadowArmy = ShadowArmy or {}

-- Lua 5.0 hard limit: 200 locals per function. Helpers live on F.
local F = {}

-- Bump on every edit. The System watches Chat.log for "<SA> loaded rev=..."
-- after sending a reload — a new rev proves the edit actually loaded.
local REV = "r31"

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
local DROPPABLE = { trace = true }

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

local panel = CreateFrame("Frame", "ShadowArmyPanel", UIParent)
panel:SetWidth(210)
panel:SetHeight(216) -- +24 third button row (Probe)
panel:SetPoint("RIGHT", UIParent, "RIGHT", -40, 60)
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
  panel:SetPoint("RIGHT", UIParent, "RIGHT", -40, 60)
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
local line6 = F.makeLine(line5, -6) -- r18: nearest quest objective

-- (v0.1 had Nearest-foe/Attack buttons; removed — they duplicated Tab and
-- the T auto-attack keybind. Rule: a button earns its place only by doing
-- something the default UI can't. Full-auto combat qualifies.)

--------------------------------------------------------------------------
-- Combat coach (r26): L0 suggestions only — vanilla action APIs are
-- click/software gated, so we do NOT auto-cast. Opens a window of
-- priority abilities for the human to press. Warlock leveling priority
-- (Corruption → Shadow Bolt → wand → melee), spellbook-gated.
-- See docs/advisor-autopilot.md (vanilla = L0 only).
--------------------------------------------------------------------------

local auto = {
  casting = false,
  castingSince = 0,
  gcdUntil = 0,      -- used only by legacy F.armorTick if it still casts
  failUntil = 0,
  shooting = false,  -- wand auto-repeat observed via events
  melee = false,     -- auto-attack swing observed via events
  known = {},        -- lowercase spell name -> true
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

function F.scanSpellbook()
  auto.known = {}
  local i = 1
  while true do
    local name = GetSpellName(i, "spell")
    if not name then break end
    auto.known[string.lower(name)] = true
    i = i + 1
  end
end

-- 1.12 UnitDebuff returns the TEXTURE first; names aren't exposed.
local CORRUPTION_TEX = "Interface\\Icons\\Spell_Shadow_AbominationExplosion"

function F.targetHasDebuff(texture)
  local i = 1
  while true do
    local tex = UnitDebuff("target", i)
    if not tex then return false end
    if tex == texture then return true end
    i = i + 1
  end
end

-- Shared by F.armorTick legacy path (cast still gated on this client).
function F.castNow(spell)
  F.dtrace("cast " .. spell)
  CastSpellByName(spell)
  auto.gcdUntil = GetTime() + 1.6
end

-- Warlock ability buttons (fixed order). Click = hardware event = cast works.
-- No pet button: imp is on Aggressive — it engages without PetAttack.
local COMBAT_ABILITIES = {
  { id = "corruption", label = "Corruption",  kind = "spell", spell = "Corruption", book = "corruption" },
  { id = "shadowbolt", label = "Shadow Bolt", kind = "spell", spell = "Shadow Bolt", book = "shadow bolt" },
  { id = "shoot",      label = "Shoot",       kind = "spell", spell = "Shoot", book = "shoot" },
  { id = "melee",      label = "Melee Attack", kind = "melee" },
}

-- Evaluate each ability: ready (priority pick), usable (click ok), reason text.
-- Returns status line, nextId, and rows[id] = { usable, ready, reason }.
function F.combatAdvice()
  local rows = {}
  local nextId = nil
  local function set(id, usable, ready, reason)
    rows[id] = { usable = usable, ready = ready, reason = reason or "" }
    if ready and not nextId then
      nextId = id
    end
  end

  local status
  if not UnitExists("target") then
    status = "|cFFFFAA00No target|r"
    local i = 1
    while i <= table.getn(COMBAT_ABILITIES) do
      set(COMBAT_ABILITIES[i].id, false, false, "need target")
      i = i + 1
    end
    return status, nil, rows
  end
  if UnitIsDeadOrGhost("target") then
    status = "|cFFFFAA00Target dead|r"
    local i = 1
    while i <= table.getn(COMBAT_ABILITIES) do
      set(COMBAT_ABILITIES[i].id, false, false, "target dead")
      i = i + 1
    end
    return status, nil, rows
  end
  if not UnitCanAttack("player", "target") then
    status = "|cFFFFAA00Friendly target|r"
    local i = 1
    while i <= table.getn(COMBAT_ABILITIES) do
      set(COMBAT_ABILITIES[i].id, false, false, "not hostile")
      i = i + 1
    end
    return status, nil, rows
  end

  local tName = UnitName("target") or "?"
  local manaPct = 0
  if UnitManaMax("player") > 0 then
    manaPct = UnitMana("player") / UnitManaMax("player") * 100
  end
  local in28 = CheckInteractDistance("target", 4) and true or false
  local in10 = CheckInteractDistance("target", 3) and true or false
  local hasWand = GetInventoryItemLink("player", 18) and true or false
  local corrUp = F.targetHasDebuff(CORRUPTION_TEX)
  local casting = auto.casting
  if casting and GetTime() - auto.castingSince > 4 then
    casting = false
  end

  status = string.format(
    "|cFF9482C9%s|r  mana %d%%  %s%s",
    tName, math.floor(manaPct),
    move.moving and "moving  " or "still  ",
    casting and "|cFFFFFF00casting|r" or "")

  -- Corruption
  if not auto.known["corruption"] then
    set("corruption", false, false, "not trained")
  elseif corrUp then
    set("corruption", true, false, "already up")
  elseif not in28 then
    set("corruption", true, false, "out of range")
  elseif manaPct <= 25 then
    set("corruption", true, false, "mana low")
  else
    set("corruption", true, true, "DoT")
  end

  -- Shadow Bolt
  if not auto.known["shadow bolt"] then
    set("shadowbolt", false, false, "not trained")
  elseif move.moving then
    set("shadowbolt", true, false, "stand still")
  elseif casting then
    set("shadowbolt", true, false, "casting")
  elseif not in28 then
    set("shadowbolt", true, false, "out of range")
  elseif manaPct <= 35 then
    set("shadowbolt", true, false, "mana low")
  else
    set("shadowbolt", true, true, "nuke")
  end

  -- Shoot
  if not auto.known["shoot"] then
    set("shoot", false, false, "not trained")
  elseif not hasWand then
    set("shoot", false, false, "no wand")
  elseif auto.shooting then
    set("shoot", true, false, "firing")
  elseif not in28 then
    set("shoot", true, false, "out of range")
  else
    set("shoot", true, true, "wand")
  end

  -- Melee
  if auto.melee then
    set("melee", true, false, "swinging")
  elseif not in10 then
    set("melee", true, false, "not in melee")
  else
    set("melee", true, true, "last resort")
  end

  if not nextId then
    if casting then
      status = status .. "  |cFFFFFF00finish cast|r"
    elseif auto.shooting then
      status = status .. "  |cFFAAAAAAwanding|r"
    end
  end
  return status, nextId, rows
end

-- Fire ability from a button OnClick (hardware event — casts work).
function F.combatUse(id)
  local i = 1
  while i <= table.getn(COMBAT_ABILITIES) do
    local a = COMBAT_ABILITIES[i]
    if a.id == id then
      if a.kind == "melee" then
        if UnitExists("target") and UnitCanAttack("player", "target")
            and not UnitIsDeadOrGhost("target") then
          AttackTarget()
        end
      elseif a.kind == "spell" and a.spell then
        if a.book and not auto.known[a.book] then
          return
        end
        F.castNow(a.spell)
      end
      return
    end
    i = i + 1
  end
end

-- Combat coach UI: clickable ability buttons
local combatFrame = CreateFrame("Frame", "ShadowArmyCombatFrame", UIParent)
combatFrame:SetWidth(260)
combatFrame:SetHeight(174) -- 4 ability buttons (no pet)
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
combatFrame:Hide()
tinsert(UISpecialFrames, "ShadowArmyCombatFrame")

local combatTitle = combatFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
combatTitle:SetPoint("TOP", combatFrame, "TOP", 0, -8)
combatTitle:SetText("|cFF9482C9Combat coach|r")

local combatClose = CreateFrame("Button", nil, combatFrame, "UIPanelCloseButton")
combatClose:SetPoint("TOPRIGHT", combatFrame, "TOPRIGHT", -2, -2)

local combatStatus = combatFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
combatStatus:SetPoint("TOPLEFT", combatFrame, "TOPLEFT", 12, -28)
combatStatus:SetPoint("TOPRIGHT", combatFrame, "TOPRIGHT", -12, -28)
combatStatus:SetJustifyH("LEFT")
combatStatus:SetText("")

local combatBtns = {}
local cbi = 1
while cbi <= table.getn(COMBAT_ABILITIES) do
  local ab = COMBAT_ABILITIES[cbi]
  local b = CreateFrame("Button", "ShadowArmyCombatBtn" .. ab.id, combatFrame, "UIPanelButtonTemplate")
  b:SetWidth(232)
  b:SetHeight(22)
  b:SetPoint("TOP", combatFrame, "TOP", 0, -44 - (cbi - 1) * 26)
  b:SetText(ab.label)
  b.abilityId = ab.id
  b:SetScript("OnClick", function()
    F.combatUse(this.abilityId)
  end)
  combatBtns[ab.id] = b
  cbi = cbi + 1
end

-- Sort key: 0 = recommended next, 1 = usable (ready or not), 2 = grey/unusable.
-- Within a tier, keep the warlock priority order from COMBAT_ABILITIES.
function F.combatSortRank(id, nextId, rows)
  local r = rows and rows[id]
  if not r then return 9 end
  if nextId and id == nextId then return 0 end
  if r.usable then return 1 end
  return 2
end

local combatAcc = 0
function F.combatRefresh()
  if not combatFrame:IsShown() then return end
  local status, nextId, rows = F.combatAdvice()
  combatStatus:SetText(status or "")

  -- Build ordered list of ability indices (stable within tier).
  local order = {}
  local n = table.getn(COMBAT_ABILITIES)
  local i = 1
  while i <= n do
    order[i] = i
    i = i + 1
  end
  -- Insertion sort (Lua 5.0, tiny n).
  local a = 2
  while a <= n do
    local key = order[a]
    local keyId = COMBAT_ABILITIES[key].id
    local keyRank = F.combatSortRank(keyId, nextId, rows)
    local b = a - 1
    while b >= 1 do
      local otherId = COMBAT_ABILITIES[order[b]].id
      local otherRank = F.combatSortRank(otherId, nextId, rows)
      -- Lower rank first; same rank keeps original priority (order[b] < key).
      if otherRank < keyRank or (otherRank == keyRank and order[b] < key) then
        break
      end
      order[b + 1] = order[b]
      b = b - 1
    end
    order[b + 1] = key
    a = a + 1
  end

  i = 1
  while i <= n do
    local ab = COMBAT_ABILITIES[order[i]]
    local btn = combatBtns[ab.id]
    local r = rows and rows[ab.id]
    if btn and r then
      local label = ab.label
      if r.reason and r.reason ~= "" then
        label = ab.label .. "  |cFF888888" .. r.reason .. "|r"
      end
      if nextId == ab.id then
        btn:SetText("|cFF44FF44→ " .. label .. "|r")
      elseif r.usable then
        btn:SetText("|cFFCCCCCC" .. label .. "|r")
      else
        btn:SetText("|cFF666666" .. label .. "|r")
      end
      if r.usable then
        btn:Enable()
      else
        btn:Disable()
      end
      -- Re-stack top → bottom by importance every refresh.
      btn:ClearAllPoints()
      btn:SetPoint("TOP", combatFrame, "TOP", 0, -44 - (i - 1) * 26)
    end
    i = i + 1
  end
end

function F.combatToggle()
  if combatFrame:IsShown() then
    combatFrame:Hide()
  else
    combatFrame:Show()
    F.combatRefresh()
  end
end

combatClose:SetScript("OnClick", function() combatFrame:Hide() end)

local combatBtn = CreateFrame("Button", "ShadowArmyCombatBtn", panel, "UIPanelButtonTemplate")
combatBtn:SetWidth(118)
combatBtn:SetHeight(20)
combatBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 56) -- top button row
combatBtn:SetText("|cFF9482C9Combat|r")
combatBtn:SetScript("OnClick", function()
  F.combatToggle()
end)

-- Remote-reload button: hidden until The System requests a reload. It must
-- be a click because this build ignores programmatic ReloadUI (see the
-- driver notes) — a mouse click is the hardware event that makes it legal.
local reloadBtn = CreateFrame("Button", "ShadowArmyReloadBtn", panel, "UIPanelButtonTemplate")
reloadBtn:SetWidth(68) -- 118 + 8 gap + 68 = 194 = panel width minus insets
reloadBtn:SetHeight(20)
reloadBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 56) -- top row, beside Combat
reloadBtn:SetText("|cFF44FF44Reload!|r")
reloadBtn:Hide()
reloadBtn:SetScript("OnClick", function()
  ReloadUI()
end)

-- One-click loot vacuum (r14): 'loot gated' proved LootSlot is a no-op
-- outside hardware-event context on this client (while sort's
-- PickupContainerItem works from OnUpdate — the gate is per-function).
-- So ride the player's first click on ANY loot item: from inside that
-- click's context, loot every other slot too. One click per corpse.
if LootButton_OnClick then
  local origLootButtonClick = LootButton_OnClick
  LootButton_OnClick = function(button)
    local clicked = this and this:GetID() or 0
    local i = GetNumLootItems()
    while i >= 1 do
      if i ~= clicked then
        LootSlot(i)
        pcall(ConfirmLootSlot, i)
      end
      i = i - 1
    end
    origLootButtonClick(button)
  end
end

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
logBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 32) -- middle row
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

-- Buff watch: warn when a tracked self-buff is missing or expiring.
-- 1.12 API quirk: GetPlayerBuff/GetPlayerBuffTimeLeft give remaining time,
-- but buff NAMES aren't exposed directly — identify by texture instead
-- (stable across ranks). Demon Skin and Demon Armor share the watch slot:
-- either one counts as "armored".
local WATCHED_BUFFS = {
  {
    label = "Demon Skin",
    textures = {
      "Interface\\Icons\\Spell_Shadow_RagingScream",  -- Demon Skin
      "Interface\\Icons\\Spell_Shadow_SpectralSight", -- Demon Armor (lvl 20+)
    },
    warnBelow = 300, -- seconds; warn under 5 minutes
    autoCast = true, -- r12: the advisor keeps this one up itself (see F.armorTick)
  },
}

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

-- Which spell to use. Demon Armor supersedes Demon Skin at 20+; auto.known
-- is the spellbook scan, so we never CastSpellByName something untrained
-- (that throws "you don't know that spell" red text at the human).
function F.armorSpell()
  if auto.known["demon armor"] then return "Demon Armor" end
  if auto.known["demon skin"] then return "Demon Skin" end
  return nil
end

-- Comma-separated list of the player's current buff icons with the
-- "Interface\Icons\" prefix stripped — the payload of the one diagnostic
-- line. Hard-bounded: 1.12 buff indices are 0..31 and a runaway while-loop
-- here would hang the client, not just the addon.
function F.playerBuffTextureList(maxN)
  local out, n, i = nil, 0, 0
  while n < maxN and i < 32 do
    local buffIndex = GetPlayerBuff(i, "HELPFUL")
    if not buffIndex or buffIndex < 0 then break end
    local tex = GetPlayerBuffTexture(buffIndex)
    if tex then
      -- Lua patterns: backslash is NOT special (only % is), so the path
      -- literal doubles as its own pattern.
      tex = string.gsub(tex, "Interface\\Icons\\", "")
      out = out and (out .. "," .. tex) or tex
      n = n + 1
    end
    i = i + 1
  end
  return out or "none"
end

function F.armorTick()
  local now = GetTime()
  if now < armorNextCheck then return end
  armorNextCheck = now + ARMOR_CHECK_EVERY
  for _, watch in ipairs(WATCHED_BUFFS) do
    if watch.autoCast and not watch.acDisabled then
      local left = F.buffTimeLeftByTexture(watch.textures)
      if left then
        -- Texture guess CONFIRMED the first time the buff reads at all. From
        -- here the safety can never trip: a short timer is not a bad texture,
        -- and warnBelow refreshes must not look like failed casts.
        watch.acProven = true
        watch.acVerifyAt = nil
      elseif watch.acVerifyAt and now >= watch.acVerifyAt then
        watch.acDisabled = true
        F.emit("err", "demon-skin autocast: buff never detected after cast — "
          .. "texture guess likely wrong; captured=" .. F.playerBuffTextureList(8))
      end
      -- Cast when the buff is missing entirely OR inside the refresh window.
      if not watch.acDisabled and (not left or left < watch.warnBelow) then
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
          F.castNow(spell) -- shared GCD bookkeeping + F.dtrace
        end
      end
    end
  end
end

local lastNag = 0
function F.buffWatchLine()
  local warnings = nil
  local nags = nil
  for _, watch in ipairs(WATCHED_BUFFS) do
    local left = F.buffTimeLeftByTexture(watch.textures)
    local warn
    if not left then
      warn = string.format("|cFFFF4444%s MISSING|r", watch.label)
    elseif left < watch.warnBelow then
      warn = string.format("|cFFFFAA00%s %dm left|r", watch.label, math.ceil(left / 60))
    end
    if warn then
      local nag = warn
      -- r12: when auto-cast owns this buff there is nothing for the human to
      -- do — show the auto state and stay out of chat entirely. If the
      -- texture-guess safety disabled auto-cast, we fall straight back to the
      -- old warning text AND the old once-a-minute chat nag.
      if watch.autoCast and not watch.acDisabled then
        warn = string.format("|cFF44FF44armor: auto (%s)|r", F.armorSpell() or "untrained")
        nag = nil
      end
      warnings = warnings and (warnings .. "  " .. warn) or warn
      if nag then
        nags = nags and (nags .. "  " .. nag) or nag
      end
    end
  end
  if nags and (GetTime() - lastNag) > 60 then
    lastNag = GetTime()
    F.say("buff watch: " .. nags) -- chat nag at most once a minute
  end
  return warnings or "|cFF44FF44buffs OK|r"
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
  -- kind: status | buffs | cast | loot | pickup | reload
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
  if kind == "loot" then
    local n, left0 = F.probeCountLootItems()
    if n == 0 then
      F.probeEmitVerdict("loot ctx=" .. ctx .. " FAIL no loot window (open a corpse first)")
      return
    end
    local i = n
    while i >= 1 do
      pcall(LootSlot, i)
      pcall(ConfirmLootSlot, i)
      i = i - 1
    end
    local _, left1 = F.probeCountLootItems()
    local verdict
    if left1 < left0 then
      verdict = "OK"
    elseif left0 == 0 then
      verdict = "EMPTY"
    else
      verdict = "GATED" -- calls returned, items still there
    end
    F.probeEmitVerdict(string.format(
      "loot ctx=%s %s slots=%d items %d->%d", ctx, verdict, n, left0, left1))
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
  F.probeLog("Loot: needs open loot window; OK if item count drops.")
  F.probeLog("Pickup: bag item on/off cursor; OK if cursor takes item.")
  F.probeLog("Reload: WILL reload UI if ungated — use last.")
  F.probeLog("Compare same probe under Click vs Frame vs Delay.")
end)

-- Action row
local actY = -70
F.makeProbeBtn("Cast armor", 10, actY, 80, function() F.probeSchedule("cast") end)
F.makeProbeBtn("Loot all", 94, actY, 70, function() F.probeSchedule("loot") end)
F.makeProbeBtn("Pickup", 168, actY, 60, function() F.probeSchedule("pickup") end)
F.makeProbeBtn("|cFFFF6644ReloadUI|r", 232, actY, 80, function() F.probeSchedule("reload") end)
F.makeProbeBtn("Clear", 316, actY, 48, function()
  if probeLogMsg then probeLogMsg:Clear() end
end)
F.makeProbeBtn("Rec", 368, actY, 36, function()
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

-- Bottom row: Admin (System ops) + Probe (sandbox instrument).
local adminBtn = CreateFrame("Button", "ShadowArmyAdminBtn", panel, "UIPanelButtonTemplate")
adminBtn:SetWidth(93)
adminBtn:SetHeight(20)
adminBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 8)
adminBtn:SetText("|cFFFF8844Admin|r")

local probeBtn = CreateFrame("Button", "ShadowArmyProbeBtn", panel, "UIPanelButtonTemplate")
probeBtn:SetWidth(93)
probeBtn:SetHeight(20)
probeBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 8)
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

function F.moneyString()
  local c = GetMoney() or 0
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
-- QUEST HELPER (r18): "where do I go next" — a nearest-objective line in the
-- advisor panel, dots on the minimap, dots on the world map. Everything here
-- is driven by QuestData.lua (global ShadowArmyQuestData, keyed by the EXACT
-- quest title). 1.12 does not expose quest IDs to addons at all, so the title
-- STRING is the only join between the live quest log and mined coordinates —
-- that is why the data file is shaped the way it is, not a stylistic choice.
--
-- If the data file is absent the whole feature no-ops after exactly one
-- `err quest data missing` line. Nothing below may ever depend on it existing.
--
-- ZONE IDENTITY IS THE HARD PART, and it is why this section looks paranoid.
-- The data file speaks AreaTable ids (85 = Tirisfal Glades). The 1.12 client
-- hands an addon zone NAMES (GetZoneText/GetRealZoneText) and world-map
-- dropdown INDICES (GetCurrentMapZone) — never AreaTable ids, and there is no
-- API that converts between them. A hand-written name->id table would be the
-- only bridge, and one wrong row in it parks an arrow on a mob three zones
-- over, which is worse than no arrow at all.
--
-- So we never convert. A waypoint is drawn only when BOTH hold:
--   (1) the quest's own quest-log HEADER name equals the player's current
--       zone name. The log groups quests by zone, and that grouping comes
--       from the same server the coordinates were mined against — it is a
--       string compare between two things the client itself produced.
--   (2) the waypoint's `zone` id equals its quest's `zone` id. Both numbers
--       come out of the data file, so the client is not involved in that
--       comparison at all.
-- Anything we cannot prove sits in the current zone is simply NOT DRAWN.
-- Fails safe: a missing arrow costs a few seconds of reading the quest log,
-- a wrong arrow costs a corpse run.
--
-- Deliberate consequence: an objective that lives in a neighbouring zone
-- stays hidden until you walk into that zone. (2) is what makes multi-zone
-- quests degrade quietly instead of pointing at the wrong patch of map.
--
-- Second, opportunistic path: every time (1) holds we LEARN `zone id -> zone
-- name` from that quest, and afterwards a waypoint carrying a learned id is
-- allowed through even when its quest headers somewhere else. Conflicting
-- evidence for an id POISONS that id permanently (it goes back to unknown),
-- because a learned mapping that is wrong is worse than no mapping. The table
-- is rebuilt from scratch every reload; it is a cache, never a source.
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
  enabled = true,
  dataWarned = false,   -- the one-and-only "no data file" F.emit
  nextTickAt = 0,
  nextMarkerAt = 0,
  nextMapFix = 0,
  logSig = "",          -- change detector for the debug-only log trace
  target = nil,         -- the waypoint the panel line is pointing at
  spots = {},           -- every drawable waypoint, nearest first
  learned = {},         -- zone id -> zone name, or false once poisoned
  zoneName = "",
  px = 0, py = 0, posOK = false,
}

local questBtn -- created below; F.questSetEnabled closes over this local

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

-- Strict TOTAL order: table.sort in 5.0 is unstable and raises "invalid order
-- function" on a sloppy comparator (the same lesson the bag sort learned).
function F.questCandCmp(a, b)
  if a.dist ~= b.dist then return a.dist < b.dist end
  return a.idx < b.idx
end

function F.questScan()
  local data = F.questData()
  local zone = GetRealZoneText() or ""
  quest.zoneName = zone
  if not data or not quest.posOK then
    quest.spots = {}
    quest.target = nil
    return
  end
  -- Quest log open: keep the previous scan rather than reach into the
  -- selection under the human's cursor. Blips stay honest anyway because
  -- they are drawn against the live player position every tick.
  if QuestLogFrame and QuestLogFrame:IsVisible() then return end

  local sel = 0
  if GetQuestLogSelection then sel = GetQuestLogSelection() or 0 end

  -- Watched (tracked) quests own the panel line when there are any.
  local watched = {}
  local nw = GetNumQuestWatches and GetNumQuestWatches() or 0
  local wi = 1
  while wi <= nw do
    local qi = GetQuestIndexForWatch(wi)
    if qi then watched[qi] = true end
    wi = wi + 1
  end

  local cand, nc = {}, 0
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
        sig = sig .. title .. (isComplete and "!" or "-")
        if isComplete then
          -- Objectives are done: the only useful waypoint is the turn-in NPC.
          local w = q.turnIn
          if w and w.x and w.y and F.questSpotHere(q, w.zone, headerMatch, zone) then
            nc = nc + 1
            cand[nc] = {
              label = w.label or title, x = w.x, y = w.y,
              turnIn = true, tracked = watched[i] and true or false, idx = nc,
            }
          end
        elseif q.objectives then
          local boards, nb = F.questBoards(i)
          local nObj = table.getn(q.objectives)
          local oi = 1
          while oi <= nObj and nc < QUEST_MAX_CAND do
            local obj = q.objectives[oi]
            local b = F.questMatchBoard(boards, nb, obj.label, oi)
            local have = (b and b.have) or 0
            local need = (b and b.need) or obj.count or 0
            local done = b and (b.done or (need > 0 and have >= need))
            if not done and obj.spots then
              sig = sig .. ":" .. have
              local nSpots = table.getn(obj.spots)
              local si = 1
              while si <= nSpots and nc < QUEST_MAX_CAND do
                local s = obj.spots[si]
                if s.x and s.y and F.questSpotHere(q, s.zone, headerMatch, zone) then
                  nc = nc + 1
                  cand[nc] = {
                    label = obj.label or title, have = have, need = need,
                    x = s.x, y = s.y,
                    tracked = watched[i] and true or false, idx = nc,
                  }
                end
                si = si + 1
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

  local k = 1
  while k <= nc do
    local c = cand[k]
    c.dx = c.x - quest.px
    c.dy = c.y - quest.py
    c.dist = F.questYards(c.dx, c.dy)
    k = k + 1
  end
  table.sort(cand, F.questCandCmp)
  quest.spots = cand

  -- Tracked quests win the panel LINE outright; the blips still show
  -- everything nearby, because the map is more useful than the line.
  local pick = nil
  k = 1
  while k <= nc do
    if cand[k].tracked then
      pick = cand[k]
      break
    end
    k = k + 1
  end
  if not pick then pick = cand[1] end
  quest.target = pick

  if sig ~= quest.logSig then
    quest.logSig = sig
    F.dtrace("quest " .. nc .. " waypoint(s) in " .. zone)
  end
end

--------------------------------------------------------------------------
-- Drawing. Textures are created once and parked (1.12 frames and their
-- regions cannot be destroyed), and SetTexture is called with COLOR numbers
-- rather than an art path — a solid dot cannot 404 on a private-server build
-- the way a guessed Interface\\ path can.
--------------------------------------------------------------------------

local questBlips = {}
function F.questBlip(i)
  local t = questBlips[i]
  if t then return t end
  t = Minimap:CreateTexture(nil, "OVERLAY")
  t:SetWidth(7)
  t:SetHeight(7)
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
  local show = quest.enabled and quest.posOK
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
      if s.turnIn then
        t:SetTexture(0.20, 1.00, 0.20, 0.90)
      else
        t:SetTexture(1.00, 0.82, 0.00, 0.90)
      end
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
  questMarkers[i] = t
  return t
end

-- The map is only ever marked when it is showing the PLAYER'S OWN zone, and
-- the oracle for that is quest.posOK: GetPlayerMapPosition reads 0,0 the
-- moment the map is pointed anywhere else. No zone id lookup, no dropdown
-- index math, and it cannot be fooled into decorating the wrong continent.
function F.questDrawMarkers()
  if not WorldMapDetailFrame then return end
  local show = quest.enabled and quest.posOK
    and WorldMapFrame and WorldMapFrame:IsVisible()
  local w = WorldMapDetailFrame:GetWidth()
  local h = WorldMapDetailFrame:GetHeight()
  local i = 1
  while i <= QUEST_MAX_MARKERS do
    local s = quest.spots[i]
    local t = F.questMarker(i)
    if show and s then
      t:ClearAllPoints()
      t:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT",
        s.x / 100 * w, -(s.y / 100 * h))
      if s.turnIn then
        t:SetTexture(0.20, 1.00, 0.20, 0.95)
      else
        t:SetTexture(1.00, 0.82, 0.00, 0.95)
      end
      t:Show()
    else
      t:Hide()
    end
    i = i + 1
  end
end

-- The advisor panel's quest line. Every state says WHY it has nothing to
-- show; a blank line reads as a broken addon.
function F.questLineText()
  if not quest.enabled then return "" end
  if not ShadowArmyQuestData then return "|cFF777777quests: no data file|r" end
  if not quest.posOK then return "|cFF777777quests: map is off-zone|r" end
  local t = quest.target
  if not t then return "|cFF777777quests: nothing mapped here|r" end
  local dir = F.questBearing(t.dx, t.dy)
  local yards = math.floor(t.dist + 0.5)
  if t.turnIn then
    return string.format("|cFF44FF44%s %s|r |cFFAAAAAA%s ~%dy %s|r",
      QUEST_MARK_TURNIN, t.label, "\194\183", yards, dir)
  end
  local prog = ""
  if t.need and t.need > 0 then
    prog = string.format(" %d/%d", t.have or 0, t.need)
  end
  return string.format("|cFFFFD200%s %s%s|r |cFFAAAAAA%s ~%dy %s|r",
    QUEST_MARK_GO, t.label, prog, "\194\183", yards, dir)
end

function F.questTick()
  if not quest.enabled then return end
  local now = GetTime()
  if now < quest.nextTickAt then return end
  quest.nextTickAt = now + QUEST_TICK_EVERY
  F.questPosition()
  F.questScan()
  F.questDrawBlips()
  F.questDrawMarkers()
end

function F.questSetEnabled(on)
  quest.enabled = on and true or false
  if questBtn then
    -- Label fixed; state is the colour. Green on, grey off.
    questBtn:SetText(quest.enabled and "|cFF44FF44Quests|r" or "|cFF999999Quests|r")
  end
  if quest.enabled then
    quest.nextTickAt = 0
  else
    quest.spots = {}
    quest.target = nil
    pcall(F.questDrawBlips)
    pcall(F.questDrawMarkers)
  end
end

questBtn = CreateFrame("Button", "ShadowArmyQuestBtn", panel, "UIPanelButtonTemplate")
questBtn:SetWidth(93) -- 8 + 93 + 8 + 93 + 8 = 210 = panel width
questBtn:SetHeight(20)
questBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 32) -- middle row, right of Log
questBtn:SetText("|cFF44FF44Quests|r")
questBtn:SetScript("OnClick", function()
  F.questSetEnabled(not quest.enabled)
end)

-- WORLD_MAP_UPDATE fires on pan/zoom/zone-switch and can arrive every frame
-- while the map is open, so the repaint is throttled; the 0.5s tick repaints
-- anyway, this just keeps markers from lagging a zone change visibly.
-- ZONE_CHANGED_NEW_AREA forces an immediate rescan because rule (1) is a
-- comparison against the zone NAME, which just changed.
local questEvents = CreateFrame("Frame", "ShadowArmyQuestEvents", UIParent)
questEvents:RegisterEvent("WORLD_MAP_UPDATE")
questEvents:RegisterEvent("ZONE_CHANGED_NEW_AREA")
questEvents:SetScript("OnEvent", function()
  if not quest.enabled then return end
  if event == "ZONE_CHANGED_NEW_AREA" then
    quest.nextTickAt = 0
    return
  end
  local now = GetTime()
  if now < quest.nextMarkerAt then return end
  quest.nextMarkerAt = now + QUEST_MARKER_EVERY
  local ok, err = pcall(F.questDrawMarkers)
  if not ok then F.emit("err", "questMarkers: " .. tostring(err)) end
end)

--------------------------------------------------------------------------
-- CREW / CORPSE BLIPS (r21): party members + own corpse on minimap + world
-- map. Independent of the quest helper — corpse runs still need a compass
-- when quests are toggled off.
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
  -- Keep map fixed when quests are off (F.questTick is the usual fixer).
  if quest.enabled then
    if quest.posOK then
      crew.px, crew.py, crew.posOK = quest.px, quest.py, true
    else
      F.crewPosition()
    end
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
--------------------------------------------------------------------------
-- Auto-loot (r11): single-shot LootSlot() at LOOT_OPENED provably did not
-- empty the window (live: `trace loot opened slots=N`, items still there).
-- Three candidate causes, and this code is built to tell them apart:
--   (a) the client gates LootSlot the way it gates ReloadUI -> retries can
--       never work, and `loot gated` says so out loud;
--   (b) the first call races the server's loot packet -> retries fix it;
--   (c) BoP/quest items want ConfirmLootSlot -> the confirm pass fixes it.
-- GetNumLootItems() counts SLOTS, which do not disappear as they are
-- looted, so "how much is left" is measured by how many slots still carry
-- an item (GetLootSlotInfo returns nil texture for a cleared slot).
--------------------------------------------------------------------------

local LOOT_RETRY_EVERY = 0.25
local LOOT_RETRY_FOR = 2.0

local loot = {
  active = false,
  openedAt = 0,
  startSlots = 0,   -- item-bearing slots when the window opened
  lastSeen = 0,     -- item-bearing slots at the most recent observation
  nextTryAt = 0,
  gatedReported = false, -- one `loot gated` per session is the whole signal
}

function F.lootSlotsLeft()
  local n = GetNumLootItems()
  if not n then return 0 end
  local left = 0
  local i = 1
  while i <= n do
    if GetLootSlotInfo(i) then -- first return is the texture; nil = cleared
      left = left + 1
    end
    i = i + 1
  end
  return left
end

function F.lootSweep()
  local n = GetNumLootItems()
  if not n then return end
  -- Backwards: LootSlot removes entries, so forward indexing skips slots.
  local i = n
  while i >= 1 do
    LootSlot(i)
    -- BoP/quest items raise a confirmation prompt; on clients with nothing
    -- pending this call errors, and an unguarded error here would kill the
    -- rest of the sweep silently (scriptErrors is off).
    pcall(ConfirmLootSlot, i)
    i = i - 1
  end
  loot.lastSeen = F.lootSlotsLeft()
end

function F.lootTick()
  local now = GetTime()
  if now < loot.nextTryAt then return end
  loot.nextTryAt = now + LOOT_RETRY_EVERY
  loot.lastSeen = F.lootSlotsLeft()
  if loot.lastSeen <= 0 then
    loot.active = false -- window is empty; summary lands on LOOT_CLOSED
    return
  end
  if (now - loot.openedAt) > LOOT_RETRY_FOR then
    loot.active = false -- retry budget spent
    if loot.lastSeen >= loot.startSlots and not loot.gatedReported then
      -- Two seconds of retries moved exactly nothing: these calls are being
      -- ignored, not raced. More retries are wasted; the next rev needs a
      -- hardware-event piggyback (same shape as the reload button).
      loot.gatedReported = true
      F.emit("loot", "gated")
    end
    return
  end
  F.lootSweep()
end

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
  -- r13: bag autosort (one swap in flight).
  if sort.active then
    local sok, serr = pcall(F.sortTick)
    if not sok then
      F.emit("err", "sortTick: " .. tostring(serr))
      pcall(F.sortStop, "error")
    end
  end
  -- r18: quest waypoints.
  if quest.enabled then
    local qok, qerr = pcall(F.questTick)
    if not qok then F.emit("err", "questTick: " .. tostring(qerr)) end
  end
  -- r21: party + corpse blips.
  if crew.enabled then
    local cok, cerr = pcall(F.crewTick)
    if not cok then F.emit("err", "crewTick: " .. tostring(cerr)) end
  end
  if loot.active then F.lootTick() end
  -- r26: combat coach panel refresh (~4 Hz when open). Display only.
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
  line5:SetText(F.buffWatchLine())
  -- Corpse-run compass wins the quest line while ghosting.
  local corpseLine = F.corpseLineText()
  line6:SetText(corpseLine or F.questLineText())
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
-- auto-loot: vanilla has no always-auto-loot option (that's a TBC setting),
-- and LootSlot isn't protected in 1.12 — vacuum the window on open, then
-- retry from the driver (r11) and report the result on close
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("LOOT_SLOT_CLEARED")
frame:RegisterEvent("LOOT_CLOSED")

frame:SetScript("OnEvent", function()
  if event == "PLAYER_ENTERING_WORLD" then
    grind.startTime = GetTime()
    grind.startXP = UnitXP("player")
    F.scanSpellbook()
    -- QoL defaults the advisor asserts on every login:
    -- F.instantQuestText() DISABLED (r14): prime remaining suspect for the
    -- reproducible crash+lockup on Complete Quest (it nils the quest
    -- panels' OnUpdate — exactly the surface involved in that click). The
    -- fanfare mute didn't take (music still played), so this is the next
    -- single-variable test. Re-enable only after turn-ins are proven safe.
    F.panelShowReset()
    F.say("ARISE. Advisor online for " .. UnitName("player") .. " — /sa help (rev=" .. REV .. ")")
    F.emit("loaded", "rev=" .. REV)
    if not ShadowArmyQuestData then
      F.say("quest data missing (QuestData.lua failed to load) — panel still works")
    end
  elseif event == "LEARNED_SPELL_IN_TAB" then
    F.scanSpellbook()
  elseif event == "SPELLCAST_START" then
    auto.casting = true
    auto.castingSince = GetTime()
  elseif event == "SPELLCAST_STOP" then
    auto.casting = false
  elseif event == "SPELLCAST_FAILED" or event == "SPELLCAST_INTERRUPTED" then
    auto.casting = false
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
  elseif event == "LOOT_OPENED" then
    loot.active = true
    loot.openedAt = GetTime()
    loot.startSlots = F.lootSlotsLeft()
    loot.lastSeen = loot.startSlots
    loot.nextTryAt = GetTime() + LOOT_RETRY_EVERY
    F.dtrace("loot opened slots=" .. tostring(GetNumLootItems())
      .. " items=" .. loot.startSlots)
    F.lootSweep() -- first attempt now; the driver retries for ~2s after this
  elseif event == "LOOT_SLOT_CLEARED" then
    -- Keeps lastSeen honest when the window empties and auto-closes inside
    -- a single retry interval.
    loot.lastSeen = F.lootSlotsLeft()
  elseif event == "LOOT_CLOSED" then
    loot.active = false
    if loot.startSlots > 0 then
      -- The one line that settles "do these calls do anything at all".
      F.emit("loot", "result took=" .. (loot.startSlots - loot.lastSeen)
        .. " left=" .. loot.lastSeen)
      loot.startSlots = 0
    end
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
  F.say("  /sa quests     toggle quest helper (map blips / objectives)")
  F.say("  /sa crew       toggle party + corpse map blips")
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
    F.questSetEnabled(not quest.enabled)
    F.say("quest helper " .. (quest.enabled and "ON" or "OFF"))
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
