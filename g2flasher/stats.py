"""Live repeater stats over the MeshCore serial CLI. Nothing is stored."""
from __future__ import annotations

import json
import logging
import threading
import time

import serial

import devices

logger = logging.getLogger(__name__)

BAUD = 115200
SERIAL_TIMEOUT = 5.0


class SerialReader:
    """Send CLI commands to the repeater; responses arrive prefixed '-> '."""

    def __init__(self, port_path: str, baud: int = BAUD,
                 timeout: float = SERIAL_TIMEOUT, serial_factory=serial.Serial):
        self._port_path = port_path
        self._baud = baud
        self._timeout = timeout
        self._serial_factory = serial_factory
        self._port = None
        self._lock = threading.Lock()
        self._connected = False

    @property
    def connected(self) -> bool:
        return self._connected

    def connect(self) -> bool:
        try:
            self._port = self._serial_factory(
                port=self._port_path, baudrate=self._baud, timeout=self._timeout)
            self._connected = True
            return True
        except Exception as e:
            logger.error("Failed to open %s: %s", self._port_path, e)
            self._connected = False
            return False

    def disconnect(self):
        with self._lock:
            if self._port is not None and self._port.is_open:
                try:
                    self._port.close()
                except Exception:
                    pass
            self._connected = False

    def send_command(self, command: str, timeout: float | None = None) -> str | None:
        if self._port is None or not self._port.is_open:
            return None
        with self._lock:
            try:
                self._drain_pending()
                self._port.write(f"{command}\r\n".encode())
                return self._read_response(timeout or self._timeout)
            except Exception as e:
                logger.error("Serial error sending %r: %s", command, e)
                self._connected = False
                return None

    def send_command_json(self, command: str) -> dict | None:
        raw = self.send_command(command)
        if not raw:
            return None
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            logger.warning("Non-JSON response for %r: %s", command, raw[:200])
            return None

    def _drain_pending(self):
        saved = self._port.timeout
        self._port.timeout = 0.05
        try:
            while getattr(self._port, "in_waiting", 0):
                if not self._port.readline():
                    break
        except Exception:
            pass
        finally:
            self._port.timeout = saved

    def _read_response(self, timeout: float) -> str:
        lines = []
        capture = False
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            self._port.timeout = min(remaining, 0.5)
            raw = self._port.readline()
            if not raw:
                if capture and lines:
                    break
                continue
            line = raw.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            if line.startswith("-> "):
                capture = True
                content = line[3:]
                if content:
                    lines.append(content)
                    break  # single-line response complete
                continue
            if capture:
                lines.append(line)
            # unsolicited lines (packet logs etc.) are ignored
        return "\n".join(lines)


POLL_INTERVAL_SECS = 10
VIEWER_WINDOW_SECS = 60
CONNECT_SETTLE_SECS = 2

DEVICE_INFO_COMMANDS = [
    ("get name", "name"),
    ("get public.key", "public_key"),
    ("get radio", "radio_config"),
    ("get lat", "lat"),
    ("get lon", "lon"),
    ("ver", "firmware"),
    ("board", "board"),
]

ERROR_RESPONSES = {"unknown command", "error", "invalid"}


class StatsPoller:
    """Polls the repeater CLI while someone is watching; keeps only the
    latest snapshot in memory."""

    def __init__(self, reader_factory=None):
        self._reader_factory = reader_factory or (lambda path: SerialReader(path))
        self._reader = None
        self._lock = threading.Lock()
        self._snapshot = {"device_info": {}, "stats": {"core": None, "radio": None, "packets": None},
                          "updated_at": None}
        self._last_viewer = 0.0
        self._thread = None
        self._stop_event = threading.Event()

    @property
    def running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def mark_viewer(self):
        with self._lock:
            self._last_viewer = time.time()

    def _has_viewer(self) -> bool:
        with self._lock:
            return (time.time() - self._last_viewer) < VIEWER_WINDOW_SECS

    def get_snapshot(self) -> dict:
        with self._lock:
            snap = {"device_info": dict(self._snapshot["device_info"]),
                    "stats": dict(self._snapshot["stats"]),
                    "updated_at": self._snapshot["updated_at"]}
        snap["age_secs"] = (time.time() - snap["updated_at"]) if snap["updated_at"] else None
        return snap

    def start(self):
        self._stop_event.clear()
        if self.running:
            return
        self._thread = threading.Thread(target=self._run, daemon=True, name="stats-poller")
        self._thread.start()

    def stop(self):
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=20)
            if not self._thread.is_alive():
                self._thread = None
            else:
                logger.warning("Stats poller thread did not exit within timeout; forcing disconnect")
        self._disconnect()

    def _run(self):
        while not self._stop_event.is_set():
            try:
                self.tick()
            except Exception:
                logger.exception("Stats poll cycle failed")
            self._stop_event.wait(POLL_INTERVAL_SECS)

    def tick(self):
        """One poll cycle. Public so tests can drive it synchronously."""
        dev = devices.detect()
        if dev["mode"] != "normal":
            self._disconnect()
            return
        if not self._has_viewer():
            return
        if self._reader is None or not self._reader.connected:
            reader = self._reader_factory(dev["path"])
            if not reader.connect():
                return
            self._reader = reader
            time.sleep(CONNECT_SETTLE_SECS)  # let the radio settle after open
            self._collect_device_info()

        if self._stop_event.is_set():
            return  # Bail out early if stop was requested
        core = self._reader.send_command_json("stats-core")
        if self._stop_event.is_set():
            return  # Bail out early if stop was requested
        radio = self._reader.send_command_json("stats-radio")
        if self._stop_event.is_set():
            return  # Bail out early if stop was requested
        packets = self._reader.send_command_json("stats-packets")
        # Firmware 1.14.x AGC resets briefly report a 0 dBm noise floor,
        # which is physically impossible — treat as missing.
        if radio is not None and radio.get("noise_floor") == 0:
            radio["noise_floor"] = None
        with self._lock:
            self._snapshot["stats"] = {"core": core, "radio": radio, "packets": packets}
            self._snapshot["updated_at"] = time.time()

    def _collect_device_info(self):
        info = {}
        for cmd, key in DEVICE_INFO_COMMANDS:
            if self._stop_event.is_set():
                return  # Bail out early if stop was requested
            resp = self._reader.send_command(cmd)
            if not resp:
                continue
            value = resp.strip().split("\n", 1)[0].strip()
            if value.startswith("> "):
                value = value[2:]
            if value.lower() in ERROR_RESPONSES:
                continue
            info[key] = value
        with self._lock:
            self._snapshot["device_info"] = info

    def _disconnect(self):
        if self._reader is not None:
            self._reader.disconnect()
            self._reader = None
