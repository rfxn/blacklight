#!/usr/bin/env bats
# tests/03-poll.bats — M11 P6 bl_poll_pending real-loop coverage.
#
# Covers: --timeout exit, step_id emit, dedup across ticks, 3-empty-cycle
# end_turn proxy, auth-fail propagation, BL_POLL_DRY_RUN bypass, missing
# case-id arg. The poll function reads from a curator-mocked listing
# endpoint; fixtures live at tests/fixtures/memstore-pending-poll-*.json.

load 'helpers/curator-mock.bash'

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    BL_VAR_DIR="$(mktemp -d)"
    export BL_VAR_DIR
    export ANTHROPIC_API_KEY="sk-ant-test"
    export BL_MEMSTORE_CASE_ID="memstore_test"
    mkdir -p "$BL_VAR_DIR/state"
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
    printf 'memstore_test' > "$BL_VAR_DIR/state/memstore-case-id"
    bl_curator_mock_init
}

teardown() {
    bl_curator_mock_teardown
}

# Source bl in a subshell, run bl_poll_pending, propagate rc.
invoke_poll() {
    local case_id="$1"
    shift
    ( . "$BL_SOURCE" 2>/dev/null; bl_poll_pending "$case_id" "$@" )
}

@test "bl_poll_pending --timeout=1 exits 0 after 1s with no new steps" {
    bl_curator_mock_set_response 'memstore-pending-poll-empty.json' 200
    run invoke_poll CASE-2026-0042 --timeout 1 --interval 1
    [ "$status" -eq 0 ]
}

@test "bl_poll_pending emits step_id from listing tick" {
    bl_curator_mock_add_route 'pending' 'memstore-pending-poll-tick1.json' 200
    run invoke_poll CASE-2026-0042 --timeout 1 --interval 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"s-0001"* ]]
}

@test "bl_poll_pending dedup — same step_id on two ticks emits once" {
    bl_curator_mock_add_route 'pending' 'memstore-pending-poll-tick1.json' 200
    run invoke_poll CASE-2026-0042 --timeout 3 --interval 1
    [ "$status" -eq 0 ]
    local count
    count=$(printf '%s\n' "$output" | grep -c '^s-0001$')
    [ "$count" -eq 1 ]
}

@test "bl_poll_pending 3 empty cycles → exit 0 (end_turn proxy)" {
    bl_curator_mock_set_response 'memstore-pending-poll-empty.json' 200
    run invoke_poll CASE-2026-0042 --interval 1
    [ "$status" -eq 0 ]
}

@test "bl_poll_pending 401 → exit 65 (auth fail propagation)" {
    bl_curator_mock_set_response 'memstore-pending-poll-empty.json' 401
    run invoke_poll CASE-2026-0042 --interval 1
    [ "$status" -eq 65 ]
}

@test "bl_poll_pending BL_POLL_DRY_RUN=1 returns 0 immediately" {
    BL_POLL_DRY_RUN=1 run invoke_poll CASE-2026-0042 --timeout 99 --interval 99
    [ "$status" -eq 0 ]
}

@test "bl_poll_pending without case-id arg → exit 64" {
    run invoke_poll "" --interval 1
    [ "$status" -eq 64 ]
}
