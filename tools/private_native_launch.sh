#!/usr/bin/env bash
# Start a home seat's native player, optionally from a pinned prepared client.
#
#   tools/private_native_launch.sh <launcher args...>
#
# Runs inside the Army dev shell with the fork checkout as cwd, in place of
# `nim r tools/launch_nim_player.nim -- <launcher args...>`.
#
# Without $SHADOW_SEAT_DIR/native-release.json this execs exactly that command,
# so the launcher keeps building and preparing the current checkout.
#
# With the manifest present the seat runs the pinned executable directly and
# never compiles. The manifest is one JSON object:
#
#   {
#     "executable": "/abs/dir/unheaded_player",
#     "executable_sha256": "<64 lowercase hex>",
#     "navigation_sha256": "<64 lowercase hex>",
#     "source": "...", "source_revision": "...", "fingerprint": "..."
#   }
#
# The other keys are optional strings; "source_commit" is accepted as an alias
# of "source_revision" (both present must agree). Any other key, a non-string
# value or a control character is refused. jq keeps the last of duplicate keys,
# so duplicates are not detected. The executable must be an absolute,
# symlink-free, regular executable file with libcoworld-navigation.so beside it
# (the client loads navigation from its own directory), and both files must
# match their hashes. Any manifest problem refuses the launch; there is no
# fallback to building the checkout.
#
# Pin mode reproduces the launcher's command for a renderer-free embedded
# lua-bot only: it requires --controller=embedded --presentation=unheaded
# --bot=lua-bot, --lua-status-dir=$SHADOW_SEAT_DIR/status and
# --character-name equal to the seat directory name. --owner=home-<seat> is
# launcher-only and is dropped; every other launcher-only option is refused.
# Like the launcher it sets COWORLD_FRAME_BUDGET_REPORT_PATH
# (<status dir>/frame-budget.json) and WOW_SDK_NIM_RUNTIME_DIR
# ($COWORLD_PLAYER_OBSERVER_DIR/lua-bot) only when absent, and always sets
# COWORLD_CHECKOUT_REVISION to the manifest revision (empty when the manifest
# has none), since the pinned binary, not the checkout, is what runs.
# Argument values and manifest contents are never printed.
set -euo pipefail

die() {
  echo "private-native-launch: error: $*" >&2
  exit 1
}

seat_dir="${SHADOW_SEAT_DIR:-}"
manifest=""
if [ -n "$seat_dir" ]; then
  manifest="$seat_dir/native-release.json"
fi

if [ -z "$manifest" ] || { [ ! -e "$manifest" ] && [ ! -L "$manifest" ]; }; then
  exec nim r tools/launch_nim_player.nim -- "$@"
fi

[ -f "$manifest" ] && [ ! -L "$manifest" ] ||
  die "manifest is not a regular file: $manifest"
command -v jq >/dev/null || die "jq is required to read $manifest"

# Prints "error" and a reason, or "ok" followed by executable,
# executable_sha256, navigation_sha256 and revision, one per line (values hold
# no control characters), then "end".
manifest_filter='
  def hex64: type == "string" and test("^[0-9a-f]{64}$");
  ["executable", "executable_sha256", "navigation_sha256"] as $required
  | ($required + ["source", "source_revision", "source_commit", "fingerprint"]) as $allowed
  | if length != 1 or (.[0] | type) != "object" then ["error", "must be exactly one JSON object"]
    else .[0]
    | ([to_entries[] | select(.value | type != "string") | .key]) as $nonstring
    | if (keys - $allowed | length) > 0 then ["error", "has an unknown key"]
      elif ($required - keys | length) > 0 then ["error", "is missing " + ($required - keys)[0]]
      elif ($nonstring | length) > 0 then ["error", $nonstring[0] + " must be a string"]
      elif any(.[]; explode | any(. < 32 or . == 127)) then ["error", "has a control character"]
      elif (.executable_sha256 | hex64 | not) or (.navigation_sha256 | hex64 | not) then
        ["error", "hashes must be 64 lowercase hex characters"]
      elif (.executable | startswith("/") | not) then ["error", "executable must be an absolute path"]
      elif has("source_revision") and has("source_commit") and .source_revision != .source_commit then
        ["error", "source_revision and source_commit disagree"]
      else ["ok", .executable, .executable_sha256, .navigation_sha256,
        (.source_revision // .source_commit // "")]
      end
    end
  | .[], "end"'
parsed=$(jq -r -s "$manifest_filter" <"$manifest" 2>/dev/null) ||
  die "manifest is not valid JSON: $manifest"
mapfile -t fields <<<"$parsed"
if [ "${fields[0]:-}" = error ] && [ "${#fields[@]}" -eq 3 ]; then
  die "manifest ${fields[1]}: $manifest"
fi
[ "${fields[0]:-}" = ok ] && [ "${#fields[@]}" -eq 6 ] && [ "${fields[5]}" = end ] ||
  die "manifest rejected: $manifest"
exe="${fields[1]}"
exe_sha="${fields[2]}"
nav_sha="${fields[3]}"
source_revision="${fields[4]}"

[ -f "$exe" ] && [ ! -L "$exe" ] || die "pinned executable is not a regular file: $exe"
[ -x "$exe" ] || die "pinned executable is not executable: $exe"
# The client resolves its own directory through /proc/self/exe, so any symlink
# in the path would make it load a navigation library other than the one hashed.
[ "$(realpath -e -- "$exe")" = "$exe" ] ||
  die "pinned executable path is not canonical (symlink or ./..): $exe"
nav="$(dirname -- "$exe")/libcoworld-navigation.so"
[ -f "$nav" ] && [ ! -L "$nav" ] || die "navigation library missing beside executable: $nav"

actual=$(sha256sum -- "$exe" | cut -d' ' -f1)
[ "$actual" = "$exe_sha" ] || die "pinned executable hash mismatch: $exe"
actual=$(sha256sum -- "$nav" | cut -d' ' -f1)
[ "$actual" = "$nav_sha" ] || die "navigation library hash mismatch: $nav"

seat="$(basename -- "$seat_dir")"
status_dir=""
controller=""
presentation=""
bot=""
character=""
seen=" "
forward=()
position=0
for arg in "$@"; do
  position=$((position + 1))
  name="${arg%%=*}"
  # Only an option-shaped name is safe to echo; a stray value may be a secret.
  [[ "$name" =~ ^--[a-z][a-z0-9-]{0,40}$ ]] || name="argument #$position"
  case "$arg" in
    --controller=* | --presentation=* | --bot=* | --owner=* | --lua-repo=* | \
      --lua-entry=* | --lua-status-dir=* | --username=* | --password=* | \
      --character-name=* | --assets=*)
      value="${arg#*=}"
      [ -n "$value" ] || die "pin mode: $name needs a value"
      ;;
    --skip-cinematic) value="" ;;
    *) die "pin mode: unsupported $name" ;;
  esac
  case "$seen" in *" $name "*) die "pin mode: $name given more than once" ;; esac
  seen="$seen$name "
  case "$name" in
    --controller) controller="$value" ;;
    --presentation) presentation="$value" ;;
    --bot) bot="$value" ;;
    --lua-status-dir) status_dir="$value" ;;
    --character-name) character="$value" ;;
    --owner)
      [ "$value" = "home-$seat" ] || die "pin mode: --owner must be home-$seat"
      continue
      ;;
  esac
  forward+=("$arg")
done

[ "$controller" = embedded ] || die "pin mode requires --controller=embedded"
[ "$presentation" = unheaded ] || die "pin mode requires --presentation=unheaded"
[ "$bot" = lua-bot ] || die "pin mode requires --bot=lua-bot"
[ "$status_dir" = "$seat_dir/status" ] ||
  die "pin mode requires --lua-status-dir=$seat_dir/status"
[ "$character" = "$seat" ] || die "pin mode requires --character-name=$seat"
[ -n "${COWORLD_PLAYER_OBSERVER_DIR:-}" ] ||
  die "pin mode requires COWORLD_PLAYER_OBSERVER_DIR"

if [ -z "${COWORLD_FRAME_BUDGET_REPORT_PATH:-}" ]; then
  export COWORLD_FRAME_BUDGET_REPORT_PATH="$status_dir/frame-budget.json"
fi
if [ -z "${WOW_SDK_NIM_RUNTIME_DIR:-}" ]; then
  export WOW_SDK_NIM_RUNTIME_DIR="$COWORLD_PLAYER_OBSERVER_DIR/lua-bot"
fi
export COWORLD_CHECKOUT_REVISION="$source_revision"

echo "private-native-launch: pinned $exe (sha256 ${exe_sha:0:12}, nav ${nav_sha:0:12})" >&2
exec "$exe" "${forward[@]}"
