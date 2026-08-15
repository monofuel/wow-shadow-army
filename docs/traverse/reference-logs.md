# Manual reference logs (human F9 movement-evidence)

Hand-driven recordings for teaching Petrel world mechanics. All are F9
activity logs (`vanilla_wow.real_playerbot_activity` JSONL, `human_step`
rows with a full player observation at ~1 Hz), recorded on the persistent
local realm at 1× with a human at the keyboard.

| Log | What it is |
|---|---|
| `local_data/reference-logs/great-lift-manual-20260809.jsonl` | The Great Lift (Thousand Needles ↔ Southern Barrens), 2026-08-09, Botwarrior (level 30). **Both lift platforms** (transport GO entries 11898/11899), ridden **up and down multiple times**. The ride signature: fixed x/y ≈ (-4667, -1828) while z sweeps ~-44 → ~+85 at ~20 yd/s. |
| `local_data/traverse-runs/20260807T041622Z-4035488/manual/real-playerbot-log-1786076362279-4043754-2.jsonl` | The manual coast swim, 2026-08-07 (77 MB, 1775 steps). The proven Tanaris water-entry → Dustwallow ribbon the cheese beats were sampled from; fatigue evidence analyzed in [duskwallow-plan.md](duskwallow-plan.md) and [merchant-bay-progress-2026-08-07.md](merchant-bay-progress-2026-08-07.md). |
| `local_data/reference-logs/timbermaw-manual-20260811-south-gallery-up.jsonl` | Timbermaw Hold cave walk 1/3, 2026-08-11, Cowcam (GM, mobs passive). South gallery climb, (6579, -2078) → the hold (6816, -2098), 49 steps / 48 s. |
| `local_data/reference-logs/timbermaw-manual-20260811-hold-to-entrance.jsonl` | Timbermaw Hold cave walk 2/3: back down from the hold to the Felwood cave mouth, (6816, -2098) → (6517, -2069), 38 steps / 37 s. Reaches within ~15 yd of the `felwood_cave_entrance` checkpoint. |
| `local_data/reference-logs/timbermaw-manual-20260811-hold-north-galleries.jsonl` | Timbermaw Hold cave walk 3/3: south gallery → the hold apex (x 7025) → east/north galleries down to (6875, -2306), 88 steps / 88 s. Deepest interior coverage of the three. |

Timbermaw walk notes (monofuel, 2026-08-11): the **Felwood entrance collision
is touchy — a JUMP was needed to get into the cave mouth properly**. Any bot
route through this entrance must expect the lip to reject plain forward
walking. Jump-scan finding (all three legs): `prior_input_execution.jumped`
is false on every sampled row — the logs are 1 Hz snapshots of 60 Hz frames,
so the jump fell between samples; the requirement stands on the pilot's
report. Leg 2 (`hold-to-entrance`) is NOT a continuous walk: it is 3 steps at
the hold, a `.tele` back to the cave mouth (visible as a 315 yd position
discontinuity), then 3 walked steps inward — the resampler's `--seed` mode
drops the pre-teleport preamble automatically.

Walked-coverage gaps (encore F9 targets, ~60 s each):
1. The mouth passage (6517, -2069) → (6579, -2078), ~62 yd — includes the
   jump lip approach.
2. The exit: north descent end (6875, -2306) → north tunnel (6606, -2363) →
   Winterspring west entry (6395, -2537).

These logs feed `tools/resample_trace_beats.py`, which generated the live
interior beat chain (`lua/config/traverse_finale_interior_beats.*`).

Recording recipe: `make play` (headed human session on the fork client),
chat + Enter to free the keyboard (startup capture bug), `F9` to start —
the terminal prints the log path — drive, `F9` to stop. Tele helpers:
`make lift-tele` / `tools/traverse_checkpoint.py`.
