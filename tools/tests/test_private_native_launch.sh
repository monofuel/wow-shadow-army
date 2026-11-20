#!/usr/bin/env bash
# Synthetic checks for tools/private_native_launch.sh: no real client, nim or
# realm is touched. A fake executable records its argv and environment.
#
#   bash tools/tests/test_private_native_launch.sh
set -euo pipefail

helper="$(cd "$(dirname "$0")/../.." && pwd)/tools/private_native_launch.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
secret="s3cret-Pass-Value"
fails=0

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

release="$root/pinned release dir"
mkdir -p "$release" "$root/bin" "$root/cwd"
cat >"$release/player" <<'SH'
#!/usr/bin/env bash
{
  printf 'cwd=%s\n' "$PWD"
  printf 'budget=%s\n' "${COWORLD_FRAME_BUDGET_REPORT_PATH-<unset>}"
  printf 'runtime=%s\n' "${WOW_SDK_NIM_RUNTIME_DIR-<unset>}"
  printf 'revision=%s\n' "${COWORLD_CHECKOUT_REVISION-<unset>}"
  printf 'login=%s\n' "${VANILLA_WOW_LOGIN_WS_URL-<unset>}"
  for a in "$@"; do printf 'arg=%s\n' "$a"; done
} >"$TEST_OUT"
SH
chmod +x "$release/player"
printf 'synthetic navigation\n' >"$release/libcoworld-navigation.so"
cat >"$root/bin/nim" <<'SH'
#!/usr/bin/env bash
{ printf 'cwd=%s\n' "$PWD"; for a in "$@"; do printf 'arg=%s\n' "$a"; done; } >"$TEST_OUT"
SH
chmod +x "$root/bin/nim"
exe_sha=$(sha256sum "$release/player" | cut -d' ' -f1)
nav_sha=$(sha256sum "$release/libcoworld-navigation.so" | cut -d' ' -f1)

seat_dir="$root/home army/Tusk"
mkdir -p "$seat_dir/status" "$seat_dir/observer"
manifest="$seat_dir/native-release.json"
out="$root/out"
err="$root/err"

make_args() {
  args=(--controller=embedded --presentation=unheaded --bot=lua-bot
    --owner=home-Tusk
    "--lua-repo=$root/army repo" --lua-entry=home
    "--lua-status-dir=$seat_dir/status"
    --username=TUSKACCT "--password=$secret" --character-name=Tusk
    --skip-cinematic --assets=http://127.0.0.1:9/assets)
}

write_manifest() {
  printf '%s\n' "$1" >"$manifest"
}
good_manifest() {
  write_manifest "{\"executable\": \"$release/player\", \"executable_sha256\": \"$exe_sha\",
    \"navigation_sha256\": \"$nav_sha\", \"source_revision\": \"abc123\", \"fingerprint\": \"fp\"}"
}

run() {
  rm -f "$out" "$err"
  (cd "$root/cwd" && env PATH="$root/bin:$PATH" TEST_OUT="$out" \
    SHADOW_SEAT_DIR="$seat_dir" COWORLD_PLAYER_OBSERVER_DIR="$seat_dir/observer" \
    VANILLA_WOW_LOGIN_WS_URL="ws://login" "$@" "$helper" "${args[@]}") 2>"$err"
}

expect_refused() {
  local label="$1"; shift
  if run "$@"; then fail "$label: exited 0"; return; fi
  if [ -e "$out" ]; then fail "$label: something was executed"; return; fi
  if grep -q "$secret" "$err"; then fail "$label: password printed"; return; fi
  if grep -q "^jq" "$err"; then fail "$label: jq diagnostics leaked"; return; fi
  pass "$label: $(head -n 1 "$err")"
}

# 1. No manifest: the original launcher command, args untouched.
make_args; rm -f "$manifest"
if run; then
  expected=$(printf 'cwd=%s\n' "$root/cwd"; printf 'arg=%s\n' r tools/launch_nim_player.nim -- "${args[@]}")
  if [ "$(cat "$out")" = "$expected" ]; then pass "no manifest runs nim r launcher with original args"
  else fail "no manifest args differ"; fi
else fail "no manifest: exited nonzero"; fi

# 2. Valid pin: owner stripped, order kept, env defaults set, nothing secret printed.
good_manifest; make_args
if run; then
  expected=$(
    printf 'cwd=%s\n' "$root/cwd"
    printf 'budget=%s\n' "$seat_dir/status/frame-budget.json"
    printf 'runtime=%s\n' "$seat_dir/observer/lua-bot"
    printf 'revision=abc123\n'
    printf 'login=ws://login\n'
    for a in "${args[@]}"; do [ "$a" = --owner=home-Tusk ] || printf 'arg=%s\n' "$a"; done
  )
  if [ "$(cat "$out")" = "$expected" ]; then pass "pin forwards args without --owner, sets env, keeps cwd"
  else fail "pin forwarding differs"; diff <(echo "$expected") "$out" || true; fi
  if grep -q "$secret" "$err"; then fail "pin printed password"; else pass "pin does not print password"; fi
else fail "valid pin: exited nonzero ($(cat "$err"))"; fi

# 3. Explicit budget/runtime env wins; the revision always comes from the manifest.
if run COWORLD_FRAME_BUDGET_REPORT_PATH=/x/budget.json WOW_SDK_NIM_RUNTIME_DIR=/x/rt \
    COWORLD_CHECKOUT_REVISION=checkout-head; then
  if grep -qx 'budget=/x/budget.json' "$out" && grep -qx 'runtime=/x/rt' "$out" &&
      grep -qx 'revision=abc123' "$out"; then pass "inherited env kept, revision pinned to manifest"
  else fail "env precedence differs"; fi
else fail "explicit env: exited nonzero"; fi

# 3b. source_commit is accepted as the revision.
write_manifest "{\"executable\": \"$release/player\", \"executable_sha256\": \"$exe_sha\",
  \"navigation_sha256\": \"$nav_sha\", \"source_commit\": \"def456\"}"
if run COWORLD_CHECKOUT_REVISION=checkout-head && grep -qx 'revision=def456' "$out"; then
  pass "source_commit sets the revision"
else fail "source_commit not used as revision"; fi

# 4. Manifest refusals (never falls back to nim).
zero=$(printf '0%.0s' {1..64})
write_manifest '{"executable": '; expect_refused "malformed JSON"
write_manifest '[]'; expect_refused "non-object manifest"
write_manifest "{\"executable\": \"$release/player\", \"executable_sha256\": \"$exe_sha\"}"
expect_refused "missing navigation_sha256"
write_manifest "{\"executable\": \"$release/player\", \"executable_sha256\": 7, \"navigation_sha256\": \"$nav_sha\"}"
expect_refused "non-string hash"
write_manifest "{\"executable\": \"$release/player\", \"executable_sha256\": \"$exe_sha\", \"navigation_sha256\": \"$nav_sha\", \"fingerprint\": 1}"
expect_refused "non-string optional metadata"
write_manifest "{\"executable\": \"$release/player\", \"executable_sha256\": \"$exe_sha\", \"navigation_sha256\": \"$nav_sha\", \"extra\": \"x\"}"
expect_refused "unknown key"
write_manifest "{\"executable\": \"$release/player\", \"executable_sha256\": \"$exe_sha\", \"navigation_sha256\": \"$nav_sha\", \"source_revision\": \"a\", \"source_commit\": \"b\"}"
expect_refused "source_revision and source_commit disagree"
good_manifest; printf '{}\n' >>"$manifest"; expect_refused "second JSON document"
write_manifest "{\"executable\": \"$secret"; expect_refused "malformed manifest holding a secret"
write_manifest "{\"executable\": \"player\", \"executable_sha256\": \"$exe_sha\", \"navigation_sha256\": \"$nav_sha\"}"
expect_refused "relative executable"
write_manifest "{\"executable\": \"$release/player\", \"executable_sha256\": \"$zero\", \"navigation_sha256\": \"$nav_sha\"}"
expect_refused "executable hash mismatch"
write_manifest "{\"executable\": \"$release/player\", \"executable_sha256\": \"$exe_sha\", \"navigation_sha256\": \"$zero\"}"
expect_refused "navigation hash mismatch"
write_manifest "{\"executable\": \"$release/player\", \"executable_sha256\": \"${exe_sha^^}\", \"navigation_sha256\": \"$nav_sha\"}"
expect_refused "uppercase hash"
ln -s "$release/player" "$root/link-player"
write_manifest "{\"executable\": \"$root/link-player\", \"executable_sha256\": \"$exe_sha\", \"navigation_sha256\": \"$nav_sha\"}"
expect_refused "symlinked executable"
write_manifest "{\"executable\": \"$release/../pinned release dir/player\", \"executable_sha256\": \"$exe_sha\", \"navigation_sha256\": \"$nav_sha\"}"
expect_refused "non-canonical executable path"
mv "$release/libcoworld-navigation.so" "$root/nav.bak"
good_manifest; expect_refused "missing navigation library"
mv "$root/nav.bak" "$release/libcoworld-navigation.so"
chmod -x "$release/player"; expect_refused "non-executable"; chmod +x "$release/player"
rm -f "$manifest"; mkdir "$manifest"; expect_refused "manifest is a directory"; rmdir "$manifest"
ln -s "$root/absent.json" "$manifest"; expect_refused "dangling manifest symlink"; rm -f "$manifest"

# 5. Argument refusals in pin mode.
good_manifest
make_args; args[0]=--controller=remote; expect_refused "wrong controller"
make_args; args[1]=--presentation=headed; expect_refused "wrong presentation"
make_args; args[2]=--bot=leveling; expect_refused "wrong bot"
make_args; args[3]=--owner=home-Igris; expect_refused "owner for another seat"
make_args; args[9]=--character-name=Igris; expect_refused "character mismatch"
make_args; args[6]="--lua-status-dir=$root/elsewhere"; expect_refused "status dir mismatch"
make_args; unset 'args[6]'; expect_refused "missing --lua-status-dir"
make_args; args+=(--league=persistent); expect_refused "launcher-only --league"
make_args; args+=(--force-build); expect_refused "launcher-only --force-build"
make_args; args+=(--nim=/x/nim); expect_refused "launcher-only --nim"
make_args; args+=(--); expect_refused "bare --"
make_args; args+=(--username=OTHER); expect_refused "duplicate --username"
make_args; args+=(--password "$secret"); expect_refused "space-separated password"
make_args; args+=("$secret"); expect_refused "stray positional secret"

echo
if [ "$fails" -eq 0 ]; then echo "test_private_native_launch: all passed"; else
  echo "test_private_native_launch: $fails failed"; exit 1; fi
