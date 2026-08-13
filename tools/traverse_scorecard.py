#!/usr/bin/env python3
"""Parse a traverse run.log into a compact per-run scorecard.

Reads FLIGHT / EV / SNAG / STALL lines from launcher stdout (other lines
ignored). Durations are simulation seconds from FLIGHT ``t`` fields.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

FLIGHT_RE = re.compile(r"FLIGHT\s+(\{.*\})")
EV_RE = re.compile(
    r"EV\s+(\w+)\b(?:.*?)\bx=([-\d.]+)\s+y=([-\d.]+)",
)
SNAG_RE = re.compile(
    r"SNAG:.*?at\s+\(([-\d.]+),\s*([-\d.]+)\)",
)
STALL_RE = re.compile(r"STALL:")


def planar(x0: float, y0: float, x1: float, y1: float) -> float:
    return math.hypot(x1 - x0, y1 - y0)


def percentile(vals: list[float], p: float) -> float | None:
    if not vals:
        return None
    s = sorted(vals)
    if len(s) == 1:
        return s[0]
    k = (len(s) - 1) * (p / 100.0)
    f = int(math.floor(k))
    c = int(math.ceil(k))
    if f == c:
        return s[f]
    return s[f] * (c - k) + s[c] * (k - f)


def _parse_flight(line: str) -> dict[str, Any] | None:
    m = FLIGHT_RE.search(line)
    if not m:
        return None
    try:
        obj = json.loads(m.group(1))
    except json.JSONDecodeError:
        return None
    if not isinstance(obj, dict):
        return None
    try:
        return {
            "t": float(obj["t"]),
            "x": float(obj["x"]),
            "y": float(obj["y"]),
            "z": float(obj.get("z") or 0),
            "hp": int(obj.get("hp") if obj.get("hp") is not None else -1),
            "form": int(obj.get("form") or 0),
            "swim": bool(obj.get("swim")),
            "combat": bool(obj.get("combat")),
            "nav": str(obj.get("nav") or ""),
            "beat": str(obj.get("beat") or ""),
            "xt": float(obj["xt"]) if obj.get("xt") is not None else -1.0,
        }
    except (KeyError, TypeError, ValueError):
        return None


def _parse_ev(line: str) -> tuple[str, float, float] | None:
    m = EV_RE.search(line)
    if not m:
        return None
    try:
        return m.group(1), float(m.group(2)), float(m.group(3))
    except ValueError:
        return None


def _parse_snag(line: str) -> tuple[float, float] | None:
    m = SNAG_RE.search(line)
    if not m:
        return None
    try:
        return float(m.group(1)), float(m.group(2))
    except ValueError:
        return None


def _stop_reason(nav: str, snag_in_interval: bool) -> str:
    if snag_in_interval:
        return "snag_hop"
    n = (nav or "").lower()
    if n == "planning":
        return "planning"
    if n in ("unavailable", "walkout"):
        return "stuck"
    return "other"


def parse_run_log(path: Path | str) -> dict[str, Any]:
    """Parse run.log; return scorecard dict. Never raises on garbage lines."""
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    flights: list[dict[str, Any]] = []
    events: list[tuple[str, float, float]] = []
    snag_xy: list[tuple[float, float]] = []
    # Ordered stream for snag-in-interval: (kind, payload)
    # kind 'flight' payload index into flights; kind 'snag' after prior flight
    stream: list[tuple[str, Any]] = []

    for line in text.splitlines():
        fl = _parse_flight(line)
        if fl is not None:
            flights.append(fl)
            stream.append(("flight", len(flights) - 1))
            continue
        ev = _parse_ev(line)
        if ev is not None:
            events.append(ev)
            continue
        sn = _parse_snag(line)
        if sn is not None:
            snag_xy.append(sn)
            stream.append(("snag", sn))
            continue
        # STALL lines tolerated (no field use yet)
        STALL_RE.search(line)

    duration_s = 0.0
    distance_yd = 0.0
    stopped_by: dict[str, float] = defaultdict(float)
    stopped_total = 0.0
    stutter_s = 0.0
    expected_yd = 0.0
    swim_s = 0.0
    hp_loss_by_bin: dict[int, float] = defaultdict(float)
    xts: list[float] = []

    # Map stream index: for each consecutive flight pair, any SNAG between them
    snag_between: dict[tuple[int, int], bool] = {}
    last_fi: int | None = None
    pending_snag = False
    for kind, payload in stream:
        if kind == "snag":
            pending_snag = True
        else:
            fi = int(payload)
            if last_fi is not None:
                snag_between[(last_fi, fi)] = pending_snag
            pending_snag = False
            last_fi = fi

    for i, fl in enumerate(flights):
        xt = fl["xt"]
        if xt is not None and xt >= 0:
            xts.append(float(xt))
        if i == 0:
            continue
        prev = flights[i - 1]
        dt = float(fl["t"]) - float(prev["t"])
        if dt < 0:
            dt = 0.0
        d = planar(prev["x"], prev["y"], fl["x"], fl["y"])
        distance_yd += d
        if d < 1.0 and dt > 0:
            reason = _stop_reason(
                str(fl.get("nav") or prev.get("nav") or ""),
                snag_between.get((i - 1, i), False),
            )
            stopped_by[reason] += dt
            stopped_total += dt
        # Sub-sample stutter: stop-and-go faster than the FLIGHT cadence
        # shows displacement every sample and NEVER trips the stopped
        # counter, yet it can halve the run (post-sync lease metronome
        # 2026-08-13: 3.3 yd/s at "stopped 7.8s"). Compare each sample's
        # pace against the active form's expected speed; count samples
        # under 70% as stuttered time and accumulate the expected-pace
        # denominator for a whole-run duty cycle.
        form_id = int(fl.get("form") or 0)
        expected = (
            (10.4 if form_id == 4 else 4.7)
            if fl.get("swim")
            else (9.8 if form_id == 3 else 7.0)
        )
        if dt > 0:
            expected_yd += expected * dt
            if 1.0 <= d < 0.7 * expected * dt:
                stutter_s += dt
        if fl.get("swim") and str(fl.get("beat") or "") != "-" and dt > 0:
            swim_s += dt
        hp0, hp1 = int(prev.get("hp", -1)), int(fl.get("hp", -1))
        if hp0 >= 0 and hp1 >= 0 and hp1 < hp0:
            loss = float(hp0 - hp1)
            bin_key = int(math.floor(float(fl["x"]) / 100.0) * 100)
            hp_loss_by_bin[bin_key] += loss

    if len(flights) >= 2:
        duration_s = max(0.0, float(flights[-1]["t"]) - float(flights[0]["t"]))
    elif len(flights) == 1:
        duration_s = 0.0

    avg_speed = (distance_yd / duration_s) if duration_s > 0 else 0.0

    cross_track = {
        "p50": percentile(xts, 50) if xts else None,
        "p95": percentile(xts, 95) if xts else None,
        "max": max(xts) if xts else None,
    }

    ev_counts: Counter[str] = Counter(t for t, _, _ in events)
    events_out = {
        "counts": dict(sorted(ev_counts.items())),
        "list": [[t, x, y] for t, x, y in events],
    }

    worst_bins = sorted(
        ((b, loss) for b, loss in hp_loss_by_bin.items() if loss > 0),
        key=lambda kv: (-kv[1], kv[0]),
    )[:5]
    hp_map = {
        "by_bin": {str(b): loss for b, loss in sorted(hp_loss_by_bin.items())},
        "worst5": [[b, loss] for b, loss in worst_bins],
    }

    snag_clusters: Counter[tuple[int, int]] = Counter()
    for x, y in snag_xy:
        cx = int(math.floor(x / 50.0) * 50)
        cy = int(math.floor(y / 50.0) * 50)
        snag_clusters[(cx, cy)] += 1
    snags = {
        "total": len(snag_xy),
        "clusters": [
            {"x": cx, "y": cy, "n": n}
            for (cx, cy), n in sorted(
                snag_clusters.items(), key=lambda kv: (-kv[1], kv[0])
            )
        ],
    }

    warnings: list[str] = []
    idle_frac = (stopped_total / duration_s) if duration_s > 0 else 0.0
    if duration_s > 0 and idle_frac > 0.15:
        warnings.append(
            f"WARN idle: stopped {stopped_total:.1f}s / {duration_s:.1f}s "
            f"({idle_frac:.1%})"
        )
    pace_frac = (distance_yd / expected_yd) if expected_yd > 0 else 1.0
    if expected_yd > 0 and pace_frac < 0.7:
        warnings.append(
            f"WARN pace: {pace_frac:.1%} of form speed "
            f"(stutter {stutter_s:.1f}s) — a passing run can still be "
            f"crawling; see the 2026-08-13 lease metronome"
        )
    p95 = cross_track["p95"]
    if p95 is not None and p95 > 25:
        warnings.append(f"WARN cross_track: p95={p95:.1f} yd (>25)")
    for t, x, y in events:
        if t == "unplanned_swim":
            warnings.append(
                f"WARN unplanned_swim: at ({x:.1f}, {y:.1f})"
            )
            break
    for t, x, y in events:
        if t == "clip":
            warnings.append(f"WARN clip: at ({x:.1f}, {y:.1f})")
            break
    for b, loss in worst_bins:
        if loss > 800:
            warnings.append(
                f"WARN hp: bin x={b} loss={loss:.0f} (>800)"
            )
            break

    return {
        "duration_s": round(duration_s, 3),
        "distance_yd": round(distance_yd, 3),
        "avg_speed": round(avg_speed, 3),
        "stopped_s_total": round(stopped_total, 3),
        "stopped_s_by_reason": {
            k: round(v, 3) for k, v in sorted(stopped_by.items())
        },
        "stutter_s": round(stutter_s, 3),
        "pace_frac": round(
            (distance_yd / expected_yd) if expected_yd > 0 else 1.0, 4
        ),
        "cross_track": {
            k: (round(v, 3) if isinstance(v, float) else v)
            for k, v in cross_track.items()
        },
        "events": events_out,
        "swim_s": round(swim_s, 3),
        "hp_map": hp_map,
        "snags": snags,
        "warnings": warnings,
    }


def format_table(sc: dict[str, Any]) -> str:
    lines = [
        "=== traverse scorecard ===",
        f"duration_s   {sc.get('duration_s')}",
        f"distance_yd  {sc.get('distance_yd')}",
        f"avg_speed    {sc.get('avg_speed')}",
        f"stopped_s    {sc.get('stopped_s_total')}  "
        f"{sc.get('stopped_s_by_reason')}",
        f"stutter_s    {sc.get('stutter_s')}  pace_frac={sc.get('pace_frac')}",
        f"cross_track  {sc.get('cross_track')}",
        f"swim_s       {sc.get('swim_s')}",
        f"events       {sc.get('events', {}).get('counts')}",
        f"snags        total={sc.get('snags', {}).get('total')}  "
        f"{sc.get('snags', {}).get('clusters')}",
        f"hp worst5    {sc.get('hp_map', {}).get('worst5')}",
    ]
    for w in sc.get("warnings") or []:
        lines.append(w)
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("run_log", type=Path, help="path to run.log")
    p.add_argument("--json", type=Path, dest="json_out", help="write dict JSON")
    args = p.parse_args(argv)
    if not args.run_log.is_file():
        print(f"error: not a file: {args.run_log}", file=sys.stderr)
        return 2
    sc = parse_run_log(args.run_log)
    print(format_table(sc))
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(
            json.dumps(sc, indent=2) + "\n", encoding="utf-8"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
