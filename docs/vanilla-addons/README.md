# Vanilla addons (1.12.1 / 5875)

Engineer docs for the **stock Blizzard 1.12.1 client (build 5875)** Lua
addon surface: packaging, Lua 5.0, stock slash commands, and the APIs we
actually use in `addons/ShadowArmy/`.

**Pin:** [docs/wow-version.md](../wow-version.md). TOC interface number:
`## Interface: 11200`.

## Do not hallucinate

**`/cancelform` does not exist on 5875.** There is no `SLASH_CANCELFORM` in
1.12.1 FrameXML. Leave forms by re-casting the form ability / switching
stance (or let the client auto-drop Travel/Aquatic at water edges — play-
observed). Full trap list:
[chat-commands.md](chat-commands.md#not-in-1121--do-not-use).

Also: bulk `LootSlot` failed even on panel click in our probe
([advisor-sandbox-gates.md](../advisor-sandbox-gates.md)) — do not document
vanilla auto-loot as working.

Modern wowwiki / retail macro pages are **not** authoritative for this
client. Stock slash aliases and handlers come from 1.12.1 FrameXML
(`GlobalStrings.lua` `SLASH_*` + `ChatFrame.lua` `SlashCmdList`). Readable
dump: [Gethe/wow-ui-source `1.12.1`](https://github.com/Gethe/wow-ui-source/tree/1.12.1/FrameXML)
(FrameXML itself lives inside client MPQs on disk).

## Reading order

| Doc | What |
|---|---|
| [addon-system.md](addon-system.md) | TOC, load/reload, Lua 5.0, frames, events, gates |
| [chat-commands.md](chat-commands.md) | Stock slashes, macros, forms, **does-not-exist** list |
| [lua-api.md](lua-api.md) | Practical API signatures + ShadowArmy patterns |

## Related (not this folder)

| Doc | Role |
|---|---|
| [../play-classic.md](../play-classic.md) | Launching the wine 5875 client |
| [../advisor.md](../advisor.md) / [../advisor-autopilot.md](../advisor-autopilot.md) | Product: L0 advisor only on vanilla |
| [../the-system-loop.md](../the-system-loop.md) | Chat bus in/out for live addon reload |
| [../wow/](../wow/) | Gameplay primer (not API) |

This is **`docs/`** (humans/agents). Do not dump engineering notes into `kb/`.
