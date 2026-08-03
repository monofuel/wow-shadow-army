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
- **operator** — upstream's `docker_vmangos_server.py` (path discovered under
  the checkout; currently `infra/mangos/vmangos/ops/…`), the script that
  brings the realm `up`/`down`. The System and `make start-server` both go
  through `tools/realm_op.sh` (auto `--build` when the image needs it);
  `SYSTEM_UPSTREAM_DIR` tells them where the
  upstream checkout lives.
- **local_data** — `wow-shadow-army/local_data/`, gitignored runtime state:
  bot logs, brain logs, nim runtime dirs. (Upstream repos have their own
  `local_data/` for realm outputs and captures.) Persistent state belongs in
  folders like this — never in docker named volumes.
- **local_classic** — `wow-shadow-army/local_classic/`, a thin playable client
  instance: a small shell of real files with all `Data/*.MPQ` symlinked into
  wow-classic-data. The pattern every client instance should follow.

## Clients

There are **two unrelated game clients**. Saying just "the client" is the most
common source of confusion in this project — always qualify it. Detail and
wiring: `docs/interfaces.md`.

- **the nim client** — upstream's Nim game client (`environment/` + `player/`
  in the upstream tree). **When a doc says "client" in a bot context, this is
  what it means.** It is also playable by a human, so "someone on the nim
  client" is a legitimate phrase — the term describes the *software*, not
  whether a bot or a person is driving it. Bot seats run it headless. We put
  **no code inside it**; we drive it from outside as an external policy over
  `WS /env`.
- **the vanilla client** — the real Blizzard 1.12 `WoW.exe` under wine,
  launched by **`make play-classic`**. **This is what monofuel plays and tests
  with.** It has an addon system (Lua 5.0, `Interface/AddOns/`), which the nim
  client does not. Its thin instance layout is `local_classic` (see above).
- **`play-classic`** — the Makefile target, and by extension the shorthand for
  "the vanilla client session monofuel is playing in." `make play` is the nim
  client instead; `make play-xr` is the xr checkout.
- **the advisor** — our Lua addon **for the vanilla client**; defined under
  "The System and seats" below.

## The System and seats

- **The System** — our management server (`system/system_server.nim`), one Nim
  binary on `127.0.0.1:7777`: htmx dashboard + MCP endpoint + admin/lifecycle
  ops. Named for the solo-leveling system. See `system/README.md`.
- **seat** — one connected game client, human or bot. Bot seats are
  **Shadowfel, Igris, Tusk, Beru** (slots 2–5), each running the **nim
  client**; **Murist** is the human seat (monofuel) on the **vanilla client**.
  One `army_host` process drives one bot seat — four in total, sharing no
  state. Bot seats historically exposed a `nim_control` socket on
  `41114 + slot`; as of pin `93730fb97` that protocol is gone and the port
  survives only as a liveness probe (`docs/interfaces.md`).
- **foundation seats** — background/utility characters (`Bot*`, Nightsun,
  Cowcam) that we ignore and filter out of dashboards by default.
- **advisor** — the ShadowArmy addon (`addons/ShadowArmy/`) for the **vanilla
  client** (see "Clients"), on the human seat: reduces monofuel's cognitive
  load in play. UI or fully automated; slash commands are a dev escape hatch,
  not the product. It is **not part of the bot stack** — it never sees an
  `AgentFrame` and never talks to `army_host`, and the nim client has no addon
  system to host it. Our two bodies of Lua — `lua/tools/` (bot policy) and
  `addons/ShadowArmy/` (advisor) — never meet. See `docs/advisor.md`.
- **fair play** — seats play as strangers: cooperation only through the
  game's own typed contracts and live observations, no out-of-band collusion,
  no GM/DB shortcuts for progress. Anything a stranger client on the live
  realm couldn't do is cheating. See AGENTS.md hard rules and
  `docs/fair-play-audit.md`.
