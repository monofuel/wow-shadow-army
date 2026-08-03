# Fair-play audit log

**Path:** `local_data/audit/fair-play.jsonl` (gitignored under `local_data/`)

**Writer:** `tools/army_host` every frame (quest/item/spell diffs + settled
milestone actions) and System admin SOAP (`respawn_shadow_army`).

## Why

Client `*-bot.log` files were overwritten on seat restart and full of move
noise. This stream is **append-only milestones** only — enough to answer
“did they accept / farm skulls / turn in without GM quest inject?”

## Events (field `event`)

| event | Meaning |
|-------|---------|
| `session_open` | Host connected; baseline quest log / skulls / has_summon_imp |
| `quest_log_present` | Already in log at session open (not a live accept) |
| `quest_log_enter` | Quest id appeared in log (accept or mid-session join) |
| `quest_log_leave` | Left log; `likely_turn_in` if also newly rewarded |
| `quest_objectives_complete` | Server `completed_quest_ids` gained id |
| `quest_rewarded` | In `rewarded_quest_ids` |
| `objective_item` | Tracked item count change (6281 = skulls for 1470) |
| `spell_learned` | New known spell (688 = Summon Imp) |
| `action_select` | Policy selected accept/turn_in/loot/cast/… |
| `action_settled` | Upstream settled milestone kind (success + message) |
| `admin` | SOAP/setup (`source=admin_setup`); not policy |

Disable: `army_host --no-audit`. Override path: `--audit-path=…`.

## Grep examples

```sh
# Full 1470 chain for one seat
rg '1470|rattlecage|summon_imp|"spell_id": 688' local_data/audit/fair-play.jsonl

# Admin tele/repair only
rg '"event":"admin"' local_data/audit/fair-play.jsonl
```

## Client log rotation

`make rotate-client-logs` (also run by `make party-army`) renames non-empty
`local_data/*-bot.log` to `*.log.YYYYMMDDTHHMMSSZ` before new nohup overwrites.
