#!/usr/bin/env bash
# Build and run the stock environment host natively on this NixOS box.
#
# Why this exists: the local realm image is built from the
# `vmangos_local_runtime` stage, which does NOT ship
# /usr/local/bin/vanilla-wow-env-host. With no env host in the container the
# game's `WS /env` relay closes every attach with code 1011, so our seats
# cannot reach the environment at all. Compiling upstream's own
# environment/host/env_host.nim here and listening on 127.0.0.1:41113 gives
# army_host its direct-TCP path (docs/work-2026-08-04.md).
#
# Usage:
#   tools/env_host.sh build     # compile from the upstream checkout
#   tools/env_host.sh start     # background, log to local_data/env-host.log
#   tools/env_host.sh run       # foreground
#   tools/env_host.sh stop
#   tools/env_host.sh status
#
# `start`/`run` build first when the binary is missing or older than the
# upstream source. Pass FORCE_BUILD=1 to rebuild unconditionally — do that
# after an upstream jump, since the host must match the realm's pin.
set -euo pipefail

ARMY_ROOT="${SYSTEM_ARMY_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
if [[ -n "${SYSTEM_UPSTREAM_DIR:-}" ]]; then
  UPSTREAM="$(cd "$SYSTEM_UPSTREAM_DIR" && pwd)"
else
  UPSTREAM="$(cd "$ARMY_ROOT/../coworld-vanilla-wow" && pwd)"
fi

SRC="$UPSTREAM/environment/host/env_host.nim"
BIN_DIR="$ARMY_ROOT/local_data/bin"
BIN="$BIN_DIR/vanilla-wow-env-host"
LOG="$ARMY_ROOT/local_data/env-host.log"
PIDFILE="$ARMY_ROOT/local_data/env-host.pid"
LIBS_CACHE="$ARMY_ROOT/local_data/env-host-libs.path"
PORT="${ENV_HOST_PORT:-41113}"

# The realm was built with no optional features, so the client define set is
# just the base one (player/Dockerfile: client_defines="-d:sovereigntyClient").
NIM_DEFINES=(
  -d:release
  -d:noGui
  -d:sovereigntyClient
  --stackTrace:on
  --lineTrace:on
  -d:httpAssets=/player/assets
  -d:simulationDataHttp
)

# The binary dlopens libbz2/libGL/X11 at runtime; on NixOS those are not on any
# default loader path, so it dies with "could not load: libbz2.so.1" unless we
# hand it an explicit LD_LIBRARY_PATH. Resolved once and cached.
resolve_libs() {
  if [[ -s "$LIBS_CACHE" ]] && [[ "${FORCE_LIBS:-0}" != "1" ]]; then
    cat "$LIBS_CACHE"
    return 0
  fi
  local attrs=(
    bzip2.out openssl.out zlib.out libglvnd.out
    xorg.libX11.out xorg.libxcb.out xorg.libXau.out xorg.libXdmcp.out
    xorg.libXext.out xorg.libXcursor.out xorg.libXi.out xorg.libXrandr.out
  )
  local paths=() a p
  for a in "${attrs[@]}"; do
    if p="$(nix-build '<nixpkgs>' -A "$a" --no-out-link 2>/dev/null | tail -1)"; then
      [[ -n "$p" ]] && paths+=("$p/lib")
    fi
  done
  if [[ ${#paths[@]} -eq 0 ]]; then
    echo "env_host: could not resolve any runtime libs via nix-build" >&2
    return 1
  fi
  mkdir -p "$(dirname "$LIBS_CACHE")"
  (IFS=:; printf '%s\n' "${paths[*]}" | tee "$LIBS_CACHE")
}

needs_build() {
  [[ "${FORCE_BUILD:-0}" == "1" ]] && return 0
  [[ ! -x "$BIN" ]] && return 0
  [[ "$SRC" -nt "$BIN" ]] && return 0
  return 1
}

do_build() {
  if [[ ! -f "$SRC" ]]; then
    echo "env_host: upstream source missing: $SRC" >&2
    exit 1
  fi
  mkdir -p "$BIN_DIR"
  echo "[env-host] building from $(git -C "$UPSTREAM" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  # -lcrypto/-lssl come from openssl; nix-shell supplies them at link time.
  ( cd "$UPSTREAM" && nix-shell -p openssl --run \
      "nim c ${NIM_DEFINES[*]} --hints:off -o:'$BIN' '$SRC'" )
  echo "[env-host] built: $BIN"
}

is_running() {
  [[ -f "$PIDFILE" ]] || return 1
  local pid
  pid="$(cat "$PIDFILE")"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

case "${1:-}" in
  build)
    do_build
    ;;
  run|start)
    needs_build && do_build
    if is_running; then
      echo "[env-host] already running (pid $(cat "$PIDFILE"))"
      exit 0
    fi
    libs="$(resolve_libs)"
    mkdir -p "$(dirname "$LOG")"
    if [[ "$1" == "run" ]]; then
      exec env LD_LIBRARY_PATH="$libs" "$BIN"
    fi
    env LD_LIBRARY_PATH="$libs" "$BIN" > "$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    for _ in $(seq 1 30); do
      if grep -q "listening on" "$LOG" 2>/dev/null; then
        echo "[env-host] up on 127.0.0.1:$PORT (pid $(cat "$PIDFILE")), log: $LOG"
        exit 0
      fi
      if ! is_running; then
        echo "[env-host] died on startup — last lines:" >&2
        tail -20 "$LOG" >&2
        exit 1
      fi
      sleep 1
    done
    echo "[env-host] did not report 'listening' within 30s; log: $LOG" >&2
    exit 1
    ;;
  stop)
    if is_running; then
      kill "$(cat "$PIDFILE")" && echo "[env-host] stopped"
    else
      echo "[env-host] not running"
    fi
    rm -f "$PIDFILE"
    ;;
  status)
    if is_running; then
      echo "[env-host] running (pid $(cat "$PIDFILE"))"
    else
      echo "[env-host] not running"
      exit 1
    fi
    ;;
  *)
    echo "usage: tools/env_host.sh {build|start|run|stop|status}" >&2
    exit 2
    ;;
esac
