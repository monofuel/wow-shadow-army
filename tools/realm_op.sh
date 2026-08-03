#!/usr/bin/env bash
# Realm lifecycle entrypoint shared by The System (dashboard) and the Makefile.
#
# Robust to upstream layout churn:
#   - Discovers docker_vmangos_server.py under SYSTEM_UPSTREAM_DIR (candidates
#     first, then a depth-limited find). No hard dependency on one path.
#   - For `up`, preflights the Compose game image: missing image or missing
#     VMaNGOS feature-metadata label ⇒ pass --build (upstream rejects bare
#     `up` without that label). No error-string scraping.
#
# Usage:
#   tools/realm_op.sh up [extra operator args...]
#   tools/realm_op.sh down [extra operator args...]
#   tools/realm_op.sh <any-operator-verb> [...]   # write-config, doctor, …
#
# Env:
#   SYSTEM_UPSTREAM_DIR  — coworld-vanilla-wow checkout (default: sibling of army)
#   SYSTEM_ARMY_DIR      — wow-shadow-army root (default: parent of tools/)
#   VMANGOS_FEATURES_LABEL — docker label key (default matches upstream today)
set -euo pipefail

ARMY_ROOT="${SYSTEM_ARMY_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
if [[ -n "${SYSTEM_UPSTREAM_DIR:-}" ]]; then
  UPSTREAM="$(cd "$SYSTEM_UPSTREAM_DIR" && pwd)"
else
  UPSTREAM="$(cd "$ARMY_ROOT/../coworld-vanilla-wow" && pwd)"
fi
FEATURES_LABEL="${VMANGOS_FEATURES_LABEL:-ai.softmax.coworld.vmangos-features}"

usage() {
  echo "usage: $0 <operator-verb> [args...]  (up auto-adds --build when needed)" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
OP="$1"
shift

discover_operator() {
  local root="$1"
  local candidates=(
    "infra/mangos/vmangos/ops/docker_vmangos_server.py"
    "server/scripts/docker_vmangos_server.py"
    "backend/vmangos/scripts/docker_vmangos_server.py"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$root/$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  # Layout moved again: find by canonical filename, stay inside the checkout.
  local found
  found="$(find "$root" -maxdepth 8 -type f -name 'docker_vmangos_server.py' \
    ! -path '*/.git/*' ! -path '*/__pycache__/*' 2>/dev/null | head -n 1 || true)"
  if [[ -n "$found" ]]; then
    printf '%s\n' "${found#"$root"/}"
    return 0
  fi
  return 1
}

resolve_game_image() {
  # Prefer the image Compose would run; fall back to the historical local tag.
  local compose=""
  local f
  for f in infra/compose.vmangos.yml infra/compose.coworld.yml; do
    if [[ -f "$UPSTREAM/$f" ]]; then
      compose="$f"
      break
    fi
  done
  if [[ -n "$compose" ]]; then
    local img
    img="$(
      docker compose -f "$UPSTREAM/$compose" --profile coworld config --images coworld-game 2>/dev/null \
        | head -n 1 || true
    )"
    if [[ -n "$img" ]]; then
      printf '%s\n' "$img"
      return 0
    fi
  fi
  printf '%s\n' "coworld-vmangos:local"
}

image_needs_build() {
  # Exit 0 when operator `up` should include --build.
  local image="$1"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    return 0
  fi
  local label
  label="$(
    docker image inspect "$image" \
      --format "{{index .Config.Labels \"$FEATURES_LABEL\"}}" 2>/dev/null || true
  )"
  if [[ -z "$label" || "$label" == "<no value>" ]]; then
    return 0
  fi
  return 1
}

if [[ ! -d "$UPSTREAM" ]]; then
  echo "realm_op: upstream missing: $UPSTREAM (set SYSTEM_UPSTREAM_DIR)" >&2
  exit 1
fi

SCRIPT_REL=""
if ! SCRIPT_REL="$(discover_operator "$UPSTREAM")"; then
  echo "realm_op: cannot find docker_vmangos_server.py under $UPSTREAM" >&2
  exit 1
fi

echo "realm_op: army=$ARMY_ROOT upstream=$UPSTREAM operator=$SCRIPT_REL op=$OP" >&2

cd "$UPSTREAM"

case "$OP" in
  up)
    args=(up)
    # Honor an explicit --build from the caller; otherwise preflight the image.
    want_build=0
    for a in "$@"; do
      if [[ "$a" == "--build" ]]; then want_build=1; break; fi
    done
    img="$(resolve_game_image)"
    if [[ "$want_build" -eq 1 ]]; then
      echo "realm_op: caller requested --build for $img" >&2
    elif image_needs_build "$img"; then
      echo "realm_op: image $img missing or lacks label $FEATURES_LABEL → --build" >&2
      args+=(--build)
    else
      echo "realm_op: image $img has feature metadata → up without --build" >&2
    fi
    # Pass through extras (e.g. --smoke, caller's --build).
    args+=("$@")
    exec uv run python "$SCRIPT_REL" "${args[@]}"
    ;;
  *)
    # down, write-config, doctor, … — discovery only, no flag rewriting.
    exec uv run python "$SCRIPT_REL" "$OP" "$@"
    ;;
esac
