# CBC-FORTUNE-R1-PI: SD-Card Longevity & Remote Deployment Design

**Date:** 2026-08-07
**Host:** `cadmin@172.30.50.48` — Raspberry Pi 4B (2GB), Debian 13 (trixie), 58GB SD card
**Role:** Remote MeshCore relay-site management box. SSH in occasionally to flash/configure
an attached Station G2 radio over serial/USB. Ethernet-only; Pi mostly idles.

## Goal

The SD card should essentially never be written to, and a power cut should never be able
to corrupt it. Maintenance stays one-command simple over SSH.

## Decisions (approved 2026-08-07)

| Decision | Choice |
|---|---|
| Protection strategy | Read-only overlay root (raspi-config OverlayFS) + write-elimination underneath |
| OS updates | Manual only — apt timers disabled |
| Radios | WiFi + Bluetooth disabled at firmware level; avahi off (Ethernet-only site) |
| Workload prep | esptool venv + repo flashing scripts staged before locking |

## Design

### 1. Write elimination (lower layer, while writable)

- **Swap:** `rpi-swap` mechanism forced to `zram` (pure RAM-compressed swap) via
  `/etc/rpi/swap.conf.d/90-zram-only.conf`. This stops the generator creating the
  nightly `rpi-zram-writeback.timer` and the 1.9GB `/var/swap` backing file (deleted).
- **Logs:** journald `Storage=volatile`, `RuntimeMaxUse=32M`
  (`/etc/systemd/journald.conf.d/10-volatile.conf`); `/var/log/journal` removed.
  Logs live in RAM, survive until reboot.
- **Timers off:** `apt-daily`, `apt-daily-upgrade`, `man-db`, `dpkg-db-backup`.
  `fstrim.timer` stays (helps wear leveling during unlocked windows).
- **fstab:** root gets `commit=60` (batched journal commits during unlocked windows);
  already `noatime`. `/tmp` already tmpfs on trixie.

### 2. Radios & discovery off

- `/boot/firmware/config.txt`: `dtoverlay=disable-wifi`, `dtoverlay=disable-bt`
  (hardware-level, also saves power). Backup at `config.txt.bak`.
- Services disabled: `bluetooth`, `avahi-daemon` (+socket), `wpa_supplicant`.

### 3. Read-only overlay root + toggle helpers

- OverlayFS via the `overlayroot` package (`overlayroot=tmpfs` on the kernel cmdline,
  the mechanism trixie's `raspi-config` uses): real root mounted read-only at
  `/media/root-ro`, tmpfs upper at `/media/root-rw`; `/boot/firmware` mounted `ro`
  via fstab. All runtime writes go to RAM and vanish on reboot; the card is
  untouched and corruption-immune.
- Helpers in `/usr/local/sbin`:
  - **`sd-unlock`** — removes `overlayroot=tmpfs` from cmdline and restores boot-RW
    by editing the *real* fstab through `/media/root-ro` (remounted rw briefly),
    then reboots. Pi comes back fully writable (root + boot).
  - **`sd-lock`** — `raspi-config nonint enable_bootro` + `enable_overlayfs`,
    then reboots. Pi comes back protected.
  - **`sd-status`** — one-line state report.
- Maintenance workflow: `sudo sd-unlock` → apt/scripts/config changes → `sudo sd-lock`.

### 4. Remote resilience

- Hardware watchdog: trixie Raspberry Pi OS already ships it enabled
  (`/usr/lib/systemd/system.conf.d/40-rpi-enable-watchdog.conf`,
  `RuntimeWatchdogSec=1m`, `RebootWatchdogSec=2m`) — verified armed and fed
  (BCM2835). Kernel hang → self-reboot within ~1min; reboots are
  consequence-free under overlay. No custom override needed.
- Passwordless sudo for `cadmin` (`/etc/sudoers.d/010-cadmin-nopasswd`) so
  lock/unlock works as one command over SSH.

### 5. Workload staging

- `cadmin` added to `dialout` (serial access).
- venv at `~/MeshCoreScripts/.venv` with `esptool` installed.
- `flash_g2_firmware.py` / `flash_g2_firmware_relays.py` copied to `~/MeshCoreScripts/`.
- Full `apt full-upgrade` performed before locking so the deployed image is current.

### RAM budget

~1.8GB usable. Idle ~160MB + journal cap 32MB + tmpfs overlay upper (grows only on
writes; idle workload writes almost nothing). >1GB headroom.

## Verification (performed on bench before deployment)

1. After reboot: no loop device / `/var/swap` gone, zram-only swap, wifi/bt absent,
   journald volatile, watchdog active, timers gone.
2. Overlay on: `/` is `overlay`, `/boot/firmware` ro; test file vanishes after reboot.
3. Full `sd-unlock` → writable → `sd-lock` cycle proven over SSH only.
4. `esptool` imports inside venv; `/dev/serial` group access confirmed.

## Maintenance runbook (post-deployment)

```
ssh cadmin@<pi>          # normal state: locked, everything RAM-backed
sudo sd-unlock           # → reboots into writable mode (reconnect after ~45s)
  sudo apt update && sudo apt full-upgrade   # or edit scripts, etc.
sudo sd-lock             # → reboots back into protected mode
```

Logs are RAM-only: check `journalctl -b` *before* rebooting when debugging.
If the site loses power mid-write during an unlocked window, worst case is fsck of a
mostly-idle ext4 — the everyday locked state cannot be corrupted.
