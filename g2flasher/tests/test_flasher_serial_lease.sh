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
assert_ok   "the unit is stopped"                    grep -q '^systemctl --no-ask-password stop mctomqtt$' "$CALLS"
assert_fail "polkit alone suffices — sudo unneeded"  grep -q '^sudo' "$CALLS"
assert_before "the stop precedes the flash"          '^systemctl --no-ask-password stop' '^esptool'
assert_before "the flash precedes the restart"       '^esptool' '^systemctl --no-ask-password start'
assert_ok   "the stop reaches the flash log"         grep -qi '^LOG .*[Ss]topped mctomqtt' <<<"$out"
assert_ok   "the restart reaches the flash log"      grep -qi '^LOG .*[Rr]estarted mctomqtt' <<<"$out"
assert_fail "no stats poller is mentioned"           grep -qi 'poller' <<<"$out"

echo "-- telemetry unit already stopped --"
export STUB_ACTIVE_UNIT="" STUB_IS_ACTIVE_RC=3
out="$(run_flash)"
assert_ok   "the flash completes"                    grep -q '^STATE=done$' <<<"$out"
assert_fail "an inactive unit is not stopped"        grep -q 'systemctl.*stop' "$CALLS"
assert_fail "an inactive unit is left stopped"       grep -q 'systemctl.*start' "$CALLS"
assert_fail "nothing about it reaches the flash log" grep -qi 'mctomqtt' <<<"$out"

echo "-- no such unit on this host --"
export STUB_IS_ACTIVE_RC=4
out="$(run_flash)"
assert_ok   "the flash completes"                    grep -q '^STATE=done$' <<<"$out"
assert_fail "no unit is touched"                     grep -qE 'systemctl .*(stop|start)' "$CALLS"
assert_fail "nothing about it reaches the flash log" grep -qi 'mctomqtt' <<<"$out"

echo "-- host without systemd --"
rm -f "$STUB/systemctl"
out="$(run_flash)"
assert_ok   "the flash completes"                    grep -q '^STATE=done$' <<<"$out"
assert_fail "nothing about it reaches the flash log" grep -qi 'mctomqtt' <<<"$out"
make_systemd_stubs "$STUB"

echo "-- polkit refuses, sudoers permits --"
export STUB_ACTIVE_UNIT=mctomqtt STUB_IS_ACTIVE_RC=3 STUB_STOP_RC=1 STUB_START_RC=1
out="$(run_flash)"
assert_ok   "the flash completes"                    grep -q '^STATE=done$' <<<"$out"
assert_before "the direct route is tried first"      '^systemctl --no-ask-password stop' '^sudo -n systemctl'
assert_ok   "the stop falls back to sudo"            grep -q '^sudo -n systemctl --no-ask-password stop mctomqtt$' "$CALLS"
assert_ok   "the unit does get stopped"              grep -qi '^LOG Stopped mctomqtt' <<<"$out"
assert_ok   "the restart falls back too"             grep -q '^sudo -n systemctl --no-ask-password start mctomqtt$' "$CALLS"
assert_ok   "the unit does get restarted"            grep -qi '^LOG Restarted mctomqtt' <<<"$out"
unset STUB_STOP_RC STUB_START_RC

echo "-- NoNewPrivileges blocks sudo, no polkit rule either --"
export STUB_STOP_RC=1 STUB_SUDO_RC=1
out="$(run_flash)"
assert_ok   "the flash runs regardless"              grep -q '^STATE=done$' <<<"$out"
assert_ok   "the refusal is logged"                  grep -qi '^LOG .*could not stop mctomqtt' <<<"$out"
assert_ok   "the sudo message is surfaced"           grep -qi 'no new privileges' <<<"$out"
assert_fail "a unit we never stopped is not started" grep -qE 'systemctl .*start' "$CALLS"
unset STUB_STOP_RC STUB_SUDO_RC

echo "-- neither route can restart the unit --"
export STUB_START_RC=1 STUB_SUDO_START_RC=1
out="$(run_flash)"
assert_ok   "the flash result is unchanged"          grep -q '^STATE=done$' <<<"$out"
assert_ok   "the operator is told to start it"       grep -qi '^LOG .*could not restart mctomqtt' <<<"$out"
unset STUB_START_RC STUB_SUDO_START_RC

echo "-- the flash fails part-way --"
export DRIVE_ESPTOOL_RC=1
out="$(run_flash)"
assert_ok   "the failure is reported"                grep -q '^STATE=error$' <<<"$out"
assert_ok   "the unit is restarted anyway"           grep -q '^systemctl --no-ask-password start mctomqtt$' "$CALLS"
unset DRIVE_ESPTOOL_RC

echo "-- the flash throws --"
export DRIVE_RAISE=1
out="$(run_flash)"
assert_ok   "the crash is reported"                  grep -q '^STATE=error$' <<<"$out"
assert_ok   "the unit is restarted anyway"           grep -q '^systemctl --no-ask-password start mctomqtt$' "$CALLS"
unset DRIVE_RAISE

echo "-- an esptool traceback is summarised, not dumped --"
export DRIVE_MODE=normal
out="$(run_flash)"
assert_ok   "the failure is reported"                grep -q '^STATE=error$' <<<"$out"
assert_ok   "the exception line survives"            grep -q 'BrokenPipeError' <<<"$out"
assert_ok   "the context above it survives"          grep -q 'Serial port /dev' <<<"$out"
assert_fail "the traceback header is dropped"        grep -q 'Traceback (most recent call last)' <<<"$out"
assert_fail "the stack frames are dropped"           grep -q 'site-packages' <<<"$out"
assert_fail "the echoed source lines are dropped"    grep -q '\^\^\^\^' <<<"$out"
assert_ok   "port contention is named as a cause"    grep -qi 'holds its serial port' <<<"$out"
unset DRIVE_MODE

echo "-- unit name from the environment --"
export G2FLASHER_SERIAL_UNIT=telemetry-bridge STUB_ACTIVE_UNIT=telemetry-bridge
out="$(run_flash)"
assert_ok   "the configured unit is stopped"         grep -q '^systemctl --no-ask-password stop telemetry-bridge$' "$CALLS"
assert_ok   "the configured unit is restarted"       grep -q '^systemctl --no-ask-password start telemetry-bridge$' "$CALLS"
assert_fail "the default unit is left alone"         grep -q 'mctomqtt' "$CALLS"
unset G2FLASHER_SERIAL_UNIT

summary
