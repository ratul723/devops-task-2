import os
import sys
import urllib.request

port = os.getenv("PORT", "8080")
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as r:
        sys.exit(0 if r.status == 200 else 1)
except Exception: # noqa: BLE001
    sys.exit(1)