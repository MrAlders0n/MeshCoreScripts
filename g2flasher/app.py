"""g2flasher web app: basic-auth Flask serving the page and JSON API."""
from __future__ import annotations

import functools
import hmac
import logging
import os
import sys
import tempfile

from flask import Flask, jsonify, render_template, request
from werkzeug.utils import secure_filename

import devices
import flasher

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(name)s %(levelname)s %(message)s")

MAX_UPLOAD_BYTES = 16 * 1024 * 1024
UPLOAD_DIR = os.path.join(tempfile.gettempdir(), "g2flasher_uploads")
AUTH_USER = "admin"


def create_app(password: str) -> Flask:
    app = Flask(__name__, static_folder=None)
    app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_BYTES

    def require_auth(view):
        @functools.wraps(view)
        def wrapped(*args, **kwargs):
            auth = request.authorization
            ok = (auth is not None
                  and auth.type == "basic"
                  and hmac.compare_digest((auth.username or "").encode(), AUTH_USER.encode())
                  and hmac.compare_digest((auth.password or "").encode(), password.encode()))
            if not ok:
                return ("Authentication required", 401,
                        {"WWW-Authenticate": 'Basic realm="g2flasher"'})
            return view(*args, **kwargs)
        return wrapped

    @app.get("/")
    @require_auth
    def index():
        return render_template("index.html")

    @app.get("/api/status")
    @require_auth
    def api_status():
        return jsonify({**flasher.get_status(), "device": devices.detect()})

    @app.post("/api/flash")
    @require_auth
    def api_flash():
        if flasher.get_status()["state"] == "flashing":
            return jsonify({"error": "Flash already in progress"}), 409
        fw = request.files.get("firmware")
        if fw is None or not fw.filename:
            return jsonify({"error": "No firmware file provided"}), 400
        if not fw.filename.lower().endswith(".bin"):
            return jsonify({"error": "Firmware file must be a .bin"}), 400

        os.makedirs(UPLOAD_DIR, exist_ok=True)
        safe_name = secure_filename(fw.filename) or "firmware.bin"
        fd, fw_path = tempfile.mkstemp(suffix=f"__{safe_name}", dir=UPLOAD_DIR)
        os.close(fd)
        fw.save(fw_path)

        if not flasher.start_flash(fw_path):
            os.remove(fw_path)
            return jsonify({"error": "Flash already in progress"}), 409
        return jsonify({"status": "started"})

    return app


def main():
    password = os.environ.get("G2FLASHER_PASSWORD")
    if not password:
        sys.exit("G2FLASHER_PASSWORD is not set — refusing to start")
    port = int(os.environ.get("G2FLASHER_PORT", "80"))

    from waitress import serve
    app = create_app(password)
    logging.getLogger(__name__).info("g2flasher listening on :%d", port)
    serve(app, host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
