# Accelerated episode results

Full 720-second league episodes (10x simulation). Score is
`level + xp / next_level_xp`, the league's own formula.

How to regenerate: `make accelerated-episode` (grind), or flip `QUESTS` at the
top of `lua/entry/accelerated.lua` and run it again. Upstream's Kobold bot
reaches ~5.28 in this league, which is the number worth chasing.

| date | brain | score | level | notes |
|---|---|---|---|---|
| 2026-08-08 | grind (fixed patrol box) | 1.385 | 1 | cleared its 35yd square in the opening minutes, then patrolled an empty clearing: zero attacks in 1346 decisions |
| 2026-08-08 | grind (roaming) | **4.791** | 4 | 67% of decisions were attacks, 55 kills, no run-ending death |
