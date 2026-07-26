-- ShadowArmy — advisor v0.1: draggable HUD panel (grind stats + target
-- intel + action buttons) on top of the hello-world plumbing.
-- 1.12 (Lua 5.0) addon: no protected functions, vararg via arg table,
-- event args via global event/arg1/arg2. Keep everything addon-local
-- except the single ShadowArmy root.

ShadowArmy = ShadowArmy or {}

-- Bump on every edit. The System watches Chat.log for "<SA> loaded rev=..."
-- after sending a reload — a new rev proves the edit actually loaded.
local REV = "r16"

-- Log window (r16): every say()/emit() line also lands here with a
-- timestamp, so errors survive chat scroll-off and can be reviewed in-game.
-- ScrollingMessageFrame is the same widget chat frames are built on —
-- free history, free scrolling. Forward-declared; UI built after the panel.
local addLog -- (kind, text)

local function say(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cFF9482C9[ShadowArmy]|r " .. tostring(msg))
  if addLog then addLog("say", tostring(msg)) end
end

-- /say lands in the server's Chat.log; The System tails it. This is
-- the addon's only outbound channel.
-- r11 flood control (live incident): the trace firehose tripped the server's
-- chat throttle — "you must wait 4s before speaking again" — which blocked
-- the HUMAN's own chat too. So nothing is sent straight from the call site
-- any more. emit() queues; the driver's OnUpdate drains at most one line per
-- EMIT_GAP seconds. The queue is deliberately tiny and priority-aware: under
-- pressure we throw away chatter (traces) and never the lines The System
-- actually reads (loaded / reloading / reload-click / err / pong / status).
local EMIT_GAP = 2.0        -- seconds between ANY two sends
local EMIT_QUEUE_MAX = 5
local DROPPABLE = { trace = true }

local emitQueue = {}        -- FIFO of { msg = string, drop = bool }
local lastSendAt = 0
local lastEmitMsg, lastEmitTime = nil, 0 -- 30s identical-message dedupe

local function emit(kind, text)
  local msg = "<SA> " .. kind .. " " .. text
  local now = GetTime()
  if msg == lastEmitMsg and (now - lastEmitTime) < 30 then
    return
  end
  lastEmitMsg = msg
  lastEmitTime = now
  if addLog then addLog(kind, text) end
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
local function emitDrain()
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
-- /say. Opt in with `<SYS> debug on`, off again with `<SYS> debug off`.
local debugMode = false
local function dtrace(text)
  if debugMode then
    emit("trace", text)
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

local function fmtDuration(seconds)
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

local function grindStats()
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
  return math.floor(perHour), fmtDuration(toLevel / (perHour / 3600))
end

--------------------------------------------------------------------------
-- Advisor panel: draggable window with live lines + buttons.
--------------------------------------------------------------------------

local panel = CreateFrame("Frame", "ShadowArmyPanel", UIParent)
panel:SetWidth(210)
panel:SetHeight(160)
panel:SetPoint("RIGHT", UIParent, "RIGHT", -40, 60)
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

local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", panel, "TOP", 0, -8)
title:SetText("|cFF9482C9Shadow Advisor|r")

local function makeLine(prev, offset)
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
local line2 = makeLine(line1)
local line3 = makeLine(line2)
local line4 = makeLine(line3)
local line5 = makeLine(line4, -6) -- buff watch / warnings

-- (v0.1 had Nearest-foe/Attack buttons; removed — they duplicated Tab and
-- the T auto-attack keybind. Rule: a button earns its place only by doing
-- something the default UI can't. Full-auto combat qualifies.)

--------------------------------------------------------------------------
-- Auto-combat: toggle + warlock rotation. When ON and you target an
-- attackable enemy, the advisor plays the fight: Corruption up, Shadow
-- Bolt while mana holds, wand otherwise, melee as last resort.
-- Uses only spells the character has LEARNED (spellbook scan) — the
-- human still trains everything at the trainer themselves.
--------------------------------------------------------------------------

local auto = {
  enabled = false,
  casting = false,   -- SPELLCAST_START..STOP window (cast-time spells)
  castingSince = 0,  -- stuck-flag safety: clear if STOP never arrives
  gcdUntil = 0,      -- our own 1.6s guard after any cast request
  failUntil = 0,     -- backoff after SPELLCAST_FAILED (no machine-gun retry)
  shooting = false,  -- wand auto-repeat active (don't re-toggle it off!)
  melee = false,     -- auto-attack swing loop active
  lastMeleeAt = 0,   -- AttackTarget re-fire guard (2nd call toggles OFF)
  known = {},        -- lowercase spell name -> true
}

-- Movement detection (r8): Shadow Bolt while moving fails with "Can't do
-- that while moving" and the rotation would retry forever instead of
-- falling back to the wand ("breaks down if I'm moving" — monofuel, live).
-- 1.12 exposes no IsMoving(); poll GetPlayerMapPosition deltas instead.
-- r11: sampled from the DRIVER's OnUpdate (every frame), not from
-- rotationStep — rotationStep is skipped during GCD/backoff windows, so
-- move.at went stale and a player who had stopped still read as moving for
-- a whole extra cycle, starving Shadow Bolt. rotationStep now only READS
-- move.moving.
local move = { x = 0, y = 0, at = 0, moving = false }
local function updateMoving()
  local x, y = GetPlayerMapPosition("player")
  if x and (x ~= 0 or y ~= 0) then
    if x ~= move.x or y ~= move.y then
      move.moving = true
      move.at = GetTime()
    elseif GetTime() - move.at > 0.3 then
      move.moving = false -- standing still for a beat
    end
    move.x, move.y = x, y
  else
    move.moving = false -- no map position (instance): assume stationary
  end
end

local function scanSpellbook()
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

local function targetHasDebuff(texture)
  local i = 1
  while true do
    local tex = UnitDebuff("target", i)
    if not tex then return false end
    if tex == texture then return true end
    i = i + 1
  end
end

local function castNow(spell)
  dtrace("cast " .. spell)
  CastSpellByName(spell)
  auto.gcdUntil = GetTime() + 1.6
end

local function rotationStep()
  if not auto.enabled then return end
  if not UnitExists("target") then return end
  if UnitIsDeadOrGhost("target") or not UnitCanAttack("player", "target") then return end
  -- stuck-casting safety: a missed SPELLCAST_STOP would freeze the whole
  -- rotation ("doesn't work" with no error). No 1.12 cast lasts 4s at our
  -- level; clear and move on.
  if auto.casting and GetTime() - auto.castingSince > 4 then
    auto.casting = false
    dtrace("casting flag stuck >4s — cleared")
  end
  if auto.casting or GetTime() < auto.gcdUntil then return end
  if GetTime() < auto.failUntil then return end

  -- move.moving is sampled by the driver every frame (see updateMoving).
  local manaPct = 0
  if UnitManaMax("player") > 0 then
    manaPct = UnitMana("player") / UnitManaMax("player") * 100
  end
  local inCastRange = CheckInteractDistance("target", 4)  -- ~28yd

  -- Pet first: sic the imp whenever it isn't on our target (Firebolt is on
  -- autocast, so PetAttack is the only command it needs). No GCD cost.
  -- UnitIsUnit handles both "no pet target" and "pet on the wrong mob".
  if UnitExists("pet") and not UnitIsDead("pet")
      and not UnitIsUnit("pettarget", "target") then
    dtrace("pet attack")
    PetAttack()
  end

  -- Priority: DoT up -> nuke while mana holds -> wand -> melee.
  -- While MOVING only instants + wand are legal: Shadow Bolt would fail
  -- "Can't do that while moving"; wand auto-repeat keeps firing on the run.
  if inCastRange and auto.known["corruption"] and manaPct > 25
      and not targetHasDebuff(CORRUPTION_TEX) then
    castNow("Corruption") -- instant: fine while moving
    return
  end
  -- Mana reserve: 30→45 (r10) was too greedy — "shadow bolt still not
  -- working" (monofuel, live): with Corruption + the imp burning mana the
  -- pool sits under 45% most of a fight, so the nuke never fired. r11 puts
  -- the floor at 35: still leaves a wand/Corruption reserve, but lets the
  -- bolt actually cast.
  if inCastRange and not move.moving
      and auto.known["shadow bolt"] and manaPct > 35 then
    castNow("Shadow Bolt")
    return
  end
  -- "Shoot" sits in the spellbook even with no wand equipped (live find);
  -- gate on the ranged slot (18) actually holding something.
  if inCastRange and auto.known["shoot"] and not auto.shooting
      and GetInventoryItemLink("player", 18) then
    -- wand toggle: casting Shoot while already repeating would turn it OFF
    dtrace("cast Shoot" .. (move.moving and " (moving)" or ""))
    CastSpellByName("Shoot")
    return
  end
  -- Melee is a LAST resort for a warlock (the imp + DoTs are the plan):
  -- only when the mob is already in our face. 3s re-fire guard — the live
  -- traces showed back-to-back AttackTarget calls, and the second one
  -- TOGGLES auto-attack off (that was the melee stutter).
  if not auto.melee and CheckInteractDistance("target", 3)
      and GetTime() - auto.lastMeleeAt > 3 then
    auto.lastMeleeAt = GetTime()
    dtrace("melee AttackTarget (last resort)")
    AttackTarget()
    return
  end
  -- Nothing fired: say why, once per situation (dedupe handles repeats).
  local known = 0
  for _ in pairs(auto.known) do known = known + 1 end
  dtrace(string.format("idle: known=%d mana=%d%% range28=%s range10=%s moving=%s shooting=%s melee=%s",
    known, manaPct, tostring(inCastRange),
    tostring(CheckInteractDistance("target", 3) and true or false),
    tostring(move.moving), tostring(auto.shooting), tostring(auto.melee)))
end

local function setAuto(on)
  auto.enabled = on
  -- r11: label always reads "Auto Combat" (the old "Auto: ON/OFF" was
  -- unclear); the STATE lives in the colour — green on, grey off.
  local label = on and "|cFF44FF44Auto Combat|r" or "|cFF999999Auto Combat|r"
  ShadowArmyAutoBtn:SetText(label)
  say(on and "auto-combat ON — target something and watch"
        or "auto-combat OFF — back to manual")
  -- /say lands in the server's Chat.log, labeling the breadcrumb corpus:
  -- everything between ON/OFF markers is addon play, not human play.
  emit("auto", on and "ON" or "OFF")
end

local autoBtn = CreateFrame("Button", "ShadowArmyAutoBtn", panel, "UIPanelButtonTemplate")
autoBtn:SetWidth(118)
autoBtn:SetHeight(20)
autoBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 8)
autoBtn:SetText("|cFF999999Auto Combat|r")
autoBtn:SetScript("OnClick", function()
  setAuto(not auto.enabled)
  -- Hardware-event probe: this click IS a hardware event. If a cast fires
  -- here but never from OnUpdate, the client gates combat calls the same
  -- way it gates ReloadUI. (Target something attackable, then click.)
  if auto.enabled then
    local ok, err = pcall(rotationStep)
    if not ok then
      emit("err", "rotation(click): " .. tostring(err))
    end
  end
end)

-- Remote-reload button: hidden until The System requests a reload. It must
-- be a click because this build ignores programmatic ReloadUI (see the
-- driver notes) — a mouse click is the hardware event that makes it legal.
local reloadBtn = CreateFrame("Button", "ShadowArmyReloadBtn", panel, "UIPanelButtonTemplate")
reloadBtn:SetWidth(68) -- 118 + 8 gap + 68 = 194 = panel width minus insets
reloadBtn:SetHeight(20)
reloadBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 8)
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

local function makeLogBtn(label, xOff, fn)
  local b = CreateFrame("Button", nil, logFrame, "UIPanelButtonTemplate")
  b:SetWidth(56)
  b:SetHeight(18)
  b:SetPoint("BOTTOMLEFT", logFrame, "BOTTOMLEFT", xOff, 7)
  b:SetText(label)
  b:SetScript("OnClick", fn)
  return b
end
makeLogBtn("Up", 12, function() logMsg:ScrollUp() end)
makeLogBtn("Down", 72, function() logMsg:ScrollDown() end)
makeLogBtn("Latest", 132, function() logMsg:ScrollToBottom() end)

-- kind -> color; errors pop, telemetry chatter stays muted
local LOG_COLORS = {
  err = { 1.0, 0.35, 0.35 },
  say = { 0.72, 0.62, 0.9 },
  trace = { 0.55, 0.55, 0.55 },
  loaded = { 0.35, 1.0, 0.35 },
}

addLog = function(kind, text)
  local c = LOG_COLORS[kind] or { 0.8, 0.8, 0.8 }
  local tag = (kind == "say") and "" or ("[" .. kind .. "] ")
  logMsg:AddMessage(date("%H:%M:%S ") .. tag .. text, c[1], c[2], c[3])
end

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
    autoCast = true, -- r12: the advisor keeps this one up itself (see armorTick)
  },
}

local function buffTimeLeftByTexture(textures)
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
local function armorSpell()
  if auto.known["demon armor"] then return "Demon Armor" end
  if auto.known["demon skin"] then return "Demon Skin" end
  return nil
end

-- Comma-separated list of the player's current buff icons with the
-- "Interface\Icons\" prefix stripped — the payload of the one diagnostic
-- line. Hard-bounded: 1.12 buff indices are 0..31 and a runaway while-loop
-- here would hang the client, not just the addon.
local function playerBuffTextureList(maxN)
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

local function armorTick()
  local now = GetTime()
  if now < armorNextCheck then return end
  armorNextCheck = now + ARMOR_CHECK_EVERY
  for _, watch in ipairs(WATCHED_BUFFS) do
    if watch.autoCast and not watch.acDisabled then
      local left = buffTimeLeftByTexture(watch.textures)
      if left then
        -- Texture guess CONFIRMED the first time the buff reads at all. From
        -- here the safety can never trip: a short timer is not a bad texture,
        -- and warnBelow refreshes must not look like failed casts.
        watch.acProven = true
        watch.acVerifyAt = nil
      elseif watch.acVerifyAt and now >= watch.acVerifyAt then
        watch.acDisabled = true
        emit("err", "demon-skin autocast: buff never detected after cast — "
          .. "texture guess likely wrong; captured=" .. playerBuffTextureList(8))
      end
      -- Cast when the buff is missing entirely OR inside the refresh window.
      if not watch.acDisabled and (not left or left < watch.warnBelow) then
        local spell = armorSpell()
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
          castNow(spell) -- shared GCD bookkeeping + dtrace
        end
      end
    end
  end
end

local lastNag = 0
local function buffWatchLine()
  local warnings = nil
  local nags = nil
  for _, watch in ipairs(WATCHED_BUFFS) do
    local left = buffTimeLeftByTexture(watch.textures)
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
        warn = string.format("|cFF44FF44armor: auto (%s)|r", armorSpell() or "untrained")
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
    say("buff watch: " .. nags) -- chat nag at most once a minute
  end
  return warnings or "|cFF44FF44buffs OK|r"
end

local function targetSummary()
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

local function moneyString()
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
local function bagButton(index)
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
        local btn = bagButton(index)
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
  bagsMoney:SetText(moneyString())
end

local function bagsShow()
  bagsFrame:Show()
  bagsUpdate()
end

local function bagsHide()
  bagsFrame:Hide()
end

local function bagsToggle()
  if bagsFrame:IsShown() then bagsHide() else bagsShow() end
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
-- after a click swap provably worked = gated, and we say so once and stop.
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
                    -- swallowed by emit()'s 30s dedupe
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

local function cursorBusy()
  local ok, has = pcall(CursorHasItem)
  if not ok then return false end
  return has and true or false
end

-- ClearCursor RETURNS a held bag item to where it came from (it does not
-- destroy it). pcall because a missing global here would kill the driver.
local function cursorDrop()
  pcall(ClearCursor)
end

-- "type/subtype", or "zz-unknown" so unidentified items sort to the end
-- instead of scattering through the grid.
local function itemTypeKey(id)
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
local function bagIsNormal(bag)
  if sort.skipBag[bag] then return false end
  if bag == 0 then return true end -- backpack is never a specialty bag
  local ok, free, btype = pcall(GetContainerNumFreeSlots, bag)
  if not ok then return true end
  if type(btype) == "number" and btype ~= 0 then return false end
  return true
end

local function slotLocked(bag, slot)
  local _, _, locked = GetContainerItemInfo(bag, slot)
  return locked and true or false
end

-- Content fingerprint of one slot. `locked` is deliberately NOT in here:
-- the lock flag is tracked separately as proof the client accepted the call,
-- and folding it in would make a lock flicker look like a completed move.
local function slotSig(bag, slot)
  local tex, count = GetContainerItemInfo(bag, slot)
  return tostring(tex) .. "#" .. tostring(count)
end

-- Flat scan of every sortable slot, in bag/slot order. Index in this list IS
-- the position the sort reasons about; entry.tex nil = empty socket.
local function sortScan()
  local list, n = {}, 0
  local bag = 0
  while bag <= 4 do -- NEVER -1/5+ (bank) and never -2 (keyring)
    if bagIsNormal(bag) then
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
            e.tkey = itemTypeKey(e.id)
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
local function sortCmp(a, b)
  if a.tkey ~= b.tkey then return a.tkey < b.tkey end
  if a.quality ~= b.quality then return a.quality > b.quality end
  local ai, bi = a.id or 0, b.id or 0
  if ai ~= bi then return ai < bi end
  if a.count ~= b.count then return a.count > b.count end
  return a.idx < b.idx
end

-- Returns destinationIndex, sourceEntry for the next swap, or nil when the
-- grid already matches the desired arrangement.
local function sortNextSwap(list, n)
  local occ, m = {}, 0
  local i = 1
  while i <= n do
    if list[i].tex then
      m = m + 1
      occ[m] = list[i]
    end
    i = i + 1
  end
  table.sort(occ, sortCmp)
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

local function sortSetLabel(active)
  if not sortBtn then return end
  sortBtn:SetText(active and "|cFFFFAA00Sorting...|r" or "|cFFCCCCCCSort|r")
end

local function sortStop(reason)
  sort.active = false
  sort.pend = nil
  if cursorBusy() then cursorDrop() end
  sortSetLabel(false)
  dtrace("sort stop " .. tostring(reason) .. " moves=" .. sort.moves)
  bagsUpdate()
end

local function sortFinish()
  local n = sort.moves
  sortStop("done")
  emit("sort", "done moves=" .. n .. " #" .. sort.seq)
end

local function sortAbort(why)
  local n = sort.moves
  sortStop(why)
  if why == "stalled" then
    emit("err", "sort stalled at " .. n .. " moves #" .. sort.seq)
  elseif why == "runaway" then
    emit("err", "sort runaway at " .. n .. " moves #" .. sort.seq)
  end
end

-- Fire at most ONE swap. ctx is "click" (hardware event) or "onupdate".
local function sortIssue(ctx)
  if sort.pend then return end
  if cursorBusy() then return end -- the human is carrying something; wait
  local list, n = sortScan()
  local dstIdx, src = sortNextSwap(list, n)
  if not dstIdx then
    sortFinish()
    return
  end
  local dst = list[dstIdx]
  -- Locked = a move we (or the human) already asked for is still in flight.
  -- Skip gracefully: no plan to invalidate, the next tick just re-scans.
  if src.locked or dst.locked then return end
  if sort.moves >= SORT_MAX_MOVES then
    sortAbort("runaway")
    return
  end
  local sig = slotSig(src.bag, src.slot) .. "|" .. slotSig(dst.bag, dst.slot)
  -- SOURCE FIRST, ALWAYS. The destination may be an empty socket, and
  -- picking up an empty slot is a no-op — doing it in the other order would
  -- leave the item stranded on the cursor.
  PickupContainerItem(src.bag, src.slot)
  PickupContainerItem(dst.bag, dst.slot)
  -- Same-item landmine: dropping a stack onto a PARTIAL stack of the same item
  -- tops it up and leaves the remainder on the cursor instead of swapping.
  -- Put the remainder back where it came from; the recompute then sees two
  -- re-balanced stacks (and this quietly consolidates stacks as a bonus).
  if cursorBusy() then
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
local function sortTick()
  if not sort.active then return end
  local now = GetTime()
  local p = sort.pend
  if p then
    if slotLocked(p.sbag, p.sslot) or slotLocked(p.dbag, p.dslot) then
      p.sawLock = true -- the client ACCEPTED the call; this path is not gated
      return
    end
    local sigNow = slotSig(p.sbag, p.sslot) .. "|" .. slotSig(p.dbag, p.dslot)
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
      if cursorBusy() then cursorDrop() end
      if not p.sawLock and p.ctx == "onupdate" then
        sort.ctxFail = sort.ctxFail + 1
        if sort.ctxFail >= 2 then
          if sort.clickWorked then
            -- The one line that settles it: clicks move items, OnUpdate does
            -- not. Next rev = click-stepper.
            emit("sort", "gated ctx=onupdate")
          else
            -- No click swap ever landed either, so this is not proof of a
            -- context gate — say so rather than blame the wrong thing.
            emit("sort", "noeffect ctx=onupdate click=untested")
          end
          sortStop("gated")
          return
        end
      end
      -- Empirical specialty-bag detection: that destination bag refused the
      -- item. Drop it from the grid and carry on with the rest.
      if not sort.skipBag[p.dbag] then
        sort.skipBag[p.dbag] = true
        dtrace("sort skipping bag " .. p.dbag .. " (placement refused)")
      end
    else
      return -- still inside the settle window
    end
  end
  if not sort.active then return end
  if (now - sort.lastMoveAt) > SORT_TIMEOUT then
    sortAbort("stalled")
    return
  end
  sortIssue("onupdate")
end

local function sortStart()
  sort.seq = sort.seq + 1
  sort.active = true
  sort.moves = 0
  sort.pend = nil
  sort.ctxFail = 0
  sort.clickWorked = false
  sort.skipBag = {}
  sort.lastMoveAt = GetTime()
  sortSetLabel(true)
  dtrace("sort start #" .. sort.seq)
  -- The first swap goes out RIGHT HERE, still inside the mouse click, so the
  -- known-good hardware-event path is exercised before OnUpdate is trusted.
  sortIssue("click")
end

sortBtn = CreateFrame("Button", "ShadowBagsSortBtn", bagsFrame, "UIPanelButtonTemplate")
sortBtn:SetWidth(64)
sortBtn:SetHeight(20)
sortBtn:SetPoint("LEFT", bagsTitle, "RIGHT", 14, 0)
sortBtn:SetText("|cFFCCCCCCSort|r")
sortBtn:SetScript("OnClick", function()
  if sort.active then
    sortStop("cancel") -- re-click = cancel, and the label snaps back
    return
  end
  -- pcall: an error in here would die silently (scriptErrors is off) and the
  -- button would just look broken.
  local ok, err = pcall(sortStart)
  if not ok then
    emit("err", "sort start: " .. tostring(err))
    sortStop("error")
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
  bagsToggle()
end

-- The bag id is irrelevant now: there is one window and it holds every bag.
function ToggleBag(id)
  bagsToggle()
end

function OpenBackpack()
  bagsShow()
end

function CloseBackpack()
  bagsHide()
end

-- Called with the requesting frame (merchant/bank/trade) in vanilla; we do not
-- need it, but the parameter stays so the signature matches what callers pass.
function OpenAllBags(frame)
  bagsShow()
end

function CloseAllBags()
  bagsHide()
end

-- ToggleKeyRing is deliberately NOT hooked: the keyring is bag -2 and is not
-- in this grid, so it keeps using the Blizzard frame. Bank frames are likewise
-- untouched this rev — opening the bank shows this window (via OpenAllBags),
-- which is enough to click items across.

-- Escape closes it, like every other UI panel. UISpecialFrames is a list of
-- frame NAMES resolved with getglobal(), which is why the frame is named.
tinsert(UISpecialFrames, "ShadowBagsFrame")

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

local function lootSlotsLeft()
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

local function lootSweep()
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
  loot.lastSeen = lootSlotsLeft()
end

local function lootTick()
  local now = GetTime()
  if now < loot.nextTryAt then return end
  loot.nextTryAt = now + LOOT_RETRY_EVERY
  loot.lastSeen = lootSlotsLeft()
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
      emit("loot", "gated")
    end
    return
  end
  lootSweep()
end

local pendingReload = 0 -- countdown of escalation steps; 0 = idle
-- r11: every request gets a number so the ladder is traceable end to end, and
-- two reloads within emit()'s 30s identical-message window can never collapse
-- into one line.
local reloadSeq = 0

local driver = CreateFrame("Frame", "ShadowArmyDriver", UIParent)
driver:SetScript("OnUpdate", function()
  -- Sample position EVERY frame: rotationStep is skipped during GCD and
  -- failure-backoff windows, and a stale sample made a standing player read
  -- as "moving" (which blocks Shadow Bolt). Two float compares, negligible.
  updateMoving()
  emitDrain() -- paced outbound chat; see EMIT_GAP
  -- r12: keep Demon Skin/Armor up. Deliberately ABOVE the auto.enabled gate —
  -- it is a self-buff, not a fight, so it works whether or not auto-combat is
  -- on. pcall for the same reason as the rotation: a raw error here would
  -- silently kill the rest of this OnUpdate (loot retries, reload ladder).
  local aok, aerr = pcall(armorTick)
  if not aok then emit("err", "armorTick: " .. tostring(aerr)) end
  -- r13: bag autosort steps here (one swap in flight, lock-polled). Above the
  -- auto.enabled gate on purpose — sorting has nothing to do with combat — and
  -- pcall'd for the same reason armorTick is: a raw error would take the rest
  -- of this OnUpdate down with it, silently.
  if sort.active then
    local sok, serr = pcall(sortTick)
    if not sok then
      emit("err", "sortTick: " .. tostring(serr))
      pcall(sortStop, "error")
    end
  end
  if loot.active then lootTick() end
  if pendingReload > 0 then
    pendingReload = pendingReload - 1
    if pendingReload == 2 then
      -- pcall: if this build has no ReloadUI/ConsoleExec global, a raw call
      -- would raise and (scriptErrors off) silently kill the whole OnUpdate
      -- for that frame with zero telemetry. Report instead.
      dtrace("reload #" .. reloadSeq .. " step 1/3 ReloadUI()")
      local ok, err = pcall(ReloadUI) -- if this works we never reach step 2
      if not ok then emit("err", "ReloadUI: " .. tostring(err)) end
    elseif pendingReload == 1 then
      dtrace("reload #" .. reloadSeq .. " step 2/3 ConsoleExec(reloadui)")
      local ok, err = pcall(ConsoleExec, "reloadui")
      if not ok then emit("err", "ConsoleExec: " .. tostring(err)) end
    elseif pendingReload == 0 then
      emit("reload-click",
        "#" .. reloadSeq .. " auto paths no-op; button lit + next-press armed")
      panel:Show() -- the button lives in the panel; unhide if /sa'd away
      reloadBtn:Show()
      reloadArmed = true -- next out-of-combat action press applies it
    end
    return
  end
  if not auto.enabled then return end
  local ok, err = pcall(rotationStep)
  if not ok and err ~= auto.lastErr then
    auto.lastErr = err
    say("|cFFFF4444rotation error:|r " .. tostring(err))
    emit("err", "rotation: " .. tostring(err))
  end
end)

local acc = 0
panel:SetScript("OnUpdate", function()
  acc = acc + arg1
  if acc < 0.5 then return end
  acc = 0
  local xph, tta = grindStats()
  line1:SetText(string.format("lvl %d  %d/%d xp",
    UnitLevel("player"), UnitXP("player"), UnitXPMax("player")))
  line2:SetText(string.format("%d xp/h  |  level up in %s", xph, tta))
  local t1, t2 = targetSummary()
  line3:SetText(t1)
  line4:SetText(t2)
  line5:SetText(buffWatchLine())
end)

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

-- Instant quest text, 1.12 style: there is no CVar for this (that arrived
-- post-vanilla). The quest/gossip text crawl is QuestFrame's type-out
-- effect; the classic fix is hooking the scroll frames' OnShow to call
-- the "text finished" path immediately. QuestFrameDetailPanel shows quest
-- description; QuestFrameProgressPanel the turn-in text.
local function instantQuestText()
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
    scanSpellbook()
    -- QoL defaults the advisor asserts on every login:
    -- instantQuestText() DISABLED (r14): prime remaining suspect for the
    -- reproducible crash+lockup on Complete Quest (it nils the quest
    -- panels' OnUpdate — exactly the surface involved in that click). The
    -- fanfare mute didn't take (music still played), so this is the next
    -- single-variable test. Re-enable only after turn-ins are proven safe.
    say("ARISE. Advisor online for " .. UnitName("player") .. " — /sa to toggle panel")
    emit("loaded", "rev=" .. REV)
  elseif event == "LEARNED_SPELL_IN_TAB" then
    scanSpellbook()
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
    dtrace("cast failed/interrupted — 0.5s backoff")
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
    loot.startSlots = lootSlotsLeft()
    loot.lastSeen = loot.startSlots
    loot.nextTryAt = GetTime() + LOOT_RETRY_EVERY
    dtrace("loot opened slots=" .. tostring(GetNumLootItems())
      .. " items=" .. loot.startSlots)
    lootSweep() -- first attempt now; the driver retries for ~2s after this
  elseif event == "LOOT_SLOT_CLEARED" then
    -- Keeps lastSeen honest when the window empties and auto-closes inside
    -- a single retry interval.
    loot.lastSeen = lootSlotsLeft()
  elseif event == "LOOT_CLOSED" then
    loot.active = false
    if loot.startSlots > 0 then
      -- The one line that settles "do these calls do anything at all".
      emit("loot", "result took=" .. (loot.startSlots - loot.lastSeen)
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
    dtrace("sys rx [" .. cmd .. "]")
    local _, _, verb, rest = string.find(cmd, "^(%S+)%s*(.*)$")
    if not verb then
      emit("err", "sys unparsed: [" .. cmd .. "]")
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
      -- #N makes each request unique so emit()'s 30s dedupe can't swallow a
      -- retry, and pairs this line with its reload-click.
      reloadSeq = reloadSeq + 1
      emit("reloading", "#" .. reloadSeq .. " from-rev=" .. REV)
      pendingReload = 3 -- escalation ladder runs on the driver; see above
    elseif verb == "ping" then
      emit("pong", "rev=" .. REV)
    elseif verb == "debug" then
      debugMode = (rest ~= "off")
      emit("debug", debugMode and "on" or "off")
    elseif verb == "status" then
      local xph = grindStats()
      emit("status", string.format("lvl=%d hp=%d/%d zone=%s xph=%d",
        UnitLevel("player"), UnitHealth("player"), UnitHealthMax("player"),
        GetZoneText(), xph))
    elseif verb == "say" then
      say(rest)
    else
      emit("err", "unknown sys command: " .. verb)
    end
  end
end)

--------------------------------------------------------------------------
-- /sa — toggle panel; /sa reload — live iteration; /sa status — chat dump.
--------------------------------------------------------------------------

SLASH_SHADOWARMY1 = "/sa"
SlashCmdList["SHADOWARMY"] = function(msg)
  if msg == "reload" then
    ReloadUI()
    return
  end
  -- Manual valve for the bag window: if the global takeover ever fails to
  -- take (another addon loading after us and re-replacing ToggleBackpack),
  -- this still opens it.
  if msg == "bags" then
    bagsToggle()
    return
  end
  if msg == "log" then
    if logFrame:IsVisible() then logFrame:Hide() else logFrame:Show() end
    return
  end
  if msg == "status" then
    local hp = UnitHealth("player")
    local hpMax = UnitHealthMax("player")
    local xph, tta = grindStats()
    say(string.format("%s — lvl %d, %d/%d hp, %s | %d xp/h, level in %s",
      UnitName("player"), UnitLevel("player"), hp, hpMax, GetZoneText(), xph, tta))
    return
  end
  if panel:IsVisible() then
    panel:Hide()
  else
    panel:Show()
  end
end
