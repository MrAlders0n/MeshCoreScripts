# g2flasher — Git-controlled deployment

**Date:** 2026-08-25
**Status:** Approved design
**Host:** `cadmin@172.30.50.48` — CBC-FORTUNE-R1-PI
**Supersedes:** the Deployment section of `2026-08-07-g2flasher-design.md` (rsync-based)

## Purpose

Put the running g2flasher app under version control and make updating the Pi a
`git pull` instead of a tarball-and-rsync ritual. Today the only copy of a
working, G3-capable app is a 14KB tarball; the repo holds design documents and
nothing else.

## Current state (verified on the box, 2026-08-25)

| Fact | Value |
|---|---|
| Deployed app | `/opt/g2flasher`, service `g2flasher` enabled + active |
| Deployed == tarball | Yes — all 8 files match SHA256 |
| Device support | G2 **and** G3 already work (`devices.py` hints `Station_G2`, `Station_G3`) |
| SD lock state | **UNLOCKED** since the 2026-08-21 G3 deploy — root is plain `ext4 rw` |
| `git` | **Not installed** (candidate `1:2.47.3-0+deb13u1`) |
| Mirrors + GitHub | `deb.debian.org`, `archive.raspberrypi.com`, `github.com` all reachable |
| Free space | 52G on root |
| Repo visibility | `MrAlders0n/MeshCoreScripts` is **public**, default branch `main` |

Both stations are ESP32-S3 with identical flash layout, so one flow covers both;
only the USB by-id name differs. No second toolchain is needed.

The rest of `2026-08-07-pi-sd-longevity-design.md` is correctly applied: zram-only
swap (no `/var/swap`), journald `Storage=volatile` (no `/var/log/journal`), wifi/bt
disabled via `config.txt` overlays, apt/man-db/dpkg timers removed, `fstrim.timer`
retained, NOPASSWD sudo for `cadmin`.

## Decisions (approved 2026-08-25)

| Decision | Choice |
|---|---|
| Update model | Git checkout on the Pi + an update helper (not boot-time auto-pull) |
| Repo access | Public repo over HTTPS — no credentials, no deploy key |
| SD lock state after migration | **Leave unlocked** — updates cost no reboots |
| Overlay guard | Retained in the helper as a safety net if the box is ever re-locked |
| Housekeeping | Remove `/opt/g2flasher.bak-*` and `~/MeshCoreScripts/.venv` |
| Tests | Out of scope for this change |

Boot-time auto-pull was rejected: `cadmin` has passwordless sudo, so automatically
executing whatever is on a remote branch would effectively be remote root. Under
this design nothing is fetched or run without a human typing the update command.

## Design

### Repo layout

The tarball's files are imported verbatim to `g2flasher/` — `app.py`, `devices.py`,
`flasher.py`, `stats.py`, `templates/index.html`, `requirements.txt`,
`g2flasher.service`, `README.md` — plus two new scripts (`bootstrap.sh`,
`g2flasher-update`) and a root `.gitignore` (the repo currently has none) covering
`venv/`, `.venv/`, `__pycache__/`, `*.pyc`, `g2flasher.env`.

`deploy.sh` is **not** imported — it is the tarball-era mechanism this design
replaces. `g2flasherg3update.tar.gz` is removed from the repo root once its
contents are tracked.

The Python needs no modification: it contains no hardcoded Pi paths and no
secrets, so a checkout runs anywhere. Only `g2flasher.service` changes.

### Pi layout

Code and machine-local state are deliberately separate, so git operations can
never touch the venv or the password:

```
/opt/MeshCoreScripts/          # git clone, cadmin-owned, tracked
  └── g2flasher/               # the app
/opt/g2flasher/                # machine-local, NOT in git — unchanged
  ├── venv/                    # stays exactly as-is
  └── g2flasher.env            # stays exactly as-is, mode 600
```

The venv and password file do not move, so the migration requires no venv rebuild
and no re-entering the password. The stale `.py` files under `/opt/g2flasher` are
deleted so there is exactly one source of truth.

Revised `g2flasher.service` — three lines change, the rest is untouched:

```
WorkingDirectory=/opt/MeshCoreScripts/g2flasher
EnvironmentFile=/opt/g2flasher/g2flasher.env
ExecStart=/opt/g2flasher/venv/bin/python /opt/MeshCoreScripts/g2flasher/app.py
```

`app.py` imports `devices`/`flasher`/`stats` as top-level modules and Flask
resolves `templates/` relative to the module directory, so both work unchanged
once the script lives in the checkout.

### `g2flasher/bootstrap.sh` — one-time migration

Run as root on the Pi, and idempotent (safe to re-run):

1. Require root; refuse if root fs is `overlay` (must be unlocked to install).
2. Install `git` if absent. Fail loudly if apt cannot reach the mirrors rather
   than half-migrating.
3. Clone `https://github.com/MrAlders0n/MeshCoreScripts.git` to
   `/opt/MeshCoreScripts` **as `cadmin`** (`runuser -u cadmin --`), so the
   checkout is never root-owned. If it already exists, fetch and fast-forward.
4. Assert `/opt/g2flasher/venv` and `/opt/g2flasher/g2flasher.env` exist — this
   is a migration, not a fresh install, and should abort rather than guess.
5. `pip install -r /opt/MeshCoreScripts/g2flasher/requirements.txt` into the existing
   venv at `/opt/g2flasher/venv` (idempotent).
6. Delete the now-duplicated files from `/opt/g2flasher`: `app.py`, `devices.py`,
   `flasher.py`, `stats.py`, `requirements.txt`, `requirements-dev.txt`,
   `README.md`, `g2flasher.service`, `__pycache__/`, `templates/`. Keep `venv/`
   and `g2flasher.env`.
7. Install `g2flasher-update` to `/usr/local/sbin`, root-owned, mode 755.
8. Install the revised unit, `daemon-reload`, restart, assert active.
9. Housekeeping: remove `/opt/g2flasher.bak-*` and `~cadmin/MeshCoreScripts/.venv`.
10. Print `sd-status` so the ending lock state is never ambiguous.

### `g2flasher-update` — the steady-state command

Installed to `/usr/local/sbin` (present in sudo's `secure_path`, so
`sudo g2flasher-update` resolves; note `/usr/local/sbin` is *not* in `cadmin`'s
non-login SSH `PATH`, so the bare name will not).

1. Require root.
2. If root fs is `overlay`, refuse and say to run `sudo sd-unlock` first. This is
   inert while the box stays unlocked, and correct if it is ever re-locked.
3. Record `HEAD`, then `git pull --ff-only` **as `cadmin`**. `--ff-only` means a
   diverged or force-pushed branch stops with an error instead of merging.
4. `git diff --name-only OLD..HEAD` decides the rest: `pip install -r` only if
   `requirements.txt` changed; copy the unit and `daemon-reload` only if it
   differs from the installed one.
5. `systemctl restart g2flasher`, then show status.
6. Print `sd-status`.

**Self-update:** the helper runs from `/usr/local/sbin`, not from the checkout, so
a pull never rewrites the file bash is mid-way through reading. When the repo copy
differs, the last step installs it to a temp file and `mv`s it into place — an
atomic rename, so the running process keeps its original inode and the new version
takes effect on the next invocation.

## Update workflow (steady state)

```
ssh cadmin@172.30.50.48
sudo g2flasher-update
```

No reboots, because the box stays unlocked. If it is ever re-locked, the flow
becomes `sudo sd-unlock` → `sudo g2flasher-update` → `sudo sd-lock`, at the cost
of two reboots — that is the read-only SD's price, not something the script can
optimize away.

## Security

- Public repo over HTTPS: no credentials on the Pi, nothing secret on the SD.
- Nothing is fetched or executed without a human running the update command.
- `--ff-only` prevents a rewritten branch from silently deploying.
- The checkout is `cadmin`-owned; running git as root would break later pulls.
- `g2flasher.env` (mode 600) and the venv are outside the checkout, so they cannot
  be clobbered by a pull or accidentally committed. `.gitignore` is a second layer,
  not the mechanism.

## Testing

**Local (Mac):** `shellcheck` both scripts; exercise the overlay guard and the
requirements-changed branch against a fixture repo.

**On the Pi, in order:**
1. Run `bootstrap.sh`; assert the service is active and
   `systemctl show -p ExecStart` points into `/opt/MeshCoreScripts`.
2. Load the web UI, confirm auth and that stats populate from the live repeater.
3. Flash a real G3 end-to-end and watch the log stream.
4. Re-run `bootstrap.sh` and `g2flasher-update` to prove both are idempotent
   no-ops when already current.

## Out of scope

- The pytest suite the original plan specified (`tests/` is referenced by the
  README but has never existed). Deliberately deferred; orthogonal to deployment.
- Boot-time auto-pull, and any change to the SD lock state.
- `flash_g2_firmware.py` / `flash_g2_firmware_relays.py`. Noted but not fixed:
  both call `find_device(hint, True)` on their retry path, where `hint` is
  undefined and the arity is wrong, so that fallback raises `NameError` instead
  of retrying.
