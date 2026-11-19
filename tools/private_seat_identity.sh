#!/usr/bin/env bash
# Refuse to start a home seat unless the private realm already holds exactly
# that character on that account with that class.
#
#   tools/private_seat_identity.sh <character> <account> <class>
#
# Seats only log in to existing characters; nothing here creates, renames or
# edits one. A roster row that drifted from the realm (wrong account, wrong
# class, missing or duplicated name) stops the launch before any policy acts.
# On success prints one line: name, guid, account id, class, level.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <character> <account> <class>" >&2
  exit 2
fi
name="$1"
account="$2"
class="$3"

case "$class" in
  warrior) class_id=1 ;; paladin) class_id=2 ;; hunter) class_id=3 ;;
  rogue) class_id=4 ;; priest) class_id=5 ;; shaman) class_id=7 ;;
  mage) class_id=8 ;; warlock) class_id=9 ;; druid) class_id=11 ;;
  *) echo "error: unknown class '$class'" >&2; exit 2 ;;
esac
case "$name$account" in
  *[!A-Za-z0-9]*) echo "error: character and account must be alphanumeric" >&2; exit 2 ;;
esac

container="${VMANGOS_GAME_CONTAINER:-coworld-vmangos-coworld-game-1}"
user="${VANILLA_WOW_MYSQL_USER:-mangos}"
pass="${VANILLA_WOW_MYSQL_PASSWORD:-mangos}"

rows=$(docker exec -e MYSQL_PWD="$pass" "$container" mariadb -h127.0.0.1 -u"$user" -N -B -e \
  "SELECT c.name, c.guid, c.account, UPPER(a.username), c.class, c.level
     FROM characters.characters c JOIN realmd.account a ON a.id = c.account
    WHERE c.name = '$name';")

count=$(printf '%s' "$rows" | grep -c . || true)
if [ "$count" -ne 1 ]; then
  echo "error: private realm has $count characters named $name; refusing to start" >&2
  exit 1
fi
IFS=$'\t' read -r row_name guid account_id username row_class level <<<"$rows"
want_account=$(printf '%s' "$account" | tr 'a-z' 'A-Z')
if [ "$username" != "$want_account" ]; then
  echo "error: $name belongs to account $username, roster says $want_account; refusing to start" >&2
  exit 1
fi
if [ "$row_class" != "$class_id" ]; then
  echo "error: $name is class $row_class, roster says $class ($class_id); refusing to start" >&2
  exit 1
fi
echo "identity: name=$row_name guid=$guid account_id=$account_id account=$username class=$row_class level=$level"
