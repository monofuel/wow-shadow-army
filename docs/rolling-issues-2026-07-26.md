# Rolling issues — 2026-07-26

Live session notes for the human-in-the-loop cast: **Murist** (you) +
**Shadowfel** (slot 2) + **Igris** (slot 3). Not the Bot* foundation seats.

## Status board

| Item | State | Prio |
|------|--------|------|
| **P0 Crypt follow** | Multi-floor: dest move. Same-floor: stock follow (dest freezes old point → chase lag) | **0** |
| Party formation | Working; Murist+Shadowfel+Igris | done |
| Caster-first DPS (no random rats / no dagger-with-mana) | In Lua; free-fire paths removed | 1 |
| Client stutter | Ranked: (1) bot /say replan spam (2) navmesh-helper CPU spikes (3) wine+GL baseline ~70% (4) SA residual OnUpdate minor when quests off | 2 |
| Auto-loot on escort | Not implemented | later |
| Advisor panel / `/sa help` | r21; TOC load order fix | done |
| Advisor party + corpse blips | r21 minimap/worldmap (cyan party / white ghost / purple corpse); `/sa crew` | done |
| Corpse-run policy | hop legs + lateral detour in escort/shadow; live ghosts still nav-stuck NE of GY | **0** |
| Defensive combat | escort nearest-attackable when in combat without focus | done |

## Cast (5-man)

| Role | Name | Seat |
|------|------|------|
| Human (leader) | Murist | classic client `make play-classic` |
| DPS | Shadowfel | slot 2 / `:41116` — `make warlock-bot` / `warlock-bot-fork` |
| DPS | Igris | slot 3 / `:41117` — `make igris-bot` |
| Tank | Tusk | slot 4 / `:41118` — `make tusk-bot` |
| Healer | Beru | slot 5 / `:41119` — `make beru-bot` |

Bring-up: `make party-army` (accounts + 4 headless seats), wait for
`:41116`–`:41119`, then `make escort-army`. Invite order from Murist:
Shadowfel, Igris, Tusk, Beru.

Foundation seats (Botwarrior/Botpriest) stay out of this cast.

---

## Postmortem: Shadowfel party join (morning)

### Symptom

- Igris accepted Murist's invite.
- Shadowfel did not. Re-invite from the classic client: *"already in a group."*
- Multiple invites had been sent.

### Ground truth (while broken)

| Source | Observation |
|--------|-------------|
| `characters.group_member` | Group 2 = Murist + Igris only. **Shadowfel ungrouped.** |
| Slot-2 `state.json` | `in_group=false`, **`invite_pending=true`**, `invite_from=Murist` |
| Control `EnvironmentFrame` | Often **stale** (`frame_id`/`tick` frozen); `invite_pending=false`; `accept_party` **not** masked |
| `party_butler` log (slot 2) | Goal install only — **no accept settlement** |

So the client error was **misleading**: pending/stuck join state, not membership.

### Root causes (stacked)

1. **Python SDK frame decode failed** against the fork/live Nim wire:
   - `navigation.exclude_flags` must be `["steep"]` for the fixed profile; wire often sends `[]`.
   - `leveling_lifecycle` gained extra keys (`quest_discovery_*`, …) the strict model rejects.
   - `brain/frame_coerce.py` only soft-fixed ActionSettled + empty enums — not these.
2. **Accept loop silent-fail**: butler needs `status(include_environment_frame=True)`; validation errors → no `accept_party` select while invites sat pending in runtime state.
3. **Control frame lag**: decision frames did not always mirror `state.json` party invite fields; selecting `accept_party` on a stale frame was rejected as mask-invalid.

### Resolution path used

- Confirmed ungrouped in DB while invites pending.
- Unstuck control by driving a **valid recommended** action (not bare noop without factors).
- Party membership later showed **Shadowfel + Murist + Igris** under leader Murist (DB + live roster).

### Follow-ups (accept path)

- [x] Document here.
- [ ] Make `frame_coerce` strip/fix lifecycle extras + navigation filter (in progress this session).
- [ ] Accept vitals: pending allowlisted invite → `accept_party` settle **or loud error** within N seconds.
- [ ] Prefer Lua `accept_invite` tool later (no more silent Python butler).

---

## Next task: follow + combat assist

### Desired behavior

Bots in party with Murist:

1. **Stand behind / stay near** (formation follow — not pull ahead).
2. **Attack what Murist is attacking** (mirror target + swing/cast).

Curriculum map (`coworld-playbook/games/solo-leveling.md`): Phase 1 Follow + Phase 2 Assist.

### Difficulty assessment

| Slice | Hardness | Notes |
|-------|----------|--------|
| Stay near leader via upstream `follow` | **Easy–medium** | `lua/tools/follow_leader.lua` already exists; needs **party + visible leader binding + non-stale frames**. |
| Mirror Murist's target | **Medium** | Upstream `assist` = stock ASSISTTARGET: select leader's target. Masked for alive party entities. Fails cleanly if leader has no target. |
| Actually deal damage | **Medium** | `assist` only **selects**; need a follow-up **`attack`** on the focus/hostile entity once selected (`auto_attack_guid` / `combat_focus_guid` / attack mask). |
| Stand *behind* (facing/offset) | **Harder / later** | Stock follow is "follow unit," not a rear offset. Good enough for questing; true rear formation is polish. |
| Robust under frame decode / dual brains | **Hard** | Same class of bugs as the party accept postmortem. Vitals > clever policy. |
| Tournament RFC roles | **Out of scope for this slice** | L19 profiles, dungeon goals, role assignment — different seat config. |

**Overall for local Murist play this week: medium** if frames stay readable; **blocked** if coerce/socket drift returns.

### In-repo building block (this session)

- Lua tool **`escort_leader`**: in formation → `assist_unit` on leader; if a hostile focus/auto-attack is known → `attack_unit`; out of range → `move_to_unit` (follow).
- Projection + intent mapping for `assist` / `attack`.
- `make escort` convenience for Shadowfel/Igris with `--leader-name Murist`.

### Live smoke (when seats up)

```sh
# Preferred: both seats standing (accept + escort). Do not also run party_butler.
make escort-army

# One seat only:
make escort SLOT=2 EXTRA='--max-seconds 120'
```

Human: walk, pull a mob, watch bots close distance and mirror target.

Graduation bar (session): full short quest walk with no babysitting; bots contribute damage on your pulls without pulling extra packs.

---

## Open rolling issues

1. **Frame coerce completeness** — navigation + leveling_lifecycle drift (fork vs SDK).
2. **Accept vitals** — both custom seats, loud failure.
3. **Escort live prove** — Shadowfel + Igris on Murist pulls.
4. **No leave_party** upstream — bots can join, cannot leave (doc'd in party-formation).
5. **Dual party_butler on one slot** — avoid; one brain per socket.
6. **Python brain is legacy harness** — do not grow grind-style policies; tools stay in `lua/`.

## How to use this file

Append dated bullets as the day goes. Promote durable lessons to `kb/postmortems/` or playbook when the session ends. Do not treat this as the permanent knowledgebase.
