# Escort leader combat join (v2)

## Problem
OOC, follower `attack` kind is often **false** → `combat.attackable` empty →
`join_leader_attack` never fires. Party frames also lag: Murist xy frozen and
no `in_combat` on party members while the human is mid-pull.

## Fix (army layer)
1. **Lua `escort_leader`**: OOC `join_leader_assist` when leader is fighting
   (`leader.in_combat` or `health_pct < 99.5`) and assistable. Idle full-HP
   leader still holds (no assist spam).
2. **Nim `army_host`**: project leader health; **`--leader-slot=0`** overlays
   live observation from Murist's control socket onto `leader_unit` (xy, hp,
   in_combat / auto_attack_guid). Control-plane only — not in-game collusion.

## Live proof shape
- Rejoin: `rejoin_far_*` → `SELECT move`
- Join: `join_leader_assist` → `SELECT assist` while `leader.in_combat=true`
- Optional: `join_leader_band:*` casts when attack mask + near-leader hostiles exist

## Ops
```
./tools/army_host --slot=2 --tool=escort_leader --leader=Murist --leader-slot=0
```
