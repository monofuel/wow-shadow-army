# coworld-vanilla-wow-fork — thin local rebase layer

Local-only fork of the coworld-vanilla-wow upstream checkout so we can carry
fixes the running realm needs without ever writing to upstream
(`../coworld-vanilla-wow` is READ-ONLY per `AGENTS.md`).

| | |
|---|---|
| Fork | `/home/monofuel/Documents/Projects/Softmax/coworld-vanilla-wow-fork` |
| Branch | `shadow-army-fixes` |
| Forked from | upstream `main` @ `98220fead107070b0999549e3074056668d34bb7` ("Refresh Coworld image set after supporting slim") |
| Remote `upstream` | `/home/monofuel/Documents/Projects/Softmax/coworld-vanilla-wow` (local path, fetch-only in practice) |
| Pushed anywhere | **No.** Local-only. Whether Softmax code may go to the personal gitea is monofuel's call — open question, do not push meanwhile. |

## Strategy: upstream is always right

Softmax's stack is what we compete on in the vanilla-wow tournament, so the
fork is a **thin rebase layer, never a divergent branch**:

1. **Minimum possible delta.** One commit per fix, each self-contained and
   upstreamable as-is (message carries the why + evidence citation). No
   refactors, no cleanups, no reformatting.
2. **Upstream wins on conflict.** Routine sync is
   `git fetch upstream && git rebase upstream/main`. If one of our commits
   conflicts with an upstream change: **drop ours, take theirs**
   (`git rebase --skip`), then re-evaluate whether the fix is still needed at
   all — upstream may have fixed it their own way.
3. **Every carried fix is a pending upstream submission**, not a permanent
   local divergence. Track status in the table below.
4. **Tournament rule: never tune bot behavior against our patched build.**
   The tournament runs on stock coworld. Fixes here must be limited to
   things that cannot influence bot tuning (e.g. the faction-standing fix is
   human-client QoL: it only affects the real 1.12 `WoW.exe`, which Nim bots
   never run). If a prospective patch would change **bot-observable server
   behavior**, stop and report instead of patching. The one bot-side change
   we carry (dual-shape `parseFactionStanding`) is strictly *more* tolerant —
   it accepts upstream's framing unchanged, so bots behave identically on the
   stock stack.

## Carried fixes

| Commit | What | Why | Upstream status |
|---|---|---|---|
| `9dead5d46` | cowpatch `FACTION_STANDING_PACKET_WRITER`: emit `uint32(1)` row-count prefix in `SMSG_SET_FACTION_STANDING` | Count-less body deterministically crashes the build 5875 client (NULL `Faction.dbc` row 0 deref at WoW.exe RVA `0x000D4BEE`) on every reputation-granting quest turn-in. Full disassembly evidence: [`quest-crash-forensics.md`](quest-crash-forensics.md). | **Not reported yet** — evidence package ready for monofuel to submit |
| `dfbccfb47` | `client/packets/quest_progression.nim` `parseFactionStanding` + proof: accept both the count-prefixed 5875 stock framing and the count-less 8-byte coworld framing | Bot must work against both the tournament stack (count-less) and our patched realm (stock framing). Shapes cannot collide (no count makes `4 + 8*count == 8`). | **Not reported yet** — same evidence package |

## Rebase on upstream

```bash
cd /home/monofuel/Documents/Projects/Softmax/coworld-vanilla-wow-fork
git fetch upstream
git rebase upstream/main        # conflicts: git rebase --skip (drop ours), then re-evaluate
```

After any rebase, re-run the validation below before rebuilding images.

## Validate the cowpatch still applies (no docker needed)

The patch system (`infra/docker/vmangos/patches/cowpatch/core.py`) is anchored
string replacement that hard-fails on anchor drift, so applying the whole
catalog against a scratch checkout of the pinned VMaNGOS ref *is* the dry run:

```bash
FORK=/home/monofuel/Documents/Projects/Softmax/coworld-vanilla-wow-fork
REF=$(grep -oP 'ARG VMANGOS_REF=\K\w+' "$FORK/infra/docker/vmangos/Dockerfile.native")
WORK=$(mktemp -d)
git init -q "$WORK/vmangos-src" && cd "$WORK/vmangos-src"
git remote add origin https://github.com/vmangos/core.git
git fetch -q --depth 1 origin "$REF" && git checkout -q FETCH_HEAD
python3 "$FORK/infra/docker/vmangos/patches/apply_coworld_patches.py" "$WORK/vmangos-src"
grep -A8 'SetFactionStanding::AppendBodyTo' src/game/Server/Packets/Misc.cpp
```

Expected: `applied 34 patch families (214 operations)` (count will drift with
upstream) and the writer emitting `buffer << static_cast<uint32>(1);` before
the row.

Bot-side gates (NixOS needs the library paths; adjust store hashes if GC'd):

```bash
cd "$FORK"
export LD_LIBRARY_PATH=/nix/store/376vgdk3hbz1gm0ix4ccz30fkgdk8ys3-bzip2-1.0.8/lib:/nix/store/604a9ayx3kdxqlx72f5wb39gn401y38v-openssl-3.6.3/lib:/nix/store/39fgb5pr1r6k3szvfhpfmv9jp829kisx-libglvnd-1.7.0/lib:/run/opengl-driver/lib
nim r --passL:"-L/nix/store/604a9ayx3kdxqlx72f5wb39gn401y38v-openssl-3.6.3/lib" \
  proof/proof_reputationframe_progression_rows.nim
nim check player/player.nim
```

## Build the shadow-army images

Distinct tags so they can never be confused with the stock `:local` images.
From `wow-shadow-army`: `make fork-images`. Or by hand (serialize them —
each build can saturate the box):

```bash
cd /home/monofuel/Documents/Projects/Softmax/coworld-vanilla-wow-fork

# 1. VMaNGOS server binaries (the slow one; carries the cowpatch fix)
docker build -f infra/docker/vmangos/Dockerfile.native \
  --target vmangos_native_runtime \
  -t coworld-vmangos-native-runtime:shadow-army .

# 2. Reference player artifact (carries the dual-shape parser)
docker build -f player/Dockerfile --ssh default \
  --target reference_player_runtime_artifact \
  -t coworld-reference-player-runtime:shadow-army .

# 3. Realm wrapper image (what coworld-game actually runs)
docker build -f infra/docker/vmangos/Dockerfile --ssh default \
  --build-arg COWORLD_NIM_PARALLEL_BUILD=8 \
  --build-context vmangos_native_runtime=docker-image://coworld-vmangos-native-runtime:shadow-army \
  --build-context reference_player_runtime=docker-image://coworld-reference-player-runtime:shadow-army \
  -t coworld-vmangos:shadow-army .
```

Verify the fix is inside the built image (build 1's log prints
`[coworld-patch] applied: write the stock faction-standing packet body`; the
patched source itself is deleted after compile, so the log line + the
pre-build dry run are the evidence).

## Switch-over (HUMAN runs this; never an agent, realm is live)

The realm is the `coworld-game` service of compose project `coworld-vmangos`,
run from the **upstream** checkout (bind mounts point at upstream's
`local_data/`; the fork has no `local_data`, so keep operating from upstream —
only the image changes). The compose file hardcodes `image:
coworld-vmangos:local`, so the swap is a retag:

```bash
cd /home/monofuel/Documents/Projects/Softmax/wow-shadow-army

# 0. keep a rollback handle on the stock image
docker tag coworld-vmangos:local coworld-vmangos:stock-98220fe

# 1. point :local at our build
docker tag coworld-vmangos:shadow-army coworld-vmangos:local

# 2. bounce only the realm container (operator up has no --build by default)
make stop-server
make start-server
```

Rollback:

```bash
docker tag coworld-vmangos:stock-98220fe coworld-vmangos:local
make stop-server && make start-server
```

Post-swap check: turn in any reputation-granting quest on the 1.12 client —
no ERROR #132. On the wire, `SMSG_SET_FACTION_STANDING` bodies are now
`4 + 8*n` bytes (leading `uint32` count) instead of exactly 8.

Caveat: anything that rebuilds `coworld-vmangos:local` from upstream (operator
`up --build`, upstream image-refresh workflows) silently reverts the swap —
re-run step 1 afterwards, or re-check which build `:local` points at with
`docker image inspect coworld-vmangos:local --format '{{.Id}}'`.

### Why the swap cannot wipe characters/accounts

- The DB lives in named volume `coworld-vmangos_vmangos-coworld-db`, mounted
  at `/var/lib/coworld-mariadb` in `coworld-game`
  (`infra/compose.vmangos.yml` `persistent`/`coworld` service +
  `volumes:` section; confirmed live via `docker inspect
  coworld-vmangos-coworld-game-1`).
- `make stop-server` → operator `down` → `docker compose ... rm --stop -f
  coworld-game` (container only). Volumes are removed **only** by the
  explicit `down --volumes` flag (`server/scripts/docker_vmangos_server.py`
  `cmd_down`, upstream lines 639-645). Never pass `--volumes`.
- Retagging images touches no volumes at all.

## Open questions

- **Remote hosting**: fork is local-only. Pushing Softmax-derived code to
  monofuel's personal gitea (or anywhere) is HIS call — not decided.
- **Upstream report**: forensics + fix are ready to hand to Softmax; not yet
  reported.
