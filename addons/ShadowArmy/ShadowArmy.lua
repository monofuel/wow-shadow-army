-- ShadowArmy — hello world stage.
-- 1.12 (Lua 5.0) addon: no protected functions, vararg via arg table,
-- event args via global event/arg1. Keep everything addon-local except
-- the single ShadowArmy root.

ShadowArmy = ShadowArmy or {}

local function say(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cFF9482C9[ShadowArmy]|r " .. tostring(msg))
end

-- Event wiring: one hidden frame, one dispatcher.
local frame = CreateFrame("Frame", "ShadowArmyFrame", UIParent)
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

frame:SetScript("OnEvent", function()
  if event == "PLAYER_ENTERING_WORLD" then
    say("ARISE. (hello world — addon loaded for " .. UnitName("player") .. ")")
  end
end)

-- /sa — prove slash commands + live state reads work.
SLASH_SHADOWARMY1 = "/sa"
SlashCmdList["SHADOWARMY"] = function(msg)
  if msg == "reload" then
    ReloadUI() -- the live-iteration loop in one word
    return
  end
  local hp = UnitHealth("player")
  local hpMax = UnitHealthMax("player")
  local level = UnitLevel("player")
  local zone = GetZoneText()
  say(string.format("%s — level %d, %d/%d hp, %s",
    UnitName("player"), level, hp, hpMax, zone))
  if msg ~= "" then
    say("(args: " .. msg .. ")")
  end
end
