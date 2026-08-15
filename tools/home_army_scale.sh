#!/usr/bin/env bash
# Scale-out home seats — roster-driven, STAGGERED rollout.
#
#   tools/home_army_scale.sh start [--from Name] [--only Name,Name] [--gap 25]
#   tools/home_army_scale.sh status
#   tools/home_army_scale.sh stop  [--only Name,Name]
#   tools/home_army_scale.sh provision       # accounts + level-1 characters
#   tools/home_army_scale.sh accounts        # create the realmd accounts only
#
# RUN `provision` BEFORE `start`. The rendered client resolves its character
# with requireExistingCharacter (select-only) and errors on a name that is not
# already on the account, so every seat needs its account row AND its level-1
# character rolled first. Both are sanctioned setup: SOAP account create, then
# a real CMSG_CHAR_CREATE from tools/roll_seat_character.nim in the fork. No DB
# writes, no GM commands, no progress of any kind.
#
# Roster: tools/data/home_army_roster.tsv (character<TAB>account<TAB>class).
# Each row becomes `make seat-start SEAT=… SEAT_USER=… SEAT_CLASS=…`; the
# generic seat targets live in the Makefile next to the original four.
#
# WHY STAGGERED: every seat streams world assets from ONE shared nginx on
# 127.0.0.1:25608, and a burst of simultaneous logins is what wedged Tusk
# (docs/postmortems/2026-08-15-asset-server-connection-drops.md). One seat per
# GAP seconds keeps the settles from overlapping. The first `nim r` also has
# to win the compile-cache race alone — concurrent `nim r` starts on a cold
# cache hit ETXTBSY — so launches are serialized by construction.
#
# GUARDRAILS: the loop re-checks free RAM, load average, and the freshness of
# the ORIGINAL FOUR seats before every launch, and stops early rather than
# brown out a box a human is playing on.
#
# AGENTS.md still binds: account creation is sanctioned setup; characters are
# rolled by the ordinary client flow (no characters-table insert); nothing here
# touches Murist or the original four seats.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
roster="${ARMY_ROSTER:-$repo_dir/tools/data/home_army_roster.tsv}"
home_army_dir="$repo_dir/local_data/home-army"

# Seats that this script must never start, stop, or count as its own.
protected_seats="Shadowfel Igris Tusk Beru"

# Stagger between launches, seconds.
gap="${ARMY_SCALE_GAP:-25}"
# Stop scaling if available RAM drops below this (MiB) …
min_free_mb="${ARMY_SCALE_MIN_FREE_MB:-8192}"
# … or if the 1-minute load average climbs past this. Default ~75% of the
# core count: these seats software-rasterize under Xvfb (see SEAT_HOST_DISPLAY
# in the Makefile), so they are CPU-hungry, and a human is playing on this box.
max_load="${ARMY_SCALE_MAX_LOAD:-$(awk -v n="$(nproc)" 'BEGIN {print int(n * 3 / 4)}')}"
# A seat heartbeat older than this is stale (matches HOME_STATUS_MAX_AGE).
status_max_age="${ARMY_SCALE_STATUS_MAX_AGE:-30}"

only=""
start_from=""

die() { echo "error: $*" >&2; exit 1; }

read_roster() {
  # Emits "name<TAB>account<TAB>class" for each non-comment, non-blank row.
  [ -f "$roster" ] || die "roster not found: $roster"
  local name account class
  while IFS=$'\t' read -r name account class _rest; do
    case "$name" in ''|'#'*) continue ;; esac
    [ -n "$account" ] || die "roster row '$name' has no account"
    [ -n "$class" ] || die "roster row '$name' has no class"
    for p in $protected_seats; do
      [ "$name" = "$p" ] && die "roster names protected seat '$name'"
    done
    if [ -n "$only" ] && ! printf '%s' ",$only," | grep -q ",$name,"; then
      continue
    fi
    printf '%s\t%s\t%s\n' "$name" "$account" "$class"
  done < "$roster"
}

status_age() {
  # Echoes the age in seconds of a seat's status.json, or "-" when absent.
  local f="$home_army_dir/$1/status/status.json"
  if [ -s "$f" ]; then echo $(( $(date +%s) - $(stat -c %Y "$f") )); else echo "-"; fi
}

seat_mode() {
  local f="$home_army_dir/$1/status/status.json"
  if [ -s "$f" ]; then jq -r '.bot.mode // "unknown"' "$f" 2>/dev/null || echo unreadable
  else echo "-"; fi
}

free_mb() { awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo; }
load1() { awk '{print $1}' /proc/loadavg; }

# True when every original seat still has a fresh heartbeat. A seat going
# stale during a ramp is load evidence — pause, do not push through it.
originals_healthy() {
  local seat age
  for seat in $protected_seats; do
    [ -d "$home_army_dir/$seat" ] || continue
    age=$(status_age "$seat")
    [ "$age" = "-" ] && continue
    if [ "$age" -gt "$status_max_age" ]; then
      echo "  original seat $seat is STALE (${age}s)" >&2
      return 1
    fi
  done
  return 0
}

headroom_ok() {
  local mb load
  mb=$(free_mb)
  load=$(load1)
  if [ "$mb" -lt "$min_free_mb" ]; then
    echo "  free RAM ${mb}MiB below floor ${min_free_mb}MiB" >&2
    return 1
  fi
  if awk -v l="$load" -v m="$max_load" 'BEGIN {exit !(l > m)}'; then
    echo "  load1 $load above ceiling $max_load" >&2
    return 1
  fi
  return 0
}

cmd_accounts() {
  local name account class
  while IFS=$'\t' read -r name account class; do
    make -C "$repo_dir" --no-print-directory seat-account \
      SEAT="$name" SEAT_USER="$account" SEAT_PASS="$account"
  done < <(read_roster)
}

# Account row + level-1 character, both through sanctioned setup paths (SOAP
# account create, then real CMSG_CHAR_CREATE). Idempotent, so re-running is
# safe. Must complete before `start`: the rendered client can only SELECT an
# existing character, never create one.
cmd_provision() {
  local name account class
  while IFS=$'\t' read -r name account class; do
    make -C "$repo_dir" --no-print-directory seat-provision \
      SEAT="$name" SEAT_USER="$account" SEAT_PASS="$account" SEAT_CLASS="$class"
  done < <(read_roster)
}

cmd_start() {
  local name account class started=0 skipped=0 seen=0 skipping=no
  [ -n "$start_from" ] && skipping=yes
  echo "roster: $roster (gap ${gap}s, RAM floor ${min_free_mb}MiB, load ceiling ${max_load})"
  while IFS=$'\t' read -r name account class; do
    seen=$((seen + 1))
    if [ "$skipping" = yes ]; then
      if [ "$name" = "$start_from" ]; then skipping=no
      else skipped=$((skipped + 1)); continue; fi
    fi

    if ! headroom_ok || ! originals_healthy; then
      echo "STOP: box degraded before launching $name — $started started, stopping here" >&2
      return 3
    fi

    if [ "$started" -gt 0 ]; then
      echo "-- waiting ${gap}s before $name"
      sleep "$gap"
    fi

    printf '[%s] launching %-10s account=%-9s class=%s  (free=%sMiB load=%s)\n' \
      "$(date -u +%H:%M:%SZ)" "$name" "$account" "$class" "$(free_mb)" "$(load1)"
    make -C "$repo_dir" --no-print-directory seat-start \
      SEAT="$name" SEAT_USER="$account" SEAT_PASS="$account" SEAT_CLASS="$class"
    started=$((started + 1))
  done < <(read_roster)
  echo "launched $started seat(s) (roster rows seen $seen, skipped $skipped)"
}

cmd_stop() {
  local name account class
  while IFS=$'\t' read -r name account class; do
    make -C "$repo_dir" --no-print-directory seat-stop SEAT="$name" || true
  done < <(read_roster)
}

cmd_status() {
  local name account class pid_file state detail age
  printf '%-11s %-9s %-8s %-9s %s\n' SEAT ACCOUNT CLASS STATE DETAIL
  while IFS=$'\t' read -r name account class; do
    pid_file="$home_army_dir/$name/launcher.pid"
    state=stopped; detail=""
    if [ -s "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
      state=starting; detail="pid=$(cat "$pid_file")"
    fi
    age=$(status_age "$name")
    if [ "$state" = starting ] && [ "$age" != "-" ]; then
      if [ "$age" -le "$status_max_age" ]; then
        state=running; detail="$detail mode=$(seat_mode "$name") status_age=${age}s"
      else
        detail="$detail stale_status=${age}s"
      fi
    fi
    printf '%-11s %-9s %-8s %-9s %s\n' "$name" "$account" "$class" "$state" "$detail"
  done < <(read_roster)
}

action="${1:-status}"
shift || true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --only) only="${2:?--only needs a comma-separated seat list}"; shift 2 ;;
    --from) start_from="${2:?--from needs a seat name}"; shift 2 ;;
    --gap) gap="${2:?--gap needs seconds}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$action" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  accounts) cmd_accounts ;;
  provision) cmd_provision ;;
  *) die "unknown action: $action (start|stop|status|accounts|provision)" ;;
esac
