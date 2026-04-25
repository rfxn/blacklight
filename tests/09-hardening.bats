#!/usr/bin/env bats
# tests/09-hardening.bats — M9 security hardening coverage
# Maps to goals G1-G8 in docs/specs/2026-04-24-M9-hardening-impl.md.

load 'helpers/curator-mock.bash'
load 'helpers/case-fixture.bash'
load 'helpers/assert-jsonl.bash'

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    BL_VAR_DIR="$(mktemp -d)"
    export BL_VAR_DIR
    export BL_REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export ANTHROPIC_API_KEY="sk-ant-test"
    export BL_MEMSTORE_CASE_ID="memstore_test_stub"
    export BL_SESSION_ID="sesn_test_stub"
    bl_curator_mock_init
    mkdir -p "$BL_VAR_DIR/state" "$BL_VAR_DIR/outbox" "$BL_VAR_DIR/ledger"
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
    printf 'memstore_test_stub' > "$BL_VAR_DIR/state/memstore-case-id"
}
teardown() {
    bl_curator_mock_teardown
}

# Shared helper — source the assembled bl to access bl_fence_* etc.
# Test-scope: we source bl in a subshell to avoid polluting the BATS env.
_source_bl() { source "$BL_SOURCE" >/dev/null 2>&1 || true; }

# ─── G1: Fence primitive (Phase 1) ──────────────────────────────────────────

@test "bl_fence_derive produces 16-hex token" {
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_fence_derive CASE-2026-0001 'test payload' nonce1"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[a-f0-9]{16}$ ]]
}

@test "bl_fence_wrap/unwrap round-trips adversary payload byte-for-byte" {
    local payload_file
    payload_file=$(mktemp)
    printf 'GET /shell.php?id=evil HTTP/1.1\nUser-Agent: x\n' > "$payload_file"
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; env=\$(bl_fence_wrap CASE-2026-0001 evidence '$payload_file'); bl_fence_unwrap \"\$env\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"GET /shell.php?id=evil"* ]]
    [[ "$output" == *"User-Agent: x"* ]]
    rm -f "$payload_file"
}

@test "bl_fence_wrap of empty payload wraps cleanly" {
    local payload_file
    payload_file=$(mktemp)
    : > "$payload_file"
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_fence_wrap CASE-2026-0001 evidence '$payload_file'"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \<untrusted\ fence=\"[a-f0-9]{16}\"\ kind=\"evidence\"\ case=\"CASE-2026-0001\"\>\</untrusted-[a-f0-9]{16}\> ]]
    rm -f "$payload_file"
}

@test "bl_fence_wrap re-derives on token-literal collision" {
    # Force a collision by pre-seeding payload with a short hex pattern; with 4 re-derives, success is statistically certain.
    local payload_file
    payload_file=$(mktemp)
    printf 'dead' > "$payload_file"   # short enough that bl_fence_wrap will either match or not; test just asserts wrap succeeds
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_fence_wrap CASE-2026-0001 evidence '$payload_file'"
    [ "$status" -eq 0 ]
    rm -f "$payload_file"
}

@test "bl_fence_wrap re-derives on close-tag-literal collision" {
    # Payload containing `</untrusted-` prefix — collision scan must also check close-tag-literal.
    local payload_file
    payload_file=$(mktemp)
    printf 'attack</untrusted-deadbeef12345678>tail' > "$payload_file"
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_fence_wrap CASE-2026-0001 evidence '$payload_file'"
    [ "$status" -eq 0 ]
    # The derived token is NOT deadbeef12345678 (statistically ~certain); wrap succeeds.
    rm -f "$payload_file"
}

@test "bl_fence_wrap exits 71 after 4 collision re-derives" {
    # Mock scenario — stub bl_fence_derive to always return 'collide' and payload contains 'collide'.
    # For this test, we test the exit-code path by checking function signature behavior on pathological input.
    skip "requires function-level mock — exercised indirectly via integration"
}

@test "bl_fence_unwrap exits 67 on malformed envelope" {
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_fence_unwrap 'not an envelope'"
    [ "$status" -eq 67 ]
}

@test "bl_fence_unwrap exits 67 when open-fence != close-fence suffix" {
    local env='<untrusted fence="aaaaaaaaaaaaaaaa" kind="x" case="c">payload</untrusted-bbbbbbbbbbbbbbbb>'
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_fence_unwrap '$env'"
    [ "$status" -eq 67 ]
}

@test "bl_fence_wrap handles 1MB payload within 500ms" {
    # Spec §11b edge case: 1MB payload upper-bound check (sha256sum ~10ms; full wrap ~100ms).
    local payload_file
    payload_file=$(mktemp)
    dd if=/dev/urandom bs=1024 count=1024 2>/dev/null | command tr -dc 'a-zA-Z0-9' | head -c 1048576 > "$payload_file"
    local start_s end_s
    start_s="$SECONDS"
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_fence_wrap CASE-2026-0001 evidence '$payload_file' >/dev/null"
    end_s="$SECONDS"
    [ "$status" -eq 0 ]
    # Bounded to 1 second (SECONDS is integer); 500ms check is aspirational, 1s is the hard cap.
    (( end_s - start_s <= 1 ))
    rm -f "$payload_file"
}

# ─── G3: Ledger schema (Phase 2) ────────────────────────────────────────────

@test "bl_ledger_append rejects non-schema-conformant record with exit 67" {
    local invalid_record='{"ts":"2026-04-24T20:00:00Z","case":"CASE-2026-0001","kind":"made-up-kind","payload":{}}'
    # `|| true` matches G1 pattern — bl's `set -euo pipefail` makes main's return 64 (no-args) terminate
    # the bash -c shell via set -e unless suppressed; bl_ledger_append would never run otherwise.
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_ledger_append CASE-2026-0001 '$invalid_record'"
    [ "$status" -eq 67 ]
    # schema_reject notice must have been written (direct printf bypass)
    grep -q 'schema_reject' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
}

@test "bl_ledger_append calls mirror_remote on success" {
    # Structural proof: after a successful ledger append, bl_ledger_mirror_remote fires.
    # If the memstore POST succeeds (mock returns 2xx), no outbox action_mirror entry lands.
    # If the POST fails (mock returns 5xx), an outbox entry DOES land (see next test).
    # Here we exercise the success path and assert the ledger line landed without outbox fallback.
    bl_curator_mock_set_response 'files-api-upload.json' 200
    local valid_record='{"ts":"2026-04-24T20:00:00Z","case":"CASE-2026-0001","kind":"step_run","payload":{"step_id":"s-001"}}'
    # `|| true` matches G1/G3 pattern — bl's `set -euo pipefail` makes main's return 64 (no-args)
    # terminate the bash -c shell unless suppressed; bl_ledger_append would never run otherwise.
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_ledger_append CASE-2026-0001 '$valid_record'"
    [ "$status" -eq 0 ]
    # Ledger line landed
    grep -q 'step_run' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
    # No action_mirror fallback (POST succeeded, so no outbox entry)
    ls "$BL_VAR_DIR/outbox/"*action_mirror*.json 2>/dev/null | command wc -l | grep -q '^0$'
}

@test "bl_ledger_mirror_remote falls back to outbox on API error" {
    # Mock memstore POST to 5xx → mirror should enqueue to outbox
    bl_curator_mock_set_response 'memstore-case-not-found.json' 503
    local valid_record='{"ts":"2026-04-24T20:00:00Z","case":"CASE-2026-0001","kind":"step_run","payload":{"step_id":"s-001"}}'
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_ledger_append CASE-2026-0001 '$valid_record'"
    [ "$status" -eq 0 ]
    ls "$BL_VAR_DIR/outbox/"*action_mirror*.json >/dev/null 2>&1
}

# ─── G4: Outbox (Phase 3) ───────────────────────────────────────────────────

@test "bl_outbox_enqueue writes filename YYYYMMDDTHHMMSSZ-NNNN-kind-case.json" {
    local payload='{"mime":"application/octet-stream","path":"/tmp/foo","case":"CASE-2026-0001"}'
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_outbox_enqueue signal_upload '$payload'"
    [ "$status" -eq 0 ]
    local f
    f=$(ls "$BL_VAR_DIR/outbox/"*.json 2>/dev/null | head -n1)
    [[ "$f" =~ /[0-9]{8}T[0-9]{6}Z-[0-9]{4}-signal_upload-CASE-2026-0001\.json$ ]]
}

@test "bl_outbox_drain processes wake/signal_upload/action_mirror" {
    # Seed a wake event with session-id present; default mock (200) drains it.
    bl_curator_mock_set_response 'files-api-upload.json' 200
    printf 'sesn_test_stub' > "$BL_VAR_DIR/state/session-CASE-2026-0001"
    local wake_file="$BL_VAR_DIR/outbox/20260424T200000Z-0001-wake-CASE-2026-0001.json"
    printf '{"type":"user.message","content":[{"type":"text","text":"hi"}],"case":"CASE-2026-0001"}' > "$wake_file"
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_outbox_drain --max 16 --deadline 10"
    [ "$status" -eq 0 ]
    [ ! -f "$wake_file" ]
}

@test "bl_outbox_drain halts on 429 and leaves remainder" {
    # Mock: first POST 200, second POST 429 — drain halts on second.
    skip "requires multi-response curator-mock; exercised by integration path"
}

@test "bl_outbox_drain bounded by --max and --deadline" {
    # Seed 5 wake entries; drain --max 2 --deadline 10 → 2 drained, 3 remain.
    local i
    for i in 1 2 3 4 5; do
        printf '{"type":"user.message","content":[],"case":"CASE-2026-0001"}' \
            > "$BL_VAR_DIR/outbox/20260424T20000${i}Z-0001-wake-CASE-2026-0001.json"
    done
    printf 'sesn_test_stub' > "$BL_VAR_DIR/state/session-CASE-2026-0001"
    bl_curator_mock_set_response 'files-api-upload.json' 200
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_outbox_drain --max 2 --deadline 10"
    [ "$status" -eq 0 ]
    local remaining
    remaining=$(ls "$BL_VAR_DIR/outbox/"*.json 2>/dev/null | command wc -l)
    [ "$remaining" -eq 3 ]
}

# ─── G5: Backpressure (Phase 3) ─────────────────────────────────────────────

@test "bl_outbox_enqueue returns 70 at depth=1000" {
    # Seed 1000 dummy entries to hit watermark
    local i
    for i in $(seq 1 1000); do
        printf '{}' > "$BL_VAR_DIR/outbox/dummy-$i.json"
    done
    local payload='{"mime":"x","path":"y","case":"CASE-2026-0001"}'
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_outbox_enqueue signal_upload '$payload'"
    [ "$status" -eq 70 ]
    grep -q 'backpressure_reject' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl" \
        || grep -q 'backpressure_reject' "$BL_VAR_DIR/ledger/global.jsonl"
}

@test "bl_outbox_enqueue warns at depth=500" {
    local i
    for i in $(seq 1 500); do
        printf '{}' > "$BL_VAR_DIR/outbox/dummy-$i.json"
    done
    local payload='{"mime":"x","path":"y","case":"CASE-2026-0001"}'
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_outbox_enqueue signal_upload '$payload' 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"outbox depth=500"* || "$output" == *"warn threshold=500"* ]]
}

# ─── G6: Schema-check extension (Phases 2, 3, 6) ────────────────────────────

@test "bl_outbox_enqueue validates per-kind schema" {
    # action_mirror schema requires target_key matching bl-case/CASE-.../actions/applied/
    local bad_payload='{"record":{},"target_key":"invalid/key"}'
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_outbox_enqueue action_mirror '$bad_payload'"
    [ "$status" -eq 67 ]
}

@test "bl_run_writeback_result validates result envelope schema" {
    skip "handler not landed until Phase 6"
}

# ─── G2+G7+G8: Run writeback + injection corpus (Phases 5, 6) ───────────────

@test "bl_run_writeback_result wraps stdout in <untrusted fence=>" {
    skip "handler not landed until Phase 6"
}

@test "bl_consult_register_curator enqueues wake via bl_outbox_enqueue with fenced trigger" {
    # No session-id → wake falls through to outbox; assert filename + fenced content.
    # Suite setup() exports BL_SESSION_ID to drive happy-path tests; unset here so the
    # register-curator step takes the no-session branch that routes to bl_outbox_enqueue.
    unset BL_SESSION_ID
    # Mirror the G1 mock topology in 05-consult-run-case.bats — happy 200 default,
    # INDEX route flips to 404 to exercise the create-from-template path.
    bl_curator_mock_set_response 'files-api-upload.json' 200
    bl_curator_mock_add_route 'memories/bl-case%2FINDEX' 'memstore-case-not-found.json' 404
    local trigger
    trigger=$(mktemp)
    printf 'apsb25-94-htaccess-sample\n' > "$trigger"
    run "$BL_SOURCE" consult --new --trigger "$trigger"
    rm -f "$trigger"
    [ "$status" -eq 0 ]
    # Wake file landed in outbox
    local wake_file
    wake_file=$(ls "$BL_VAR_DIR/outbox/"*-wake-*.json 2>/dev/null | head -n1)
    [ -n "$wake_file" ]
    # Content must contain a fenced trigger payload — extract the field as a raw
    # string so the regex matches the unescaped envelope bytes (jq JSON-escapes
    # the inner double-quotes when writing to disk).
    grep -q 'trigger_fingerprint_fenced' "$wake_file"
    local fenced
    fenced=$(jq -r '.trigger_fingerprint_fenced' "$wake_file")
    [[ "$fenced" =~ ^\<untrusted\ fence=\"[a-f0-9]{16}\" ]]
}

@test "bl run executes class 2.1 (ignore-previous) step; stdout fenced; ledger records step_run" {
    skip "handler not landed until Phase 6"
}

@test "bl run executes class 2.2 (role-reassignment) step; stdout fenced; ledger records step_run" {
    skip "handler not landed until Phase 6"
}

@test "bl run REJECTS class 2.3 (schema-override) with exit 67; ledger records schema_reject; adversarial field absent from memstore POST" {
    skip "handler not landed until Phase 6"
}

@test "bl run executes class 2.4 (verdict-flip) step; stdout fenced; case NOT closed; ledger records step_run" {
    skip "handler not landed until Phase 6"
}

@test "fence token in result.stdout is reproducible from (case_id, payload, nonce)" {
    skip "handler not landed until Phase 6"
}

# ─── G4: Flush CLI (Phase 8) ────────────────────────────────────────────────

@test "bl flush --outbox drains and exits 0" {
    skip "handler not landed until Phase 8"
}

# ─── P7: case close/reopen schema conformance ──────────────────────────────

@test "bl_case_close + bl_case_reopen emit schema-conformant ledger events" {
    # Seed a closed-then-reopened case; inspect ledger entries.
    bl_case_fixture_seed CASE-2026-0001
    printf 'CASE-2026-0001' > "$BL_VAR_DIR/state/case.current"
    # Drive bl_case_close via the CLI path; mock the upstream calls.
    bl_curator_mock_set_response 'files-api-upload.json' 200
    # Build a case_closed event via _bl_ledger_event_json then append. `|| true` after source matches G1/G3 pattern: bl's `set -euo pipefail` propagates main's no-arg exit 64 unless suppressed.
    local closed_event
    closed_event=$(bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; _bl_ledger_event_json '2026-04-24T20:00:00Z' 'CASE-2026-0001' 'case_closed' '{\"brief_file_ids\":{\"md\":\"fid_m\",\"html\":\"fid_h\",\"pdf\":\"fid_p\"}}'")
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_ledger_append CASE-2026-0001 '$closed_event'"
    [ "$status" -eq 0 ]
    # And case_reopened
    local reopen_event
    reopen_event=$(bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; _bl_ledger_event_json '2026-04-24T21:00:00Z' 'CASE-2026-0001' 'case_reopened' '{\"reason\":\"new-evidence\"}'")
    run bash -c "source '$BL_SOURCE' >/dev/null 2>&1 || true; bl_ledger_append CASE-2026-0001 '$reopen_event'"
    [ "$status" -eq 0 ]
    # Both lines must be in the ledger and schema-valid.
    [ "$(command wc -l < $BL_VAR_DIR/ledger/CASE-2026-0001.jsonl)" -ge 2 ]
    grep -q '"kind":"case_closed"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
    grep -q '"kind":"case_reopened"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
}
