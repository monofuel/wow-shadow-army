# File-space audit — game copies, .git bloat, telemetry sinks

Audited 2026-07-31 during the workstation → NFS (`/mnt/steel-chest/Monolab/Home/monofuel/Softmax`)
migration. Numbers are `du -sh` from the workstation copies. Context: a private
vmangos test realm ran for a couple of days in late July and quietly dumped
tens of GB of logs/telemetry — that run is most of the surprise weight here.

## How many copies of the game exist (found: ~5, should be: 1 + thin instances)

| # | Location | Size | What it is |
|---|---|---|---|
| 1 | `wow-classic-data/Coworld-WoW-Classic/` | 7.9G | **Canonical.** Git worktree: 5.1G client + 2.9G extracted `vmangos-5875-data`. Has `checksums.txt`. The 4-hour tailscale download. |
| 2 | `wow-classic-data/.git` | 6.2G | Packed git history of #1 — the data repo versions the game assets themselves, so the clone pays ~2x. |
| 3 | `coworld-vanilla-wow/local_data/coworld-bundle/Coworld-WoW-Classic/` | 7.9G | Full duplicate of #1. Redundant once #1 exists. |
| 4 | `coworld-vanilla-wow/local_data/player/` | 9.3G | Installed/provisioned client instance for upstream runs. |
| 5 | `coworld-vanilla-wow-xr/local_data/player/` | 9.3G | XR variant's own provisioned client (used for `-d:xr` client testing — a legit second instance while that work is active). |
| — | `wow-shadow-army/local_classic/client/` | 9.2M | **The right pattern.** Thin shell (WoW.exe, DLLs, WTF/WDB); all `Data/*.MPQ` are absolute symlinks into #1. |

Target state: **one** canonical store (`wow-classic-data`), and every repo that
needs a playable client builds a thin symlinked instance like
`wow-shadow-army/local_classic` does. #3 (bundle duplicate) is deletable; #4/#5
are rebuildable from #1 and could be converted to symlink instances.

Related: `coworld-vanilla-wow/local_data/downloads/` (1.2G) and
`local_data/vmangos-5875-data` (921M) + `vmangos-db` (130M) — partial overlaps
with what #1 already carries; worth a dedupe check before deleting anything.

## Why .git is so heavy per repo

| Repo | .git | Why |
|---|---|---|
| `wow-classic-data` | 6.2G | Game assets are committed to git; history ≈ another full copy of the data. Price of distributing via git over tailscale. |
| `coworld-vanilla-wow-fork` | 119M | Full clone of upstream's ~17.2k-commit history. Our actual delta is ~11 commits of nim work (a couple MB); the rest is inherited history. Same story for `-xr` (108M). |
| `coworld-vanilla-wow` | 107M | Upstream's own 17.2k commits — normal for a repo this active. |
| `wow-shadow-army` | 1.1M | Healthy. `local_data/` + `local_classic/` are gitignored, so runtime weight never enters history. |

Every coworld variant also carries a ~68M Python `.venv` (regenerable, never
worth copying/backing up).

## Where telemetry and logs go (the couple-day test realm dumped ~32G)

| Sink | Size | Producer |
|---|---|---|
| `coworld-vanilla-wow/local_data/coworld-captures/godview_*.jsonl` | 18G | Godview observation capture shards, 257M each, sequentially numbered from the test-realm session. |
| `coworld-vanilla-wow/local_data/coworld-run/logs/` | 13G | Realm/run logs from the same session. |
| `wow-shadow-army/local_data/brain-logs/*.jsonl` | ~720M | Shadow brain streams; single files reach 494M. |
| `wow-shadow-army/local_data/*-bot.log*` | ~100M | Per-bot seat logs (beru, igris, tusk, warlock, …), rotated by timestamp suffix. |

None of this is bounded or rotated by size today — a multi-day realm session
grows unbounded. Leveling-up options when we care: size-capped rotation for
`coworld-run/logs` and `brain-logs`, and archive-then-prune (zstd) for godview
captures we want to keep for analysis.

## Hidden state: docker named volumes (RULE VIOLATION — should be folders)

Standing rule: all persistent state lives in bind-mounted folders so it can't
be missed by backups/migrations. Upstream's `infra/compose.vmangos.yml`
follows that for every input/output mount (seeds, config, logs, captures →
`local_data/`) but hardcodes **named volumes** for the live DB dirs — the one
place holding non-regenerable state:

| Volume | Mount | Holds |
|---|---|---|
| `coworld-vmangos_vmangos-coworld-db` | `/var/lib/coworld-mariadb` | **Live realm DB — accounts + characters** |
| `coworld-vmangos_vmangos-db` | `/var/lib/mysql` | Standalone `db` service MariaDB |
| `coworld-vmangos_vmangos-etc` | `/vmangos-etc` | Generated server configs |

Snapshots taken 2026-07-31 (server stopped, quiescent) →
`<NFS>/Softmax/backups/vmangos-coworld-db-2026-07-31.tar.gz` (57M) +
`vmangos-etc-2026-07-31.tar.gz`. Planned fix (not yet done): compose override
bind-mounting the DB dirs into `local_data/`, one-time volume→folder
migration, then retire the named volumes. Until then, any backup story must
include `docker volume ls`.

## Migration status (NFS share)

Copied in full and **checksum-verified** (`rsync -aic`, zero content diffs)
as of 2026-08-01: AGENTS.md, autoresearch, wow-shadow-army, wow-classic-data
(15G), coworld-vanilla-wow (50G), coworld-vanilla-wow-fork,
coworld-vanilla-wow-xr (9.5G), plus docker-volume snapshots under
`backups/`. Not yet migrated: the other Softmax projects (coworld-games,
crewrift, marketboard, playbook, workspace nim siblings mummy/jsony/…, etc.).
Cleanup decisions happen against the NFS copy, with the workstation originals
as fallback until we're confident.
