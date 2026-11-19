#!/usr/bin/env bash
# Serve the fork checkout's current player assets for every home seat.
#
# Home seats share one checkout asset listener. A seat launcher that starts the
# listener itself also stops it when that one seat exits, cutting terrain reads
# for every other seat. This script runs the same nginx command the launcher
# would (from the fork's own `native_support.py prepare`) as the foreground
# process of the `wow-home-assets` user unit, so the listener lives and dies
# with that unit instead of with a seat. Seat launchers then only reuse it.
#
# Usage (inside this repo's dev shell, from `make home-assets-start`):
#   tools/home_assets.sh FORK_CHECKOUT URL_FILE [VERSION_FILE]
# Once preparation succeeds VERSION_FILE (default: assets-version beside
# URL_FILE) receives the prepared asset version, then URL_FILE the served URL.
# Readiness compares that version with what the listener actually serves.
set -euo pipefail

fork="${1:?usage: home_assets.sh FORK_CHECKOUT URL_FILE [VERSION_FILE]}"
url_file="${2:?usage: home_assets.sh FORK_CHECKOUT URL_FILE [VERSION_FILE]}"
version_file="${3:-$(dirname "$url_file")/assets-version}"
cd "$fork"

result="$(mktemp --suffix=.json)"
trap 'rm -f "$result"' EXIT
uv run python player/launch/native_support.py prepare --result="$result" >&2

url="$(jq -r '.local_assets_url' "$result")"
version="$(jq -r '.local_assets_version' "$result")"
mapfile -t command < <(jq -r '.local_assets_command[]' "$result")
if [ -z "$url" ] || [ -z "$version" ] || [ "${#command[@]}" -eq 0 ]; then
	echo "home_assets: prepare did not describe a local asset listener" >&2
	exit 1
fi
port="${url#http://127.0.0.1:}"
port="${port%%/*}"
printf "%s\n" "$version" >"$version_file"
printf "%s\n" "$url" >"$url_file"

# A launcher-owned listener of the same version may still hold the port. Take
# the port over the moment it is released so seats see no meaningful gap.
waited=0
while (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
	if [ "$waited" -eq 0 ]; then
		echo "home_assets: port $port is held by another listener; waiting to take it over" >&2
		waited=1
	fi
	sleep 0.05
done

echo "home_assets: serving asset version $version at $url" >&2
rm -f "$result"
trap - EXIT
exec "${command[@]}"
