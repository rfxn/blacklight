#!/usr/bin/env bats
# tests/02-preflight.bats — bl_preflight happy-path + fail-path coverage
# Consumes tests/helpers/bl-preflight-mock.bash for zero-network API stubbing.

load 'helpers/bl-preflight-mock.bash'

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    export BL_VAR_DIR="$(mktemp -d)"
    export ANTHROPIC_API_KEY="sk-ant-test"
    bl_mock_init   # prepends mock curl to PATH
}

teardown() {
    bl_mock_teardown
    [[ -n "${BL_VAR_DIR:-}" && -d "$BL_VAR_DIR" ]] && rm -rf "$BL_VAR_DIR"
}

@test "bl_preflight on unseeded workspace returns 66 and prints bootstrap heredoc" {
    bl_mock_set_response empty
    run "$BL_SOURCE" observe
    [ "$status" -eq 66 ]
    [[ "$output" == *"this Anthropic workspace has not been seeded"* ]]
    [[ "$output" == *"bl setup"* ]]
}

@test "bl_preflight with cached agent-id returns 0 (skip API probe)" {
    mkdir -p "$BL_VAR_DIR/state"
    printf '%s' "agent_cached_stub" > "$BL_VAR_DIR/state/agent-id"
    # mock still configured empty — preflight should NOT hit API because cache exists.
    bl_mock_set_response empty
    run "$BL_SOURCE" observe
    # preflight passes (cached agent-id), router returns 64 with missing sub-verb diagnostic
    [ "$status" -eq 64 ]
    [[ "$output" == *"missing sub-verb"* ]]
}

@test "bl_preflight on seeded workspace (API returns 1+ agent) caches agent-id and returns 0" {
    # No pre-seed. Mock returns populated list. Preflight should cache + pass.
    bl_mock_set_response populated
    run "$BL_SOURCE" observe
    [ "$status" -eq 64 ]   # preflight success → handler stub → 64
    [[ -r "$BL_VAR_DIR/state/agent-id" ]]
    [[ "$(cat "$BL_VAR_DIR/state/agent-id")" == "agent_test_stub" ]]
}

@test "bl_preflight without ANTHROPIC_API_KEY exits 65 with distinct diagnostic" {
    unset ANTHROPIC_API_KEY
    run "$BL_SOURCE" observe
    [ "$status" -eq 65 ]
    [[ "$output" == *"ANTHROPIC_API_KEY not set"* ]]
}

@test "bl_preflight with empty ANTHROPIC_API_KEY exits 65 with distinct diagnostic" {
    export ANTHROPIC_API_KEY=""
    run "$BL_SOURCE" observe
    [ "$status" -eq 65 ]
    [[ "$output" == *"ANTHROPIC_API_KEY empty"* ]]
}

@test "bl_preflight without curl in PATH exits 65" {
    # Build an isolated PATH containing only jq (no curl) — mirrors no-jq test pattern
    local jq_only_dir
    jq_only_dir=$(mktemp -d)
    local real_jq
    real_jq=$(command -v jq) || skip "jq not installed in the test environment"
    cp "$real_jq" "$jq_only_dir/jq"
    local saved_path="$PATH"
    PATH="$jq_only_dir" run "$BL_SOURCE" observe
    PATH="$saved_path"
    rm -rf "$jq_only_dir"
    [ "$status" -eq 65 ]
    [[ "$output" == *"curl not found"* ]]
}

@test "bl_preflight without jq in PATH exits 65" {
    # Build a PATH containing only curl (via mock), no jq
    local curl_only_dir
    curl_only_dir=$(mktemp -d)
    cp "$BL_MOCK_BIN/curl" "$curl_only_dir/curl"
    local saved_path="$PATH"
    PATH="$curl_only_dir" run "$BL_SOURCE" observe
    PATH="$saved_path"
    rm -rf "$curl_only_dir"
    [ "$status" -eq 65 ]
    [[ "$output" == *"jq not found"* ]]
}

@test "bl with corrupted (empty) agent-id file re-probes and treats as unseeded" {
    mkdir -p "$BL_VAR_DIR/state"
    : > "$BL_VAR_DIR/state/agent-id"   # empty file
    bl_mock_set_response empty
    run "$BL_SOURCE" observe
    [ "$status" -eq 66 ]
    [[ "$output" == *"not been seeded"* ]]
}

@test "bl_preflight 401 (invalid API key) → exit 65 with auth error envelope" {
    # Per src/bl.d/20-api.sh:35-39 (bl_api_call), 401/403 returns
    # BL_EX_PREFLIGHT_FAIL=65 with "authentication failed (HTTP 401)".
    bl_mock_set_response bad_key
    run "$BL_SOURCE" observe
    [ "$status" -eq 65 ]
    [[ "$output" == *"authentication"* ]] || [[ "$output" == *"401"* ]]
}

# ---------------------------------------------------------------------------
# M12 P3: preflight drains outbox when entries are aged beyond warn threshold
# The drain gate only fires after a live API probe caches the agent-id (the
# cached-agent-id fast-path exits before reaching the drain code). This test
# leaves the state/agent-id file absent so preflight does the full probe, then
# checks that the info log message from bl_outbox_should_drain + drain appears.
# ---------------------------------------------------------------------------

@test "preflight outbox drain fires when oldest entry age exceeds warn threshold" {
    # Pre-populate outbox with one aged wake entry
    mkdir -p "$BL_VAR_DIR/outbox"
    local aged_entry="$BL_VAR_DIR/outbox/20260101T000000Z-0001-wake-CASE-2026-0001.json"
    printf '{"type":"user.message","case":"CASE-2026-0001","content":[{"type":"text","text":"aged wake"}]}\n' > "$aged_entry"
    # Force mtime to 2h ago so it is > BL_OUTBOX_AGE_WARN_SECS (3600s)
    touch -d "2 hours ago" "$aged_entry"

    # Use populated mock — API returns agent_test_stub; preflight caches it then
    # reaches the drain block. No pre-seeded agent-id so the probe path fires.
    bl_mock_set_response populated

    # BL_LOG_LEVEL=info ensures bl_info output reaches captured output
    BL_LOG_LEVEL=info run "$BL_SOURCE" observe
    # status 64 (missing sub-verb) is expected — preflight passed, routing failed.
    # Drain attempt should have logged an info message on stderr (captured by BATS run).
    [[ "$output" == *"outbox has aged entries"* ]] || [[ "$output" == *"draining"* ]]
}

# ---------------------------------------------------------------------------
# M14 P3: bl_init_workdir creates baserun/ subdir for tlog_lib cursor state
# ---------------------------------------------------------------------------

@test "bl_init_workdir creates baserun/ subdir for tlog_lib cursor state" {
    local td
    td=$(mktemp -d)
    BL_VAR_DIR="$td" run bash -c 'source ./bl; bl_init_workdir'
    [ "$status" -eq 0 ]
    [ -d "$td/baserun" ]
    command rm -rf "$td"
}

@test "bl on bash <4.1 exits 65 with 'bash 4.1+ required' (best-effort source-under-patched-VERSINFO)" {
    # Attempt to source bl under a patched BASH_VERSINFO simulating bash 3.2.
    # If the patched assignment does not propagate, skip the test.
    local rc=0
    local out
    out=$(bash -c '
        BASH_VERSINFO=([0]=3 [1]=2 [2]=0 [3]=0 [4]=0 [5]="x86_64")
        if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 401 )); then
            echo "SKIP: VERSINFO patch did not take"
            exit 88
        fi
        source "'"$BL_SOURCE"'" --version 2>&1
        echo "rc=$?"
    ' 2>&1) || rc=$?
    if [[ "$out" == *"SKIP: VERSINFO patch did not take"* ]]; then
        skip "bash floor test requires bash >=4 with VERSINFO assignable"
    fi
    [[ "$out" == *"bash 4.1+ required"* ]]
}
