#!/usr/bin/env bash
# A flash deletes its own upload when it finishes, but a process killed
# mid-flash never gets there. Startup clears whatever the last process left.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

PYTHON3="$(command -v python3)"
if [ -z "$PYTHON3" ]; then printf '  SKIP no python3 on PATH\n'; exit 0; fi
if ! "$PYTHON3" -c 'import flask' 2>/dev/null; then
    printf '  SKIP flask not installed\n'; exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

APP_DIR="$HERE/.."
export APP_DIR

sweep() { DRIVE_UPLOAD_DIR="$1" "$PYTHON3" "$HERE/upload_sweep_driver.py" 2>&1; }

echo "-- uploads left by a killed flash --"
UP="$WORK/uploads"
mkdir -p "$UP"
printf 'firmware\n' > "$UP/tmpaaaa__old-one.bin"
printf 'firmware\n' > "$UP/tmpbbbb__old-two.bin"
out="$(sweep "$UP")"
assert_ok     "the sweep returns"              grep -q '^RETURNED$' <<<"$out"
assert_absent "the first stale upload is gone" "$UP/tmpaaaa__old-one.bin"
assert_absent "the second stale upload is gone" "$UP/tmpbbbb__old-two.bin"
assert_exists "the directory itself survives"  "$UP"
assert_ok     "the count is reported"          grep -qiE '^LOG .*2 ' <<<"$out"

echo "-- nothing to do --"
out="$(sweep "$UP")"
assert_ok   "an empty directory is fine"       grep -q '^RETURNED$' <<<"$out"
assert_fail "and says nothing"                 grep -qi '^LOG .*stale' <<<"$out"

echo "-- no upload directory yet --"
out="$(sweep "$WORK/never-created")"
assert_ok   "a missing directory is a no-op"   grep -q '^RETURNED$' <<<"$out"
assert_absent "and is not created by the sweep" "$WORK/never-created"

summary
