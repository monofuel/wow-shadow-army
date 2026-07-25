# Command channel — how the monarch talks to the shadow army

Design brainstorm (2026-07-25), captured before any implementation. The core
idea: **in-game party chat is the command bus**, and the game's own targeting
mechanics resolve "that enemy." Nothing here is built yet; open questions are
marked `(verify)`.

## Why party chat

The human leader is already in a party with the shadows — that's the
solo-leveling premise. Vanilla 1.12 chat gives us addressing for free:

- **Party chat** (`/p`) = broadcast to all shadows.
- **Whisper** (`/w Botwar ...`) = one specific soldier.
- **Prefix in party chat** (`/p Botwar attack`) = one-of-many without a
  whisper.

Historical rhyme: 1.12 added `SendAddonMessage()` precisely because addons
needed a machine-to-machine channel over chat (CTRA, threat meters). We're
using plain visible chat instead — deliberately. Visible commands double as
a human-readable log, and other players' policies can in principle learn to
read them too, which fits the Softmax cooperate-with-strangers mission.

`(verify)` Chat events must actually appear in the EnvironmentFrame the nim
client streams over `nim_control.v1`. If they don't, that's an upstream
feature conversation, not something we hack around.

## "That enemy" — deixis via game mechanics

Vanilla already solved pointing at things. Use the native mechanisms rather
than inventing coordinates-in-chat:

1. **Leader's current target.** Bare `attack` means "attack what I'm
   targeting." The frame should expose the leader's target when the leader
   is a visible party member `(verify)`.
2. **Raid target icons** (skull, cross, moon, ... — added in 1.11, so
   available). Marks become standing doctrine: skull = kill first,
   moon = crowd-control, etc. This is the same protocol human PUGs use,
   so shadows trained on it coordinate with strangers using stranger
   conventions — no private language. (NO-COLLUSION note: marks are a
   public, in-game, any-player-visible mechanism; interpreting them is
   normal play, not a side channel.)

## Command tiers map onto the architecture layers

Same three-layer split as racha_notes AI/game_bots/architecture.md:

| Tier | Examples | Where it lands |
|---|---|---|
| Reflex | `attack`, `follow`, `stay`, `flee` | Lua tool dispatch, instant, no LLM |
| Standing goal | `gather copper until bags full`, `guard me` | goal state in the Lua tool layer; persists across ticks |
| Planning | `do that quest`, `go sell junk and come back` | LLM decomposes into travel/kill/loot tool sequences (toolsmithing loop) |

Reflex commands must stay LLM-free — a kill order that round-trips through
a language model is too slow for combat and violates the reflex-tier rule.

## Grammar sketch (not final)

```
[<bot-name>] <verb> [<object>]

attack            # leader's target, or skull if marked
follow | stay | flee
gather <item|node> [until <condition>]
quest <quest-name|"that">    # "that" = leader's most recent quest event (verify)
status            # bot replies in party chat with current order + state
```

Keep the verb set tiny at first. Every verb is a named intent in
`lua/tools/registry.lua`; parsing is a pure Lua function (unit-testable with
fixture chat lines, no realm needed).

## Back-channel: acks in chat, telemetry to The System

- **In-game:** shadows acknowledge in party chat ("On it — Kobold Vermin"),
  and report completion/failure tersely. The human should never need the
  dashboard mid-pull.
- **The System (:7777):** every command gets a structured record — raw chat
  line, parsed intent, dispatching tool, outcome, timestamps. Dashboard
  gains a per-soldier "current order / status / recent commands" panel.
- **Third face — MCP:** The System already exposes MCP (MCPort). The same
  dispatch path that handles a parsed chat command can accept an MCP tool
  call, so Racha can issue orders out-of-game. One grammar, three doors:
  in-game chat, dashboard, MCP. (One-dispatch-path-two-faces rule extends
  to three faces; do not fork command handling per entry point.)

## Open questions before building

1. Do chat messages (party + whisper) appear in EnvironmentFrame? Which
   kinds, and with sender identity? `(verify against live frames)`
2. Can a shadow *send* chat via nim_control — is there an action for it,
   or is speaking masked off? `(verify action masks)`
3. Do raid target icon assignments appear in frames? `(verify)`
4. Does the leader's target show on party-member frame data? `(verify)`
5. Party formation itself is still blocked (invite_party masked while solo
   — see docs/control-plane.md); the command channel is moot until shadows
   can actually join the party.

First concrete step when we build: capture live frames while a human types
in party chat, whispers a bot, sets a raid mark, and changes target — then
diff the frames. That answers questions 1–4 in one session and gives us
fixture data for the parser's unit tests.
