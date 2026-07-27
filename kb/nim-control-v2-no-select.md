# nim_control.v2 has no external action selection

Verified 2026-07-27 against upstream pin `ec5bd2f9d`
(`player/reference_player/runtime/nim_control_server.nim`).

The v2 wire protocol accepts exactly: goal request (1), control directive
(2 — `hold` / `resume` / `cancel` only), status request (4), and emits
control status (5), environment frame (6), control error (8). The v1
`ActionSelectionRequest` / select frame is gone. `executeBotAction` exists
in-process but is only reachable from the upstream policy's own decisions.

## Consequences

- Per-frame policy runs **in-process upstream** (`player/behavior/` —
  leveling, escort, rotations). External hosts configure it via goals
  (leader / party / roster) and observe.
- Our `lua/tools/*` decide layer has **no runtime** on stock v2. It is a
  prepared policy surface, kept tested, waiting for a select surface.
- `tools/army_host.nim` is honest about its v2 job: goal install, thrash
  watchdogs, unstick via goal-id bump, fair-play audit. Its
  `projectEscort` / `runDecide` / `mapIntent` procs are the dormant v1-era
  decide path.
- The old Python `brain/` targeted v1 selects and could not run at all;
  deleted 2026-07-27 (see `docs/v2.md`).
- Behavior fixes land as thin commits on the fork's `shadow-army-fixes`
  branch (`docs/coworld-fork.md`) — in-process Nim policy, upstreamable.

## If a select surface returns

Wire `army_host` main() to project → `lua/tools/<tool>.decide` →
`mapIntent` (code already present) and re-check these salvaged ideas from
the deleted Python brain:

- `should_accept_invite` allowlist, fail-closed on empty list (was
  `brain/accept_invite.py`; loud-fail when an allowlisted invite stays
  pending but masks say no — the stuck-invite postmortem fix).
- Frozen-frame watchdog: same `frame_id`+`observed_tick` across N polls →
  reinstall goal (distinct signal from zero-displacement).
- Corridor helpers: `subsample_corridor` / `next_corridor_index` /
  `corridor_progress` (~40 lines of pure Lua if corridor walking returns).
- Grind-policy state ideas: leash to anchor, per-guid approach/hold
  blacklists, rest gating on hp/mana. See git history of
  `brain/grind_policy.py` for the tuned constants.
