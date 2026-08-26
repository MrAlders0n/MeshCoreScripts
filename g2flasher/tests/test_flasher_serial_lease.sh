#!/usr/bin/env bash
# Tests for the serial-port lease flasher.py takes around a flash: a telemetry
# daemon that streams the radio's packet log holds the same port esptool needs,
# and sharing it corrupts the flash silently, so the flash has to stop that unit
# and put it back afterwards.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/helpers.sh"

PYTHON3="$(command -v python3)"
if [ -z "$PYTHON3" ]; then printf '  SKIP no python3 on PATH\n'; exit 0; fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUB="$WORK/bin"
make_systemd_stubs "$STUB"

APP_DIR="$HERE/.."
CALLS="$WORK/calls.log"
DRIVE_FW="$WORK/firmware.bin"
STUB_SYSTEMCTL_LOG="$CALLS"
export APP_DIR DRIVE_FW STUB_SYSTEMCTL_LOG

# run_flash — drive one flash. stdout is STATE=<state> plus the flash log the
# web UI would show; $CALLS gets the unit calls interleaved with the flash.
run_flash() {
    : > "$CALLS"
    printf 'firmware\n' > "$DRIVE_FW"   # the worker deletes it when it finishes
    # PATH is the stub dir alone so a real systemctl on the host can never be
    # reached; python is invoked by absolute path and does not need PATH.
    ( export PATH="$STUB"; "$PYTHON3" "$HERE/serial_lease_driver.py" 2>&1 )
}

# line_no <pattern> — line of the first match in $CALLS, empty if absent.
line_no() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }

assert_before() {
    local desc="$1" first="$2" second="$3" a b
    a="$(line_no "$first")"; b="$(line_no "$second")"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then
        pass "$desc"
    else
        fail "$desc ('$first' at ${a:-none}, '$second' at ${b:-none})"
    fi
}

echo "-- telemetry unit running --"
export STUB_ACTIVE_UNIT=mctomqtt
out="$(run_flash)"
assert_ok   "the flash completes"                    grep -q '^STATE=done$' <<<"$out"
assert_ok   "is-active is consulted"                 grep -q '^systemctl is-active --quiet mctomqtt$' "$CALLS"
assert_fail "is-active does not go through sudo"     grep -q 'sudo.*is-active' "$CALLS"
assert_ok   "the unit is stopped"                    grep -q '^systemctl stop mctomqtt$' "$CALLS"
assert_ok   "the stop goes through sudo"             grep -q '^sudo -n systemctl stop mctomqtt$' "$CALLS"
assert_before "the stop precedes the flash"          'systemctl stop' 'esptool'
assert_before "the flash precedes the restart"       'esptool' 'systemctl start'
assert_ok   "the stop reaches the flash log"         grep -qi '^LOG .*[Ss]topped mctomqtt' <<<"$out"
assert_ok   "the restart reaches the flash log"      grep -qi '^LOG .*[Rr]estarted mctomqtt' <<<"$out"

echo "-- telemetry unit already stopped --"
export STUB_ACTIVE_UNIT="" STUB_IS_ACTIVE_RC=3
out="$(run_flash)"
assert_ok   "the flash completes"                    grep -q '^STATE=done$' <<<"$out"
assert_fail "an inactive unit is not stopped"        grep -q 'systemctl stop' "$CALLS"
assert_fail "an inactive unit is left stopped"       grep -q 'systemctl start' "$CALLS"
assert_fail "nothing about it reaches the flash log" grep -qi 'mctomqtt' <<<"$out"

echo "-- no such unit on this host --"
export STUB_IS_ACTIVE_RC=4
out="$(run_flash)"
assert_ok   "the flash completes"                    grep -q '^STATE=done$' <<<"$out"
assert_fail "no unit is touched"                     grep -qE 'systemctl (stop|start)' "$CALLS"
assert_fail "nothing about it reaches the flash log" grep -qi 'mctomqtt' <<<"$out"

echo "-- host without systemd --"
rm -f "$STUB/systemctl"
out="$(run_flash)"
assert_ok   "the flash completes"                    grep -q '^STATE=done$' <<<"$out"
assert_fail "nothing about it reaches the flash log" grep -qi 'mctomqtt' <<<"$out"
make_systemd_stubs "$STUB"

echo "-- the flash fails part-way --"
export STUB_ACTIVE_UNIT=mctomqtt STUB_IS_ACTIVE_RC=3 DRIVE_ESPTOOL_RC=1
out="$(run_flash)"
assert_ok   "the failure is reported"                grep -q '^STATE=error$' <<<"$out"
assert_ok   "the unit is restarted anyway"           grep -q '^systemctl start mctomqtt$' "$CALLS"
unset DRIVE_ESPTOOL_RC

echo "-- the flash throws --"
export DRIVE_RAISE=1
out="$(run_flash)"
assert_ok   "the crash is reported"                  grep -q '^STATE=error$' <<<"$out"
assert_ok   "the unit is restarted anyway"           grep -q '^systemctl start mctomqtt$' "$CALLS"
unset DRIVE_RAISE

echo "-- sudo does not permit the stop --"
export STUB_STOP_RC=1
out="$(run_flash)"
assert_ok   "the flash runs regardless"              grep -q '^STATE=done$' <<<"$out"
assert_ok   "the refusal is logged"                  grep -qi '^LOG .*could not stop mctomqtt' <<<"$out"
assert_fail "a unit we never stopped is not started" grep -q 'systemctl start' "$CALLS"
unset STUB_STOP_RC

echo "-- sudo does not permit the restart --"
export STUB_START_RC=1
out="$(run_flash)"
assert_ok   "the flash result is unchanged"          grep -q '^STATE=done$' <<<"$out"
assert_ok   "the operator is told to start it"       grep -qi '^LOG .*could not restart mctomqtt' <<<"$out"
unset STUB_START_RC

echo "-- unit name from the environment --"
export G2FLASHER_SERIAL_UNIT=telemetry-bridge STUB_ACTIVE_UNIT=telemetry-bridge
out="$(run_flash)"
assert_ok   "the configured unit is stopped"         grep -q '^systemctl stop telemetry-bridge$' "$CALLS"
assert_ok   "the configured unit is restarted"       grep -q '^systemctl start telemetry-bridge$' "$CALLS"
assert_fail "the default unit is left alone"         grep -q 'mctomqtt' "$CALLS"
unset G2FLASHER_SERIAL_UNIT

summary
