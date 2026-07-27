# Advisor as gradual autopilot (L0–L5)

**Status:** product framing (2026-07-27). Captures how monofuel wants the
vanilla-client **ShadowArmy advisor** to evolve, and how that relates to the
Softmax tournament bots. Supplements — does not replace — `docs/advisor.md`
(hypothesis + early design) and `docs/the-system-loop.md` (reload/telemetry).

## Why this exists

The tournament goal is **full autonomous dungeon play**: party of seats that
walk the content without a human driving each character. That end state is
**level-5 automation** on the **Nim client** path
(`nim_control.v1` → host → `lua/tools` intents → upstream goals).

The human seat is different. Monofuel plays on the **real 1.12 client**
(`make play-classic`) to validate world, quests, combat, party, and recovery
with eyes on the screen. The advisor addon is the **gradual autopilot** for
that seat: same kind of ladder as car SAE levels — start as instruments and
hints, climb toward “I only supervise,” then hand capability off to the Nim
bots rather than trying to turn the vanilla client into the tournament
runtime.

```
Vanilla 1.12 client + ShadowArmy     Nim client + army_host + lua tools
─────────────────────────────────    ─────────────────────────────────
Human validates with HITL            Tournament / army automation
Advisor climbs L0 → L5 (here)        Target: L5 always (full policy)
Same realm, same rules, no cheats    Same realm, same rules, no cheats
```

Fair-play still applies on both faces: no GM gameplay outcomes, no out-of-
band collusion, no stranger-invisible edges. Human seat is for **finding
and fixing the real pipeline**, not papering over it.

## Two clients, deliberately different jobs

| | Human seat | Bot seats |
|---|---|---|
| Client | Stock 1.12 `WoW.exe` (wine) | Upstream Nim client |
| Policy surface | Addon Lua (`addons/ShadowArmy/`) | Named intents in `lua/tools/` |
| Perception | Client UI APIs + local state | Typed environment frames |
| Actuation | Whatever the 1.12 addon sandbox actually allows | Goals/actions over `nim_control.v1` |
| Purpose | Gradual autopilot + live validation | Tournament automation |

Do **not** treat the advisor as a second tournament bot. If a capability
only works as a vanilla-addon hack and cannot transfer to the Nim/Lua path,
it is still useful as human QoL — but it is not a win condition. Prefer
features whose *decision* can live as structured advice or a named intent
the bots can also consume (transfer hedge from `docs/advisor.md`).

## Automation levels (advisor ladder)

Rough SAE analogy. Levels describe **how much the human must still do**, not
how clever the UI looks. A feature can be L2 for combat and L0 for quests
at the same time — the level is per domain, not a single global switch.

| Level | Name | Human does | Advisor does | Example (current or intended) |
|------:|---|---|---|---|
| **0** | Instruments | Everything | Display only | XP/h, target intel, log window, quest blips |
| **1** | Assisted | Acts on prompts | Suggests / warns | Buff missing nag, “elite — skip”, nearest objective line |
| **2** | Partial | Sets goals, supervises | Runs one slice while engaged | Auto-combat while you hold target; auto Demon Skin when proven; one-click loot vacuum |
| **3** | Conditional | Monitors, takes over on edge cases | Runs a whole activity under conditions | “Grind this area while mana > X and bags free”; auto drink/eat; stay in formation if party |
| **4** | High | Starts the run, intervenes rarely | Multi-step route / quest chain / recovery under broad conditions | Full Tirisfal quest circuit with corpse run; RFC trash packs with role scripts |
| **5** | Full | Not required on this seat | Entire dungeon/session without human input | **Not the advisor’s job.** This is the Nim bot army. |

**Crossover test (from advisor.md):** when a thin L3/L4 advisor plus almost
no human input out-levels “L1 advisor + attentive human,” the policy side
is ready to live on bots. The human should *feel* that shift (they’re
mostly rubber-stamping).

### What “gradual” means in practice

- Climb by **domain** (combat, loot, bags, quests, navigation, party, recovery),
  not by dumping a full bot into the addon.
- Each step should leave a **manual override** (toggle off, or just don’t
  target / don’t open the corpse).
- Prefer **structured recommendations** first (L0–L1), then bind them to
  actuation only when the human seat proves the call is right (L2+).
- Anything that reaches L3+ on the advisor should have a clear story for
  the **same decision** on Nim seats (Lua tool or upstream goal) — otherwise
  we built a local toy.

## Current honest placement (ShadowArmy ~r21)

Not a scorecard to game — a map of where we actually are.

| Domain | ~Level | Notes |
|---|:---:|---|
| HUD / grind stats / log | 0 | Solid instruments |
| Quest objective blips + line | 0–1 | Data-backed waypoints; human still walks and turns in |
| Buff watch | 0–1 | Reminder path; autocast attempted but disabled when texture verify fails |
| Auto Demon Skin / Armor | 2 (intent) / 0–1 (live) | Designed as keep-up from driver; live failure was **detection**, not “must click” |
| Auto-combat (warlock) | 2 | Target + toggle; rotation from OnUpdate |
| Auto-loot | ~1.5 | Not zero-click; one click per corpse after gate findings |
| Bag UI + sort | 1–2 | Human opens / starts sort; swaps can continue after first accepted call |
| Remote reload / The System | n/a | Dev loop, not gameplay automation |
| Navigation / dungeon AI | 0 | Human or Nim bots; not advisor policy |
| Full dungeon autopilot | — | **Nim L5 path only** |

## Client sandbox reality (stop the blanket story)

Agents have repeatedly assumed “everything is a hardware-event check.” That
is the **post-2.0 protected-function** mental model. Our human seat is
**1.12**. Live findings:

- **Not one global lockdown.** Behavior is **per API**, discovered by
  probe (works from click? from `OnUpdate`? from `CHAT_MSG_SYSTEM`?).
- **`CastSpellByName` works from software context** on this client —
  auto-combat and armor ticks fire from the driver `OnUpdate`. Demon Skin
  is not blocked because “it needs a hardware event”; when autocast died,
  the safety path said the buff **never read present** after cast (texture
  / scan issue).
- **Some calls do silent no-ops outside input-derived context** on this
  build, notably **`ReloadUI`** (remote announce / deferred tick fail;
  slash, button click, action-bar piggyback work) and **`LootSlot`**
  (vacuum from `LOOT_OPENED` failed; piggyback on loot-row click works).
- **Bag pickup/sort** accepted continuing swaps from `OnUpdate` after a
  first click-started swap — different from loot.

Rule for agents and future revs:

1. Do not invent a hardware-event requirement without a live probe or a
   line in this doc / the addon comments.
2. Prefer measuring: same call from OnClick vs OnUpdate vs chat handler;
   emit a one-shot `gated` / `ok` line if unsure.
3. Gameplay L2+ features that need a real click every time are still
   useful as HITL assists — document them as **click-gated L2**, not as
   “vanilla is fully free” or “vanilla is fully locked.”

Details of the reload/loot ladders live in addon comments and
`docs/the-system-loop.md` / session checkpoints — this section is the
policy so we stop thrashing the wrong root cause.

## How this serves the tournament

1. **Faster truth than bot logs alone.** Human eyes catch “stuck in geometry,”
   bad quest text, threat death, loot that never looted — then we fix Nim/Lua
   or upstream, not the wine UI.
2. **Curriculum for policy.** L0–L1 advice forces us to name decisions
   (skip elite, drink now, next objective). Those names become intents.
3. **Crossover before dungeon day.** If the advisor cannot reliably run
   combat + loot + a short quest loop under supervision, the army will not
   clear a dungeon by magic on Nim.
4. **Separation of concerns.** Vanilla addon may implement a *preview* of
   a behavior; the **ship path for L5** remains Nim host + Lua tools +
   upstream capabilities. No cheating either face.

## Relationship to other docs

| Doc | Role |
|---|---|
| `docs/advisor.md` | Original hypothesis, advice classes, transfer hedge, live-edit loop idea |
| `docs/advisor-autopilot.md` (this file) | Product ladder L0–L5, two-client split, sandbox honesty |
| `docs/the-system-loop.md` | SOAP announce / Chat.log / remote reload |
| `docs/quest-data.md` | Ground-truth waypoints for L0–L1 quest instruments |
| `docs/v2.md` | Army architecture (kb / lua / host); advisor listed as separate |
| `AGENTS.md` | Fair play, no Python bot policy, rely on upstream |

## Open rungs (when we next climb)

Not a sprint plan — ordered by how much they teach the tournament path:

1. **Fix Demon Skin detect → restore L2 keep-up** (texture list / buff scan).
2. **Loot:** document click-gated L2 as the 1.12 ceiling unless a real
   ungated path appears; do not spend weeks on wine-only loot hacks that
   Nim already loots correctly via upstream.
3. **L1 danger / resource lines** from real state (mana, elite, corpse with
   quest item) — structured first, prose second.
4. **L2 “follow this waypoint”** only if it teaches pathing issues we still
   see on bots — else leave walking to human or Nim.
5. **Never prioritize vanilla L5.** When a domain is “good enough under
   supervision,” move the decision into `lua/tools` and prove it on a Nim
   seat.

## One-liner

**Advisor = SAE ladder on the human vanilla client so monofuel can validate
and climb automation with hands on the wheel; tournament win = Nim seats at
L5 through the real control plane — not a perfect 1.12 addon bot.**
