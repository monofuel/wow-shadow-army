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

First concrete step when we build: same frame-capture session as
command-channel.md (chat, marks, targeting) plus quest pickup/turn-in and
a loot event — one session answers both docs' perception questions.
