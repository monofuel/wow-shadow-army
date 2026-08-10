# Addon system — 1.12.1 / 5875

How addons load and run on the vanilla client monofuel plays
(`make play-classic`). Product policy for *our* advisor (L0 only, no
actuation growth) lives in [../advisor-autopilot.md](../advisor-autopilot.md).

## Layout

```
Interface/AddOns/<AddonName>/
  <AddonName>.toc
  *.lua
  (optional textures, etc.)
```

Repo source of truth for the human-seat advisor: `addons/ShadowArmy/`.
`tools/play_classic.sh` symlinks each `addons/*` into
`local_classic/client/Interface/AddOns/` on launch — edit the repo tree,
not a hand-copied client copy.

## TOC

Minimal example (see `addons/ShadowArmy/ShadowArmy.toc`):

```
## Interface: 11200
## Title: My Addon
## Notes: short description
## Version: 0.1.0
## SavedVariables: MyAddonDB
## SavedVariablesPerCharacter: MyAddonCharDB

Core.lua
More.lua
```

- **`Interface: 11200`** — 1.12.x interface version. Wrong major numbers get
  “out of date” treatment; we pin 11200 for 5875.
- File list order = load order.
- **TOC file list is cached for the whole client session.** Adding a *new*
  `.lua` filename (or renaming) needs a **full client restart** once so the
  TOC is rescanned. Pure edits to already-listed files can reload.
- Optional data files that may fail to parse should load *after* core UI so
  a bad data load does not kill slash commands / panels (ShadowArmy loads
  `QuestData.lua` second for this reason).

## Lua version: 5.0 only

| Do | Don't |
|---|---|
| `table.getn(t)` or walk `t[i]` until nil | `#t` (Lua 5.1+) |
| varargs via global `arg` / `arg.n` | `...` as in 5.1+ |
| `string.find` / `string.gsub` / `string.format` | assume modern `string.match` style APIs without checking |
| keep locals under the **200 locals per function** hard limit | giant monofunctions (ShadowArmy parks helpers on a table `F`) |
| `pcall(fn, arg1, arg2)` around flaky UI calls | assume every API always exists; do not write Lua 5.1 `function(...)` vararg style |

`ShadowArmy.lua` header restates the contract: event args via globals
`event` / `arg1`…, keep everything addon-local except one root global.

## Frames and scripts

```lua
local f = CreateFrame("Frame", "MyAddonFrame", UIParent)
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function()
  -- event, arg1, arg2, ... are GLOBALS in 1.12, not parameters
  if event == "PLAYER_ENTERING_WORLD" then
    -- ...
  end
end)
f:SetScript("OnUpdate", function()
  -- arg1 = elapsed seconds this frame
end)
```

- Script handlers see **`this`** as the widget (not an implicit `self`
  argument unless you wrap it).
- **`SetPoint` accumulates anchors.** Always `ClearAllPoints()` before
  re-anchoring, or layouts stack garbage.
- Frames (and their textures/fontstrings) are **not destroyable** — create
  once, hide/pool, reuse.
- `OnUpdate` every frame is expensive; throttle with an accumulator
  (ShadowArmy panel refreshes at ~0.5s).

## Events worth knowing (names differ from modern)

Vanilla uses older spell/combat event names, for example:

- `SPELLCAST_START` / `SPELLCAST_STOP` / `SPELLCAST_FAILED` /
  `SPELLCAST_INTERRUPTED` / `SPELLCAST_DELAYED`
- `SPELLCAST_CHANNEL_START` / `SPELLCAST_CHANNEL_UPDATE` /
  `SPELLCAST_CHANNEL_STOP` (channeling; see FrameXML CastingBarFrame)
- `START_AUTOREPEAT_SPELL` / `STOP_AUTOREPEAT_SPELL` (wand / auto-shot loop)
- `PLAYER_ENTER_COMBAT` / `PLAYER_LEAVE_COMBAT` (melee auto-attack swing)
- `CHAT_MSG_SYSTEM` (GM `announce` / system lines)
- `LOOT_OPENED` / `LOOT_SLOT_CLEARED` / `LOOT_CLOSED`
- `PLAYER_AURAS_CHANGED`, `BAG_UPDATE`, `WORLD_MAP_UPDATE`, …

There is **no** modern `UNIT_SPELLCAST_*` suite on this client.

## Hardware-event gate (not SecureTemplates)

1.12 does **not** ship the retail Secure* / full taint lockdown model. Many
action APIs still check that the call came from a **hardware event**
(keybind, mouse click on a button). Calls from pure `OnUpdate`, delayed
timers, or some chat/system paths can **silently no-op**.

Observed on our wine 5875 seat (advisor **Probe** panel — see
`docs/advisor-sandbox-gates.md`, autopilot appendix):

| Call | Click / keybind | Software timer / bare OnUpdate |
|---|---|---|
| `CastSpellByName` | works (armor probe) | gated |
| `ReloadUI` | works | gated (returns without reloading) |
| `LootSlot` (bulk loot) | **does not** (panel click insufficient) | **does not** |

Implications:

- Vanilla ShadowArmy is **L0 instruments** — suggestions and UI, not a
  full rotation bot (`docs/advisor-autopilot.md`).
- Combat coach buttons exist so the human click *is* the hardware event.
- Remote reload escalates: try free `ReloadUI` → show **Reload!** button →
  arm next action-bar keypress. See AGENTS.md “Shadow Advisor — live update”
  and [../the-system-loop.md](../the-system-loop.md).

Do not “solve” gates with random unlockers (`docs/advisor-unlock.md` is
research-only, not pursuing).

## No network / no files from Lua

Addons cannot open sockets, HTTP, or arbitrary filesystem I/O. The only
live loop we have is **chat**:

- Out: `SendChatMessage(..., "SAY")` → server `Chat.log` → The System
- In: SOAP GM `announce` → `CHAT_MSG_SYSTEM` → whitelist parser

Detail: [../the-system-loop.md](../the-system-loop.md).

## Registering a slash command (addons)

```lua
SLASH_MYADDON1 = "/myaddon"
SLASH_MYADDON2 = "/ma"   -- optional alias
SlashCmdList["MYADDON"] = function(msg)
  msg = string.gsub(msg or "", "^%s+", "")
  msg = string.gsub(msg, "%s+$", "")
  -- msg is the text AFTER the slash command
end
```

The key in `SlashCmdList` is the token after `SLASH_`, not the chat string.
Stock commands use the same mechanism (FrameXML); see
[chat-commands.md](chat-commands.md).

## Reload paths

| Path | When |
|---|---|
| Edit listed `.lua`, then reload UI | Daily iteration |
| New TOC entry / new addon folder | Full client restart once |
| `/console reloadui` or `ReloadUI()` | Dev / power-user; may be gated off hardware |
| System `reload_addon` / `<SYS> reload` | Preferred agent path during `play-classic` |

Bump a `REV` string and emit a `loaded rev=…` chat line if you need proof
the new code is live (ShadowArmy pattern).

## SavedVariables

- `## SavedVariables: Foo` — account-wide, loaded before addon code as global
  `Foo` (may be nil first run — initialize in `ADDON_LOADED` /
  `PLAYER_LOGIN` style handlers if you use them).
- `## SavedVariablesPerCharacter: Bar` — per character.
- Writes flush on clean logout / reload; do not treat mid-session mutation
  as durable until then.
