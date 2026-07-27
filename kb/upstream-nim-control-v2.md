# Upstream pin `ec5bd2f9d` — nim_control.v2 break for external army_host

**Date:** 2026-07-27  
**Pin:** `coworld-vanilla-wow ec5bd2f9dffd6685b94e0a6b10702906989c0b01`

## What changed upstream

Docs (`docs/bot-environment-contract.md`):

- Protocol: `vanilla_wow.nim_control.v2` (was `.v1`)
- Policy is **in-process only**: `actions = step(observation)`
- **No** offered-frame phase, external selection callback, factor binding,
  or action mask
- Python/control socket may install goals and **observe** frames; it does
  **not** choose/resubmit actions

`player/contract/environment_frame.nim` is now a thin MessagePack writer
(~19 lines). The old `buildPolicyFrame` / `addGenericPolicyMasks` path is gone.

## Impact on wow-shadow-army

| Component | Status on v2 |
|-----------|----------------|
| `tools/army_host` external SELECT loop | **Broken** until redesigned |
| Lua tools as factorized intent → select | **Broken** (no mask/select wire) |
| Headless seats + autonomous upstream planner | May still run for stock bots |
| Fork `bakPromoteParty` execute path | Still present on `party-invite-observation`; no external mask to expose it |

## Carried fork after rebase

- `main` = stock `ec5bd2f9d` (Gitea pushed)
- `shadow-army-fixes`: faction-standing cowpatch + dual parse (rebased)
- `party-invite-observation`: social-party + promote execute (rebased);
  **quest/death external mask hunks dropped** (no target API on v2)

## Do not

- Rebuild/restart all seats onto v2 and expect escort Lua to work without a
  new control design
- Paper over with GM quest complete / tele loops

## Working path (shipped 2026-07-27)

1. **Fork** `party-invite-observation`: leveling goals keep `leader_name` /
   `party_members`; `levelingRecommendation` prioritizes escort
   (accept/promote/follow/assist) so unsupported undead packs still move.
2. **`tools/army_host`**: nim_control.**v2** goal installer only (no action
   select). Re-asserts escort leveling goal; fair-play audit still runs.
3. Headless seats: built binary `local_data/player_bin` from fork; need
   `VANILLA_WOW_EXTRACTED_DATA_DIR` (DBC) or race parse fails.
4. Live check: seats listening, phase=`running`, action-results advancing
   (`move` / `cast`).

### Remaining gaps

- Env-frame JSON shape changed — army_host heartbeat may show empty name/pos
  until observation paths are remapped (does not block motion).
- Quest Lua tools are not the live control path anymore; grind/quest is
  in-process upstream policy + escort overlay.
