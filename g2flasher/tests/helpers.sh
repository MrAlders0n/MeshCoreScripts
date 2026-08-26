# shellcheck shell=bash
# Minimal assertion helpers for the g2flasher shell tests.
# Sourced by test_*.sh. Bash 3.2 compatible (macOS ships 3.2).

TESTS_RUN=0
TESTS_FAILED=0

pass() { printf '  ok   %s\n' "$*"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  FAIL %s\n' "$*" >&2; }

# The command under test runs in a subshell: the scripts being tested call
# die(), which exits, and an exit in the current shell would kill the test run.
# Filesystem side effects still persist; only shell-variable ones would not.

# assert_ok <description> <command...>  — command must exit 0
assert_ok() {
    local desc="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if ( "$@" ) >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# assert_fail <description> <command...>  — command must exit non-zero
assert_fail() {
    local desc="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if ( "$@" ) >/dev/null 2>&1; then fail "$desc (expected non-zero exit)"; else pass "$desc"; fi
}

assert_eq() {
    local desc="$1" got="$2" want="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$got" = "$want" ]; then pass "$desc"; else fail "$desc (got '$got', want '$want')"; fi
}

assert_exists() {
    local desc="$1" path="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -e "$path" ]; then pass "$desc"; else fail "$desc ($path missing)"; fi
}

assert_absent() {
    local desc="$1" path="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -e "$path" ]; then fail "$desc ($path still present)"; else pass "$desc"; fi
}

summary() {
    printf '\n%d checks, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
    [ "$TESTS_FAILED" -eq 0 ]
}

# make_stubs <dir> — write fake findmnt/git/runuser/systemctl/apt-get into dir.
# Behaviour is driven by STUB_* environment variables read at call time.
make_stubs() {
    local dir="$1"
    mkdir -p "$dir"

    cat > "$dir/findmnt" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_FSTYPE:-ext4}"
STUB

    cat > "$dir/runuser" <<'STUB'
#!/usr/bin/env bash
# Called as: runuser -u <user> -- <cmd...>   Strip the wrapper, run the rest.
shift 2
if [ "$1" = "--" ]; then shift; fi
exec "$@"
STUB

    cat > "$dir/git" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        diff)      printf '%s\n' ${STUB_GIT_DIFF:-}; exit 0 ;;
        rev-parse) printf '%s\n' "${STUB_GIT_HEAD:-aaaaaaaabbbbbbbb}"; exit 0 ;;
        pull)      exit "${STUB_GIT_PULL_RC:-0}" ;;
    esac
done
exit 0
STUB

    cat > "$dir/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${STUB_SYSTEMCTL_LOG:-/dev/null}"
exit 0
STUB

    cat > "$dir/apt-get" <<'STUB'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "${STUB_APT_LOG:-/dev/null}"
exit "${STUB_APT_RC:-0}"
STUB

    chmod +x "$dir"/findmnt "$dir"/runuser "$dir"/git "$dir"/systemctl "$dir"/apt-get
}

# make_systemd_stubs <dir> — write fake systemctl/sudo into dir, for the tests
# that exercise flasher.py's serial-port lease. Every call is appended to
# $STUB_SYSTEMCTL_LOG so a test can assert on both the calls and their order.
# Behaviour is driven by environment variables read at call time:
#   STUB_ACTIVE_UNIT  — the one unit `is-active` reports as running
#   STUB_IS_ACTIVE_RC — exit code for any other unit (3 inactive, 4 no such unit)
#   STUB_STOP_RC      — exit code for `systemctl stop`
#   STUB_START_RC     — exit code for `systemctl start`
# These run with PATH narrowed to the stub dir, so the shebang has to name an
# absolute interpreter — `/usr/bin/env bash` would have no PATH to find bash on.
make_systemd_stubs() {
    local dir="$1"
    mkdir -p "$dir"

    cat > "$dir/systemctl" <<'STUB'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "${STUB_SYSTEMCTL_LOG:-/dev/null}"
verb="$1"; shift
unit=""
for a in "$@"; do case "$a" in --*) ;; *) unit="$a" ;; esac; done
case "$verb" in
    is-active) [ "$unit" = "${STUB_ACTIVE_UNIT:-}" ] && exit 0
               exit "${STUB_IS_ACTIVE_RC:-3}" ;;
    stop)      exit "${STUB_STOP_RC:-0}" ;;
    start)     exit "${STUB_START_RC:-0}" ;;
esac
exit 0
STUB

    # Log the invocation, drop sudo's own options, run what was asked.
    cat > "$dir/sudo" <<'STUB'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "${STUB_SYSTEMCTL_LOG:-/dev/null}"
while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
exec "$@"
STUB

    chmod +x "$dir"/systemctl "$dir"/sudo
}
