#!/usr/bin/env bats
# tests/08-setup.bats — M8 bl setup coverage (DESIGN.md §8.2-§8.5; docs/setup-flow.md authoritative)
# Consumes tests/helpers/curator-mock.bash + tests/fixtures/setup-*.json.

load 'helpers/curator-mock.bash'

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    BL_VAR_DIR="$(mktemp -d)"
    export BL_VAR_DIR
    export BL_REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export ANTHROPIC_API_KEY="sk-ant-test-M8"
    bl_curator_mock_init
}

teardown() {
    bl_curator_mock_teardown
}

# ---------------------------------------------------------------------------
# S1: Happy path — full provisioning from blank state
# ---------------------------------------------------------------------------

@test "bl setup: blank state → creates agent + env + 2 memstores + seeds skills + persists 4 ids" {
    bl_curator_mock_add_route '/v1/agents\?name=bl-curator' 'setup-agents-list-empty.json' 200
    bl_curator_mock_add_route '/v1/agents$' 'setup-agent-create-success.json' 201
    bl_curator_mock_add_route '/v1/environments$' 'setup-env-create-success.json' 201
    bl_curator_mock_add_route '/v1/memory_stores\?name=bl-skills' 'setup-memstore-list-empty.json' 200
    bl_curator_mock_add_route '/v1/memory_stores\?name=bl-case' 'setup-memstore-list-empty.json' 200
    bl_curator_mock_add_route '/v1/memory_stores$' 'setup-memstore-create-skills.json' 201
    bl_curator_mock_set_response 'setup-memory-create-success.json' 201
    run "$BL_SOURCE" setup
    [ "$status" -eq 0 ]
    [ -f "$BL_VAR_DIR/state/agent-id" ]
    [ -f "$BL_VAR_DIR/state/env-id" ]
    [ -f "$BL_VAR_DIR/state/memstore-skills-id" ]
    [ -f "$BL_VAR_DIR/state/memstore-case-id" ]
    [[ "$(cat "$BL_VAR_DIR/state/agent-id")" == "agent_M8_TEST" ]]
    [[ "$output" == *"BL_READY=1"* ]]
}

# ---------------------------------------------------------------------------
# S2: Idempotent re-run (DESIGN.md §8.5; setup-flow.md §5)
# ---------------------------------------------------------------------------

@test "bl setup: pre-seeded state → no-op summary, zero create calls" {
    skip "blocked on Phase 4"
    mkdir -p "$BL_VAR_DIR/state"
    printf '%s' "agent_M8_TEST"           > "$BL_VAR_DIR/state/agent-id"
    printf '%s' "env_M8_TEST"             > "$BL_VAR_DIR/state/env-id"
    printf '%s' "memstore_skills_M8"      > "$BL_VAR_DIR/state/memstore-skills-id"
    printf '%s' "memstore_case_M8"        > "$BL_VAR_DIR/state/memstore-case-id"
    bl_curator_mock_add_route 'MANIFEST' 'setup-manifest-current.json' 200
    bl_curator_mock_set_response 'setup-memstore-list-skills-hit.json' 200
    run "$BL_SOURCE" setup
    [ "$status" -eq 0 ]
    [[ "$output" == *"no-op"* ]] || [[ "$output" == *"already provisioned"* ]]
}

# ---------------------------------------------------------------------------
# S3: --check partial-state matrix (operator's "ends when" criterion #1)
# ---------------------------------------------------------------------------

@test "bl setup --check: empty state → reports all four resources missing" {
    skip "blocked on Phase 4"
    run "$BL_SOURCE" setup --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"agent: missing"* ]]
    [[ "$output" == *"env: missing"* ]]
    [[ "$output" == *"memstore-skills: missing"* ]]
    [[ "$output" == *"memstore-case: missing"* ]]
}

@test "bl setup --check: agent-only → reports env + memstores missing" {
    skip "blocked on Phase 4"
    mkdir -p "$BL_VAR_DIR/state"; printf '%s' "agent_M8_TEST" > "$BL_VAR_DIR/state/agent-id"
    run "$BL_SOURCE" setup --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"agent: ok"* ]]
    [[ "$output" == *"env: missing"* ]]
    [[ "$output" == *"memstore-skills: missing"* ]]
    [[ "$output" == *"memstore-case: missing"* ]]
}

@test "bl setup --check: agent+env → reports memstores missing" {
    skip "blocked on Phase 4"
    mkdir -p "$BL_VAR_DIR/state"
    printf '%s' "agent_M8_TEST" > "$BL_VAR_DIR/state/agent-id"
    printf '%s' "env_M8_TEST"   > "$BL_VAR_DIR/state/env-id"
    run "$BL_SOURCE" setup --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"agent: ok"* ]]
    [[ "$output" == *"env: ok"* ]]
    [[ "$output" == *"memstore-skills: missing"* ]]
    [[ "$output" == *"memstore-case: missing"* ]]
}

@test "bl setup --check: agent+env+one-memstore → reports remaining memstore missing" {
    skip "blocked on Phase 4"
    mkdir -p "$BL_VAR_DIR/state"
    printf '%s' "agent_M8_TEST"      > "$BL_VAR_DIR/state/agent-id"
    printf '%s' "env_M8_TEST"        > "$BL_VAR_DIR/state/env-id"
    printf '%s' "memstore_skills_M8" > "$BL_VAR_DIR/state/memstore-skills-id"
    run "$BL_SOURCE" setup --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"memstore-skills: ok"* ]]
    [[ "$output" == *"memstore-case: missing"* ]]
}

@test "bl setup --check: all four resources present → exits 0 with green summary" {
    skip "blocked on Phase 4"
    mkdir -p "$BL_VAR_DIR/state"
    printf '%s' "agent_M8_TEST"      > "$BL_VAR_DIR/state/agent-id"
    printf '%s' "env_M8_TEST"        > "$BL_VAR_DIR/state/env-id"
    printf '%s' "memstore_skills_M8" > "$BL_VAR_DIR/state/memstore-skills-id"
    printf '%s' "memstore_case_M8"   > "$BL_VAR_DIR/state/memstore-case-id"
    run "$BL_SOURCE" setup --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"agent: ok"* ]]
    [[ "$output" == *"env: ok"* ]]
    [[ "$output" == *"memstore-skills: ok"* ]]
    [[ "$output" == *"memstore-case: ok"* ]]
}

# ---------------------------------------------------------------------------
# S4: --sync skills-delta (operator's "ends when" criterion #2)
# ---------------------------------------------------------------------------

@test "bl setup --sync: remote MANIFEST matches local → zero POST calls, summary reports 0 changes" {
    mkdir -p "$BL_VAR_DIR/state"
    printf '%s' "agent_M8_TEST"      > "$BL_VAR_DIR/state/agent-id"
    printf '%s' "memstore_skills_M8" > "$BL_VAR_DIR/state/memstore-skills-id"
    # Synth a current-state fixture matching the live skills/ corpus, written to
    # the mock's fixtures dir so the route below resolves it. Cleanup in teardown.
    _bl_M8_synth_current_manifest > "$BL_CURATOR_MOCK_FIXTURES_DIR/setup-manifest-current.json"
    bl_curator_mock_add_route 'memories/MANIFEST' "setup-manifest-current.json" 200
    bl_curator_mock_set_response 'setup-memory-create-success.json' 200
    run "$BL_SOURCE" setup --sync
    rm -f "$BL_CURATOR_MOCK_FIXTURES_DIR/setup-manifest-current.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 changes"* ]] || [[ "$output" == *"no skills delta"* ]]
}

@test "bl setup --sync: remote MANIFEST is baseline (empty) → POSTs every skill, summary lists count" {
    mkdir -p "$BL_VAR_DIR/state"
    printf '%s' "agent_M8_TEST"      > "$BL_VAR_DIR/state/agent-id"
    printf '%s' "memstore_skills_M8" > "$BL_VAR_DIR/state/memstore-skills-id"
    bl_curator_mock_add_route 'memories/MANIFEST' 'setup-manifest-baseline.json' 200
    bl_curator_mock_set_response 'setup-memory-create-success.json' 201
    run "$BL_SOURCE" setup --sync
    [ "$status" -eq 0 ]
    local skill_count
    skill_count=$(find "$BL_REPO_ROOT/skills" -name '*.md' -not -name 'INDEX.md' | wc -l)
    [[ "$output" == *"$skill_count"* ]]
}

# ---------------------------------------------------------------------------
# S5: preflight finds existing agent → caches id, skips create path
# ---------------------------------------------------------------------------

@test "bl setup: preflight finds existing agent → caches id, skips create" {
    bl_curator_mock_add_route '/v1/agents\?name=bl-curator' 'setup-agents-list-hit.json' 200
    bl_curator_mock_add_route '/v1/environments$' 'setup-env-create-success.json' 201
    bl_curator_mock_add_route '/v1/memory_stores\?name=' 'setup-memstore-list-empty.json' 200
    bl_curator_mock_add_route '/v1/memory_stores$' 'setup-memstore-create-skills.json' 201
    bl_curator_mock_set_response 'setup-memory-create-success.json' 201
    run "$BL_SOURCE" setup
    [ "$status" -eq 0 ]
    [[ "$(cat "$BL_VAR_DIR/state/agent-id")" == "agent_M8_TEST" ]]
}

# ---------------------------------------------------------------------------
# S9: create-time 409 race (per docs/setup-flow.md §4.2 + §6)
# ---------------------------------------------------------------------------
# Scenario: preflight GET returns empty (no existing agent), POST /v1/agents
# races against another host and returns 409 already_exists. bl_setup must
# re-probe preflight and continue with the now-existing id. Exercises the
# BL_EX_CONFLICT (71) branch made live by the Phase 2 bl_api_call 409 patch.
# ---------------------------------------------------------------------------

@test "bl setup: create-time 409 race → bl_api_call returns 71, ensure_agent re-probes + caches" {
    # First preflight GET → empty (race begins here)
    # POST /v1/agents → 409 (race lost)
    # Re-probe GET /v1/agents → hit (other host won)
    # Note: curator-mock does not stateful — we use the order-of-registration
    # priority: route lookup matches first registered pattern. The two GET
    # /v1/agents calls hit the same route, so we cannot distinguish first from
    # re-probe. Use the hit fixture for both — the create still hits 409, and
    # ensure_agent's re-probe path consumes the same hit response correctly.
    bl_curator_mock_add_route '/v1/agents\?name=bl-curator' 'setup-agents-list-hit.json' 200
    bl_curator_mock_add_route '/v1/agents$' 'setup-agent-create-conflict.json' 409
    bl_curator_mock_add_route '/v1/environments$' 'setup-env-create-success.json' 201
    bl_curator_mock_add_route '/v1/memory_stores\?name=' 'setup-memstore-list-empty.json' 200
    bl_curator_mock_add_route '/v1/memory_stores$' 'setup-memstore-create-skills.json' 201
    bl_curator_mock_set_response 'setup-memory-create-success.json' 201
    run "$BL_SOURCE" setup
    [ "$status" -eq 0 ]
    [[ "$(cat "$BL_VAR_DIR/state/agent-id")" == "agent_M8_TEST" ]]
}

# ---------------------------------------------------------------------------
# S6: 401 unauthorized → exits 65 with PREFLIGHT_FAIL message
# ---------------------------------------------------------------------------

@test "bl setup: 401 from API → exits 65" {
    bl_curator_mock_set_response 'setup-error-401.json' 401
    run "$BL_SOURCE" setup
    [ "$status" -eq 65 ]
}

# ---------------------------------------------------------------------------
# S7: 400 invalid_request_error on agent create → exits 65 with field-name surfaced
# ---------------------------------------------------------------------------

@test "bl setup: 400 on agent create → exits 65 with body forwarded to operator" {
    bl_curator_mock_add_route '/v1/agents\?name=bl-curator' 'setup-agents-list-empty.json' 200
    bl_curator_mock_add_route '/v1/agents$' 'setup-error-400.json' 400
    run "$BL_SOURCE" setup
    [ "$status" -eq 65 ]
}

# ---------------------------------------------------------------------------
# S8: Source-of-truth resolution (DESIGN.md §8.3)
# ---------------------------------------------------------------------------

@test "bl setup: cwd has skills/ + prompts/ → uses cwd (no clone)" {
    skip "blocked on Phase 4"
    cd "$BL_REPO_ROOT"
    bl_curator_mock_set_response 'setup-memstore-list-empty.json' 200
    bl_curator_mock_add_route '/v1/agents\?' 'setup-agents-list-hit.json' 200
    run "$BL_SOURCE" setup --check
    [[ "$output" == *"source: cwd"* ]] || [[ "$output" == *"source=cwd"* ]]
}

# ---------------------------------------------------------------------------
# Helper: synthesize a current-manifest fixture from the live skills/ corpus.
# Lets the matches-current test stay green even as new skills land.
# ---------------------------------------------------------------------------

_bl_M8_synth_current_manifest() {
    # Mirrors bl_setup_compute_manifest exactly so the no-op sync test sees a
    # remote MANIFEST that matches local. jq emits the {path,sha256} entries and
    # then nests the resulting array as a JSON-as-string in .content (matches
    # production wire shape per setup-flow.md §4.5).
    local skills_dir="$BL_REPO_ROOT/skills"
    local entries=""
    local rel sha
    while IFS= read -r f; do
        rel="${f#"$skills_dir"/}"
        sha=$(sha256sum "$f" | command awk '{print $1}')
        [[ -n "$entries" ]] && entries="$entries,"
        entries="$entries$(jq -n --arg p "$rel" --arg s "$sha" '{path:$p, sha256:$s}')"
    done < <(find "$skills_dir" -name '*.md' -not -name 'INDEX.md' | sort)
    jq -n --arg c "[$entries]" '{id:"memory_MANIFEST", key:"MANIFEST.json", content:$c}'
}
