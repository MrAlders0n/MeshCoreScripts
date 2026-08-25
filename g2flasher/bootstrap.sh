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
