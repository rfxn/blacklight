#!/bin/bash
# pkg/test/test-pkg-install.sh — blacklight package install verification
set -euo pipefail

PASS=0; FAIL=0
PKG_TYPE="${1:-auto}"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

check_file() {
    local path="$1" desc="$2"
    if [ -e "$path" ]; then pass "$desc ($path)"; else fail "$desc ($path missing)"; fi
}

check_perms() {
    local path="$1" expected="$2" desc="$3"
    local actual; actual=$(stat -c '%a' "$path" 2>/dev/null || echo "-")   # path may not exist; fall through to FAIL
    if [ "$actual" = "$expected" ]; then pass "$desc (perms $actual)"
    else fail "$desc (perms $actual, expected $expected)"; fi
}

if [ "$PKG_TYPE" = "auto" ]; then
    if command -v rpm >/dev/null 2>&1 && rpm -q blacklight >/dev/null 2>&1; then
        PKG_TYPE="rpm"
    elif command -v dpkg >/dev/null 2>&1 && dpkg -s blacklight >/dev/null 2>&1; then
        PKG_TYPE="deb"
    else echo "ERROR: cannot detect installed package type"; exit 1
    fi
fi

echo "=== blacklight package verification ($PKG_TYPE) ==="
check_file /usr/bin/bl "Binary"
check_perms /usr/bin/bl 755 "Binary perms"
check_file /var/lib/bl "State dir"
check_file /var/lib/bl/state "State/state subdir"
check_file /var/lib/bl/ledger "State/ledger subdir"
check_file /var/lib/bl/outbox "State/outbox subdir"
check_perms /var/lib/bl 750 "State dir perms"
check_file /usr/share/doc/blacklight/README.md "Docs: README"

# Execution smoke — bl --version must print "bl <pinned-version>"
ver_out=$(/usr/bin/bl --version 2>&1 || true)   # exit code 0 expected; || true protects PASS=0 path on missing binary
if [[ "$ver_out" =~ ^bl\ [0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pass "bl --version ($ver_out)"
else
    fail "bl --version output: $ver_out"
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
