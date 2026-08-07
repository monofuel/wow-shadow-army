# Merchant Bay progress — 2026-08-07

## Goal and proof state

The current goal is a robust swim from the Tanaris desert coast to Merchant
Bay. The route must remain in swimmable water, preserve Aquatic Form, avoid
ocean fatigue, and use the fork's real navigation and collision information.

The implementation has not passed its proof gates yet. We have not completed
the required five consecutive `water_entry` runs or three consecutive untouched
Tanaris-start runs. The current liquid policy is not capable of routing around
the first coastal cliff reliably and must not be described as working
pathfinding.

## Correction: invalid depth assumption

The 2026-08-07 implementation incorrectly treated modeled seafloor depth as a
swimmability requirement. It rejected candidate headings below an invented
7.5-yard threshold. This assumption was not supported by WoW movement rules:
the character can continue swimming over ocean water regardless of how far the
modeled bottom lies below it.

The earlier observation that Aquatic Form was lost near a modeled 6.53-yard
sample did **not** establish that depth caused the loss. Treating the later
7.93-yard sample as a safe lower bound repeated the same correlation/causation
error. Those numbers are diagnostics only and must not gate ocean navigation.

Run `20260807T040143Z-4015926` demonstrates the damage: the headed bot swam a
straight line toward wet leg A, then rejected all headings as `shallow` or
`depth_unknown` at `(-6508.6, -4859.7)` and stopped beside the cliff. The bot
was still swimming and in Aquatic Form. The stop was caused by our invalid
policy, not proof that the water was unswimmable.

For this route, the relevant evidence is liquid presence, the live swimming
flag, Aquatic Form, authoritative physical collision, movement progress, and
fatigue state. Modeled depth remains useful telemetry but is not a movement
permission gate.

## Distance gained from the Tanaris start

The campaign's northing score is the increase in world `x` from the fixed
Tanaris start at `x = -9187`. It is monotonic progress along this coast, not the
bot's total path length. The configured route milestones are:

| Milestone | Northing gained from start | Planar distance remaining to Merchant Bay |
|---|---:|---:|
| `water_entry` | 2,402.5 yd | 5,321.3 yd |
| `wet_leg_a` | 2,987.0 yd | 4,745.5 yd |
| `wet_leg_b` | 4,187.0 yd | 3,545.1 yd |
| `wet_leg_c` | 5,387.0 yd | 2,309.3 yd |
| `wet_leg_d` | 6,587.0 yd | 1,075.9 yd |
| `merchant` | 7,653.3 yd | 0 yd |

Historical fatigue failures around `x = -5740` represented about **3,447 yd**
of northing from the start, or **45%** of the required northing. They do not
change the current first blocker at the coastal cliff. The best recorded run so
far, `20260807T021511Z-3724036`, reached `x = -2772.9`:
**6,414 yd** from the start, about **84%** of the required northing, with
1,268.8 planar yards remaining. That run ended on a debugging anomaly rather
than a valid Merchant Bay success and predates this correction, so it is
distance evidence only—not validation of the current navigation policy.

## Implemented infrastructure

- The Lua bot now runs inside the fork's Nim client and supplies named intents;
  the client remains responsible for per-frame navigation and input lowering.
- ClientView exposes typed fatigue state as well as the existing liquid,
  swimming, breath, form, and movement observations.
- Liquid coverage, modeled depth, collision, and progress are recorded for
  diagnosis. The depth-based candidate rejection built on top of that telemetry
  is invalid and is not a completed navigation capability.
- Dry-to-water entry has a bounded, explicitly logged observation grace path.
- Experimental fatigue recovery uses hysteresis and is owned by the liquid
  corridor policy. Its route behavior is not proven.
- Accepted form casts wait for ClientView confirmation, and navigation and form
  batches share one client-owned input sequence allocator.

## Debugging and durable evidence

Every run now writes a timestamped folder under `local_data/traverse-runs/`.
Artifacts include the event trace, campaign summary, anomaly context, and
rendered evidence where available. Runs are not automatically pruned.

The trace records wall and simulation time separately, typed liquid/form/fatigue
observations, position and displacement, chosen navigation branch, probe
rejections, final emitted inputs, and their emitting layer. Severe anomalies
capture their preceding context and stop the run. The admin surface can retrieve
the latest bundle, but correctness no longer depends on polling it at 10x speed.

This instrumentation exposed and fixed several assumption-driven errors:

- A rapid-turn alarm included turns from the preceding land leg and falsely
  blamed liquid navigation (`20260807T021913Z-3752220`). Turn history is now
  scoped to the liquid context.
- Run `20260807T022428Z-3763386` was previously labeled a narrow-shallow-ridge
  failure. That causal label is withdrawn: the trace showed a depth correlation,
  not proof that depth made the route unswimmable.
- The client could move while terrain collision still forced it underneath a
  cliff (`20260807T022919Z-3775026`). Exact terrain/vmap witnesses now reject
  that heading.
- Source-less transient blockage poisoned every candidate heading
  (`20260807T023730Z-3793853`). Only a physical collision source is treated as
  a terrain contact.
- Collision residency at 10x speed looked like navigation no-progress
  (`20260807T024029Z-3801457`). Residency has its own wall-clock diagnostic and
  no longer contaminates the movement detector.
- A single dry observation stopped a healthy swim
  (`20260807T024847Z-3820342`). Dry transition detection is now debounced.
- A shadowed depth variable compared candidates against infinity
  (`20260807T031159Z-3881931`). The logging defect was real, but fixing it did
  not validate using depth as a navigation gate.
- Unknown liquid coverage self-resolved after several simulation seconds
  (`20260807T031741Z-3896930`). Its diagnostic bound now reflects observed 10x
  asset-loading behavior without treating unknown as safe.

## Current behavior

The bot can enter the water and acquire Aquatic Form, but its liquid navigation
is currently a short-horizon local heading chooser. It usually selects the
straight bearing toward the next beat. When the first cliff enters its local
horizon, the invalid depth gate rejects the available water and the policy
stops. It has no proven longer-horizon route, coastal boundary following, or
backtracking around that obstruction.

Fatigue work farther north remains unproven, but it is not the first blocker.
The first blocker is that the current policy cannot navigate around the coastal
cliff after `water_entry`.

## Next investigation

1. Remove modeled depth as a permission gate for established ocean swimming;
   keep it as telemetry.
2. Re-prove the actual transition conditions from ClientView: liquid present,
   swimming, Aquatic Form, physical collision, progress, and fatigue.
3. Replace straight local steering with navigation that can route around the
   first coastal cliff, then rerun the `water_entry` checkpoint.
4. Reach Merchant Bay once without a severe anomaly, then investigate any
   remaining route-specific failures.
5. Run five consecutive clean checkpoint successes, followed by three clean
   untouched Tanaris-start successes. Keep the checkboxes in
   `traverse-2026-08-06.md` open until those artifacts exist.

Relevant implementation and investigation contracts are documented in
[army-debug.md](army-debug.md), [embed-lua-client.md](embed-lua-client.md), and
[traverse-2026-08-06.md](traverse-2026-08-06.md).
