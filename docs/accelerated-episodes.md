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
| 2026-08-08 | grind + quests | 1.000 | 1 | wedged on one questgiver for all 1380 decisions and never fought; see below |

## Why quests are off

Turning `QUESTS` on cost the entire episode. The bot picked Chief Hawkwind,
never got a dialog open, and stood there — zero kills, zero XP. Upstream hit
the same wall from the other direction and disabled their own accelerated
quest work after it delayed the first kill.

The dialog machinery itself is proven at the unit level (accept, turn-in,
row selection, and the guard that refuses anything outside the dialog verbs),
so what is missing is the approach: reaching interaction range and confirming
the client opened something. A questgiver now gets 45 seconds of patience
before the brain writes it off, so a future attempt cannot cost a whole run,
but the flag stays off until an episode says otherwise.
