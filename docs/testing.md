# Testing — wow-shadow-army

Doctrine baseline: racha_notes `Programming/testing.md` (three tiers,
unit must be stupid fast, CI green checkmark on every push, mechanism-
shaped assertions). This file maps that doctrine onto **this** repo.

## Tiers (this repo)

| Tier | Make target | Required? | What it is here |
|---|---|---|---|
| **Unit** | `make test` | **YES — every push** | Lua tool library under `lua/tests/test_*.lua` + stdlib Python under `brain/tests/`. Instant: no network, no docker, no sleeps, no realm. |
| **Integration** | `make integration-test` | optional; **local only** (not CI) | Recorded-frame fixtures (`tests/fixtures/frames/wire_*.bin`) decoded through the **real** upstream `EnvironmentFrame` client, projected, run through real Lua tools, intent-mapped. Also pin-drift vs `upstream.lock`. No live services, no realm, no docker. |
| **e2e** | `make e2e-test` (planned) | optional; **not wired yet** | Full stack: VMaNGOS realm + headless reference player + brain/Lua seat. Nightly cron + manual dispatch only (see e2e plan). |

Rules that stay fixed:

- `make test` is the unit glob only. Integration/e2e never sneak into it.
- Unit suite stays green and instant before every commit (`AGENTS.md`).
- Assert mechanisms (decide kinds, hold reasons, "leader not visible → hold"),
  not magic radii or tuning constants. Pin literals only when the value
  *is* the contract (wire labels, protocol names).

## Unit CI (wired)

`.gitea/workflows/test.yml` on `monolab-builder`:

1. checkout
2. `apt-get install -y lua5.3` (same apt pattern as crewrift-prime-bots;
   Makefile prefers `lua5.3` then `lua`)
3. `make test`

No docker, no nix, no nim. Current tools have zero Lua module deps
(no cjson/socket yet); add packages to the install step only when a unit
test actually needs them.

**Integration is deliberately not in CI** (see § Integration CI prerequisites
below). Push checkmark stays unit-only.

## Integration tier (IMPLEMENTED — local)

### How to run

```sh
# From wow-shadow-army root. Needs sibling ../coworld-vanilla-wow at the
# commit in upstream.lock, uv, and lua5.3 (or lua / nix shell).
make integration-test
# pin only:
make pin-check
```

`integration-test` invokes `pin-check` then:

```sh
uv run --project ../coworld-vanilla-wow python -m unittest discover \
  -s tests/integration -p 'test_*.py' -v
```

Same interpreter env as live brain (`brain/README.md`): upstream's uv project
supplies pydantic + msgpack. Target runtime is a few seconds.

### What it covers

| Check | Where | Mechanism assertion |
|---|---|---|
| Pin drift | `tests/integration/test_pin_drift.py` | `git rev-parse HEAD` of `../coworld-vanilla-wow` equals the SHA in `upstream.lock`; required files (`player/sdk/nim_control.py`, …) still exist. Mismatch message: *upstream checkout does not match upstream.lock — bump the pin deliberately and re-run integration*. |
| Wire parse | `tests/integration/test_wire_replay.py` | Each `tests/fixtures/frames/wire_*.bin` (raw kind-6 MessagePack, no 16-byte header) → `msgpack.unpackb` → `frame_coerce` → `EnvironmentFrame.model_validate` succeeds. |
| Projection | same | `project_for_follow_leader` yields `self_unit` with finite `x`/`y`; party not formed ⇒ `leader_unit is None`. |
| Lua tools | same | Real `lua5.3` via `brain/lua_runner` + `lua/tools/follow_leader.lua`: party absent ⇒ `{kind="hold", reason="leader_not_visible"}`. |
| Intent map | same | `map_intent(hold)` ⇒ `skip=True`, no `FactorizedAction` kwargs (brain must not call `select()`). |

Fixtures and capture notes: `tests/fixtures/frames/README.md`. Summaries
(`frame_*.summary.json`) document the live session shape (solo seat,
`in_group=false`); tests assert those **mechanisms**, not magic radii or
hard-coded map coords.

### Capture new fixtures

With realm + headless seat up (see `docs/control-plane.md` / milestone-1
runbook):

```sh
uv run --project ../coworld-vanilla-wow python -m brain.shadow \
  --slot 0 --leader-name Botpriest --party-members Botpriest,Botwarrior \
  --move-fallback --max-seconds 65 --capture-frames 5
```

`brain.shadow --capture-frames N` writes `frame_*.bin` / summaries under
`tests/fixtures/frames/`. Raw wire payloads (`wire_*.bin`) are the preferred
integration input (kind-6 MessagePack only); see fixtures README for the
re-decode sketch and how wire probes were taken during milestone 1.

After an intentional upstream pin bump: update `upstream.lock`, re-capture
if the frame schema changed, then `make integration-test`.

### Integration CI prerequisites (not wired)

The Gitea runner clones **only this repo**. Integration needs:

1. **Private upstream on the runner.** Mirror `coworld-vanilla-wow` to Gitea
   the same way `Monolab/wow-classic-data` is mirrored (private org repo +
   token-readable clone). Public GitHub Metta-AI checkout is not available
   to the job without secrets and still must land at the **pin**, not tip.
2. **Checkout step** at the SHA in `upstream.lock` (sibling path or
   `WOW_SHADOW_UPSTREAM`), not a floating branch.
3. **`uv` + upstream project install** so `uv run --project <upstream>` can
   import pydantic/msgpack for `EnvironmentFrame`.
4. **`lua5.3`** (already installed for unit CI).

Until (1)–(3) exist, keep integration **local-only**. Do not add an
integration job to `.gitea/workflows/test.yml` — a red job that cannot
fetch private upstream would block the unit checkmark. When ready, prefer
a **separate** workflow (e.g. `integration.yml`) with `workflow_dispatch` /
optional schedule so unit CI stays green without upstream.

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

## e2e plan (design only — not implemented)

Cost-gated per doctrine: full realm + bot is heavy. Run **nightly +
manual**, never on every push.

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
        ssh://git@10.11.4.11:222/Monolab/wow-classic-data.git \
        local_data/wow-classic-data
# compose bind-/volume-mounts these paths read-only where
# VANILLA_WOW_EXTRACTED_DATA_DIR / VMANGOS_MYSQL_DUMPS_DIR expect them
```

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

### (e) Mechanism-shaped e2e assertions

Not "reach level 2 in 90s" or hard-coded map coords. Prefer:

1. **Realm up:** `healthz` (or compose health) becomes ready within timeout.
2. **Seat attaches:** headless reference player + control socket accept a
   connection (`wow-sdk control doctor --backend nim` or equivalent at pin).
3. **Frame contract:** at least one environment frame projects into the
   plain-table shape Lua tools consume (`self_unit` present).
4. **Tool mechanism under live frames:** with a known party leader unit
   visible outside near radius, `follow_leader.decide` returns
   `kind == "move_to_unit"` and the live `unit_id` — not a scripted
   coordinate. Leader missing/not visible → `hold` /
   `leader_not_visible` (same contracts as unit tests).
5. **Fair play:** no out-of-band seat recognition; party membership comes
   only from game observations.

Timeouts and readiness polls live only in e2e; unit tier remains sleep-
free.

### (f) Concrete next steps (implementation order)

1. **Keep unit CI green** (this workflow). Add Lua packages only when deps appear.
2. **Fixtures + integration** — done locally (`make integration-test`). CI
   still blocked on private upstream mirror (see § Integration CI prerequisites).
3. **Data pin file** (e.g. `data.lock` next to `upstream.lock`) recording
   `Monolab/wow-classic-data` commit SHA for reproducible e2e.
4. **One-shot seed script** for the named volume (runnable on the runner
   host or as a `workflow_dispatch` "seed-only" job).
5. **Image build workflow** for `coworld-vmangos` at `upstream.lock` pin →
   push to `gitea.solution-nine.monofuel.dev/monolab/wow-shadow-army/...`
   with a strict `.dockerignore` excluding all Blizzard-derived trees.
6. **`.gitea/workflows/e2e.yml`:** nightly + dispatch; pull images; mount
   volume; compose up; run mechanism assertions; always compose down
   (no volume wipe).
7. **First green nightly** against follow_leader + monofuel (or Bot*) as
   leader; expand coverage only after that is boringly stable.

Until steps 3–6 exist, e2e stays local: `make start-server` + manual seat
bring-up per `docs/control-plane.md` and coworld-playbook
`games/vanilla-wow.md`.
