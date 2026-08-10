# Duskwallow segment plan — 2026-08-07

**Status:** active day plan — **isolated swim only**  
**Segment name (config):** `duskwallow_coast` (Dustwallow Marsh coast water)  
**Parent thesis:** [petrel-plan.md](petrel-plan.md) · feet: [pathfinding-plan.md](pathfinding-plan.md)  
**Manual gold path:** `local_data/traverse-runs/20260807T041622Z-4035488/manual/`  
**Debug contract:** [army-debug.md](army-debug.md)

This file is the **only** swim scope for today. Merchant Bay, Barrens land,
Everlook, and bird variants are out of scope until this segment is green.

---

## 1. Isolated mission

| | |
|---|---|
| **Start (segment)** | Tanaris north water entry |
| **End (segment)** | Dustwallow coast water |
| **Form** | **Aquatic** the whole wet prove |
| **Path** | Stay in water; no dry land-cut; no beach trash farming |
| **Death** | Stop run, reset, re-run — no SOAP revive |

### Coordinates (authoritative)

| Point | XYZ (map 1) | Notes |
|---|---|---|
| Fixture spawn (not segment start) | `-9187.0, -2530.25, 14.09` | Stock league seed |
| **Water entry** | `-6784.5, -4833.9, 0.7` | Checkpoint tele / segment start for wet debug |
| Water entry beat (config) | `-6784.5, -4920.0, 0.7` r=50 | `lua/config/traverse_beats.json` (seaward of old prove) |
| **Duskwallow goal** | **`-4627.01, -4869.45, -2.37`** | `goal_id = duskwallow_coast`, r=**100** |

### Segment length (geometry)

| Metric | Value |
|---|---:|
| Planar water_entry → duskwallow (`-6784.5,-4833.9` → goal) | **~2,158 yd** |
| Northing ΔX (same points) | **~2,157 yd** |
| Northing from fixture start to water_entry | **2,402.5 yd** |
| Northing from fixture start to duskwallow | **~4,560 yd** |

Beat list for the wet corridor lives in `lua/config/traverse_beats.json`
(`coast_01` … `coast_11` → `duskwallow_coast`). Strategy advances sparse
beats; feet must not treat “one chord to Dustwallow” as pathing.

---

## 1b. Ocean swimming (how this strip actually works)

Agents keep failing this segment by collapsing **two independent systems** into
one wrong rule. Read this before changing liquid policy.

### Two systems, not one

| System | Signal | What it means | What it does **not** mean |
|---|---|---|---|
| **Swim permission** | Client liquid + swimming (Aquatic for breath) | You may keep swimming here | That the water is “safe forever” |
| **Fatigue** | Mirror-timer type 0 (`fatigue_*` on ClientView) | You’re spending time in **unsafe / exterior ocean** | That the water is unswimmable |

**Modeled seafloor depth is telemetry only.** “No bottom,” deep bottom, or
`depth_unknown` often *correlates* with the fatigue ocean, but depth is **not**
a movement gate. Rejecting headings as `shallow` / inventing a min-depth law
was a false stop while still wet + Aquatic
([merchant-bay-progress-2026-08-07.md](merchant-bay-progress-2026-08-07.md)).

Fatigue **drains** over open exterior ocean. Fatigue **recovers** when the body
returns to the **playable coastal water** (the real “game world” liquid band
near shore geometry — not “find a bottom to stand on,” not mesh triangles).
When the bar empties → damage → death if you stay offshore.

```text
[ beach / trash / dry ]  |  SAFE COAST RIBBON  |  FATIGUE OCEAN → death
                         |  (human F9 path)    |
                         |  mid fatigue OK     |
```

- **Too far inland** → land, form drop, beach trash (fails wet prove).  
- **Too far seaward** → still swimming, still “valid water,” **fatigue kills**.  
- **Human path** rides the ribbon: close enough to stay recoverable, far enough
  not to scrape shore every yard. It is a **tube**, not a straight chord to
  Dustwallow.

### League score vs control law

Kalimdor scoring rewards **world X (northing)**. That is a **score metric**, not
the swim controller objective. A shorter open-ocean chord can raise X faster and
still be a **failed** segment (fatigue death). Humans “waste” path length to stay
on the ribbon. The bot that optimizes pure bearing / planar distance to a far
beat will **leave monofuel’s personal run** and die offshore.

### Sparse beats ≠ path following

`coast_01`…`coast_11` are **samples of a centerline** (from / aligned with the
human route). They are not a continuous constraint. If feet take **shortest
liquid heading** between samples, the interpolant bows **seaward** into clear
ocean: collision-free, “following,” and fatal.

Authoritative ribbon: F9 log
`local_data/traverse-runs/20260807T041622Z-4035488/manual/real-playerbot-log-1786076362279-4043754-2.jsonl`
— **positions over time as corridor evidence**, not keypress replay.

### Fatigue closed loop

Fatigue is a **slow integral of corridor error** (how long / how far seaward).

| Phase | What you see | Correct reading |
|---|---|---|
| Early offshore | Bar still high, X still increasing | Already wrong; not “fine” |
| Mid | Bar dropping, still swimming | Need **cross-track back to ribbon**, not more pure north |
| Late | Bar critical far from shore | Recovery swim is long; death likely if still open-ocean seeking |
| Mid fatigue **on** the ribbon | Remaining can dip (~0.6 seen on human run) | Survivable; do **not** panic thrash or invent 0.85 emergency retreat |

Recovery action class: **reduce cross-track toward playable coast / human
centerline** until the timer recovers. Not L/R thrash, not jump, not depth
gates, not “touch cliff mesh” as a ritual.

### Failure mode we actually observe

```text
CHECKPOINT water_entry → Aquatic + north
  → liquid steer to far beat / chord
  → cross-track grows seaward (no collision)
  → fatigue starts while “progress” still looks good
  → no hard ribbon pull
  → bar empty far from safe water → death
```

Example: headed wet run `20260807T180948Z-741510` — tele worked, swam
`coast_01`…`coast_05`, furthest X ≈ `-5936`, then **death** with ~**1,451 yd**
planar still to duskwallow. Not a mesh “can’t move” failure: **wrong water
volume** (open-ocean point-to-point instead of coastal-corridor follow).

### Mental model (locked)

```text
fair-play ordinary swim input
  ∧ stay liquid + Aquatic for the prove
  ∧ stay near human coastal ribbon (fatigue geometry)   ← primary wet constraint
  ∧ only then advance northing / beats toward duskwallow
```

| Correct | Wrong |
|---|---|
| Depth = debug | Depth = min depth to allow swim |
| No navmesh on ocean = use liquid steer / direct water | No navmesh = unswimmable |
| Fatigue = leave unsafe residency | Fatigue = stop swimming or thrash |
| Northing = score | Northing = only control objective |
| Sparse beats + continuous corridor cost | Sparse beats alone = path |
| Human F9 = ribbon gold | Human F9 = keypress script |

---

## 1c. Working process (mandatory — no coding without this)

**Goal of the process:** monotonic progress toward duskwallow. Feeling smarter,
cleaner architecture, or “better logs” does **not** count unless the number
moves the right way — or the change is pure instrumentation that is proven
not to regress the number.

### Primary metric (the Number)

| | |
|---|---|
| **Name** | `best_planar_to_duskwallow_wet` |
| **Definition** | Minimum planar distance (yards) to goal `(-4627.01, -4869.45)` at any sample where the bot was **swimming** and **Aquatic confirmed**, during a standard wet-lab run |
| **Direction** | **Lower is better** |
| **Win** | Number ≤ **25** and run meets §2 success bar (alive hold, no land-cut, durable artifacts) |

**Secondary (context only — never sole accept criterion):**

| Metric | Use |
|---|---|
| `furthest_northing_x` while wet+Aquatic | How far north; can improve while dying offshore — **not** enough to keep a change |
| Beats reached (`coast_N`) | Debugging breadcrumb |
| Time-to-death / fatigue min remaining | Failure mode label |
| Cross-track vs human F9 ribbon | Explains *why* the Number moved |

**Forbidden “progress” claims:** max X alone, land yards, “nav following longer,”
anomaly count down, code deleted, “foundational,” subjective watch quality.

### Baseline and board

Keep a **single live baseline** for the standard wet lab:

| Field | Rule |
|---|---|
| **Mode** | `make traverse-headed CHECKPOINT=water_entry` (default) or headless same CHECKPOINT — **do not mix** when comparing |
| **Sim scale** | Same as launcher default (document if changed) |
| **Goal** | `duskwallow_coast` / `TRAVERSE_GOAL_*` unchanged |
| **Baseline Number** | Best `best_planar_to_duskwallow_wet` on current mainline policy |
| **Baseline run id** | Durable `local_data/traverse-runs/<id>/` that produced that Number |

Until a cleaner wet-lab series exists, **historical floor** (any durable run,
not yet locked as process baseline):

| | Value | Run |
|---|---:|---|
| Best known wet+Aquatic planar | **~187 yd** | `20260807T025221Z-3829787` (anomaly — distance only) |
| Recent headed wet lab death | **~1,451 yd** remaining at death; through `coast_05` | `20260807T180948Z-741510` |

**First process step when resuming work:** re-run the standard wet lab once,
write the Number + run id into §7 as **baseline**, then only accept changes
that beat that baseline under the same mode.

### Improve-or-revert law

1. **One change (or one tightly coupled patch) at a time.**  
2. **Measure** with ≥1 standard wet-lab run (prefer 2 if the delta is small or
   noisy). Record run id, Number, secondary metrics, outcome.  
3. **Accept** only if Number **strictly improves** (lower planar), or reaches
   G1 success.  
4. **Revert** immediately if Number is equal or worse — including “looks
   better on video” with a worse or equal Number.  
5. **No stacking.** Do not land change B on top of unproven change A.  
6. **Death / anomaly:** the Number is still the min planar while wet+Aquatic
   *during* the run if timeline supports it; if instrumentation only has final
   pose, use final wet+Aquatic pose and say so. Do not hide a regression by
   switching which field you report.

**Exception — instrumentation only:** logging, ClientView fields, admin
export, offline log tools. These may land without improving the Number **only
if**:

- A standard wet-lab run shows Number **not worse** than baseline (within a
  documented noise band, default **0** — treat equal as OK for pure logs,
  worse as revert), and  
- They do not change navigate/cast/hold decisions.

If “just logging” regresses the Number → **revert**.

### Loop (every iteration)

```text
1. READ
   - Baseline Number + run id from §7
   - Failing (or best) run: campaign-summary, status, timeline, transitions,
     anomalies, player.log; human F9 ribbon if cross-track matters
   - Optional: offline tools over existing logs (no live run required for READ)

2. HYPOTHESIS
   - One sentence cause
   - Label each support: observed | inferred | unknown
   - Cite run id + fields (fatigue, pose, intent, nav branch, form, …)
   - State the smallest disproof

3. CHANGE
   - Single policy/nav/logging patch aimed at that hypothesis
   - No goal substitution (“foundations”) without a Number plan

4. MEASURE
   - Same wet-lab command as baseline
   - New run id → compute Number
   - Update working notes with both numbers side by side

5. DECIDE
   - Number better → keep; promote baseline; write §7 row
   - Number same/worse → REVERT; keep the analysis note (what failed)
   - Never leave a regression “to fix later” on the branch of record
```

### Logging and analysis tools (encouraged)

Allowed anytime under the instrumentation exception:

| Kind | Purpose |
|---|---|
| ClientView / status fields | Fatigue, liquid, form evidence, pose at higher fidelity |
| Timeline / campaign fields | Min planar-to-goal while wet+Aquatic **during** run (not only final) |
| Offline tools on `traverse-runs/` | Rank runs by Number, plot X/Y vs human F9, fatigue vs cross-track, beat advance |
| Compare tool | Baseline run id vs candidate run id → Number delta |

**Analysis does not replace MEASURE.** A beautiful plot of why we died is not
progress until a post-change wet lab beats the baseline Number.

### Noise and fairness

- Prefer **headed + CHECKPOINT=water_entry** for wet iteration so land is not
  the confounder.  
- G3 (full spawn) is a **separate board** — do not use a land-stuck run to
  accept or reject a swim patch.  
- If two runs of the *same* binary differ by more than an agreed band, run a
  third before accept/revert; default band is tight — flaky improvement is
  not a keep without a second confirming run.  
- SOAP checkpoint is setup only; Number is still ordinary swim progress after
  tele.

### Anti-patterns (process violations)

| Violation | What to do |
|---|---|
| Multi-hour “foundations” with no Number | Stop; revert to last baseline; re-measure |
| Keep change that dies earlier but “nav is cleaner” | Revert |
| Improve max X while planar-to-goal gets worse | Revert (offshore cheese) |
| Claim G1 without ≤100 wet+Aquatic hold | Reject |
| Change metric definition mid-series to make a patch look good | Forbidden; rebaseline explicitly if metric must change |

### Definition of done for a work session

Session succeeded only if **at least one** of:

1. New baseline Number **strictly better** than session start, recorded in §7, or  
2. G1 achieved, or  
3. Pure instrumentation landed with Number not worse **and** the next session
   has a clearer MEASURE (e.g. during-run min planar now automatic).

“Understood the problem better” with no Number move and no instrumentation
delta is an incomplete session — write the hypothesis, do not pretend ship.

---

## 2. Success bar (this segment only)

A run **counts** only if **all** of the following hold at stop:

1. Alive (not dead / ghost thrash).  
2. **Swimming** and **Aquatic Form confirmed**.  
3. Planar distance to **`(-4627.01, -4869.45)` ≤ 25 yd** (beat `radius`; was 100).  
4. No dry-land shortcut to the score.  
5. No fatigue exhaustion death.  
6. Durable artifacts under `local_data/traverse-runs/<id>/` with
   `campaign-summary.json` showing the above.

### Campaign gates

| Gate | Requirement |
|---|---|
| **G1** | One clean automated success (checkpoint-start OK) |
| **G2** | Five consecutive clean successes (same start mode) |
| **G3** (later) | One clean success from stock Tanaris spawn (no wet tele) |

**Do not** claim Merchant Bay, Everlook, or bird-variant progress until G1 is
real. Historical high northing without (2)+(3) is **distance evidence only**.

### Explicit non-goals (today)

- Merchant Bay / Barrens / Everlook land route  
- Petrel / Skua / Gannet packaging  
- Great lifts (Gannet)  
- SOAP/GM revive or ghost recovery  
- Modeled seafloor depth as a swimmability gate  
- “Foundational refactors” that do not move pose toward the goal  
- L/R thrash, jump-while-wet, hop carpets as pathing  

---

## 3. Current achievement (recorded 2026-08-07; amended 2026-08-09)

**The segment HAS passed, once** — recovered from the durable artifacts on
2026-08-09 (the scan below predated it and the scoreboard was never
updated):

| | |
|---|---|
| Run | **`20260807T183426Z-790239`** (2026-08-07 18:34Z, old ClientView stack) |
| Outcome | `outcome=success`, `at_goal=true` under the run's own config (radius **100**; final dist **98.66 yd**) |
| Proof | All **42** beats reached (`water_entry` → `cheese_01..40` → `duskwallow_coast`), wet + Aquatic the whole prove, 0 form losses, 0 input rejections, alive at hold |
| Fatigue | min remaining **0.2497** (194 sim-s exposure), trend `inactive` at hold — survived without any fatigue policy |
| Witness | monofuel watched the run live; confirmed correct coast-ribbon swim |

The §2 bar was tightened to 25 yd **one minute after** this run
(`3ab8330`); under today's bar it is a near-pass. It remains the proof the
cheese-carpet strategy works. It ran on plumbing deleted in `1454caa`, so
it does not validate the lua-bot host — that is what the wet lab below
re-proves.

Earlier scan (2026-08-07, before the success): durable
`local_data/traverse-runs/*/campaign-summary.json` + final `status.json`
poses showed no passing run.

### Best distance (not a pass)

| Rank claim | Run id | Final / furthest pose | Notes |
|---|---|---|---|
| **Closest to duskwallow while wet+Aquatic** | `20260807T025221Z-3829787` | **`(-4451.79, -4803.14, -3.82)`** | Planar **~187 yd** to goal; still **>100 yd**; outcome `anomaly_pending` |
| Next closest wet+Aquatic | `20260807T031741Z-3896930` | `(-4885.80, -4806.47, -3.75)` | Planar **~266 yd**; furthest X **`-4853.94`** |
| Closest wet under 400 yd (other) | `20260807T024029Z-3801457` | `(-4266.67, -4808.61, -3.41)` | Planar **~365 yd**; anomaly stop |
| **Highest furthest_northing_x ever** | `20260807T021511Z-3724036` | furthest **`x = -2772.86`** | **+6,414 yd** from spawn, **~1,269 yd** planar to old merchant point; past duskwallow X but **~1,931 yd planar** from duskwallow goal (wrong Y corridor / anomaly). **Not** segment success; predates depth-gate correction |

### How to read the numbers

- **Segment progress (preferred):** planar yards remaining to
  `(-4627.01, -4869.45)` while swimming + Aquatic.  
- **Northing from water:** `final_x - (-6784.5)`. Full segment ≈ **2,157 yd**.  
  Best wet close approach (~187 yd out) is roughly **~2,333 yd** north of
  water_entry in X — near the end geometrically in X, still short on the
  proof envelope.  
- **Do not** use max world-X alone as “almost Dustwallow” if planar to the
  goal is still hundreds of yards (coast vs open water).

### First blocker (policy honesty)

| Blocker | Evidence |
|---|---|
| **Leaves the coastal ribbon** → open ocean → fatigue death | Headed `CHECKPOINT=water_entry` `20260807T180948Z-741510`: wet through `coast_05`, seaward of human path, death ~1.4k yd short of duskwallow (see §1b) |
| First coastal cliff / liquid routing still not a clean pass | Depth-gate false stop at `(-6508.6, -4859.7)` on `20260807T040143Z-4015926` (removed); live clean G1 still missing |
| Land approach freezes on some untouched 10x runs | Prerequisite for G3 only; wet debug may use `CHECKPOINT=water_entry` |

### Manual reference (human, works)

Run **`20260807T041622Z-4035488`**:

| Artifact | Path |
|---|---|
| Full F9 swim (authoritative) | `…/manual/real-playerbot-log-1786076362279-4043754-2.jsonl` (~77MB, 1,775 steps) |
| False-start F9 | `…/manual/real-playerbot-log-1786076342152-4043754-1.jsonl` |
| Client log | `…/player.log` |

Use as **centerline evidence**, not keypress replay. Detail:
[traverse-2026-08-06.md](traverse-2026-08-06.md) § manual route.

### Human fatigue clear positions (F9 gold path)

From the complete manual log above (1,775 `human_step`s): every sample where
`fatigue_timer_active` went **true → false** (fatigue went away). Map 1.
At each clear, `fatigue_remaining_fraction` was **1.0**. False-start log had
**no** clear events.

| # | x | y | z | min fatigue during bout |
|---:|---:|---:|---:|---:|
| 1 | -6212.07 | -4898.94 | -4.12 | 0.961 |
| 2 | -6132.93 | -4862.77 | -4.61 | 0.850 |
| 3 | -5992.12 | -4798.81 | -0.76 | **0.592** (lowest) |
| 4 | -5931.18 | -4795.98 | -5.93 | 0.834 |
| 5 | -5796.50 | -4695.21 | -2.51 | 0.632 |
| 6 | -5651.18 | -4792.12 | -2.76 | 0.644 |
| 7 | -5619.63 | -4799.54 | -3.99 | 0.994 (blink) |
| 8 | -5523.22 | -4832.72 | -4.43 | 0.761 |
| 9 | -5459.74 | -4862.15 | -6.19 | 0.858 |
| 10 | -5392.13 | -4892.86 | -6.99 | 0.867 |
| 11 | -5362.84 | -4904.10 | -6.74 | 0.978 (blink) |
| 12 | -5248.47 | -4898.10 | -6.87 | 0.892 |
| 13 | -5116.02 | -4863.38 | -9.30 | 0.742 |
| 14 | -4971.87 | -4762.63 | -6.03 | 0.652 |
| 15 | -4814.44 | -4857.20 | -3.08 | 0.628 |
| 16 | -4691.23 | -4866.47 | -2.24 | 0.875 |

**16** clears total. #7 and #11 barely dipped (min ≥ 0.97) — short timer
flickers. Meaningful recovery cluster is roughly **Y ≈ -4695…-4906** along this
coast ribbon, not deep open ocean. Use as evidence of **where fatigue returns**
on a survivable human path; not a waypoint carpet to hard-code as the only
legal path.

---

## 4. Operator loop (local)

| Mode | Command | Use |
|---|---|---|
| Wet lab (preferred for G1/G2) | `make traverse-headed CHECKPOINT=water_entry` | SOAP tele after login; skip desert tax |
| Headless wet | `make traverse CHECKPOINT=water_entry` | Same tele path |
| Full spawn prove (G3 only) | `make traverse` / `traverse-headed` **without** CHECKPOINT | Fair local shape |
| Status | `local_data/traverse-cv-status.json` | Live pose / intent / form |
| Runs | `local_data/traverse-runs/<id>/` | `campaign-summary.json`, `timeline.jsonl`, anomalies |
| Admin | `127.0.0.1:7788` | [army-debug.md](army-debug.md) |

Checkpoint tele is **local setup only** — not tournament progress, not death
recovery. Fair prove remains ordinary movement from stock spawn (G3).

Default goal env for the CV launcher already points at duskwallow
(`TRAVERSE_GOAL_*` ≈ `-4627.01` in `tools/traverse_cv.sh`). Keep it there;
do not retarget Merchant Bay during this campaign.

---

## 5. Work order

**Process of record is §1c.** Improve-or-revert on `best_planar_to_duskwallow_wet`.
No goal substitution. Investigation contract: [army-debug.md](army-debug.md).

Technical focus order (each step still requires a better Number to keep):

1. Instrument during-run min planar + fatigue + ribbon cross-track if missing.  
2. Stay on human coastal ribbon (kill seaward open-ocean chords).  
3. First cliff + mid-corridor without depth gates; shoreward fatigue recovery.  
4. G1 → G2 → only then G3 / birds.

### Agent rules (from overnight + ocean failures)

| Do | Don't |
|---|---|
| Improve **the Number** or revert | Ship “foundations” with equal/worse Number |
| Optimize **ribbon + planar to duskwallow** | Treat max X alone as progress |
| Treat **no bottom / deep ocean** as fatigue geography | Treat depth / missing mesh as unswimmable |
| Pull **toward playable coast** when fatigue is high | L/R thrash, jump-while-wet, pure seaward northing |
| Read traces / build log tools before guessing | Stack recovery on unproven obstacles |
| Use CHECKPOINT tele for wet iteration | Treat scenario-bot setup tele as fair-play ban |
| Death → reset + re-run | SOAP revive rabbit-hole |

---

## 6. Relation to bird variants (context only)

From [traverse-2026-08-07.md](traverse-2026-08-07.md) — **not today's delivery**:

| Bird | Swim ends | Then |
|---|---|---|
| **Skua** | This duskwallow segment | Travel Form land north |
| **Petrel** | Merchant Bay / Barrens water | Travel Form land north |
| **Gannet** | None (lifts) | Blocked on lift logs |

Skua is **blocked on G1/G2 of this plan**. Petrel is blocked on a longer wet
route after this segment is solid.

League Everlook goal (not this segment):
`(6687.333052, -4647.667, 721.678)`, `reached_goal` within **300 yd**.
Score is still max northing X; this file does not optimize for Everlook.

---

## 7. Scoreboard (process board)

### Process baseline (wet lab — update only via §1c accept)

| Field | Value |
|---|---|
| Mode | **`make traverse-wet`** (lua-bot host; SOAP tele to `wet_start`, headless, PETREL_SWIM=1) — locked 2026-08-10 |
| Metric | `best_planar_to_duskwallow_wet` (lower better; computed by the harness from status samples with swimming + Aquatic) |
| **Baseline Number** | **295.8** (best; sibling configs 378.8 / 403.1) |
| **Baseline run id** | health-log stamp `20260810T024114Z` (v8 dense carpet); current line v12 `20260810T033603Z` = 403.1 |
| G1 / G2 | ✗ / ✗ on the lua-bot host (historical G1: `20260807T183426Z-790239`, old stack, §3) |

### 2026-08-10 robustness campaign (batteries 1-5)

Fixture repair (headed targets restored: full course by default,
CHECKPOINT tele on time, corpse-refusal) then robustness: no-breach
surfacing (JUMP releases within 2 yd of the surface), cliff slide-off
reflex, swim collision sub-stepping (0.8 yd), v13 refill beats (one per
human safe-bout entry, tight capture while the bar drains), and a
walk-to-waterline recovery leg (releases on observable liquid).

Gate history: **segment gate MET in battery 3 (2 consecutive PASSes,
24.6/23.7 yd)**; full course has PASSed once headless (24.3 yd) and twice
under monofuel's eyes (headed), but per-battery variance remains: battery
5 threw three far-graveyard deaths on the same code. Open: late-route
(~x -5400..-4700) mortality — fatigue deaths at hp 1 and residual falls —
needs a dedicated autopsy of that stretch. Regressions held: desert PASS
in every battery.

### 2026-08-10 wet-lab campaign (29 runs, lua-bot host)

Number progression: 2158 (never wet) → 1418 → 1298 → 1155 → 821 → 295.8
→ 378.8 → 403.1. Every fix is a commit on `monofuel/traverse` (brain,
route, harness) or `monofuel/master` (fork). What the campaign proved:

1. **Casting**: chat-driven form casts must own consecutive frames or the
   open edit box eats the keyboard (frozen swimmer) / pollutes the text
   (formless drowning). Fixed in the pilot; action-button path preferred.
2. **Route depth**: z-following at 10x used to fall through unstreamed
   collision into the void (server failsafe → graveyard teleports).
   Fixed in client physics: a swimmer's descent requires floor evidence.
3. **Fatigue**: the refill is INSTANT and binary (monofuel); the human
   track's shoreward weave is load-bearing. The carpet is now the F9
   track resampled over samples where the human's fatigue timer was
   inactive (measured safe water) — `tools/resample_human_ribbon.py`.
4. **The -5675,-4770 wall spur**: surface path pins on it; the seaward
   bypass costs ~a full fatigue bar (unaffordable); the human's under-
   dive is the only line, followable since the physics fix.
5. **Remaining blocker**: late-route (~x -4950..-4800) falls and parks —
   the seat freezes or falls near the endgame with the goal ≲400 yd out.
   The park watchdog (surface-ride window) is in; falls under
   investigation.

### Historical distance (not automatic baseline)

| Date | Kind | Number (planar yd, lower better) | Run id | Notes |
|---|---|---:|---|---|
| 2026-08-07 | best attempt any mode | **~187** | `20260807T025221Z-3829787` | wet+Aquatic; anomaly; not process baseline until reproduced under wet lab |
| 2026-08-07 | headed wet lab death | **~1451** at death | `20260807T180948Z-741510` | through `coast_05`; off-ribbon / fatigue |

### Accepted improvements (append only on keep)

| Date | Before → After (yd) | Run id | Change one-liner |
|---|---|---|---|
| — | — | — | — |

Clean G1 rows also satisfy §2 fully; attempts only need a better Number + §1c.

### Live re-verify — `make traverse` 2026-08-07

Ran stock headless `make traverse` (no `CHECKPOINT`), run
**`20260807T180604Z-733517`**. Launcher env matched this plan:
`TRAVERSE_GOAL_*=-4627.01,-4869.45,r=100`, `goal_id=duskwallow_coast`.

| | |
|---|---|
| Final pose | `(-7479.66, -4171.33, 14.76)` — **still dry land** |
| Furthest X / northing | `-7479.66` / **+1,707 yd** from spawn |
| Planar to duskwallow | **~2,937 yd** remaining |
| Planar to water_entry | **~960 yd** (never wet) |
| Beats reached | none (`active_beat=land_approach`) |
| Stop | severe anomaly `movement_without_progress`; nav land recovery thrash |
| Success | **false** |

Re-scanned all durable runs after this launch: historical bests in §3 still
hold; still **zero** clean ≤100 yd wet+Aquatic successes.

### Live wet lab — `make traverse-headed CHECKPOINT=water_entry` 2026-08-07

Run **`20260807T180948Z-741510`** (headed, SOAP tele to water).

| | |
|---|---|
| Tele | Worked — wet + Aquatic within seconds of login |
| Beats | through **`coast_05`** |
| Furthest X | **`-5936.5`** (~**+3,250 yd** from spawn) |
| Final | `(-6078.0, -4884.4, -1.9)` · planar duskwallow **~1,451 yd** |
| Stop | **death** / `release_spirit` (fatigue / off-ribbon ocean — see §1b) |
| Success | **false** |

---

## See also

- [petrel-plan.md](petrel-plan.md) — full course thesis  
- [pathfinding-plan.md](pathfinding-plan.md) — RPB feet ownership  
- [checkpointing.md](checkpointing.md) — SOAP tele mechanics  
- [merchant-bay-progress-2026-08-07.md](merchant-bay-progress-2026-08-07.md) — depth-gate autopsy (broader scope; superseded for *goal*)  
- [traverse-2026-08-06.md](traverse-2026-08-06.md) — campaign checklist + manual learnings  
- Config: `lua/config/traverse_beats.json`, `tools/traverse_checkpoints.json`
