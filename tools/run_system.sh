#!/usr/bin/env bash
# Start The System (wow-shadow-army dashboard + MCP) for systemd user runs.
# Always enters this repo's flake via `nix develop` so openssl/nginx/uv/nim
# match interactive work (no ad-hoc nix-shell -p).
#
# `nim r` recompiles on every start — restart the unit to deploy source edits.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Pin the operator checkout and army root explicitly (no cwd guessing).
export SYSTEM_UPSTREAM_DIR="${SYSTEM_UPSTREAM_DIR:-$(cd "$ROOT/../coworld-vanilla-wow" && pwd)}"
export SYSTEM_ARMY_DIR="${SYSTEM_ARMY_DIR:-$ROOT}"

if ! command -v nix >/dev/null 2>&1; then
  echo "run_system.sh: nix not on PATH" >&2
  exit 1
fi

exec nix develop --command nim r system/system_server.nim
