# Postmortem: Shadowfel pet-as-target thrash (2026-07-27)

## Symptom

Slot 2 (Shadowfel) burned nearly every action as `attack` / `stop_attack` on
the **imp** while OOC full HP. Last-100 action window: ~82 stop_attack + 18
attack, zero casts, zero useful moves. Other seats still cast/move fine.

## Ground truth

| Source | Observation |
|--------|-------------|
| `state.json` / env `observation` | `selected_target_guid == active_pet_guid` |
| `action-results.jsonl` | attack/stop_attack target = pet guid |
| `leveling_lifecycle` | `local-level-window` / stage farm, no progress |
| Party | 5/5 in group, leader Murist, clustered Tirisfal |

## Root cause (stacked)

1. **In-process v2 policy** (no external Lua SELECT) can stick combat on the
   active pet guid for warlocks.
2. Once stuck, escort/grind never reselects a hostile — thrash forever.
3. **`control_directive: cancel` is not a safe unstick** on this pin: sending
   cancel closed the control socket and the seat process exited
   (`runtime exited`, `:41116` gone). Do not use cancel for thrash recovery.

## Recovery that worked

1. Restart seat only: `make warlock-bot-fork` (Shadowfel / slot 2).
2. Reinstall escort goals: `make escort-army`.
3. Confirm `selected_target_guid != active_pet_guid` (or zero target).

## Host mitigation shipped

`tools/army_host.nim` thrash watchdogs (goal reinstall only — never cancel):

1. **AA on own pet:** `auto_attack_guid == active_pet_guid` for ~7s.
   Do **not** use `selected_target_guid == pet` alone — warlocks sit OOC
   with pet selected after every pull (false unsticks on Igris).
2. **Stuck combat follow-only:** `in_combat` + `no_progress_seconds >= 15`
   + recommended actions are only move/follow/face/stop_attack. Catches
   sticky far-target combat where policy only move→leader (Shadowfel live:
   AA on mob 60yd away, only follow).
3. **Zero-displacement move:** recommended move dest ≥25yd away but body
   moves &lt;0.6yd for ~25 frames. Live: all 4 seats froze near Brill
   (~2230,450) with move→Murist (2062,1976) “success” and zero xy change
   (wrong dest z / navmesh stall). Goal reinstall unsticks; seat restart
   also recovered the cast to Murist.

Cooldown 60s between unsticks per seat.

## Follow-ups

- [ ] Upstream / fork: never recommend attack on own pet guid; clear sticky
  combat when target is out of cast range and only escort-follow remains.
- [ ] Optional: army_host seat-health probe that restarts a dead `:4111x`
  without human ops (agent-owned).
