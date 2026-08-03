#!/usr/bin/env bash
# Start The System (wow-shadow-army dashboard + MCP) for systemd user runs.
# Mirrors ffxiv_crafter/tools/run_ffxiv_mcp.sh: `nim r` recompiles on every
# start, so a service restart picks up the latest source (restart = deploy).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# nix-ld dynlib paths for NixOS systemd user sessions (no interactive profile).
nix_ld_lib="/run/current-system/sw/share/nix-ld/lib"
export NIX_LD="${NIX_LD:-$nix_ld_lib/ld.so}"
export NIX_LD_LIBRARY_PATH="${NIX_LD_LIBRARY_PATH:-$nix_ld_lib}"
export LD_LIBRARY_PATH="${nix_ld_lib}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Pin the operator checkout and army root explicitly (no cwd guessing).
export SYSTEM_UPSTREAM_DIR="${SYSTEM_UPSTREAM_DIR:-$(cd "$ROOT/../coworld-vanilla-wow" && pwd)}"
export SYSTEM_ARMY_DIR="${SYSTEM_ARMY_DIR:-$ROOT}"

exec nim r system/system_server.nim
