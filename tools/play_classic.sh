#!/usr/bin/env bash
# Launch the genuine 1.12.1 WoW client under wine against the local realm.
# Invoked via `make play-classic` (inside the flake devshell, which provides
# wine with 32-bit support — WoW.exe is a 32-bit binary).
#
# Layout under local_classic/ (gitignored):
#   client/Data      -> symlink into wow-classic-data (8GB MPQs, immutable)
#   client/WTF, client/Interface, client/*.exe, client/*.dll  = COPIES
#     (the game writes settings into WTF/ and addon state into Interface/;
#      wow-classic-data is a private immutable snapshot — never write there)
#   wineprefix/      = dedicated WINEPREFIX so nothing touches ~/.wine
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNAPSHOT="/home/monofuel/Documents/Projects/Softmax/wow-classic-data/Coworld-WoW-Classic/client"
LOCAL="$REPO_ROOT/local_classic"
CLIENT="$LOCAL/client"
export WINEPREFIX="$LOCAL/wineprefix"
# Skip wine-mono/gecko installers: WoW 1.12 needs neither, and the wineboot
# installer prompt hangs a headless/first run for minutes (verified live).
export WINEDLLOVERRIDES="mscoree,mshtml=${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"

if [ ! -f "$SNAPSHOT/WoW.exe" ]; then
  echo "error: client snapshot missing: $SNAPSHOT" >&2
  exit 1
fi
command -v wine >/dev/null 2>&1 || {
  echo "error: wine not on PATH — run via 'make play-classic' (flake devshell)" >&2
  exit 1
}

# --- one-time local client assembly (idempotent) ---------------------------
mkdir -p "$CLIENT"
if [ ! -e "$CLIENT/Data" ]; then
  ln -s "$SNAPSHOT/Data" "$CLIENT/Data"
  echo "[play-classic] symlinked Data/ from snapshot"
fi
for item in WTF Interface WoW.exe dbghelp.dll fmod.dll ijl15.dll unicows.dll DivxDecoder.dll; do
  if [ ! -e "$CLIENT/$item" ] && [ -e "$SNAPSHOT/$item" ]; then
    cp -r "$SNAPSHOT/$item" "$CLIENT/$item"
    echo "[play-classic] copied $item"
  fi
done

# Local realm, always (snapshot's realmlist points at the old tailnet host).
printf 'set realmlist 127.0.0.1\n' > "$CLIENT/realmlist.wtf"

# Our addons: symlink each addons/* into the client (repo is the source of
# truth; wine follows host symlinks). New addons still need a client restart
# once (TOC scan at launch); code edits only need /console reloadui.
for addon in "$REPO_ROOT"/addons/*/; do
  name="$(basename "$addon")"
  if [ ! -e "$CLIENT/Interface/AddOns/$name" ]; then
    ln -s "${addon%/}" "$CLIENT/Interface/AddOns/$name"
    echo "[play-classic] linked addon $name"
  fi
done

# OpenGL renderer (runs better under wine than the d3d path) + windowed.
CONFIG="$CLIENT/WTF/Config.wtf"
if [ -f "$CONFIG" ]; then
  sed -i 's/^SET gxApi .*/SET gxApi "opengl"/' "$CONFIG"
  grep -q '^SET gxApi' "$CONFIG" || printf 'SET gxApi "opengl"\n' >> "$CONFIG"
  grep -q '^SET gxWindow' "$CONFIG" || printf 'SET gxWindow "1"\n' >> "$CONFIG"
else
  mkdir -p "$CLIENT/WTF"
  printf 'SET gxApi "opengl"\nSET gxWindow "1"\n' > "$CONFIG"
fi

# Sound: force fmod (the client's bundled FMOD 3.x) onto the WINMM/waveOut
# path instead of DirectSound. Wine's dsound mixing is a known-open bug
# (winehq #9358) and the era-canonical vanilla-on-wine fix is
# SoundOutputSystem "1" (FSOUND enum: 0=nosound 1=winmm 2=dsound).
# Deployed 2026-07-25 for a reproducible crash on quest turn-in, right as
# the iQuestComplete fanfare spins up a fresh one-shot stream. Values are
# asserted (sed) rather than appended-once because the client rewrites
# Config.wtf on exit and could persist a dsound value back.
set_cvar() {
  if grep -q "^SET $1 " "$CONFIG"; then
    sed -i "s/^SET $1 .*/SET $1 \"$2\"/" "$CONFIG"
  else
    printf 'SET %s "%s"\n' "$1" "$2" >> "$CONFIG"
  fi
}
set_cvar SoundOutputSystem 1
set_cvar SoundBufferSize 100

# --- wine prefix (idempotent) ----------------------------------------------
if [ ! -d "$WINEPREFIX" ]; then
  echo "[play-classic] initializing wine prefix (first run only, ~1min)"
  wineboot --init
fi

echo "[play-classic] launching WoW.exe -opengl (realm 127.0.0.1, login monofuel/password)"
cd "$CLIENT"
exec wine WoW.exe -opengl
