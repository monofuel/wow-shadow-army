# Traverse — local testing checkpoints (brainstorm)

**Problem:** Wet-leg iteration pays a full Tanaris land run (and/or 45m league
episode) every time. There is **no** emulator save-state. We need a way to
debug coast swim without replaying the entire scenario.

**Scope:** local debug only. Fair-play / weekend prove still means full
`make traverse` from stock fixture spawn when it counts. Death mid-run →
**reset + re-run** ([petrel-plan.md](petrel-plan.md)); no SOAP/GM **revive**
loop. Setup tele for debug placement is a separate question (see below).

---

## How the traverse scenario actually works

`make traverse` / `make traverse-headed` run
`launch_nim_player --league=traverse`. That path:

1. Builds a local league profile from the manifest variant
   **`kalimdor-south-to-north`** (see upstream `game/local_league.py` +
   `infra/coworld_manifest_template.json`).
2. **Rewrites** runtime
   `~/.coworld/.../leagues/traverse/config/config.json` from that profile
   every prepare.
3. Seeds the character (Northbound): level, gear, spells, and
   **`character.start`** = Tanaris desert
   `(-9187, -2530, 14)` — also locked in `game/traversal.py` as
   `_TRAVERSAL_START`.
4. Client logs in; episode clock runs (fixture max ticks / wall time).

So the **scenario owns spawn**. Anything that only edits pose *before*
prepare, or assumes the DB row is sticky across prepares, loses.

---

## Why earlier ideas failed or are weak

### Offline SQL / “park Northbound” before `make traverse`

**Does not work** for the league path. Prepare re-seeds from fixture start and
overwrites `characters.position_*`. Writing SQL while logged out is fine for
*non-reseeding* play; it is stomped on the next traverse prepare.

### Patch runtime `config.json` then launch (`CHECKPOINT=water_entry` attempt)

**Does not work as implemented.** Prepare calls `local_league_profile()` and
**rewrites** `config.json` from the manifest *after* any pre-launch patch.
Seed then uses stock Tanaris `start`. Observed live: status still at
`~(-9182, -2539)` after a “water_entry” apply.

A **post-prepare** hook (patch the *generated* config / profile immediately
before seed, once) could work, but that is a real launch-pipeline change, not
a one-shot file edit. A background “race re-apply” loop is fragile and was
rejected.

### New full local leagues / scenarios for each checkpoint

**Works in principle** (clone `kalimdor-south-to-north`, change `start` only),
but **not free**:

- Easy: new variant JSON in the manifest.
- Medium: new `LeagueKey` in `league_catalog.py`, allowlists in
  `launch_nim_player` / prepare CLI, ports/compose project names, our
  Makefile wiring.
- Touches **upstream** coworld, not only this repo.
- Overkill for “start wet for 20 minutes of debug.”

### `TRAVERSE_GOAL_*` only

Changes the **policy goal**, not where the body is. Still runs the desert.

### Replay pack / unit tests

Replays **watch**; they do not re-drive the pilot. Lua unit frames test
**decide**, not live ClientView swim.

### SOAP/GM **revive** mid-run

Explicitly **not** the recovery plan ([petrel-plan.md](petrel-plan.md) death
policy). Different from setup tele below.

---

## Option A — SOAP tele *after* the scenario starts

**Suggestion (Claude Fable 5):** keep using `--league=traverse` (seed, bridge,
status JSON as today), but once the character is online, use the MaNGOS **SOAP**
admin HTTP port (often `7878`) to **teleport** to a wet checkpoint.

### SOAP enabled + CHECKPOINT tele (done)

Local traverse backends enable SOAP via durable mangosd overrides, then
**`CHECKPOINT=`** teles after login (this is the working path).

| Piece | Role |
|---|---|
| `tools/traverse_soap_overrides.json` | `SOAP.Enabled=1`, bind `0.0.0.0:7878` |
| `tools/traverse_soap.py` | Env JSON + patch league `config.json` |
| `tools/traverse_checkpoints.json` | Named poses (`water_entry`, …) |
| `tools/traverse_checkpoint.py` | Wait for SOAP + in-world status; `tele name Northbound <loc>` |
| `tools/traverse_cv.sh` | Exports SOAP env; if `CHECKPOINT` set, runs apply watcher |

**Operator usage (local debug only):**

```bash
make traverse CHECKPOINT=water_entry          # headless
make traverse-headed CHECKPOINT=water_entry  # headed (same tele path)
make traverse-checkpoints                    # list names
# omit CHECKPOINT → stock Tanaris seed, no tele
```

Env: `TRAVERSE_CHECKPOINT=water_entry` (Make sets this from `CHECKPOINT=`).

Flow:

1. Scenario still seeds Tanaris (fixture start unchanged).
2. Client logs in; bridge writes `local_data/traverse-cv-status.json`.
3. Watcher waits for SOAP + fresh in-world status, ensures `game_tele` row +
   reload, raises COWCAM gmlevel, then SOAP:
   `tele name Northbound petrel_water_entry`
4. Retries until planar dist to checkpoint is small (~tens of yards).
5. Pilot continues from water (Aquatic / coast).

Host SOAP URL: **container IP:7878** (not published on host ports). Auth:
`COWCAM:COWCAM` (gmlevel raised for local tele).

**Not** fair-play / not death recovery — reset + relaunch if you die; pass
`CHECKPOINT` again for wet re-runs.

---

## Option B — No traverse scenario: Northbound2 on a normal play session

**Idea:** the checkpoint **is a character**, not a fixture start.

1. Create **Northbound2** (copy of Northbound gear/spells if useful, or a
   simple 60 druid) on a realm that **does not re-seed** every launch.
2. Place Northbound2 **once** at water (SOAP tele / GM / offline SQL on that
   non-reseeding realm — setup only).
3. Launch the **Coworld player** with `TRAVERSE_LUA_BRIDGE` still set, but
   **without** `--league=traverse` (e.g. attach to persistent / existing
   realm / practice session — exact flags TBD against
   `launch_nim_player` bare/persistent paths).
4. Log in as **Northbound2**. Pose sticks; no 45m fixture unless you want it.
5. Die → stop client → re-place if needed → login again. No desert tax.

| Pros | Cons |
|---|---|
| Avoids scenario seed entirely | Not `make traverse` as-is; needs a second launch path |
| Character row *is* the checkpoint | Placement still setup tele/SQL once (or after death) |
| No config rewrite race | Bridge is on the **player**, not wine `play-classic` |
| Clear split: Northbound = prove, Northbound2 = wet lab | Character select / account plumbing must be explicit |

Rough shape later: `make traverse-wet` / `make traverse-free` that does **not**
pass `--league=traverse`, logs into Northbound2 on a long-lived backend.

Hosted / fair prove remains stock Northbound + traverse league.

---

## What still helps without moving the body

| Tool | Role |
|---|---|
| Status JSON | Live watch of pose / form / reason |
| `TRAVERSE_GOAL_*` | Goal only |
| Replays | Postmortem watch |
| Day notes / petrel-plan | Policy truth |

---

## Preference (local wet debug, draft)

1. **Northbound2 + non-traverse session** if we invest in one stable launch path
   (best mental model: character = checkpoint).
2. **SOAP tele after traverse login** if we want zero new launch path and accept
   tele + SOAP enablement for local only.
3. **New local league variants** only if we want seed-native multi-starts and
   are willing to touch upstream catalog/CLI.
4. Do **not** rely on pre-launch config patch or offline SQL under
   `--league=traverse`.

---

## Success bar

- Wet debug starts in **minutes**, not a full land approach.  
- Full spawn→merchant prove still available unchanged.  
- Death: reset + re-run (re-tele or re-login Northbound2); no revive rabbit-hole.
