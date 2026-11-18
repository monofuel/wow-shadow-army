# Testing — wow-shadow-army

Doctrine baseline: racha_notes `Programming/testing.md` (three tiers,
unit must be stupid fast, CI green checkmark on every push, mechanism-
shaped assertions). This file maps that doctrine onto **this** repo.

## Tiers (this repo)

| Tier | Make target | Required? | What it is here |
|---|---|---|---|
| **Unit** | `make test` | **YES — every push** | Lua tool library under `lua/tests/test_*.lua` + Nim tiers (`system/tests/`, `tools/tests/`; soft-skip when nim is missing) + the smoke tier below. Instant: no network, no docker, no sleeps, no realm. No Python. |
| **Smoke** | `make test-smoke` (inside `make test`) | **YES — every push** | Parse/compile gate for code no unit test executes: `luac -p` every non-test Lua file (the addon's only automated gate) + `nim check` every Nim entrypoint (`NIM_CHECK_FILES`; army_host has no unit suite yet). Nim leg soft-skips like test-nim-soft. |
| **Pin** | `make pin-check` | on upstream bumps | Pure shell: `git rev-parse HEAD` of `../coworld-vanilla-wow` equals the SHA in `upstream.lock`. |
| **Live smoke** | `make escort-army` / `make grind` | before milestone claims | Real realm + seats on the Nim host. Evidence lands in `local_data/audit/fair-play.jsonl` + realm logs (LevelUp/Loot). |

The old Python integration/e2e tiers (recorded-frame replay through
`brain/`, `tests/e2e/mechanism_e2e.py`) died with the v1 select protocol —
brain/ was deleted 2026-07-27 (`docs/v2.md`). Frame fixtures remain under
`tests/fixtures/frames/` for forensics.

Rules that stay fixed:

- `make test` is the unit glob only. Integration/e2e never sneak into it.
- Unit suite stays green and instant before every commit (`AGENTS.md`).
- Assert mechanisms (decide kinds, hold reasons, "leader not visible → hold"),
  not magic radii or tuning constants. Pin literals only when the value
  *is* the contract (wire labels, protocol names).

## Unit CI (wired)

`.gitea/workflows/test.yml` on `monolab-builder`, one job per language leg
(doctrine: wall clock = slowest leg, and a dep problem in one language
cannot hide a unit failure in another):

- **`lua-tests`**: checkout → `apt-get install -y lua5.3` (crewrift-prime-bots
  pattern; also provides `luac5.3` for the parse smoke) →
  `make test-lua test-smoke-lua`. Explicitly lua-only targets: the builder
  image carries a dep-less nim, so plain `make test` would run the nim tier
  without its packages and fail for the wrong reason (this exact failure
  shipped red from the v0.10.0 push until 2026-08-03).
- **`nim-tests`**: checkout → sibling sources at the job's `FORK_PIN` /
  `SCRIPTORIUM_PIN` (`../monofuel-vanilla-wow` from the private mirror with
  the read-only `CI_DEPLOY_KEY`, `../scriptorium` from public GitHub; the
  `nim.cfg` paths the map-browser and conductor tests import) →
  `treeform/setup-nim-action@v6` (nim 2.2.4, ships nimby; Racha build.yml
  pattern) → `NIMBY_HOME=$HOME/.nimby/profiles/wow-coworld` → cache
  `~/.nimble` + `~/.nimby` keyed on `hashFiles('nimby.lock')` and the fork
  pin → `nimby create` in `$NIMBY_HOME`, then `nimby sync -g` of the fork's
  lock and then this repo's lock → `make test-nim test-smoke-nim`. Both
  syncs install into `$NIMBY_HOME/pkgs` and append to `$NIMBY_HOME/nim.cfg`,
  which `config.nims` reads, so the profile holds the union of the two locks
  exactly as local dev does. Lock-based `-g` sync from that external profile
  is the ONLY nimby invocation allowed near this repo — plain workspace-mode
  `nimby sync` mutates Softmax sibling checkouts.

Current tools have zero Lua module deps (no cjson/socket yet); add packages
to the lua install step only when a unit test actually needs them. Unit jobs
stay independent of integration so a mirror/token problem cannot hide a unit
failure behind a single job.

## Pin tier (CI job `pin-check` in `test.yml`)

Runs on every push / workflow_dispatch **in parallel with** `lua-tests`
(unit stays first in the file and does not depend on it):

1. checkout this repo
2. ssh-clone private mirror `Monolab/coworld-vanilla-wow` into
   `$(dirname $GITHUB_WORKSPACE)/coworld-vanilla-wow` (sibling so
   `../coworld-vanilla-wow` resolves), then `git checkout` the SHA from
   `upstream.lock`
3. `make pin-check` (pure shell — no lua, no uv, no Python)

**Cross-repo auth:** `GITHUB_TOKEN` is repo-scoped and cannot read other
private Monolab repos. Jobs use the **`CI_DEPLOY_KEY` Monolab org secret**
(created 2026-07-24): a read-only ssh deploy key installed on
`Monolab/coworld-vanilla-wow` and `Monolab/wow-classic-data`. Clones go
over `ssh://git@10.11.4.11:222/...` with `GIT_SSH_COMMAND` pointing at the
key. Registry login tries the built-in actions token first, `GIT_PAT`
fallback.

## Pin tier (local)

```sh
# From wow-shadow-army root. Needs sibling ../coworld-vanilla-wow at the
# commit in upstream.lock.
make pin-check
```

After an intentional upstream pin bump: update `upstream.lock`, re-run
`make pin-check`, and re-run a live smoke before the next milestone claim.

Historical note (2026-07-27): the Python integration tier (recorded
`wire_*.bin` replay through `brain/` frame_coerce → projection → Lua →
intent_mapping) and the nightly mechanism e2e were deleted along with
`brain/` — they asserted the v1 external-select mechanism, which
`nim_control.v2` removed (`docs/nim-control-v2-external-select.md`). Fixtures stay
under `tests/fixtures/frames/` for forensics.

## Copyright / data boundary

`Monolab/wow-classic-data` is a **private** mirror of Blizzard-derived
client + VMaNGOS server data (see that repo's README). Rules for every
tier and every artifact we ever publish:

- **Private infra only.** Never push the tree, a tarball of it, or a
  public GitHub/Gitea release containing it.
- **Never into public artifacts.** No public CI logs that dump DBC
  contents, no public workflow artifacts, no public container registry
  tags.
- **Never into image layers.** Realm images we push to the Gitea package
  registry must contain only server binaries/config entrypoints. Mount
  maps/vmaps/mmaps/DBCs and mysql dumps at **run time** from a runner-
  local data cache. A `COPY` of wow-classic-data into a Dockerfile is a
  hard fail.
- Images that *are* private (Gitea package registry under Monolab,
  auth-gated) still must not bake the data in — the layer history is a
  durable leak surface and bloats every pull.

## e2e plan (wired — `.gitea/workflows/e2e.yml`)

Cost-gated per doctrine: full realm + bot is heavy. Run **nightly +
manual**, never on every push. Workflow file: `.gitea/workflows/e2e.yml`.
Harness: `tests/e2e/mechanism_e2e.py`.

### (a) Runner docker availability — finding

**Yes: monolab-builder job containers have Docker via the host socket.**

Evidence (read-only, from monolab infra + sibling CI; did not probe the
runner by pushing commits):

| Source | What it shows |
|---|---|
| `Monolab/monolab` role `docker-gitea-runner` `templates/docker-compose.yml.j2` | act_runner mounts `/var/run/docker.sock` into the runner container |
| same role `templates/config.yaml.j2` | `DOCKER_HOST: unix:///var/run/docker.sock`; label `monolab-builder:docker://gitea.solution-nine.monofuel.dev/monofuel/monolab/monolab-builder:latest` |
| `Monolab/monolab/docs/gentoo-images.md` | Explicit: "The act runner bind-mounts `/var/run/docker.sock` into job containers" |
| `Racha/.gitea/workflows/build.yml` | `runs-on: monolab-builder` then `docker/setup-buildx-action`, `docker run`, `docker push` — live proof the label can drive the host daemon |

Caveats for e2e design:

- Job containers are **not** DinD; they drive the **host** docker daemon.
  `docker compose up` creates sibling containers on the host network
  namespace of the runner host (same pattern as local `make start-server`).
- `container.privileged` defaults **false**; host-sock is enough for
  compose, not a blank check for nested privileged DinD.
- Job bind-mounts from host are restricted by `valid_volumes` (today:
  certs + `/opt/gitea-runner/grok` only). Do **not** assume an arbitrary
  host path is mountable into the *job* container. Prefer Docker named
  volumes / compose mounts (those go through the host daemon and do not
  need `valid_volumes`).
- Docker CLI may need to be present in the job image or installed in a
  step; buildx-using workflows already exercise this path successfully.

### (b) Realm images → Gitea container registry

**Registry host:** `gitea.solution-nine.monofuel.dev`  
**Auth:** package write via `secrets.GIT_PAT` (same as Racha/monky/monolab
image workflows: `docker/login-action` with `username: monolab`).  
**CA:** runner already injects monolab CA certs; buildx configs often pin:

```toml
[registry."gitea.solution-nine.monofuel.dev"]
  ca = ["/usr/local/share/ca-certificates/monolab-ca.crt",
        "/usr/local/share/ca-certificates/monolab-int-ca.crt"]
```

**Tag convention** (match monolab package path style used by racha/monky):

```
gitea.solution-nine.monofuel.dev/monolab/wow-shadow-army/<image>:<tag>
```

Proposed images (built from upstream pin in `upstream.lock`, **without**
baking data):

| Image | Role |
|---|---|
| `.../coworld-vmangos:<pin-sha>` | Realm (realmd/mangosd) — binary/config only |
| `.../coworld-vmangos:latest` | Moving tip of the pin we currently test |
| optional later: `.../reference-player:<pin-sha>` | Headless client for bot seat |

Build job (future, separate workflow or e2e prep workflow): checkout this
repo + sibling upstream at pin, build realm image, push tags above. Data
dirs stay out of the build context (`.dockerignore` + no `COPY` of
`local_data` / wow-classic-data).

### (c) Data — gitea actions cache keyed on an immutable snapshot

`Monolab/wow-classic-data` is a snapshot of the 2006 client: it is
effectively **immutable**, which makes caching trivial — a static cache
key never needs invalidation. Use the standard gitea `actions/cache`
(same mechanism as crewrift's nimby cache), NOT runner-local docker
volumes: the cache server is central, so it behaves identically across
all runners with zero per-host state.

```yaml
- uses: actions/cache@v4
  with:
    path: local_data/wow-classic-data
    key: wow-classic-data-v1   # bump ONLY if the snapshot ever changes
- name: Fetch data on cache miss
  run: |
    [ -d local_data/wow-classic-data/.git ] || \
      git clone --depth 1 \
        "https://oauth2:${TOKEN}@gitea.solution-nine.monofuel.dev/Monolab/wow-classic-data.git" \
        local_data/wow-classic-data
# TOKEN = secrets.MIRROR_TOKEN or secrets.GIT_PAT
# Operator paths:
#   VANILLA_WOW_EXTRACTED_DATA_DIR = <data>/Coworld-WoW-Classic/vmangos-5875-data
#   VMANGOS_MYSQL_DUMPS_DIR        = <data>/vmangos-db/mysql-dump
```

**Why HTTPS+token instead of the ssh://10.11.4.11:222 form:** job containers
do not carry monofuel deploy keys; house `GIT_PAT` / `MIRROR_TOKEN` already
authenticate to gitea HTTPS. Same private data, no per-host SSH state.

Notes:

- Worst case (cold cache AND miss on clone) it's one ~8GB LAN transfer
  from our own gitea on a *nightly* job — fine. If the gitea cache
  server rejects entries this large, drop the cache step entirely and
  just clone every run; measure before optimizing further.
- Never `docker commit` a container that had this data mounted, never
  COPY it into pushed image layers, never tar/cat it out as artifacts.

### (d) Triggers

```yaml
on:
  schedule:
    - cron: "0 7 * * *"   # nightly 07:00 UTC — adjust once wall-clock preference is known
  workflow_dispatch:        # manual: "run e2e now"
# deliberately NOT on: push
```

Unit workflow stays on `push` + `workflow_dispatch`. E2e is a **separate**
workflow file when implemented (e.g. `.gitea/workflows/e2e.yml`) so a
red nightly cannot block the unit checkmark.

### (e) Mechanism-shaped e2e assertions (implemented)

`tests/e2e/mechanism_e2e.py` (not position / XP):

1. **Realm up:** operator `up --smoke` + curl healthz 200 on CI ports.
2. **Control socket:** TCP accept on `WOW_SDK_NIM_CONTROL_PORT` (CI default
   `14114`).
3. **StatusRequest** answers.
4. **GoalRequest(leveling, selection_mode=external)** accepted (revision
   bump observed).
5. **≥5 EnvironmentFrames** received.
6. **≥1 ActionSelectionRequest** settlement (any `success` value —
   `movement_blocked` without navmesh is OK; **do not** assert position
   change). See `docs/milestone-1-evidence.md`.

Headless seat path (chosen after inspecting the registry image):
`coworld-reference-player-runtime:<pin>` is a **scratch artifact** with only
`/vanilla-wow-reference-player`. CI does `docker create` + `docker cp` into
`bin/`, then runs the binary in the job with `AUTONOMOUS=0` (cheaper and more
reliable than rebuilding via nimby; never plain `nimby sync` workspace mode).

CI ports (env overrides on operator): `13724` / `18085` / `18080` / `13307`
so a runner never collides with a human local realm. Compose project
`wow-e2e-$RUN_ID`. Registry login: `docker/login-action` + `secrets.GIT_PAT`
(house style). Teardown: operator `down` + docker logout (`if: always()`).

**Host networking gotchas (job is bridge, dockerd is host sock):**

- Compose bind-mount sources must be **host** paths. Workflow resolves
  `GITHUB_WORKSPACE` → host path via `docker inspect` on the job container;
  falls back to named-volume + `docker cp` materialization.
- Operator smoke / healthz / realmd use the job's default-route gateway IP
  (usually the docker bridge gateway), not bare `127.0.0.1`.
- After bootstrap, `realmlist` is patched to
  `address=<host_gateway>, port=<VMANGOS_WORLD_HOST_PORT>` so the headless
  client (also in the job) can reach the remapped world port.

Timeouts and readiness polls live only in e2e; unit tier remains sleep-free.

### (f) Remaining / follow-ups

1. **First green nightly** on a real runner (secrets + 8GB data cache +
   host-gateway reachability for published ports from the job bridge network).
2. Optional `data.lock` SHA for wow-classic-data if the snapshot ever moves.
3. Expand e2e to party/follow once navmesh + mutual visibility are available;
   keep mechanism shape, not "reach level 2".
4. Local still works: `make start-server` + manual seat per
   `docs/control-plane.md` / coworld-playbook `games/vanilla-wow.md`.
