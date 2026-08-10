# Lua API notes — 1.12.1 / 5875 (practical)

Not a full FrameXML dump. Signatures and traps we hit in
`addons/ShadowArmy/ShadowArmy.lua`, plus a few stock FrameXML facts.
When unsure, check 1.12.1 FrameXML or probe in-game — do not copy retail
Wowpedia blindly.

Hardware-event gates: [addon-system.md](addon-system.md#hardware-event-gate-not-securetemplates).

---

## Units

Common unit tokens: `"player"`, `"target"`, `"pet"`, `"party1"`…`"party4"`,
`"raidN"`, `"mouseover"` (where supported).

Useful checks (all used by ShadowArmy):

| API | Notes |
|---|---|
| `UnitExists(u)` | |
| `UnitName(u)` | |
| `UnitLevel(u)` | |
| `UnitHealth` / `UnitHealthMax` | |
| `UnitMana` / `UnitManaMax` | mana/energy/rage pool for that unit’s power type |
| `UnitIsDeadOrGhost(u)` | |
| `UnitIsGhost(u)` | |
| `UnitCanAttack("player", u)` | hostile check |
| `UnitXP` / `UnitXPMax` / `UnitLevel("player")` | grind stats |

No `IsMoving()` on 1.12 — sample `GetPlayerMapPosition("player")` over time
and treat position deltas as movement (ShadowArmy `F.updateMoving`).

---

## Buffs / debuffs (texture-first world)

### Player buffs

```lua
-- filter tokens (FrameXML BuffFrame): HELPFUL | HARMFUL | CANCELABLE | NOT_CANCELABLE
local buffIndex, untilCancelled = GetPlayerBuff(i, "HELPFUL")
-- invalid buffIndex is < 0 (BuffFrame skips those)
if buffIndex < 0 then return end
local tex = GetPlayerBuffTexture(buffIndex)
local left = GetPlayerBuffTimeLeft(buffIndex)
-- cancel: CancelPlayerBuff(buffIndex)  -- BuffFrame right-click path
```

Indices are small and bounded (ShadowArmy treats helpful buffs as roughly
`0..31` and hard-stops loops). Prefer texture match over names — names are
not reliably exposed the way modern `UnitAura` is.

### Target debuffs

```lua
-- 1.12 (TargetFrame / FrameXML): texture first; names not exposed like UnitAura.
local tex, applications, debuffType = UnitDebuff("target", i)
```

ShadowArmy matches Corruption via icon path
`Interface\\Icons\\Spell_Shadow_AbominationExplosion`, not the string
`"Corruption"`.

`PLAYER_AURAS_CHANGED` fires when player auras change; do not assume a rich
aura-id API.

---

## Spellbook and casting

```lua
local name = GetSpellName(i, "spell")  -- nil when past end
CastSpellByName("Shadow Bolt")        -- exact localized name
UseAction(slot)                       -- action bar slot
```

Patterns:

- Scan spellbook once on `PLAYER_ENTERING_WORLD` / `LEARNED_SPELL_IN_TAB`
  into a lowercase set; never cast a name that is not trained.
- Wand / Auto Shot: watch `START_AUTOREPEAT_SPELL` /
  `STOP_AUTOREPEAT_SPELL` — casting Shoot again **toggles** the repeat off.
- Melee auto-attack: `PLAYER_ENTER_COMBAT` / `PLAYER_LEAVE_COMBAT`; ability
  name is typically `"Attack"` (locale-dependent on non-enUS clients).
- Cast window: `SPELLCAST_START` / `STOP` / `FAILED` / `INTERRUPTED`.

Stock chat path `/cast` / `/spell` is also just `CastSpellByName`
([chat-commands.md](chat-commands.md)).

**There is no `/cancelform`.** Leave forms by casting the form spell again
or another form; water form swaps are often automatic
([chat-commands.md](chat-commands.md#how-to-leave-a-form--stance--stealth)).

---

## Range

`CheckInteractDistance(unit, index)` — stock indices (client C distances;
yards are approximate folklore, not FrameXML constants):

| Index | Meaning (usual vanilla table) | ~yards |
|---|---|---|
| 1 | Inspect | ~28 |
| 2 | Trade | ~11 |
| 3 | Duel | ~10 |
| 4 | Follow | ~28 |

```lua
CheckInteractDistance("target", 3)  -- ~10 yd (duel)
CheckInteractDistance("target", 4)  -- ~28 yd (follow)
```

ShadowArmy uses 3/4 as near/far coach buckets. No modern `IsSpellInRange`
suite you should assume without probing.

---

## Map / corpse / party blips

| API | Notes |
|---|---|
| `GetPlayerMapPosition(unit)` | Returns map **fractions**; `(0,0)` often means unknown / wrong map / other zone |
| `SetMapToCurrentZone()` | Fix map when position is 0,0 and world map is not open |
| `GetCorpseMapPosition()` | Own corpse; `(0,0)` if none / wrong surface |
| `GetZoneText()` | Zone name string |

Zone yard sizes are **not** exposed — ShadowArmy uses tunable yards-per-%
for distance estimates. No dependable `IsIndoors()`.

Party *corpses* in other places are not a separate API; ghost unit map
position is what you get while they are released.

---

## Bags / items

| API | Notes |
|---|---|
| `GetContainerNumSlots(bag)` | |
| `GetContainerItemLink(bag, slot)` | |
| `GetContainerItemInfo(bag, slot)` | texture, count, locked, quality, readable — verify order if you touch it |
| `PickupContainerItem(bag, slot)` | cursor; hardware-gated in some contexts |
| `GetItemInfo(linkOrId)` | **Often nil until the client has cached the item** — never assume cold cache |
| `CursorHasItem()` | |

`SetPoint` on bag buttons: clear anchors first. Quality colors exist on
FrameXML globals in principle; ShadowArmy uses local tables to avoid
depending on load order.

---

## Loot

```lua
GetNumLootItems()
LootSlot(i)
ConfirmLootSlot(i)  -- when needed
```

Vanilla has **no** always-auto-loot CVar (that is later expansions).
`LootSlot` is not retail-style SecureTemplate-protected, but on **this wine
5875 seat** probe results were harsh: **Click / Frame / Delay all failed**
for bulk `LootSlot` (`docs/advisor-sandbox-gates.md`, autopilot appendix).
ShadowArmy still attempts vacuum + retry on `LOOT_OPENED` as a heuristic —
that is not proof of a free loot API.

---

## Quest log

```lua
-- GetQuestLogTitle-style returns (1.12):
-- title, level, questTag, isHeader, isCollapsed, isComplete
```

**No quest IDs** for addons on 1.12 — match by **exact title** string.
Headers collapse/expand; selection can move under you. Instant quest text
is not a CVar (later feature); FrameXML type-out hacks are fragile
(ShadowArmy disabled its instant-text hook after turn-in crash suspicion).

---

## Chat I/O

```lua
SendChatMessage(msg, "SAY")      -- also "PARTY", "GUILD", "WHISPER", ...
SendChatMessage(msg, "WHISPER", nil, targetName)
```

Inbound:

| Event | Typical use |
|---|---|
| `CHAT_MSG_SAY` / `PARTY` / … | Visible chat |
| `CHAT_MSG_SYSTEM` | GM announce / system — The System uses `<SYS> …` |

Strip color codes before parsing (`|cAARRGGBB` … `|r`). Never `loadstring`
arbitrary chat. ShadowArmy whitelists verbs: `reload`, `ping`, `debug`,
`status`, `say`, `admin` (display only).

`SendAddonMessage` exists in 1.12 for hidden addon channels (CTRA-era); our
command-channel design prefers **visible** party chat on purpose
([../command-channel.md](../command-channel.md)).

---

## UI helpers

| API | Notes |
|---|---|
| `CreateFrame(type, name, parent, template?)` | |
| `UIParent` | |
| `ReloadUI()` | May no-op off hardware event |
| `GetTime()` | Seconds; use for throttles |
| `GetMoney()` | Copper |
| `pcall(fn, ...)` | |

Templates used by ShadowArmy: `UIPanelButtonTemplate`,
`UIPanelCloseButton`, `ScrollingMessageFrame` for logs.

---

## Patterns from ShadowArmy (where to look)

All paths under `addons/ShadowArmy/ShadowArmy.lua` unless noted.

| Concern | Pattern |
|---|---|
| Root global | `ShadowArmy = ShadowArmy or {}`; helpers on `F` to dodge 200-local limit |
| Rev / live reload proof | `REV = "rNN"`; emit `loaded rev=` on enter world |
| Spell gate | `F.scanSpellbook` + lowercase map |
| Debuff check | texture constant vs `UnitDebuff` |
| Move detect | map position delta, 0.3s settle |
| Combat coach | L0 only — buttons call cast on **click** |
| API probe | click vs next-frame vs delay0.5 modes; verdict OK/GATED |
| Slash | `SLASH_SHADOWARMY1 = "/sa"` + `SlashCmdList["SHADOWARMY"]` |
| System bus | `CHAT_MSG_SYSTEM` + `<SYS>` whitelist; outbound `SendChatMessage` SAY |
| Bags takeover | replace `ToggleBackpack`-style entry points carefully |
| Map markers | create textures once; `ClearAllPoints` before move |

TOC: `addons/ShadowArmy/ShadowArmy.toc` (`Interface: 11200`).

---

## What not to invent

- Retail `C_*` namespaces, `UnitAura` id/name packs, `SecureActionButton`,
  `InCombatLockdown`, focus unit, `/cancelform`, castsequence, macro
  conditionals.
- Assuming `ReloadUI` / `CastSpellByName` always work from timers.
- Quest IDs, reliable `GetItemInfo` without cache, `IsMoving()`, zone size
  API.

When an API is missing, **document the gap** and keep the advisor at L0 —
do not paper over with cheats (AGENTS.md).
