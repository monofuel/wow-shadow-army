# Race Wow — standings, competitors, and petrel progress

Scoring: farthest authoritative **northing** across Kalimdor
(`world_x + 9187`; spawn = 0, Everlook goal ≈ 15,874) inside one
45-sim-minute episode at 10x. Division: Kalimdor Race. Rounds every
~30 min (observed round #1678, 2026-08-13). `is_champion` = OUR active
entry, NOT rank (see AGENTS.md).

## Course landmarks (northing from spawn)

| landmark | world x | northing |
|---|---|---|
| spawn (south Tanaris) | -9187 | 0 |
| water_entry (Tanaris coast) | -6784 | 2,403 |
| duskwallow_coast | -4627 | 4,560 |
| merchant_coast (inner bay) | -1817 | 7,370 |
| barrens_shore (Ratchet) | -910 | 8,277 |
| top_barrens | 1071 | 10,258 |
| felwood_cave_entrance | 6503 | 15,690 |
| Everlook (goal) | 6687 | 15,874 |

## Competitors (fill names from the leaderboard web UI — the CLI does
## not expose the entrant roll; observe/coworld return empty players)

| entrant | best score | last seen | notes |
|---|---|---|---|
| andre | 10,700 | 2026-08-13 | league leader; ~just past top_barrens |
| (petrel — us) | 2,400 hosted / 10,221 local | 2026-08-13 | see progress table |
| (several entrants) | 0 | 2026-08-13 | scoring zeros — league possibly flaky (monofuel) |

## Petrel version progress

| version | frozen SHAs (fork / wsa) | local best northing | hosted best | notes |
|---|---|---|---|---|
| v1 | 4c24e52f4 / eeb86be | 10,221 (lucky water entry; 14,088 yd, ~4.1 wall min) | 2,400 (#4) | waterline-spin cascade predates the fix: hosted episodes + monofuel's replay spin at the beach; the local 10.2k run rolled lucky entry dice |
| v2 | e261c3d84 / 7936932 | 10,204 (0 stalls, 0 deaths, clock-limited at top_barrens) | pending first round | spin structurally dead (turn clamp + one seaward target + JUMP releases); known flaws: land zig-zag (ticket 0013), flag-flicker bobbing (0002), cave wall-stick (0012) |
| v3 | 0f45b0aed / 2787505 | 9,980 phase-0 clean run; night median dragged by dice (wedges/fatigue/mobs) | submitted 2026-08-13 07:51Z, qualifying | BOTH wedge escapes live (0016+0016b, rescue demonstrated at the seam) + fatigue metric in FLIGHT; hypothesis: hosted 2.4k plateau = pre-water wedge family, v3 should climb past it; sub_1afb44aa, version ebf33966, guard over v2 c4c72440 |
| v4 | 0f45b0aed / 592766f | (same bot as v3) | submitted 2026-08-13 08:5xZ, pending | THE FIX: ENV PETREL_SWIM=1 — v1/v2/v3 hosted episodes all ran with the wet chain OFF (env gate default-off, image never set it); every hosted run parked at the waterline = ~2,400 = water_entry landmark. v3 round 1703 scored 2,367 and confirmed the plateau on a wedge-escape build; expected hosted with swim on: ~10k. sub_eb972b1f, version 0b2886a3, guard over v3 ebf33966 |

## Standings history (append-only)

| date (UTC) | our champion | our score | our rank | leader | leader score | notes |
|---|---|---|---|---|---|---|
| 2026-08-13 | petrel:v1 | ~2,400 | #4 | andre | 10,700 | v1 froze before the spin fixes; hosted runs stall at the beach. Several entrants at 0. |
| 2026-08-13 | petrel:v2 (submitted, qualifying) | — | — | andre | 10,700 | sub_6ef950c7, champion-guard replacement; expect ~10.2k when its round lands |
