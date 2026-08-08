# Current issues — prefer-upstream Petrel (evening 2026-08-07)

State of play after the realign to `monofuel/petrel`, today's integration
fixes, and the second upstream pull (`59191fb24..5858d278d`). Per-run history:
[realign-runs-2026-08-07.md](realign-runs-2026-08-07.md). Wet-corridor rules:
[duskwallow-plan.md](duskwallow-plan.md).

## What works now

- Land mesh navigation actually serves the desert corridor after the second
  upstream pull (`nav=following` most of the leg; it was `unavailable`
  end-to-end before).
- Death is visible to the strategy (`gameplay.dead`/`ghost`, `health_known`
  projected; `status.json` records `dead`/`ghost`/health). No more form-cast
  spam on corpses.
- Form casts drive to completion in ~3 ticks with aura-evidence guards
  against toggle-off.
- Wet leg: checkpoint tele → walk-in → Aquatic → beat-following swim all
  function (`swim_cheese_04` reached at speed on the first wet-lab run).

## Open issue 1 — "no productive ground input" stalls (the killer)

The ground-step projection (`updateGroundMovementSteps`) only certifies steps
that settle **grounded**. When no step qualifies, `appendSteering` stops and
the pilot has no recovery — the bot statues until something kills it.

| Where it bites | Evidence |
|---|---|
| Tile seam x≈−8533.3 (ADT boundary): projection empty while the next tile's object-build lags (`World stream delayed … primitive=0`) | Every desert run halts/slows in the same ~100 yd strip; run `215341Z` stalled ~10 s there, recovered, then died stalled at (−8288,−3435) in a mob camp |
| Shoreline re-entry: steps into swimmable water end un-grounded → all seaward steps rejected | Wet run `215819Z`: beached at (−6403,−4901), then `enter_water` toward cheese_07 (z=−4.9) wedged forever with full health |

A stationary bot in mob territory dies in seconds; the stall is fatal even
when the stall itself would clear.

**Planned fix (not yet implemented):** bounded patience — after ~2–3 sim-s
with no movement emitted while alive and far from the beat, fall back to
blind face-then-go (no projection needed, same control law as the swim
steer) until certified steps return; plus a generic pose-unchanged watchdog
as backstop for any future silence-class bug.

## Open issue 2 — planar swim steer cuts corners onto land

`petrelSwimSteer` is 2-D face-then-go at the current beat. Where the
coastline bulges (cheese_06 → cheese_07, the documented first-cliff zone),
the straight chord clips the beach; Aquatic drops on exit and the bot is
subject to issue 1 at the waterline. The old branch's liquid policy had
short-horizon collision sampling around bends; the port has none.

**Planned fix:** stay-in-liquid awareness or corridor cross-track pull on
the wet steer. Note the fatigue geometry (duskwallow-plan §1b) also wants
cross-track control — one mechanism can serve both.

## Open issue 3 — mob camps on the land chord

Even moving, the off-road spawn → `land_approach` chord crosses hostile
camps; the bot has zero threat behavior and dies if slowed there. Distinct
from issue 1 but multiplies it. Route content (road-shaped land beats) or
threat avoidance is untouched work.

## Infra footguns hit today (for the next operator)

- **Disk exhaustion** wedged backend prepare invisibly: compose creates
  nothing, `docker_vmangos_server.py` sleeps through its smoke loop, and its
  buffered stdout means `player.log` shows only "waiting for status" until
  exit. Check `df -h` first when prepare hangs; the upstream image rebuild
  writes tens of GB.
- Two concurrent `make traverse` launchers race container recreates and both
  lose ("Resource is still in use", healthz never up). Kill leftovers before
  relaunching.
- `docker_vmangos_server.py … down --volumes` run by hand resolves the
  **default** compose project, not the launcher unit's — it tears down
  `coworld-vmangos-*`, not `coworld-native-<unit>-*`.
- Flight recorder is still not ported to this branch: runs record only
  `status.json` + `player.log`, so per-tick observation facts (held keys,
  ground-step contents) are not diagnosable from artifacts.

## Best distances on record (context)

| Run | Result |
|---|---|
| `20260807T210656Z` (full spawn, post-pull #2, pre-crash) | **3,635 yd**, died at (−5552,−4835), 926 yd planar from Dustwallow |
| `20260807T215819Z` (wet lab) | swam to ≈(−6403,−4901) then beached (issue 2 → issue 1) |
