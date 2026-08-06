# Traverse (Kalimdor league)

Home for **Kalimdor Traverse** notes, plans, and version labels. Point new
traverse writeups here instead of scattering under `docs/`.

| Doc | What it is |
|---|---|
| [petrel-plan.md](petrel-plan.md) | **Plan of record** — legs, fatigue, swim-north, weekend contender thesis |
| [clientview-migration.md](clientview-migration.md) | ClientView Lua pilot (`make traverse` / `traverse-headed`); water-entry proven |
| [checkpointing.md](checkpointing.md) | Local wet debug: why config/SQL fail; SOAP tele; Northbound2 free play |
| [pathing.md](pathing.md) | **Pathing architecture** — sparse major beats + real nav A→B (scales weekly / multi-comp) |
| [embed-lua-client.md](embed-lua-client.md) | **Plan:** embed Lua in Nim client (strategy) + RPB nav feet; kill bridge hack |
| [obstacle-avoidance.md](obstacle-avoidance.md) | Older land polish notes (hut/mountain); superseded for architecture by pathing.md |
| [traverse-2026-08-05.md](traverse-2026-08-05.md) | Day notes / V4 checklist scratchpad |
| [traverse_wow.md](traverse_wow.md) | League scouting: rules, scoring, fixture, submission gates (from upstream) |
| [traverse-2026-08-04.md](traverse-2026-08-04.md) | Older V1 plan / status (Lua PoL on `/env` — historical) |
| [versions.md](versions.md) | `ibis:vN` engineer notes (not on the dashboard) |

Related elsewhere (not traverse-only):

- `../deploy-2026-08-04.md` — multi-league deploy punch list (includes Traverse)
- `../lua_architecture.md` — entry modes including `traverse`
- Makefile: `traverse`, `traverse-headed` (ClientView Lua); legacy `traverse-pol` / `traverse-desert`
- System dashboard: http://127.0.0.1:7777/traverse
