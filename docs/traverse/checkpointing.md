# Traverse — local testing checkpoints (brainstorm)

**Problem:** ClientView traverse always logs in at Tanaris spawn. Wet-leg
iteration pays a long land run every time. There is **no** sim save-state or
“resume mid-coast” API.

**Scope:** local setup only. Fair-play prove still starts from real spawn when
it counts. Death mid-run → **reset + re-run** ([petrel-plan.md](petrel-plan.md));
no SOAP/GM revive loop.

---

## What exists today

| Thing | Helps wet testing? |
|---|---|
| `TRAVERSE_GOAL_*` / `TRAVERSE_WATER_*` | Changes targets only, not character pose |
| `local_data/traverse-cv-status.json` | Watch only |
| `pack_traverse_replay` / `make traverse-replay` | Replay watch, not re-drive from mid-run |
| Lua unit frames | Policy-only; not a live world start |

---

## Ideas (live world)

### 1. Manually set position (simplest)

Characters table (`characters.characters`): `position_x/y/z`, `map`,
`orientation`, etc.

- Logout (or offline).
- `UPDATE` Northbound to water entry or a mid-coast wet pose.
- Login + start pilot → already swimming.

Do **not** fight a live session with SQL writes.

### 2. Position templates (named checkpoints)

Save a few offline poses as SQL snippets or small scripts:

| Name | Approx pose | Use |
|---|---|---|
| `water_entry` | `-6784.5, -4833.9, 0.7` | Form gap + first swim |
| `fatigue_band` | e.g. `x≈-6200` wet | Coast hug / fatigue |
| `merchant_near` | near `-1533.7, -4056.5` | Arrival / hold only |

Restore template → run → on death, restore again (no ghost work).

### 3. Backup / restore character row

- `mysqldump` or dump one character (+ related tables if needed).
- Restore “parked at water” snapshot before wet loops.
- Full clone (second name) is messier (guid / inventory FKs); optional later.

### 4. Second seat (wet-only)

Separate character always parked at water. Full-run seat stays Tanaris spawn.
Same Lua pilot; different login body.

### 5. Setup tele (explicit only)

GM/SOAP place once **before** pilot start. Same as (1) with different tools.
Not mid-run recovery. Only when monofuel orders tele.

### 6. Out of scope (don’t build for this)

- Emulator-style full-sim snapshot
- Mid-run revive as the default path
- Changing hosted tournament spawn

---

## Preference order (draft)

1. Offline **position template** restore (water entry first).  
2. Optional **second wet-only character**.  
3. Full character dump only if templates get painful.

---

## Success bar for “easier testing”

- Start a wet-only local run in **minutes**, not a full land approach.  
- After death: restore template + relaunch (aligned with reset policy).  
- Full spawn→merchant prove remains available unchanged.
