#!/usr/bin/env bats
# tests/14-unattended.bats — blacklight.conf parsing + bl_is_unattended chain + tier policy

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    export BL_VAR_DIR
    BL_VAR_DIR="$(mktemp -d)"
    mkdir -p "$BL_VAR_DIR/state"
    export BL_BLACKLIGHT_CONF="$BL_VAR_DIR/blacklight.conf"
}

teardown() {
    [[ -n "${BL_VAR_DIR:-}" && -d "$BL_VAR_DIR" ]] && rm -rf "$BL_VAR_DIR"
}

# G3 — config tree
@test "preflight: blacklight.conf parsed; allowlisted keys exported" {
    cp "$BATS_TEST_DIRNAME/fixtures/blacklight-conf-sample.conf" "$BL_BLACKLIGHT_CONF"
    run bash -c '
        export BL_BLACKLIGHT_CONF="'"$BL_BLACKLIGHT_CONF"'"
        export BL_VAR_DIR="'"$BL_VAR_DIR"'"
        source '"'$BL_SOURCE'"' >/dev/null 2>&1 || true
        _bl_load_blacklight_conf
        printf "MODE=%s\nFLOOR=%s\nWIN=%s\n" \
            "$BL_UNATTENDED_MODE" "$BL_NOTIFY_SEVERITY_FLOOR" \
            "$BL_LMD_TRIGGER_DEDUP_WINDOW_HOURS"
    '
    [[ "$output" == *"MODE=1"* ]]
    [[ "$output" == *"FLOOR=warn"* ]]
    [[ "$output" == *"WIN=12"* ]]
}

@test "preflight: blacklight.conf with metachar in value → log + skip" {
    cp "$BATS_TEST_DIRNAME/fixtures/blacklight-conf-sample.conf" "$BL_BLACKLIGHT_CONF"
    run bash -c '
        export BL_BLACKLIGHT_CONF="'"$BL_BLACKLIGHT_CONF"'"
        export BL_VAR_DIR="'"$BL_VAR_DIR"'"
        source '"'$BL_SOURCE'"' >/dev/null 2>&1 || true
        _bl_load_blacklight_conf 2>&1
    '
    [[ "$output" == *"metacharacter"* ]]
}

@test "preflight: blacklight.conf with unknown key → log + skip" {
    cp "$BATS_TEST_DIRNAME/fixtures/blacklight-conf-sample.conf" "$BL_BLACKLIGHT_CONF"
    run bash -c '
        export BL_BLACKLIGHT_CONF="'"$BL_BLACKLIGHT_CONF"'"
        export BL_VAR_DIR="'"$BL_VAR_DIR"'"
        source '"'$BL_SOURCE'"' >/dev/null 2>&1 || true
        _bl_load_blacklight_conf 2>&1
    '
    [[ "$output" == *"unknown key 'unknown_key'"* ]]
}

# G4 — bl_is_unattended resolution chain
@test "bl_is_unattended: --unattended flag wins over conf" {
    cp "$BATS_TEST_DIRNAME/fixtures/blacklight-conf-sample.conf" "$BL_BLACKLIGHT_CONF"
    run bash -c '
        export BL_BLACKLIGHT_CONF="'"$BL_BLACKLIGHT_CONF"'"
        export BL_VAR_DIR="'"$BL_VAR_DIR"'"
        source '"'$BL_SOURCE'"' >/dev/null 2>&1 || true
        _bl_load_blacklight_conf
        BL_UNATTENDED_MODE=0   # conf says 0
        BL_UNATTENDED_FLAG=1   # flag overrides
        bl_is_unattended && echo "yes" || echo "no"
    '
    [[ "$output" == *"yes"* ]]
}

@test "bl_is_unattended: BL_UNATTENDED env wins over conf" {
    run bash -c '
        export BL_VAR_DIR="'"$BL_VAR_DIR"'"
        source '"'$BL_SOURCE'"' >/dev/null 2>&1 || true
        BL_UNATTENDED=1
        BL_UNATTENDED_MODE=0
        bl_is_unattended && echo "yes" || echo "no"
    '
    [[ "$output" == *"yes"* ]]
}

@test "bl_is_unattended: conf unattended_mode=1 fires when no flag/env" {
    run bash -c '
        export BL_VAR_DIR="'"$BL_VAR_DIR"'"
        source '"'$BL_SOURCE'"' >/dev/null 2>&1 || true
        BL_UNATTENDED_MODE=1
        unset BL_UNATTENDED BL_UNATTENDED_FLAG BL_INVOKED_BY
        bl_is_unattended && echo "yes" || echo "no"
    ' < /dev/null
    [[ "$output" == *"yes"* ]]
}

@test "bl_is_unattended: BL_INVOKED_BY=lmd-hook fires" {
    run bash -c '
        export BL_VAR_DIR="'"$BL_VAR_DIR"'"
        source '"'$BL_SOURCE'"' >/dev/null 2>&1 || true
        BL_INVOKED_BY=lmd-hook
        unset BL_UNATTENDED BL_UNATTENDED_FLAG BL_UNATTENDED_MODE
        bl_is_unattended && echo "yes" || echo "no"
    '
    [[ "$output" == *"yes"* ]]
}

@test "bl_is_unattended: no-TTY fallback fires" {
    run bash -c '
        export BL_VAR_DIR="'"$BL_VAR_DIR"'"
        source '"'$BL_SOURCE'"' >/dev/null 2>&1 || true
        unset BL_UNATTENDED BL_UNATTENDED_FLAG BL_UNATTENDED_MODE BL_INVOKED_BY
        bl_is_unattended && echo "yes" || echo "no"
    ' < /dev/null
    [[ "$output" == *"yes"* ]]
}

# G5 — tier policy under unattended (P9 wires the actual tier policy gates;
# these tests assert the predicate plus the existing run/defend skip paths)
@test "unattended: read-only tier auto-applies" {
    skip "covered after P9 (full setup + run integration)"
}

@test "unattended: reversible-modsec tier auto-applies (gate passes)" {
    skip "covered after P9 (full setup + run integration)"
}

@test "unattended: destructive tier always queues (even with --yes)" {
    skip "covered after P9 (full setup + run integration)"
}

@test "unattended: destructive queue → bl_notify warn" {
    skip "covered after P9 (full setup + run integration)"
}
