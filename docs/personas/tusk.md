# Tusk — undead warrior (tank)

Shadow-soldier persona for the 5-man cast. **Thesis (pinned):** a simple
threat-first tank that holds the leader's target and body-blocks pulls beats
a fancy rotation while the party is still learning formation.

| | |
|---|---|
| Account | `shadow3` / `shadow3` |
| Character | `Tusk` (wire-created on first login) |
| Race / class | undead / warrior |
| Role | tank |
| Control slot | **4** → `127.0.0.1:41118` |
| Runtime dir | `local_data/nim-runtime-slot4/` |
| Bring-up | `make tusk-account` then `make tusk-bot` (fork client) |

## Day-0 behavior

Uses the same `escort_leader` brain as the locks: accept Murist invites,
rejoin formation, assist when in combat. Warrior-specific threat (Sunder,
Heroic Strike priority, taunt) is **not** implemented yet — nearest-hostile
attack + follow is the acceptance bar for "in the party and standing up."

## Not this persona

- Botwarrior (slot 0, orc foundation seat) — movement proof only, not the cast.
- Out-of-band collusion with other seats (fair play).
