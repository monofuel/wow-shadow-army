# Asset-server connection drops wedge bot clients under load

**Status:** diagnosed to strong hypothesis, NOT yet verified by experiment.
**Suspected blast radius:** the production/hosted bot asset-loading failures
monofuel could never reproduce on his 7950X dev box.
**Date:** 2026-08-15, home realm, during four-seat + human play session.

## What happened

Tusk (home seat, warrior, level 6) went offline mid-fight ~05:59Z. The
launcher process stayed alive; `status.json` froze (last write mid-combat,
`intent_kind=libAttack`); the realm dropped the character. Restarting the
seat recovered it. Nobody and nothing noticed except the human eyeballing
the dashboard roster (ticket 0055 exists because of this).

## Evidence (attachments in `2026-08-15-asset-server-attachments/`)

1. **Every seat was eating asset-fetch failures all night**, not just Tusk:
   `grep -c 'http fetch failed' launcher.log` → Shadowfel 27, Igris 24,
   Beru 28, Tusk 3 (post-restart) + 8 (wedge log). Error string, always:
   `http fetch failed (Connection was closed before full request has been
   made): http://127.0.0.1:25608/assets/...`
2. **All seats share ONE nginx.** `ss -tlnp` shows a single listener on
   127.0.0.1:25608 (nginx 1.30.4), config generated per launch-unit by the
   client's `player/` launcher tooling into
   `~/.coworld/player/launcher_units/<hash>/nginx-assets-25608.conf`
   (copy attached). All four seat logs fetch from :25608.
3. **The config tunes for bursts, not marathons.** It raises
   `worker_rlimit_nofile 16384` and `worker_connections 8192` (comment block
   documents an older refused-connection bug with invisible doodads), sets
   `keepalive_timeout 30`, and sets **no `keepalive_requests`** — so the
   nginx default of **1000 requests per keepalive connection** applies.
4. **Streams are bigger than the per-connection budget.** Tusk's final
   settle: `queued=3071 started=3068 completed=3054 failed=12`. Two earlier
   settles: 2197 and 2666 queued (failed=0). A `HTTP assets delayed:
   pending=113 blocker=...` stall preceded the wedge window.
5. **The failures that precede the wedge include chunk MANIFESTS, not just
   art:** `azeroth_29_27.assets.txt` and `azeroth_28_28.assets.txt` both
   failed in the last settle before the freeze. A lost texture degrades a
   model; a lost manifest plausibly stalls the whole chunk-load pipeline.

## Hypotheses, in confidence order

- **H1 — keepalive_requests exhaustion.** nginx closes a keepalive
  connection after its 1000th request. A client streaming 3,071 assets over
  few connections crosses that boundary ~3 times per settle; requests
  already queued on the closing connection die with exactly the observed
  error. Predicts small failed counts on big settles (observed: 12) and
  zero on streams that fit the budget (observed: earlier settles failed=0
  at 2197/2666 queued only if spread over more connections — connection
  count per stream is not logged, a gap the experiment must close).
- **H2 — keepalive_timeout 30 under CPU starvation.** A contended client
  that stalls >30s mid-stream returns to a connection nginx already closed.
  Load-dependent in exactly the way that spares an idle 7950X and hits
  shared prod backends and tonight's 4-seat + agents box.
- **H3 — client-side handling of server-initiated close is the wedge.**
  failed=12-of-3071 shows retries usually absorb the closes. The unlucky
  path: a failed .assets.txt manifest fetch that does NOT get retried (or
  whose retry also lands on a closing connection) leaves the world-stream
  pipeline waiting forever → frozen client → realm disconnect. H3 is the
  difference between "cosmetic failures" (three surviving seats) and
  "wedge" (Tusk).

## Why prod-not-dev

Both H1 and H2 amplify with load: more concurrent clients per nginx, slower
per-request drain, longer streams, more 30s stalls. Solo on a 7950X the
streams drain fast, nothing idles 30s, and retries absorb the rare
boundary close. Whether hosted backends share one asset server per N bots
the way home does is UNKNOWN and worth answering first when comparing.

## Verification plan (fork-side, local — ticket 0056)

1. Reproduce with load: 4 seats + throttled CPU (or more seats), count
   `http fetch failed` per hour as baseline.
2. Flip ONE knob: regenerate the conf with `keepalive_requests 100000;`
   (client launcher change on the fork — client-side, allowed). Same load.
   H1 predicts failures collapse to ~zero; H2 predicts survivors.
3. If failures persist, raise `keepalive_timeout` and repeat (H2).
4. Separately grep the client's fetch/retry code for manifest
   (`.assets.txt`) retry behavior (H3) — a missing retry there is worth
   fixing regardless of H1/H2.
5. Then monofuel decides on the upstream report with this doc + results
   attached (upstream owns the launcher tooling and the fetch code).

## Cross-references

- Evidence ledger: wow-coworld `upstream-health.md` entry 2026-08-15.
- Ticket: wow-coworld `tickets/` 0056 (verification experiment),
  0055 (seat babysitter — detection/recovery for wedges of any cause).
- Prod reports: monofuel's unreproducible hosted asset-loading failures
  (no local ticket; his report is the motivating symptom).

## 2026-08-15 update — H1 CONFIRMED against prod, fixed at the source

The traverse-lane agent closed the loop the same night:

- **Prod confirmation:** the exact error string appears in hosted episode
  logs for policy versions v10-v13; drop counts scaled with fetch
  concurrency (0 in v7-v9 before the residency pump raised concurrency,
  8 in v13, including a vmap collision model) — the H1 request-budget
  signature.
- **Why prod stalls instead of wedging:** the traverse fork's collision/
  terrain/navmesh consumers treat transient fetch failure as keep-waiting
  with a 1s transport retry, so drops cost ~1s stalls. The home wedge is
  therefore most plausibly H3 in the RENDERER's world-stream manifest
  path — a different consumer. H3 remains the open question (ticket 0056,
  rescoped).
- **Correction to this doc:** the generated conf's template is
  FORK-owned — `tools/nginx_assets.conf` in monofuel-vanilla-wow — not
  upstream launcher tooling as hypothesized above. The fix
  (`keepalive_requests 100000;`) landed on fork master a8835801f,
  cross-referencing this postmortem, and rides the next daemon build to
  hosted (v14). The pod-side platform asset server (job-*-game:8080) is
  not ours to tune; client retries absorb it.
- **Home rollout:** our fork checkout rebased onto that master
  (debug-port branch ad48d2f78 now carries the fix); the next
  home-army-restart launches seats with the fixed conf. Expected local
  result: fetch-failure counts drop to ~0. If a seat still wedges after
  that, H3 is isolated by elimination.

## 2026-08-15 update 2 — H3 RETIRED by fork audit; H4 is the wedge suspect

Full audit on branch monofuel/h3-manifest-retry (no changes needed):
- **H3 retired.** Transient manifest failures map to AssetWaiting and are
  re-fetched at 1 Hz forever (httpassets.nim:1698-1706, 1958-1972, retry
  requeue :1471-1479); 404 walks a bounded ladder to a clean terminal
  skip; NOTHING gates on manifest state — worst case is slower serial
  discovery, never a freeze. Falsifiable: injecting .assets.txt failures
  should NOT wedge a seat; if it does, H3 revives.
- **H4 (new prime suspect): native fetch-pool exhaustion with no
  effective timeout.** Under -d:noGui (bot seats): MaxConcurrentFetches
  == NativeHttpFetchWorkerCount == 16 (no spare workers);
  cancelExpiredFetches is a native no-op; the 30s deadline is evaluated
  only on a legacy blocking path runtime polling never enters; the
  worker HttpClient timeout is per socket READ, not per transfer — a
  half-closed keepalive or dribbling response holds a worker
  indefinitely. 16 such sockets = every fetch worker stuck = pending
  grows with a STABLE blocker URL and no "World stream settled" — the
  exact pre-freeze Tusk telemetry. Secondary: warm lane starves while
  the demand lane has any backlog (:1291-1308).
- **Repro rig:** fault proxy before :25608 holding 16 concurrent
  requests open (partial headers, no data, no FIN); expect climbing
  pending=, no settle, frozen status.json.
- **Instrumentation gap:** the "HTTP assets delayed" line logs neither
  inflight count nor oldest-fetch age; adding both makes H4 diagnosable
  from seat logs alone (would have settled Tusk from the attachments).
- Minor non-freeze defect logged: the manifest 3-attempt retry ladder is
  reachable only by definite 404s (which retries can't help); transients
  never reach it. Cosmetic, left alone for rebase friction.

## 2026-08-15 update 3 — triple simultaneous wedge during the 15-seat ramp

During the new-army cold-stream stampede (H1 fix LIVE, box healthy: load
~6, RAM 42/125G), Igris, Tusk, and Beru froze within a ~10s window
(status.json stale together); Shadowfel on the same nginx survived.
All three logs end with a COMPLETED "World stream settled" line
(failed=8 / 22 / 73; Tusk again shows .assets.txt manifest failures;
Beru shows unusually large 4,300-4,700-asset re-stream churn) — the
freeze is POST-settle, same as the original Tusk wedge. This weakens
"mid-stream pool paralysis" and points at whatever runs after settle
(retention sync / released-asset accounting / the settle epilogue) or
at pool exhaustion whose symptom emerges between streams. Evidence in
the rotated launcher.log.<timestamp> files per seat. The three seats
were restarted onto the INSTRUMENTED build (inflight=/oldest= now in
their logs) — the next wedge is self-diagnosing.

## 2026-08-15 update 4 — load-scaling evidence from the army ramp

Ramp to 10 total software-rendered seats (llvmpipe, ~+3.4 load each;
peak ~58, steady 38-52 on 32 cores) produced:
- **H2 confirmed in the wild:** asset fetch failures returned (Tank 13,
  Baruka 9, Greed 9) with keepalive_requests 100000 LIVE — CPU-starved
  clients idling past keepalive_timeout 30 is the surviving drop
  mechanism, exactly as predicted. Retries absorbed all of it.
- **A third, distinct failure mode:** Bellion was dropped by the WS
  bridge at peak load ("WebSocket peer closed the connection" ->
  "World reconnect exhausted", failed=0 assets) — transport-layer, not
  asset-layer; recovered on restart once load fell.
- The original four seats stayed fresh through the whole ramp, and the
  new babysitter performed its first live recoveries (Igris/Tusk/Beru
  re-pidded) without human involvement.

## 2026-08-15 update 5 — QA-seat freezes with H1 live (independent corroboration)

The quest-QA scenario seat (Kaisel) froze twice in the exact wedge
shape: status.json stops advancing, process alive ~50% CPU / 2.5GB
RSS, DEBUG PORT STOPS ACKING (new signal — the control-file poll on
the decide thread dies with it, placing the freeze at or above the
decide loop, not just the renderer), manifest fetch failures in the
tail — all with keepalive_requests 100000 confirmed live. Keepalive
exhaustion (H1) is definitively not the whole story; H2/H4 remain.
Details: docs/quest-qa-2026-08-15.md "Environment issue" section.
