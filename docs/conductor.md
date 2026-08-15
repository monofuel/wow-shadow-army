# Conductor — the autoresearch loop

A dumb, reliable Nim daemon that runs the experiment loop for a league
lane: claim a ticket, let a coding agent work it on a branch, hold the
result against a reviewer, structural diff guards, and a pure code
gate, then merge only what ratchets the score upward — and ship behind
the champion guard when the merged build beats the last-shipped one.

Born from the 2026-08-13 postmortem: LLM-driven loops halt on transient
errors, grade their own homework, and thrash. So here the control plane
is plain software; LLMs are fallible subprocess workers; the gate is
code and cannot be argued with; the score can only go up.

## Layout

| piece | where |
|---|---|
| CLI / daemon | `src/conductor.nim` (`nim r src/conductor.nim <league> <cmd>`) |
| modules | `src/conductor/{cfg,state,ledger,evalgate,masterhealth,tickets,agents,tick,shiplib}.nim` |
| config | `<wow-coworld root>/conductor.json` (tracked in the root repo) |
| runtime state | `.conductor/` in this checkout (gitignored): `state.json`, `master-health.json`, `conductor.pid`, `pause`, `NEEDS-HUMAN`, `worktrees/` |
| score ledger | `scores/<league>.jsonl` + `scores/<league>-hosted.jsonl`, committed on the lane branch |
| agent library | scriptorium (`../scriptorium`, wow-coworld submodule): `agent_runner` + harnesses, `git_ops`, `prompt_catalog` |
| prompts | `src/conductor/prompts/{coding_agent,review_agent}.md` (staticRead) |
| systemd unit | `tools/conductor.service` (manual install; PID guard makes double-starts safe) |

## Commands

```
nim r src/conductor.nim traverse status     # config, champion, tick state, flags
nim r src/conductor.nim traverse baseline   # eval lane HEAD, seed the ledger
nim r src/conductor.nim traverse hosted     # ingest hosted episode scores
nim r src/conductor.nim traverse once       # one full tick
nim r src/conductor.nim traverse run        # the daemon
nim r src/conductor.nim traverse gate       # re-eval + gate the in-flight candidate
nim r src/conductor.nim traverse master-health [--force]  # test this checkout's HEAD
nim r src/conductor.nim traverse ship [guard-uuid]   # manual ship (guard needed first time)
```

Run from this checkout (or set `CONDUCTOR_REPO`); the wow-coworld root
is the parent dir (or `CONDUCTOR_ROOT`).

## The tick

1. **Claim** — oldest eligible `tickets/open/` for the lane (`**Lane:**`
   match, `**Depends:**` satisfied, no `**Blocked-on:**`); `git mv` to
   in-progress IS the assignment (concurrent sessions race through git).
2. **Worktree** — fresh branch `monofuel/exp-<NNNN-slug>` off the lane
   branch under `.conductor/worktrees/`, shared `local_data` symlinked.
3. **Code** — coding agent (conductor.json `agents.coding`) implements
   and commits in the worktree. One revision round on reviewer BLOCK.
4. **Diff guards** (structural, non-negotiable): protected paths
   untouched (eval tooling, Makefile, Dockerfile.petrel, conductor
   itself, scores/); test-assertion count must not decrease.
5. **Review** — a different harness/model. REJECT-ONLY: `VERDICT: SHIP`
   lets the candidate proceed to the gate, `VERDICT: BLOCK` (or an
   unparseable reply) does not; a reviewer can never override the gate.
6. **Static tests** — `make test` in the worktree: the full unit tier
   (lua + `test-nim-soft` + smoke/`nim check` + the Python traverse
   soap/checkpoint tiers + `traverse-lint-soft`). Measured 2026-08-15:
   `test-lua` alone 2s, full `make test` 30s warm in a checkout and 89s
   cold in a fresh conductor worktree (nim cache is keyed by path, so
   every new worktree pays the compile) — cheap against a multi-minute
   eval, so the whole tier is inside the gate. Before ticket 0044 this
   leg was `test-lua` only and `3def984` rode a broken Nim tier and
   broken Python road tests to master.
7. **Eval gate** — optional `**Repro:**` failure-site bracket first
   (must pass), then the full-course eval; the PURE comparator holds it
   against the champion ledger row: floor ratchet (`max_northing` never
   goes down), configured assertions (deaths, fat_min, fatigue_s,
   form_lost, snags — each `<=`/`>=` vs champion), and no NEW warning
   classes. Eval-slot contention (make rc=2 / stale run.log) unclaims
   the ticket without charging an attempt.
8. **Merge or park** — pass: rebase, ff-only (no-ff fallback) into the
   lane branch, ledger `merged` row, ticket → done/. Fail: branch
   pushed for autopsy, falsification note + attempt count on the
   ticket (→ open/, or stuck/ at `maxAttemptsPerTicket`), ledger
   `parked` row.
9. **Ship** (daemon, `ship.auto: true`) — see below.

### Eval mode doctrine

Headless evals are AUTHORITATIVE (the tournament runs headless on
servers). Headed runs are timing-inaccurate on the 10x client and roll
worse; behavior inspection = pack + replay a headless run
(tools/pack_traverse_replay.sh, TRAVERSE_REPLAY=<file>
tools/traverse_replay.sh), never a headed test's outcome.

## Master health (the second line of defence)

The gate only sees candidates the loop itself built. A hand commit pushed
straight to master never passes through it — that is how `3def984` landed
with no `scores/traverse.jsonl` row at all. So the daemon also runs a
watchdog at the top of every loop pass (`src/conductor/masterhealth.nim`):

- It runs **the same `make test`** the gate's static leg runs, in the
  checkout the conductor lives in (`wow-shadow-army`, on `master`).
- Only when that HEAD **moved since the last verdict**. A quiet master
  costs one `git rev-parse`; a moved master costs the measured ~30s.
- The verdict lands in `.conductor/master-health.json` and, on red, one
  log line: `conductor: MASTER RED — master @ <sha> fails make test — …`
  (`journalctl --user -u conductor`). `conductor <league> status` prints
  the same verdict; `conductor <league> master-health [--force]` runs it
  by hand and exits 1 on red.

It **flags**, it does not block: a red master is reported within one tick,
not prevented. Blocking direct-to-master needs a git hook, which is a
separate hardening (ticket 0044 item 2).

State file shape (atomic write, gitignored, never committed):

```json
{
  "branch": "master",
  "sha": "3def984ab",
  "status": "green",
  "checkedAt": "2026-08-15T06:41:12Z",
  "durationS": 31.4,
  "command": "make test",
  "detail": ""
}
```

`status` is one of `unknown` (never checked / file corrupt), `green`,
`red`, `error` (could not run — no HEAD sha, harness fault). `detail` is
`""` on green and the last ~600 chars of failing output on red.

**Dashboard light (not implemented here — `system/system_server.nim` is
owned by another lane).** The hookup is a read of that one file: The
System already knows the army dir (`SYSTEM_ARMY_DIR`), so read
`<army dir>/.conductor/master-health.json` on the existing dashboard
poll, and paint a light from `status` — green/red/grey(unknown|error) —
labelled with `sha` and `checkedAt`, with `detail` as the hover/expand
text. Stale-data rule applies: if `checkedAt` is older than the daemon's
tick cadence (or the file is missing), show grey "unknown", never a stale
green. No new endpoint or make target is needed and nothing needs
refreshing by hand.

## The ship ratchet

Stricter than the merge gate: the merged report must beat the
**last-shipped** ledger row on floor + every assertion axis, and the
lane may hold no open/in-progress tickets tagged `**Severity:** death`
(never ship with a known dies/stalls class). Execution follows
`playbooks/upload-bot.md` exactly: freeze (clean trees) → `make
petrel-image` → identity (exactly one player or STOP) → upload →
submit `--expected-champion-policy-version <last shipped id>` →
readback → `player unset`. Any ambiguity writes `.conductor/NEEDS-HUMAN`
and skips the ship — the reigning champion keeps racing, so a skipped
ship is always safe.

**First ship must be seeded**: `conductor traverse ship <guard-uuid>`
with the current hosted champion's policy-version id (e.g. petrel:v4 =
`0b2886a3-4f...`). After that the ledger's shipped row carries the guard.

## Runbook

- **Start**: `nix develop --command nim r src/conductor.nim traverse run`
  (or install `tools/conductor.service`).
- **Pause without stopping**: `touch .conductor/pause` (removing it
  resumes). SIGTERM/ctrl-c stops cleanly; a crashed tick is unwound on
  the next start (ticket back to open uncharged, branch kept).
- **NEEDS-HUMAN**: append-only flag file; `status` prints it. Clear it
  after acting (`rm .conductor/NEEDS-HUMAN`).
- **Read the ledger**: `scores/traverse.jsonl` — one JSON row per gate
  decision; the champion is the last `baseline|merged|shipped` row.
  `scores/traverse-hosted.jsonl` tracks hosted floor/mean/best and
  warns on local-vs-hosted divergence (the PETREL_SWIM class).
- **5xx / agent flake**: consumed by harness retries + tick backoff
  (30s→600s). The loop does not die; that is the point.

## Adding a league

Add an entry under `leagues` in conductor.json: lane branch + checkout,
ticket lane, eval make target/vars, floor metric, assertions, protected
paths, ship block. The eval must produce
`local_data/traverse-segment-result.json`-shaped output (or extend
`evalgate.runEval` for that league's scorecard).

## Known limits (deliberate v1)

- One eval slot (ticket 0023 parallel slots plugs in here; the human
  owns slot 0 by convention — conductor waits, never steals).
- (Lifted 2026-08-15, ticket 0044) "Nim test tier runs in the main
  checkout only" is no longer true: `setupWorktree` symlinks the sibling
  checkouts next to the worktree and nim's parent-config walk still finds
  the main `nim.cfg`, so the whole `make test` tier — nim included — is
  green from a nested worktree. Verified in a probe worktree at the real
  depth before widening the gate.
- Master health flags, it does not block: a direct-to-master commit still
  lands, it just gets named within one tick (see above).
- race.md / G01 scoreboard rows for ships are still hand-written —
  the ledger row is authoritative; port the prose rows when convenient.
- No goal-derived ticket minting: an empty lane queue idles rather than
  inventing work (tickets/goals discipline stays human-curated).
