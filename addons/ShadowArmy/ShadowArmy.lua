-- ShadowArmy — advisor v0.1: draggable HUD panel (grind stats + target
-- intel + action buttons) on top of the hello-world plumbing.
-- 1.12 (Lua 5.0) addon: no protected functions, vararg via arg table,
-- event args via global event/arg1/arg2. Keep everything addon-local
-- except the single ShadowArmy root.

ShadowArmy = ShadowArmy or {}

-- Bump on every edit. The System watches Chat.log for "<SA> loaded rev=..."
-- after sending a reload — a new rev proves the edit actually loaded.
local REV = "r5"

local function say(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cFF9482C9[ShadowArmy]|r " .. tostring(msg))
end

-- /say lands in the server's Chat.log; The System tails it. This is
-- the addon's only outbound channel.
local lastEmitMsg, lastEmitTime = nil, 0
local function emit(kind, text)
  local msg = "<SA> " .. kind .. " " .. text
  local now = GetTime()
  if msg == lastEmitMsg and (now - lastEmitTime) < 30 then
    return
  end
  lastEmitMsg = msg
  lastEmitTime = now
  SendChatMessage(msg, "SAY")
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
  gcdUntil = 0,      -- our own 1.6s guard after any cast request
  shooting = false,  -- wand auto-repeat active (don't re-toggle it off!)
  melee = false,     -- auto-attack swing loop active
  known = {},        -- lowercase spell name -> true
}

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
  CastSpellByName(spell)
  auto.gcdUntil = GetTime() + 1.6
end

local function rotationStep()
  if not auto.enabled then return end
  if not UnitExists("target") then return end
  if UnitIsDeadOrGhost("target") or not UnitCanAttack("player", "target") then return end
  if auto.casting or GetTime() < auto.gcdUntil then return end

  local manaPct = 0
  if UnitManaMax("player") > 0 then
    manaPct = UnitMana("player") / UnitManaMax("player") * 100
  end
  local inCastRange = CheckInteractDistance("target", 4)  -- ~28yd

  -- Priority: DoT up -> nuke while mana holds -> wand -> melee.
  if inCastRange and auto.known["corruption"] and manaPct > 25
      and not targetHasDebuff(CORRUPTION_TEX) then
    castNow("Corruption")
    return
  end
  if inCastRange and auto.known["shadow bolt"] and manaPct > 30 then
    castNow("Shadow Bolt")
    return
  end
  if inCastRange and auto.known["shoot"] and not auto.shooting then
    -- wand toggle: casting Shoot while already repeating would turn it OFF
    CastSpellByName("Shoot")
    return
  end
  if not auto.melee and CheckInteractDistance("target", 3) then
    AttackTarget()
  end
end

local function setAuto(on)
  auto.enabled = on
  local label = on and "|cFF44FF44Auto: ON|r" or "Auto: OFF"
  ShadowArmyAutoBtn:SetText(label)
  say(on and "auto-combat ON — target something and watch"
        or "auto-combat OFF — back to manual")
  -- /say lands in the server's Chat.log, labeling the breadcrumb corpus:
  -- everything between ON/OFF markers is addon play, not human play.
  emit("auto", on and "ON" or "OFF")
end

local autoBtn = CreateFrame("Button", "ShadowArmyAutoBtn", panel, "UIPanelButtonTemplate")
autoBtn:SetWidth(110)
autoBtn:SetHeight(20)
autoBtn:SetPoint("BOTTOM", panel, "BOTTOM", 0, 8)
autoBtn:SetText("Auto: OFF")
autoBtn:SetScript("OnClick", function()
  setAuto(not auto.enabled)
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

local lastNag = 0
local function buffWatchLine()
  local warnings = nil
  for _, watch in ipairs(WATCHED_BUFFS) do
    local left = buffTimeLeftByTexture(watch.textures)
    local warn
    if not left then
      warn = string.format("|cFFFF4444%s MISSING|r", watch.label)
    elseif left < watch.warnBelow then
      warn = string.format("|cFFFFAA00%s %dm left|r", watch.label, math.ceil(left / 60))
    end
    if warn then
      warnings = warnings and (warnings .. "  " .. warn) or warn
    end
  end
  if warnings and (GetTime() - lastNag) > 60 then
    lastNag = GetTime()
    say("buff watch: " .. warnings) -- chat nag at most once a minute
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

-- Rotation driver lives on its OWN always-shown frame — NOT the panel.
-- (OnUpdate only fires for visible frames; hiding the panel via /sa must
-- not kill auto-combat.) pcall so a rotation bug reports instead of
-- dying silently when scriptErrors is off.
-- Deferred remote reload: live findings — ReloadUI() and
-- ConsoleExec("reloadui") are both silently no-ops from a CHAT_MSG_SYSTEM
-- handler (r2) and from a deferred OnUpdate frame (r3/r4), while the same
-- call from the /sa slash handler works. Working theory: this client gates
-- programmatic UI reload on hardware-event context (the slash path starts
-- from a keypress). r5: still try the free paths (combat may have been a
-- confound), then fall back to a one-click reload button — a mouse click IS
-- a hardware event, so ReloadUI from its OnClick works like the slash path.
local pendingReload = 0 -- countdown of escalation steps; 0 = idle
local reloadBtn -- created lazily on first fallback

local function showReloadButton()
  if not reloadBtn then
    reloadBtn = CreateFrame("Button", "ShadowArmyReloadBtn", UIParent,
      "UIPanelButtonTemplate")
    reloadBtn:SetWidth(220)
    reloadBtn:SetHeight(28)
    reloadBtn:SetPoint("TOP", UIParent, "TOP", 0, -140)
    reloadBtn:SetText("|cFF9482C9ShadowArmy:|r click to finish reload")
    reloadBtn:SetScript("OnClick", function()
      ReloadUI()
    end)
  end
  reloadBtn:Show()
end

local driver = CreateFrame("Frame", "ShadowArmyDriver", UIParent)
driver:SetScript("OnUpdate", function()
  if pendingReload > 0 then
    pendingReload = pendingReload - 1
    if pendingReload == 2 then
      ReloadUI() -- if this works we never reach the next step
    elseif pendingReload == 1 then
      ConsoleExec("reloadui")
    elseif pendingReload == 0 then
      emit("reload-click", "auto paths no-op; showing one-click button")
      showReloadButton()
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

frame:SetScript("OnEvent", function()
  if event == "PLAYER_ENTERING_WORLD" then
    grind.startTime = GetTime()
    grind.startXP = UnitXP("player")
    scanSpellbook()
    -- QoL defaults the advisor asserts on every login:
    instantQuestText() -- no slow quest-text crawl (no CVar for this in 1.12)
    say("ARISE. Advisor online for " .. UnitName("player") .. " — /sa to toggle panel")
    emit("loaded", "rev=" .. REV)
  elseif event == "LEARNED_SPELL_IN_TAB" then
    scanSpellbook()
  elseif event == "SPELLCAST_START" then
    auto.casting = true
  elseif event == "SPELLCAST_STOP" or event == "SPELLCAST_FAILED"
      or event == "SPELLCAST_INTERRUPTED" then
    auto.casting = false
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
    local _, _, verb, rest = string.find(cmd, "^(%S+)%s*(.*)$")
    if not verb then return end
    verb = string.lower(verb)
    if verb == "reload" then
      -- "reloading" without a following "loaded" = the reload never ran.
      emit("reloading", "rev=" .. REV)
      pendingReload = 3 -- escalation ladder runs on the driver; see above
    elseif verb == "ping" then
      emit("pong", "rev=" .. REV)
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
