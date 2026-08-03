# Terms — WoW coworld project vocabulary

Canonical glossary for the WoW coworld work. Agents and docs should use these
terms consistently; when a doc says "upstream" or "the fork", it means exactly
what's defined here. Each entry stays short — deep detail lives in the linked
doc.

## Repos and code flow

- **upstream** — the `Metta-AI/coworld-vanilla-wow` repo on GitHub. Actively
  developed by other Softmax engineers; **we must stay up to date with it for
  the competition**. It contains both **client** components (the Nim game
  client, `nim_control` goals/frames) and **server** components (VMaNGOS realm,
  compose infra, operator scripts) — always be mindful of which side a change
  touches. Our local checkout is `../coworld-vanilla-wow`; it is **read-only**
  (never commit there — see AGENTS.md hard rules).
- **the fork** — `../coworld-vanilla-wow-fork`, our fork of upstream where our
  changes live. **Client customizations are allowed; server components stay
  untouched** — always take upstream's version of server code verbatim.
  Staying current means periodically syncing upstream `main`; merge conflicts
  in client files are an expected cost of that and we resolve them — they are
  not a reason to stop syncing. Remotes: `origin` = our Gitea, `upstream` =
  GitHub (push disabled), `local-upstream` = the local upstream checkout
  (push disabled). Our work branches: `shadow-army-fixes`,
  `lua-external-policy`, etc. See `docs/coworld-fork.md`.
- **xr** — `../coworld-vanilla-wow-xr`, a third checkout used for `-d:xr`
  client-build testing. Carries its own provisioned player client.
- **mirror** — our Gitea copy of upstream (`10.11.4.11:222/Monolab/
  coworld-vanilla-wow`). Kept in sync by fetching upstream `main` and pushing
  it to Gitea; lets servers on the LAN clone without GitHub access.
- **the pin / `upstream.lock`** — the upstream commit wow-shadow-army is
  currently built and tested against (repo root `upstream.lock`). We consume
  upstream at the pin through the `nim_control` boundary; moving the pin is a
  deliberate, tested step, not a side effect.
- **wow-classic-data** — the canonical store for the 1.12 game client +
  extracted server data (`Coworld-WoW-Classic/`, `vmangos-5875-data`). The
  4-hour tailscale download; one copy, everything else symlinks to it. See
  `docs/file-space-audit.md`.

## Runtime and realm

- **realm** — our local VMaNGOS 1.12 private server, run for testing via
  upstream's compose (`infra/compose.vmangos.yml`, project `coworld-vmangos`).
- **operator** — upstream's `server/scripts/docker_vmangos_server.py`, the
  script that brings the realm `up`/`down`. The System and `make
  start-server` both call it; `SYSTEM_UPSTREAM_DIR` tells The System where the
  upstream checkout lives.
- **local_data** — `wow-shadow-army/local_data/`, gitignored runtime state:
  bot logs, brain logs, nim runtime dirs. (Upstream repos have their own
  `local_data/` for realm outputs and captures.) Persistent state belongs in
  folders like this — never in docker named volumes.
- **local_classic** — `wow-shadow-army/local_classic/`, a thin playable client
  instance: a small shell of real files with all `Data/*.MPQ` symlinked into
  wow-classic-data. The pattern every client instance should follow.

## The System and seats

- **The System** — our management server (`system/system_server.nim`), one Nim
  binary on `127.0.0.1:7777`: htmx dashboard + MCP endpoint + admin/lifecycle
  ops. Named for the solo-leveling system. See `system/README.md`.
- **seat** — one connected game client, human or bot. Bot seats are
  **Shadowfel, Igris, Tusk, Beru**; **Murist** is the human seat (monofuel).
  Bot seats expose a `nim_control` socket on port `41114 + slot`.
- **foundation seats** — background/utility characters (`Bot*`, Nightsun,
  Cowcam) that we ignore and filter out of dashboards by default.
- **advisor** — the ShadowArmy vanilla-client addon (`addons/ShadowArmy/`) on
  the human seat: reduces monofuel's cognitive load in play. UI or fully
  automated; slash commands are a dev escape hatch, not the product. See
  `docs/advisor.md`.
- **fair play** — seats play as strangers: cooperation only through the
  game's own typed contracts and live observations, no out-of-band collusion,
  no GM/DB shortcuts for progress. Anything a stranger client on the live
  realm couldn't do is cheating. See AGENTS.md hard rules and
  `kb/fair-play-audit.md`.
