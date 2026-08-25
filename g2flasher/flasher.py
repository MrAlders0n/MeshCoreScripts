"""Background firmware flash via esptool subprocess.

Sequence (from flash_g2_firmware.py): if the station is in normal mode, touch
it at 1200 baud to enter the bootloader, wait, re-detect the port, then
write_flash at 0x10000. State is a module-level dict polled by the web layer.
The Station G2 and G3 are both ESP32-S3 boards with the same flash layout, so
one flow covers both.
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
    try:
        digest = _sha256(fw_path)
        size_kb = os.path.getsize(fw_path) / 1024
        _append_log(f"Firmware: {os.path.basename(fw_path)} ({size_kb:.0f} KB)")
        _append_log(f"SHA256: {digest}")

        _append_log("Stopping stats poller to release the serial port...")
        poller.stop()

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
