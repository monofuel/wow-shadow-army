#!/usr/bin/env bash
# Headed Nim client on the Traverse league fixture — Softmax's normal way to
# *see* a bot play (one process: window + bot).
#
#   make traverse-headed
#
# This is upstream:
#   launch_nim_player --league=traverse --controller=embedded \
#     --presentation=headed --bot=real-playerbot
#
# That is Softmax's RealPlayerBot inside the headed Nim client (their docs:
# participate-kalimdor-traverse.md "Develop And Prove"). One command, one window.
#
# Our Lua army_host pilot is a *different* Softmax lane (WS /env external policy).
# Softmax runs that headless (reference_player / env host) — no client window on
# that path. Watching that lane live is not this target.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="${UPSTREAM:-$ROOT/../coworld-vanilla-wow}"
WOW_ENV="${WOW_ENV:-$ROOT/tools/wow_env.sh}"
OWNER="${TRAVERSE_OWNER:-${USER:-monofuel}}"

if [[ ! -d "$UPSTREAM" ]]; then
  echo "error: upstream missing: $UPSTREAM" >&2
  exit 1
fi
if [[ ! -f "$WOW_ENV" ]]; then
  echo "error: missing $WOW_ENV" >&2
  exit 1
fi

cd "$UPSTREAM"
# shellcheck source=/dev/null
set +u
. "$WOW_ENV"
set -u

echo "[traverse-headed] Softmax headed Nim client + RealPlayerBot on league=traverse"
echo "[traverse-headed] (one process, one window — not the live-POV spectator)"
echo "[traverse-headed] owner=$OWNER  Ctrl-C to stop"

# nginx on PATH for asset serving (same as Makefile `traverse` target).
exec nix shell nixpkgs#nginx --command sh -c "
  . \"$WOW_ENV\"
  exec nim r tools/launch_nim_player.nim -- \
    --league=traverse \
    --controller=embedded \
    --presentation=headed \
    --bot=real-playerbot \
    --owner=$(printf %q "$OWNER")
"
