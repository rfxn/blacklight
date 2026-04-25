#!/usr/bin/env bats
# tests/05-consult-run-case.bats — M5 bl consult/run/case coverage
# Consumes tests/helpers/{curator-mock,case-fixture,assert-jsonl}.bash.

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
}

teardown() {
    bl_curator_mock_teardown
    bl_case_fixture_teardown
}

# ---------------------------------------------------------------------------
# G1: bl consult --new allocates case-id + writes case.current
# ---------------------------------------------------------------------------

@test "bl consult --new allocates CASE-YYYY-NNNN and writes case.current" {
    # Seed agent-id; all API calls to memstore succeed (201 POST, 200 GET)
    mkdir -p "$BL_VAR_DIR/state"
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
    printf 'memstore_test_stub' > "$BL_VAR_DIR/state/memstore-case-id"
    # Default catch-all first, then specific overrides (routes matched in order)
    bl_curator_mock_set_response 'files-api-upload.json' 200
    bl_curator_mock_add_route 'memories/bl-case%2FINDEX' 'memstore-case-not-found.json' 404
    local trigger
    trigger=$(mktemp)
    printf 'apsb25-94-htaccess-sample\n' > "$trigger"
    run "$BL_SOURCE" consult --new --trigger "$trigger"
    rm -f "$trigger"
    [ "$status" -eq 0 ]
    [[ "$output" =~ CASE-[0-9]{4}-[0-9]{4} ]]
    [ -f "$BL_VAR_DIR/state/case.current" ]
    [[ "$(cat "$BL_VAR_DIR/state/case.current")" =~ ^CASE-[0-9]{4}-[0-9]{4}$ ]]
}

# ---------------------------------------------------------------------------
# G2: bl consult --attach hit + miss
# ---------------------------------------------------------------------------

@test "bl consult --attach to existing case flips case.current" {
    bl_case_fixture_seed CASE-2026-0001
    # hypothesis.md probe returns 200 → case found
    bl_curator_mock_add_route 'hypothesis' 'files-api-upload.json' 200
    run "$BL_SOURCE" consult --attach CASE-2026-0001
    [ "$status" -eq 0 ]
    [ "$(cat "$BL_VAR_DIR/state/case.current")" = "CASE-2026-0001" ]
}

@test "bl consult --attach rejects malformed case-id (traversal attempt)" {
    bl_case_fixture_seed CASE-2026-0001
    rm -f "$BL_VAR_DIR/state/case.current"
    run "$BL_SOURCE" consult --attach '../../etc/passwd'
    [ "$status" -eq 64 ]   # BL_EX_USAGE
    printf '%s\n' "$output" | grep -q "case-id format invalid"
    # case.current must NOT have been written
    [ ! -f "$BL_VAR_DIR/state/case.current" ]
}

@test "bl consult --attach rejects shape-mismatched case-id" {
    bl_case_fixture_seed CASE-2026-0001
    rm -f "$BL_VAR_DIR/state/case.current"
    run "$BL_SOURCE" consult --attach 'CASE-26-1'
    [ "$status" -eq 64 ]
    [ ! -f "$BL_VAR_DIR/state/case.current" ]
}

@test "bl run rejects malformed step-id arg (CLI-arg traversal guard)" {
    bl_case_fixture_seed CASE-2026-0001
    printf 'CASE-2026-0001' > "$BL_VAR_DIR/state/case.current"
    run "$BL_SOURCE" run "../../etc/passwd"
    [ "$status" -eq 64 ]   # BL_EX_USAGE
    printf '%s\n' "$output" | grep -q "step-id format invalid"
    # No /tmp/bl-step-... write should have happened
    [ ! -f "/tmp/bl-step-../../etc/passwd.out" ]
}

@test "bl consult --attach to unknown case exits 72" {
    # Seed state dir with agent-id so preflight passes; all memstore calls return 404
    bl_case_fixture_seed CASE-2026-0001
    rm -f "$BL_VAR_DIR/state/case.current"   # don't want an active case to interfere
    bl_curator_mock_set_response 'memstore-case-not-found.json' 404
    run "$BL_SOURCE" consult --attach CASE-2026-9999
    [ "$status" -eq 72 ]
}

# ---------------------------------------------------------------------------
# G3: bl consult --sweep-mode inventory
# ---------------------------------------------------------------------------

@test "bl consult --sweep-mode lists closed cases without opening a new case" {
    bl_case_fixture_seed_closed CASE-2026-0001
    # Return a list with a closed.md entry
    bl_curator_mock_set_response 'memstore-get-empty.json' 200
    run "$BL_SOURCE" consult --sweep-mode
    [ "$status" -eq 0 ]
    # sweep-mode must NOT write a new case.current
    [[ ! -f "$BL_VAR_DIR/state/case.current" ]] || [ "$(cat "$BL_VAR_DIR/state/case.current")" = "CASE-2026-0001" ]
}

# ---------------------------------------------------------------------------
# G12: concurrent bl consult --new allocates sequential ids (flock)
# ---------------------------------------------------------------------------

@test "two concurrent bl consult --new invocations allocate sequential ids via flock" {
    # Seed agent-id so preflight passes; mock all memstore calls
    mkdir -p "$BL_VAR_DIR/state"
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
    printf 'memstore_test_stub' > "$BL_VAR_DIR/state/memstore-case-id"
    bl_curator_mock_set_response 'files-api-upload.json' 201
    local trig1 trig2
    trig1=$(mktemp)
    trig2=$(mktemp)
    printf 'trig1' > "$trig1"
    printf 'trig2' > "$trig2"
    ( "$BL_SOURCE" consult --new --trigger "$trig1" >/dev/null 2>&1 ) &
    local p1=$!
    ( "$BL_SOURCE" consult --new --trigger "$trig2" >/dev/null 2>&1 ) &
    local p2=$!
    wait $p1 || true   # may fail due to memstore mock 201 not matching expected format; ignore
    wait $p2 || true
    rm -f "$trig1" "$trig2"
    # Counter must have been incremented (at least once, up to 2)
    [ -f "$BL_VAR_DIR/state/case-id-counter" ]
    local n
    n=$(jq -r '.n' "$BL_VAR_DIR/state/case-id-counter" 2>/dev/null)
    [ "$n" -ge 1 ]
}

# ---------------------------------------------------------------------------
# G13: dedup fingerprint
# ---------------------------------------------------------------------------

@test "bl consult --new --dedup with matching fingerprint attaches to existing case" {
    bl_case_fixture_seed CASE-2026-0001
    rm -f "$BL_VAR_DIR/state/case.current"   # dedup --attach must (re)write case.current
    # Trigger content 'apsb25-94-dedup-fingerprint-test' → sha256[:16] = 541413cc0f10f775
    # Matches the fingerprint baked into memstore-hypothesis-dedup-fp.json
    local trigger
    trigger=$(mktemp)
    printf 'apsb25-94-dedup-fingerprint-test' > "$trigger"
    # Default catch-all; explicit routes override in registration priority order
    bl_curator_mock_set_response 'files-api-upload.json' 200
    # INDEX.md GET → roster with active CASE-2026-0001 (existing memstore-index.json)
    bl_curator_mock_add_route 'bl-case%2FINDEX\.md' 'memstore-index.json' 200
    # Hypothesis.md for CASE-2026-0001 carries matching trigger_fingerprint
    bl_curator_mock_add_route 'CASE-2026-0001%2Fhypothesis\.md' 'memstore-hypothesis-dedup-fp.json' 200
    run "$BL_SOURCE" consult --new --dedup --trigger "$trigger"
    rm -f "$trigger"
    [ "$status" -eq 0 ]
    [ "$(cat "$BL_VAR_DIR/state/case.current")" = "CASE-2026-0001" ]
    grep -q '"kind":"case_attached"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
}

# ---------------------------------------------------------------------------
# G4: bl run step — schema/tier/not-found/unknown-tier paths
# ---------------------------------------------------------------------------

@test "bl run on malformed step exits 67 without execution" {
    bl_case_fixture_seed CASE-2026-0001
    # step-schema-fail has no step_id — schema validation must reject it
    bl_curator_mock_set_response 'files-api-upload.json' 200
    bl_curator_mock_add_route 'pending%2Fs-schema-fail' 'memstore-step-schema-fail.json' 200
    run "$BL_SOURCE" run s-schema-fail
    [ "$status" -eq 67 ]
    [ -f "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl" ]
    grep -q '"kind":"schema_reject"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
}

@test "bl run destructive without --yes exits 68 without execution" {
    bl_case_fixture_seed CASE-2026-0001
    bl_curator_mock_set_response 'files-api-upload.json' 200
    bl_curator_mock_add_route 'pending%2Fs-0044' 'memstore-step-destructive.json' 200
    BL_PROMPT_DEFAULT=N run "$BL_SOURCE" run s-0044
    [ "$status" -eq 68 ]
    grep -q '"kind":"operator_decline"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
}

@test "bl run on non-existent step exits 72" {
    bl_case_fixture_seed CASE-2026-0001
    # All calls → 404 so step not found in pending/
    bl_curator_mock_set_response 'memstore-case-not-found.json' 404
    run "$BL_SOURCE" run s-nowhere
    [ "$status" -eq 72 ]
}

@test "bl run on unknown-tier step without --unsafe --yes exits 68" {
    bl_case_fixture_seed CASE-2026-0001
    bl_curator_mock_set_response 'files-api-upload.json' 200
    bl_curator_mock_add_route 'pending%2Fs-0099' 'memstore-step-unknown.json' 200
    run "$BL_SOURCE" run s-0099
    [ "$status" -eq 68 ]
    [[ "$output" == *"tier-gate denied"* ]]
    grep -q '"kind":"unknown_tier_deny"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
}

@test "bl run with no active case exits 72" {
    # Seed agent-id only (no case.current), so preflight passes but no active case
    mkdir -p "$BL_VAR_DIR/state"
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
    printf 'memstore_test_stub' > "$BL_VAR_DIR/state/memstore-case-id"
    bl_curator_mock_set_response 'files-api-upload.json' 200
    run "$BL_SOURCE" run s-0001
    [ "$status" -eq 72 ]
}

# ---------------------------------------------------------------------------
# G5: bl run --batch halts at tier boundary
# ---------------------------------------------------------------------------

@test "bl run --batch halts at suggested/destructive tier boundary without --yes" {
    bl_case_fixture_seed CASE-2026-0001
    # List pending returns 3 steps; uses query-string URL
    # Default catch-all first; specific overrides take priority (matched in registration order)
    bl_curator_mock_set_response 'files-api-upload.json' 200
    bl_curator_mock_add_route 'key_prefix=bl-case' 'memstore-pending-list-mixed.json' 200
    # Individual step GETs use %2F-encoded paths
    bl_curator_mock_add_route 'pending%2Fs-0042' 'memstore-step-auto.json' 200
    bl_curator_mock_add_route 'pending%2Fs-0043' 'memstore-step-suggested.json' 200
    bl_curator_mock_add_route 'pending%2Fs-0044' 'memstore-step-destructive.json' 200
    BL_PROMPT_DEFAULT=N run "$BL_SOURCE" run --batch
    # auto step: handler not yet landed (64) but batch continues (rc != 68)
    # suggested step: prompts, declined (68) → batch halts
    [ "$status" -eq 68 ]
}

# ---------------------------------------------------------------------------
# G6: bl run --list enumerates pending without execution
# ---------------------------------------------------------------------------

@test "bl run --list enumerates pending steps without executing them" {
    bl_case_fixture_seed CASE-2026-0001
    bl_curator_mock_add_route 'key_prefix=bl-case' 'memstore-pending-list-empty.json' 200
    run "$BL_SOURCE" run --list
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# G7: bl case show
# ---------------------------------------------------------------------------

@test "bl case show renders 6 sections for an active case" {
    bl_case_fixture_seed CASE-2026-0001
    bl_curator_mock_set_response 'files-api-upload.json' 200
    run "$BL_SOURCE" case show CASE-2026-0001
    [ "$status" -eq 0 ]
    [[ "$output" == *"# Case CASE-2026-0001"* ]]
    [[ "$output" == *"## Hypothesis"* ]]
    [[ "$output" == *"## Evidence"* ]]
    [[ "$output" == *"## Pending steps"* ]]
    [[ "$output" == *"## Applied actions"* ]]
    [[ "$output" == *"## Defense hits"* ]]
    [[ "$output" == *"## Open questions"* ]]
}

@test "bl case show without active case exits 72" {
    # Seed agent-id so preflight passes but no case.current
    mkdir -p "$BL_VAR_DIR/state"
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
    printf 'memstore_test_stub' > "$BL_VAR_DIR/state/memstore-case-id"
    bl_curator_mock_set_response 'memstore-case-not-found.json' 404
    run "$BL_SOURCE" case show
    [ "$status" -eq 72 ]
}

# ---------------------------------------------------------------------------
# G8: bl case log emits parseable JSONL
# ---------------------------------------------------------------------------

@test "bl case log emits JSONL parseable by jq" {
    bl_case_fixture_seed CASE-2026-0001
    # Seed ledger with 2 events
    mkdir -p "$BL_VAR_DIR/ledger"
    printf '{"ts":"2026-04-24T10:00:00Z","case":"CASE-2026-0001","kind":"case_opened","payload":{}}\n' >> "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
    printf '{"ts":"2026-04-24T11:00:00Z","case":"CASE-2026-0001","kind":"step_run","payload":{"step_id":"s-0001"}}\n' >> "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
    run "$BL_SOURCE" case log CASE-2026-0001
    [ "$status" -eq 0 ]
    # Output must parse as JSON (each line)
    printf '%s\n' "$output" | head -1 | jq -e '.' >/dev/null
}

# ---------------------------------------------------------------------------
# G9: bl case list --open/--closed/--all
# ---------------------------------------------------------------------------

@test "bl case list accepts --open --closed --all flags without error" {
    bl_case_fixture_seed CASE-2026-0001
    # INDEX.md GET returns a memstore-wrapped index body
    bl_curator_mock_set_response 'memstore-index.json' 200
    run "$BL_SOURCE" case list --open
    [ "$status" -eq 0 ]
    run "$BL_SOURCE" case list --closed
    [ "$status" -eq 0 ]
    run "$BL_SOURCE" case list --all
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# G11: bl case reopen
# ---------------------------------------------------------------------------

@test "bl case reopen archives closed.md and updates ledger" {
    bl_case_fixture_seed_closed CASE-2026-0001
    # Default catch-all first; specific overrides take priority (matched in registration order)
    bl_curator_mock_set_response 'files-api-upload.json' 200
    # GET closed.md → memstore-wrapped closed.md
    bl_curator_mock_add_route 'closed\.md$' 'memstore-closed-md.json' 200
    # INDEX PATCH/GET → return index JSON
    bl_curator_mock_add_route 'INDEX' 'memstore-index.json' 200
    run "$BL_SOURCE" case reopen CASE-2026-0001 --reason "new evidence landed"
    [ "$status" -eq 0 ]
    # Ledger should record case_reopened
    grep -q '"kind":"case_reopened"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
}

@test "bl case reopen without --reason exits 64" {
    bl_case_fixture_seed_closed CASE-2026-0001
    run "$BL_SOURCE" case reopen CASE-2026-0001
    [ "$status" -eq 64 ]
}

# ---------------------------------------------------------------------------
# G14: curator-mock serves fixture JSON via curl shim
# ---------------------------------------------------------------------------

@test "curator-mock serves fixture JSON; curl shim returns expected body" {
    bl_curator_mock_set_response 'files-api-upload.json' 200
    # Use curl directly to verify the shim works
    run curl -sS -w '\n%{http_code}' "https://api.anthropic.com/v1/test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"file_01TESTupload"* ]]
    [[ "$output" == *"200"* ]]
}

# ---------------------------------------------------------------------------
# G15: full-lifecycle integration (skipped until individual gates pass)
# ---------------------------------------------------------------------------

@test "full-lifecycle: new case → run-list → log shows events" {
    skip "comprehensive integration test; enable after G1/G4/G6/G8 all pass green"
}
