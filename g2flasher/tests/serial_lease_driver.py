"""Run one flasher._flash_worker pass with the hardware faked out.

Driven by test_flasher_serial_lease.sh, which puts stub systemctl/sudo on PATH.
esptool and device detection are replaced here; the fake esptool writes a marker
into the same log the systemctl stub appends to, so the shell test can assert on
the ORDER of stop / flash / restart, not just that each happened.

Environment: APP_DIR, DRIVE_FW, STUB_SYSTEMCTL_LOG, and optionally
DRIVE_ESPTOOL_RC (default 0), DRIVE_RAISE=1 to make the flash throw, or
DRIVE_MODE=normal to take the 1200-baud touch path and fail to reach the
bootloader, which is what surfaces esptool's output for diagnosis.
"""
import os
import sys

sys.path.insert(0, os.environ["APP_DIR"])

import devices
import flasher

LOG = os.environ["STUB_SYSTEMCTL_LOG"]
ESPTOOL_RC = int(os.environ.get("DRIVE_ESPTOOL_RC", "0"))
RAISE = os.environ.get("DRIVE_RAISE") == "1"
MODE = os.environ.get("DRIVE_MODE", "bootloader")

# Verbatim from a Station G3: the touch drops the device off USB mid-open, and
# esptool reports it as an unhandled exception.
TOUCH_OUTPUT = [
    "Serial port /dev/serial/by-id/usb-Espressif_Systems_Station_G3_ESP32_XXXX-if00",
    "Connecting...Traceback (most recent call last):",
    '  File "<frozen runpy>", line 198, in _run_module_as_main',
    '  File "/opt/venv/lib/python3.13/site-packages/esptool/loader.py", line 788, in connect',
    "    last_error = self._connect_attempt(reset_strategy, mode)",
    "    ~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^",
    "BrokenPipeError: [Errno 32] Broken pipe",
]


def fake_run_esptool(args, timeout, echo=True):
    with open(LOG, "a") as f:
        f.write("esptool %s\n" % " ".join(args))
    if RAISE:
        raise RuntimeError("simulated esptool crash")
    if not echo:
        return 1, TOUCH_OUTPUT   # the touch always "fails" — the device drops off
    return ESPTOOL_RC, []


# In bootloader mode the touch and its waits are skipped, leaving exactly one
# esptool call to order against. In normal mode the device never comes back, so
# the run takes the diagnostic path.
devices.detect = lambda: ({"mode": "normal", "path": "/dev/fake-port"} if MODE == "normal"
                          else {"mode": "bootloader", "path": "/dev/fake-port"})
flasher._run_esptool = fake_run_esptool
flasher.TOUCH_SETTLE_SECS = 0
if MODE == "normal":
    flasher.BOOTLOADER_WAIT_SECS = 0   # give up at once; the port never returns

flasher._flash_worker(os.environ["DRIVE_FW"])

status = flasher.get_status()
print("STATE=%s" % status["state"])
for line in status["log"]:
    print("LOG %s" % line)
