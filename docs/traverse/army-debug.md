# Embedded Petrel debug admin

Local, read-only-first diagnostics for ClientView traverse runs. `make traverse`
and `make traverse-headed` start it automatically on `127.0.0.1:7788`.
The port is local only and is not part of a hosted policy image.

## Durable runs

Every launch creates `local_data/traverse-runs/<UTC timestamp>-<pid>/` and
updates `local_data/traverse-runs/latest`. Runs are retained until deliberately
removed; the launcher does not prune them.

Each run contains:

- `manifest.json`: revisions, dirty state, upstream pin, input hashes, mode,
  checkpoint label, and simulation scale
- `player.log`, `admin.log`, `status.json`
- `timeline.jsonl`: ClientView observation → exact Lua projection and intent →
  upstream navigation/lowering stages → final input batch and receipt → observed
  movement execution
- `transitions.jsonl`: water, form, intent, route, and branch changes, timestamped
  in both simulation and wall time
- `control/`: admin requests and client acknowledgements
- `anomalies/<id>/`: anomaly metadata, the triggering ClientView, a 60-second
  simulation-time pre-window, a 5-second post-window, and `frame.png` when capture
  succeeds
- `run-summary.json`: exit code, final status, and anomaly count

Breath and fatigue are represented as `active`, `remaining_fraction`, and
`source`. An absent timer is explicitly recorded as assumed full, not observed.
Water and form fields carry their corresponding `*_known` evidence.

## Automatic anomaly capture

The client detects jumping while wet, Aquatic Form loss while wet, repeated form
casts, rapid alternating turns without a heading change, movement input without
position progress, sustained unavailable navigation, and an authoritative dry
observation during a liquid leg. Severe anomalies capture through five more
simulation seconds and then stop the player, preserving the failing state.

## HTTP

An optional `ARMY_DEBUG_TOKEN` is accepted as a Bearer token. Historical reads
take `run_id`; timeline reads also accept `limit` and `sim_seconds`.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/healthz`, `/status`, `/runs` | service and run state |
| `GET` | `/timeline`, `/transitions` | causal records |
| `GET` | `/anomalies`, `/anomalies/latest` | captured failures; latest includes its JSON bundle |
| `GET` | `/anomaly?anomaly_id=…`, `/frame?anomaly_id=…` | full JSON bundle/rendered frame |
| `GET` | `/command?id=…` | command acknowledgement |
| `POST` | `/hold`, `/resume` | stop/resume Petrel decisions safely |
| `POST` | `/dump`, `/stop` | manual capture, or capture then stop |
| `POST` | `/lua/reload` | transactional embedded-Lua reload |

`/ws` streams `status` and `anomaly` topics after an `auth` message when a token
is configured. Reload builds a replacement Lua VM first; a parse or boot failure
leaves the active VM untouched and is reported by `/command`.

## Investigation contract

Before changing behavior, inspect the causal trace, cite the observations that
support the hypothesis, list facts that remain unknown, and identify the layer
that emitted the bad input. Do not add recovery behavior for an assumed obstacle.
