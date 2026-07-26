"""Unit tier: pure accept decision for the party butler (no SDK import)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))


def _should_accept(pending, invite_from, allowlist):
    # Mirror of brain.party_butler.should_accept, imported lazily so the unit
    # tier never pulls the upstream SDK.
    if not pending:
        return False
    return invite_from.strip().lower() in [n.strip().lower() for n in allowlist]


class TestShouldAccept(unittest.TestCase):
    def test_accepts_allowlisted(self):
        self.assertTrue(_should_accept(True, "Murist", ["Murist"]))

    def test_case_and_whitespace_insensitive(self):
        self.assertTrue(_should_accept(True, " murist ", ["MURIST"]))

    def test_rejects_without_pending(self):
        self.assertFalse(_should_accept(False, "Murist", ["Murist"]))

    def test_rejects_stranger(self):
        self.assertFalse(_should_accept(True, "Randomguy", ["Murist"]))

    def test_rejects_empty_inviter(self):
        self.assertFalse(_should_accept(True, "", ["Murist"]))

    def test_matches_real_module_logic(self):
        # Keep the mirror honest if the real module is importable (it guards
        # its SDK import behind ensure_upstream_on_path, so only run when the
        # sibling checkout exists).
        try:
            from brain.party_butler import should_accept
        except Exception:
            self.skipTest("upstream checkout not available")
        cases = [
            (True, "Murist", ["Murist"]),
            (True, "murist", ["Murist"]),
            (False, "Murist", ["Murist"]),
            (True, "Other", ["Murist"]),
            (True, "", ["Murist"]),
        ]
        for case in cases:
            self.assertEqual(should_accept(*case), _should_accept(*case))


if __name__ == "__main__":
    unittest.main()
