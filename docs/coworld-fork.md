# coworld-vanilla-wow-fork

Private Gitea mirror of Metta-AI `coworld-vanilla-wow` for client customizations.
Upstream checkout `../coworld-vanilla-wow` stays READ-ONLY per `AGENTS.md`.

| | |
|---|---|
| Worktree | `/home/monofuel/Documents/Projects/Softmax/coworld-vanilla-wow-fork` |
| Gitea | `ssh://git@10.11.4.11:222/Monolab/coworld-vanilla-wow.git` |
| Web | https://gitea.solution-nine.monofuel.dev/Monolab/coworld-vanilla-wow |
| Branch `main` | mirrors Metta-AI `main` (stock upstream) |

## Remotes

| Remote | URL | Push |
|---|---|---|
| `origin` | Gitea `Monolab/coworld-vanilla-wow` | **yes** |
| `upstream` | `git@github.com:Metta-AI/coworld-vanilla-wow.git` | **DISABLED** |
| `local-upstream` | path to `../coworld-vanilla-wow` | **DISABLED** |

Never push to GitHub from this worktree. All writes go to Gitea via `origin`.

## Sync upstream → Gitea

```bash
cd /home/monofuel/Documents/Projects/Softmax/coworld-vanilla-wow-fork

git fetch upstream
git checkout main
git merge --ff-only upstream/main
git push origin main
```

Do **not** force-push `main`. Offline alternative: `git fetch local-upstream`
after `cd ../coworld-vanilla-wow && git pull`, then merge `local-upstream/main`.

## Client vs server

- **Client customizations** go on the fork (Nim client / player).
- **Server components** stay stock upstream — never diverge.
- Tournament runs stock coworld; do not tune bot behavior against a patched build.
