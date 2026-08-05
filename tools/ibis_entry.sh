#!/usr/bin/env bash
# Hosted entry for Ibis (army_host --mode=traverse + lua/entry/traverse.lua).
# Observatory sets COWORLD_PLAYER_WS_URL; army_host rewrites /player → /env.
set -euo pipefail
cd /app
export ARMY_MODE="${ARMY_MODE:-traverse}"
if [[ -z "${COWORLD_PLAYER_WS_URL:-}" ]]; then
  echo "ibis_entry: COWORLD_PLAYER_WS_URL is unset" >&2
  echo "  (local PoL still uses: make traverse-pol / army_host --mode=traverse --ws …)" >&2
  exit 1
fi
exec /bin/army_host \
  --mode="${ARMY_MODE}" \
  --ws \
  --verbose \
  --no-audit \
  --pol-min-yards=0 \
  "$@"
