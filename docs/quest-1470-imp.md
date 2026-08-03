# Quest 1470 — Piercing the Veil (Summon Imp)

- **Who:** undead warlock (Shadowfel, Igris). Class bit warlock, race undead/orc.
- **Giver/ender:** Venya Marthand (creature 5667).
- **Requires:** 3× Rattlecage Skull (item 6281) from Rattlecage Skeleton (1890).
- **Reward:** teaches Summon Imp (`RewSpellCast 7763`).
- **Lua tool:** `warlock_imp_quest` (`lua/tools/warlock_imp_quest.lua`).

## Upstream gap (do not paper over in Python)

`accept_quest` / `turn_in_quest` are often **not** on the generic external policy mask.
When the projection has no `quest.offers` / `quest.turn_ins`, decide returns
`hold:quest_masks_unavailable` or `imp_quest_idle`. Fix belongs in the
**coworld-vanilla-wow-fork** (expose masks / planner recommendation), not a
local GM or Python FSM.

## Host note

Intent→wire mapping lives in `tools/army_host.nim` (`mapIntent`:
`accept_quest`, `turn_in_quest`, `interact`) — dormant under v2's
no-select protocol (`kb/nim-control-v2-external-select.md`). Policy logic is
Lua only.
