#!/usr/bin/env python3
"""Report the league score from the last episode.

The bot's own status file is the first source; the client's retained
observation is the fallback, because a run that ends mid-hold may not have
written progress with its final decision.
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def from_status() -> dict | None:
    try:
        bot = json.loads((ROOT / "local_data/lua-bot-status.json").read_text()).get("bot")
        return bot if bot and bot.get("level") is not None else None
    except Exception:
        return None


def from_observation() -> dict | None:
    path = ROOT / "local_data/player/observer/observation.json"
    try:
        observed = json.loads(path.read_text())
        return {
            "level": observed.get("level"),
            "xp": observed.get("xp"),
            "next_level_xp": observed.get("next_level_xp"),
        }
    except Exception:
        return None


def main() -> int:
    progress = from_status() or from_observation()
    if not progress or progress.get("level") is None:
        print("episode score: unknown (no progress recorded)")
        return 0
    level = progress.get("level") or 0
    xp = progress.get("xp") or 0
    nxt = progress.get("next_level_xp") or 1
    print(f"episode score: {level + xp / nxt:.3f} (level {level}, xp {xp}/{nxt})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
