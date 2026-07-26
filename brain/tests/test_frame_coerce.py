"""Stdlib-only unit tests for frame_coerce (no pydantic, no upstream import)."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from brain.frame_coerce import (  # noqa: E402
    coerce_action_settled,
    coerce_frame_payload,
    coerce_json_payload,
)


class TestEmptyEnums(unittest.TestCase):
    def test_movement_and_liquid_enums(self):
        out = coerce_frame_payload({"observation": {"movement_mode": "", "liquid_kind": ""}})
        self.assertEqual(out["observation"]["movement_mode"], "unknown")
        self.assertEqual(out["observation"]["liquid_kind"], "unknown")

    def test_service_context_empty_destination_demoted(self):
        """Live frames can flash kind=train with blank destinations."""
        payload = {
            "leveling_context": {
                "service": {
                    "kind": "train",
                    "destination_id": "",
                    "destination_label": "",
                }
            }
        }
        svc = coerce_frame_payload(payload)["leveling_context"]["service"]
        self.assertEqual(svc["kind"], "none")
        self.assertEqual(svc["destination_id"], "")
        self.assertEqual(svc["destination_label"], "")

    def test_leveling_context_min_length_fields(self):
        """The blocker that stopped every Shadowfel frame read."""
        payload = {
            "leveling_context": {
                "profile_id": "unsupported_profile",
                "profile_label": "",
                "strategy_id": "",
                "strategy_label": "",
                "farm_area_id": "",
                "farm_area_label": "",
                "quest_step_id": "",
            }
        }
        ctx = coerce_frame_payload(payload)["leveling_context"]
        for key in (
            "profile_label",
            "strategy_id",
            "strategy_label",
            "farm_area_id",
            "farm_area_label",
        ):
            self.assertEqual(ctx[key], "unknown", key)
        # A non-empty value is never rewritten.
        self.assertEqual(ctx["profile_id"], "unsupported_profile")
        # quest_step_id has no min_length upstream; leave it alone.
        self.assertEqual(ctx["quest_step_id"], "")

    def test_nested_lists_are_walked(self):
        out = coerce_frame_payload({"a": [{"movement_mode": ""}, {"b": 1}]})
        self.assertEqual(out["a"][0]["movement_mode"], "unknown")
        self.assertEqual(out["a"][1]["b"], 1)


class TestActionSettledReconciliation(unittest.TestCase):
    def test_agreeing_values_pass_through(self):
        self.assertEqual(
            coerce_action_settled({"success": True, "reason_code": "ok"}),
            {"success": True, "reason_code": "ok"},
        )
        self.assertEqual(
            coerce_action_settled({"success": False, "reason_code": "movement_blocked"}),
            {"success": False, "reason_code": "movement_blocked"},
        )

    def test_success_with_failure_code_becomes_failure(self):
        out = coerce_action_settled({"success": True, "reason_code": "movement_blocked"})
        self.assertFalse(out["success"])
        self.assertEqual(out["reason_code"], "movement_blocked")

    def test_failure_with_ok_code_becomes_action_rejected(self):
        out = coerce_action_settled({"success": False, "reason_code": "ok"})
        self.assertFalse(out["success"])
        self.assertEqual(out["reason_code"], "action_rejected")

    def test_unknown_or_missing_reason_code(self):
        self.assertEqual(coerce_action_settled({"success": True})["reason_code"], "ok")
        self.assertEqual(
            coerce_action_settled({"success": False, "reason_code": "wat"})["reason_code"],
            "action_rejected",
        )

    def test_coercion_never_invents_a_success(self):
        """Load-bearing: a real disagreement is never resolved into success.

        A *missing/unusable* reason_code is not a disagreement — there the
        boolean is the only signal we have, so it is trusted. A disagreement
        is a well-formed failure code alongside ``success: true``.
        """
        real_codes = ("movement_blocked", "spell_rejected", "unsupported_action",
                      "action_rejected", "unsafe_route")
        for success in (True, False):
            for reason in real_codes + ("ok", "", "bogus"):
                out = coerce_action_settled({"success": success, "reason_code": reason})
                # The model's own invariant must always hold afterwards.
                self.assertEqual(out["success"], out["reason_code"] == "ok")
                if reason in real_codes:
                    self.assertFalse(out["success"], f"{success}/{reason}")

    def test_embedded_in_frame_is_reconciled(self):
        out = coerce_frame_payload(
            {"previous_transition": {"type": "action_settled", "success": True,
                                     "reason_code": "action_rejected"}}
        )
        self.assertFalse(out["previous_transition"]["success"])


class TestJsonPayload(unittest.TestCase):
    def test_roundtrip(self):
        raw = json.dumps({"type": "action_settled", "success": False, "reason_code": "ok"}).encode()
        out = json.loads(coerce_json_payload(raw))
        self.assertEqual(out["reason_code"], "action_rejected")

    def test_non_json_is_returned_untouched(self):
        self.assertEqual(coerce_json_payload(b"not json"), b"not json")

    def test_non_dict_json_untouched(self):
        self.assertEqual(coerce_json_payload(b"[1,2]"), b"[1,2]")


if __name__ == "__main__":
    unittest.main()
