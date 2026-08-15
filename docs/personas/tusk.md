# Tusk — undead warrior (tank)

Shadow-soldier persona for the 5-man cast. **Thesis (pinned):** a simple
threat-first tank that holds the leader's target and body-blocks pulls beats
a fancy rotation while the party is still learning formation.

| | |
|---|---|
| Account | `shadow3` / `shadow3` |
| Character | `Tusk` (persistent realm) |
| Race / class | undead / warrior |
| Role | tank |
| Runtime dir | `local_data/home-army/Tusk/` |
| Policy | `lua/entry/home.lua` |
| Lifecycle | `make tusk-start` / `make tusk-stop` |

## Day-0 behavior

Accepts Murist's invite, promotes him if necessary, holds a hard follow leash,
and assists his observed target. In combat it taunts enemies attacking another
party member, then prioritizes Sunder Armor, Revenge, Heroic Strike, Thunder
Clap, Demoralizing Shout, and Battle Shout from the spells it actually knows.
When Murist is unavailable it uses the solo accelerated policy. Corpse recovery
is shared with the other home seats.

## Not this persona

- Botwarrior (slot 0, orc foundation seat) — movement proof only, not the cast.
- Out-of-band collusion with other seats (fair play).
