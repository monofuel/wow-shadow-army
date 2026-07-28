# Breadcrumbs — server-side logging on the local realm

How we harvest ground truth from the realm itself instead of the client.
Applied 2026-07-25 to the local Stack A all-in-one realm
(`coworld-vanilla-wow` @ pin, `infra/compose.vmangos.yml --profile coworld`,
service `coworld-game`).

(The earlier `breadcrumbs/` Python DB poller this approach superseded was
deleted 2026-07-27 — the save-interval staleness below is why it lost.)

Everything here goes through the operator's config-override mechanism
(`vmangos.mangosd_config_overrides` / `realmd_config_overrides` in
`local_data/coworld-config/config.json`). The upstream repo is read-only —
no VMaNGOS conf template or source was edited.

Source facts below were read from `github.com/vmangos/core` at the pinned
`VMANGOS_REF=d0aff0cedc18d140b72cac95ba0284218cd4175c` (the same ref
`infra/docker/vmangos/Dockerfile.native` builds).

## Where the files land

`LogsDir = "/coworld-run/logs"` → host path
`../coworld-vanilla-wow/local_data/coworld-run/logs/`.

`/coworld-run` is the one writable bind mount `coworld-game` has
(`${COWORLD_RUN_DIR}:/coworld-run` in the compose file), so logs are
host-readable live and survive container replacement. Before this change
`LogsDir` was `""` and mangosd's cwd is `/opt/vmangos` — every log was
trapped in the container's overlay layer and died with the container.

The operator chowns `/coworld-run` back to the invoking user on every
`up`/`down` (`restore_output_ownership`), so the files read as
`monofuel:users` on the host with no sudo.

## The override set (applied, verified in the live conf)

`vmangos.mangosd_config_overrides`:

| Key | Value | Why |
| --- | --- | --- |
| `LogsDir` | `/coworld-run/logs` | host-readable mounted volume |
| `LogLevel.File` | `4` | **the load-bearing one** — see below |
| `LogLevel.Console` | `2` | deliberately NOT raised; see "console" |
| `LogLevel.DB` | `4` | lets `logs_player` take DETAIL-level rows |
| `LogFilter_Combat` | `0` | unfilter attack/roll-outcome lines |
| `LogFilter_SpellCast` | `0` | unfilter cast/aura/proc lines |
| `LogFilter_Damage` | `0` | unfilter direct/area damage trace |
| `LogFilter_PlayerMoves` | `0` | unfilter player grid/cell transitions |
| `LogFilter_PeriodicAffects` | `0` | unfilter DoT/HoT ticks |
| `LogFile.Basic` | `Server.log` | where combat/spell/move lines actually go |
| `LogFile.Chat` | `Chat.log` | player chat |
| `LogFile.Char` | `Char.log` | login/logout/create/delete |
| `LogFile.Movement` | `Movement.log` | anomalies only — see caveat |
| `LogFile.Timestamp` | `0` | stable filenames (no `_YYYY-MM-DD` suffix) so tailers don't chase new paths |
| `LogsDB.Chat` | `1` | chat rows into `logs.logs_player` |
| `LogsDB.Characters` | `1` | login/logout rows into `logs.logs_player` |
| `LogsDB.LevelUp` | `1` | levelup rows |
| `PlayerSave.Interval` | `20000` | 20s (was 900000 = 15 min) |
| `PlayerSave.Stats.MinLevel` | `1` | populate `character_stats` for all levels |
| `PlayerSave.Stats.SaveOnlyOnLogout` | `0` | write stats every save, not just logout |

`vmangos.realmd_config_overrides`:

| Key | Value | Why |
| --- | --- | --- |
| `LogsDir` | `/coworld-run/logs` | auth log to the host too |
| `LogFile` | `Realmd.log` | realmd uses a flat `LogFile` key, not `LogFile.Basic` |
| `LogFileLevel` | `2` | was `0` (errors only) |

## Why `LogLevel.File = 4` is the whole trick

Combat and spellcast do **not** get their own log files. They route through
`DEBUG_FILTER_LOG` (`src/shared/Log.h`), which expands to:

```c
if (sLog.HasLogLevelOrHigher(LOG_LVL_DEBUG) && !sLog.HasLogFilter(F))
    sLog.Out(LOG_BASIC, LOG_LVL_DEBUG, __VA_ARGS__);
```

Two independent gates, and `LOG_BASIC` as the sink:

1. **The filter** — `LogFilter_Combat = 0` etc. Already 0 in the shipped conf.
2. **The level** — `LOG_LVL_DEBUG = 4` (`enum LogLevel`), and `OutFile`
   drops anything where `m_fileLevel < logLevel`. At the previous
   `LogLevel.File = 2` every combat/spellcast/move line was discarded no
   matter what the filters said. **Unfiltered ≠ enabled.**
3. **The destination** — `LOG_BASIC`, i.e. `LogFile.Basic` = `Server.log`.
   Not `Combat.log` (no such thing).

105 `DEBUG_FILTER_LOG` call sites exist at this ref; 42 are combat/damage/
spellcast. Confirmed emitters:

- `src/game/Objects/Unit.cpp:2206` — `AttackerStateUpdate: (Player) %u attacked %u ... for %u dmg, absorbed %u, blocked %u, resisted %u`
- `src/game/Objects/Unit.cpp:2268+` — `RollMeleeOutcomeAgainst: MISS / CRIT / DODGE`
- `src/game/Spells/SpellEffects.cpp:1644` — `Spell: Aura is: %u [Spell%u:DiminishingGroup%u]`
- `src/game/Maps/Map.cpp:1393` — `Player %s relocation grid[..]cell[..]->grid[..]cell[..]`

Chat is different and was *already* at a passing level:
`World::LogChat` (`src/game/World.cpp:3135`) emits at `LOG_LVL_MINIMAL` (1),
so `Chat.log` worked before this change — it just wrote to an unreachable
path.

## Console stays at 2 on purpose

`coworld-game` is the one service in `compose.vmangos.yml` with **no**
`logging: *bounded-logging` anchor — its docker json log is unrotated. The
`db`, `mangosd`, `realmd`, and `persistent-game` services all cap at
10m × 3. Raising `LogLevel.Console` to 4 would firehose an unbounded file
on a disk already at 88%. File-level 4 gives us the same lines in a
volume we control. (Player logs — chat/char — never hit the console at
all: `// Player logs should never go to the console`, `Player.cpp:22748`.)

## The save-interval fix

`characters.characters` position/XP rows only update when the player object
saves. `setConfigPos(CONFIG_UINT32_INTERVAL_SAVE, "PlayerSave.Interval", 15 * MINUTE * IN_MILLISECONDS)`
(`src/game/World.cpp:583`) — default 900000 ms. DB-polling breadcrumbs were
therefore up to 15 minutes stale.

Now 20000 ms (20s). `setConfigPos` only rejects *negative* values — there is
no lower clamp, so 20s is honored as-is. Cost is one player-save write burst
per 20s per online character; trivial at our roster size (8 characters).

`PlayerSave.Stats.MinLevel = 1` + `SaveOnlyOnLogout = 0` additionally
populate `characters.character_stats` (max_health, max_power1..5, attack
power, resistances) on every save — `Player::_SaveStats`, `Player.cpp:17047`.
That table was empty before; it needs `MinLevel >= 1` because the guard is
`if (!MinLevel || GetLevel() < MinLevel) return;`.

## Two harvest surfaces

**Files** — `local_data/coworld-run/logs/`, `fflush`ed per line
(`Log::OutFile`, `Log.cpp:447`), so tailing is safe and lossless.

**Database** — `logs.logs_player` is the nicer target: already structured,
with position columns. Schema (`INSERT` at `Player.cpp:22646`):

```
id, type, subtype, account, ip, guid, name, map, pos_x, pos_y, pos_z, text
```

Gated by `IsPlayerLoggingEnabledToDB` (`Player.cpp:22614`) — needs both
`LogsDB.<kind> = 1` and `LogLevel.DB >=` the emit level, which is why
`LogLevel.DB = 4` is in the set (logout/login emit at DETAIL = 3).
`LogsDatabase` is initialized at startup via `StartDB("Logs", ...)`
(`src/mangosd/Master.cpp:485`) and `LogsDatabase.Info` already points at the
`logs` schema, so no DB plumbing was needed.

Other tables in `logs`: `logs_trade`, `logs_transactions`,
`logs_battleground`, `instance_creature_kills`, `instance_wipes`,
`smartlog_creature`.

Note combat/spellcast have **no** DB path — they are file-only
(`Server.log`). `logs_player` covers chat, char ops, levelup, loot, trades,
BG, GM.

## Exact line shapes to parse

Player-log lines get a header from `PlayerLogHeaderToFile`
(`Player.cpp:22580`): `[<type>] (<subtype>) (acc %u, ip %s, guid %u, name %s, map %u, pos %g %g %g) `
prefixed by a timestamp. Real captured lines:

```
2026-07-24 17:25:27 [Chat] (acc 100003, ip 172.20.0.1, guid 1000002, name Botwarrior, map 1, pos -618.518 -4251.67 38.718) [Say] Botwarrior:1000002 : external factorized policy action
2026-07-25 11:26:52 [Character] (Login) (acc 100008, ip 172.20.0.1, guid 1000007, name Murist, map 0, pos 1720.83 1676.83 131.105)
```

Note chat lines carry **position for free** — a `/p` message is also a
positional breadcrumb. Chat type tags come from the `LogChat` call sites
(`src/game/Handlers/ChatHandler.cpp`): `Say`, `Yell`, `Emote`, `Whisp`,
`Group`, `Guild`, `Officer`, `Raid`, `BG`, `Chan`. Group/raid/guild lines
carry the group or guild id as `[Group:<id>]`; channel lines carry the
channel name.

Combat/spell lines in `Server.log` are plain `Log::Out` — timestamp plus
message, **no** player header. Correlating them to a character means
matching the GUIDs embedded in the message text.

## Caveat: `Movement.log` is not a movement trace

`LOG_MOVEMENT` has 31 of ~35 call sites at `LOG_LVL_ERROR`, and the rest are
undermap/teleport anomalies (`MovementHandler.cpp:1128` `[UNDERMAP] Player ...
Teleporting to safe position`). It is a **movement-anomaly** log, useful for
detecting a stuck or fallen-through-the-world shadow — not a position feed.

For actual movement breadcrumbs use, in order of preference:
1. `characters.characters` position columns (now 20s fresh).
2. `logs_player` rows — every chat/login line is position-stamped.
3. `LogFilter_PlayerMoves` grid-transition lines in `Server.log` (coarse:
   grid/cell granularity, not coordinates).

## Verified vs pending

**Verified live (2026-07-25):**
- Both override blocks present in `/vmangos-etc/mangosd.conf` and
  `/vmangos-etc/realmd.conf` inside the running container.
- All 17 log files present and host-readable at
  `local_data/coworld-run/logs/`, owned `monofuel:users`.
- `/opt/vmangos/*.log` is now **empty** — nothing is being written to the
  container-only path any more.
- `Server.log` grows under load: 114200 → 116640 bytes across a probe
  window, carrying level-4 SQL-text debug lines.
- `Char.log` captured a real login with position:
  `[Character] (Login) ... name Murist, map 0, pos 1720.83 1676.83 131.105`.
- `logs.logs_player` took its first row (id 1) — the DB breadcrumb path
  works end to end, with map/x/y/z populated.
- `config.json` validates against upstream `ScenarioConfig` (operator
  `doctor` → `coworld:config ... is ready`).
- Realm healthy after a clean operator `down` → `up`: `/healthz` HTTP 200,
  :3724 and :8085 reachable, and `tools/backend_doctor.py --stack a`
  reports `AUTH_LOGON_CHALLENGE` and `SMSG_AUTH_CHALLENGE` both parseable,
  8 accounts / 8 characters intact. No `docker kill` was used.

**Pending a play session (needs a real client in the world):**
- Actual `[Chat] ... [Say]/[Group]` lines under the new `LogsDir` — the
  mechanism is proven by the pre-existing `Chat.log` from 2026-07-24, but
  no chat has occurred since the restart.
- Combat/spellcast lines in `Server.log` — the gate math is confirmed from
  source, but no melee swing or cast has happened on the restarted realm.
  Expect `AttackerStateUpdate:` and `RollMeleeOutcomeAgainst:` lines.
- `character_stats` rows — table is still empty (0 rows); populates on the
  first save tick with a character online.
- Volume of level-4 output under real combat is unmeasured. If `Server.log`
  grows uncomfortably, the first thing to re-filter is
  `LogFilter_PeriodicAffects` (DoT/HoT ticks) and `LogFilter_SQLText = 1`
  (SQL text is the bulk of current idle volume), keeping Combat and
  SpellCast at 0.

## Reproducing / changing the set

`make server-logging` (below) writes the config and restarts the realm.

The overrides live in `../coworld-vanilla-wow/local_data/coworld-config/config.json`
under `vmangos`. Editing that file and running `make stop-server && make
start-server` is equivalent — `configure_vmangos.py` re-applies the whole
block into the conf on every container start (`entrypoint.nim:47`), so the
config is the source of truth, not the conf file.

Precedence, per `configure_vmangos.py:198` (`merge_values`): container
defaults < `config.json` `vmangos.*_config_overrides` <
`VMANGOS_MANGOSD_CONFIG_OVERRIDES` env. Note `up` without `--force-config`
leaves an existing valid `config.json` alone, which is why the make target
passes `--force-config`.

One key is reserved: `Coworld.SimulationTimeScale` is rejected in overrides
(`game/config.py:583`) — it belongs to `vmangos.simulation_time_scale`.
