#!/usr/bin/env bash
# Build tools/libpetrel.so — in-process Lua strategy for the player (dynlib).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/tools/libpetrel.so}"
mkdir -p "$(dirname "$OUT")"
# Prefer nix lua5.3 for headers + lib.
export PETREL_LUA_PREFIX
PETREL_LUA_PREFIX="$(nix shell nixpkgs#lua5_3 --command sh -c 'dirname $(dirname $(which lua))')"
echo "[libpetrel] LUA_PREFIX=$PETREL_LUA_PREFIX"
echo "[libpetrel] out=$OUT"
cd "$ROOT"
nix shell nixpkgs#lua5_3 --command nim c \
  --app:lib \
  --noMain:on \
  --nimcache:"$ROOT/local_data/nimcache-libpetrel" \
  -d:release \
  -d:LuaPrefix="$PETREL_LUA_PREFIX" \
  --passC:"-I$PETREL_LUA_PREFIX/include" \
  --passL:"-L$PETREL_LUA_PREFIX/lib -llua -lm -ldl" \
  -o:"$OUT" \
  src/petrel/c_api.nim
echo "[libpetrel] built $OUT"
ls -la "$OUT"
