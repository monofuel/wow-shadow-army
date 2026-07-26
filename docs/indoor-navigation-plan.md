# Indoor (WMO) navigation fix — plan

Written 2026-07-26. Goal: fix the wow-coworld bug that stops bots from
navigating inside WMOs (crypts, buildings, dungeon entrances), prove it on a
fresh testbed warlock, and hand upstream a PR.

| | |
|---|---|
| Fork branch | `indoor-wmo-navigation` (Gitea `Monolab/coworld-vanilla-wow`) |
| Based on | upstream `main` @ `033fa79c4` ("Admit retained Orc quest discovery actions") |
| Testbed | second fresh undead warlock (own account + slot; NOT Shadowfel's slot 2) |
| Status | branch cut, plan agreed, **no code yet** |

## Why this bug is the early-game blocker

Not just the crypt escape. The Deathknell loop is:

1. Spawn **underground** in the Shadow Grave crypt; the exit is an easy walk
   out through a hole in the terrain at the entrance.
2. Grind outdoor mobs — this already works (`brain/grind.py` took Shadowfel
   to level 4 legitimately).
3. But in the first town, **every NPC is inside a building**: the imp quest
   (1470, Venya Marthand) is inside the church, and the two buildings with
   merchant NPCs matter for early gear — one of them is two-story.

So quest 1470 has TWO independent blockers stacked: the quest-action mask
(upstream is actively fixing — see the `grindbot-goap` / orc-grinder stream,
`docs/orc-grinder-handoff.md` upstream) AND physically walking indoors to the
questgiver. Even when the mask lands, a bot that can't cross a doorway can't
accept or turn in. Vendor gear is indoor-gated the same way.

## The bug, precisely (verified at `033fa79c4`)

`routeForwardFloorSafety` (`player/behavior/navigation_semantics.nim:359`)
walks each route waypoint and probes the **ADT terrain height** (the outdoor
heightmap). If the terrain sample sits more than 2yd *above* the path
(`MaxProjectedVerticalDistance`, line 427), the route is rejected. Inside a
WMO the terrain sample is the hillside/roof above you, so the guard compares
the route against a floor the bot is not standing on and rejects every
interior route.

The bypass exists but doesn't reach us:

- `allowTerrainOverhead` skips the terrain probe entirely
  (`navigation_semantics.nim:406`).
- It is granted **only** to the planner's own navmesh-graph-edge plans
  (`navigation.nim:553` — "a native adjacency is the floor contract") and
  copied onto externally-echoed recommended actions via private lowering
  (`controller.nim:809`).
- External policy actions cannot send it: `actions.nim:1390` serializes
  `allow_terrain_overhead` outbound only; the inbound `AllowedKeys` parser
  (`actions.nim:1104`) rejects the key.

Secondary suspect (verify during reproduce): Grok's overnight logs show
`graph movement made no progress into target polygon` on unit-target moves —
there may be a second, smaller executor bug hiding behind the guard. Confirm
whether the mmap navmesh actually has polys for the Deathknell interiors and
stairs before blaming the guard alone.

## Fix candidates, ranked

1. **Collision-aware floor probe (the pick).** The guard's real question is
   "is the client about to fall off the walkable deck?" — it answers with the
   wrong floor source. Probe the collision/VMAP floor beneath each sample
   (the cache already does collision probes via
   `collisionForwardDropLookahead`) instead of ADT-only terrain. Indoors the
   deck IS the floor and divergence goes to ~0; outdoors ADT still catches
   under-world dives. Root-cause fix, no waivers, strongest PR story, and the
   only option that handles the two-story case (see matrix).
2. **Ceiling test (fallback).** Before comparing against the terrain sample,
   raycast up; if WMO geometry sits between the probe and the terrain height,
   the ADT sample is provably not our floor — skip that comparison. Smaller
   delta, weaker semantics (skips rather than corrects), does nothing for
   upper floors where terrain is *below* the path.
3. **Extend the "native adjacency" waiver to all Detour routes.** One-line-ish
   but widens a safety waiver instead of fixing the check — semantic drift
   upstream's style (typed guards, proofs everywhere) resists. Weak PR case.
4. **Round-trip `allow_terrain_overhead` externally.** Unblocks only our brain
   and hands every external policy a safety bypass; unnecessary if 1 or 2
   lands (external destination moves then pass the corrected guard). Leave
   out of the PR.

## Acceptance matrix — Deathknell provides all four cases in ~200yd

| # | Route | Geometry case | What it exercises |
|---|---|---|---|
| 1 | Crypt interior → outside via terrain hole | underground WMO, terrain far ABOVE path | the classic `>2yd above` rejection |
| 2 | Church door → Venya Marthand (quest 1470) | building on sloped terrain + doorway threshold | ADT↔WMO floor transition mid-route |
| 3 | Merchant house, ground floor | simplest indoor | must-pass baseline |
| 4 | Two-story merchant house, upstairs | terrain BELOW path, stairs | forward-drop lookahead must treat the upper WMO deck as the floor; climb logic |

Case 4 is why option 1 beats option 2.

## Plan

1. **Reproduce on stock code.** Stand up warlock #2 (fresh account, own
   slot), submit routes for all four matrix cases, capture the typed
   rejections (`failureStage="floor"`, reason strings) as the PR evidence
   package. Also settle the navmesh-coverage question (secondary suspect).
2. **Implement option 1** on `indoor-wmo-navigation`; option 2 is the
   fallback. One self-contained commit per fork rules — message carries the
   why + evidence citation.
3. **Add a proof** in upstream's `proof/*.nim` style exercising a
   crypt-interior route (check whether the proof harness's collision data
   covers Tirisfal at coding time).
4. **Validate live**: warlock #2 walks all four routes unassisted,
   DB-verified positions — the exact thing that previously required a DB
   reposition, done clean.
5. **PR upstream** from the fork branch (monofuel submits, per AGENTS.md).

## Rules in effect

- Per `docs/coworld-fork.md` tournament rule: this patch changes bot
  behavior, so it is developed and proven on the branch only — do NOT run
  the bot army day-to-day on the patched build. Upstream landing the PR is
  what actually unblocks the bots.
- Upstream checkout `../coworld-vanilla-wow` stays read-only; all work on the
  fork worktree, pushes to Gitea only.
- No DB pokes / GM teleports to "help" the testbed — the whole point is the
  bot walks out on its own.
