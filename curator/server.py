"""Local Flask glue — manifest HTTP endpoint + report inbox.

The Claude-driven investigation loop runs in a Managed Agents session (see
curator/managed_agents.py). This module is thin local plumbing that the
fleet's bl-agent scripts talk to:

- GET /health           — liveness for docker healthcheck
- GET /manifest.yaml    — current defense manifest (written by the session)
- POST /reports         — bl-agent uploads land here as files in the inbox

Day 1 scope: enough to satisfy `docker compose up` + curl /health + curl
/manifest.yaml. Day 4 adds SHA-256 lineage headers, stack-profile filtering,
and the session's event-stream consumer that writes manifest updates to disk.
"""

from __future__ import annotations

import os
from pathlib import Path

from flask import Flask, abort, jsonify, request, send_file

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
        # Day-1 empty manifest — synthesizer populates it once Day 4 lands.
        return (EMPTY_MANIFEST, 200, {"Content-Type": "application/x-yaml"})
    return send_file(MANIFEST_PATH, mimetype="application/x-yaml")


@app.post("/reports")
def report_in():
    payload = request.get_data()
    if not payload:
        abort(400, description="empty report")
    host = request.headers.get("X-Host-Id", "unknown")
    # os.urandom for collision-free file naming within a batch of uploads.
    drop = INBOX_DIR / f"{host}-{os.urandom(4).hex()}.tar"
    drop.write_bytes(payload)
    return jsonify({"accepted": True, "inbox_path": str(drop)}), 202


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
