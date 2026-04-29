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

@test "M17 live integration: env packages + agent skills + verb routing" {
    _live_skip_unless_live
    # Depends on state.json from test 1 (--sync). Skip if provisioning failed.
    [ -f "$BL_STATE_DIR/state.json" ] || skip "prior test (--sync) did not provision; cannot run M17 integration"

    # (a) Assert live env has config.packages populated with canonical 9-name list.
    local env_id
    env_id=$(jq -r '.env_id // empty' "$BL_STATE_DIR/state.json")
    [ -n "$env_id" ] || { echo "env_id missing from state.json"; return 1; }
    local env_resp
    env_resp=$(curl -sSf \
        "https://api.anthropic.com/v1/environments/${env_id}" \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: managed-agents-2026-04-01")
    # Canonical 9-package list (sorted for stable comparison)
    local canonical_sorted="apache2 duckdb jq libapache2-mod-security2 modsecurity-crs pandoc weasyprint yara zstd"
    local live_sorted
    live_sorted=$(printf '%s' "$env_resp" | jq -r '(.config.packages.apt // []) | sort | join(" ")')
    [ "$live_sorted" = "$canonical_sorted" ] || {
        echo "packages mismatch: got '$live_sorted', want '$canonical_sorted'"; return 1;
    }

    # (b) Assert live agent has skills:[] with 6 custom routing-skill IDs (version: "latest") + pdf.
    local agent_id
    agent_id=$(jq -r '.agent.id // empty' "$BL_STATE_DIR/state.json")
    [ -n "$agent_id" ] || { echo "agent_id missing from state.json"; return 1; }
    local agent_resp
    agent_resp=$(curl -sSf \
        "https://api.anthropic.com/v1/agents/${agent_id}" \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: managed-agents-2026-04-01")
    local custom_count
    custom_count=$(printf '%s' "$agent_resp" | jq '[.skills[] | select(.type == "custom")] | length')
    [ "$custom_count" -eq 6 ] || { echo "expected 6 custom skills, got $custom_count"; return 1; }
    local pdf_present
    pdf_present=$(printf '%s' "$agent_resp" | jq '[.skills[] | select(.type == "anthropic" and .skill_id == "pdf")] | length')
    [ "$pdf_present" -eq 1 ] || { echo "pdf skill missing from agent"; return 1; }
    # Each custom skill must carry version: "latest"
    local non_latest
    non_latest=$(printf '%s' "$agent_resp" | jq '[.skills[] | select(.type == "custom" and .version != "latest")] | length')
    [ "$non_latest" -eq 0 ] || { echo "$non_latest custom skill(s) not pinned to version latest"; return 1; }

    # (c) Assert each routing-skill display_title matches expected name.
    local expected_names=("synthesizing-evidence" "prescribing-defensive-payloads" "curating-cases" "gating-false-positives" "extracting-iocs" "authoring-incident-briefs")
    local skills_list_resp
    skills_list_resp=$(curl -sSf \
        "https://api.anthropic.com/v1/skills" \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: skills-2025-10-02,code-execution-2025-08-25,files-api-2025-04-14")
    local sname missing_titles=""
    for sname in "${expected_names[@]}"; do
        local found
        found=$(printf '%s' "$skills_list_resp" | jq -r --arg n "$sname" \
            '[.data[] | select(.display_title == $n)] | length')
        [ "$found" -ge 1 ] || missing_titles="${missing_titles} $sname"
    done
    [ -z "$missing_titles" ] || { echo "missing routing-skill display_title(s):$missing_titles"; return 1; }

    # NOTE: A sub-test (d) for verb→skill routing via `bl consult --prompt` was
    # dropped at sentinel review — `--prompt` is not (yet) a flag on `bl consult`.
    # Sub-tests (a)/(b)/(c) cover M17's load-bearing deltas (env packages,
    # agent skills:[] with version "latest", routing-skill display titles)
    # without requiring live curator turns. Verb→skill routing verification
    # is a follow-on item (FUTURE.md) once a real consult-prompt UX exists.
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
