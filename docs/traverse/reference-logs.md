# Manual reference logs (human F9 movement-evidence)

Hand-driven recordings for teaching Petrel world mechanics. All are F9
activity logs (`vanilla_wow.real_playerbot_activity` JSONL, `human_step`
rows with a full player observation at ~1 Hz), recorded on the persistent
local realm at 1× with a human at the keyboard.

| Log | What it is |
|---|---|
| `local_data/reference-logs/great-lift-manual-20260809.jsonl` | The Great Lift (Thousand Needles ↔ Southern Barrens), 2026-08-09, Botwarrior (level 30). **Both lift platforms** (transport GO entries 11898/11899), ridden **up and down multiple times**. The ride signature: fixed x/y ≈ (-4667, -1828) while z sweeps ~-44 → ~+85 at ~20 yd/s. |
| `local_data/traverse-runs/20260807T041622Z-4035488/manual/real-playerbot-log-1786076362279-4043754-2.jsonl` | The manual coast swim, 2026-08-07 (77 MB, 1775 steps). The proven Tanaris water-entry → Dustwallow ribbon the cheese beats were sampled from; fatigue evidence analyzed in [duskwallow-plan.md](duskwallow-plan.md) and [merchant-bay-progress-2026-08-07.md](merchant-bay-progress-2026-08-07.md). |

Recording recipe: `make play` (headed human session on the fork client),
chat + Enter to free the keyboard (startup capture bug), `F9` to start —
the terminal prints the log path — drive, `F9` to stop. Tele helpers:
`make lift-tele` / `tools/traverse_checkpoint.py`.
