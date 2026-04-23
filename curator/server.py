"""Local Flask glue — manifest HTTP endpoint + report inbox.

The Claude-driven investigation loop runs in a Managed Agents session
bootstrapped by `curator/agent_setup.py` and driven by
`curator/session_runner.py`. This module is thin local plumbing that the
fleet's bl-agent scripts talk to:

- GET /health                 — liveness for docker healthcheck
- GET /manifest.yaml          — current defense manifest (written by synthesize)
- GET /manifest.yaml.sha256   — sidecar for bl-pull verification
- POST /reports               — bl-agent uploads land here as files in the inbox
"""

from __future__ import annotations

import os
import re
from pathlib import Path

from flask import Flask, abort, jsonify, request, send_file

# Accept only filename-safe characters from the caller-supplied host id.
# A compromised fleet host is in the threat model; the raw header cannot
# be trusted for a filesystem path component.
_HOST_ID_SAFE = re.compile(r"[^A-Za-z0-9._-]")

STORAGE_DIR = Path(os.environ.get("BL_STORAGE", "/app/curator/storage"))
MANIFEST_PATH = STORAGE_DIR / "manifest.yaml"
INBOX_DIR = Path(os.environ.get("BL_INBOX", "/app/inbox"))
INBOX_DIR.mkdir(parents=True, exist_ok=True)
STORAGE_DIR.mkdir(parents=True, exist_ok=True)

EMPTY_MANIFEST = "version: 0\ndefenses: []\n"

app = Flask(__name__)


@app.get("/health")
def health():
    return jsonify({
        "status": "ok",
        "manifest_exists": MANIFEST_PATH.exists(),
        "inbox_dir": str(INBOX_DIR),
    })


@app.get("/manifest.yaml")
def manifest():
    if not MANIFEST_PATH.exists():
        # Fleet brings up before the first synthesize run — serve an empty
        # manifest so bl-pull has a 200 to parse on cold start.
        return (EMPTY_MANIFEST, 200, {"Content-Type": "application/x-yaml"})
    return send_file(MANIFEST_PATH, mimetype="application/x-yaml")


@app.get("/manifest.yaml.sha256")
def manifest_sha256():
    sidecar = STORAGE_DIR / "manifest.yaml.sha256"
    if not sidecar.exists():
        abort(404, description="manifest sidecar not yet published")
    return send_file(sidecar, mimetype="text/plain")


@app.post("/reports")
def report_in():
    payload = request.get_data()
    if not payload:
        abort(400, description="empty report")
    raw_host = request.headers.get("X-Host-Id", "unknown")
    host = _HOST_ID_SAFE.sub("_", raw_host)[:64] or "unknown"
    # os.urandom for collision-free file naming within a batch of uploads.
    drop = INBOX_DIR / f"{host}-{os.urandom(4).hex()}.tar"
    drop.write_bytes(payload)
    return jsonify({"accepted": True, "inbox_path": str(drop)}), 202


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
