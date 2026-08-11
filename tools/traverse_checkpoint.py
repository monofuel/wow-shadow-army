#!/usr/bin/env python3
"""Local-debug checkpoint and segment support for make traverse.

After the traverse scenario seeds Tanaris and the character is in-world (or
offline between seed and login), place them at a named pose via MaNGOS SOAP:

  tele name <character> <game_tele_name>

game_tele rows are ensured in the world DB and reloaded. Fair-play prove does
not use this path — local CHECKPOINT setup only (monofuel-authorized tele).

The ``wait`` command observes an already-running local checkpoint episode and
returns success when its named END_CHECKPOINT is reached.
"""
from __future__ import annotations

import argparse
import base64
import json
import math
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TABLE = ROOT / "tools" / "traverse_checkpoints.json"
# The live status file is written by the lua-bot host every frame; the old
# traverse-cv-status.json died with the ClientView bridge (1454caa).
# Traverse-private status file: the shared local_data/lua-bot-status.json
# is written by EVERY lua-bot league (the accelerated bot clobbered it
# mid-battery, 2026-08-10); the traverse launch passes --lua-status-dir.
DEFAULT_STATUS = ROOT / "local_data" / "traverse-status" / "status.json"
DEFAULT_CHAR = os.environ.get("TRAVERSE_CHARACTER", "Northbound")
DEFAULT_SOAP_USER = os.environ.get("TRAVERSE_SOAP_USER", "COWCAM")
DEFAULT_SOAP_PASS = os.environ.get("TRAVERSE_SOAP_PASS", "COWCAM")


class SoapError(RuntimeError):
    pass


def load_table(path: Path | None = None) -> dict[str, Any]:
    p = path or DEFAULT_TABLE
    data = json.loads(p.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not data:
        raise ValueError(f"checkpoint table empty: {p}")
    return data


def resolve_checkpoint(name: str, table: dict[str, Any] | None = None) -> dict[str, Any]:
    t = table if table is not None else load_table()
    if name not in t:
        known = ", ".join(sorted(t))
        raise KeyError(f"unknown checkpoint {name!r}; known: {known}")
    pose = dict(t[name])
    pose["name"] = name
    return pose


def tele_command(character: str, tele_name: str) -> str:
    """Build MaNGOS SOAP command for this realm (verified: tele name <char> <loc>)."""
    if not character or not tele_name:
        raise ValueError("character and tele_name required")
    if any(c.isspace() for c in character) or any(c.isspace() for c in tele_name):
        raise ValueError("character/tele_name must be single tokens")
    return f"tele name {character} {tele_name}"


def find_traverse_container() -> str | None:
    try:
        out = subprocess.check_output(
            ["docker", "ps", "--format", "{{.Names}}"],
            text=True,
            timeout=10,
        )
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        return None
    names = [n.strip() for n in out.splitlines() if n.strip()]
    # Prefer running traverse game containers
    for n in names:
        if "traverse" in n and "coworld-game" in n:
            return n
    for n in names:
        if "coworld-game" in n:
            return n
    return None


def container_ip(name: str) -> str:
    out = subprocess.check_output(
        [
            "docker",
            "inspect",
            name,
            "--format",
            "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
        ],
        text=True,
        timeout=10,
    ).strip()
    if not out:
        raise RuntimeError(f"no IP for container {name}")
    return out


def soap_url(host: str | None = None, port: int | None = None) -> str:
    h = host or os.environ.get("TRAVERSE_SOAP_HOST")
    p = port or int(os.environ.get("TRAVERSE_SOAP_PORT", "7878"))
    if not h:
        c = find_traverse_container()
        if not c:
            raise RuntimeError("no traverse coworld-game container running")
        h = container_ip(c)
    return f"http://{h}:{p}/"


def soap_execute(
    command: str,
    *,
    url: str | None = None,
    user: str | None = None,
    password: str | None = None,
    timeout: float = 8.0,
) -> str:
    """POST MaNGOS executeCommand; return result text or raise SoapError."""
    endpoint = url or soap_url()
    u = user or DEFAULT_SOAP_USER
    pw = password if password is not None else DEFAULT_SOAP_PASS
    body = (
        '<?xml version="1.0"?>'
        '<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" '
        'xmlns:ns1="urn:MaNGOS"><SOAP-ENV:Body><ns1:executeCommand><command>'
        f"{escape(command)}"
        "</command></ns1:executeCommand></SOAP-ENV:Body></SOAP-ENV:Envelope>"
    )
    auth = base64.b64encode(f"{u}:{pw}".encode()).decode()
    req = urllib.request.Request(
        endpoint,
        data=body.encode("utf-8"),
        method="POST",
        headers={
            "Content-Type": "text/xml",
            "Authorization": f"Basic {auth}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            text = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", errors="replace")
        fault = re.search(r"<faultstring>(.*?)</faultstring>", text, re.S)
        detail = re.search(r"<detail>(.*?)</detail>", text, re.S)
        msg = ""
        if fault:
            msg = _xml_unesc(fault.group(1))
        if detail:
            msg = (msg + " " + _xml_unesc(detail.group(1))).strip()
        raise SoapError(msg or f"HTTP {e.code}: {text[:300]}") from e
    except urllib.error.URLError as e:
        raise SoapError(f"SOAP unreachable at {endpoint}: {e}") from e

    m = re.search(r"<result>(.*?)</result>", text, re.S)
    if m:
        return _xml_unesc(m.group(1)).strip()
    if "Fault" in text:
        raise SoapError(text[:400])
    return text.strip()


def _xml_unesc(s: str) -> str:
    return (
        s.replace("&#xD;", "\n")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
        .replace("&quot;", '"')
    )


def docker_exec_sql(sql: str, database: str = "mangos") -> str:
    c = find_traverse_container()
    if not c:
        raise RuntimeError("no traverse container for SQL")
    cmd = [
        "docker",
        "exec",
        c,
        "sh",
        "-c",
        f"mariadb -umangos -pmangos {database} -N -e {json.dumps(sql)}",
    ]
    return subprocess.check_output(cmd, text=True, timeout=30, stderr=subprocess.STDOUT)


def ensure_gm_account(username: str = "COWCAM", level: int = 100) -> None:
    """Local-debug: raise gmlevel so tele name works after SOAP enable."""
    c = find_traverse_container()
    if not c:
        return
    sql = (
        f"UPDATE account SET gmlevel={int(level)} "
        f"WHERE username='{username.replace(chr(39), '')}';"
    )
    try:
        subprocess.check_call(
            [
                "docker",
                "exec",
                c,
                "sh",
                "-c",
                f"mariadb -umangos -pmangos realmd -e {json.dumps(sql)}",
            ],
            timeout=30,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        pass


def ensure_game_tele(pose: dict[str, Any]) -> str:
    """Ensure game_tele row exists for pose['tele_name']; return tele name."""
    tele_name = pose.get("tele_name")
    if not tele_name:
        raise ValueError("pose has no tele_name (spawn / no-op)")
    x, y, z = float(pose["x"]), float(pose["y"]), float(pose["z"])
    o = float(pose.get("orientation") or 0.0)
    mid = int(pose.get("map_id") or 1)
    # Escape name for SQL string
    name = str(tele_name).replace("\\", "\\\\").replace("'", "''")
    sql = (
        "INSERT INTO game_tele (position_x, position_y, position_z, orientation, map, name) "
        f"SELECT {x}, {y}, {z}, {o}, {mid}, '{name}' FROM DUAL "
        f"WHERE NOT EXISTS (SELECT 1 FROM game_tele WHERE name='{name}');"
        f"UPDATE game_tele SET position_x={x}, position_y={y}, position_z={z}, "
        f"orientation={o}, map={mid} WHERE name='{name}';"
        f"SELECT name FROM game_tele WHERE name='{name}';"
    )
    try:
        out = docker_exec_sql(sql)
        print(f"[traverse-checkpoint] game_tele ensure: {out.strip()!r}")
    except Exception as e:  # noqa: BLE001
        print(f"[traverse-checkpoint] warn: game_tele SQL: {e}", file=sys.stderr)
    # Reload so mangosd sees the row (locations are cached until reload).
    try:
        r = soap_execute("reload game_tele")
        print(f"[traverse-checkpoint] reload game_tele: {r}")
    except SoapError as e:
        print(f"[traverse-checkpoint] warn: reload game_tele: {e}", file=sys.stderr)
    return str(tele_name)


def planar_dist(x0: float, y0: float, x1: float, y1: float) -> float:
    return math.hypot(x1 - x0, y1 - y0)


def read_status(path: Path | None = None) -> dict[str, Any] | None:
    p = path or Path(os.environ.get("TRAVERSE_CV_STATUS", str(DEFAULT_STATUS)))
    if not p.is_file():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def status_path_resolved(path: Path | None = None) -> Path:
    return path or Path(os.environ.get("TRAVERSE_CV_STATUS", str(DEFAULT_STATUS)))


def wait_for_soap(*, timeout: float = 180.0, poll: float = 2.0) -> str:
    """Block until SOAP server info works; return result text. Re-resolve container IP each try."""
    deadline = time.time() + timeout
    last_err: Exception | None = None
    while time.time() < deadline:
        try:
            # Prefer live container IP every loop (recreate changes IP).
            url = soap_url()
            result = soap_execute("server info", url=url)
            if result:
                print(f"[traverse-checkpoint] SOAP up at {url}")
                return result
        except Exception as e:  # noqa: BLE001 — retry until timeout
            last_err = e
        time.sleep(poll)
    raise TimeoutError(f"SOAP not reachable within {timeout}s: {last_err}")


def wait_for_in_world(
    *,
    status_path: Path | None = None,
    timeout: float = 300.0,
    poll: float = 2.0,
    min_sequence: int = 1,
    max_age_s: float = 30.0,
) -> dict[str, Any]:
    """Wait until status JSON is fresh and shows an in-world pose (client logged in)."""
    p = status_path_resolved(status_path)
    deadline = time.time() + timeout
    last: dict[str, Any] | None = None
    while time.time() < deadline:
        try:
            age = time.time() - p.stat().st_mtime if p.is_file() else 1e9
        except OSError:
            age = 1e9
        st = read_status(p)
        if (
            st
            and age <= max_age_s
            and isinstance(st.get("x"), (int, float))
            and isinstance(st.get("y"), (int, float))
        ):
            seq = st.get("sequence") or 0
            try:
                seq_n = int(seq)
            except (TypeError, ValueError):
                seq_n = 0
            # Require a live bridge tick so we don't tele against a stale file
            # while the character is still offline for SOAP.
            if seq_n >= min_sequence and not st.get("ghost"):
                print(
                    f"[traverse-checkpoint] in-world x={st['x']:.1f} y={st['y']:.1f} "
                    f"seq={seq_n} age={age:.1f}s"
                )
                return st
            last = st
        time.sleep(poll)
    if last:
        return last
    raise TimeoutError("timed out waiting for fresh traverse-cv-status.json in-world pose")


def pose_dist_to_checkpoint(st: dict[str, Any], pose: dict[str, Any]) -> float:
    return planar_dist(
        float(st["x"]),
        float(st["y"]),
        float(pose["x"]),
        float(pose["y"]),
    )


def apply_checkpoint(
    name: str,
    *,
    character: str | None = None,
    status_path: Path | None = None,
    wait_timeout: float = 300.0,
    near_yards: float = 120.0,
    skip_wait: bool = False,
) -> dict[str, Any]:
    """Resolve checkpoint, ensure tele loc + GM, wait in-world, SOAP tele, verify pose."""
    pose = resolve_checkpoint(name)
    char = character or DEFAULT_CHAR
    sp = status_path_resolved(status_path)
    if not pose.get("tele_name"):
        return {
            "ok": True,
            "checkpoint": name,
            "skipped": True,
            "reason": "no tele (spawn)",
        }

    print(f"[traverse-checkpoint] apply {name!r} → ({pose['x']}, {pose['y']}, {pose['z']})")
    print("[traverse-checkpoint] waiting for SOAP…")
    wait_for_soap(timeout=min(180.0, wait_timeout))
    ensure_gm_account(DEFAULT_SOAP_USER, 100)
    tele_name = ensure_game_tele(pose)
    cmd = tele_command(char, tele_name)

    if not skip_wait:
        print(f"[traverse-checkpoint] waiting for in-world status (timeout={wait_timeout}s)…")
        st = wait_for_in_world(status_path=sp, timeout=wait_timeout)
        # Never teleport a corpse: a late apply that moves a dead bot just
        # parks a zombie at the checkpoint (its run_over hold never acts).
        if st.get("intent_reason") == "run_over":
            print(
                "[traverse-checkpoint] REFUSED: the bot is already dead "
                "(run_over) — a teleported corpse would sit at the "
                "checkpoint doing nothing. Restart the run.",
                flush=True,
            )
            return {
                "ok": False,
                "checkpoint": name,
                "reason": "bot dead (run_over); refusing to teleport a corpse",
                "status": st,
            }

    # Tele and re-tele until live status is near the checkpoint.
    # Offline tele alone does not move an already-logged-in body.
    deadline = time.time() + (30.0 if skip_wait else 120.0)
    last_result = ""
    best: dict[str, Any] | None = None
    best_d = 1e18
    attempt = 0
    while time.time() < deadline:
        attempt += 1
        try:
            wait_for_soap(timeout=30.0)
            ensure_gm_account(DEFAULT_SOAP_USER, 100)
            # Re-ensure tele location each attempt — fresh DB / un-reloaded cache
            # yields "Teleport location not found!" until insert+reload stick.
            if attempt == 1 or attempt % 3 == 0:
                ensure_game_tele(pose)
            last_result = soap_execute(cmd)
            print(f"[traverse-checkpoint] SOAP attempt {attempt}: {last_result}", flush=True)
        except SoapError as e:
            err = str(e)
            print(f"[traverse-checkpoint] SOAP attempt {attempt} error: {e}", flush=True)
            if "location not found" in err.lower():
                try:
                    ensure_game_tele(pose)
                except Exception as e2:  # noqa: BLE001
                    print(f"[traverse-checkpoint] re-ensure game_tele failed: {e2}", flush=True)
            time.sleep(3)
            continue

        # Give the server a moment to move the unit, then read status.
        for _ in range(5):
            time.sleep(1.5)
            st = read_status(sp)
            if not st or not isinstance(st.get("x"), (int, float)):
                continue
            if st.get("intent_reason") == "run_over":
                print(
                    "[traverse-checkpoint] REFUSED: bot died during apply "
                    "— not re-teleporting a corpse. Restart the run.",
                    flush=True,
                )
                return {
                    "ok": False,
                    "checkpoint": name,
                    "reason": "bot died during apply",
                    "status": st,
                }
            d = pose_dist_to_checkpoint(st, pose)
            if d < best_d:
                best_d = d
                best = st
            print(f"[traverse-checkpoint] status dist={d:.1f} yd to {name}")
            if d <= near_yards:
                return {
                    "ok": True,
                    "checkpoint": name,
                    "command": cmd,
                    "soap_result": last_result,
                    "dist": d,
                    "status": st,
                    "attempts": attempt,
                }
        time.sleep(2)

    soap_ok = "teleport" in last_result.lower() and "not found" not in last_result.lower()
    if soap_ok and skip_wait:
        return {
            "ok": True,
            "checkpoint": name,
            "command": cmd,
            "soap_result": last_result,
            "dist": best_d if best else None,
            "status": best,
            "offline_tele": "offline" in last_result.lower(),
            "attempts": attempt,
        }

    return {
        "ok": best_d <= near_yards,
        "checkpoint": name,
        "command": cmd,
        "soap_result": last_result,
        "dist": best_d if best else None,
        "status": best,
        "attempts": attempt,
        "warning": None if best_d <= near_yards else f"pose still {best_d:.0f} yd from target",
    }


def wait_for_segment_endpoint(
    start_name: str,
    end_name: str,
    *,
    status_path: Path | None = None,
    timeout: float = 2700.0,
    near_yards: float = 50.0,
    start_near_yards: float = 120.0,
    poll: float = 0.5,
) -> dict[str, Any]:
    """Wait for a fresh checkpoint start, then measure until the endpoint."""
    start_pose = resolve_checkpoint(start_name)
    end_pose = resolve_checkpoint(end_name)
    sp = status_path_resolved(status_path)
    deadline = time.monotonic() + timeout

    # Ignore the scenario spawn while the asynchronous SOAP tele is pending.
    started_status: dict[str, Any] | None = None
    while time.monotonic() < deadline:
        st = read_status(sp)
        if st and isinstance(st.get("x"), (int, float)) and isinstance(st.get("y"), (int, float)):
            if pose_dist_to_checkpoint(st, start_pose) <= start_near_yards:
                started_status = st
                break
            if st.get("intent_reason") == "run_over":
                return {
                    "ok": False,
                    "start_checkpoint": start_name,
                    "end_checkpoint": end_name,
                    "reason": "bot died before segment start",
                    "deaths": 1,
                }
        time.sleep(poll)
    if started_status is None:
        return {
            "ok": False,
            "start_checkpoint": start_name,
            "end_checkpoint": end_name,
            "reason": "start checkpoint was not observed",
            "deaths": 0,
        }

    segment_started = time.monotonic()
    last_sample_at = segment_started
    last_x = float(started_status["x"])
    last_y = float(started_status["y"])
    stationary_since = segment_started
    total_idle = 0.0
    max_stationary = 0.0
    swimming_samples = 1 if started_status.get("swimming") else 0
    samples = 1
    final_status = started_status

    while time.monotonic() < deadline:
        time.sleep(poll)
        now = time.monotonic()
        st = read_status(sp)
        if not st or not isinstance(st.get("x"), (int, float)) or not isinstance(st.get("y"), (int, float)):
            continue
        x, y = float(st["x"]), float(st["y"])
        sample_seconds = max(0.0, now - last_sample_at)
        moved = planar_dist(last_x, last_y, x, y) > 0.2
        if moved:
            max_stationary = max(max_stationary, now - stationary_since)
            stationary_since = now
        else:
            total_idle += sample_seconds
        last_x, last_y = x, y
        last_sample_at = now
        final_status = st
        samples += 1
        if st.get("swimming"):
            swimming_samples += 1
        distance = pose_dist_to_checkpoint(st, end_pose)
        if distance <= near_yards:
            elapsed = now - segment_started
            max_stationary = max(max_stationary, now - stationary_since)
            return {
                "ok": True,
                "start_checkpoint": start_name,
                "end_checkpoint": end_name,
                "elapsed_seconds": round(elapsed, 3),
                "endpoint_distance_yards": round(distance, 3),
                "max_stationary_seconds": round(max_stationary, 3),
                "total_idle_seconds": round(total_idle, 3),
                "idle_fraction": round(total_idle / elapsed, 4) if elapsed > 0 else 0.0,
                "swimming_samples": swimming_samples,
                "samples": samples,
                "deaths": 0,
                "final_nav_error": st.get("nav_error") or "",
            }
        if st.get("intent_reason") == "run_over":
            return {
                "ok": False,
                "start_checkpoint": start_name,
                "end_checkpoint": end_name,
                "reason": "bot died during segment",
                "deaths": 1,
                "endpoint_distance_yards": round(distance, 3),
                "final_nav_error": st.get("nav_error") or "",
            }

    return {
        "ok": False,
        "start_checkpoint": start_name,
        "end_checkpoint": end_name,
        "reason": "segment endpoint timeout",
        "deaths": 0,
        "endpoint_distance_yards": round(
            pose_dist_to_checkpoint(final_status, end_pose), 3
        ),
        "final_nav_error": final_status.get("nav_error") or "",
    }


def cmd_list(_: argparse.Namespace) -> int:
    for name, pose in load_table().items():
        print(
            f"{name:16s}  ({pose.get('x')}, {pose.get('y')}, {pose.get('z')})  "
            f"tele={pose.get('tele_name')!r}  {pose.get('note', '')}"
        )
    return 0


def cmd_resolve(args: argparse.Namespace) -> int:
    print(json.dumps(resolve_checkpoint(args.name), indent=2))
    return 0


def cmd_tele_cmd(args: argparse.Namespace) -> int:
    pose = resolve_checkpoint(args.name)
    if not pose.get("tele_name"):
        print("spawn")  # no-op sentinel
        return 0
    print(tele_command(args.character or DEFAULT_CHAR, str(pose["tele_name"])))
    return 0


def cmd_apply(args: argparse.Namespace) -> int:
    out = apply_checkpoint(
        args.name,
        character=args.character,
        status_path=Path(args.status) if args.status else None,
        wait_timeout=args.timeout,
        near_yards=args.near,
        skip_wait=args.no_wait,
    )
    print(json.dumps(out, indent=2, default=str))
    return 0 if out.get("ok") else 1


def cmd_wait(args: argparse.Namespace) -> int:
    out = wait_for_segment_endpoint(
        args.start,
        args.end,
        status_path=Path(args.status) if args.status else None,
        timeout=args.timeout,
        near_yards=args.near,
        start_near_yards=args.start_near,
        poll=args.poll,
    )
    body = json.dumps(out, indent=2, default=str)
    if args.result:
        result_path = Path(args.result)
        result_path.parent.mkdir(parents=True, exist_ok=True)
        result_path.write_text(body + "\n", encoding="utf-8")
    print(body)
    return 0 if out.get("ok") else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="List named checkpoints")
    pr = sub.add_parser("resolve", help="Print checkpoint pose JSON")
    pr.add_argument("name")
    pt = sub.add_parser("tele-cmd", help="Print SOAP tele command string")
    pt.add_argument("name")
    pt.add_argument("--character", default=DEFAULT_CHAR)
    pa = sub.add_parser("apply", help="Wait for in-world + SOAP tele to checkpoint")
    pa.add_argument("name")
    pa.add_argument("--character", default=DEFAULT_CHAR)
    pa.add_argument("--status", default=str(DEFAULT_STATUS))
    pa.add_argument("--timeout", type=float, default=300.0)
    pa.add_argument("--near", type=float, default=120.0)
    pa.add_argument("--no-wait", action="store_true", help="Tele immediately (offline ok)")
    pw = sub.add_parser("wait", help="Wait for a checkpoint-to-checkpoint segment")
    pw.add_argument("start")
    pw.add_argument("end")
    pw.add_argument("--status", default=str(DEFAULT_STATUS))
    pw.add_argument("--timeout", type=float, default=2700.0)
    pw.add_argument("--near", type=float, default=50.0)
    pw.add_argument("--start-near", type=float, default=120.0)
    pw.add_argument("--poll", type=float, default=0.5)
    pw.add_argument("--result")

    args = p.parse_args()
    if args.cmd == "list":
        return cmd_list(args)
    if args.cmd == "resolve":
        return cmd_resolve(args)
    if args.cmd == "tele-cmd":
        return cmd_tele_cmd(args)
    if args.cmd == "apply":
        return cmd_apply(args)
    if args.cmd == "wait":
        return cmd_wait(args)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130) from None
