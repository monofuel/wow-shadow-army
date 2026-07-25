#!/usr/bin/env python3
"""DB breadcrumb poller — record a JSONL event stream while a human plays.

Polls the local VMaNGOS characters DB on a fixed interval, diffs consecutive
snapshots, and appends change events. Unit tests exercise pure diff logic on
plain dict fixtures (no DB, no network). Live DB access shells out to
`docker exec … mariadb` (same path as system/system_server.nim).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple

# ---------------------------------------------------------------------------
# Coupling isolation: host/realm pin for the local compose stack.
# ---------------------------------------------------------------------------

DEFAULT_CONTAINER = os.environ.get(
    "SYSTEM_MYSQL_CONTAINER", "coworld-vmangos-coworld-game-1"
)
DB_USER = "mangos"
DB_PASS = "mangos"
DB_NAME = "characters"
DEFAULT_INTERVAL = 5.0
DEFAULT_REALM = "local-vmangos"
# WoW yards; ignore float jitter below this when declaring a position move.
POSITION_EPSILON = 0.5

# VMaNGOS QuestStatus (src/game/QuestDef.h). `rewarded` is a separate bool col.
QUEST_STATUS_NONE = 0
QUEST_STATUS_COMPLETE = 1
QUEST_STATUS_UNAVAILABLE = 2
QUEST_STATUS_INCOMPLETE = 3
QUEST_STATUS_AVAILABLE = 4  # unused in practice
QUEST_STATUS_FAILED = 5

QUEST_STATUS_NAMES = {
    QUEST_STATUS_NONE: "none",
    QUEST_STATUS_COMPLETE: "complete",
    QUEST_STATUS_UNAVAILABLE: "unavailable",
    QUEST_STATUS_INCOMPLETE: "incomplete",
    QUEST_STATUS_AVAILABLE: "available",
    QUEST_STATUS_FAILED: "failed",
}

_SAFE_NAME = re.compile(r"^[A-Za-z0-9_]+$")


# ---------------------------------------------------------------------------
# TSV helpers (docker exec mariadb -N -B)
# ---------------------------------------------------------------------------


def parse_tsv(tsv: str) -> List[List[str]]:
    """Parse mariadb batch TSV into rows of string columns. Skips blank lines."""
    rows: List[List[str]] = []
    for line in tsv.splitlines():
        line = line.rstrip("\r")
        if not line:
            continue
        rows.append(line.split("\t"))
    return rows


def _require_cols(row: Sequence[str], n: int, label: str) -> None:
    if len(row) < n:
        raise ValueError(f"{label}: expected ≥{n} columns, got {len(row)}: {row!r}")


def sql_quote_name(name: str) -> str:
    """Validate + SQL-string-escape a character name (letters/digits/_ only)."""
    if not _SAFE_NAME.match(name):
        raise ValueError(
            f"character name must match {_SAFE_NAME.pattern}, got {name!r}"
        )
    return name.replace("\\", "\\\\").replace("'", "''")


# ---------------------------------------------------------------------------
# Snapshot builders from TSV (pure; fixtures feed these in tests)
# ---------------------------------------------------------------------------


def character_row_from_tsv(row: Sequence[str]) -> Dict[str, Any]:
    """Map one characters SELECT row to a plain dict.

    Expected order:
      guid name level xp map position_x position_y position_z orientation
      health power1 death_expire_time online
    """
    _require_cols(row, 12, "character")
    return {
        "guid": int(row[0]),
        "name": row[1],
        "level": int(row[2]),
        "xp": int(row[3]),
        "map": int(row[4]),
        "x": float(row[5]),
        "y": float(row[6]),
        "z": float(row[7]),
        "orientation": float(row[8]),
        "health": int(row[9]),
        "power1": int(row[10]),
        "death_expire_time": int(row[11]),
        "online": int(row[12]) if len(row) > 12 else 0,
    }


def quests_from_tsv(rows: Sequence[Sequence[str]]) -> Dict[int, Dict[str, Any]]:
    """quest status rows → {quest_id: {...}}.

    Expected order per row:
      quest status rewarded explored
      mob_count1..4 item_count1..4
    """
    out: Dict[int, Dict[str, Any]] = {}
    for row in rows:
        _require_cols(row, 12, "queststatus")
        qid = int(row[0])
        out[qid] = {
            "status": int(row[1]),
            "rewarded": int(row[2]),
            "explored": int(row[3]),
            "mob_counts": [int(row[4]), int(row[5]), int(row[6]), int(row[7])],
            "item_counts": [int(row[8]), int(row[9]), int(row[10]), int(row[11])],
        }
    return out


def inventory_from_tsv(rows: Sequence[Sequence[str]]) -> Dict[int, int]:
    """Aggregate inventory by item_id → total count.

    Expected order: item_id count
    """
    out: Dict[int, int] = {}
    for row in rows:
        _require_cols(row, 2, "inventory")
        item_id = int(row[0])
        count = int(row[1])
        out[item_id] = out.get(item_id, 0) + count
    return out


def skills_from_tsv(rows: Sequence[Sequence[str]]) -> Dict[int, int]:
    """skill rows → {skill_id: value}. Expected: skill value."""
    out: Dict[int, int] = {}
    for row in rows:
        _require_cols(row, 2, "skills")
        out[int(row[0])] = int(row[1])
    return out


def spells_from_tsv(rows: Sequence[Sequence[str]]) -> Set[int]:
    """spell rows → set of spell ids. Expected: spell [active] [disabled]."""
    out: Set[int] = set()
    for row in rows:
        _require_cols(row, 1, "spells")
        # Skip disabled spells when the column is present.
        if len(row) >= 3 and int(row[2]) != 0:
            continue
        out.add(int(row[0]))
    return out


def build_snapshot(
    character: Mapping[str, Any],
    quests: Mapping[int, Mapping[str, Any]],
    inventory: Mapping[int, int],
    skills: Mapping[int, int],
    spells: Iterable[int],
) -> Dict[str, Any]:
    """Normalize a full character snapshot for diffing."""
    return {
        "character": dict(character),
        "quests": {int(k): dict(v) for k, v in quests.items()},
        "inventory": {int(k): int(v) for k, v in inventory.items()},
        "skills": {int(k): int(v) for k, v in skills.items()},
        "spells": set(int(s) for s in spells),
    }


# ---------------------------------------------------------------------------
# Diff → events (pure)
# ---------------------------------------------------------------------------


def _ts_iso(ts: Optional[float] = None) -> str:
    t = time.time() if ts is None else ts
    return datetime.fromtimestamp(t, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _event(kind: str, ts: str, **fields: Any) -> Dict[str, Any]:
    ev: Dict[str, Any] = {"ts": ts, "kind": kind}
    ev.update(fields)
    return ev


def _moved(a: Mapping[str, Any], b: Mapping[str, Any], eps: float = POSITION_EPSILON) -> bool:
    if int(a["map"]) != int(b["map"]):
        return True
    dx = float(a["x"]) - float(b["x"])
    dy = float(a["y"]) - float(b["y"])
    dz = float(a["z"]) - float(b["z"])
    return (dx * dx + dy * dy + dz * dz) ** 0.5 >= eps


def diff_snapshots(
    prev: Optional[Mapping[str, Any]],
    curr: Mapping[str, Any],
    *,
    ts: Optional[str] = None,
    position_epsilon: float = POSITION_EPSILON,
) -> List[Dict[str, Any]]:
    """Compare two snapshots; return ordered breadcrumb events.

    When ``prev`` is None, emits only ``session_start`` (baseline, no diffs).
    HP/mana changes are intentionally omitted (too noisy).
    """
    now = ts if ts is not None else _ts_iso()
    ch = curr["character"]
    name = ch.get("name", "")
    guid = ch.get("guid")
    events: List[Dict[str, Any]] = []

    if prev is None:
        events.append(
            _event(
                "session_start",
                now,
                character=name,
                guid=guid,
                level=ch.get("level"),
                xp=ch.get("xp"),
                map=ch.get("map"),
                x=ch.get("x"),
                y=ch.get("y"),
                z=ch.get("z"),
            )
        )
        return events

    prev_ch = prev["character"]

    # Level / XP
    if int(ch["level"]) > int(prev_ch["level"]):
        events.append(
            _event(
                "level_up",
                now,
                character=name,
                guid=guid,
                from_level=int(prev_ch["level"]),
                to_level=int(ch["level"]),
                xp=int(ch["xp"]),
            )
        )
    elif int(ch["xp"]) != int(prev_ch["xp"]):
        # Level-up already implies XP reset; only emit xp_gain when level stable.
        delta = int(ch["xp"]) - int(prev_ch["xp"])
        events.append(
            _event(
                "xp_gain",
                now,
                character=name,
                guid=guid,
                from_xp=int(prev_ch["xp"]),
                to_xp=int(ch["xp"]),
                delta=delta,
                level=int(ch["level"]),
            )
        )

    # Position
    if _moved(prev_ch, ch, position_epsilon):
        events.append(
            _event(
                "position",
                now,
                character=name,
                guid=guid,
                map=int(ch["map"]),
                x=float(ch["x"]),
                y=float(ch["y"]),
                z=float(ch["z"]),
                orientation=float(ch.get("orientation", 0.0)),
                from_map=int(prev_ch["map"]),
                from_x=float(prev_ch["x"]),
                from_y=float(prev_ch["y"]),
                from_z=float(prev_ch["z"]),
            )
        )

    # Death: death_expire_time advances, or health drops to 0 from >0
    death = False
    if int(ch.get("death_expire_time", 0)) > int(prev_ch.get("death_expire_time", 0)):
        death = True
    elif int(ch.get("health", 1)) == 0 and int(prev_ch.get("health", 1)) > 0:
        death = True
    if death:
        events.append(
            _event(
                "death",
                now,
                character=name,
                guid=guid,
                death_expire_time=int(ch.get("death_expire_time", 0)),
                health=int(ch.get("health", 0)),
                map=int(ch["map"]),
                x=float(ch["x"]),
                y=float(ch["y"]),
                z=float(ch["z"]),
            )
        )

    # Quests
    events.extend(_diff_quests(prev.get("quests", {}), curr.get("quests", {}), now, name, guid))

    # Inventory
    events.extend(
        _diff_inventory(prev.get("inventory", {}), curr.get("inventory", {}), now, name, guid)
    )

    # Skills
    events.extend(_diff_skills(prev.get("skills", {}), curr.get("skills", {}), now, name, guid))

    # Spells
    prev_spells = set(prev.get("spells", set()))
    curr_spells = set(curr.get("spells", set()))
    for spell_id in sorted(curr_spells - prev_spells):
        events.append(
            _event(
                "spell_learned",
                now,
                character=name,
                guid=guid,
                spell=int(spell_id),
            )
        )

    return events


def _diff_quests(
    prev: Mapping[int, Any],
    curr: Mapping[int, Any],
    ts: str,
    name: str,
    guid: Any,
) -> List[Dict[str, Any]]:
    events: List[Dict[str, Any]] = []
    prev_ids = set(int(k) for k in prev)
    curr_ids = set(int(k) for k in curr)

    for qid in sorted(curr_ids - prev_ids):
        q = curr[qid]
        status = int(q["status"])
        rewarded = int(q.get("rewarded", 0))
        if rewarded:
            events.append(
                _event(
                    "quest_rewarded",
                    ts,
                    character=name,
                    guid=guid,
                    quest=qid,
                    status=status,
                    status_name=QUEST_STATUS_NAMES.get(status, "unknown"),
                )
            )
        elif status == QUEST_STATUS_COMPLETE:
            events.append(
                _event(
                    "quest_completed",
                    ts,
                    character=name,
                    guid=guid,
                    quest=qid,
                    status=status,
                    status_name=QUEST_STATUS_NAMES.get(status, "unknown"),
                )
            )
        else:
            # New row: accepted into log (typically INCOMPLETE).
            events.append(
                _event(
                    "quest_accepted",
                    ts,
                    character=name,
                    guid=guid,
                    quest=qid,
                    status=status,
                    status_name=QUEST_STATUS_NAMES.get(status, "unknown"),
                )
            )

    for qid in sorted(curr_ids & prev_ids):
        p = prev[qid]
        c = curr[qid]
        p_status = int(p["status"])
        c_status = int(c["status"])
        p_rew = int(p.get("rewarded", 0))
        c_rew = int(c.get("rewarded", 0))

        if c_rew and not p_rew:
            events.append(
                _event(
                    "quest_rewarded",
                    ts,
                    character=name,
                    guid=guid,
                    quest=qid,
                    status=c_status,
                    status_name=QUEST_STATUS_NAMES.get(c_status, "unknown"),
                )
            )
        elif c_status == QUEST_STATUS_COMPLETE and p_status != QUEST_STATUS_COMPLETE:
            events.append(
                _event(
                    "quest_completed",
                    ts,
                    character=name,
                    guid=guid,
                    quest=qid,
                    status=c_status,
                    status_name=QUEST_STATUS_NAMES.get(c_status, "unknown"),
                    from_status=p_status,
                    from_status_name=QUEST_STATUS_NAMES.get(p_status, "unknown"),
                )
            )

        p_mobs = list(p.get("mob_counts", [0, 0, 0, 0]))
        c_mobs = list(c.get("mob_counts", [0, 0, 0, 0]))
        p_items = list(p.get("item_counts", [0, 0, 0, 0]))
        c_items = list(c.get("item_counts", [0, 0, 0, 0]))
        if p_mobs != c_mobs or p_items != c_items:
            events.append(
                _event(
                    "quest_objective",
                    ts,
                    character=name,
                    guid=guid,
                    quest=qid,
                    status=c_status,
                    status_name=QUEST_STATUS_NAMES.get(c_status, "unknown"),
                    mob_counts=c_mobs,
                    item_counts=c_items,
                    from_mob_counts=p_mobs,
                    from_item_counts=p_items,
                )
            )

    return events


def _diff_inventory(
    prev: Mapping[int, int],
    curr: Mapping[int, int],
    ts: str,
    name: str,
    guid: Any,
) -> List[Dict[str, Any]]:
    events: List[Dict[str, Any]] = []
    ids = set(int(k) for k in prev) | set(int(k) for k in curr)
    for item_id in sorted(ids):
        before = int(prev.get(item_id, 0))
        after = int(curr.get(item_id, 0))
        if after > before:
            events.append(
                _event(
                    "item_gained",
                    ts,
                    character=name,
                    guid=guid,
                    item_id=item_id,
                    count=after - before,
                    total=after,
                )
            )
        elif after < before:
            events.append(
                _event(
                    "item_lost",
                    ts,
                    character=name,
                    guid=guid,
                    item_id=item_id,
                    count=before - after,
                    total=after,
                )
            )
    return events


def _diff_skills(
    prev: Mapping[int, int],
    curr: Mapping[int, int],
    ts: str,
    name: str,
    guid: Any,
) -> List[Dict[str, Any]]:
    events: List[Dict[str, Any]] = []
    for skill_id in sorted(set(int(k) for k in curr)):
        after = int(curr[skill_id])
        before = int(prev.get(skill_id, 0))
        if after > before:
            events.append(
                _event(
                    "skill_up",
                    ts,
                    character=name,
                    guid=guid,
                    skill=skill_id,
                    from_value=before,
                    to_value=after,
                )
            )
    return events


# ---------------------------------------------------------------------------
# DB access (subprocess; not used by unit tests)
# ---------------------------------------------------------------------------


class MariadbError(RuntimeError):
    pass


def run_mariadb_sql(
    sql: str,
    *,
    container: str = DEFAULT_CONTAINER,
    db: str = DB_NAME,
    user: str = DB_USER,
    password: str = DB_PASS,
    runner: Optional[Callable[..., subprocess.CompletedProcess]] = None,
) -> str:
    """Run a SELECT via `docker exec <container> mariadb … -N -B -e`.

    Returns stdout TSV. Raises MariadbError on non-zero exit.
    """
    run = runner or subprocess.run
    cmd = [
        "docker",
        "exec",
        container,
        "mariadb",
        f"-u{user}",
        f"-p{password}",
        db,
        "-N",
        "-B",
        "-e",
        sql,
    ]
    proc = run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        err = (proc.stderr or "").strip() or (proc.stdout or "").strip()
        raise MariadbError(
            f"mariadb query failed (exit {proc.returncode}) via docker exec "
            f"{container}: {err}"
        )
    return proc.stdout or ""


CHAR_SELECT = (
    "SELECT guid, name, level, xp, map, position_x, position_y, position_z, "
    "orientation, health, power1, death_expire_time, online "
    "FROM characters"
)

QUEST_SELECT = (
    "SELECT quest, status, rewarded, explored, "
    "mob_count1, mob_count2, mob_count3, mob_count4, "
    "item_count1, item_count2, item_count3, item_count4 "
    "FROM character_queststatus WHERE guid={guid}"
)

INV_SELECT = (
    "SELECT i.item_id, COALESCE(ii.count, 1) "
    "FROM character_inventory i "
    "LEFT JOIN item_instance ii ON i.item_guid = ii.guid "
    "WHERE i.guid={guid}"
)

SKILL_SELECT = "SELECT skill, value FROM character_skills WHERE guid={guid}"

SPELL_SELECT = (
    "SELECT spell, active, disabled FROM character_spell WHERE guid={guid}"
)


def list_character_names(
    *,
    container: str = DEFAULT_CONTAINER,
    sql_runner: Optional[Callable[..., str]] = None,
) -> List[str]:
    run_sql = sql_runner or (
        lambda sql: run_mariadb_sql(sql, container=container)
    )
    tsv = run_sql("SELECT name FROM characters ORDER BY name")
    return [row[0] for row in parse_tsv(tsv) if row]


def fetch_character_snapshot(
    name: str,
    *,
    container: str = DEFAULT_CONTAINER,
    sql_runner: Optional[Callable[..., str]] = None,
) -> Dict[str, Any]:
    """Load a full snapshot for one character name from the live DB."""
    safe = sql_quote_name(name)
    run_sql = sql_runner or (
        lambda sql: run_mariadb_sql(sql, container=container)
    )

    char_tsv = run_sql(f"{CHAR_SELECT} WHERE name='{safe}' LIMIT 1")
    char_rows = parse_tsv(char_tsv)
    if not char_rows:
        raise MariadbError(f"character not found: {name!r}")
    character = character_row_from_tsv(char_rows[0])
    guid = int(character["guid"])

    quests = quests_from_tsv(parse_tsv(run_sql(QUEST_SELECT.format(guid=guid))))
    inventory = inventory_from_tsv(parse_tsv(run_sql(INV_SELECT.format(guid=guid))))
    skills = skills_from_tsv(parse_tsv(run_sql(SKILL_SELECT.format(guid=guid))))
    spells = spells_from_tsv(parse_tsv(run_sql(SPELL_SELECT.format(guid=guid))))
    return build_snapshot(character, quests, inventory, skills, spells)


# ---------------------------------------------------------------------------
# Session I/O
# ---------------------------------------------------------------------------


def default_session_dir(repo_root: Path, character_label: str) -> Path:
    stamp = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d_%H%M%S")
    safe_label = re.sub(r"[^A-Za-z0-9_-]+", "_", character_label) or "session"
    return repo_root / "sessions" / f"{stamp}-{safe_label}"


def write_manifest(
    session_dir: Path,
    *,
    character: str,
    started_at: str,
    realm: str = DEFAULT_REALM,
    extra: Optional[Mapping[str, Any]] = None,
) -> Path:
    session_dir.mkdir(parents=True, exist_ok=True)
    path = session_dir / "manifest.json"
    data: Dict[str, Any] = {
        "character": character,
        "started_at": started_at,
        "realm": realm,
    }
    if extra:
        data.update(extra)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def append_events(events_path: Path, events: Sequence[Mapping[str, Any]]) -> None:
    if not events:
        return
    events_path.parent.mkdir(parents=True, exist_ok=True)
    with events_path.open("a", encoding="utf-8") as fh:
        for ev in events:
            fh.write(json.dumps(ev, separators=(",", ":"), sort_keys=True) + "\n")


# ---------------------------------------------------------------------------
# Poll loop
# ---------------------------------------------------------------------------


def poll_once(
    names: Sequence[str],
    state: Dict[str, Optional[Dict[str, Any]]],
    writers: Mapping[str, Path],
    *,
    container: str,
    sql_runner: Optional[Callable[..., str]] = None,
    ts: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """Fetch + diff each named character; append JSONL; update state.

    Returns all events emitted this tick (for tests / logging).
    """
    emitted: List[Dict[str, Any]] = []
    for name in names:
        snap = fetch_character_snapshot(
            name, container=container, sql_runner=sql_runner
        )
        prev = state.get(name)
        events = diff_snapshots(prev, snap, ts=ts)
        state[name] = snap
        append_events(writers[name], events)
        emitted.extend(events)
    return emitted


def run_poller(
    names: Sequence[str],
    session_dirs: Mapping[str, Path],
    *,
    interval: float = DEFAULT_INTERVAL,
    container: str = DEFAULT_CONTAINER,
    realm: str = DEFAULT_REALM,
    once: bool = False,
    sql_runner: Optional[Callable[..., str]] = None,
) -> None:
    started = _ts_iso()
    writers: Dict[str, Path] = {}
    for name in names:
        sdir = session_dirs[name]
        write_manifest(
            sdir,
            character=name,
            started_at=started,
            realm=realm,
            extra={"container": container, "interval": interval},
        )
        writers[name] = sdir / "events.jsonl"

    state: Dict[str, Optional[Dict[str, Any]]] = {n: None for n in names}
    label = ",".join(names)
    print(
        f"breadcrumbs: polling {label} every {interval}s → "
        f"{session_dirs[names[0]].parent}",
        file=sys.stderr,
    )

    while True:
        tick_ts = _ts_iso()
        try:
            events = poll_once(
                names,
                state,
                writers,
                container=container,
                sql_runner=sql_runner,
                ts=tick_ts,
            )
            for ev in events:
                print(json.dumps(ev, separators=(",", ":"), sort_keys=True))
        except MariadbError as exc:
            print(f"breadcrumbs: DB error: {exc}", file=sys.stderr)
        except KeyboardInterrupt:
            print("breadcrumbs: stopped", file=sys.stderr)
            return
        if once:
            return
        try:
            time.sleep(interval)
        except KeyboardInterrupt:
            print("breadcrumbs: stopped", file=sys.stderr)
            return


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Poll VMaNGOS characters DB and record breadcrumb JSONL events."
    )
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--character", metavar="NAME", help="Single character name to poll")
    g.add_argument(
        "--all",
        action="store_true",
        help="Poll every character on the realm (one session subdir each)",
    )
    p.add_argument(
        "--session-dir",
        metavar="DIR",
        help="Session directory (default: sessions/<utc-date-charname>)",
    )
    p.add_argument(
        "--interval",
        type=float,
        default=DEFAULT_INTERVAL,
        help=f"Poll interval seconds (default {DEFAULT_INTERVAL})",
    )
    p.add_argument(
        "--container",
        default=DEFAULT_CONTAINER,
        help=f"docker container with mariadb (default {DEFAULT_CONTAINER})",
    )
    p.add_argument(
        "--realm",
        default=DEFAULT_REALM,
        help=f"Realm label written to manifest.json (default {DEFAULT_REALM})",
    )
    p.add_argument(
        "--once",
        action="store_true",
        help="Single poll then exit (smoke / tests)",
    )
    return p


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)
    repo = _repo_root()

    try:
        if args.all:
            names = list_character_names(container=args.container)
            if not names:
                print("breadcrumbs: no characters in DB", file=sys.stderr)
                return 1
        else:
            names = [args.character]
            # Validate name early (SQL safety).
            sql_quote_name(args.character)
    except (MariadbError, ValueError) as exc:
        print(f"breadcrumbs: {exc}", file=sys.stderr)
        return 1

    session_dirs: Dict[str, Path] = {}
    if args.session_dir:
        base = Path(args.session_dir)
        if not base.is_absolute():
            base = repo / base
        if len(names) == 1:
            session_dirs[names[0]] = base
        else:
            for n in names:
                session_dirs[n] = base / n
    else:
        if len(names) == 1:
            session_dirs[names[0]] = default_session_dir(repo, names[0])
        else:
            base = default_session_dir(repo, "all")
            for n in names:
                session_dirs[n] = base / n

    run_poller(
        names,
        session_dirs,
        interval=args.interval,
        container=args.container,
        realm=args.realm,
        once=args.once,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
