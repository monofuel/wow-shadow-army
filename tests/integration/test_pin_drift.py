"""Pin-drift guard: local upstream checkout must match upstream.lock.

Fails hard when HEAD drifts so integration fixtures stay interpretable
against the same EnvironmentFrame models that captured them.
"""

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
_LOCK = _REPO / "upstream.lock"
_DEFAULT_UPSTREAM = (_REPO.parent / "coworld-vanilla-wow").resolve()

# Paths brain/upstream.py + frame_coerce import (relative to upstream root).
_REQUIRED_UPSTREAM_FILES = (
    "player/__init__.py",
    "player/sdk/__init__.py",
    "player/sdk/nim_control.py",
)


def _parse_lock() -> tuple[str, str]:
    text = _LOCK.read_text(encoding="utf-8").strip()
    if not text:
        raise AssertionError(f"empty lock file: {_LOCK}")
    parts = text.split()
    if len(parts) < 2:
        raise AssertionError(
            f"upstream.lock expected '<name> <sha>', got: {text!r}"
        )
    return parts[0], parts[1]


def _upstream_root() -> Path:
    import os

    return Path(
        os.environ.get("WOW_SHADOW_UPSTREAM", str(_DEFAULT_UPSTREAM))
    ).resolve()


def _git_head(repo: Path) -> str:
    proc = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        raise AssertionError(
            f"cannot read HEAD of upstream checkout {repo}: {err}"
        )
    return proc.stdout.strip()


class TestPinDrift(unittest.TestCase):
    def test_upstream_lock_file_exists(self):
        self.assertTrue(_LOCK.is_file(), f"missing {_LOCK}")

    def test_upstream_checkout_matches_lock(self):
        _name, expected_sha = _parse_lock()
        root = _upstream_root()
        self.assertTrue(
            root.is_dir(),
            f"upstream checkout missing: {root} "
            f"(set WOW_SHADOW_UPSTREAM or place coworld-vanilla-wow as a sibling)",
        )
        actual = _git_head(root)
        if actual != expected_sha and not actual.startswith(expected_sha):
            # Allow short lock SHA if it is a prefix of full HEAD.
            if not (
                expected_sha.startswith(actual)
                or actual.startswith(expected_sha)
            ):
                self.fail(
                    "upstream checkout does not match upstream.lock — "
                    "bump the pin deliberately and re-run integration\n"
                    f"  lock:     {expected_sha}\n"
                    f"  checkout: {actual}\n"
                    f"  path:     {root}"
                )

    def test_required_upstream_files_exist(self):
        root = _upstream_root()
        missing = [
            rel for rel in _REQUIRED_UPSTREAM_FILES if not (root / rel).is_file()
        ]
        self.assertEqual(
            missing,
            [],
            "upstream files brain/upstream.py depends on are missing: "
            + ", ".join(missing),
        )


if __name__ == "__main__":
    unittest.main()
