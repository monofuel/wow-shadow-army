#!/usr/bin/env bash
# Dump the realm databases (characters/realmd/mangos) from the running game
# container into a dated, labeled directory with a restore manifest.
#
# Usage:
#   tools/backup_server.sh [label]
#     label — optional slug appended to the backup dir name
#             (e.g. `faction-bug-repro`)
#
# Backups land under coworld-vanilla-wow local_data (gitignored data home):
#   <upstream>/local_data/vmangos-db/backups/<UTC timestamp>[-label]/
#
# Restore (per db):
#   zcat <db>.sql.gz | docker exec -i <container> mariadb -h127.0.0.1 \
#     -umangos -pmangos <db>
# then restart the realm so mangosd reloads world state.
set -euo pipefail

ARMY_ROOT="${SYSTEM_ARMY_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
if [[ -n "${SYSTEM_UPSTREAM_DIR:-}" ]]; then
  UPSTREAM="$(cd "$SYSTEM_UPSTREAM_DIR" && pwd)"
else
  UPSTREAM="$(cd "$ARMY_ROOT/../coworld-vanilla-wow" && pwd)"
fi

CONTAINER="${VMANGOS_GAME_CONTAINER:-coworld-vmangos-coworld-game-1}"
DBS=(characters realmd mangos)
MYSQL_USER="${VANILLA_WOW_MYSQL_USER:-mangos}"
MYSQL_PASS="${VANILLA_WOW_MYSQL_PASSWORD:-mangos}"

label="${1:-}"
stamp="$(date -u +%Y%m%d-%H%M%S)"
name="$stamp${label:+-$label}"
backup_root="$UPSTREAM/local_data/vmangos-db/backups"
dest="$backup_root/$name"

if ! docker inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null \
    | grep -q true; then
  echo "error: container '$CONTAINER' is not running" >&2
  exit 1
fi

# Build in a .partial dir and mv into place so an interrupted run never
# leaves something that looks like a complete backup.
partial="$dest.partial"
mkdir -p "$partial"

for db in "${DBS[@]}"; do
  out="$partial/$db.sql.gz"
  echo "[backup-server] dumping $db ..."
  docker exec "$CONTAINER" mariadb-dump -h127.0.0.1 \
    -u"$MYSQL_USER" -p"$MYSQL_PASS" \
    --single-transaction --skip-lock-tables --routines "$db" \
    | gzip > "$out"
  # gzip of an empty/failed dump is ~20 bytes; a real db is far bigger.
  size=$(stat -c%s "$out")
  if [ "$size" -lt 1024 ]; then
    echo "error: $db dump suspiciously small ($size bytes) — aborting" >&2
    exit 1
  fi
  echo "[backup-server]   $db: $(du -h "$out" | cut -f1)"
done

image_id="$(docker inspect "$CONTAINER" --format '{{.Image}}')"
image_tags="$(docker inspect "$image_id" --format '{{join .RepoTags " "}}' 2>/dev/null || true)"
upstream_head="$(git -C "$UPSTREAM" rev-parse HEAD 2>/dev/null || echo unknown)"
upstream_branch="$(git -C "$UPSTREAM" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

cat > "$partial/manifest.txt" << EOF
created_utc: $stamp
label: ${label:-none}
container: $CONTAINER
image_id: $image_id
image_tags: ${image_tags:-none}
upstream_checkout: $UPSTREAM
upstream_branch: $upstream_branch
upstream_head: $upstream_head
databases: ${DBS[*]}
restore: zcat <db>.sql.gz | docker exec -i $CONTAINER mariadb -h127.0.0.1 -u$MYSQL_USER -p<pass> <db>; then restart the realm.
EOF

mv "$partial" "$dest"
echo "[backup-server] done: $dest"
