#!/usr/bin/env bats
# tests/live/setup-live.bats — M15 P8: live integration smoke
#
# Exercises bl setup → check → consult-create-session against the real
# Anthropic Managed Agents API. Mirrors the gating pattern from
# tests/skill-routing/eval-runner.bats (BL_LIVE=1 + ANTHROPIC_API_KEY).
#
# GATING: BL_LIVE=1 required to exercise live paths.
# Default CI behaviour (BL_LIVE unset): every test skips cleanly → exit 0.

LIVE_SKIP_MSG="BL_LIVE=1 required (live API)"

_live_skip_unless_live() {
    [[ -n "${BL_LIVE:-}" ]] || skip "$LIVE_SKIP_MSG"
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] || { echo "ANTHROPIC_API_KEY required when BL_LIVE=1"; return 1; }
}

# Shared workspace dir across all tests in the file — tests 2-4 depend on
# state.json provisioned by test 1. setup_file() runs once before any test;
# setup() re-running mktemp -d per test would isolate state and trip the
# `[ -f state.json ] || skip` guards in tests 2-4.
setup_file() {
    BL_VAR_DIR_LIVE="$(mktemp -d)"
    export BL_VAR_DIR_LIVE
}

teardown_file() {
    [[ -d "${BL_VAR_DIR_LIVE:-}" ]] && rm -rf "$BL_VAR_DIR_LIVE"
}

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../../bl}"
    export BL_VAR_DIR="$BL_VAR_DIR_LIVE"
    export BL_STATE_DIR="$BL_VAR_DIR/state"
    BL_REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export BL_REPO_ROOT
}

@test "bl setup --sync: provisions agent + env + memstore + corpora + skills-as-files against live API" {
    _live_skip_unless_live
    run "$BL_SOURCE" setup --sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"agent created"* ]] || [[ "$output" == *"agent updated"* ]]
    [ -f "$BL_STATE_DIR/state.json" ]
    [ -n "$(jq -r '.agent.id // empty' "$BL_STATE_DIR/state.json")" ]
    [ -n "$(jq -r '.env_id // empty' "$BL_STATE_DIR/state.json")" ]
    # 8 corpus files + 6 routing-skill fallback files = 14 when Skills API is unavailable
    local fc
    fc=$(jq -r '.files | length' "$BL_STATE_DIR/state.json")
    [ "$fc" -ge 8 ]
    [ -n "$(jq -r '.case_memstores._default // empty' "$BL_STATE_DIR/state.json")" ]
}

@test "bl setup --check: post-sync reports all resources present" {
    _live_skip_unless_live
    # state.json provisioned by the previous test in this file (shared
    # BL_VAR_DIR via setup_file). If absent, the previous test failed.
    [ -f "$BL_STATE_DIR/state.json" ] || skip "previous test (--sync) did not provision; cannot --check"
    run "$BL_SOURCE" setup --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"agent: ok"* ]]
    [[ "$output" == *"env: ok"* ]]
    [[ "$output" == *"files:"* ]]
}

@test "bl consult --new (smoke): creates case + session with corpora attached" {
    _live_skip_unless_live
    [ -f "$BL_STATE_DIR/state.json" ] || skip "prior test did not provision"
    run "$BL_SOURCE" consult --new --trigger "M15-P8-smoke"
    [ "$status" -eq 0 ]
    # bl_consult_new emits the allocated case-id as the LAST line of stdout.
    # Earlier lines may name OTHER cases (dedup-warning, materialize-conflict
    # 409 messages naming the conflicting case) — must take the trailing
    # match, not the first.
    local case_id
    case_id=$(printf '%s\n' "$output" | grep -oE 'CASE-[0-9]{4}-[0-9]{4}' | tail -1)
    [ -n "$case_id" ]
    # Session is created by bl_consult_register_curator; persisted to legacy path
    local sid_file="$BL_STATE_DIR/session-$case_id"
    [ -f "$sid_file" ]
    local session_id
    session_id=$(cat "$sid_file")
    [ -n "$session_id" ]
}

@test "bl setup --reset --force: archive verb retires the agent live" {
    _live_skip_unless_live
    [ -f "$BL_STATE_DIR/state.json" ] || skip "prior test did not provision"
    local agent_id
    agent_id=$(jq -r '.agent.id // empty' "$BL_STATE_DIR/state.json")
    run "$BL_SOURCE" setup --reset --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"archived agent $agent_id"* ]]
    [ "$(jq -r '.agent.id' "$BL_STATE_DIR/state.json")" = "" ]
}
