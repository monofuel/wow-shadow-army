# Navmesh — the Detour pathfinding helper

Status: **RESOLVED 2026-07-26.** Headless bots move. This closes
`docs/milestone-1-evidence.md` unresolved blocker #1 and the `movement_blocked`
note in `docs/warlock-seat.md`.

Before: every semantic `move` / `follow` settled
`reason_code=movement_blocked`, `msg='navmesh unavailable for semantic goal:
VANILLA_WOW_NAVMESH_HELPER is not configured.'`, and `characters.position_*`
never changed.

After: `reason_code=ok`, `msg='walked Reference Player navmesh route through 3
waypoint(s)'`, and the DB position moves.

## What the helper actually is

`player/sdk/helpers/vmangos_navmesh_helper.cpp` (upstream) is a ~2000-line
stdin/stdout JSON tool that mmaps VMaNGOS `.mmap`/`.mmtile` files and answers
three ops — `status`, `route`, `local_graph` — over protocol
`vanilla_wow.navmesh_helper.v2`. The client shells out to it per query; the
path resolves from `VANILLA_WOW_NAVMESH_HELPER`, else
`<upstream>/tmp/vmangos-navmesh-helper` (`client/localpaths.nim:181-192`).

**It is a compile-only step.** The build links the helper against VMaNGOS's
*vendored* Detour library. It does **not** build the VMaNGOS server, and it
does **not** generate mmaps — those are the multi-hour job, and we already have
them. Total cost: one sparse git fetch (~74 MB) plus ~30 s of `g++`.

### The two inputs

| Input | Where | Status |
|---|---|---|
| Detour C++ sources — `dep/recastnavigation/Detour/{Include,Source}` and `dep/include/nlohmann/json.hpp` | `$(VMANGOS_CORE_DIR)` = `<upstream>/local_data/reference/vmangos-core` | fetched, see below |
| Prebuilt mmaps — 41 `.mmap` + 1742 `.mmtile`, 1.9 GB | `<upstream>/local_data/vmangos-5875-data/mmaps` (from `VANILLA_WOW_EXTRACTED_DATA_DIR`) | **already extracted, nothing to do** |

The mmaps being present is the whole reason this was cheap. Do not regenerate
them, and do not go looking in the `coworld-vmangos` container for them.

## How to get the Detour sources

`vmangos/core` is a large repo and we need one subtree of it. Use a blob-less
partial clone with sparse checkout — that is what produced the 74 MB tree at
`<upstream>/local_data/reference/vmangos-core`:

```sh
cd ../coworld-vanilla-wow/local_data/reference
git clone --filter=blob:none --sparse git@github.com:vmangos/core.git vmangos-core
cd vmangos-core
git sparse-checkout set src dep     # NOTE: no leading slashes, or git refuses
```

Pin used: `d0aff0ce` ("Add CI build for USE_PCH=OFF (#3492)"), matching the
`d0aff0cedc…` pin already named in `milestone-1-evidence.md`.

`local_data/` is gitignored upstream, so this writes nothing tracked. The build
output `<upstream>/tmp/vmangos-navmesh-helper` is likewise under upstream's
`tmp/` gitignore rule.

## Build and check

```sh
make navmesh-helper     # compile (idempotent, ~30 s; expect Detour -Wmaybe-uninitialized noise)
make navmesh-status     # readiness probe, no realm needed
```

`navmesh-status` should print:

```json
{"available":true,
 "capabilities":["local_graph_stable_poly_keys","route_stable_poly_keys"],
 "helper":"vmangos_navmesh_helper",
 "message":"helper and mmap inputs are configured.",
 "mmap_files":82,"mmtile_files":3484,
 "protocol":"vanilla_wow.navmesh_helper.v2"}
```

A raw route query, for debugging a specific spot (note the payload nests the
route under `request` — a flat body returns `missing route request`):

```sh
echo '{"op":"route","mmaps_dir":"'"$VANILLA_WOW_EXTRACTED_DATA_DIR"'/mmaps",
       "request":{"map_id":0,
                  "source":{"map_id":0,"x":1676.35,"y":1677.45,"z":121.67},
                  "target":{"map_id":0,"x":1720.0,"y":1620.0,"z":120.0}}}' \
  | "$VANILLA_WOW_NAVMESH_HELPER"
# -> {"status":"ok","path_type":"smooth", 47 waypoints,
#     "message":"route planned with VMaNGOS Detour mmaps"}
```

## Env wiring

`Makefile` exports it globally next to the other realm operator inputs, so
every seat target inherits it:

```make
export VANILLA_WOW_NAVMESH_HELPER := $(UPSTREAM)/tmp/vmangos-navmesh-helper
VMANGOS_CORE_DIR := $(UPSTREAM)/local_data/reference/vmangos-core
```

Verify a *running* seat actually picked it up (a seat launched before this
change will not have it, and must be restarted):

```sh
tr '\0' '\n' < /proc/<pid>/environ | grep NAVMESH
```

## Proof — 2026-07-26

Seat: `Botwarrior`, slot 0, socket `127.0.0.1:41114` — the same seat that
produced the original `movement_blocked` evidence, so this is a clean A/B.

```sh
make navmesh-helper
# relaunch the seat so it inherits VANILLA_WOW_NAVMESH_HELPER
# (2026-07-26 proof used the v1-era `make shadow` Python host, since deleted;
# today: make escort SLOT=0)
```

Brain output — settlements now succeed:

```
[shadow] #4  SELECT move ok=True reason=ok msg='walked Reference Player navmesh route through 3 waypoint(s)'
[shadow] #24 SELECT move ok=True reason=ok msg='advanced Reference Player graph route toward semantic goal'
```

`characters.characters`, before and after the 75 s run:

```
name        map  position_x  position_y  position_z
Botwarrior   1   -618.518    -4251.67    38.718      <- before
Botwarrior   1   -547.185    -4190.31    50.7127     <- after
```

~94 yd of ground covered, with elevation change — the bot walked up out of the
Valley of Trials starting hollow. **Position change: yes.**

## Known-good vs still-open

Two `movement_blocked` settlements still appeared mid-run, and they are the
*healthy* kind — the navmesh answered and the route was judged:

```
'piloted movement failed: client settled on 1:11:22:0:10553 before target polygon 1:11:22:0:11077'
'movement route stopped 4.00 yd from target'
```

Those are route-quality/tolerance signals, not "no navmesh". Contrast with the
old failure text (`navmesh unavailable for semantic goal`) — if you ever see
that string again, the env did not reach the seat.

Two *unrelated* blockers surfaced while proving this out; neither is navmesh:

1. **Warlock seats have no leveling profile.** `Shadowfel` resolves
   `profile_id=unsupported_profile`, so the planner emits
   `noop / "unsupported leveling profile"` and never offers a move option — the
   seat cannot be moved by a `leveling` goal regardless of navmesh. Supported
   profiles are the Durotar/starting-zone set (`Botwarrior` gets
   `durotar_troll_shaman`). Movement itself is fine; the *policy* has nothing
   to say. Shadowfel therefore still has not moved.
2. **`brain.shadow` cannot parse warlock frames.** Two pydantic errors block
   it: `leveling_context.farm_area_id` / `farm_area_label` are `""` on the wire
   but the model requires `min_length=1`, and `ActionSettled` rejects the
   unsupported-profile settlement with "action settlement success must agree
   with reason_code". Same family as unresolved #2 in
   `milestone-1-evidence.md` (`brain/frame_coerce.py`) — the coercion layer
   needs these two fields added.

For the dungeon competition, seats should use classes/races with a real
starting-zone profile until (1) is addressed.

## Gotchas worth remembering

- `git sparse-checkout set` rejects leading slashes (`/src/`) with "specify
  directories rather than patterns" — use `src dep`.
- `status_request` over the control socket requires **both**
  `include_environment_frame` and `include_action_settled` as explicit
  booleans; omitting one returns `invalid_request: ... must be a boolean`.
- A seat launched before the Makefile export exists will silently keep
  failing. Restart the seat, then confirm via `/proc/<pid>/environ`.
