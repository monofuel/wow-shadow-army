"""Recorded-frame replay: wire MessagePack → real EnvironmentFrame → Lua tools.

No live services. Decodes tests/fixtures/frames/wire_*.bin (kind-6 payload
only) through brain/upstream + frame_coerce, projects with frame_projection,
runs real follow_leader via lua_runner, maps intent. Assertions are
mechanism-shaped (parse, finite self coords, party-absent → hold
leader_not_visible → skip select), derived from fixture capture context
(see tests/fixtures/frames/README.md and *.summary.json party.in_group=false).
"""

from __future__ import annotations

import json
import math
import sys
import unittest
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

_FIXTURES = _REPO / "tests" / "fixtures" / "frames"


def _wire_paths() -> list[Path]:
    paths = sorted(_FIXTURES.glob("wire_*.bin"))
    if not paths:
        raise FileNotFoundError(f"no wire_*.bin under {_FIXTURES}")
    return paths


def _load_summary(wire_path: Path) -> dict | None:
    # Optional: same-index summary is human evidence, not a strict golden.
    idx = wire_path.stem.split("_", 1)[-1]
    summary = _FIXTURES / f"frame_{idx}.summary.json"
    if summary.is_file():
        return json.loads(summary.read_text(encoding="utf-8"))
    return None


class TestWireReplay(unittest.TestCase):
    """End-to-end offline path for each captured EnvironmentFrame wire blob."""

    @classmethod
    def setUpClass(cls):
        # Import after path is set; pulls real pydantic/msgpack via upstream.
        import msgpack

        from brain import lua_runner
        from brain.frame_coerce import coerce_frame_payload
        from brain.frame_projection import project_for_follow_leader
        from brain.intent_mapping import map_intent, mapped_to_factorized_kwargs
        from brain.upstream import EnvironmentFrame

        cls.msgpack = msgpack
        cls.coerce_frame_payload = staticmethod(coerce_frame_payload)
        cls.EnvironmentFrame = EnvironmentFrame
        cls.project_for_follow_leader = staticmethod(project_for_follow_leader)
        cls.lua_runner = lua_runner
        cls.map_intent = staticmethod(map_intent)
        cls.mapped_to_factorized_kwargs = staticmethod(mapped_to_factorized_kwargs)

    def _decode_wire(self, path: Path):
        raw = path.read_bytes()
        self.assertGreater(len(raw), 0, f"empty fixture {path.name}")
        payload = self.coerce_frame_payload(
            self.msgpack.unpackb(raw, raw=False, strict_map_key=True)
        )
        frame = self.EnvironmentFrame.model_validate(payload)
        return frame

    def test_every_wire_fixture_parses_projects_and_holds(self):
        for path in _wire_paths():
            with self.subTest(fixture=path.name):
                self._assert_wire_pipeline(path)

    def _assert_wire_pipeline(self, path: Path) -> None:
        frame = self._decode_wire(path)

        # --- parse contract ---
        self.assertEqual(frame.type, "environment_frame")
        self.assertTrue(
            str(frame.protocol).startswith("vanilla_wow.bot_environment"),
            f"unexpected protocol: {frame.protocol!r}",
        )
        self.assertIsNotNone(frame.observation)
        obs = frame.observation
        party = obs.party
        self.assertIsNotNone(party)

        # Capture context (README + summaries): solo seat, no party formed.
        # Summaries all record in_group=false; wire blobs match that mechanism.
        self.assertFalse(
            party.in_group,
            f"{path.name}: expected party absent (in_group=false); "
            "follow_leader must hold, not chase",
        )

        # --- projection ---
        projection = self.project_for_follow_leader(frame)
        self_unit = projection["self_unit"]
        self.assertIsNotNone(
            self_unit,
            f"{path.name}: projection missing self_unit",
        )
        self.assertIn("x", self_unit)
        self.assertIn("y", self_unit)
        self.assertTrue(
            math.isfinite(float(self_unit["x"])),
            f"{path.name}: self_unit.x not finite: {self_unit['x']!r}",
        )
        self.assertTrue(
            math.isfinite(float(self_unit["y"])),
            f"{path.name}: self_unit.y not finite: {self_unit['y']!r}",
        )
        # Not in group → no leader_unit for Lua (mechanism, not a magic radius).
        self.assertIsNone(
            projection["party"]["leader_unit"],
            f"{path.name}: leader_unit should be absent when not in_group",
        )

        # --- real Lua tool ---
        intent = self.lua_runner.decide("follow_leader", projection)
        self.assertIsNotNone(intent, f"{path.name}: decide returned nil")
        self.assertEqual(intent["kind"], "hold")
        self.assertEqual(
            intent["reason"],
            "leader_not_visible",
            f"{path.name}: party absent ⇒ hold leader_not_visible, got {intent!r}",
        )

        # --- intent mapping yields no select action for hold ---
        mapped = self.map_intent(intent)
        self.assertTrue(mapped.skip, f"{path.name}: hold must skip select")
        self.assertIsNone(mapped.kind)
        self.assertEqual(mapped.reason, "leader_not_visible")
        self.assertIsNone(
            self.mapped_to_factorized_kwargs(mapped),
            f"{path.name}: hold must not produce FactorizedAction kwargs",
        )

        # Soft cross-check against summary when present (entity_count / name).
        summary = _load_summary(path)
        if summary is not None and summary.get("party"):
            self.assertFalse(
                summary["party"].get("in_group", False),
                f"{path.name}: summary claims in_group but capture docs say solo",
            )


if __name__ == "__main__":
    unittest.main()
