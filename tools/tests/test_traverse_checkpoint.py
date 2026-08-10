#!/usr/bin/env python3
"""Unit tests for tools/traverse_checkpoint.py (shipped SOAP tele path)."""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import traverse_checkpoint as tc  # noqa: E402


class TestTraverseCheckpoint(unittest.TestCase):
    def test_resolve_water_entry_from_table(self) -> None:
        pose = tc.resolve_checkpoint("water_entry")
        self.assertEqual(pose["x"], -6784.5)
        self.assertEqual(pose["y"], -4833.9)
        self.assertEqual(pose["z"], 0.7)
        self.assertEqual(pose["map_id"], 1)
        self.assertEqual(pose["tele_name"], "petrel_water_entry")

    def test_primary_course_checkpoints(self) -> None:
        expected = {
            "water_entry": (-6784.5, -4833.9, 0.7),
            "duskwallow_coast": (-4627.01, -4869.45, -2.37),
            "merchant_coast": (-1533.7, -4056.5, -12.3),
            "top_barrens": (1071.6, -2303.4, 91.7),
            "everlook": (6687.333052, -4647.667, 721.678),
        }
        for name, coordinates in expected.items():
            with self.subTest(checkpoint=name):
                pose = tc.resolve_checkpoint(name)
                self.assertEqual(
                    (pose["x"], pose["y"], pose["z"]), coordinates
                )
                self.assertEqual(pose["map_id"], 1)
                self.assertTrue(pose["tele_name"])

        # TODO: add the difficult Everlook cave entrance after capturing its pose.

    def test_spawn_has_no_tele(self) -> None:
        pose = tc.resolve_checkpoint("spawn")
        self.assertIsNone(pose.get("tele_name"))

    def test_unknown_checkpoint_raises(self) -> None:
        with self.assertRaises(KeyError):
            tc.resolve_checkpoint("not_a_real_checkpoint")

    def test_tele_command_format(self) -> None:
        cmd = tc.tele_command("Northbound", "petrel_water_entry")
        self.assertEqual(cmd, "tele name Northbound petrel_water_entry")

    def test_tele_command_rejects_spaces(self) -> None:
        with self.assertRaises(ValueError):
            tc.tele_command("North bound", "petrel_water_entry")

    def test_cli_tele_cmd_uses_shipped_resolver(self) -> None:
        import subprocess

        out = subprocess.check_output(
            [
                sys.executable,
                str(ROOT / "tools" / "traverse_checkpoint.py"),
                "tele-cmd",
                "water_entry",
            ],
            text=True,
        ).strip()
        self.assertEqual(out, "tele name Northbound petrel_water_entry")

    def test_soap_execute_posts_real_command(self) -> None:
        """Drive soap_execute; mock only the network layer, not command build."""
        captured: dict = {}

        class FakeResp:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return (
                    b'<?xml version="1.0"?>'
                    b"<SOAP-ENV:Envelope>"
                    b"<SOAP-ENV:Body>"
                    b"<ns1:executeCommandResponse>"
                    b"<result>You are teleporting Northbound (offline) to petrel_water_entry.</result>"
                    b"</ns1:executeCommandResponse>"
                    b"</SOAP-ENV:Body></SOAP-ENV:Envelope>"
                )

        def fake_urlopen(req, timeout=8.0):
            captured["url"] = req.full_url
            captured["data"] = req.data.decode()
            captured["auth"] = req.headers.get("Authorization") or req.get_header(
                "Authorization"
            )
            return FakeResp()

        pose = tc.resolve_checkpoint("water_entry")
        cmd = tc.tele_command("Northbound", str(pose["tele_name"]))
        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = tc.soap_execute(cmd, url="http://127.0.0.1:7878/")
        self.assertIn("petrel_water_entry", result)
        self.assertIn("tele name Northbound petrel_water_entry", captured["data"])
        self.assertIn("127.0.0.1:7878", captured["url"])

    def test_apply_spawn_skips_tele(self) -> None:
        out = tc.apply_checkpoint("spawn", skip_wait=True)
        self.assertTrue(out["ok"])
        self.assertTrue(out.get("skipped"))


if __name__ == "__main__":
    unittest.main()
