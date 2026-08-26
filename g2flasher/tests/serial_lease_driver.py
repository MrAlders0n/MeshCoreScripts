"""Run one flasher._flash_worker pass with the hardware faked out.

Driven by test_flasher_serial_lease.sh, which puts stub systemctl/sudo on PATH.
esptool and device detection are replaced here; the fake esptool writes a marker
into the same log the systemctl stub appends to, so the shell test can assert on
the ORDER of stop / flash / restart, not just that each happened.

Environment: APP_DIR, DRIVE_FW, STUB_SYSTEMCTL_LOG, and optionally
DRIVE_ESPTOOL_RC (default 0) or DRIVE_RAISE=1 to make the flash throw.
"""
import os
import sys

sys.path.insert(0, os.environ["APP_DIR"])

import devices
import flasher

LOG = os.environ["STUB_SYSTEMCTL_LOG"]
ESPTOOL_RC = int(os.environ.get("DRIVE_ESPTOOL_RC", "0"))
RAISE = os.environ.get("DRIVE_RAISE") == "1"


def fake_run_esptool(args, timeout, echo=True):
    with open(LOG, "a") as f:
        f.write("esptool %s\n" % " ".join(args))
    if RAISE:
        raise RuntimeError("simulated esptool crash")
    return ESPTOOL_RC, []


class FakePoller:
    def start(self):
        pass

    def stop(self):
        pass


# Report the station as already in the bootloader: that skips the 1200-baud
# touch and its sleeps, leaving exactly one esptool call to order against.
devices.detect = lambda: {"mode": "bootloader", "path": "/dev/fake-port"}
flasher._run_esptool = fake_run_esptool

flasher._flash_worker(os.environ["DRIVE_FW"], FakePoller())

status = flasher.get_status()
print("STATE=%s" % status["state"])
for line in status["log"]:
    print("LOG %s" % line)
