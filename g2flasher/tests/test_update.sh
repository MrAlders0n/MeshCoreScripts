#!/usr/bin/env bash
# Unit tests for g2flasher-update's decision logic.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUB="$WORK/bin"
make_stubs "$STUB"

# Point every external command at a stub, then source the script under test.
FINDMNT="$STUB/findmnt"
GIT="$STUB/git"
RUNUSER="$STUB/runuser"
SYSTEMCTL="$STUB/systemctl"
REPO_DIR="$WORK/repo"
STATE_DIR="$WORK/state"
APP_DIR="$REPO_DIR/g2flasher"
UNIT_DEST="$WORK/unit-installed.service"
HELPER_DEST="$WORK/g2flasher-update"
SD_STATUS="$WORK/no-such-sd-status"
export FINDMNT GIT RUNUSER SYSTEMCTL REPO_DIR STATE_DIR APP_DIR UNIT_DEST HELPER_DEST SD_STATUS

mkdir -p "$APP_DIR"
. "$HERE/../g2flasher-update"
set +e  # the script under test turns on errexit when sourced; these tests assert on failures

echo "-- overlay guard --"
export STUB_FSTYPE=overlay
assert_ok   "overlay root is detected as locked" is_overlay_locked
export STUB_FSTYPE=ext4
assert_fail "ext4 root is not locked"            is_overlay_locked
export STUB_FSTYPE=""
assert_fail "empty findmnt output is not locked" is_overlay_locked

echo "-- requirements change detection --"
export STUB_GIT_DIFF="g2flasher/requirements.txt"
assert_ok   "requirements.txt in the diff triggers pip install" requirements_changed old new
export STUB_GIT_DIFF="g2flasher/app.py g2flasher/stats.py"
assert_fail "app-only changes do not trigger pip install"       requirements_changed old new
export STUB_GIT_DIFF=""
assert_fail "an empty diff does not trigger pip install"        requirements_changed old new
export STUB_GIT_DIFF="docs/requirements.txt"
assert_fail "a requirements.txt elsewhere does not match"       requirements_changed old new

echo "-- unit install detection --"
printf 'A\n' > "$WORK/unit-src.service"
printf 'B\n' > "$UNIT_DEST"
assert_ok   "differing unit needs installing"   unit_needs_install "$WORK/unit-src.service" "$UNIT_DEST"
printf 'A\n' > "$UNIT_DEST"
assert_fail "identical unit is left alone"      unit_needs_install "$WORK/unit-src.service" "$UNIT_DEST"
rm -f "$UNIT_DEST"
assert_ok   "missing unit needs installing"     unit_needs_install "$WORK/unit-src.service" "$UNIT_DEST"

echo "-- main guards --"
export STUB_FSTYPE=overlay
out="$(main 2>&1)"; rc=$?
assert_eq "main refuses on an overlay-locked root" "$rc" "1"
assert_ok "the refusal names sd-unlock" grep -q "sd-unlock" <<<"$out"

export STUB_FSTYPE=ext4
rm -rf "$REPO_DIR/.git"
out="$(main 2>&1)"; rc=$?
assert_eq "main refuses when the checkout is missing" "$rc" "1"
assert_ok "the refusal names bootstrap" grep -qi "bootstrap" <<<"$out"

summary
