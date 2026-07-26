# The advisor — human augmentation as a ramp to full AI guidance

Design brainstorm (2026-07-25), no implementation yet. This is the
shadow-army application of the racha_notes hypothesis
`AI/game_bots/hypotheses.md` → "Human augmentation as a ramp to full AI
guidance" (monofuel, 2026-07-24): build tools that advise a *human* player
first — the human is the training wheels, and the handoff to a fully
autonomous policy is gradual instead of a day-0 leap.

Companion doc: `command-channel.md` — same chat bus, opposite direction.
Commands flow human→shadows; advice flows shadows→human.

## The unfair advantage: ground truth in mariadb

Blizzard-era addon authors spent years crowdsourcing quest and node data
(Questie, wowhead, Joana's leveling guide). We run the server — the
VMaNGOS world DB is queryable: `quest_template`, creature spawns,
gameobject spawns (every ore vein and herb node coordinate), loot tables,
XP formulas. "Optimal" is computable, not heuristic.

## Advice classes, in rough build order

1. **Quest routing** — given level, quest log, and position: score quests
   by XP-per-minute *including travel*, emit an ordered route. Vanilla
   quest design scatters players brutally (that's why Joana's guide was a
   celebrated artifact); this is a live, personalized Joana. Classic
   orienteering/TSP over DB coordinates.
2. **Gather routing** — herb/vein spawn points are in `gameobject`; an
   optimal farming circuit is a solved graph problem. Deliberately dual-
   use: built as human advice, reused later as the Industry Empire bots'
   route policy. This is the hypothesis's transfer claim made concrete.
3. **Rotation / danger advice** — vanilla rotations are 3–4 buttons, so
   "press 2" is low value. The real advice is resource and threat
   management: "drink now or you won't have mana for the next pull,"
   "that's an elite, skip it," "loot that corpse — it has the quest item."
   Danger prediction beats DPS optimization at leveling.

## Delivery: the advisor is a shadow

One bot in the party whose job is *watching the human* and whispering
hints. No new infrastructure: it uses the same frame-perception and chat
path the command channel needs anyway, inverted. Solo Leveling flavor
holds — an intelligence-officer shadow.

- **In-game face:** whispers / party chat, terse, human reaction-time.
- **Dashboard face:** The System (:7777) renders the route map, quest
  scores, and current recommendation — second monitor material.
- `(verify)` Whether the human's own client exposes frames over
  nim_control. If it doesn't, the advisor-in-party design sidesteps the
  question: a party member's frames see most of what the human sees
  (position, target, combat, party HP/mana).

## Why this serves the hypothesis (not just the game)

- **Free evaluator in the loop:** every hint followed or ignored is a
  labeled data point on advice quality, at few-second cadence — versus
  the 40-game win-rate batches in `eval_discipline.md`.
- **Perception-first by force:** an advisor can't bluff. "Loot that"
  requires actually seeing the corpse in the frame. This is the
  perception-gate hypothesis wearing a product costume.
- **Built-in crossover test:** the day "advisor + trivial follow-the-route
  policy" out-levels "advisor + human," the handoff has happened — and
  the human feels it coming, because they notice they're just doing what
  it says.

## Structured recommendation objects (the transfer hedge)

Open question 1 in the hypothesis note: does advice tuned for human
reaction time transfer to an AI policy, or does it need a rebuild? Hedge
by construction — every hint is a thin rendering over a structured
recommendation:

```
{ kind: "quest_route",  waypoints: [...], scores: {...} }
{ kind: "danger",       unit: ..., reason: "elite", action: "skip" }
{ kind: "resource",     resource: "mana", action: "drink", deadline_s: ... }
```

The human gets prose in a whisper; a bot policy consumes the object
directly. Advice generation and advice rendering never mix — same
one-dispatch-path rule as The System's faces. Transfer becomes free
instead of a rebuild.

## Client fork: Nim client vs real 1.12 client for the human seat

The realm is stock VMaNGOS 1.12.1 — a genuine 1.12 Blizzard client connects
to it (that is what VMaNGOS exists to serve), and the client files are
already in wow-classic-data. That opens a fork for how the *human* receives
advice:

- **Nim client (current path):** no addon/Lua surface at all. Advice
  arrives as chat text from the advisor shadow. Zero new stack; works
  today.
- **Real 1.12 client (option):** full vanilla addon sandbox — the
  protected-function lockdown came in 2.0, so 1.12 addons may freely call
  `ReloadUI()`, register slash commands, and react to chat events. A thin
  advisor addon could parse the shadow's whispers (structured text) and
  render them as a HUD: quest arrows, route lines, danger flashes —
  Questie-grade UX instead of chat spam. Cost: a second client stack to
  babysit, and `(verify)` that the real client runs at all under
  wine/NixOS against our realm.

### Live iteration loop (the exciting part)

1.12's addon environment makes mid-session improvement automatable:
`ReloadUI()` re-reads all addon Lua from disk without leaving the game,
and an addon can trigger it itself — e.g. on a `!reload` whisper from a
trusted sender. So the loop becomes:

1. Human, in-game, asks for help or a change in party chat ("advisor,
   show gather nodes on the minimap").
2. The LLM tier (Racha / The System) edits the advisor's code on disk —
   addon Lua for the HUD rendering, and/or the shadow-side tool that
   generates the recommendation objects.
3. Advisor whispers `!reload` handled by the addon → `ReloadUI()` → the
   human sees the improvement seconds later, without leaving the game.
4. The improved *generation* logic (the structured recommendation side)
   trickles down to bot policies for free — bots consume the objects
   directly, per the transfer hedge above. Only the HUD rendering is
   human-specific.

This is the toolsmithing rail from architecture.md wearing a product
face: the human's requests are the feature backlog, arriving at play-time,
verified by the requester seconds after deployment. Note our own Lua tool
tier already hot-reloads by construction (brain/lua_runner.py spawns a
fresh interpreter per decide, so edits apply on the next tick) — the same
property, achieved statelessly. Caveat for both sides: a syntax error in
a freshly-written file fails the next call rather than keeping the old
version running — the toolsmithing rail should parse-check (`luac -p`)
before overwriting a live file.

## Open questions before building

1. Does the human client emit frames over nim_control, or does the
   advisor need to be a party-member bot? `(verify — decides delivery)`
2. What does a party member's frame actually reveal about the leader —
   target, cast, combat state, mana? `(same capture session as
   command-channel.md open questions — do them together)`
3. Quest-log visibility: can the advisor see the human's quest log from
   frames, or does it need the human to `/w` it quest names once?
4. Acceptance-rate logging: The System should record every hint + whether
   the human's subsequent behavior followed it. That's the hypothesis's
   measurement, and it needs to be in from day one — retrofitting the
   metric later loses the baseline.
5. Does the real 1.12 client run under wine/NixOS against our realm, and
   is the addon sandbox worth the second stack? `(verify — gates the HUD
   path above; the chat-text path needs none of it)`

First concrete step when we build: same frame-capture session as
command-channel.md (chat, marks, targeting) plus quest pickup/turn-in and
a loot event — one session answers both docs' perception questions.

## Built: quest waypoint data (2026-07-25)

First piece of the "ground truth in mariadb" thesis shipped as an artifact:
`tools/gen_quest_data.py` joins `quest_template` against creature/gameobject
spawns and loot tables, converts world coords to the zone-normalized percent
space `GetPlayerMapPosition` uses, and writes
`addons/ShadowArmy/QuestData.lua` — 3050 quests with locatable turn-ins,
questgivers and objective spots, 1.1 MiB, whole game, regenerated with
`make quest-data`.

This is advice *generation* only, per the transfer hedge above: the file is a
structured recommendation source with no rendering opinion, so the addon HUD
and a future bot route policy consume the same waypoints. Details, the verified
coordinate derivation, and known gaps: `docs/quest-data.md`.
