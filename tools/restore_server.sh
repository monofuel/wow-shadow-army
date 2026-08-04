#!/usr/bin/env bash
# Restore realm state from a tools/backup_server.sh backup dir.
#
# Usage:
#   tools/restore_server.sh <backup-dir-or-name> [--yes]
#     <backup-dir-or-name> — full path, or a dir name under
#                            <upstream>/local_data/vmangos-db/backups/
#     --yes                — skip the confirmation prompt (required when
#                            running non-interactively)
#
# Prefers the cold volume copy (vmangos-coworld-db-volume.tar.gz): stops the
# realm, replaces the DB volume contents byte-for-byte, starts the realm.
# Falls back to the SQL dumps (server must come up first, then dumps are
# piped in and the realm is restarted so mangosd reloads world state).
#
# DESTRUCTIVE: current realm DB state is replaced by the backup.
set -euo pipefail

ARMY_ROOT="${SYSTEM_ARMY_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
if [[ -n "${SYSTEM_UPSTREAM_DIR:-}" ]]; then
  UPSTREAM="$(cd "$SYSTEM_UPSTREAM_DIR" && pwd)"
else
  UPSTREAM="$(cd "$ARMY_ROOT/../coworld-vanilla-wow" && pwd)"
fi
REALM_OP="$ARMY_ROOT/tools/realm_op.sh"

CONTAINER="${VMANGOS_GAME_CONTAINER:-coworld-vmangos-coworld-game-1}"
VOLUME="${VMANGOS_DB_VOLUME:-coworld-vmangos_vmangos-coworld-db}"
UTIL_IMAGE="${RESTORE_UTIL_IMAGE:-alpine:latest}"
MYSQL_USER="${VANILLA_WOW_MYSQL_USER:-mangos}"
MYSQL_PASS="${VANILLA_WOW_MYSQL_PASSWORD:-mangos}"
DBS=(characters realmd mangos)

if [[ $# -lt 1 ]]; then
  echo "usage: tools/restore_server.sh <backup-dir-or-name> [--yes]" >&2
  exit 2
fi
arg="$1"
confirm="${2:-}"

if [[ -d "$arg" ]]; then
  backup="$(cd "$arg" && pwd)"
elif [[ -d "$UPSTREAM/local_data/vmangos-db/backups/$arg" ]]; then
  backup="$UPSTREAM/local_data/vmangos-db/backups/$arg"
else
  echo "error: backup dir not found: $arg" >&2
  echo "available:" >&2
  ls -1 "$UPSTREAM/local_data/vmangos-db/backups" >&2 2>/dev/null || true
  exit 1
fi

if [[ ! -f "$backup/manifest.txt" ]]; then
  echo "error: no manifest.txt in $backup — not a backup_server.sh backup" >&2
  exit 1
fi

volume_tar="$backup/vmangos-coworld-db-volume.tar.gz"
if [[ -f "$volume_tar" ]]; then
  mode="volume"
else
  mode="sql"
  for db in "${DBS[@]}"; do
    if [[ ! -f "$backup/$db.sql.gz" ]]; then
      echo "error: $backup has neither a volume tar nor $db.sql.gz" >&2
      exit 1
    fi
  done
fi

echo "[restore-server] backup: $backup"
echo "[restore-server] mode:   $mode restore"
sed 's/^/[restore-server]   manifest: /' "$backup/manifest.txt" | head -6

if [[ "$confirm" != "--yes" ]]; then
  if [[ ! -t 0 ]]; then
    echo "error: non-interactive run — pass --yes to confirm" >&2
    exit 2
  fi
  read -r -p "[restore-server] REPLACE current realm DB with this backup? [y/N] " ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "aborted"; exit 1 ;; esac
fi

wait_healthz() {
  for _ in $(seq 1 30); do
    sleep 10
    if curl -s -m 2 http://127.0.0.1:8080/healthz 2>/dev/null | grep -q '"ok":true'; then
      echo "[restore-server] realm healthy"
      return 0
    fi
  done
  echo "error: realm did not become healthy within 300s" >&2
  return 1
}

if [[ "$mode" == "volume" ]]; then
  echo "[restore-server] stopping realm"
  "$REALM_OP" down
  echo "[restore-server] replacing volume $VOLUME contents"
  # Paths inside the helper container are fixed literals (/from, /restore);
  # deletion never touches host paths.
  docker run --rm \
    -v "$VOLUME":/from \
    -v "$backup":/restore:ro \
    "$UTIL_IMAGE" sh -ec '
      find /from -mindepth 1 -delete
      tar xzf /restore/vmangos-coworld-db-volume.tar.gz -C /from
    '
  echo "[restore-server] starting realm"
  "$REALM_OP" up
  wait_healthz
else
  if ! docker inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null \
      | grep -q true; then
    echo "[restore-server] realm not running — starting it"
    "$REALM_OP" up
    wait_healthz
  fi
  for db in "${DBS[@]}"; do
    echo "[restore-server] restoring $db"
    zcat "$backup/$db.sql.gz" | docker exec -i "$CONTAINER" \
      mariadb -h127.0.0.1 -u"$MYSQL_USER" -p"$MYSQL_PASS" "$db"
  done
  echo "[restore-server] restarting realm so mangosd reloads state"
  "$REALM_OP" down
  "$REALM_OP" up
  wait_healthz
fi

echo "[restore-server] done — realm restored from $(basename "$backup")"
echo "[restore-server] note: the realm runs whatever image is tagged coworld-vmangos:local;"
echo "[restore-server] swap tags (stock-pre-faction-fix / faction-fixed) before restoring if needed."
