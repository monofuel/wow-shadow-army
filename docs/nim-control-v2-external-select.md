# nim_control.v2 external action selection — stock gap, fork surface

> **STALE — written against upstream pin `ec5bd2f9d`.** The pin moved to
> `93730fb97` on 2026-08-03 after a 1661-commit upstream restructure
> (`client/` + `player/` → `environment/` + `bots/`), and the
> `lua-external-policy` fork branch this describes was dropped. Nothing below
> is verified against the new tree. See `docs/work-2026-08-03.md`.

Stock upstream v2 (pin `ec5bd2f9d`) has **no external action selection**:
the wire accepts goal request (1), control directive (2 — hold/resume/
cancel), status request (4), and emits control status (5), environment
frame (6), control error (8). Per-frame policy runs in-process
(`player/behavior/`); `executeBotAction` is only reachable from the
planner's own decisions. The v1 `ActionSelectionRequest` is gone — which
is why the Python `brain/` was dead code (deleted 2026-07-27).

## Fork surface (branch `lua-external-policy`, 2026-07-27)

Our fork re-exposes a select surface as one thin, upstreamable commit
(`docs/coworld-fork.md` rules):

- **Frame 7 `execute_action`** → one typed BotAction per request through
  the existing `executeAndRecordAction` path; **frame 9 `action_result`**
  carries success/message/reason_code/movement_settlement back.
- Guarded: rejected while the in-process planner can step. External mode =
  goal idle (or held) so exactly one policy owns the seat.
- Status-served env frames refresh the observation from the live mirror
  when the planner is held/idle (otherwise external hosts would read a
  frozen snapshot).
- Two concurrency fixes the external call path needed (inline planner
  dispatch never hit them): passive physics yields while an action is in
  progress, and the world loop parks while an external action owns the
  session. Without them a single 4yd external move pegged the event loop
  at 100% CPU (passive physics fought the walk packet-for-packet, then
  no-op loop iterations starved the action's continuations).

Requires the seat to run the fork build (`local_data/player_bin.lua-external`
via `tools/relaunch_seat.sh <slot> <acct> <char> <class> <binary>`).

## Consumer

`tools/army_host --external --tool=<lua tool>`: each tick — env frame →
`projectV2` (observation → plain Lua table; unit ids are dense 1-based,
host maps id→guid on the way out since raw guids overflow Lua doubles) →
`lua/tools/<tool>.decide` → `mapIntentV2` → execute_action. Proven live
2026-07-27: Shadowfel grinding under `grind_nearest` (loot + Shadow Bolt
casts), `make grind SLOT=2`.

The v2 frame has **no action_space/action_mask/bindings** — tools own
their choices (e.g. spell-id priority tables per class in
`grind_nearest`), reading `spells{known,cooldowns,mana_pct}` from the
projection.

## Still open

- Escort rail: `escort_leader` patched for the v2 projection (tests
  green); live external smoke pending — `make escort-army` still runs the
  in-process escort policy meanwhile.
- Other seats run the pre-fork binary; roll them onto the fork build
  before pointing `--external` at them (unknown frame kind otherwise).
- Salvage list from the deleted Python brain, when porting deeper policy:
  accept-invite allowlist fail-closed + loud-fail watchdog, frozen-frame
  watchdog, corridor helpers, grind leash/per-guid blacklists/rest gating
  (git history of `brain/grind_policy.py` has the tuned constants).
- Upstream ask: submit the execute_action commit (and the two concurrency
  fixes) so the tournament build gains the surface officially.
