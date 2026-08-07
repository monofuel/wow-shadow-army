# coworld-vanilla-wow-fork

Private Gitea mirror of Metta-AI `coworld-vanilla-wow` for client customizations.
Upstream checkout `../coworld-vanilla-wow` stays READ-ONLY per `AGENTS.md`.

| | |
|---|---|
| Worktree | `/home/monofuel/Documents/Projects/Softmax/coworld-vanilla-wow-fork` |
| Gitea | `ssh://git@10.11.4.11:222/Monolab/coworld-vanilla-wow.git` |
| Web | https://gitea.solution-nine.monofuel.dev/Monolab/coworld-vanilla-wow |
| Branch `main` | **should** mirror Metta-AI `main` (stock upstream) — currently polluted with Petrel history; use `upstream-mirror` until force-with-lease |

## Remotes

| Remote | URL | Push |
|---|---|---|
| `origin` | Gitea `Monolab/coworld-vanilla-wow` | **yes** |
| `upstream` | `git@github.com:Metta-AI/coworld-vanilla-wow.git` | **DISABLED** |
| `local-upstream` | path to `../coworld-vanilla-wow` | **DISABLED** |

Never push to GitHub from this worktree. All writes go to Gitea via `origin`.

## Branches (prefer-upstream realign)

| Branch | Meaning |
|---|---|
| `upstream-mirror` | Exact `upstream/main` tip (pure Metta). **Use this as the integration base.** |
| `monofuel/petrel` | Started at pure `upstream/main` for rebased Petrel (WIP — not a full Petrel port yet). |
| `embedded-lua-client` | **Current working Petrel** on old merge-base (`petrel-pre-realign-20260807` tag). Wet cheese still runs here. |
| `main` (Gitea) | Dirty until rewritten; do not treat as pure upstream until fixed. |

Prefer **upstream** on every shared RPB/nav/player conflict. Do not forever-vendor
deleted `client_types.nim`. Full port notes:
[docs/traverse/petrel-upstream-realign.md](traverse/petrel-upstream-realign.md).

**Why not a simple merge:** upstream moved pilot to `bot_pilot.nim` and
`Observation`/`Action` (`plan_route` + `input`). Petrel still hooks the older
ClientView → input-batch path in `visual_adapter.nim`. Realign = re-host Petrel
on the new contract, not `git merge` thrash.

## Sync upstream → Gitea

```bash
cd /home/monofuel/Documents/Projects/Softmax/coworld-vanilla-wow-fork

git fetch upstream
git checkout -B upstream-mirror upstream/main
git push -u origin upstream-mirror
```

To make `main` pure again (history rewrite — **monofuel must OK**):

```bash
git checkout -B main upstream/main
git push --force-with-lease origin main
```

Offline alternative: `git fetch local-upstream` after
`cd ../coworld-vanilla-wow && git pull`, then point mirror at `local-upstream/main`.

## Client vs server

- **Client customizations** go on the fork (Nim client / player).
- **Server components** stay stock upstream — never diverge.
- Tournament runs stock coworld; do not tune bot behavior against a patched build.
- **Land pathing** = upstream RPB feet. **Wet cheese waypoints** = shadow-army
  strategy only (`lua/config/traverse_beats.json`).
