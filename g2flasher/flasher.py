"""Background firmware flash via esptool subprocess.

Sequence (from flash_g2_firmware.py): if the station is in normal mode, touch
it at 1200 baud to enter the bootloader, wait, re-detect the port, then
write_flash at 0x10000. State is a module-level dict polled by the web layer.
The Station G2 and G3 are both ESP32-S3 boards with the same flash layout, so
one flow covers both.

Anything else holding the radio's serial port has to let go for the duration:
see _release_serial_unit for why that cannot be left to fail loudly.
"""
from __future__ import annotations

import hashlib
import logging
import os
import subprocess
import sys
import threading
import time

import devices

logger = logging.getLogger(__name__)

ESPTOOL_CMD = [sys.executable, "-m", "esptool"]
FLASH_OFFSET = "0x10000"
TOUCH_SETTLE_SECS = 8
BOOTLOADER_WAIT_SECS = 15
FLASH_TIMEOUT_SECS = 300
SERIAL_UNIT_ENV = "G2FLASHER_SERIAL_UNIT"
DEFAULT_SERIAL_UNIT = "mctomqtt"
SYSTEMCTL_TIMEOUT_SECS = 30

_lock = threading.Lock()
_state = {"state": "idle", "progress": "", "log": []}


def get_status() -> dict:
    with _lock:
        return {"state": _state["state"], "progress": _state["progress"],
                "log": list(_state["log"])}


def reset_state():
    with _lock:
        _state.update({"state": "idle", "progress": "", "log": []})


def _set_state(state: str, progress: str = ""):
    with _lock:
        _state["state"] = state
        _state["progress"] = progress


def _append_log(line: str):
    with _lock:
        _state["log"].append(line)


def _fail(message: str):
    _append_log(f"ERROR: {message}")
    _set_state("error", message)


def start_flash(fw_path: str, poller) -> bool:
    """Kick off a flash in a background thread. False if one is running."""
    with _lock:
        if _state["state"] == "flashing":
            return False
        _state.update({"state": "flashing", "progress": "Starting...", "log": []})
    threading.Thread(target=_flash_worker, args=(fw_path, poller),
                     daemon=True, name="flash-worker").start()
    return True


def _flash_worker(fw_path: str, poller):
    held_unit = None
    try:
        digest = _sha256(fw_path)
        size_kb = os.path.getsize(fw_path) / 1024
        _append_log(f"Firmware: {os.path.basename(fw_path)} ({size_kb:.0f} KB)")
        _append_log(f"SHA256: {digest}")

        _append_log("Stopping stats poller to release the serial port...")
        poller.stop()
        held_unit = _release_serial_unit()

        dev = devices.detect()
        if dev["mode"] == "disconnected":
            _fail("No Station G2/G3 found on USB")
            return

        touch_output: list[str] = []
        if dev["mode"] == "normal":
            _set_state("flashing", "Entering bootloader mode...")
            _append_log(f"Device in normal mode: {dev['path']}")
            _append_log("Entering bootloader via 1200-baud touch...")
            # The touch always "fails" — the device drops off USB mid-command — so
            # its output is captured rather than logged, and surfaced below only if
            # the bootloader port never turns up.
            _, touch_output = _run_esptool(["--port", dev["path"], "--baud", "1200",
                                            "--after", "no_reset", "chip_id"],
                                           timeout=30, echo=False)
            time.sleep(TOUCH_SETTLE_SECS)
        else:
            _append_log("Device already in bootloader mode")

        dev = _wait_for_bootloader()
        if dev is None:
            if touch_output:
                _append_log("--- touch output (for diagnosis) ---")
                for line in touch_output:
                    _append_log(line)
            _fail("Bootloader port did not appear")
            return
        _append_log("Bootloader ready.")

        _set_state("flashing", "Writing firmware...")
        _append_log(f"Flashing at {FLASH_OFFSET} on {dev['path']}")
        code, _ = _run_esptool(["--port", dev["path"], "write_flash",
                                FLASH_OFFSET, fw_path], timeout=FLASH_TIMEOUT_SECS)
        if code == 0:
            _set_state("done", "Flash complete")
            _append_log("Firmware flash completed successfully.")
        else:
            _fail(f"esptool exited with code {code}")
    except Exception as e:
        logger.exception("Flash worker crashed")
        _fail(str(e))
    finally:
        # First, before anything that could go wrong: a flash that failed or
        # threw must not leave an operator's telemetry dead.
        if held_unit:
            _restore_serial_unit(held_unit)
        try:
            os.remove(fw_path)
        except OSError:
            pass
        _append_log("Restarting stats poller...")
        try:
            poller.start()
        except Exception as e:
            _append_log(f"Warning: could not restart stats poller: {e}")
        _append_log("Done.")


def _release_serial_unit() -> str | None:
    """Stop the telemetry unit holding the radio's serial port, if it is up.

    Returns the unit name only when this call stopped it, so the caller knows
    what it owes an operator afterwards; None when there was nothing to stop or
    the stop was refused.

    Some deployments run a daemon beside g2flasher that streams the radio's
    packet log to MQTT. It does not open the port exclusively, so esptool's own
    open succeeds and nothing anywhere reports a conflict — the two simply share
    the stream, and the daemon's reads swallow bootloader replies and its device
    polling injects bytes into the flashing protocol. There is no port-busy
    error to catch here, only a port to clear beforehand. A serial multiplexer
    is no substitute either: the flash starts with a 1200-baud touch, and a PTY
    forwards neither baud nor control-line changes.
    """
    unit = os.environ.get(SERIAL_UNIT_ENV, DEFAULT_SERIAL_UNIT)
    # is-active needs no privilege, so it stays off sudo: on the great majority
    # of hosts, which run no such daemon, this is the only call ever made.
    active, _ = _systemctl(["is-active", "--quiet", unit], sudo=False)
    if active != 0:
        # No such unit, or an operator stopped it deliberately. Not ours either
        # way — leave it exactly as found.
        return None

    _append_log(f"Stopping {unit} to release the serial port...")
    code, output = _systemctl(["stop", unit], sudo=True)
    if code != 0:
        _append_log(f"Warning: could not stop {unit} (exit {code}) — the flash "
                    "may be disrupted while it holds the port.")
        if output:
            _append_log(output)
        return None
    _append_log(f"Stopped {unit}.")
    return unit


def _restore_serial_unit(unit: str):
    """Start a unit _release_serial_unit stopped. Reports, never raises."""
    _append_log(f"Restarting {unit}...")
    code, output = _systemctl(["start", unit], sudo=True)
    if code == 0:
        _append_log(f"Restarted {unit}.")
        return
    # Not _fail(): the flash itself may well have worked, and its result is not
    # this helper's to overwrite. Say it loudly in the log instead.
    _append_log(f"ERROR: could not restart {unit} (exit {code}) — start it by "
                "hand to bring telemetry back.")
    if output:
        _append_log(output)


def _systemctl(args: list[str], sudo: bool) -> tuple[int, str]:
    """Run systemctl and return (exit code, combined output).

    Exit 127 means the command could not be run at all — no systemd here, or no
    sudo — which callers treat the same as a unit that is not there. Stopping a
    unit does need privilege; -n makes sudo refuse outright rather than block on
    a password prompt that a background service has nobody to answer.
    """
    cmd = (["sudo", "-n"] if sudo else []) + ["systemctl"] + args
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True,
                              timeout=SYSTEMCTL_TIMEOUT_SECS)
    except (OSError, subprocess.SubprocessError) as e:
        return 127, str(e)
    return proc.returncode, proc.stdout.strip()


def _run_esptool(args: list[str], timeout: float,
                 echo: bool = True) -> tuple[int, list[str]]:
    """Run esptool as a subprocess and return (exit code, output lines).

    Output is always collected. With echo=True it is also streamed into the
    flash log as it arrives; with echo=False the caller receives the lines and
    decides whether they are worth showing. The 1200-baud touch 'fails' by
    design (the device disconnects), so the caller decides what to do with the
    exit code.
    """
    cmd = ESPTOOL_CMD + list(args)
    if echo:
        _append_log("$ " + " ".join(cmd))
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, bufsize=1)
    except FileNotFoundError:
        message = "ERROR: esptool not found — is it installed in the venv?"
        if echo:
            _append_log(message)
        return 127, [message]

    lines: list[str] = []
    timer = threading.Timer(timeout, proc.kill)
    timer.start()
    try:
        for line in proc.stdout:
            line = line.rstrip("\n")
            if line:
                lines.append(line)
                if echo:
                    _append_log(line)
                    if "Writing at" in line or "%" in line:
                        _set_state("flashing", line.strip())
        return proc.wait(), lines
    finally:
        timer.cancel()


def _wait_for_bootloader():
    deadline = time.monotonic() + BOOTLOADER_WAIT_SECS
    while time.monotonic() < deadline:
        dev = devices.detect()
        if dev["mode"] == "bootloader":
            return dev
        time.sleep(0.5)
    return None


def _sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()
