"""Run app._clear_stale_uploads against a throwaway upload directory.

Driven by test_upload_sweep.sh. DRIVE_UPLOAD_DIR replaces the real one, so the
test can plant files and check they are gone. Log output goes to stdout so the
shell test can assert on what the operator would see at startup.
"""
import logging
import os
import sys

sys.path.insert(0, os.environ["APP_DIR"])

# Before importing app: its own basicConfig() would otherwise claim the root
# logger first and this format would never take effect.
logging.basicConfig(level=logging.INFO, format="LOG %(message)s", stream=sys.stdout)

import app as appmod  # noqa: E402

appmod.UPLOAD_DIR = os.environ["DRIVE_UPLOAD_DIR"]
appmod._clear_stale_uploads()
print("RETURNED")
