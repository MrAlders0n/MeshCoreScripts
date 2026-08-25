# g2flasher

Web-based firmware flasher + live stats for a MeshCore Station G2 or
Station G3 connected to a Raspberry Pi over USB. Upload a `.bin`, watch
esptool run, see repeater stats while the page is open. Nothing is stored
on the Pi.

Both stations are ESP32-S3 boards with the same 16MB flash layout, so the
flash flow is identical; only the USB device name differs (`BQ_Station_G2_*`
vs `Station_G3_ESP32_*`).

## Install (on the Pi)

From your workstation, sync the code:

    rsync -a --delete --exclude .venv --exclude tests --exclude __pycache__ \
        g2flasher/ cadmin@172.30.50.48:/tmp/g2flasher-src/

Then on the Pi (`ssh cadmin@172.30.50.48`), one-time setup — needs sudo:

    sudo mkdir -p /opt/g2flasher
    sudo chown cadmin:cadmin /opt/g2flasher
    sudo usermod -aG dialout cadmin        # serial port access
    
    # Group membership takes effect on new login; log out and back in (or reboot)
    # before running g2flasher manually from this shell. (systemd service is unaffected.)
    
    rsync -a --delete --exclude venv --exclude g2flasher.env /tmp/g2flasher-src/ /opt/g2flasher/
    python3 -m venv /opt/g2flasher/venv
    /opt/g2flasher/venv/bin/pip install -r /opt/g2flasher/requirements.txt
    echo 'G2FLASHER_PASSWORD=CHANGE-ME' > /opt/g2flasher/g2flasher.env
    chmod 600 /opt/g2flasher/g2flasher.env
    sudo cp /opt/g2flasher/g2flasher.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now g2flasher

Browse to http://172.30.50.48/ — username `admin`, password as set above.

## Updating

    rsync -a --delete --exclude .venv --exclude tests --exclude __pycache__ \
        --exclude venv --exclude g2flasher.env \
        g2flasher/ cadmin@172.30.50.48:/opt/g2flasher/
    ssh cadmin@172.30.50.48 sudo systemctl restart g2flasher

(Direct rsync to /opt works after first install since cadmin owns it; the
service restart needs sudo.)

## Notes

- Flash sequence: 1200-baud bootloader touch → `esptool write_flash 0x10000`.
- Stats poll only runs while a browser has the page open, and never while
  the device is in bootloader mode.
- Environment: `G2FLASHER_PASSWORD` (required), `G2FLASHER_PORT` (default 80).
- Run tests: `python -m pytest tests/ -v` from `g2flasher/`.
