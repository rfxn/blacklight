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

@test "bl setup --sync: provisions agent + env + memstore + 8 corpora against live API" {
    _live_skip_unless_live
    run "$BL_SOURCE" setup --sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"agent created"* ]] || [[ "$output" == *"agent updated"* ]]
    [ -f "$BL_STATE_DIR/state.json" ]
    [ -n "$(jq -r '.agent.id // empty' "$BL_STATE_DIR/state.json")" ]
    [ -n "$(jq -r '.env_id // empty' "$BL_STATE_DIR/state.json")" ]
    [ "$(jq -r '.files | length' "$BL_STATE_DIR/state.json")" -eq 8 ]
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
    [[ "$output" == *"files: 8 workspace files"* ]]
}

@test "bl consult --new (smoke): creates session with corpora attached" {
    _live_skip_unless_live
    [ -f "$BL_STATE_DIR/state.json" ] || skip "prior test did not provision"
    # Open a fresh case; --attach creates the session bound to the agent
    run "$BL_SOURCE" consult --new --trigger "M15-P8-smoke" --attach
    [ "$status" -eq 0 ]
    local case_id session_id
    case_id=$(jq -r '.case_current // empty' "$BL_STATE_DIR/state.json")
    session_id=$(jq -r --arg c "$case_id" '.session_ids[$c] // empty' "$BL_STATE_DIR/state.json")
    [ -n "$case_id" ]
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
