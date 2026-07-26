# Indoor (WMO) navigation — plan and RESOLUTION

Written 2026-07-26. Goal was: fix the wow-coworld bug that stops bots from
navigating inside WMOs (crypts, buildings, dungeon entrances), prove it on a
fresh testbed warlock, and hand upstream a PR.

**RESOLUTION (same day): no fix needed — upstream already fixed it.** At
`033fa79c4` the testbed warlock Igris walked crypt-interior → outdoors →
INTO the cathedral to the imp questgiver on the UNPATCHED build, driven by
plain external `move` actions with a destination (`brain/walkto.py`). The
old-pin analysis below is kept for the record; see §"Resolution evidence".

| | |
|---|---|
| Fork branch | `indoor-wmo-navigation` (Gitea `Monolab/coworld-vanilla-wow`) — **empty on purpose**, no carried delta |
| Based on | upstream `main` @ `033fa79c4` ("Admit retained Orc quest discovery actions") |
| Testbed | Igris — undead warlock, account `shadow2/shadow2`, slot 3 / socket 41117, seat runs from the FORK worktree (`make igris-bot`) |
| Status | **resolved: works upstream**; fork doctrine says drop our fix when upstream fixed it their way |

## Resolution evidence (2026-07-26)

- Walk 1, crypt → Venya Marthand (quest 1470 giver, church interior):
  `uv run --project ../coworld-vanilla-wow-fork` +
  `WOW_SHADOW_UPSTREAM=<fork>` `python -m brain.walkto --slot 3
  --character Igris --to venya`. Result: **ARRIVED gap=2.5yd**,
  pos (1839.2, 1632.2, 96.9), 67 moves total across two runs, 2 transient
  `graph movement made no progress into target polygon` failures that
  self-recovered by replanning. Crypt spiral (z 121→134), tunnel exit
  (z→101), church door, nave — all on graph-edge moves.
- DB ground truth: `characters` row for Igris at (1839.2, 1632.2, 96.9),
  online — the cathedral interior, next to Venya (1836.94, 1633.43, 97.02).
- Why it works now: `planNavigationAction`
  (`player/behavior/navigation.nim:574+`) converts every destination move
  into native navmesh-graph-edge legs and stamps
  `allowTerrainOverhead = true` (line 553, "a native adjacency is the floor
  contract"), which skips the ADT terrain-divergence rejection in
  `routeForwardFloorSafety` and keeps physics on the collision deck
  (`client/simulation/physics.nim solidFloorAt`). Between our old pin
  `98220fead` and `033fa79c4` upstream's navmesh-graph rework closed the
  gap the plan below was written against.
- The Detour mesh itself always covered the interiors: the navmesh helper
  routes crypt→Venya (69 waypoints) and outdoors→church (29, smooth)
  offline via `{"op":"route"}` — see docs/navmesh.md.

Practical consequences:

- Shadowfel-era DB repositioning is obsolete: bots can WALK out of the
  Shadow Grave, and into the church/vendor buildings, today.
- `brain/walkto.py` is the reusable walk driver + evidence logger
  (presets: `outside`, `venya`, `crypt`).
- No residual external-move gap: `resolvePolicyAction`
  (`player/contract/environment_frame.nim:1019-1040`) lowers BOTH external
  move forms — target-form (destination := target's observed location,
  arrival 4yd) and destination-form — to `navigationMode = "goal"`, which is
  not in `planNavigationAction`'s `manual/local/transport` bypass list
  (`navigation.nim:584`), so every external move gets graph planning and the
  terrain-overhead contract. The `manual`/`local` modes that skip the flag
  are internal planner-authored actions only.
- The transient `graph movement made no progress into target polygon`
  failures are the corridor settlement classifier
  (`player/contract/actions.nim:994`) reporting a stalled leg; walkto's next
  submission replans and recovers — observed twice in 67 moves, both
  self-healed.
- If a future upstream pin ever regresses this, the analysis + ranked fix
  options below become live again.

---

# Original plan (pre-resolution, kept for the record)

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
