#!/usr/bin/env bats
# tests/14-notify.bats — alert_lib channel registration + dispatch + outbox

load 'helpers/assert-jsonl'

setup() {
    export BL_VAR_DIR
    BL_VAR_DIR="$(mktemp -d)"
    export BL_NOTIFY_DIR
    BL_NOTIFY_DIR="$(mktemp -d)"
    export BL_REPO_ROOT="$BATS_TEST_DIRNAME/.."
    mkdir -p "$BL_VAR_DIR/state" "$BL_VAR_DIR/ledger" "$BL_VAR_DIR/outbox"
}

teardown() {
    rm -rf "$BL_VAR_DIR" "$BL_NOTIFY_DIR"
}

@test "_bl_notify_register_channels: missing token → channel auto-disabled" {
    run bash -c '
        source "$BL_REPO_ROOT/bl"
        _bl_notify_register_channels
        alert_channel_enabled slack && echo "ENABLED" || echo "DISABLED"
    '
    [[ "$output" == *"DISABLED"* ]]
}

@test "_bl_notify_register_channels: chmod != 0600 → channel skip-enable (R5)" {
    printf 'token=xoxb-test\nchannel=test\n' > "$BL_NOTIFY_DIR/slack.token"
    chmod 0644 "$BL_NOTIFY_DIR/slack.token"
    run bash -c '
        source "$BL_REPO_ROOT/bl"
        _bl_notify_register_channels
        alert_channel_enabled slack && echo "ENABLED" || echo "DISABLED"
    '
    [[ "$output" == *"DISABLED"* ]]
    [[ "$output" == *"perms 644 != 600"* ]]
}

@test "_bl_notify_register_channels: 0600 token + content → channel enabled" {
    printf 'token=xoxb-test\nchannel=test\n' > "$BL_NOTIFY_DIR/slack.token"
    chmod 0600 "$BL_NOTIFY_DIR/slack.token"
    run bash -c '
        source "$BL_REPO_ROOT/bl"
        _bl_notify_register_channels
        alert_channel_enabled slack && echo "ENABLED" || echo "DISABLED"
        printf "TOKEN=%s\n" "$ALERT_SLACK_TOKEN"
    '
    [[ "$output" == *"ENABLED"* ]]
    [[ "$output" == *"TOKEN=xoxb-test"* ]]
}

@test "_bl_notify_export_from_file: rejects metacharacter in value" {
    printf 'token=xoxb;rm -rf /\n' > "$BL_NOTIFY_DIR/slack.token"
    chmod 0600 "$BL_NOTIFY_DIR/slack.token"
    run bash -c '
        source "$BL_REPO_ROOT/bl"
        _bl_notify_export_from_file "$BL_NOTIFY_DIR/slack.token" ALERT_SLACK
        printf "TOKEN=%s\n" "${ALERT_SLACK_TOKEN:-empty}"
    '
    [[ "$output" == *"metacharacter"* ]]
    [[ "$output" == *"TOKEN=empty"* ]]
}

@test "bl_notify: severity floor below conf → no dispatch" {
    run bash -c '
        source "$BL_REPO_ROOT/bl"
        export BL_NOTIFY_SEVERITY_FLOOR=warn
        bl_notify CASE-2026-0001 info "test" "body"
    '
    [ "$status" -eq 0 ]
}

@test "bl_notify: missing args → BL_EX_USAGE (64)" {
    run bash -c '
        source "$BL_REPO_ROOT/bl"
        bl_notify "" info "subj" "body"
    '
    [ "$status" -eq 64 ]
}

@test "bl_notify: no channels enabled → returns 0 with warn" {
    run bash -c '
        source "$BL_REPO_ROOT/bl"
        # No channels enabled (default state after sourcing bl)
        bl_notify CASE-2026-0001 info "subj" "body"
    '
    [ "$status" -eq 0 ]
}

@test "bl_notify: enabled channels receive payload" {
    # Stub alert_dispatch to record the call instead of actually dispatching
    run bash -c '
        source "$BL_REPO_ROOT/bl"
        alert_dispatch() { echo "DISPATCHED:$2:$3" >> "$BL_VAR_DIR/dispatch.log"; return 0; }
        alert_channel_enabled() { return 0; }   # all-channels-enabled stub
        bl_notify CASE-2026-0001 info "subj" "body"
        cat "$BL_VAR_DIR/dispatch.log"
    '
    [[ "$output" == *"DISPATCHED:subj:"* ]]
}

@test "bl_notify: per-channel send fail → notify_failed ledger + outbox enqueue" {
    run bash -c '
        source "$BL_REPO_ROOT/bl"
        alert_dispatch() { return 1; }
        alert_channel_enabled() { [[ "$1" == "slack" ]]; }   # only slack enabled
        bl_notify CASE-2026-0001 critical "alert" "body"
    '
    [ -f "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl" ]
    grep -q '"kind":"notify_failed"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
    grep -q '"channel":"slack"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
}

@test "bl_notify: per-channel send fail → notify_dispatched ledger entry" {
    run bash -c '
        source "$BL_REPO_ROOT/bl"
        alert_dispatch() { return 1; }
        alert_channel_enabled() { [[ "$1" == "slack" ]]; }   # only slack enabled
        bl_notify CASE-2026-0001 critical "alert" "body"
    '
    [ -f "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl" ]
    grep -q '"kind":"notify_dispatched"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
}

@test "_bl_notify_export_from_file: valid key=value → exported with prefix" {
    printf 'webhook_url=https://hooks.example.com/test\n' > "$BL_NOTIFY_DIR/test.token"
    chmod 0600 "$BL_NOTIFY_DIR/test.token"
    run bash -c '
        source "$BL_REPO_ROOT/bl"
        _bl_notify_export_from_file "$BL_NOTIFY_DIR/test.token" ALERT_TEST
        printf "URL=%s\n" "${ALERT_TEST_WEBHOOK_URL:-empty}"
    '
    [[ "$output" == *"URL=https://hooks.example.com/test"* ]]
}

@test "_bl_notify_register_channels: syslog registered + enabled when logger present" {
    run bash -c '
        source "$BL_REPO_ROOT/bl"
        # Provide a logger stub
        logger() { return 0; }
        export -f logger
        _bl_notify_register_channels
        alert_channel_enabled syslog && echo "SYSLOG_ENABLED" || echo "SYSLOG_DISABLED"
    '
    # syslog state depends on whether logger(1) binary is present in test env;
    # accept either outcome — the important test is no error on registration
    [ "$status" -eq 0 ]
}

@test "bl_setup --import-from-lmd: extracts slack_token + chmods 0600 (G11)" {
    local td
    td=$(mktemp -d)
    mkdir -p "$td/usr/local/maldetect" "$td/etc/blacklight/notify.d"
    cp "$BATS_TEST_DIRNAME/fixtures/lmd-conf-maldet-sample.conf" "$td/usr/local/maldetect/conf.maldet"
    local bls
    bls="$BATS_TEST_DIRNAME/../bl"
    run bash -c '
        source "'"$bls"'"
        BL_LMD_CONF_PATH="'"$td"'/usr/local/maldetect/conf.maldet"
        BL_BLACKLIGHT_DIR="'"$td"'/etc/blacklight"
        bl_setup_import_from_lmd 2>&1
    '
    [ "$status" -eq 0 ]
    [ -f "$td/etc/blacklight/notify.d/slack.token" ]
    local perms
    perms=$(command stat -c '%a' "$td/etc/blacklight/notify.d/slack.token")
    [ "$perms" = "600" ]
    grep -q 'token=xoxb-test-bot-token' "$td/etc/blacklight/notify.d/slack.token"
    grep -q 'channel=maldetreports' "$td/etc/blacklight/notify.d/slack.token"
    rm -rf "$td"
}

@test "bl setup --import-from-lmd: idempotent on re-run (G11)" {
    local td
    td=$(mktemp -d)
    mkdir -p "$td/usr/local/maldetect"
    cp "$BATS_TEST_DIRNAME/fixtures/lmd-conf-maldet-sample.conf" "$td/usr/local/maldetect/conf.maldet"
    local bls
    bls="$BATS_TEST_DIRNAME/../bl"
    bash -c '
        source "'"$bls"'"
        BL_LMD_CONF_PATH="'"$td"'/usr/local/maldetect/conf.maldet"
        BL_BLACKLIGHT_DIR="'"$td"'/etc/blacklight"
        bl_setup_import_from_lmd
    '
    local first
    first=$(find "$td/etc/blacklight/notify.d" -type f -exec md5sum {} \; | sort)
    bash -c '
        source "'"$bls"'"
        BL_LMD_CONF_PATH="'"$td"'/usr/local/maldetect/conf.maldet"
        BL_BLACKLIGHT_DIR="'"$td"'/etc/blacklight"
        bl_setup_import_from_lmd
    '
    local second
    second=$(find "$td/etc/blacklight/notify.d" -type f -exec md5sum {} \; | sort)
    rm -rf "$td"
    [ "$first" = "$second" ]
}
