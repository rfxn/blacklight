#!/bin/bash
# tests/fixtures/smoke/test-bl-apply.sh — bl-apply unit smoke.
# Exercises: apache install + configtest PASS; nginx skip; missing manifest; idempotent re-run.
# Standalone: uses shims for yq and apachectl — no live fleet required.
# Also serves as the docker-exec runner stub for Phase 31 live smoke.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && command pwd)"
BL_APPLY="$(cd "$SCRIPT_DIR/../../.." && command pwd)/bl-agent/bl-apply"

log()  { command printf '[test-bl-apply %s] %s\n' "$(command date -u +%H:%M:%SZ)" "$*" >&2; }
pass() { log "PASS: $*"; }
fail() { log "FAIL: $*"; exit 1; }

# Minimal manifest with one apache rule and version "1"
FAKE_MANIFEST_CONTENT='version: "1"
rules:
  - id: "BL-001"
    applies_to:
      - apache
      - apache-modsec
    body: "# BL-001 placeholder rule"
'

# ---- setup ----------------------------------------------------------------
TMPROOT=$(command mktemp -d -t bl-apply-smoke.XXXXXX)
trap 'command rm -rf "$TMPROOT"' EXIT

FAKE_MANIFEST="$TMPROOT/manifest.yaml"
CONF_AVAILABLE="$TMPROOT/conf-available"
CONF_ENABLED="$TMPROOT/conf-enabled"
SHIM_BIN="$TMPROOT/bin"

command mkdir -p "$CONF_AVAILABLE" "$CONF_ENABLED" "$SHIM_BIN"
command printf '%s' "$FAKE_MANIFEST_CONTENT" > "$FAKE_MANIFEST"

# yq shim — minimal subset used by bl-apply
command cat > "$SHIM_BIN/yq" <<'YQEOF'
#!/bin/bash
# Minimal yq shim: supports .version, '.rules | length', .rules[N].applies_to[], .rules[N].body
# against a YAML file that uses the exact structure of FAKE_MANIFEST_CONTENT above.
EXPR="$1"
FILE="$2"
case "$EXPR" in
    '.version')
        grep -m1 '^version:' "$FILE" | sed "s/.*: *['\"]//;s/['\"]$//"
        ;;
    '.rules | length')
        grep -c '^  - id:' "$FILE" || true
        ;;
    .rules\[*\].applies_to\[\])
        IDX=$(echo "$EXPR" | grep -o '\[[0-9]*\]' | tr -d '[]')
        # Print each applies_to entry (lines between applies_to: and next key)
        awk '/^rules:/{r=1} r && /^ *- id:/{n++} r && n=='"$((IDX+1))"' && /applies_to:/{a=1;next} r && a && /^ *- /{print $2;next} r && a && /^[^ ]/{a=0}' "$FILE"
        ;;
    .rules\[*\].body)
        IDX=$(echo "$EXPR" | grep -o '\[[0-9]*\]' | tr -d '[]')
        awk '/^rules:/{r=1} r && /^ *- id:/{n++} r && n=='"$((IDX+1))"' && /^ *body:/{print $2;exit}' "$FILE" | sed "s/^['\"]//;s/['\"]$//"
        ;;
    *)
        echo "yq-shim: unsupported expr: $EXPR" >&2
        exit 1
        ;;
esac
YQEOF
command chmod +x "$SHIM_BIN/yq"

# apachectl shim (PASS)
command cat > "$SHIM_BIN/apachectl" <<'ACEOF'
#!/bin/bash
if [[ "${1:-}" == "-t" ]]; then
    echo "Syntax OK"
    exit 0
fi
exit 0
ACEOF
command chmod +x "$SHIM_BIN/apachectl"

# Prepend shim bin to PATH for all sub-invocations
export PATH="$SHIM_BIN:$PATH"

# ---- scenario 1: apache apply + configtest PASS ---------------------------
log "scenario 1: apache apply + configtest PASS"
out=$(BL_MANIFEST_LOCAL="$FAKE_MANIFEST" \
      BL_STACK_OVERRIDE=apache \
      BL_APACHE_CONF_AVAILABLE="$CONF_AVAILABLE" \
      BL_APACHE_CONF_ENABLED="$CONF_ENABLED" \
      bash "$BL_APPLY" 2>&1)

command echo "$out" | command grep -q 'apachectl -t PASS' \
    || fail "scenario 1: apachectl -t PASS not logged. output: $out"
[[ -f "$CONF_AVAILABLE/bl-rules-1.conf" ]] \
    || fail "scenario 1: rule file not created at $CONF_AVAILABLE/bl-rules-1.conf"
[[ -L "$CONF_ENABLED/bl-rules.conf" ]] \
    || fail "scenario 1: symlink not created at $CONF_ENABLED/bl-rules.conf"
pass "scenario 1: apache apply + configtest PASS"

# ---- scenario 2: nginx skip -----------------------------------------------
log "scenario 2: nginx skip"
# Remove rule file to prove nginx path does not create it
command rm -f "$CONF_AVAILABLE/bl-rules-1.conf" "$CONF_ENABLED/bl-rules.conf"
out=$(BL_MANIFEST_LOCAL="$FAKE_MANIFEST" \
      BL_STACK_OVERRIDE=nginx \
      BL_APACHE_CONF_AVAILABLE="$CONF_AVAILABLE" \
      BL_APACHE_CONF_ENABLED="$CONF_ENABLED" \
      bash "$BL_APPLY" 2>&1)

command echo "$out" | command grep -q "skipping Apache ruleset" \
    || fail "scenario 2: skip log not found. output: $out"
[[ ! -f "$CONF_AVAILABLE/bl-rules-1.conf" ]] \
    || fail "scenario 2: rule file unexpectedly created on nginx host"
pass "scenario 2: nginx skip"

# ---- scenario 3: unknown stack skip ---------------------------------------
log "scenario 3: unknown stack skip"
out=$(BL_MANIFEST_LOCAL="$FAKE_MANIFEST" \
      BL_STACK_OVERRIDE=unknown \
      BL_APACHE_CONF_AVAILABLE="$CONF_AVAILABLE" \
      BL_APACHE_CONF_ENABLED="$CONF_ENABLED" \
      bash "$BL_APPLY" 2>&1)

command echo "$out" | command grep -q "skipping Apache ruleset" \
    || fail "scenario 3: skip log not found. output: $out"
pass "scenario 3: unknown stack skip"

# ---- scenario 4: missing manifest -----------------------------------------
log "scenario 4: missing manifest → exit 1"
set +e
out=$(BL_MANIFEST_LOCAL="$TMPROOT/does-not-exist.yaml" \
      BL_STACK_OVERRIDE=apache \
      bash "$BL_APPLY" 2>&1)
exit_code=$?
set -e
[[ "$exit_code" -eq 1 ]] \
    || fail "scenario 4: expected exit 1 on missing manifest, got $exit_code"
pass "scenario 4: missing manifest → exit 1"

# ---- scenario 5: idempotent re-run ----------------------------------------
log "scenario 5: idempotent re-run (apply twice)"
BL_MANIFEST_LOCAL="$FAKE_MANIFEST" \
    BL_STACK_OVERRIDE=apache \
    BL_APACHE_CONF_AVAILABLE="$CONF_AVAILABLE" \
    BL_APACHE_CONF_ENABLED="$CONF_ENABLED" \
    bash "$BL_APPLY" >/dev/null  # first apply (idempotent: second run should still PASS)
out=$(BL_MANIFEST_LOCAL="$FAKE_MANIFEST" \
      BL_STACK_OVERRIDE=apache \
      BL_APACHE_CONF_AVAILABLE="$CONF_AVAILABLE" \
      BL_APACHE_CONF_ENABLED="$CONF_ENABLED" \
      bash "$BL_APPLY" 2>&1)

command echo "$out" | command grep -q 'apachectl -t PASS' \
    || fail "scenario 5: second apply did not PASS. output: $out"
pass "scenario 5: idempotent re-run"

pass "bl-apply smoke: 5/5 scenarios passed"
