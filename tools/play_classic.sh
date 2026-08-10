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
WORKSPACE_ROOT="${WOW_WORKSPACE_ROOT:-$(cd "$REPO_ROOT/.." && pwd)}"
SNAPSHOT="${WOW_CLASSIC_SNAPSHOT:-$WORKSPACE_ROOT/wow-classic-data/Coworld-WoW-Classic/client}"
LOCAL="${WOW_CLASSIC_LOCAL:-$REPO_ROOT/local_classic}"
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

# Create or repair links owned by this launcher. A stale link whose old target
# still exists must be compared by target, not merely skipped by `-e`. Real
# files/directories are human overrides and are deliberately preserved.
reconcile_link() {
  local target=$1
  local dest=$2
  if [ -L "$dest" ]; then
    if [ "$(readlink "$dest")" != "$target" ]; then
      ln -sfn "$target" "$dest"
      echo "[play-classic] relinked $dest -> $target"
    fi
  elif [ ! -e "$dest" ]; then
    ln -s "$target" "$dest"
    echo "[play-classic] linked $dest -> $target"
  fi
}

# --- one-time local client assembly (idempotent) ---------------------------
mkdir -p "$CLIENT"
# Data/ is a REAL dir of per-entry symlinks (not one symlink to the snapshot):
# the 1.12 client checks loose files under Data/ before MPQs, and we need a
# writable spot for sound-mute overrides without ever touching the snapshot.
if [ -L "$CLIENT/Data" ]; then
  rm "$CLIENT/Data"
  echo "[play-classic] migrating Data/ symlink -> real dir with entry links"
fi
mkdir -p "$CLIENT/Data"
for f in "$SNAPSHOT/Data"/*; do
  base="$(basename "$f")"
  reconcile_link "$f" "$CLIENT/Data/$base"
done
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
mkdir -p "$CLIENT/Interface/AddOns"
for addon in "$REPO_ROOT"/addons/*/; do
  name="$(basename "$addon")"
  reconcile_link "${addon%/}" "$CLIENT/Interface/AddOns/$name"
done

# Non-GUI verification hook for the idempotent assembly/relink phase.
if [ "${PLAY_CLASSIC_PREPARE_ONLY:-0}" = "1" ]; then
  echo "[play-classic] preparation complete"
  exit 0
fi

# Graphics API: Direct3D under wine (gxApi d3d, no -opengl flag).
# Was hard-forced to OpenGL; monofuel 2026-07-26 A/B — GL + weather particles
# hitch hard on this host; trying d3d instead. Flip back to opengl + `-opengl`
# if d3d is worse.
CONFIG="$CLIENT/WTF/Config.wtf"
GX_API="${WOW_GX_API:-d3d}"
if [ -f "$CONFIG" ]; then
  sed -i "s/^SET gxApi .*/SET gxApi \"$GX_API\"/" "$CONFIG"
  grep -q '^SET gxApi' "$CONFIG" || printf 'SET gxApi "%s"\n' "$GX_API" >> "$CONFIG"
  grep -q '^SET gxWindow' "$CONFIG" || printf 'SET gxWindow "1"\n' >> "$CONFIG"
else
  mkdir -p "$CLIENT/WTF"
  printf 'SET gxApi "%s"\nSET gxWindow "1"\n' "$GX_API" > "$CONFIG"
fi

# Sound: back on the default (dsound) path. The 2026-07-25 WINMM experiment
# (SoundOutputSystem "1") did NOT fix the quest-turn-in crash and became the
# prime suspect for periodic frame stutter — reverted; the crash is handled
# by the loose-file fanfare mute above instead. Delete the experiment's
# lines if a Config.wtf still carries them (the client persists CVars on
# exit).
sed -i '/^SET SoundOutputSystem /d;/^SET SoundBufferSize /d' "$CONFIG"

# --- wine prefix (idempotent) ----------------------------------------------
if [ ! -d "$WINEPREFIX" ]; then
  echo "[play-classic] initializing wine prefix (first run only, ~1min)"
  wineboot --init
fi

# -opengl forces the GL path and overrides Config gxApi. For d3d, launch bare.
cd "$CLIENT"
if [ "$GX_API" = "opengl" ]; then
  echo "[play-classic] launching WoW.exe -opengl (gxApi=$GX_API, realm 127.0.0.1)"
  exec wine WoW.exe -opengl
else
  echo "[play-classic] launching WoW.exe (gxApi=$GX_API, realm 127.0.0.1)"
  exec wine WoW.exe
fi
