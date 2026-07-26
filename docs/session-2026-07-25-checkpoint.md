# Checkpoint — 2026-07-25 (Saturday session)

Written at usage-limit checkpoint. Everything below is committed and pushed
unless marked otherwise.

## State of the world

| Thing | Where | State |
|---|---|---|
| Human seat | `make play-classic` (real 1.12 client, wine) | Murist, undead warlock lvl 5, Tirisfal |
| Advisor addon | `addons/ShadowArmy/` | **r18** (see below) |
| The System | `make system` → :7777 | running; dashboard + MCP + Chat.log tailer |
| Realm | upstream `infra/compose.vmangos.yml --profile coworld` | up, SOAP enabled, 20s saves |
| Bot seat | `make warlock-bot` | Shadowfel (undead warlock lvl 1) online, stuck in crypt |
| Upstream checkout | `../coworld-vanilla-wow` | pulled to `6ea95cd55` (was `98220fead`, +167) |
| Our fork | `../coworld-vanilla-wow-fork` | branch `shadow-army-fixes`, 2 commits, based on old pin |

## Addon revs shipped today (r1 → r18)

Telemetry/reload loop, auto-combat, ShadowBags (unified inventory + autosort +
money), advisor log window, quest objective helper. The live-iteration loop
works: edit → commit → `reload_addon` MCP tool → the human's next
out-of-command-bar keypress applies it (auto-reload piggyback).

Known-unresolved in the addon:
- Demon Skin/Armor autocast disabled itself — buff texture guesses wrong.
  The safety emitted `captured=none`, so the real textures still need
  capturing (the `err` line is designed to hand them over; it fired with an
  empty list, which is itself a clue — the scan may be wrong, not the guess).
- Auto-loot is one-click-per-corpse (LootSlot is gated outside click
  context on this client). Shift+right-click on the corpse is the native
  zero-click path.

## Bugs root-caused today

1. **Quest turn-in crash** (`docs/quest-crash-forensics.md`) — SERVER bug, not
   sound/addon/wine. cowpatch stripped the `uint32` row-count prefix from
   `SMSG_SET_FACTION_STANDING`; 5875's handler still reads it → Faction.dbc
   row 0 → NULL deref at WoW.exe RVA `0x000D4BEE`. All six dumps identical.
   **Still present on latest upstream** (`commerce_and_social.py` untouched in
   the 167 new commits). Fixed in our fork (2 commits); image build was in
   flight at checkpoint.
2. **Indoor/underground movement blocked** (`docs/warlock-seat.md`) —
   `navigation_semantics.nim` rejects any route whose ADT terrain sample sits
   >2.0yd above the path (`MaxProjectedVerticalDistance`), which is every
   route inside a WMO. The bypass `allowTerrainOverhead` exists but is
   **serialize-only**: `actions.nim:1385` writes `allow_terrain_overhead`
   outbound and nothing parses it back from an external policy action (same
   for `water_column_move`, `combat_egress`, `move_step_limit`). Agent was
   fixing this at checkpoint. **Tournament-critical**: many dungeon entrances
   are underground.
3. **Orphaned player containers** — 8 `coworld-run-player-*` containers
   survived their game container and burned 6 cores for 3h (load 9.4).
   Stopped manually; cleanup gap worth an upstream note.

## Bot capability proven today

- **Movement**: navmesh helper built (`make navmesh-helper`), Botwarrior
  walked a 47-waypoint route, DB-verified (`docs/navmesh.md`).
- **Autonomous kill loop**: `brain/grind.py` — move → attack → kill → loot,
  8 corpses / 19 settlements in 150s (`make grind SLOT=n CHARACTER=x`).
- **Any class/race is externally drivable** — `unsupported_profile` only
  silences `recommended_action`; generic action masks are goal-independent.
  This was thought to be a hard blocker and is not.
- **Party formation**: root-caused and proven bot↔bot; `accept_party` is the
  stranger-friendly path (unmasked from `invitePending` alone), so our seats
  should be invite-ACCEPTORS, not recruiters (`docs/party-formation.md`).
- **Quest data**: 3050 quests with waypoints mined from the world DB.

## Not yet proven (next session's targets)

- XP accrual by a bot (Botwarrior was lvl 30 killing lvl 4 mobs = 0 XP;
  needs a low-level outdoor seat).
- Quest accept/turn-in by a bot — `accept_quest`/`turn_in_quest` are never
  generically masked and `interact` on a questgiver yielded no `quest_offers`.
- Whether the terrain guard also fires INSIDE instance maps (decides whether
  issue #2 is annoying or fatal for dungeons).
- `leave_party`/`decline_party` don't exist in `BotActionKind` — a bot can
  join but not leave. Upstream ask.

## Operating rules learned today (also in memory)

- Upstream is authoritative: the fork is a thin rebase layer, minimum delta,
  upstream wins every conflict. Bots must be tuned against upstream behavior,
  never our patched build.
- Never put bots on the human's realm or let them contact the human's
  character without asking first, every time.
