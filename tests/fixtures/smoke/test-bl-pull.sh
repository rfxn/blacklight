#!/bin/bash
# tests/fixtures/smoke/test-bl-pull.sh — bl-pull integration smoke.
# Exercises: sidecar-first fetch; hash verify PASS; hash verify FAIL; sidecar 404.
# Usage: bash tests/fixtures/smoke/test-bl-pull.sh
# Dependencies: python3 (stdlib http.server), sha256sum, curl, bash.
# Self-contained: spins its own ephemeral HTTP test-double curator.

set -euo pipefail

SCRIPT_DIR="$(command dirname "$(command readlink -f "$0")")"
REPO_ROOT="$(command readlink -f "$SCRIPT_DIR/../../..")"
BL_PULL="$REPO_ROOT/bl-agent/bl-pull"

log()  { command printf '[test-bl-pull %s] %s\n' "$(command date -u +%H:%M:%SZ)" "$*" >&2; }
pass() { log "PASS: $*"; }
fail() { log "FAIL: $*"; exit 1; }

[[ -f "$BL_PULL" ]] || fail "bl-pull not found at $BL_PULL"

# --- Ephemeral HTTP server setup ----------------------------------------------
SERVE_DIR=$(command mktemp -d -t bl-pull-serve.XXXXXX)
PORT_FILE=$(command mktemp -t bl-pull-port.XXXXXX)
PY_SCRIPT=$(command mktemp -t bl-pull-srv.XXXXXX.py)

# Write a minimal python3 file server that prints its port to PORT_FILE
command cat > "$PY_SCRIPT" << 'PYEOF'
import sys, os, http.server, socketserver

serve_dir = sys.argv[1]
port_file  = sys.argv[2]
os.chdir(serve_dir)

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):  # suppress per-request access log
        pass

with socketserver.TCPServer(("127.0.0.1", 0), QuietHandler) as srv:
    with open(port_file, "w") as fh:
        fh.write(str(srv.server_address[1]))
    srv.serve_forever()
PYEOF

# shellcheck disable=SC2064  # expand variables at trap-set time (PID/paths)
trap "command rm -rf '$SERVE_DIR' '$PORT_FILE' '$PY_SCRIPT'; kill \$SERVER_PID 2>/dev/null || true" EXIT  # clean up on exit

# Build initial valid fixture
command printf 'version: "smoke-v1"\ndefenses: []\n' > "$SERVE_DIR/manifest.yaml"
( cd "$SERVE_DIR" && sha256sum manifest.yaml > manifest.yaml.sha256 )

# Launch server; stderr suppressed — per-request logs are cosmetic noise, real failures
# surface as non-zero curl exits in bl-pull
python3 "$PY_SCRIPT" "$SERVE_DIR" "$PORT_FILE" 2>/dev/null &
SERVER_PID=$!

# Wait up to 3s for port file to be populated
for _i in 1 2 3 4 5 6; do
    [[ -s "$PORT_FILE" ]] && break
    command sleep 0.5
done
[[ -s "$PORT_FILE" ]] || fail "test curator did not start (port file empty after 3s)"

SERVER_PORT=$(command cat "$PORT_FILE")
log "test curator on port $SERVER_PORT (pid $SERVER_PID)"
CURATOR_URL="http://127.0.0.1:$SERVER_PORT"

# ======================== Scenario 1: happy path ==============================
log "scenario 1: happy path — valid manifest + valid sidecar"
WORK1=$(command mktemp -d -t bl-pull-s1.XXXXXX)
MANIFEST1="$WORK1/manifest.yaml"

BL_CURATOR_URL="$CURATOR_URL" BL_MANIFEST_LOCAL="$MANIFEST1" \
    bash "$BL_PULL" 2>"$WORK1/bl-pull.log"

[[ -f "$MANIFEST1" ]]          || fail "s1: manifest not written"
[[ -f "${MANIFEST1}.sha256" ]] || fail "s1: sidecar not written"
command grep -q 'hash verified' "$WORK1/bl-pull.log" || fail "s1: log missing 'hash verified'"
pass "scenario 1: happy path"

# ======================== Scenario 2: corrupt sidecar =========================
log "scenario 2: corrupt sidecar — bl-pull must exit non-zero, local manifest preserved"
command printf 'deadbeef  manifest.yaml\n' > "$SERVE_DIR/manifest.yaml.sha256"

WORK2=$(command mktemp -d -t bl-pull-s2.XXXXXX)
MANIFEST2="$WORK2/manifest.yaml"
command printf 'version: "prior"\ndefenses: []\n' > "$MANIFEST2"
PRIOR2=$(command cat "$MANIFEST2")

set +e
BL_CURATOR_URL="$CURATOR_URL" BL_MANIFEST_LOCAL="$MANIFEST2" \
    bash "$BL_PULL" 2>"$WORK2/bl-pull.log"
S2_EXIT=$?
set -e

[[ "$S2_EXIT" -ne 0 ]] || fail "s2: expected non-zero exit on corrupt sidecar (got 0)"
command grep -q 'SHA-256 mismatch' "$WORK2/bl-pull.log" || fail "s2: log missing 'SHA-256 mismatch'"
[[ "$(command cat "$MANIFEST2")" == "$PRIOR2" ]] || fail "s2: prior manifest was overwritten (must be preserved)"
pass "scenario 2: corrupt sidecar rejected, prior manifest preserved"

# ======================== Scenario 3: sidecar 404 =============================
log "scenario 3: sidecar 404 (pre-publish) — bl-pull must exit non-zero, prior manifest preserved"
command rm -f "$SERVE_DIR/manifest.yaml.sha256"

WORK3=$(command mktemp -d -t bl-pull-s3.XXXXXX)
MANIFEST3="$WORK3/manifest.yaml"
command printf 'version: "prior"\ndefenses: []\n' > "$MANIFEST3"
PRIOR3=$(command cat "$MANIFEST3")

set +e
BL_CURATOR_URL="$CURATOR_URL" BL_MANIFEST_LOCAL="$MANIFEST3" \
    bash "$BL_PULL" 2>"$WORK3/bl-pull.log"
S3_EXIT=$?
set -e

[[ "$S3_EXIT" -ne 0 ]] || fail "s3: expected non-zero exit on sidecar 404 (got 0)"
command grep -q 'fetch failed' "$WORK3/bl-pull.log" || fail "s3: log missing 'fetch failed'"
[[ "$(command cat "$MANIFEST3")" == "$PRIOR3" ]] || fail "s3: prior manifest was overwritten (must be preserved)"
pass "scenario 3: sidecar 404 rejected, prior manifest preserved"

log "ALL SCENARIOS PASSED (3/3)"
