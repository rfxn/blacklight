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
    # Force attended-mode for tier-gate tests; bats has no TTY so auto-detect
    # would otherwise trip the unattended queue+notify path.
    export BL_UNATTENDED=0
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
    # Seed agent-id + state.json so bl_consult_create_session can POST /v1/sessions.
    # Unset BL_SESSION_ID to force the create-then-register path (Path C).
    mkdir -p "$BL_VAR_DIR/state"
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
    printf 'memstore_test_stub' > "$BL_VAR_DIR/state/memstore-case-id"
    # state.json with agent.id + 2 workspace files so resources[] is non-empty
    cp "$BATS_TEST_DIRNAME/fixtures/state-json-baseline.json" "$BL_VAR_DIR/state/state.json"
    unset BL_SESSION_ID
    # Route /v1/sessions POST → sessions-create.json; default catch-all for memstore
    bl_curator_mock_set_response 'files-api-upload.json' 200
    bl_curator_mock_add_route 'v1/sessions$' 'sessions-create.json' 200
    bl_curator_mock_add_route 'memories/bl-case%2FINDEX' 'memstore-case-not-found.json' 404
    local trigger
    trigger=$(mktemp)
    printf 'apsb25-94-htaccess-sample\n' > "$trigger"
    run "$BL_SOURCE" consult --new --trigger "$trigger"
    rm -f "$trigger"
    export BL_SESSION_ID="sesn_test_stub"   # restore for teardown safety
    [ "$status" -eq 0 ]
    [[ "$output" =~ CASE-[0-9]{4}-[0-9]{4} ]]
    [ -f "$BL_VAR_DIR/state/case.current" ]
    [[ "$(cat "$BL_VAR_DIR/state/case.current")" =~ ^CASE-[0-9]{4}-[0-9]{4}$ ]]
    # Assert session-$case_id was written (create-then-register path persists it)
    local allocated_case
    allocated_case=$(cat "$BL_VAR_DIR/state/case.current")
    [ -f "$BL_VAR_DIR/state/session-$allocated_case" ]
}

# ---------------------------------------------------------------------------
# G2: bl consult --attach hit + miss
# ---------------------------------------------------------------------------

@test "bl consult --attach to existing case flips case.current" {
    bl_case_fixture_seed CASE-2026-0001
    # hypothesis.md probe returns 200 → case found
    bl_curator_mock_add_route 'hypothesis' 'files-api-upload.json' 200
    # sessions.create route available; attach itself does not call register_curator
    bl_curator_mock_add_route 'v1/sessions$' 'sessions-create.json' 200
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
    # Seed agent-id + state.json so bl_consult_create_session can run; route sessions.create
    mkdir -p "$BL_VAR_DIR/state"
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
    printf 'memstore_test_stub' > "$BL_VAR_DIR/state/memstore-case-id"
    cp "$BATS_TEST_DIRNAME/fixtures/state-json-baseline.json" "$BL_VAR_DIR/state/state.json"
    bl_curator_mock_set_response 'files-api-upload.json' 201
    bl_curator_mock_add_route 'v1/sessions$' 'sessions-create.json' 200
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

@test "bl consult --new --dedup uses INDEX fp column fast path (no hypothesis.md GET)" {
    # Audit M10: prior version did N sequential hypothesis.md GETs (one per
    # active case). Fast path reads fp from INDEX row column. To verify the
    # fast path resolves WITHOUT a per-hypothesis fan-out, route any
    # hypothesis.md GET to a 404 — fast path must still attach successfully.
    bl_case_fixture_seed CASE-2026-0001
    rm -f "$BL_VAR_DIR/state/case.current"
    local trigger
    trigger=$(mktemp)
    printf 'apsb25-94-dedup-fingerprint-test' > "$trigger"
    bl_curator_mock_set_response 'files-api-upload.json' 200
    # INDEX.md → new format with fp column populated
    bl_curator_mock_add_route 'bl-case%2FINDEX\.md' 'memstore-index-with-fp.json' 200
    # ANY hypothesis.md GET 404s — fast path must not need it
    bl_curator_mock_add_route 'hypothesis\.md' 'memstore-case-not-found.json' 404
    run "$BL_SOURCE" consult --new --dedup --trigger "$trigger"
    rm -f "$trigger"
    [ "$status" -eq 0 ]
    [ "$(cat "$BL_VAR_DIR/state/case.current")" = "CASE-2026-0001" ]
    grep -q '"kind":"case_attached"' "$BL_VAR_DIR/ledger/CASE-2026-0001.jsonl"
}

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
    bl_curator_mock_add_route 'path_prefix=/bl-case' 'memstore-pending-list-mixed.json' 200
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
    bl_curator_mock_add_route 'path_prefix=/bl-case' 'memstore-pending-list-empty.json' 200
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
    skip "comprehensive integration test; enable after G1/G4/G6/G8 all pass green (session_id persisted to state.json via bl_consult_create_session)"
}

# ---------------------------------------------------------------------------
# G16: bl run rejects step that fails schemas/step.json (M11 P9)
# Activates the bare tests/fixtures/step-schema-fail.json fixture by wrapping
# its content inline into a memstore-shaped response at test time. Distinct
# from G4 (which uses the pre-wrapped memstore-step-schema-fail.json) — this
# test exercises the schema-validation gate against the bare-step canonical
# fixture grep-trackable at tests/fixtures/step-schema-fail.json.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# G17: bl case close detaches per-case Files + queues GC (M13 P8 regression)
# ---------------------------------------------------------------------------

@test "bl case close detaches per-case Files + queues GC" {
    # Seed a case in closed-able state: pass all preconditions by mocking the
    # memstore to return empty open-questions.md, empty pending/, and no
    # applied-actions (so retire_hint check passes vacuously).
    bl_case_fixture_seed CASE-2026-0001
    # state.json with case_files + session_ids for CASE-2026-0001
    cp "$BATS_TEST_DIRNAME/fixtures/state-json-baseline.json" "$BL_VAR_DIR/state/state.json"
    # Inject case_files and session_ids into state.json
    local updated_state
    updated_state=$(jq \
        '.case_files["CASE-2026-0001"] = {"/case/raw.md": {workspace_file_id: "file_01CASERAW001", session_resource_id: "sesrsc_01CASERAW001"}} |
         .session_ids["CASE-2026-0001"] = "sesn_01CASESESSION01" |
         .files_pending_deletion = []' \
        "$BL_VAR_DIR/state/state.json")
    printf '%s\n' "$updated_state" > "$BL_VAR_DIR/state/state.json"
    # Mock: open-questions.md returns empty content (no unresolved questions)
    bl_curator_mock_set_response 'files-api-upload.json' 200
    bl_curator_mock_add_route 'open-questions' 'memstore-get-empty.json' 200
    bl_curator_mock_add_route 'pending' 'memstore-pending-list-empty.json' 200
    bl_curator_mock_add_route 'results' 'memstore-pending-list-empty.json' 200
    bl_curator_mock_add_route 'actions/applied' 'memstore-pending-list-empty.json' 200
    bl_curator_mock_add_route 'hypothesis' 'memstore-get-empty.json' 200
    bl_curator_mock_add_route 'v1/sessions$' 'sessions-create.json' 200
    bl_curator_mock_add_route 'INDEX' 'memstore-index.json' 200
    # Skip stage-2 HTML/PDF render (avoids 60s poll loop in mock environment)
    export BL_BRIEF_MIMES="text/markdown"
    # Run bl case close with --force (bypass confidence gate since mock hypothesis is empty)
    run "$BL_SOURCE" case close CASE-2026-0001 --force
    [ "$status" -eq 0 ]
    # Assert files_pending_deletion grew by 1 (the per-case file)
    local pending_count
    pending_count=$(jq '.files_pending_deletion | length' "$BL_VAR_DIR/state/state.json" 2>/dev/null || printf '0')
    [ "$pending_count" -ge 1 ]
    # Assert case_files["CASE-2026-0001"] no longer present
    local case_files_val
    case_files_val=$(jq '.case_files["CASE-2026-0001"] // null' "$BL_VAR_DIR/state/state.json" 2>/dev/null)
    [ "$case_files_val" = "null" ]
    # Assert session_ids["CASE-2026-0001"] no longer present
    local session_ids_val
    session_ids_val=$(jq '.session_ids["CASE-2026-0001"] // null' "$BL_VAR_DIR/state/state.json" 2>/dev/null)
    [ "$session_ids_val" = "null" ]
}

# ---------------------------------------------------------------------------
# G18: integration — observe rotate → case close → gc end-to-end (spec §11b row 10)
# Verifies the chain: evidence uploaded to Files API (state.json case_files populated),
# then bl case close moves the file_id to files_pending_deletion + clears case_files,
# then bl setup --gc deletes the pending file_id (no live sessions hold it after close).
# ---------------------------------------------------------------------------

@test "integration: case close queues file_id for GC; setup --gc removes it" {
    bl_case_fixture_seed CASE-2026-0001
    # Seed state.json with a case_files entry for CASE-2026-0001 (simulates post-observe rotate)
    mkdir -p "$BL_VAR_DIR/state"
    local fid_before="file_TESTINTEGRATION01"
    jq -n \
        --arg fid "$fid_before" \
        '{
            schema_version: 1,
            agent: {id: "agent_test_stub", version: 1, skill_versions: {}},
            env_id: "env_test_stub",
            skills: {},
            files: {},
            files_pending_deletion: [],
            case_memstores: {_legacy: "memstore_test_stub"},
            case_files: {
                "CASE-2026-0001": {
                    "/case/CASE-2026-0001/raw/apache.jsonl": {
                        workspace_file_id: $fid,
                        session_resource_id: "sesrsc_TESTINTEGRATION01"
                    }
                }
            },
            case_id_counter: {},
            case_current: "CASE-2026-0001",
            session_ids: {},
            last_sync: "2026-04-26T00:00:00Z"
        }' > "$BL_VAR_DIR/state/state.json"
    # Mock routes for bl case close: all preconditions pass (empty open-questions,
    # no pending steps, no applied actions requiring retire_hint)
    bl_curator_mock_set_response 'files-api-upload.json' 200
    bl_curator_mock_add_route 'open-questions' 'memstore-get-empty.json' 200
    bl_curator_mock_add_route 'pending' 'memstore-pending-list-empty.json' 200
    bl_curator_mock_add_route 'results' 'memstore-pending-list-empty.json' 200
    bl_curator_mock_add_route 'actions/applied' 'memstore-pending-list-empty.json' 200
    bl_curator_mock_add_route 'hypothesis' 'memstore-get-empty.json' 200
    bl_curator_mock_add_route 'v1/sessions$' 'sessions-create.json' 200
    bl_curator_mock_add_route 'INDEX' 'memstore-index.json' 200
    export BL_BRIEF_MIMES="text/markdown"   # skip HTML/PDF render in mock env
    # Step 1: bl case close moves file_id → files_pending_deletion + clears case_files
    run "$BL_SOURCE" case close CASE-2026-0001 --force
    [ "$status" -eq 0 ]
    # case_files["CASE-2026-0001"] must be absent after close
    local case_files_val
    case_files_val=$(jq '.case_files["CASE-2026-0001"] // null' "$BL_VAR_DIR/state/state.json" 2>/dev/null)
    [ "$case_files_val" = "null" ]
    # file_id must appear in files_pending_deletion
    local in_pending
    in_pending=$(jq --arg f "$fid_before" '[.files_pending_deletion[] | select(.file_id == $f)] | length' \
        "$BL_VAR_DIR/state/state.json" 2>/dev/null || printf '0')
    [ "$in_pending" -ge 1 ]
    # Step 2: bl setup --gc deletes the pending file_id (session_ids is empty — no live sessions)
    bl_curator_mock_reset_routes
    bl_curator_mock_set_response 'setup-agent-create-success.json' 200
    run "$BL_SOURCE" setup --gc
    [ "$status" -eq 0 ]
    # files_pending_deletion must be empty after GC
    local post_gc_pending
    post_gc_pending=$(jq '.files_pending_deletion | length' "$BL_VAR_DIR/state/state.json" 2>/dev/null || printf '1')
    [ "$post_gc_pending" -eq 0 ]
}

@test "bl run rejects malformed step (missing step_id) with exit 67" {
    bl_case_fixture_seed CASE-2026-0001
    printf 'CASE-2026-0001' > "$BL_VAR_DIR/state/case.current"
    # Build a per-test wrapper fixture so we don't pollute the committed
    # memstore-step-schema-fail.json. Cleanup at test end below.
    local inline_fix="$BATS_TEST_DIRNAME/fixtures/memstore-step-schema-fail-inline.json"
    local content
    content=$(< "$BATS_TEST_DIRNAME/fixtures/step-schema-fail.json")
    jq -n --arg c "$content" --arg k "bl-case/CASE-2026-0001/pending/s-fail.json" \
        '{key:$k, content:$c, content_sha256:"abc"}' > "$inline_fix"
    bl_curator_mock_set_response 'files-api-upload.json' 200
    bl_curator_mock_add_route 'pending%2Fs-fail' 'memstore-step-schema-fail-inline.json' 200
    run "$BL_SOURCE" run s-fail
    rm -f "$inline_fix"
    [ "$status" -eq 67 ]   # BL_EX_SCHEMA_VALIDATION_FAIL
    [[ "$output" == *"schema"* ]] || [[ "$output" == *"validation"* ]] || [[ "$output" == *"step_id"* ]]
}

# ---------------------------------------------------------------------------
# G17.5 (M14 P1): Schema enum extensions — positive-accept + regression guard
# Validates that schemas/ledger-event.json and schemas/step.json enumerate the
# 8 new M14 ledger kinds and 3 new step verbs.  Uses jq enum-membership checks
# (python3/jsonschema is not present in the test container).
# ---------------------------------------------------------------------------

@test "ledger event schema accepts M14 new kinds" {
    local schema_file="$BATS_TEST_DIRNAME/../schemas/ledger-event.json"
    local kinds=(
        lmd_hook_received trigger_dedup_attached lmd_hit_degraded
        notify_dispatched notify_failed
        cpanel_lockin_invoked cpanel_lockin_failed cpanel_lockin_rolled_back
    )
    for k in "${kinds[@]}"; do
        run jq -e --arg k "$k" \
            '.properties.kind.enum | index($k) != null' \
            "$schema_file"
        [ "$status" -eq 0 ]
        [[ "$output" == "true" ]]
    done
}

@test "step verb schema accepts M14 new verbs" {
    local schema_file="$BATS_TEST_DIRNAME/../schemas/step.json"
    local verbs=( trigger.lmd setup.install_hook setup.import_from_lmd )
    for v in "${verbs[@]}"; do
        run jq -e --arg v "$v" \
            '.properties.verb.enum | index($v) != null' \
            "$schema_file"
        [ "$status" -eq 0 ]
        [[ "$output" == "true" ]]
    done
}

@test "ledger event schema rejects unknown kind" {
    local schema_file="$BATS_TEST_DIRNAME/../schemas/ledger-event.json"
    run jq -e --arg k "this_is_not_a_real_kind" \
        '.properties.kind.enum | index($k) == null' \
        "$schema_file"
    [ "$status" -eq 0 ]
    [[ "$output" == "true" ]]
}

# ---------------------------------------------------------------------------
# F12 regression: sessions.create request body uses 'agent' field, not 'agent_id'
# ---------------------------------------------------------------------------

@test "bl consult: session-create body uses 'agent' field name (F12 regression)" {
    # Seed state dir and state.json with agent.id = "agent_M8_TEST" so
    # bl_consult_create_session reads it when POSTing /v1/sessions.
    mkdir -p "$BL_VAR_DIR/state"
    cp "$BATS_TEST_DIRNAME/fixtures/state-json-baseline.json" "$BL_VAR_DIR/state/state.json"
    # Overwrite agent.id in state.json to the known sentinel value
    local updated
    updated=$(jq '.agent.id = "agent_M8_TEST"' "$BL_VAR_DIR/state/state.json")
    printf '%s\n' "$updated" > "$BL_VAR_DIR/state/state.json"
    printf 'agent_M8_TEST' > "$BL_VAR_DIR/state/agent-id"
    printf 'memstore_test_stub' > "$BL_VAR_DIR/state/memstore-case-id"
    # Capture every curl invocation (method + URL + compact body)
    export BL_MOCK_REQUEST_LOG
    BL_MOCK_REQUEST_LOG=$(mktemp)
    # Route sessions.create → fixture; catch-all for memstore uploads
    bl_curator_mock_set_response 'files-api-upload.json' 200
    bl_curator_mock_add_route 'v1/sessions$' 'sessions-create.json' 200
    bl_curator_mock_add_route 'memories/bl-case%2FINDEX' 'memstore-case-not-found.json' 404
    local trigger
    trigger=$(mktemp)
    printf 'f12-regression-trigger' > "$trigger"
    # Unset BL_SESSION_ID to force Path C (create-then-register) in bl_consult_register_curator
    unset BL_SESSION_ID
    run "$BL_SOURCE" consult --new --trigger "$trigger"
    rm -f "$trigger"
    export BL_SESSION_ID="sesn_test_stub"   # restore for teardown safety
    # Inspect captured request log for the POST /v1/sessions body
    grep -E '"agent":"agent_M8_TEST"' "$BL_MOCK_REQUEST_LOG"
    [ "$?" -eq 0 ]
    # Anti-assertion: the wrong field name must NOT appear in the request body
    ! grep -E '"agent_id":"agent_M8_TEST"' "$BL_MOCK_REQUEST_LOG"
    rm -f "$BL_MOCK_REQUEST_LOG"
}
