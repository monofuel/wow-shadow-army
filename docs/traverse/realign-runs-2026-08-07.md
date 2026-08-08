# Prefer-upstream realign — run log (2026-08-07)

Fix-forward log for getting `make traverse` (stock spawn → `duskwallow_coast`)
working again on `monofuel/petrel` after the upstream pull. One row per prove
run; **progress** is the best position before death/wedge, not the graveyard
teleport (`score` in a dead run's final status is corpse position and lies —
see root cause 5). Full route ≈ 5,125 yd planar; land beat ≈ 2,087 yd
northing; water entry ≈ 2,403 yd northing.

| # | Run id | Change under test | Furthest real progress | Outcome |
|---|---|---|---|---|
| 1 | `20260807T200310Z-941558` | none (baseline, uncommitted realign state) | 632 yd @ (-8555,-3163) | **Died** in mob territory; corpse invisible to strategy → travel-form cast spam on the corpse (misread at the time as "froze then killed") |
| 2 | `20260807T201240Z-954286` | aura form-guard; cast advances every tick; wet face-then-go steer; drop stop edges on `rpUnavailable` | 654 yd @ (-8533,-3144) | Wedged on the ridge line: stride target carried `z = pos.z`, every slope step rejected as vertical regression |
| 3 | `20260807T202311Z-968539` | goal-directed `advanceExploration` fallback | **regression** 170 yd @ (-9016,-2298) | Exploration walked *away* from the beat (frontier selection is origin-outward, not travel-goal-directed) |
| 4 | `20260807T203022Z-979892` | stride = `appendSteering` at the real beat target (true z) | 1,123 yd @ (-8064,-3648) z=61 | Crossed the ridge patch by **climbing off-route into the mountains** (lucky micro-path, not a fix), died in a mob camp → corpse cast spam again |
| 5 | `20260807T203813Z-992456` | same binary, headed (operator watch) | 653 yd @ (-8534,-3199) | Wedged at the ridge line again — same ~100 yd patch as runs 1/2 |

## Confirmed root causes so far

1. **Death is invisible to the strategy** (the "halts in the desert" symptom).
   `projectClientView` reads death from `gameplay.dead` / `gameplay.ghost`;
   the prefer-upstream pilot projection wrote a top-level `death` object and
   never set those keys → `is_dead` always false in Lua. `health_known` was
   also never projected, so `health_pct` hardcoded to 100 and the corpse
   fallback could never fire. A dead druid has form 0, so the Lua requested
   travel form forever on the corpse. Ghost only surfaced later via the
   aura-8326 fallback (the graveyard `dead_reset` hold). Fixed in
   `petrel_pilot.nim`: project `gameplay.dead`/`ghost` + `health_known`,
   refuse casts while dead/ghost, record `dead`/`ghost`/health honestly in
   `status.json`.
2. **Form-cast pipeline advanced one keystroke per 3 s** while holding
   position. Fixed: chat sequence drives every tick; aura evidence guards
   against toggle-off re-casts.
3. **`rpUnavailable` stop edges starved the fallback** — forward toggled off
   on alternating views. Fixed: drop the stop edges before the fallback.
4. **Fabricated step-target z wedged every slope** — `observedGroundStep`
   rejects steps that worsen `|z − dest.z|` (> 0.1 yd, contour 0.5). A step
   target at `pos.z` turned every downhill/uphill bearing into "vertical
   regression". Fixed: steer at the beat's real position.
5. **`status.json` hid the death state** — `ghost` was hardcoded false and
   no health/dead fields existed, which is how runs 1/4 got misdiagnosed.
   Fixed alongside cause 1.
6. **`advanceExploration` is not goal-directed travel** — do not hand Petrel
   legs to it (run 3). Attempted, measured, reverted.

## Open blockers (pre-existing, not regressions)

- **Tanaris land approach (G3) was never solved on any branch.**
  `merchant-bay-progress-2026-08-07.md` (old branch): "untouched 10x runs are
  failing before the water segment on the Tanaris land approach …
  rendered-floor/navmesh mismatches and terrain residency failures." The
  single 2,100-yd `land_approach` chord crosses a ridge line at
  x≈−8530..−8580 where every run wedges or detours into mob mountains.
- **Flight recorder not ported** (`petrel_debug` timeline/campaign-summary),
  so prefer-upstream runs record only `status.json` + `player.log` — far less
  than the docs' READ step expects.
- **Wet board (`CHECKPOINT=water_entry`) unproven on this branch** — the wet
  steer (`petrelSwimSteer`) has not yet had a measured wet-lab run. Number =
  best planar-to-goal while swimming+Aquatic, lower is better.

## Next

- Verify death visibility on a full-spawn run (dead=true in status, death
  hold instead of cast spam).
- Wet lab run to baseline the Number on this branch.
