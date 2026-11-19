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

# The persistent realm database lives on a plain host directory (bind mount,
# rsync/backup-friendly) instead of a docker named volume — volumes are how
# the private world got wiped on 2026-08-07. Only realm_op exports this, so
# ephemeral episode realms launched elsewhere keep their own named volumes
# and can never write into the persistent database.
export VMANGOS_DB_DIR="${VMANGOS_DB_DIR:-$ARMY_ROOT/../local_data/vmangos-db/data}"

usage() {
  echo "usage: $0 <operator-verb> [args...]  (up auto-adds --build when needed)" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
OP="$1"
shift

# The original private world has its own audited image and real file-backed
# database. The current upstream Compose file ignores VMANGOS_DB_DIR. Never
# let make/dashboard up replace it with a named-volume realm or newer schema.
# Explicit disposable DB paths retain the existing upstream operator route.
private_db=$(realpath -m "$ARMY_ROOT/../local_data/vmangos-db/data")
if [[ $(realpath -m "$VMANGOS_DB_DIR") == "$private_db" ]]; then
  case "$OP" in
    up|down)
      [[ $# == 0 ]] || { echo "realm_op: private lifecycle does not accept upstream build/reset flags" >&2; exit 2; }
      private_launcher="$ARMY_ROOT/../tools/private_realm.sh"
      [[ -x $private_launcher ]] || {
        echo "realm_op: private launcher missing: $private_launcher; refusing the named-volume fallback" >&2
        exit 1
      }
      if [[ $OP == up ]]; then private_verb=start; else private_verb=stop; fi
      exec nix develop "$ARMY_ROOT" --command bash "$private_launcher" "$private_verb"
      ;;
    *)
      echo "realm_op: private realm supports only up/down; use tools/private_realm.sh check for readiness. Refusing upstream config/reset operations." >&2
      exit 2
      ;;
  esac
fi

# A different DB path is not sufficient isolation: upstream ignores it. Only
# the actual target Compose project separates a disposable realm. Never let
# its up/down replace or remove a container mounting the protected world.
if [[ $OP == up || $OP == down ]]; then
  target_project=${COMPOSE_PROJECT_NAME:-coworld-vmangos}
  containers=$(docker ps -aq --filter "label=com.docker.compose.project=$target_project")
  for container in $containers; do
    mounts=$(docker container inspect "$container" --format '{{range .Mounts}}{{println .Source}}{{end}}')
    if grep -Fxq "$private_db" <<< "$mounts"; then
      echo "realm_op: target project $target_project contains the private file-backed world; refusing the disposable operator route" >&2
      exit 2
    fi
  done
fi

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
  # The feature *key* must exist on the image. An empty value is still valid
  # metadata (upstream may build with no optional features selected); docker
  # `index` returns "" for both missing and empty, so check JSON keys.
  local image="$1"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    return 0
  fi
  local has_key
  has_key="$(
    docker image inspect "$image" --format '{{json .Config.Labels}}' 2>/dev/null \
      | python3 -c "
import json,sys
labs=json.load(sys.stdin) or {}
print('yes' if sys.argv[1] in labs else 'no')
" "$FEATURES_LABEL" 2>/dev/null || echo no
  )"
  if [[ "$has_key" != "yes" ]]; then
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
