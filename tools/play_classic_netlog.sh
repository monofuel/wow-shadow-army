#!/usr/bin/env bash
# Launch the genuine 1.12 client (tools/play_classic.sh) with a loopback
# packet capture running for the whole session. Realm (3724) + world (8085)
# traffic lands in captures/play-classic-<timestamp>.pcap for offline
# analysis. After auth the 5875 client encrypts world packet HEADERS with
# the session key (bodies are plaintext), and the server OVERWRITES
# account.sessionkey on every login — so the keys are snapshotted to a
# .sessionkey file next to the pcap when the session ends. Without that
# snapshot a capture becomes undecodable after the next login: the packet
# size field lives in the encrypted header, so the stream can't even be
# re-framed. All accounts' keys are saved (bot sessions share these ports).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAPDIR="$REPO_ROOT/captures"
mkdir -p "$CAPDIR"
PCAP="$CAPDIR/play-classic-$(date +%Y%m%d-%H%M%S).pcap"

command -v tcpdump >/dev/null 2>&1 || {
  echo "error: tcpdump not on PATH — run via 'make play-classic-netlog' (flake devshell)" >&2
  exit 1
}
TCPDUMP="$(command -v tcpdump)"

# Capturing on lo needs CAP_NET_RAW and the nix-store tcpdump carries no
# file capabilities, so sudo it. Prime credentials in the foreground first
# so the password prompt doesn't tangle with the backgrounded capture.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
  sudo -v
fi

# -U flushes each packet to the savefile as it arrives (a client crash is
# exactly when the tail of the capture matters most). -Z drops tcpdump back
# to $USER before the savefile opens, so the pcap comes out user-owned.
$SUDO "$TCPDUMP" -i lo -U -Z "$USER" -w "$PCAP" \
  'tcp port 3724 or tcp port 8085' &
CAPTURE_PID=$!

cleanup() {
  if kill -0 "$CAPTURE_PID" 2>/dev/null; then
    # SIGINT makes tcpdump flush and print its packet counts; with sudo the
    # signal must be sent as root (sudo relays it to tcpdump).
    $SUDO kill -INT "$CAPTURE_PID" 2>/dev/null || true
    wait "$CAPTURE_PID" 2>/dev/null || true
  fi
  echo "[netlog] capture saved: $PCAP"
  snapshot_session_keys
}

# The session key is generated at login and only replaced by the NEXT login,
# so snapshotting after the client exits captures the right key. Best-effort:
# a missing container must not eat the pcap-saved message above.
UPSTREAM="$REPO_ROOT/../coworld-vanilla-wow"
COMPOSE_FILE="infra/compose.vmangos.yml"
snapshot_session_keys() {
  local keyfile="${PCAP%.pcap}.sessionkey" cid
  cid="$(cd "$UPSTREAM" 2>/dev/null &&
    docker compose -f "$COMPOSE_FILE" --profile coworld ps -q coworld-game)" || true
  if [ -z "${cid:-}" ]; then
    echo "[netlog] WARNING: coworld-game container not found — session keys" >&2
    echo "[netlog] NOT saved; world (8085) traffic in this pcap becomes" >&2
    echo "[netlog] undecodable after the next login on these accounts." >&2
    return 0
  fi
  if docker exec "$cid" mariadb -umangos -pmangos realmd -N -B -e \
    "SELECT username, sessionkey FROM account WHERE sessionkey IS NOT NULL AND sessionkey != ''" \
    > "$keyfile" 2>/dev/null; then
    echo "[netlog] session keys saved: $keyfile"
  else
    rm -f "$keyfile"
    echo "[netlog] WARNING: session key query failed — keys NOT saved" >&2
  fi
}
trap cleanup EXIT INT TERM

sleep 1
kill -0 "$CAPTURE_PID" 2>/dev/null || {
  echo "error: tcpdump failed to start" >&2
  exit 1
}
echo "[netlog] capturing lo ports 3724/8085 -> $PCAP"

"$REPO_ROOT/tools/play_classic.sh"
