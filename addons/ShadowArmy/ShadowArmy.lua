-- ShadowArmy — advisor v0.1: draggable HUD panel (grind stats + target
-- intel + action buttons) on top of the hello-world plumbing.
-- 1.12 (Lua 5.0) addon: no protected functions, vararg via arg table,
-- event args via global event/arg1/arg2. Keep everything addon-local
-- except the single ShadowArmy root.

ShadowArmy = ShadowArmy or {}

local function say(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cFF9482C9[ShadowArmy]|r " .. tostring(msg))
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
panel:SetHeight(150)
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

-- Buttons: Tab-target nearest enemy, and attack current target.
-- 1.12 has no protected functions — these are legal addon calls.
local targetBtn = CreateFrame("Button", "ShadowArmyTargetBtn", panel, "UIPanelButtonTemplate")
targetBtn:SetWidth(90)
targetBtn:SetHeight(20)
targetBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 8)
targetBtn:SetText("Nearest foe")
targetBtn:SetScript("OnClick", function()
  TargetNearestEnemy()
end)

local attackBtn = CreateFrame("Button", "ShadowArmyAttackBtn", panel, "UIPanelButtonTemplate")
attackBtn:SetWidth(90)
attackBtn:SetHeight(20)
attackBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 8)
attackBtn:SetText("Attack")
attackBtn:SetScript("OnClick", function()
  if UnitExists("target") and UnitCanAttack("player", "target") then
    AttackTarget()
  else
    say("no attackable target — try Nearest foe first")
  end
end)

--------------------------------------------------------------------------
-- Live refresh: event-driven where possible, plus a 0.5s tick for the
-- clock-ish lines. Range bucket via CheckInteractDistance (1.12 addons
-- get no world coordinates for other units — buckets are what we have).
--------------------------------------------------------------------------

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
end)

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

local frame = CreateFrame("Frame", "ShadowArmyFrame", UIParent)
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

frame:SetScript("OnEvent", function()
  if event == "PLAYER_ENTERING_WORLD" then
    grind.startTime = GetTime()
    grind.startXP = UnitXP("player")
    say("ARISE. Advisor online for " .. UnitName("player") .. " — /sa to toggle panel")
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
