#!/usr/bin/env python3
"""Unit tests for tools/traverse_soap.py (shipped override apply path)."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import traverse_soap  # noqa: E402


class TestTraverseSoap(unittest.TestCase):
    def test_load_overrides_from_repo_file(self) -> None:
        ovr = traverse_soap.load_overrides()
        self.assertEqual(ovr.get("SOAP.Enabled"), 1)
        self.assertEqual(ovr.get("SOAP.IP"), "0.0.0.0")
        self.assertEqual(ovr.get("SOAP.Port"), 7878)

    def test_apply_overrides_to_config_merges(self) -> None:
        cfg = {
            "scenario_id": "kalimdor-south-to-north",
            "vmangos": {
                "mangosd_config_overrides": {"Rate.XP.Kill": 1},
                "simulation_time_scale": 1,
            },
            "players": [],
        }
        out = traverse_soap.apply_overrides_to_config(cfg)
        mo = out["vmangos"]["mangosd_config_overrides"]
        self.assertEqual(mo["Rate.XP.Kill"], 1)
        self.assertEqual(mo["SOAP.Enabled"], 1)
        self.assertEqual(mo["SOAP.IP"], "0.0.0.0")
        self.assertEqual(mo["SOAP.Port"], 7878)

    def test_patch_config_file_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "config.json"
            path.write_text(
                json.dumps(
                    {
                        "scenario_id": "kalimdor-south-to-north",
                        "vmangos": {},
                        "players": [{"character": {"name": "Northbound"}}],
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            self.assertTrue(traverse_soap.patch_config_file(path))
            data = json.loads(path.read_text(encoding="utf-8"))
            mo = data["vmangos"]["mangosd_config_overrides"]
            self.assertEqual(mo["SOAP.Enabled"], 1)
            # second apply is idempotent
            self.assertFalse(traverse_soap.patch_config_file(path))

    def test_cli_env_matches_file(self) -> None:
        proc = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "traverse_soap.py"), "env"],
            check=True,
            capture_output=True,
            text=True,
        )
        env = json.loads(proc.stdout.strip())
        self.assertEqual(env, traverse_soap.load_overrides())


if __name__ == "__main__":
    unittest.main()
