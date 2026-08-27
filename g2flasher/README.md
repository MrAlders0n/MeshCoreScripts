# g2flasher

Web-based firmware flasher for a MeshCore Station G2 or Station G3
connected to a Raspberry Pi over USB. Upload a `.bin`, watch esptool run.
Nothing is stored on the Pi.

Nothing here opens the radio's serial port except esptool, during a flash.
The page reports whether a station is attached and which port it is on,
and that comes from the device node in `/dev/serial/by-id`, not from
talking to the radio.

Both stations are ESP32-S3 boards with the same 16MB flash layout, so the
flash flow is identical; only the USB device name differs (`BQ_Station_G2_*`
vs `Station_G3_ESP32_*`).

## Layout

Code is a git checkout; machine-local state is not:

    /opt/MeshCoreScripts/       # this repo, owned by the service account
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

Browse to the Pi on port 80 — username `admin`, password from
`/opt/g2flasher/g2flasher.env`. Which address that is depends on how the host
is reachable: a deployment that firewalls port 80 off the LAN and reaches it
over a VPN or overlay network will not answer on its LAN address at all.

## Updating

    ssh <service-account>@<pi>
    sudo g2flasher-update

That pulls, reinstalls dependencies only if `requirements.txt` changed,
reinstalls the systemd unit only if it changed, restarts the service, and
reports the SD lock state.

If the SD is overlay-locked, both scripts refuse rather than write changes that
would vanish on the next reboot. Unlock first:

    sudo sd-status          # read-only: which mode am I in?
    sudo sd-unlock          # reboots
    sudo g2flasher-update
    sudo sd-lock            # reboots, only if you want it locked again

These live in `/usr/local/sbin`, which is on sudo's `secure_path` but not on a
normal user's `PATH` — hence `sudo`, and hence `command -v sd-lock` finding
nothing when you check as yourself.

While locked, `systemctl --failed` permanently lists
`systemd-remount-fs.service`. That is expected, not a fault: the unit applies
fstab options to `/` at boot, and the kernel refuses to reconfigure an overlay
mount (`overlay: No changes allowed in reconfigure`). It clears on unlock. One
failed unit with that name is the correct baseline while locked; anything else
is real.

## Sharing the radio with a telemetry daemon

Some sites run a daemon beside g2flasher that streams the radio's packet log to
MQTT (Cisien/meshcoretomqtt is the usual one). It holds the station's serial
port open continuously — the same port esptool needs.

**This does not fail loudly.** The daemon does not open the port exclusively, so
esptool's own open succeeds and nothing reports a conflict; the two just share
the stream, and the daemon's reads swallow bootloader replies while its device
polling injects bytes into the flashing protocol. A flash started while
telemetry is running does not error out — it corrupts or stalls, usually on
hardware that is nowhere near you. Do not write code or docs here that expect a
port-busy error; there is none to catch. A serial multiplexer is no answer
either: the flash begins with a 1200-baud touch, and a PTY forwards neither
baud changes nor control-line changes.

So a flash stops that unit first and starts it again when it is done:

- The unit is named by `G2FLASHER_SERIAL_UNIT` (default `mctomqtt`).
- Nothing happens unless `systemctl is-active` reports the unit running, so a
  host with no such daemon pays one unprivileged query per flash and logs
  nothing.
- A unit that was already stopped is left stopped — an operator may have
  stopped it deliberately.
- The restart runs in a `finally`, so a flash that fails or throws part-way
  still puts telemetry back.
- Both actions appear in the flash log in the web UI, rather than happening
  invisibly.

Telemetry units of this kind typically set `Restart=always`. That does not fight
an explicit `systemctl stop` — systemd honours the stop — so there is no race
back onto the port mid-flash.

Stopping a unit needs privilege, and g2flasher runs as an unprivileged service
account. It tries two routes, in this order:

1. **Directly.** `systemctl` is not setuid — it hands the request to PID 1 over
   D-Bus and polkit decides. Grant the service account this one unit with a
   polkit rule matching `org.freedesktop.systemd1.manage-units` on the unit
   name, for the `start` and `stop` verbs only.
2. **Through `sudo -n`**, for deployments that grant the rights in sudoers
   instead.

Prefer the first. Our own unit sets `NoNewPrivileges=true`, and that flag stops
sudo becoming root at all — whatever sudoers says, sudo fails with *"the no new
privileges flag is set"*. Nothing about the D-Bus route is affected by it, so
the polkit rule works with the hardening left on.

Where neither is permitted, g2flasher logs both refusals and flashes anyway: a
disrupted flash beats one that never starts.

**Known limitation:** if the g2flasher process itself is killed mid-flash, the
`finally` never runs and the unit stays down until someone starts it —
`Restart=always` does not help, because the stop was explicit. The uploaded
firmware from that run is cleaned up on the next start, but the unit is not.
Keep a manual stop/start runbook as the fallback:

    systemctl is-active <unit>
    sudo systemctl start <unit>

## Notes

- Flash sequence: 1200-baud bootloader touch → `esptool write_flash 0x10000`.
- The page never opens the serial port, so it cannot contend with a flash
  or with anything else on the host.
- Environment: `G2FLASHER_PASSWORD` (required), `G2FLASHER_PORT` (default 80),
  `G2FLASHER_SERIAL_UNIT` (default `mctomqtt`, see above).
- Run the shell tests: `bash tests/run_tests.sh` from `g2flasher/`.
  The `.py` files under `tests/` are fixtures those shell tests drive, not a
  suite of their own — there is still no Python test runner here.
