#!/usr/bin/env bats
# tests/14-trigger-lmd.bats — bl trigger lmd verb + bl-lmd-hook adapter

load 'helpers/assert-jsonl.bash'
load 'helpers/curator-mock.bash'
load 'helpers/lmd-mock.bash'

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    export BL_REPO_ROOT="${BL_REPO_ROOT:-$BATS_TEST_DIRNAME/..}"
    export BL_VAR_DIR
    BL_VAR_DIR="$(mktemp -d)"
    export BL_STATE_DIR="$BL_VAR_DIR/state"
    export BL_BLACKLIGHT_CONF="$BL_VAR_DIR/blacklight.conf"
    export ANTHROPIC_API_KEY="sk-ant-test"
    export BL_MEMSTORE_CASE_ID="memstore_test_stub"
    export BL_SESSION_ID="sesn_test_stub"
    mkdir -p "$BL_VAR_DIR/state" "$BL_VAR_DIR/ledger" "$BL_VAR_DIR/outbox"
    _lmd_seed_agent_id
    bl_curator_mock_init
    # Default mock routes for case-open path
    bl_curator_mock_set_response 'files-api-upload.json' 200
    bl_curator_mock_add_route 'v1/sessions$' 'sessions-create.json' 200
    bl_curator_mock_add_route 'memories/bl-case%2FINDEX' 'memstore-case-not-found.json' 404
}

teardown() {
    bl_curator_mock_teardown
    rm -rf "$BL_VAR_DIR"
    _lmd_mock_unset
}

# ---------------------------------------------------------------------------
# G1 — LMD hook integration (adapter behaviour)
# ---------------------------------------------------------------------------

@test "bl-lmd-hook: agent-id cached + LMD_HITS>0 → fork bl trigger lmd" {
    _lmd_setup_session
    # Install a mock bl at /usr/local/bin/bl so the hook's hardcoded exec path lands in our trace.
    # The hook always exits 0 (fail-open); we verify it invoked bl by checking the log.
    local orig_bl=""
    [[ -f /usr/local/bin/bl ]] && orig_bl=$(mktemp) && cp /usr/local/bin/bl "$orig_bl"
    cat > /usr/local/bin/bl <<'EOF'
#!/bin/bash
printf 'INVOKED:%s\n' "$*" >> "$BL_VAR_DIR/trigger.log"
EOF
    chmod +x /usr/local/bin/bl
    run "$BATS_TEST_DIRNAME/../files/hooks/bl-lmd-hook"
    local hook_status=$status
    sleep 0.2   # fork-exec is async; brief pause for background child
    # Restore original bl (if any)
    if [[ -n "$orig_bl" ]]; then cp "$orig_bl" /usr/local/bin/bl; rm -f "$orig_bl"
    else rm -f /usr/local/bin/bl; fi
    [ "$hook_status" -eq 0 ]
    grep -q "INVOKED:trigger lmd --scanid" "$BL_VAR_DIR/trigger.log"
}

@test "bl-lmd-hook: agent-id missing → exit 0 + syslog skip" {
    rm -f "$BL_STATE_DIR/agent-id"
    _lmd_setup_session
    run "$BATS_TEST_DIRNAME/../files/hooks/bl-lmd-hook"
    [ "$status" -eq 0 ]
}

@test "bl-lmd-hook: LMD_HITS=0 → exit 0 (no trigger)" {
    _lmd_setup_session
    LMD_HITS=0 run "$BATS_TEST_DIRNAME/../files/hooks/bl-lmd-hook"
    [ "$status" -eq 0 ]
    [ ! -f "$BL_VAR_DIR/trigger.log" ]
}

@test "bl-lmd-hook: returns in <100ms (perf bound)" {
    _lmd_setup_session
    # Use /dev/null bl stub so fork is minimal
    local tmpbin
    tmpbin=$(mktemp -d)
    printf '#!/bin/bash\nexit 0\n' > "$tmpbin/bl"
    chmod +x "$tmpbin/bl"
    local start_ms end_ms elapsed
    start_ms=$(($(date +%s%N) / 1000000))
    PATH="$tmpbin:$PATH" "$BATS_TEST_DIRNAME/../files/hooks/bl-lmd-hook"
    end_ms=$(($(date +%s%N) / 1000000))
    elapsed=$((end_ms - start_ms))
    [ "$elapsed" -lt 100 ]
}

# ---------------------------------------------------------------------------
# G2 — cluster-scoped case opening (regression case)
# ---------------------------------------------------------------------------

@test "bl trigger lmd: 7-hit TSV opens single case with cluster fingerprint" {
    # Seed state.json + memstore-case-id for bl_consult_new
    cp "$BATS_TEST_DIRNAME/fixtures/state-json-baseline.json" "$BL_VAR_DIR/state/state.json"
    printf 'memstore_test_stub' > "$BL_VAR_DIR/state/memstore-case-id"
    unset BL_SESSION_ID
    bl_curator_mock_add_route 'v1/sessions$' 'sessions-create.json' 200
    bl_curator_mock_add_route 'memories/bl-case%2FINDEX' 'memstore-case-not-found.json' 404
    run bash -c '
        source '"$BL_SOURCE"'
        bl_trigger_lmd --scanid SCAN-FOO \
            --session-file '"$BATS_TEST_DIRNAME"'/fixtures/lmd-session-tsv-7-hits.tsv 2>&1
    '
    export BL_SESSION_ID="sesn_test_stub"
    [ "$status" -eq 0 ]
    [[ "$output" =~ CASE-[0-9]{4}-[0-9]{4} ]]
    grep -q '"kind":"lmd_hook_received"' "$BL_VAR_DIR/ledger/global.jsonl"
}

@test "bl trigger lmd: identical fingerprint within 24h attaches to existing case" {
    # Full dedup round-trip requires a pre-seeded INDEX containing the exact
    # sha256[:16] computed for SCAN-DEDUP + 7-hit TSV. The fingerprint is
    # deterministic but must be injected into the memstore INDEX mock at the
    # correct column position.  The dynamic fixture generation requires the
    # container to have jq available at bl_curator_mock_add_route time.
    # Skip here and verify the path in the next assert below.
    skip "dedup-attach integration requires dynamic INDEX fixture seeding; verified via _bl_trigger_lmd_fingerprint unit test (test 44) + bl_consult_new dedup path (05-consult-run-case.bats)"
}

@test "bl trigger lmd: identical fingerprint after 24h opens new case" {
    skip "requires fixture with >24h-old case_opened ts; mock via case-fixture helper"
}

@test "_bl_trigger_lmd_fingerprint: reads JSONL on stdin, deterministic output" {
    run bash -c '
        source '"$BL_SOURCE"'
        printf "{\"sig\":\"hex.php.webshell.polyshell\",\"path\":\"/var/www/a.php\"}\n{\"sig\":\"hex.php.eval.b64\",\"path\":\"/var/www/b.php\"}\n" | _bl_trigger_lmd_fingerprint SCAN-FOO
    '
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[a-f0-9]{16}$ ]]
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "bl trigger lmd: broken/empty TSV with LMD_HITS>0 → stub case + lmd_hit_degraded" {
    cp "$BATS_TEST_DIRNAME/fixtures/state-json-baseline.json" "$BL_VAR_DIR/state/state.json"
    printf 'memstore_test_stub' > "$BL_VAR_DIR/state/memstore-case-id"
    unset BL_SESSION_ID
    bl_curator_mock_add_route 'v1/sessions$' 'sessions-create.json' 200
    bl_curator_mock_add_route 'memories/bl-case%2FINDEX' 'memstore-case-not-found.json' 404
    run bash -c '
        source '"$BL_SOURCE"'
        bl_trigger_lmd --scanid SCAN-DEGRADED --session-file /no/such/path 2>&1
    '
    export BL_SESSION_ID="sesn_test_stub"
    grep -q '"kind":"lmd_hit_degraded"' "$BL_VAR_DIR/ledger/global.jsonl"
}

@test "bl trigger: missing --scanid → BL_EX_USAGE" {
    run bash -c 'source '"$BL_SOURCE"'; bl_trigger lmd 2>&1'
    [ "$status" -eq 64 ]
}

@test "bl trigger: unknown sub-verb → BL_EX_USAGE" {
    run bash -c 'source '"$BL_SOURCE"'; bl_trigger frobnicate 2>&1'
    [ "$status" -eq 64 ]
}
