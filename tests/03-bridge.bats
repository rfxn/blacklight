#!/usr/bin/env bats
# tests/03-bridge.bats — M16 P3 session-event → memstore-pending bridge.
#
# Covers: report_step extraction + custom_tool_use_id enrichment, cursor
# advance via state.json.session_cursors, idempotent re-post (409→success),
# non-report_step custom-tool skip, no-session no-op, missing case-id arg.
#
# Mock surface: bl_curator_mock_* shims curl. Fixtures live in tests/fixtures/.

load 'helpers/curator-mock.bash'

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    BL_VAR_DIR="$(mktemp -d)"
    export BL_VAR_DIR
    export ANTHROPIC_API_KEY="sk-ant-test"
    export BL_MEMSTORE_CASE_ID="memstore_test"
    mkdir -p "$BL_VAR_DIR/state"
    # Seed legacy per-key files for preflight (matches 03-poll.bats convention)
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
    printf 'memstore_test' > "$BL_VAR_DIR/state/memstore-case-id"
    # Seed minimal state.json with one session_id mapping
    cat > "$BL_VAR_DIR/state/state.json" <<EOF
{
  "schema_version": 1,
  "agent": {"id": "agent_test", "version": 1, "skill_versions": {}},
  "env_id": "env_test",
  "skills": {},
  "files": {},
  "files_pending_deletion": [],
  "case_memstores": {"_legacy": "memstore_test"},
  "case_files": {},
  "case_id_counter": {},
  "case_current": "CASE-2026-0042",
  "session_ids": {"CASE-2026-0042": "sesn_test_bridge"},
  "last_sync": ""
}
EOF
    bl_curator_mock_init
}

teardown() {
    bl_curator_mock_teardown
    [[ -n "$BL_VAR_DIR" && -d "$BL_VAR_DIR" ]] && rm -rf "$BL_VAR_DIR"
}

invoke_bridge() {
    local case_id="$1"
    ( . "$BL_SOURCE" 2>/dev/null; bl_bridge_session_to_memstore "$case_id" )
}

@test "bridge: pulls 3 report_step events from session, posts to memstore pending/" {
    bl_curator_mock_add_route 'GET .*/v1/sessions/sesn_test_bridge/events' 'sessions-events-bridge-3-report-steps.json' 200
    bl_curator_mock_add_route 'POST .*/v1/memory_stores/.*/memories' 'memstore-bridge-step-post-ok.json' 200
    BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/mock-requests.log"
    export BL_MOCK_REQUEST_LOG
    run invoke_bridge CASE-2026-0042
    [ "$status" -eq 0 ]
    # 3 report_step events → 3 POSTs. The 4th custom_tool_use (some_other_custom_tool) is skipped.
    # The URL is /v1/memory_stores/<id>/memories — the pending/<step>.json path lives in the body.
    local post_count
    post_count=$(grep -c "^POST .*memory_stores" "$BL_MOCK_REQUEST_LOG" || true)
    [ "$post_count" -eq 3 ]
}

@test "bridge: enriches each step body with custom_tool_use_id from event id" {
    bl_curator_mock_add_route 'GET .*/v1/sessions/sesn_test_bridge/events' 'sessions-events-bridge-3-report-steps.json' 200
    bl_curator_mock_add_route 'POST .*/v1/memory_stores/.*/memories' 'memstore-bridge-step-post-ok.json' 200
    BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/mock-requests.log"
    export BL_MOCK_REQUEST_LOG
    run invoke_bridge CASE-2026-0042
    [ "$status" -eq 0 ]
    # Each POST body must carry the custom_tool_use_id matching the event id from the fixture.
    grep -F 'sevt_01TestStep0001AAAAAAAA' "$BL_MOCK_REQUEST_LOG"
    grep -F 'sevt_01TestStep0002BBBBBBBB' "$BL_MOCK_REQUEST_LOG"
    grep -F 'sevt_01TestStep0003CCCCCCCC' "$BL_MOCK_REQUEST_LOG"
    # The non-report_step event id must NOT appear (skipped silently).
    ! grep -F 'sevt_01OtherTool0001DDDDDDDD' "$BL_MOCK_REQUEST_LOG"
}

@test "bridge: saves next_page cursor to state.json.session_cursors[case-id]" {
    bl_curator_mock_add_route 'GET .*/v1/sessions/sesn_test_bridge/events' 'sessions-events-bridge-3-report-steps.json' 200
    bl_curator_mock_add_route 'POST .*/v1/memory_stores/.*/memories' 'memstore-bridge-step-post-ok.json' 200
    run invoke_bridge CASE-2026-0042
    [ "$status" -eq 0 ]
    local cursor
    cursor=$(jq -r '.session_cursors["CASE-2026-0042"] // empty' "$BL_VAR_DIR/state/state.json")
    [ "$cursor" = "page_fixture_cursor_aaa" ]
}

@test "bridge: empty event response is no-op rc=0, no cursor advance" {
    bl_curator_mock_add_route 'GET .*/v1/sessions/sesn_test_bridge/events' 'sessions-events-bridge-empty.json' 200
    run invoke_bridge CASE-2026-0042
    [ "$status" -eq 0 ]
    # No cursor should be saved (next_page is null in the empty fixture).
    local cursor
    cursor=$(jq -r '.session_cursors["CASE-2026-0042"] // "absent"' "$BL_VAR_DIR/state/state.json")
    [ "$cursor" = "absent" ]
}

@test "bridge: 409 on memstore POST is treated as success (idempotent re-run)" {
    bl_curator_mock_add_route 'GET .*/v1/sessions/sesn_test_bridge/events' 'sessions-events-bridge-3-report-steps.json' 200
    # 409 conflict on every memstore POST (already-exists)
    bl_curator_mock_add_route 'POST .*/v1/memory_stores/.*/memories' 'memstore-bridge-step-post-ok.json' 409
    run invoke_bridge CASE-2026-0042
    [ "$status" -eq 0 ]
}

@test "bridge: case with no session_id is a no-op (rc=0)" {
    # Wipe session_ids in state.json
    jq '.session_ids = {}' "$BL_VAR_DIR/state/state.json" > "$BL_VAR_DIR/state/state.json.tmp"
    mv "$BL_VAR_DIR/state/state.json.tmp" "$BL_VAR_DIR/state/state.json"
    run invoke_bridge CASE-2026-0042
    [ "$status" -eq 0 ]
}

@test "bridge: missing case-id arg exits 64" {
    run invoke_bridge ""
    [ "$status" -eq 64 ]
}

@test "bridge: malformed case-id arg exits 64" {
    run invoke_bridge "not-a-case"
    [ "$status" -eq 64 ]
}

@test "bridge: cursor reused on second invocation (passed in URL)" {
    # Pre-seed a saved cursor
    jq '. + {session_cursors: {"CASE-2026-0042": "page_resume_xyz"}}' "$BL_VAR_DIR/state/state.json" > "$BL_VAR_DIR/state/state.json.tmp"
    mv "$BL_VAR_DIR/state/state.json.tmp" "$BL_VAR_DIR/state/state.json"
    bl_curator_mock_add_route 'GET .*/v1/sessions/sesn_test_bridge/events' 'sessions-events-bridge-empty.json' 200
    BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/mock-requests.log"
    export BL_MOCK_REQUEST_LOG
    run invoke_bridge CASE-2026-0042
    [ "$status" -eq 0 ]
    grep -F 'page=page_resume_xyz' "$BL_MOCK_REQUEST_LOG"
}

@test "bl flush --session-events --case <id> dispatches to bridge" {
    bl_curator_mock_add_route 'GET .*/v1/sessions/sesn_test_bridge/events' 'sessions-events-bridge-empty.json' 200
    run "$BL_SOURCE" flush --session-events --case CASE-2026-0042
    [ "$status" -eq 0 ]
}

@test "bl flush without target arg exits 64" {
    run "$BL_SOURCE" flush
    [ "$status" -eq 64 ]
    [[ "$output" == *"missing target"* ]]
}

@test "bl flush --session-events with no open sessions is no-op rc=0" {
    jq '.session_ids = {}' "$BL_VAR_DIR/state/state.json" > "$BL_VAR_DIR/state/state.json.tmp"
    mv "$BL_VAR_DIR/state/state.json.tmp" "$BL_VAR_DIR/state/state.json"
    run "$BL_SOURCE" flush --session-events
    [ "$status" -eq 0 ]
}
