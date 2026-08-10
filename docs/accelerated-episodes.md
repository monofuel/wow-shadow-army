# Accelerated episode results

Full 720-second league episodes (10x simulation). Score is
`level + xp / next_level_xp`, the league's own formula.

How to regenerate: `make accelerated-episode` (720 wall seconds, local
`--league=ten-x`). Score is from `tools/episode_score.py`. Upstream's Kobold
bot reaches ~5.28 in this league, which is the number worth chasing.

| date | brain | score | level | notes |
|---|---|---|---|---|
| 2026-08-08 | grind (fixed patrol box) | 1.385 | 1 | cleared its 35yd square in the opening minutes, then patrolled an empty clearing: zero attacks in 1346 decisions |
| 2026-08-08 | grind (roaming) | **4.791** | 4 | 67% of decisions were attacks, 55 kills, no run-ending death — **B0 ship bar** |
| 2026-08-08 | grind + quests (naive) | 1.000 | 1 | wedged on one questgiver for all 1380 decisions and never fought |
| 2026-08-10 | soft quests (budgeted) | **2.009** | 2 | **worse than B0** — budget killed Hawkwind lock but still burned travel; logged budget exhaust + Grull give-up; do not ship |

## Soft quests (2026-08-10)

Naive `QUESTS=true` zeroed the run (Chief Hawkwind, no dialog). Soft mode keeps
lua-bot dialog verbs (`/questaccept` etc., not RPB quest FSM / scene proofs) and
adds gates so grind always resumes:

- do not walk to **new** accepts until level ≥ 2 (turn-ins still allowed)
- do not walk to givers while a huntable mob is in search range
- 45s per-giver patience and 25s continuous quest budget
- interact stop distance 3.5 yd

Ship only if a full episode score **beats 4.791**.
