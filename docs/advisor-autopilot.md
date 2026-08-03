# Advisor as gradual autopilot (L0–L5)

**Status:** product decision (2026-07-27). Supplements `docs/advisor.md`
(hypothesis) and `docs/the-system-loop.md` (reload/telemetry).

## Decision (read this first)

| Seat | Automation level | Where |
|------|------------------|--------|
| **Vanilla 1.12 + ShadowArmy** | **Strictly L0** | Human eyes, instruments only |
| **Nim client + army host + `lua/tools`** | L1–L5 (tournament path) | Real control plane |
| **Nim client Lua addon system** (upstream, in progress) | **Future home for advisor L1–L4** | Wait for them — do not invent unlock/patch workarounds on stock `WoW.exe` |

**Why:** stock 1.12 action APIs are not a workable automation surface for
levels 1–4 (Probe 2026-07-27; see appendix). Broad client unlock is too
much pain for the value. Softmax is already building a Lua addon path into
the **Nim** client — that is the place to climb L1–L4 with a human in the
loop, not wine + binary patches.

**Agents:** do not implement new advisor **actuation** (cast, loot, move,
target, auto-combat, keep-up buffs, etc.) on vanilla ShadowArmy. L0 display
and QoL that does not need restricted action APIs is fine. Do not spend
time on unlockers (`docs/advisor-unlock.md` is reference-only / abandoned
for product).

## Why this exists

Tournament goal: **full autonomous dungeon play** — party of seats without
a human driving each character. That end state is **L5** on the Nim path:

```
nim_control.v1 → army_host → lua/tools intents → upstream goals
```

The human still plays Murist on **real 1.12** to validate the world. The
vanilla advisor stays a **dashboard** (L0): stats, blips, logs, quest
waypoints on the map — human does every action.

```
Vanilla 1.12 + ShadowArmy          Nim client
─────────────────────────          ──────────────────────────────
L0 instruments only (now)          Bots: L5 target (army + tools)
Human validates with eyes          Future: Lua addons → advisor L1–L4
No client unlock project           Same realm, fair play
```

## Levels (SAE-style)

Levels = how much the human must still do. **Per domain** when we climb
again on Nim addons — not one global switch.

| Level | Name | Human | System |
|------:|------|-------|--------|
| **0** | Instruments | Everything | Display only |
| **1** | Assisted | Acts on prompts | Suggests / warns |
| **2** | Partial | Sets goals, supervises | Runs one slice while engaged |
| **3** | Conditional | Monitors edge cases | Whole activity under conditions |
| **4** | High | Starts run, rare takeover | Multi-step route / recovery |
| **5** | Full | Not required | Entire session / dungeon |

### Where each level lives (2026-07-27)

| Level | Vanilla ShadowArmy | Nim bots / host | Nim Lua addons (when ready) |
|------:|:------------------:|:---------------:|:---------------------------:|
| **0** | **Yes — only scope** | n/a | Yes |
| **1** | **No** (wait) | Policy as intents / chat later | **Yes — target** |
| **2–4** | **No** (wait) | Growing via tools + upstream | **Yes — target** |
| **5** | Never | **Yes — tournament** | Optional later |

**Crossover test** (from original hypothesis): when thin L3/L4 plus almost
no human input out-levels “hints + attentive human,” that policy belongs
on bot seats. We re-run that test on the **Nim addon** seat, not wine 1.12.

## Vanilla ShadowArmy — L0 only

### In scope

- HUD: XP/h, target intel, buff **status text** (not auto-cast)
- Quest / crew / corpse **map blips** and compass lines
- Advisor log, Probe panel (for sandbox forensics if needed)
- Quest data (`QuestData.lua`) as **display** waypoints
- The System loop: telemetry + remote reload (ops, not gameplay automation)
- Bag UI as pure inventory view if useful — not as automation project

### Out of scope (do not grow)

- Auto-combat, spell keep-up, auto-loot, programmatic movement/targeting
- “Click-gated L2” as a product direction
- Client unlock / inject / patch projects for freer Lua actions

Existing non-L0 code in the addon is **legacy debt**. Prefer not to extend
it; removing or disabling it is fine when touching the file. Do not treat
it as the ladder.

### Honest L0 map

| Domain | Level | Notes |
|--------|:-----:|-------|
| HUD / grind stats / log | 0 | Keep |
| Quest / crew blips | 0 | Keep (human walks) |
| Buff **display** | 0 | Text only |
| Combat coach (ability list) | 0 | Suggestions only — you press the keys |
| Auto cast / combat / loot | — | **Not product** on this client |
| Full dungeon | — | Nim L5 |

## Tournament path (unchanged)

1. Human L0 seat finds world/quest/party/recovery truth with eyes.
2. Named decisions live in **`kb/`** + **`lua/tools/`** on Nim seats.
3. Rely on upstream for pathing, combat, loot, recovery — not vanilla addon hacks.
4. Fair play on both faces. No GM gameplay outcomes, no seat collusion.
5. L5 win = Nim army through `nim_control`, not a perfect 1.12 addon.

## Relationship to other docs

| Doc | Role |
|-----|------|
| `docs/advisor.md` | Original hypothesis / advice classes |
| `docs/advisor-autopilot.md` (this file) | **Levels + product decision** |
| `docs/advisor-unlock.md` | Unlock research notes — **not pursuing** for product |
| `docs/advisor-sandbox-gates.md` | Probe measurements (why vanilla L1–4 stopped) |
| `docs/the-system-loop.md` | SOAP / Chat.log / reload |
| `docs/quest-data.md` | Waypoint data for L0 display |
| `docs/v2.md` | Army architecture |
| `AGENTS.md` | Fair play, Lua tools, no Python policy |

## Open work

1. Keep vanilla advisor useful as **L0** (display, data, ops loop).
2. Drive automation on **Nim host + lua tools** (tournament).
3. When upstream Nim **Lua addon** support lands: port advisor ladder
   **L1→L4** there; re-open this doc’s “where levels live” table.
4. Do **not** open a client-unlock workstream.

## One-liner

**Vanilla advisor = L0 dashboard. L1–L4 wait for Nim addons. L5 = Nim
bots. No unlock rabbit hole.**

---

## Appendix — why vanilla stopped at L0 (Probe 2026-07-27)

Instrument: advisor **Probe** (Click / Frame / Delay). Historical; product
decision above does not depend on re-probing forever.

| API | Click | Frame | Delay | Notes |
|-----|:-----:|:-----:|:-----:|-------|
| Cast armor (`CastSpellByName`) | OK | no | no | Software cast dead |
| ReloadUI | OK | no | no | Remote reload only arms button / next press |
| Loot all (`LootSlot`) | no | no | no | Even panel click insufficient |

Broad freer Lua on stock 1.12 would mean a large unlock surface (or shared
gate RE). **Rejected** for time cost; see `docs/advisor-unlock.md` +
`../zebra` as reference only. Do not download/run third-party unlockers.
