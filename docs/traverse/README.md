# Traverse (Kalimdor league)

Home for **Kalimdor Traverse** notes, plans, and version labels. Point new
traverse writeups here instead of scattering under `docs/`.

| Doc | What it is |
|---|---|
| [clientview-migration.md](clientview-migration.md) | ClientView Lua pilot (`make traverse` / `traverse-headed`); water-entry proven |
| [obstacle-avoidance.md](obstacle-avoidance.md) | **Next polish:** hut/mountain pathing vs straight-line hop move |
| [traverse-2026-08-05.md](traverse-2026-08-05.md) | V4 route/product notes (forms, water entry, swim strategy) |
| [traverse_wow.md](traverse_wow.md) | League scouting: rules, scoring, fixture, submission gates (from upstream) |
| [traverse-2026-08-04.md](traverse-2026-08-04.md) | Older V1 plan / status (Lua PoL on `/env` — historical) |
| [versions.md](versions.md) | `ibis:vN` engineer notes (not on the dashboard) |

Related elsewhere (not traverse-only):

- `../deploy-2026-08-04.md` — multi-league deploy punch list (includes Traverse)
- `../lua_architecture.md` — entry modes including `traverse`
- Makefile: `traverse`, `traverse-headed` (ClientView Lua); legacy `traverse-pol` / `traverse-desert`
- System dashboard: http://127.0.0.1:7777/traverse
