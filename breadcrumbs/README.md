# Breadcrumbs — DB poller for human play sessions

While a human plays on the local VMaNGOS realm, this poller records a **JSONL
event stream** of character state changes (breadcrumbs). Use it later for
teaching bots and offline analysis.

## What it captures

Polls the `characters` MariaDB (via `docker exec … mariadb`, same path as
The System) about every **5 seconds** and emits events **only when values
change**:

| Kind | Source |
|---|---|
| `session_start` | First snapshot of a run |
| `position` | `map` / `position_x/y/z` moved ≥ 0.5 yards |
| `level_up` | `characters.level` |
| `xp_gain` | `characters.xp` (skipped on the tick that levels) |
| `quest_accepted` | New `character_queststatus` row |
| `quest_objective` | `mob_count*` / `item_count*` change |
| `quest_completed` | `status` → `COMPLETE` (1) |
| `quest_rewarded` | `rewarded` → 1 |
| `item_gained` / `item_lost` | Inventory aggregate by `item_id` (+ `item_instance.count`) |
| `skill_up` | `character_skills.value` increase |
| `spell_learned` | New non-disabled `character_spell` |
| `death` | `death_expire_time` advance, or `health` 0 after non-zero |

**Skipped on purpose:** HP / mana / power ticks (too noisy between saves).

### Quest `status` enum (VMaNGOS `QuestDef.h`)

| Value | Name |
|---|---|
| 0 | `NONE` |
| 1 | `COMPLETE` |
| 2 | `UNAVAILABLE` |
| 3 | `INCOMPLETE` |
| 4 | `AVAILABLE` (unused in practice) |
| 5 | `FAILED` |

Turn-in reward is the separate `rewarded` boolean column, not a status value.

## Caveats (read this)

1. **Save-interval staleness.** Character rows update on the world server's
   DB save interval (another worker is lowering it toward ~15–30s), **not**
   every client tick. The poller runs every ~5s so you sample soon after a
   save, but you will still miss sub-save movement and may coalesce several
   real actions into one event batch.
2. **What the DB cannot see.** Per-GCD spell casts, chat, combat log detail,
   targeting, camera, UI clicks — those need **server logs** / client frames,
   not this poller.
3. **Observer only.** Read-only SELECTs. Never a policy action path
   (`AGENTS.md`: no DB pokes for bot progress).

## Run

Realm must be up (`make start-server`). MariaDB is inside the
`coworld-game` container (host port 3307).

```sh
# One character (default interval 5s)
make breadcrumbs CHARACTER=Murist

# Equivalent:
python3 breadcrumbs/poller.py --character Murist

# All characters on the realm (per-name subdirs)
python3 breadcrumbs/poller.py --all

# Custom session dir / interval / single smoke poll
python3 breadcrumbs/poller.py --character Murist \
  --session-dir sessions/my-run --interval 5 --once
```

Optional env: `SYSTEM_MYSQL_CONTAINER` (default
`coworld-vmangos-coworld-game-1`).

## Output layout

```
sessions/<UTC-date>_<time>-<CharName>/   # gitignored
  manifest.json     # character, started_at, realm
  events.jsonl      # one JSON object per line
```

Example event:

```json
{"character":"Murist","delta":150,"from_xp":100,"guid":1000007,"kind":"xp_gain","level":3,"to_xp":250,"ts":"2026-07-25T12:00:05.123Z"}
```

## Tests

Stdlib unittest, fixture dicts only — no network/docker:

```sh
python3 -m unittest discover -s breadcrumbs/tests -p 'test_*.py' -v
# or (repo unit suite):
make test
```
