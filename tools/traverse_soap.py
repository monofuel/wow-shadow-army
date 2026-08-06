#!/usr/bin/env python3
"""Local-only SOAP overrides for Kalimdor traverse backends.

Durable path:
  1) JSON file tools/traverse_soap_overrides.json (source of truth)
  2) Env VMANGOS_MANGOSD_CONFIG_OVERRIDES (merged by container configure_vmangos)
  3) Optional patch of league config.json vmangos.mangosd_config_overrides

Fair-play prove does not depend on SOAP; this is local debug only.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OVERRIDES = ROOT / "tools" / "traverse_soap_overrides.json"
RUNTIME_ROOT = Path(
    os.environ.get(
        "TRAVERSE_RUNTIME_ROOT",
        str(Path.home() / ".coworld" / "player" / "launcher_units" / "runtime"),
    )
)


def load_overrides(path: Path | None = None) -> dict[str, Any]:
    p = path or DEFAULT_OVERRIDES
    data = json.loads(p.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not data:
        raise ValueError(f"overrides file must be a non-empty object: {p}")
    # Normalize JSON numbers that should stay ints for conf (Enabled/Port).
    out: dict[str, Any] = {}
    for key, value in data.items():
        out[str(key)] = value
    return out


def overrides_env_json(overrides: dict[str, Any] | None = None) -> str:
    return json.dumps(overrides if overrides is not None else load_overrides(), separators=(",", ":"))


def apply_overrides_to_config(
    config: dict[str, Any],
    overrides: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Merge SOAP overrides into a ScenarioConfig-shaped dict. Mutates and returns config."""
    ovr = overrides if overrides is not None else load_overrides()
    vmangos = config.setdefault("vmangos", {})
    if not isinstance(vmangos, dict):
        raise TypeError("config.vmangos must be an object")
    existing = vmangos.get("mangosd_config_overrides")
    if existing is None:
        merged: dict[str, Any] = {}
    elif isinstance(existing, dict):
        merged = dict(existing)
    else:
        raise TypeError("vmangos.mangosd_config_overrides must be an object")
    merged.update(ovr)
    vmangos["mangosd_config_overrides"] = merged
    return config


def patch_config_file(path: Path, overrides: dict[str, Any] | None = None) -> bool:
    """Patch one config.json. Returns True if file content changed."""
    original = path.read_text(encoding="utf-8")
    config = json.loads(original)
    if not isinstance(config, dict):
        raise TypeError(f"{path}: root must be an object")
    apply_overrides_to_config(config, overrides)
    new_text = json.dumps(config, indent=2) + "\n"
    if new_text == original:
        return False
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(new_text, encoding="utf-8")
    os.chmod(tmp, path.stat().st_mode & 0o777)
    os.replace(tmp, path)
    return True


def find_traverse_configs() -> list[Path]:
    found: list[Path] = []
    # Launcher unit runtimes (prepare writes here for native league).
    if RUNTIME_ROOT.is_dir():
        found.extend(sorted(RUNTIME_ROOT.glob("*/leagues/traverse/config/config.json")))
    # Checkout-local state dirs if present.
    for base in (
        ROOT / "local_data" / "coworld-config",
        ROOT.parent / "coworld-vanilla-wow" / "local_data",
        ROOT.parent / "coworld-vanilla-wow-fork" / "local_data",
    ):
        if not base.exists():
            continue
        found.extend(sorted(base.glob("**/leagues/traverse/config/config.json")))
        # bare coworld-config used by compose default
        candidate = base / "config.json"
        if candidate.is_file() and candidate not in found:
            # only treat as traverse if scenario looks like traverse
            try:
                d = json.loads(candidate.read_text(encoding="utf-8"))
                if d.get("scenario_id") == "kalimdor-south-to-north" or (
                    isinstance(d.get("players"), list)
                    and any(
                        (p.get("character") or {}).get("name") == "Northbound"
                        for p in d["players"]
                        if isinstance(p, dict)
                    )
                ):
                    found.append(candidate)
            except (OSError, json.JSONDecodeError):
                pass
    # de-dupe preserving order
    seen: set[str] = set()
    out: list[Path] = []
    for p in found:
        key = str(p.resolve())
        if key not in seen:
            seen.add(key)
            out.append(p)
    return out


def cmd_env(_: argparse.Namespace) -> int:
    sys.stdout.write(overrides_env_json())
    sys.stdout.write("\n")
    return 0


def cmd_export_shell(_: argparse.Namespace) -> int:
    # Safe for eval "$(tools/traverse_soap.py export-shell)"
    payload = overrides_env_json()
    # single-quoted shell string
    escaped = payload.replace("'", "'\"'\"'")
    print(f"export VMANGOS_MANGOSD_CONFIG_OVERRIDES='{escaped}'")
    return 0


def cmd_patch(args: argparse.Namespace) -> int:
    overrides = load_overrides()
    paths = [Path(p) for p in args.paths] if args.paths else find_traverse_configs()
    if not paths:
        print("error: no traverse config.json found to patch", file=sys.stderr)
        return 1
    changed = 0
    for path in paths:
        if not path.is_file():
            print(f"skip missing {path}", file=sys.stderr)
            continue
        did = patch_config_file(path, overrides)
        print(f"{'patched' if did else 'unchanged'} {path}")
        if did:
            changed += 1
    print(f"[traverse-soap] overrides={overrides} files_changed={changed}")
    return 0


def cmd_show(_: argparse.Namespace) -> int:
    print(json.dumps(load_overrides(), indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("show", help="Print overrides JSON")
    sub.add_parser("env", help="Print compact JSON for VMANGOS_MANGOSD_CONFIG_OVERRIDES")
    sub.add_parser("export-shell", help="Print export line for eval")
    p_patch = sub.add_parser("patch", help="Merge overrides into traverse config.json file(s)")
    p_patch.add_argument("paths", nargs="*", help="config.json paths (default: discover)")

    args = parser.parse_args()
    if args.cmd == "show":
        return cmd_show(args)
    if args.cmd == "env":
        return cmd_env(args)
    if args.cmd == "export-shell":
        return cmd_export_shell(args)
    if args.cmd == "patch":
        return cmd_patch(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
