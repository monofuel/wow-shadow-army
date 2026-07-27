# Beru — undead priest (healer)

Shadow-soldier persona for the 5-man cast. **Thesis (pinned):** a reactive
healer that keeps the tank/leader alive from the cast mask (PW:S → flash/heal
on lowest party HP) beats pre-cast overheal spam while we still lack a real
party HP projection.

| | |
|---|---|
| Account | `shadow4` / `shadow4` |
| Character | `Beru` (wire-created on first login) |
| Race / class | undead / priest |
| Role | healer |
| Control slot | **5** → `127.0.0.1:41119` |
| Runtime dir | `local_data/nim-runtime-slot5/` |
| Bring-up | `make beru-account` then `make beru-bot` (fork client) |

## Day-0 behavior

Uses `escort_leader` for invite accept + formation follow. Warlock rotation
paths no-op (no Shadow Bolt on mask) → hold / assist. Real heal policy is a
follow-up tool (`escort_healer` or cast branches in projection), not required
for "logged in and in party."

## Not this persona

- Botpriest (slot 1 foundation) — not the cast.
- Fair play: no out-of-band "heal only our bots" hacks.
