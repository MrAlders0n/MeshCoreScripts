# shellcheck shell=bash
# Minimal assertion helpers for the g2flasher shell tests.
# Sourced by test_*.sh. Bash 3.2 compatible (macOS ships 3.2).

TESTS_RUN=0
TESTS_FAILED=0

pass() { printf '  ok   %s\n' "$*"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  FAIL %s\n' "$*" >&2; }

# assert_ok <description> <command...>  — command must exit 0
assert_ok() {
    local desc="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# assert_fail <description> <command...>  — command must exit non-zero
assert_fail() {
    local desc="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then fail "$desc (expected non-zero exit)"; else pass "$desc"; fi
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
