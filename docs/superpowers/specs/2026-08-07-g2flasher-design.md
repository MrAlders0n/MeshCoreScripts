# g2flasher — Web-based Station G2 firmware flasher with live stats

**Date:** 2026-08-07
**Status:** Approved design

## Purpose

A small password-protected web app hosted on the Raspberry Pi at `172.30.50.48`
(`CBC-FORTUNE-R1-PI`). Browsing to it lets you:

1. Upload a MeshCore firmware `.bin` and flash the Station G2 connected to the
   Pi via USB, watching esptool output live in the browser.
2. See live repeater stats (polled over the G2's serial CLI) while the page is
   open. Nothing is stored — display only.

The Pi stays minimal: one Python process, no database, no extra services.

## Context

- The flash mechanics come from `flash_g2_firmware.py` in this repo (serial-only
  variant — no GPIO relays on this Pi).
- The architecture (background flash worker, polled status dict, SHA256-verified
  upload, serial CLI stats protocol) is adapted from
  [MrAlders0n/RepeaterWatch](https://github.com/MrAlders0n/RepeaterWatch), which
  the user deliberately does **not** want to run here — it's too heavy for this
  Pi. RepeaterWatch's flasher targets an nRF52 (adafruit-nrfutil); this device
  is an ESP32-S3 flashed with esptool, so only the architecture transfers, not
  the flash commands.
- Pi environment (verified): Debian 13 (trixie) aarch64, Python 3.13, ~2GB RAM.
  Only bluetooth runs beyond the base system; nothing holds the serial port.
  G2 appears as `/dev/serial/by-id/usb-Espressif_Systems_BQ_Station_G2_*`.
  `sudo` requires a password → one-time install steps are run by the user.

## Decisions (from brainstorming)

- **Firmware source:** browser upload only. No release fetching.
- **Relays:** none. Serial-only flash flow.
- **Auth:** HTTP basic auth with a single shared password, stored in an env
  file on the Pi (never in git).
- **Stats:** live display only, never stored.

## Architecture

One Flask process, deployed to `/opt/g2flasher` on the Pi, run by systemd as
`cadmin`. Code lives in this repo under `g2flasher/`.

```
g2flasher/
├── app.py               # Flask app: routes, basic auth, upload handling
├── flasher.py           # Flash worker: state dict, background thread, esptool subprocess
├── stats.py             # SerialReader + stats poller (trimmed from RepeaterWatch, no DB)
├── templates/
│   └── index.html       # Single page: stats tiles, upload, flash button, live log
├── requirements.txt     # flask, esptool, pyserial
├── g2flasher.service    # systemd unit
└── README.md            # install steps for the Pi
```

### Device detection

Shared helper that lists `/dev/serial/by-id` and classifies the device
(hints from `flash_g2_firmware.py`):

- name contains `Station_G2` → **normal mode** (CLI available, can poll stats)
- name contains `Espressif_USB_JTAG` → **bootloader mode** (no CLI; flash only)
- neither → **disconnected**

### HTTP API

All routes behind basic auth (username `admin`, password from env file).

| Route | Method | Behavior |
|---|---|---|
| `/` | GET | The single page. |
| `/api/status` | GET | `{state, progress, log, device}` — flash state machine (`idle\|flashing\|done\|error`), log lines, and current device mode. Polled by the page every 1s during a flash, slower otherwise. |
| `/api/stats` | GET | Latest stats snapshot + device info + snapshot age in seconds. Requesting this marks "someone is watching" for poll gating. |
| `/api/flash` | POST | Multipart: `firmware` (`.bin` file). 409 if a flash is running. Validates extension and ≤16MB size cap. Saves to a temp dir, computes the file's SHA256 server-side and reports it in the flash log (browser-side hashing is impossible: SubtleCrypto is disabled in non-HTTPS contexts). Kicks the background flash thread, returns `{"status": "started"}`. esptool's own post-write hash verification is the integrity check that matters. |

### Flash worker (`flasher.py`)

Thread-safe module-level state `{state, progress, log}` guarded by a lock,
same pattern as RepeaterWatch's `firmware_flasher.py`. One flash at a time.

Sequence (mechanics from `flash_g2_firmware.py`):

1. Stop the stats poller (releases the serial port). In-process call — no
   systemctl, no sudoers.
2. Find device. If **normal mode**: enter bootloader via 1200-baud touch —
   `esptool --port <dev> --baud 1200 --after no_reset chip_id` — then wait 8s.
   If already in **bootloader mode**: skip the touch.
3. Re-find device (now the `Espressif_USB_JTAG` port).
4. Run `python -m esptool --port <dev> write_flash 0x10000 <bin>` as a
   **subprocess**, streaming each stdout line into the log. Subprocess (not
   `esptool.main()` in-process) so a crash can't take down the server and
   output capture is exact. esptool's default `--after hard_reset` reboots the
   device into normal mode on success.
5. Exit code 0 → `done`; nonzero → `error`. 300s timeout kills the process.
6. Delete the uploaded file, restart the stats poller. The poller re-collects
   device info on reconnect, so the new firmware version appearing in the
   stats tiles confirms the flash visibly.

Error paths (no device found, esptool failure, timeout) all land in `error`
with the full log preserved on the page.

### Stats poller (`stats.py`)

Trimmed from RepeaterWatch's `SerialReader`/`StatsPoller`: same serial
protocol, no database, no packet parsing, no Pi-health metrics.

- **Protocol:** 115200 baud on the by-id device path. Commands are sent as
  `<cmd>\r\n`; responses arrive prefixed `-> ` (JSON for stats commands,
  plain text for `get`/`ver`/`board`).
- **Device info** (once per connect, and after every flash): `get name`,
  `get public.key`, `get radio`, `get lat`, `get lon`, `ver`, `board`.
- **Stats cycle** (every ~10s): `stats-core`, `stats-radio`, `stats-packets`.
  Latest JSON kept in a thread-safe in-memory snapshot; previous values are
  overwritten. Noise-floor value of exactly 0 is treated as missing
  (firmware 1.14.x AGC-reset quirk, per RepeaterWatch).
- **Poll gating — mode:** before each connect/cycle, check device mode via
  the by-id listing. **Bootloader mode → do not open serial / do not poll**
  (the CLI doesn't exist there); page shows "in bootloader mode".
  Disconnected → cheap directory checks only. Normal mode → poll.
- **Poll gating — viewers:** only issue serial commands if `/api/stats` was
  requested within the last 60s. No browser open → the serial port stays
  quiet.
- **Graceful degradation:** if firmware doesn't answer the CLI (e.g. a
  companion build was flashed), stats show "unavailable"; flashing still
  works.

### Page (`index.html`)

Single page, plain HTML/CSS/JS, no frontend framework. Visual design follows
the frontend-design skill — the user wants a modern, clean interface (not
templated-bootstrap defaults):

- **Stats tiles** (top): device name, firmware version, board, radio config,
  uptime, battery voltage, noise floor, last RSSI/SNR, packet counters
  (recv / sent / fwd / dups). Grayed out when the snapshot is stale; replaced
  by a mode banner when the device is in bootloader mode or disconnected.
- **Flash section**: file picker for `.bin`, shows name/size after selection
  (the upload's SHA256 appears in the flash log, computed server-side), Flash
  button with a confirmation step, then a live log console (the esptool
  output) with a state badge (flashing / done / error).
- Polling: `/api/stats` every 10s; `/api/status` every 1s while a flash is
  active, every 5s otherwise.

## Security

- HTTP basic auth on every route; password lives in
  `/opt/g2flasher/g2flasher.env` (`G2FLASHER_PASSWORD=...`), mode 600,
  referenced by the systemd unit via `EnvironmentFile=`. Not in git.
- Plain HTTP on a trusted LAN — accepted risk, user's call.
- Upload constraints: `.bin` extension, 16MB cap. Server reports the upload's
  SHA256 in the flash log for manual comparison against published checksums;
  esptool verifies the written flash after writing (integrity, not
  authenticity — any valid upload is trusted; the user is the only operator).

## Deployment

> **Superseded 2026-08-25** by
> `2026-08-25-g2flasher-git-deployment-design.md`. The rsync flow below is
> kept for history; the Pi now runs from a git checkout at
> `/opt/MeshCoreScripts` and updates with `sudo g2flasher-update`.

- `rsync` the `g2flasher/` folder to the Pi; create a venv;
  `pip install -r requirements.txt`.
- systemd unit runs as `cadmin`, binds port 80 via
  `AmbientCapabilities=CAP_NET_BIND_SERVICE` (no root, no reverse proxy).
- One-time steps for the user (password sudo): create `/opt/g2flasher`,
  ensure `cadmin` is in `dialout`, install + enable the unit, create the env
  file with the chosen password.

## Testing

- Local (Mac): app starts, auth rejects/accepts correctly, upload validation
  (extension/size/hash) works, status endpoints return sane shapes with no
  device present.
- On the Pi, end-to-end: stats tiles populate from the live repeater; then a
  real flash with a user-provided `.bin`, watching the log stream; stats
  resume afterward showing the new firmware version. Bootloader-mode gating
  verified by observing the mode banner during the flash window.

## Out of scope (YAGNI)

- Fetching firmware releases from the internet
- GPIO relay power-cycling
- Storing any history / charts / database
- HTTPS, multi-user auth, sessions
- Support for devices other than the Station G2
