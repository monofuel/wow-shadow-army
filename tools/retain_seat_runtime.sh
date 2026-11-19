#!/usr/bin/env bash
# Keep a stopped seat's last runtime evidence before its next launch replaces it.
#
#   tools/retain_seat_runtime.sh <seat_dir>
#
# Seat start recipes call this after their live-pid guard and before they
# delete anything. Under one rotation id (the UTC stamp, with -N appended when
# that stamp is already taken) it renames launcher.log to launcher.log.<id> and
# copies into retained/<id>/, keeping relative paths, the files a new client
# rewrites or the start recipe deletes:
#
#   status/status.json, control/request.json
#   observer/{heartbeat.json,observation.json,history.jsonl}  (observer publisher)
#   <runtime dir>/{heartbeat.json,runtime.json,finalization.json}
#   <runtime dir>/worker-telemetry.tail.jsonl  (last lines only)
#
# A runtime dir is any observer/<bot> or observer/<league>/<bot> directory
# holding a heartbeat.json or runtime.json; home seats use observer/lua-bot.
# Only that runtime heartbeat carries the typed native_failure of a terminal
# turn, so index.txt records per runtime dir whether one is present, alongside
# sha256 sums. Missing files are skipped. Nothing is deleted, nothing but
# launcher.log is moved, and no existing name is overwritten. Prints one line
# with the id; never prints file contents, since launcher logs can hold login
# arguments.
set -euo pipefail

TelemetryTailLines=20
MaxIdAttempts=100

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <seat_dir>" >&2
  exit 2
fi
if [ ! -d "$1" ]; then
  echo "error: no seat directory: $1" >&2
  exit 2
fi
cd "$1"
seat=$(basename "$PWD")

if [ -s launcher.pid ] && kill -0 "$(cat launcher.pid)" 2>/dev/null; then
  echo "error: $seat is running (pid $(cat launcher.pid)); nothing retained" >&2
  exit 1
fi

files=()
for f in status/status.json control/request.json \
    observer/heartbeat.json observer/observation.json observer/history.jsonl; do
  if [ -f "$f" ]; then files+=("$f"); fi
done
runtime_dirs=()
if [ -d observer ]; then
  while IFS= read -r d; do runtime_dirs+=("$d"); done < <(
    find observer -mindepth 2 -maxdepth 3 -type f \
      \( -name heartbeat.json -o -name runtime.json \) -printf '%h\n' | sort -u)
fi
tails=()
for d in "${runtime_dirs[@]}"; do
  for name in heartbeat.json runtime.json finalization.json; do
    if [ -f "$d/$name" ]; then files+=("$d/$name"); fi
  done
  if [ -s "$d/worker-telemetry.jsonl" ]; then tails+=("$d"); fi
done

has_log=0
if [ -s launcher.log ]; then has_log=1; fi
if [ "${#files[@]}" -eq 0 ] && [ "${#tails[@]}" -eq 0 ] && [ "$has_log" -eq 0 ]; then
  exit 0
fi

umask 077
mkdir -p retained
stamp=$(date -u +%Y%m%dT%H%M%SZ)
id="$stamp"
attempt=0
until [ ! -e "launcher.log.$id" ] && mkdir "retained/$id" 2>/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$MaxIdAttempts" ]; then
    echo "error: no free rotation id for $seat at $stamp" >&2
    exit 1
  fi
  id="$stamp-$attempt"
done
out="retained/$id"

for f in "${files[@]}"; do
  cp -p --parents "$f" "$out/"
done
for d in "${tails[@]}"; do
  mkdir -p "$out/$d"
  tail -n "$TelemetryTailLines" "$d/worker-telemetry.jsonl" \
    >"$out/$d/worker-telemetry.tail.jsonl"
  touch -r "$d/worker-telemetry.jsonl" "$out/$d/worker-telemetry.tail.jsonl"
done

log_name=none
if [ "$has_log" -eq 1 ]; then
  # A hard link fails rather than replacing an existing name.
  ln launcher.log "launcher.log.$id"
  rm launcher.log
  log_name="launcher.log.$id"
fi

summary=""
retained_count=$(( ${#files[@]} + ${#tails[@]} ))
if [ "$retained_count" -eq 0 ]; then
  rmdir "$out"
  rmdir retained 2>/dev/null || true
else
  {
    echo "seat=$seat"
    echo "id=$id"
    echo "retained_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "launcher_log=$log_name"
    for d in "${runtime_dirs[@]}"; do
      state=missing
      if [ -f "$d/heartbeat.json" ]; then
        if ! command -v jq >/dev/null; then
          state=unknown
        elif jq -e '.native_failure != null' "$d/heartbeat.json" >/dev/null 2>&1; then
          state=present
        elif jq -e '.' "$d/heartbeat.json" >/dev/null 2>&1; then
          state=absent
        else
          state=unreadable
        fi
      fi
      echo "native_failure $d=$state"
      summary="$summary $d=$state"
    done
    (cd "$out" && find . -type f ! -name index.txt -printf '%P\n' | sort |
      xargs -r -d '\n' sha256sum)
  } >"$out/index.txt"
fi

echo "retained $seat as $id (log $log_name; $retained_count runtime files; native_failure:${summary:- none})"
