# Beru — undead priest (healer)

Shadow-soldier persona for the 5-man cast. **Thesis (pinned):** a reactive
healer that keeps the tank/leader alive from the cast mask (PW:S → flash/heal
on lowest party HP) beats pre-cast overheal spam.

| | |
|---|---|
| Account | `shadow4` / `shadow4` |
| Character | `Beru` (persistent realm) |
| Race / class | undead / priest |
| Role | healer |
| Runtime dir | `local_data/home-army/Beru/` |
| Policy | `lua/entry/home.lua` |
| Lifecycle | `make beru-start` / `make beru-stop` |

## Day-0 behavior

Accepts Murist's invite, follows him, and evaluates self plus party health
before the hard follow leash. It shields emergency targets when Weakened Soul
permits, selects an appropriate direct heal or Renew, buffs Fortitude and Inner
Fire out of combat, resurrects nearby party members, and contributes priest
damage when healing is unnecessary. Other dead seats briefly wait for a living
nearby level-10+ Beru before releasing.

## Not this persona

- Botpriest (slot 1 foundation) — not the cast.
- Fair play: no out-of-band "heal only our bots" hacks.
