#!/usr/bin/env bats
# tests/15-cpanel-apply.bats — cPanel Stage 4 apply + two-stage rollback
#
# G6 × 3: presence detection, global apply happy path, uservhost apply path.
# G7 × 3: rollback + succeed, rollback + fail, bl_notify critical on rollback fail.
# Edge case 5: _bl_cpanel_present returns false when restartsrv_httpd is missing.

load 'helpers/cpanel-mock'

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    BL_VAR_DIR="$(mktemp -d)"
    export BL_VAR_DIR
    export BL_REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export ANTHROPIC_API_KEY="sk-ant-test"
    mkdir -p "$BL_VAR_DIR/state" "$BL_VAR_DIR/ledger" "$BL_VAR_DIR/backups"
    _cpanel_mock_setup
    # BL_CPANEL_DIR + BL_CPANEL_SCRIPT_DIR already exported by _cpanel_mock_setup
}

teardown() {
    _cpanel_mock_teardown
    rm -rf "$BL_VAR_DIR"
}

# ---------------------------------------------------------------------------
# G6 — cPanel detection + apply path
# ---------------------------------------------------------------------------

@test "_bl_cpanel_present: detects mock cPanel dir + executable restartsrv_httpd" {
    run bash -c '
        source '"$BL_SOURCE"'
        _bl_cpanel_present && echo "yes" || echo "no"
    '
    [[ "$output" == *"yes"* ]]
}

@test "_bl_cpanel_lockin_global: restartsrv_httpd success emits cpanel_lockin_invoked" {
    printf 'foo rule\n' > "$BL_VAR_DIR/conf"
    printf 'old rule\n' > "$BL_VAR_DIR/backup"
    run bash -c '
        export BL_VAR_DIR='"$BL_VAR_DIR"'
        export BL_REPO_ROOT='"$BL_REPO_ROOT"'
        export BL_CPANEL_DIR='"$BL_CPANEL_DIR"'
        export BL_CPANEL_SCRIPT_DIR='"$BL_CPANEL_SCRIPT_DIR"'
        export BL_TEST_RESTARTSRV_RC=0
        source '"$BL_SOURCE"'
        _bl_cpanel_lockin_global CASE-2026-0001 '"$BL_VAR_DIR"'/conf '"$BL_VAR_DIR"'/backup 2>&1
    '
    [ "$status" -eq 0 ]
    grep -q '"kind":"cpanel_lockin_invoked"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
}

@test "_bl_cpanel_lockin_uservhost: ensure_vhost_includes + restartsrv_httpd success" {
    printf 'vhost rule\n' > "$BL_VAR_DIR/vhost"
    printf 'old vhost\n' > "$BL_VAR_DIR/vhost.bak"
    run bash -c '
        export BL_VAR_DIR='"$BL_VAR_DIR"'
        export BL_REPO_ROOT='"$BL_REPO_ROOT"'
        export BL_CPANEL_DIR='"$BL_CPANEL_DIR"'
        export BL_CPANEL_SCRIPT_DIR='"$BL_CPANEL_SCRIPT_DIR"'
        export BL_TEST_RESTARTSRV_RC=0
        export BL_TEST_ENSURE_VHOST_RC=0
        source '"$BL_SOURCE"'
        _bl_cpanel_lockin_uservhost CASE-2026-0001 testuser example.com \
            '"$BL_VAR_DIR"'/vhost '"$BL_VAR_DIR"'/vhost.bak 2>&1
    '
    [ "$status" -eq 0 ]
    grep -q '"kind":"cpanel_lockin_invoked"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
}

# ---------------------------------------------------------------------------
# G7 — two-stage rollback
# ---------------------------------------------------------------------------

@test "Stage 4 fail: backup restored + retry restartsrv_httpd succeeds → rollback_succeeded=true" {
    printf 'new-content\n' > "$BL_VAR_DIR/conf"
    printf 'orig-content\n' > "$BL_VAR_DIR/backup"

    # Stateful stub: first call exits 1, second call exits 0
    cat > "$BL_CPANEL_SCRIPT_DIR/restartsrv_httpd" <<'STUB'
#!/bin/bash
ATTEMPT_FILE="${BL_VAR_DIR}/restartsrv-attempt"
if [ ! -f "$ATTEMPT_FILE" ]; then
    printf '1' > "$ATTEMPT_FILE"
    exit 1
else
    exit 0
fi
STUB
    chmod 0755 "$BL_CPANEL_SCRIPT_DIR/restartsrv_httpd"

    run bash -c '
        export BL_VAR_DIR='"$BL_VAR_DIR"'
        export BL_REPO_ROOT='"$BL_REPO_ROOT"'
        export BL_CPANEL_DIR='"$BL_CPANEL_DIR"'
        export BL_CPANEL_SCRIPT_DIR='"$BL_CPANEL_SCRIPT_DIR"'
        source '"$BL_SOURCE"'
        _bl_cpanel_lockin_global CASE-2026-0001 '"$BL_VAR_DIR"'/conf '"$BL_VAR_DIR"'/backup 2>&1
    '
    # Non-zero return even on rollback-success (Stage 4 failed overall)
    [ "$status" -ne 0 ]
    grep -q '"kind":"cpanel_lockin_failed"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
    grep -q '"kind":"cpanel_lockin_rolled_back"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
    grep -q '"rollback_succeeded":true' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
    # Config should be restored to backup contents
    diff "$BL_VAR_DIR/conf" "$BL_VAR_DIR/backup"
}

@test "Stage 4 fail + rollback fail: emits cpanel_lockin_rolled_back rollback_succeeded=false" {
    printf 'new-content\n' > "$BL_VAR_DIR/conf"
    printf 'orig-content\n' > "$BL_VAR_DIR/backup"

    run bash -c '
        export BL_VAR_DIR='"$BL_VAR_DIR"'
        export BL_REPO_ROOT='"$BL_REPO_ROOT"'
        export BL_CPANEL_DIR='"$BL_CPANEL_DIR"'
        export BL_CPANEL_SCRIPT_DIR='"$BL_CPANEL_SCRIPT_DIR"'
        export BL_TEST_RESTARTSRV_RC=1
        source '"$BL_SOURCE"'
        _bl_cpanel_lockin_global CASE-2026-0001 '"$BL_VAR_DIR"'/conf '"$BL_VAR_DIR"'/backup 2>&1
    '
    [ "$status" -ne 0 ]
    grep -q '"kind":"cpanel_lockin_rolled_back"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
    grep -q '"rollback_succeeded":false' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
}

@test "Stage 4 fail + rollback fail: bl_notify invoked with severity=critical" {
    printf 'new\n' > "$BL_VAR_DIR/conf"
    printf 'old\n' > "$BL_VAR_DIR/backup"

    run bash -c '
        export BL_VAR_DIR='"$BL_VAR_DIR"'
        export BL_REPO_ROOT='"$BL_REPO_ROOT"'
        export BL_CPANEL_DIR='"$BL_CPANEL_DIR"'
        export BL_CPANEL_SCRIPT_DIR='"$BL_CPANEL_SCRIPT_DIR"'
        export BL_TEST_RESTARTSRV_RC=1
        source '"$BL_SOURCE"'
        bl_notify() { printf "NOTIFY:%s:%s:%s\n" "$1" "$2" "$3" >> "'"$BL_VAR_DIR"'/notify.log"; return 0; }
        export -f bl_notify
        _bl_cpanel_lockin_global CASE-2026-0001 '"$BL_VAR_DIR"'/conf '"$BL_VAR_DIR"'/backup 2>&1
    '
    [ "$status" -ne 0 ]
    grep -q "NOTIFY:CASE-2026-0001:critical:Stage 4 rollback failed" "$BL_VAR_DIR/notify.log"
}

# ---------------------------------------------------------------------------
# Edge case 5 — restartsrv_httpd missing
# ---------------------------------------------------------------------------

@test "_bl_cpanel_present returns false when restartsrv_httpd is missing" {
    rm -f "$BL_CPANEL_SCRIPT_DIR/restartsrv_httpd"
    run bash -c '
        export BL_CPANEL_DIR='"$BL_CPANEL_DIR"'
        export BL_CPANEL_SCRIPT_DIR='"$BL_CPANEL_SCRIPT_DIR"'
        source '"$BL_SOURCE"'
        _bl_cpanel_present && echo "yes" || echo "no"
    '
    [[ "$output" == *"no"* ]]
}
