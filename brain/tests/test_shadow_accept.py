"""Unit tests for shadow invite-accept helper (no SDK)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from brain.accept_invite import should_accept_invite  # noqa: E402


class TestShouldAcceptInvite(unittest.TestCase):
    def test_accepts_allowlisted(self):
        self.assertTrue(should_accept_invite(True, "Murist", ["Murist"]))

    def test_case_insensitive(self):
        self.assertTrue(should_accept_invite(True, " murist ", ["MURIST"]))

    def test_rejects_empty_allowlist(self):
        self.assertFalse(should_accept_invite(True, "Murist", []))

    def test_rejects_without_pending(self):
        self.assertFalse(should_accept_invite(False, "Murist", ["Murist"]))

    def test_rejects_stranger(self):
        self.assertFalse(should_accept_invite(True, "Random", ["Murist"]))


if __name__ == "__main__":
    unittest.main()
