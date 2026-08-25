#!/usr/bin/env bash
# Unit tests for bootstrap.sh — especially that pruning never eats the venv or the password.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUB="$WORK/bin"
make_stubs "$STUB"

FINDMNT="$STUB/findmnt"
GIT="$STUB/git"
RUNUSER="$STUB/runuser"
SYSTEMCTL="$STUB/systemctl"
APT_GET="$STUB/apt-get"
REPO_DIR="$WORK/repo"
STATE_DIR="$WORK/state"
APP_DIR="$REPO_DIR/g2flasher"
UNIT_DEST="$WORK/unit-installed.service"
HELPER_DEST="$WORK/sbin/g2flasher-update"
HOME_STAGE="$WORK/home/MeshCoreScripts"
SD_STATUS="$WORK/no-such-sd-status"
export FINDMNT GIT RUNUSER SYSTEMCTL APT_GET REPO_DIR STATE_DIR APP_DIR
export UNIT_DEST HELPER_DEST HOME_STAGE SD_STATUS

. "$HERE/../bootstrap.sh"
set +e  # the script under test turns on errexit when sourced; these tests assert on failures

# Build a STATE_DIR that mirrors the real /opt/g2flasher before migration.
seed_state_dir() {
    rm -rf "$STATE_DIR"
    mkdir -p "$STATE_DIR/venv/bin" "$STATE_DIR/templates" "$STATE_DIR/__pycache__"
    touch "$STATE_DIR"/app.py "$STATE_DIR"/devices.py "$STATE_DIR"/flasher.py \
          "$STATE_DIR"/stats.py "$STATE_DIR"/requirements.txt \
          "$STATE_DIR"/requirements-dev.txt "$STATE_DIR"/README.md \
          "$STATE_DIR"/g2flasher.service "$STATE_DIR"/templates/index.html \
          "$STATE_DIR"/__pycache__/app.cpython-313.pyc
    printf 'G2FLASHER_PASSWORD=secret\n' > "$STATE_DIR/g2flasher.env"
    chmod 600 "$STATE_DIR/g2flasher.env"
    printf '#!/bin/sh\n' > "$STATE_DIR/venv/bin/python"
    chmod +x "$STATE_DIR/venv/bin/python"
}

echo "-- pruning preserves machine-local state --"
seed_state_dir
prune_stale_files >/dev/null 2>&1
assert_exists "the venv survives pruning"          "$STATE_DIR/venv/bin/python"
assert_exists "the password file survives pruning" "$STATE_DIR/g2flasher.env"
assert_eq     "the password file is unchanged" \
              "$(cat "$STATE_DIR/g2flasher.env")" "G2FLASHER_PASSWORD=secret"

echo "-- pruning removes the duplicated app files --"
assert_absent "app.py removed"              "$STATE_DIR/app.py"
assert_absent "devices.py removed"          "$STATE_DIR/devices.py"
assert_absent "flasher.py removed"          "$STATE_DIR/flasher.py"
assert_absent "stats.py removed"            "$STATE_DIR/stats.py"
assert_absent "requirements.txt removed"    "$STATE_DIR/requirements.txt"
assert_absent "requirements-dev.txt removed" "$STATE_DIR/requirements-dev.txt"
assert_absent "README.md removed"           "$STATE_DIR/README.md"
assert_absent "g2flasher.service removed"   "$STATE_DIR/g2flasher.service"
assert_absent "templates/ removed"          "$STATE_DIR/templates"
assert_absent "__pycache__/ removed"        "$STATE_DIR/__pycache__"

echo "-- pruning is idempotent --"
assert_ok "a second prune on a clean dir succeeds" prune_stale_files

echo "-- state assertions --"
seed_state_dir
assert_ok "a complete state dir passes" assert_state_dir
rm -f "$STATE_DIR/g2flasher.env"
assert_fail "a missing password file aborts" assert_state_dir
seed_state_dir
rm -rf "$STATE_DIR/venv"
assert_fail "a missing venv aborts" assert_state_dir

echo "-- git install --"
STUB_APT_LOG="$WORK/apt.log"
export STUB_APT_LOG
assert_ok "ensure_git is a no-op when git is present" ensure_git
assert_eq "no apt call was made" "$(cat "$WORK/apt.log" 2>/dev/null || true)" ""

echo "-- housekeeping --"
mkdir -p "$STATE_DIR.bak-20260821-173809" "$HOME_STAGE/.venv"
housekeeping >/dev/null 2>&1
assert_absent "the stale backup dir is removed" "$STATE_DIR.bak-20260821-173809"
assert_absent "the redundant home venv is removed" "$HOME_STAGE/.venv"
assert_ok "housekeeping is idempotent" housekeeping

echo "-- main guards --"
export STUB_FSTYPE=overlay
out="$(main 2>&1)"; rc=$?
assert_eq "main refuses on an overlay-locked root" "$rc" "1"
assert_ok "the refusal names sd-unlock" grep -q "sd-unlock" <<<"$out"

summary
