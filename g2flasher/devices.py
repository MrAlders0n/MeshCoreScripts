"""Classify the station's USB serial device by its /dev/serial/by-id name.

Station G2 running MeshCore appears as usb-Espressif_Systems_BQ_Station_G2_*;
Station G3 as usb-Espressif_Systems_Station_G3_ESP32_* (both boards are
ESP32-S3, so the bootloader port is the same USB-JTAG device).
"""
import os

BY_ID_DIR = "/dev/serial/by-id"
NORMAL_HINTS = ("Station_G2", "Station_G3")
BOOTLOADER_HINT = "Espressif_USB_JTAG"


def detect() -> dict:
    try:
        names = sorted(os.listdir(BY_ID_DIR))
    except OSError:
        names = []

    hints = [(hint, "normal") for hint in NORMAL_HINTS]
    hints.append((BOOTLOADER_HINT, "bootloader"))
    for hint, mode in hints:
        for name in names:
            if hint in name:
                return {"mode": mode, "path": os.path.join(BY_ID_DIR, name)}
    return {"mode": "disconnected", "path": None}
