# coworld-vanilla-wow-fork — thin rebase layer on Gitea

Our private fork of Metta-AI `coworld-vanilla-wow`. Carries realm/client fixes
we need without writing to Softmax GitHub. Upstream checkout
`../coworld-vanilla-wow` stays READ-ONLY per `AGENTS.md`.

| | |
|---|---|
| Worktree | `/home/monofuel/Documents/Projects/Softmax/coworld-vanilla-wow-fork` |
| Gitea | `ssh://git@10.11.4.11:222/Monolab/coworld-vanilla-wow.git` |
| Web | https://gitea.solution-nine.monofuel.dev/Monolab/coworld-vanilla-wow |
| Branch `main` | mirrors Metta-AI `main` (stock upstream, no local delta) |
| Branch `shadow-army-fixes` | our carried commits, rebased on `main` |
| Last synced upstream | `adbdd1497` ("Refresh current-main Coworld image set") — 2026-08-03, 730 commits past prior sync; pin `ec5bd2f9d` now 1661 behind main; `shadow-army-fixes` not yet rebased |

## Remotes (on the fork worktree)

| Remote | URL | Push |
|---|---|---|
| `origin` | Gitea `Monolab/coworld-vanilla-wow` | **yes** — our home |
| `upstream` | `git@github.com:Metta-AI/coworld-vanilla-wow.git` | **DISABLED** |
| `local-upstream` | path to `../coworld-vanilla-wow` (offline fetch) | **DISABLED** |

Never push to GitHub from this worktree. All writes go to Gitea via `origin`.

## Strategy: upstream is always right

Softmax's stack is what we compete on in the vanilla-wow tournament, so the
fork is a **thin rebase layer, never a divergent branch**:

1. **Minimum possible delta.** One commit per fix, each self-contained and
   upstreamable as-is (message carries the why + evidence citation). No
   refactors, no cleanups, no reformatting.
2. **Upstream wins on conflict.** Routine sync is below. If one of our commits
   conflicts with an upstream change: **drop ours, take theirs**
   (`git rebase --skip`), then re-evaluate whether the fix is still needed —
   upstream may have fixed it their own way.
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

## Sync upstream → Gitea

```bash
cd /home/monofuel/Documents/Projects/Softmax/coworld-vanilla-wow-fork

git fetch upstream
git checkout main
git merge --ff-only upstream/main
git push origin main

git checkout shadow-army-fixes
git rebase upstream/main          # conflicts: git rebase --skip (drop ours), re-evaluate
git push --force-with-lease origin shadow-army-fixes
```

`--force-with-lease` is expected after rebase (history rewrites). Do **not**
force-push `main`. After any rebase, re-run the validation below before
rebuilding images.

Offline alternative: `git fetch local-upstream` after updating the sibling
checkout (`cd ../coworld-vanilla-wow && git pull`), then merge/rebase onto
`local-upstream/main` instead of `upstream/main`.

## Carried fixes

SHAs rewrite on every rebase; identify by message / path.

| Tip SHA (as of last sync) | What | Why | Upstream status |
|---|---|---|---|
| `2816b7e33` (`shadow-army-fixes`) | cowpatch `FACTION_STANDING_PACKET_WRITER`: emit `uint32(1)` row-count prefix in `SMSG_SET_FACTION_STANDING` | Count-less body deterministically crashes the build 5875 client (NULL `Faction.dbc` row 0 deref at WoW.exe RVA `0x000D4BEE`) on every reputation-granting quest turn-in. Full disassembly evidence: [`quest-crash-forensics.md`](quest-crash-forensics.md). | **Not reported yet** — evidence package ready for monofuel to submit |
| `065853773` (`shadow-army-fixes`) | `client/packets/quest_progression.nim` `parseFactionStanding` + proof: accept both the count-prefixed 5875 stock framing and the count-less 8-byte coworld framing | Bot must work against both the tournament stack (count-less) and our patched realm (stock framing). Shapes cannot collide (no count makes `4 + 8*count == 8`). | **Not reported yet** — same evidence package |
| `62685254c` (`party-invite-observation`) | client: apply social-party packet models to retained party state | Party roster / invite observation for escort | Keep; rebased 2026-07-27 |
| `cb092b666` (`party-invite-observation`) | `bakPromoteParty` + execute path (masks **dropped** — upstream removed factorized external masks in `nim_control.v2`) | Hand leadership to Murist; death/quest external masks no longer apply on v2 | **Adapt needed** — see `docs/upstream-nim-control-v2.md` |

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

- **Upstream report**: forensics + fix are ready to hand to Softmax; not yet
  reported.
