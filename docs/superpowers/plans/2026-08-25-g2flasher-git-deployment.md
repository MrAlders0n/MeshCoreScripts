# g2flasher Git-Controlled Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the running g2flasher app under version control and reduce updating the Pi to `sudo g2flasher-update`.

**Architecture:** The app source is imported verbatim into `g2flasher/` in this repo. On the Pi, a git checkout at `/opt/MeshCoreScripts` holds the code while `/opt/g2flasher` keeps only machine-local state (`venv/`, `g2flasher.env`), so git operations can never touch the venv or the password. Two new bash scripts do the work: `bootstrap.sh` migrates the existing install once, and `g2flasher-update` is the steady-state pull-and-restart command.

**Tech Stack:** Bash (Pi runs 5.2, dev Mac runs 3.2 — write for 3.2), git, systemd, shellcheck. No new Python dependencies; the app itself is not modified.

**Spec:** `docs/superpowers/specs/2026-08-25-g2flasher-git-deployment-design.md`

## Global Constraints

- **Bash 3.2 compatible.** The dev Mac ships bash 3.2.57. No associative arrays, no `mapfile`/`readarray`, no `${var,,}` / `${var^^}`. Substring expansion `${var:0:8}` and `${@:2}` are fine.
- **Never touch `/opt/g2flasher/venv` or `/opt/g2flasher/g2flasher.env`.** These are the live venv and the mode-600 password file. Every destructive operation must be tested to preserve them.
- **All git operations on the Pi run as `cadmin`**, via `/usr/sbin/runuser -u cadmin --`. Root-owned files in the checkout break later pulls. `runuser` is not in `cadmin`'s non-login `PATH`, but sudo's `secure_path` includes `/usr/sbin`, so scripts running under sudo resolve it.
- **Every script is sourceable for testing.** Side-effecting commands go behind `: "${VAR:=default}"` overrides; `main` runs only under `if [ "${BASH_SOURCE[0]}" = "${0}" ]`.
- **Repo:** `https://github.com/MrAlders0n/MeshCoreScripts.git`, public, default branch `main`.
- Pi paths, verbatim: `REPO_DIR=/opt/MeshCoreScripts`, `STATE_DIR=/opt/g2flasher`, `APP_DIR=/opt/MeshCoreScripts/g2flasher`, `UNIT_DEST=/etc/systemd/system/g2flasher.service`, `HELPER_DEST=/usr/local/sbin/g2flasher-update`.
- Run shell tests with `bash g2flasher/tests/run_tests.sh` from the repo root.
- Commit after every task.

---

### Task 1: Import the app source into git

**Files:**
- Create: `.gitignore`
- Create: `g2flasher/app.py`, `g2flasher/devices.py`, `g2flasher/flasher.py`, `g2flasher/stats.py`, `g2flasher/templates/index.html`, `g2flasher/requirements.txt`, `g2flasher/README.md` (all verbatim from the tarball)
- Create: `g2flasher/g2flasher.service` (from the tarball, three lines changed)
- Delete: `g2flasherg3update.tar.gz`

**Interfaces:**
- Produces: the `g2flasher/` tree that Tasks 2–5 operate on, and `g2flasher/g2flasher.service` with the paths the update helper installs.

- [ ] **Step 1: Create the .gitignore**

The repo currently has none. Create `.gitignore` at the repo root:

```
__pycache__/
*.py[cod]
venv/
.venv/
g2flasher.env
.DS_Store
```

- [ ] **Step 2: Extract the app source from the tarball**

The tarball in the repo root is the authoritative copy — its eight files were verified byte-identical to what is running on the Pi.

```bash
cd /Users/schnobbc/Documents/Github/MeshCore_Scripts/MeshCoreScripts
mkdir -p g2flasher/templates
tar -xzf g2flasherg3update.tar.gz --strip-components=1 -C g2flasher \
  g2flasher-g3-update/app.py \
  g2flasher-g3-update/devices.py \
  g2flasher-g3-update/flasher.py \
  g2flasher-g3-update/stats.py \
  g2flasher-g3-update/requirements.txt \
  g2flasher-g3-update/README.md \
  g2flasher-g3-update/g2flasher.service \
  g2flasher-g3-update/templates/index.html
ls -la g2flasher g2flasher/templates
```

Note `deploy.sh` is deliberately NOT extracted — it is the mechanism this plan replaces.

- [ ] **Step 3: Verify the import matches production**

This is the test for this task: the imported files must hash-match the live Pi.

```bash
cd /Users/schnobbc/Documents/Github/MeshCore_Scripts/MeshCoreScripts/g2flasher
for f in app.py devices.py flasher.py stats.py requirements.txt README.md templates/index.html; do
  printf '%-24s %s\n' "$f" "$(shasum -a 256 "$f" | cut -c1-16)"
done
ssh cadmin@172.30.50.48 'for f in app.py devices.py flasher.py stats.py requirements.txt README.md templates/index.html; do printf "%-24s %s\n" "$f" "$(sha256sum /opt/g2flasher/$f | cut -c1-16)"; done'
```

Expected: the two lists are identical, seven for seven. `g2flasher.service` is excluded here because Step 4 changes it. If any file differs, STOP — the Pi has drifted from the tarball and the drift must be understood before continuing.

- [ ] **Step 4: Point the systemd unit at the checkout**

Edit `g2flasher/g2flasher.service`. Change exactly these three lines:

```
WorkingDirectory=/opt/MeshCoreScripts/g2flasher
EnvironmentFile=/opt/g2flasher/g2flasher.env
ExecStart=/opt/g2flasher/venv/bin/python /opt/MeshCoreScripts/g2flasher/app.py
```

`EnvironmentFile` is unchanged from the original but is listed so all three path lines are visible together. Leave `[Unit]`, `User`, `Group`, `AmbientCapabilities`, `CapabilityBoundingSet`, `NoNewPrivileges`, `Restart`, `RestartSec`, and `[Install]` untouched.

Verify:

```bash
grep -E 'WorkingDirectory|EnvironmentFile|ExecStart' g2flasher/g2flasher.service
```

Expected: the three lines above.

- [ ] **Step 5: Remove the tarball and commit**

The tarball's contents are now tracked, so the archive is redundant.

```bash
cd /Users/schnobbc/Documents/Github/MeshCore_Scripts/MeshCoreScripts
rm g2flasherg3update.tar.gz
git add .gitignore g2flasher/
git add -u
git commit -m "Import g2flasher app source (G2+G3), verified against live Pi

Eight files lifted verbatim from the g3-update tarball; seven hash-match
/opt/g2flasher on CBC-FORTUNE-R1-PI. g2flasher.service repoints at the
/opt/MeshCoreScripts checkout. deploy.sh is dropped in favour of
bootstrap.sh + g2flasher-update."
```

---

### Task 2: `g2flasher-update` with a shell test harness

**Files:**
- Create: `g2flasher/tests/helpers.sh`
- Create: `g2flasher/tests/run_tests.sh`
- Create: `g2flasher/tests/test_update.sh`
- Create: `g2flasher/g2flasher-update`

**Interfaces:**
- Produces: `g2flasher-update` exposing sourceable functions `root_fs_type`, `is_overlay_locked`, `as_repo_user`, `repo_head`, `changed_files`, `requirements_changed OLD NEW`, `unit_needs_install SRC DEST`, and `main`. Task 3 reuses `helpers.sh` and the stub pattern established here.

- [ ] **Step 1: Install shellcheck**

```bash
brew install shellcheck
shellcheck --version
```

Expected: version 0.9 or later. (Not currently installed on this Mac; brew is at `/opt/homebrew/bin/brew`.)

- [ ] **Step 2: Write the assertion helpers**

`g2flasher/tests/helpers.sh` — bash 3.2 compatible, no dependencies:

```bash
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
```

- [ ] **Step 3: Write the test runner**

`g2flasher/tests/run_tests.sh`:

```bash
#!/usr/bin/env bash
# Run every g2flasher shell test. Usage: bash g2flasher/tests/run_tests.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0

for t in "$HERE"/test_*.sh; do
    printf '\n=== %s ===\n' "$(basename "$t")"
    if ! bash "$t"; then rc=1; fi
done

printf '\n'
if [ "$rc" -eq 0 ]; then printf 'ALL TESTS PASSED\n'; else printf 'TESTS FAILED\n'; fi
exit "$rc"
```

- [ ] **Step 4: Write the failing tests for `g2flasher-update`**

`g2flasher/tests/test_update.sh`:

```bash
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
```

Note the `main` guard tests run as a non-root user, so the root check must come *after* the checks being asserted, or those two assertions would only ever see the root refusal. Order the guards in `main` as: overlay → checkout-exists → root. The root check is the last guard before any side effect.

- [ ] **Step 5: Run the tests to verify they fail**

```bash
cd /Users/schnobbc/Documents/Github/MeshCore_Scripts/MeshCoreScripts
bash g2flasher/tests/run_tests.sh
```

Expected: FAIL — `g2flasher/tests/../g2flasher-update: No such file or directory`.

- [ ] **Step 6: Write `g2flasher-update`**

`g2flasher/g2flasher-update` (no `.sh` extension — it is installed as a command):

```bash
#!/usr/bin/env bash
# Update g2flasher from its git checkout and restart the service.
# Installed to /usr/local/sbin/g2flasher-update — run as: sudo g2flasher-update
set -euo pipefail

: "${REPO_DIR:=/opt/MeshCoreScripts}"
: "${STATE_DIR:=/opt/g2flasher}"
: "${APP_DIR:=${REPO_DIR}/g2flasher}"
: "${UNIT_DEST:=/etc/systemd/system/g2flasher.service}"
: "${HELPER_DEST:=/usr/local/sbin/g2flasher-update}"
: "${REPO_USER:=cadmin}"
: "${FINDMNT:=findmnt}"
: "${GIT:=git}"
: "${SYSTEMCTL:=systemctl}"
: "${RUNUSER:=/usr/sbin/runuser}"
: "${SD_STATUS:=/usr/local/sbin/sd-status}"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

root_fs_type() {
    "$FINDMNT" -n -o FSTYPE / 2>/dev/null || true
}

is_overlay_locked() {
    case "$(root_fs_type)" in
        *overlay*) return 0 ;;
        *)         return 1 ;;
    esac
}

as_repo_user() {
    "$RUNUSER" -u "$REPO_USER" -- "$@"
}

repo_head() {
    as_repo_user "$GIT" -C "$REPO_DIR" rev-parse HEAD
}

changed_files() {  # $1=old rev, $2=new rev
    as_repo_user "$GIT" -C "$REPO_DIR" diff --name-only "$1" "$2"
}

requirements_changed() {  # $1=old rev, $2=new rev
    changed_files "$1" "$2" | grep -qx 'g2flasher/requirements.txt'
}

unit_needs_install() {  # $1=source, $2=destination
    ! cmp -s "$1" "$2"
}

main() {
    if is_overlay_locked; then
        die "root filesystem is overlay-locked — an update would vanish on reboot.
Run 'sudo sd-unlock' (it reboots), then re-run this command."
    fi

    [ -d "$REPO_DIR/.git" ] || die "$REPO_DIR is not a git checkout — run bootstrap.sh first"
    [ "$(id -u)" -eq 0 ] || die "run as: sudo g2flasher-update"

    local old new
    old="$(repo_head)"
    log "Pulling $REPO_DIR (at ${old:0:8})..."
    as_repo_user "$GIT" -C "$REPO_DIR" pull --ff-only
    new="$(repo_head)"

    if [ "$old" = "$new" ]; then
        log "Already up to date at ${new:0:8}."
    else
        log "Updated ${old:0:8} -> ${new:0:8}"
        if requirements_changed "$old" "$new"; then
            log "requirements.txt changed — installing dependencies..."
            "$STATE_DIR/venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"
        fi
    fi

    if unit_needs_install "$APP_DIR/g2flasher.service" "$UNIT_DEST"; then
        log "Installing updated systemd unit..."
        install -m 644 -o root -g root "$APP_DIR/g2flasher.service" "$UNIT_DEST"
        "$SYSTEMCTL" daemon-reload
    fi

    log "Restarting g2flasher..."
    "$SYSTEMCTL" restart g2flasher
    sleep 2
    "$SYSTEMCTL" --no-pager --lines=0 status g2flasher || true

    # Self-update by atomic rename: the running shell keeps its original inode,
    # so overwriting the file it is reading cannot corrupt this run.
    if ! cmp -s "$APP_DIR/g2flasher-update" "$HELPER_DEST"; then
        log "Updating $HELPER_DEST (takes effect on the next run)..."
        install -m 755 -o root -g root "$APP_DIR/g2flasher-update" "${HELPER_DEST}.new"
        mv -f "${HELPER_DEST}.new" "$HELPER_DEST"
    fi

    log ""
    if [ -x "$SD_STATUS" ]; then "$SD_STATUS"; fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
cd /Users/schnobbc/Documents/Github/MeshCore_Scripts/MeshCoreScripts
bash g2flasher/tests/run_tests.sh
```

Expected: `ALL TESTS PASSED`, 14 checks, 0 failed.

- [ ] **Step 8: Shellcheck the script**

```bash
shellcheck g2flasher/g2flasher-update g2flasher/tests/run_tests.sh
```

Expected: clean. If SC2034 fires on the `: "${VAR:=default}"` overrides, that is a false positive for sourced config — add a targeted `# shellcheck disable=` with a one-line reason, never a blanket file-level disable.

- [ ] **Step 9: Commit**

```bash
git add g2flasher/g2flasher-update g2flasher/tests/
git commit -m "Add g2flasher-update helper and shell test harness

Pull --ff-only as cadmin, pip install only when requirements.txt changed,
reinstall the unit only when it differs, restart, report sd-status. Self-
updates by atomic rename so a pull never rewrites the running script."
```

---

### Task 3: `bootstrap.sh` one-time migration

**Files:**
- Create: `g2flasher/bootstrap.sh`
- Create: `g2flasher/tests/test_bootstrap.sh`

**Interfaces:**
- Consumes: `helpers.sh` and the `make_stubs` pattern from Task 2; installs the `g2flasher-update` file from Task 2.
- Produces: `bootstrap.sh` exposing `ensure_git`, `assert_state_dir`, `clone_or_update`, `prune_stale_files`, `install_helper`, `install_unit`, `housekeeping`, `main`.

- [ ] **Step 1: Write the failing tests**

`g2flasher/tests/test_bootstrap.sh`. The `prune_stale_files` tests are the most important in this plan — a bug there deletes the password file.

```bash
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
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/schnobbc/Documents/Github/MeshCore_Scripts/MeshCoreScripts
bash g2flasher/tests/run_tests.sh
```

Expected: `test_bootstrap.sh` fails with `g2flasher/tests/../bootstrap.sh: No such file or directory`. `test_update.sh` still passes.

- [ ] **Step 3: Write `bootstrap.sh`**

`g2flasher/bootstrap.sh`:

```bash
#!/usr/bin/env bash
# One-time migration: move /opt/g2flasher from a copied-file install to a git
# checkout at /opt/MeshCoreScripts. Idempotent — safe to re-run.
#
# On the Pi:
#   curl -fsSL -o /tmp/bootstrap.sh \
#     https://raw.githubusercontent.com/MrAlders0n/MeshCoreScripts/main/g2flasher/bootstrap.sh
#   sudo bash /tmp/bootstrap.sh
set -euo pipefail

: "${REPO_URL:=https://github.com/MrAlders0n/MeshCoreScripts.git}"
: "${REPO_DIR:=/opt/MeshCoreScripts}"
: "${STATE_DIR:=/opt/g2flasher}"
: "${APP_DIR:=${REPO_DIR}/g2flasher}"
: "${UNIT_DEST:=/etc/systemd/system/g2flasher.service}"
: "${HELPER_DEST:=/usr/local/sbin/g2flasher-update}"
: "${REPO_USER:=cadmin}"
: "${HOME_STAGE:=/home/cadmin/MeshCoreScripts}"
: "${FINDMNT:=findmnt}"
: "${GIT:=git}"
: "${APT_GET:=apt-get}"
: "${SYSTEMCTL:=systemctl}"
: "${RUNUSER:=/usr/sbin/runuser}"
: "${SD_STATUS:=/usr/local/sbin/sd-status}"

# Files under STATE_DIR that the checkout now owns. venv/ and g2flasher.env
# are deliberately absent from both lists.
STALE_FILES="app.py devices.py flasher.py stats.py requirements.txt requirements-dev.txt README.md g2flasher.service deploy.sh"
STALE_DIRS="__pycache__ templates"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

root_fs_type() {
    "$FINDMNT" -n -o FSTYPE / 2>/dev/null || true
}

is_overlay_locked() {
    case "$(root_fs_type)" in
        *overlay*) return 0 ;;
        *)         return 1 ;;
    esac
}

as_repo_user() {
    "$RUNUSER" -u "$REPO_USER" -- "$@"
}

ensure_git() {
    if command -v "$GIT" >/dev/null 2>&1; then
        log "git present: $("$GIT" --version)"
        return 0
    fi
    log "Installing git..."
    "$APT_GET" update -qq || die "apt-get update failed — check the network and mirrors"
    DEBIAN_FRONTEND=noninteractive "$APT_GET" install -y -qq git \
        || die "apt-get install git failed"
}

assert_state_dir() {
    [ -x "$STATE_DIR/venv/bin/python" ] \
        || die "$STATE_DIR/venv is missing — this migrates an existing install, it does not create one"
    [ -f "$STATE_DIR/g2flasher.env" ] \
        || die "$STATE_DIR/g2flasher.env is missing — refusing to continue"
}

clone_or_update() {
    if [ -d "$REPO_DIR/.git" ]; then
        log "Checkout already at $REPO_DIR — fetching..."
        as_repo_user "$GIT" -C "$REPO_DIR" pull --ff-only
    else
        log "Cloning $REPO_URL -> $REPO_DIR"
        install -d -o "$REPO_USER" -g "$REPO_USER" "$REPO_DIR"
        as_repo_user "$GIT" clone --quiet "$REPO_URL" "$REPO_DIR"
    fi
}

prune_stale_files() {
    local f d
    for f in $STALE_FILES; do
        if [ -e "$STATE_DIR/$f" ]; then
            rm -f "$STATE_DIR/$f"
            log "  removed $STATE_DIR/$f"
        fi
    done
    for d in $STALE_DIRS; do
        if [ -d "$STATE_DIR/$d" ]; then
            rm -rf "${STATE_DIR:?}/$d"
            log "  removed $STATE_DIR/$d/"
        fi
    done
    return 0
}

install_helper() {
    install -d -m 755 "$(dirname "$HELPER_DEST")"
    install -m 755 "$APP_DIR/g2flasher-update" "$HELPER_DEST"
    log "Installed $HELPER_DEST"
}

install_unit() {
    install -m 644 "$APP_DIR/g2flasher.service" "$UNIT_DEST"
    "$SYSTEMCTL" daemon-reload
    log "Installed $UNIT_DEST"
}

housekeeping() {
    local b
    for b in "$STATE_DIR".bak-*; do
        if [ -d "$b" ]; then
            rm -rf "$b"
            log "  removed $b"
        fi
    done
    if [ -d "$HOME_STAGE/.venv" ]; then
        rm -rf "$HOME_STAGE/.venv"
        log "  removed $HOME_STAGE/.venv"
    fi
    return 0
}

main() {
    if is_overlay_locked; then
        die "root filesystem is overlay-locked — this migration would vanish on reboot.
Run 'sudo sd-unlock' (it reboots), then re-run this script."
    fi
    [ "$(id -u)" -eq 0 ] || die "run as: sudo bash bootstrap.sh"

    assert_state_dir
    ensure_git
    clone_or_update

    log "Installing dependencies into the existing venv..."
    "$STATE_DIR/venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"

    log "Removing files the checkout now owns..."
    prune_stale_files

    install_helper
    install_unit

    log "Restarting g2flasher..."
    "$SYSTEMCTL" restart g2flasher
    sleep 2
    "$SYSTEMCTL" --no-pager --lines=0 status g2flasher \
        || die "g2flasher failed to start — check: journalctl -u g2flasher -n 50"

    log "Housekeeping..."
    housekeeping

    log ""
    log "Done. Updates from here on are: sudo g2flasher-update"
    if [ -x "$SD_STATUS" ]; then "$SD_STATUS"; fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/schnobbc/Documents/Github/MeshCore_Scripts/MeshCoreScripts
bash g2flasher/tests/run_tests.sh
```

Expected: `ALL TESTS PASSED`. `test_bootstrap.sh` contributes 24 checks.

- [ ] **Step 5: Shellcheck**

```bash
shellcheck g2flasher/bootstrap.sh
```

Expected: clean. `STALE_FILES`/`STALE_DIRS` are intentionally unquoted at their `for` loops for word splitting; if SC2086 fires there, add a targeted disable with a reason on that line.

- [ ] **Step 6: Commit**

```bash
git add g2flasher/bootstrap.sh g2flasher/tests/test_bootstrap.sh
git commit -m "Add bootstrap.sh one-time migration to a git checkout

Installs git, clones as cadmin, prunes the files the checkout now owns,
installs the helper and unit, sweeps the stale backup and home venv.
Tests assert pruning never touches venv/ or g2flasher.env."
```

---

### Task 4: Documentation

**Files:**
- Modify: `g2flasher/README.md` (replace the Install and Updating sections)
- Modify: `docs/superpowers/specs/2026-08-07-g2flasher-design.md` (mark the Deployment section superseded)

**Interfaces:**
- Consumes: the command names and paths from Tasks 2 and 3.

- [ ] **Step 1: Rewrite the README's Install section**

In `g2flasher/README.md`, replace everything from `## Install (on the Pi)` through the end of `## Updating` with:

```markdown
## Layout

Code is a git checkout; machine-local state is not:

    /opt/MeshCoreScripts/       # this repo, cadmin-owned
      └── g2flasher/            # the app
    /opt/g2flasher/             # NOT in git
      ├── venv/
      └── g2flasher.env         # G2FLASHER_PASSWORD, mode 600

## Install (on the Pi)

    curl -fsSL -o /tmp/bootstrap.sh \
      https://raw.githubusercontent.com/MrAlders0n/MeshCoreScripts/main/g2flasher/bootstrap.sh
    less /tmp/bootstrap.sh        # optional: read it before running it
    sudo bash /tmp/bootstrap.sh

bootstrap.sh migrates an *existing* install — it expects `/opt/g2flasher/venv`
and `/opt/g2flasher/g2flasher.env` to be there already, and aborts rather than
guessing if either is missing.

## Updating

    ssh cadmin@172.30.50.48
    sudo g2flasher-update

That pulls, reinstalls dependencies only if `requirements.txt` changed,
reinstalls the systemd unit only if it changed, restarts the service, and
reports the SD lock state.

If the SD is overlay-locked, both scripts refuse rather than write changes that
would vanish on the next reboot. Unlock first:

    sudo sd-unlock          # reboots
    sudo g2flasher-update
    sudo sd-lock            # reboots, only if you want it locked again
```

- [ ] **Step 2: Fix the stale test reference in the README**

The `## Notes` section currently claims `python -m pytest tests/ -v`. No pytest suite has ever existed. Replace that line with:

```markdown
- Run the shell tests: `bash tests/run_tests.sh` from `g2flasher/`.
  (There is no Python test suite yet.)
```

- [ ] **Step 3: Mark the old spec's Deployment section superseded**

In `docs/superpowers/specs/2026-08-07-g2flasher-design.md`, insert directly under the `## Deployment` heading:

```markdown
> **Superseded 2026-08-25** by
> `2026-08-25-g2flasher-git-deployment-design.md`. The rsync flow below is
> kept for history; the Pi now runs from a git checkout at
> `/opt/MeshCoreScripts` and updates with `sudo g2flasher-update`.
```

- [ ] **Step 4: Verify and commit**

```bash
cd /Users/schnobbc/Documents/Github/MeshCore_Scripts/MeshCoreScripts
grep -n "rsync" g2flasher/README.md || echo "OK: no rsync instructions left in the README"
grep -n "pytest" g2flasher/README.md || echo "OK: no stale pytest reference left"
git add g2flasher/README.md docs/superpowers/specs/2026-08-07-g2flasher-design.md
git commit -m "Document the git-based install and update flow"
```

Expected: both `grep`s report OK.

---

### Task 5: Deploy to the Pi and verify end to end

**Files:** none changed — this task exercises the real device.

**Interfaces:**
- Consumes: everything from Tasks 1–4, pushed to `main`.

**Prerequisite:** you need a MeshCore `.bin` for the Station G3 on the machine running the browser, for Step 4. Ask the user for one before starting if you do not have it.

- [ ] **Step 1: Push to GitHub**

`bootstrap.sh` clones from GitHub, so nothing works until the commits are pushed. This is the ordering trap in this plan.

```bash
cd /Users/schnobbc/Documents/Github/MeshCore_Scripts/MeshCoreScripts
git push origin main
git log --oneline -6
```

Verify the raw file is actually reachable before touching the Pi:

```bash
curl -fsSL https://raw.githubusercontent.com/MrAlders0n/MeshCoreScripts/main/g2flasher/bootstrap.sh | head -5
```

Expected: the script's shebang and header comment.

- [ ] **Step 2: Record the pre-migration state**

```bash
ssh cadmin@172.30.50.48 'sudo /usr/local/sbin/sd-status; systemctl is-active g2flasher; ls /opt/g2flasher; sudo systemctl show -p ExecStart g2flasher'
```

Expected: `UNLOCKED`, `active`, the old flat file list, and an `ExecStart` pointing at `/opt/g2flasher/app.py`. If `sd-status` reports LOCKED, run `sudo sd-unlock` and wait ~45s for the reboot before continuing.

- [ ] **Step 3: Run the migration**

```bash
ssh cadmin@172.30.50.48 'curl -fsSL -o /tmp/bootstrap.sh https://raw.githubusercontent.com/MrAlders0n/MeshCoreScripts/main/g2flasher/bootstrap.sh && sudo bash /tmp/bootstrap.sh'
```

Expected: git installs, the clone lands, stale files are listed as removed, the service restarts active, the backup dir and home venv are removed, and it ends with `UNLOCKED — root filesystem writable`.

Then confirm the service really runs from the checkout, and that the password survived:

```bash
ssh cadmin@172.30.50.48 'sudo systemctl show -p ExecStart g2flasher; ls -la /opt/g2flasher; ls /opt/MeshCoreScripts/g2flasher; sudo test -f /opt/g2flasher/g2flasher.env && echo "env file intact"'
```

Expected: `ExecStart` now names `/opt/MeshCoreScripts/g2flasher/app.py`; `/opt/g2flasher` contains only `venv/` and `g2flasher.env`; `env file intact`.

- [ ] **Step 4: Verify the app end to end**

Ask the user to do this part — it needs a browser and a real radio:

1. Browse to `http://172.30.50.48/`, log in as `admin`, confirm the stats tiles populate from the live repeater.
2. Upload the G3 `.bin` and flash it, watching the log stream.
3. Confirm the flash reports success and stats resume afterwards showing the firmware version.

STOP here if the flash fails. Recovery is `sudo systemctl stop g2flasher` plus a manual `esptool` run; the previous code is still in git history, and `/opt/MeshCoreScripts` can be reset with `git -C /opt/MeshCoreScripts reset --hard <old-sha>`.

- [ ] **Step 5: Verify idempotency**

```bash
ssh cadmin@172.30.50.48 'sudo bash /tmp/bootstrap.sh'
ssh cadmin@172.30.50.48 'sudo g2flasher-update'
```

Expected: bootstrap re-runs cleanly with nothing left to prune; `g2flasher-update` reports `Already up to date at <sha>.`, restarts the service, and prints `UNLOCKED`. Neither should error.

- [ ] **Step 6: Prove the update path works for real**

Make a trivial tracked change, push it, and pull it through:

```bash
cd /Users/schnobbc/Documents/Github/MeshCore_Scripts/MeshCoreScripts
printf '\n<!-- deployment verified %s -->\n' "$(date +%Y-%m-%d)" >> g2flasher/templates/index.html
git add g2flasher/templates/index.html
git commit -m "Verify the git update path end to end"
git push origin main
ssh cadmin@172.30.50.48 'sudo g2flasher-update'
ssh cadmin@172.30.50.48 'tail -2 /opt/MeshCoreScripts/g2flasher/templates/index.html'
```

Expected: the helper reports `Updated <old> -> <new>`, does NOT run pip (requirements unchanged), does NOT reinstall the unit, restarts cleanly, and the comment is present on the Pi.

- [ ] **Step 7: Report the final state**

```bash
ssh cadmin@172.30.50.48 'sudo /usr/local/sbin/sd-status; systemctl is-active g2flasher; git -C /opt/MeshCoreScripts log --oneline -1'
```

Expected: `UNLOCKED`, `active`, and the checkout's HEAD matching `origin/main`. Per the approved spec the box is deliberately left unlocked — do not run `sd-lock`.

---

## Notes for the executor

- The Pi is a live relay-site box. Every command in Task 5 is real and mostly irreversible in effect; nothing there is a dry run.
- If a step fails on the Pi, the previous install is recoverable: `/opt/g2flasher.bak-20260821-173809` still exists until Task 5 Step 3's housekeeping removes it. Do not remove it by hand earlier.
- Do not modify `app.py`, `devices.py`, `flasher.py`, `stats.py`, or `templates/index.html` beyond the verification comment in Task 5 Step 6. G2 and G3 support already works; this plan only changes how the code gets to the Pi.
