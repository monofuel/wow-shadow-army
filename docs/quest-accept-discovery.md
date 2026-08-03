# Quest accept discovery (external policy)

## Wire facts

- Factorized `quest` is a **1-based bindings.quests index**, not `quest_id`.
- `policy.quest == 0` → executor `questId = 0` → `acceptQuestAtQuestgiver` greets
  the target and accepts the **first live offer** from the dialog list.
- Turn-in cannot use factor 0 (questId 0 fails); use concrete completed ids.

## Live failure mode (fixed in army tools)

- Nearest interactable is often a vendor with `questgiver` service and **empty**
  gossip quest rows → accept returns `opened no quest dialog`.
- Sticky synthetic offers + nearest-vendor interact loops forever.

## Fix (army layer)

- Project interactables with `services` / `is_questgiver`; rank pure questgivers
  ahead of vendor/trainer/innkeeper.
- `lua/tools/quest_interact.lua`: approach pure qgs; when dialog admits
  accept, use discovery accept (factor 0) or concrete offer factors.
- Brill: Apothecary Johaan (entry **1518**) offers **367 A New Plague** at
  level ≥ 6 with no prev quest — verified live for Tusk + Beru.

## Tool

- Host: `tools/army_host --tool=quest_interact`
- Unit tests: `lua/tests/test_quest_interact.lua`

## Escort leader projection (related)

Party binding locations often have **z=0** while xy is correct. Do **not**
replace xy with `last_visible` when z is missing — only fill z. Overwriting xy
collapsed rejoin onto the follower (false near-band).
