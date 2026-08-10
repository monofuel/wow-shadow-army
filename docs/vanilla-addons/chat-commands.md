# Chat and slash commands — 1.12.1 / 5875

Stock commands only. Source: 1.12.1 FrameXML `GlobalStrings.lua` (`SLASH_*`)
and `ChatFrame.lua` (`SlashCmdList`). Readable dump:
[Gethe/wow-ui-source `1.12.1`/FrameXML](https://github.com/Gethe/wow-ui-source/tree/1.12.1/FrameXML).

Addon-registered commands (`/sa`, …) are separate — see
[addon-system.md](addon-system.md#registering-a-slash-command-addons).

---

## Not in 1.12.1 — do not use

These appear constantly in modern macro docs and in AI output. **They are
not stock commands on 5875.** There is no `SLASH_*` entry and no
`SlashCmdList` handler for them in 1.12.1 FrameXML.

| Hallucinated command | Reality |
|---|---|
| **`/cancelform`** | **Invalid. Does not exist. Never emit it in macros, bots, docs, or advisor tips.** |
| `/cancelaura` | Invalid |
| `/castsequence` | Invalid |
| `/startattack` | Invalid |
| `/stopattack` | Invalid |
| `/stopcasting` | Invalid |
| `/dismount` | Invalid as a slash |
| `/use` | Invalid as stock slash (use `/cast` / `/spell`) |
| `/equip` | Invalid as stock slash |
| `/focus` | Invalid (no focus frame unit) |
| `/click` | Invalid |
| Macro options `[form:1]`, `[combat]`, `[mod:shift]`, `@target`, etc. | Post-vanilla |

### How to leave a form / stance / stealth

1. **Druid forms / stealth / similar toggles:** re-cast the **same** ability
   to leave, or cast a different form to switch.
2. **Warrior stances (and most stance bars):** leave by casting **another**
   stance — do not assume re-casting the current stance “unstanced” you the
   way a druid form toggle does.
3. **Travel Form ↔ water (play-observed on our realm, not a FrameXML
   constant):** client **auto-cancels** Travel on enter water and Aquatic on
   exit. No cancel slash, no shore ritual (`docs/traverse/petrel-plan.md`,
   `docs/traverse/traverse-2026-08-06.md`).
4. **Buff cancel from UI:** buff buttons call `CancelPlayerBuff` on click
   (FrameXML `BuffFrame.lua`) — that is not `/cancelform`.

If something “needs cancelform,” the design is wrong for 5875.

---

## How stock slashes work

1. Player types `/cast Corruption` (or a macro line).
2. Client uppercases the first token, looks up `SLASH_<NAME>n` globals for
   a match (`SLASH_CAST1 = "/cast"`, `SLASH_CAST2 = "/spell"`, …).
3. Dispatches `SlashCmdList["CAST"](msg)` with `msg` = remainder
   (`"Corruption"`).

`/cast` and `/spell` both call:

```lua
CastSpellByName(msg)
```

(ChatFrame `SlashCmdList["CAST"]`.)

---

## Chat channels

| Command aliases | Role |
|---|---|
| `/s`, `/say` | Say |
| `/y`, `/yell`, `/sh`, `/shout` | Yell |
| `/p`, `/party` | Party |
| `/g`, `/gc`, `/gu`, `/guild` | Guild |
| `/o`, `/osay` | Officer |
| `/ra`, `/raid`, `/rsay` | Raid |
| `/rw` | Raid warning |
| `/bg`, `/battleground` | Battleground |
| `/w`, `/whisper`, `/tell`, `/t`, `/send` | Whisper (need name) |
| `/r`, `/reply` | Reply last tell |
| `/e`, `/em`, `/emote`, `/me` | Emote text |
| `/v` | Voice macro |
| `/c`, `/csay` | Numbered chat channel say |

Channel management: `/join` `/channel` `/chan`, `/leave` `/chatleave`
`/chatexit`, `/chatlist` `/chatwho` `/chatinfo`, plus mute/mod/owner/password
family (`/mute`, `/mod`, `/owner`, `/password`, …).

---

## Targeting, follow, social

| Aliases | Effect |
|---|---|
| `/target`, `/tar` | Target unit/name |
| `/assist`, `/a` | Assist target (or named unit) |
| `/follow`, `/f`, `/fol` | Follow target |
| `/i`, `/inv`, `/invite` | Party invite |
| `/uninvite`, `/u`, `/un`, `/kick` | Remove from party |
| `/promote`, `/pr` | Promote party leader |
| `/inspect`, `/ins` | Inspect |
| `/trade`, `/tr` | Trade |
| `/who` | Who list |
| `/friends`, `/friend` | Friends |
| `/removefriend`, `/remfriend` | Remove friend |
| `/ignore` / `/unignore` | Ignore list |
| `/duel` | Duel |
| `/concede`, `/forfeit`, `/yield` | Forfeit duel |
| `/readycheck` | Ready check (raid leader) |

Guild ops: `/ginvite`, `/gremove`, `/gpromote`, `/gdemote`, `/gleader`,
`/gmotd`, `/gquit`, `/gdisband`, `/ginfo`, `/groster`, `/ghelp`,
`/glist`/`/gwho`/`/whoguild`, `/saveguildroster`.

---

## Combat-adjacent stock commands

| Aliases | Effect |
|---|---|
| **`/cast`, `/spell`** | **`CastSpellByName`** — the stock ability/item-by-name path |
| `/pvp` | Toggle PvP desired flag |
| `/ffa` | Loot: free-for-all |
| `/roundrobin` | Loot: round robin |
| `/master` | Loot: master looter |

There is **no** stock `/startattack`. Melee auto-attack is the **Attack**
ability / action bar (addons use `CastSpellByName("Attack")` or
`UseAction` on the Attack slot — still subject to hardware-event gates).

---

## Utility

| Aliases | Effect |
|---|---|
| `/script`, `/run` | Run Lua (security/gate caveats still apply to many APIs) |
| `/macro`, `/m` | Open macro UI |
| `/macrohelp` | Macro help text |
| `/console` | Console command (`/console reloadui`, cvars, …) |
| `/random`, `/rand`, `/rnd`, `/roll` | Roll |
| `/played` | Time played |
| `/time` | Game time |
| `/clear` | Clear focused chat window |
| `/chatlog` | Toggle chat log file |
| `/combatlog` | Toggle combat log file |
| `/logout`, `/camp` | Logout |
| `/quit`, `/exit` | Quit client |
| `/raidinfo` | Saved raid instances UI |
| `/afk`, `/dnd` | AFK / DND |
| `/help`, `/h`, `/?` | Help |
| `/chat`, `/chathelp` | Chat help |

---

## Emotes (including `/sit`)

Text emotes are a **separate** table (`EMOTE*_CMD*`), not `SlashCmdList`
combat commands. Examples: `/sit`, `/stand` (where defined), `/wave`, …

They still type as `/sit` in chat; they are **not** evidence that other
modern combat slashes exist. Prefer not to treat emotes as a bot control
plane.

---

## Macros on 5875

What works:

- Multi-line macros (one slash command per line).
- `/cast Spell Name` / `/spell Spell Name` with **exact** localized name.
- `/target`, `/assist`, `/follow`, chat lines, `/script` (limited).

What does **not** work (stock):

- Conditional clauses: `[combat]`, `[form:1]`, `[mod:alt]`, `[@focus]`, …
- `/castsequence`, `/cancelform`, `/startattack`, `/use` as distinct macro
  verbs, `#showtooltip` behavior from modern clients (do not assume retail
  macro UI features).

Keep macros dumb. Put logic in the human, in keybinds, or in an addon UI
button that the human clicks (hardware event).

---

## Operator vs stock

- **Stock game:** this file.
- **ShadowArmy dev slash:** `/sa …` — power-user escape hatch; product path
  is panel UI / automation (AGENTS.md). Not a second language monofuel
  should memorize mid-fight.
- **The System → clients:** GM announce `<SYS> reload|ping|…` parsed from
  `CHAT_MSG_SYSTEM` ([../the-system-loop.md](../the-system-loop.md)).
