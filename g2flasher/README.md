# g2flasher

Web-based firmware flasher + live stats for a MeshCore Station G2 or
Station G3 connected to a Raspberry Pi over USB. Upload a `.bin`, watch
esptool run, see repeater stats while the page is open. Nothing is stored
on the Pi.

Both stations are ESP32-S3 boards with the same 16MB flash layout, so the
flash flow is identical; only the USB device name differs (`BQ_Station_G2_*`
vs `Station_G3_ESP32_*`).

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

Browse to http://172.30.50.48/ — username `admin`, password from
`/opt/g2flasher/g2flasher.env`.

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

## Notes

- Flash sequence: 1200-baud bootloader touch → `esptool write_flash 0x10000`.
- Stats poll only runs while a browser has the page open, and never while
  the device is in bootloader mode.
- Environment: `G2FLASHER_PASSWORD` (required), `G2FLASHER_PORT` (default 80).
- Run the shell tests: `bash tests/run_tests.sh` from `g2flasher/`.
  (There is no Python test suite yet.)
