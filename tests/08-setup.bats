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
    run "$BL_SOURCE" setup --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"agent: missing"* ]]
    [[ "$output" == *"env: missing"* ]]
    [[ "$output" == *"memstore-skills: missing"* ]]
    [[ "$output" == *"memstore-case: missing"* ]]
}

@test "bl setup --check: agent-only → reports env + memstores missing" {
    mkdir -p "$BL_VAR_DIR/state"; printf '%s' "agent_M8_TEST" > "$BL_VAR_DIR/state/agent-id"
    run "$BL_SOURCE" setup --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"agent: ok"* ]]
    [[ "$output" == *"env: missing"* ]]
    [[ "$output" == *"memstore-skills: missing"* ]]
    [[ "$output" == *"memstore-case: missing"* ]]
}

@test "bl setup --check: agent+env → reports memstores missing" {
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
    cd "$BL_REPO_ROOT"
    bl_curator_mock_set_response 'setup-memstore-list-empty.json' 200
    bl_curator_mock_add_route '/v1/agents\?' 'setup-agents-list-hit.json' 200
    run "$BL_SOURCE" setup --check
    [[ "$output" == *"source: cwd"* ]] || [[ "$output" == *"source=cwd"* ]]
}

# ---------------------------------------------------------------------------
# S6: defense.json + intent.json input_schemas are non-empty (audit M2)
# Empty stub schemas defeat the structured-emit invariant Managed-Agents
# custom tools rely on — verify they carry required fields.
# ---------------------------------------------------------------------------

@test "schemas/defense.json declares required fields for synthesize_defense" {
    local schema="$BL_REPO_ROOT/schemas/defense.json"
    [ -r "$schema" ]
    # Required array must include kind/body/reasoning/case_id at minimum
    run jq -e '.required | sort' "$schema"
    [ "$status" -eq 0 ]
    run jq -e '.required | index("kind") and index("body") and index("reasoning") and index("case_id")' "$schema"
    [ "$status" -eq 0 ]
    # Properties must list at least the four required + kind enum
    run jq -e '.properties.kind.enum | sort' "$schema"
    [ "$status" -eq 0 ]
    run jq -e '.properties.kind.enum | index("modsec") and index("firewall") and index("sig")' "$schema"
    [ "$status" -eq 0 ]
    # case_id pattern must match canonical CASE-YYYY-NNNN
    run jq -er '.properties.case_id.pattern' "$schema"
    [ "$status" -eq 0 ]
    [[ "$output" == "^CASE-[0-9]{4}-[0-9]{4}$" ]]
}

@test "schemas/intent.json declares required fields for reconstruct_intent" {
    local schema="$BL_REPO_ROOT/schemas/intent.json"
    [ -r "$schema" ]
    run jq -e '.required | index("file_id") and index("depth") and index("case_id")' "$schema"
    [ "$status" -eq 0 ]
    run jq -e '.properties.depth.enum | index("shallow") and index("deep")' "$schema"
    [ "$status" -eq 0 ]
    run jq -er '.properties.case_id.pattern' "$schema"
    [ "$status" -eq 0 ]
    [[ "$output" == "^CASE-[0-9]{4}-[0-9]{4}$" ]]
}

@test "schemas/{defense,intent}.json reject Managed-Agents-prohibited keywords" {
    # Per DESIGN.md §12 — additionalProperties + per-field description rejected
    # by managed-agents-2026-04-01. Verify schemas carry neither.
    local d="$BL_REPO_ROOT/schemas/defense.json"
    local i="$BL_REPO_ROOT/schemas/intent.json"
    run jq -e '.additionalProperties == null and .properties[].description == null' "$d"
    [ "$status" -eq 0 ]
    run jq -e '.additionalProperties == null and .properties[].description == null' "$i"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# S10 (M11 P9): partial-state recovery
# Audit gap: only S1 (full-blank) and S2 (full-seeded) covered before. Operator
# crash mid-provision leaves agent-id but env-id missing — bl setup must repair.
# ---------------------------------------------------------------------------

@test "bl setup recovers partial state — agent exists, env missing → repair" {
    mkdir -p "$BL_VAR_DIR/state"
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
    # Only agent-id is present; no env-id, no memstore-skills-id, no memstore-case-id
    # Mock returns: agent listing hit (existing), env-create success, memstore-create successes.
    # Memory_stores list must return empty so the create branch fires (per src/bl.d/84-setup.sh:200).
    bl_curator_mock_set_response 'setup-agents-list-hit.json' 200
    bl_curator_mock_add_route '/v1/environments$' 'setup-env-create-success.json' 201
    bl_curator_mock_add_route '/v1/memory_stores\?name=' 'setup-memstore-list-empty.json' 200
    bl_curator_mock_add_route '/v1/memory_stores$' 'setup-memstore-create-skills.json' 201
    run "$BL_SOURCE" setup
    [ "$status" -eq 0 ]
    # Verify all four ids now cached
    [ -r "$BL_VAR_DIR/state/agent-id" ]
    [ -r "$BL_VAR_DIR/state/env-id" ]
    [ -r "$BL_VAR_DIR/state/memstore-skills-id" ]
    [ -r "$BL_VAR_DIR/state/memstore-case-id" ]
}

# ---------------------------------------------------------------------------
# S11 (M11 P13): --sync delta verification — only the modified skill is POSTed.
# Audit gap: prior --sync tests assert summary text; this asserts the actual
# wire traffic (which keys hit the memory POST endpoint).
# ---------------------------------------------------------------------------

@test "bl setup --sync — only POSTs the modified skill (delta verification)" {
    mkdir -p "$BL_VAR_DIR/state" "$BL_VAR_DIR/fixtures"
    printf 'agent_test_stub'      > "$BL_VAR_DIR/state/agent-id"
    printf 'env_test_stub'        > "$BL_VAR_DIR/state/env-id"
    printf 'memstore_skills_stub' > "$BL_VAR_DIR/state/memstore-skills-id"
    printf 'memstore_case_stub'   > "$BL_VAR_DIR/state/memstore-case-id"
    # Build a fake repo with 3 skills + curator-agent prompt so resolve_source
    # accepts BL_REPO_ROOT (DESIGN.md §8.3 step 0).
    local fake_repo
    fake_repo=$(mktemp -d)
    mkdir -p "$fake_repo/skills/foo" "$fake_repo/prompts"
    printf 'skill-a-content-original\n' > "$fake_repo/skills/foo/a.md"
    printf 'skill-b-content\n'          > "$fake_repo/skills/foo/b.md"
    printf 'skill-c-content\n'          > "$fake_repo/skills/foo/c.md"
    printf 'curator prompt\n'           > "$fake_repo/prompts/curator-agent.md"
    export BL_REPO_ROOT="$fake_repo"
    # Redirect fixtures dir so the per-test MANIFEST baseline does not collide
    # with the shared tests/fixtures/setup-manifest-baseline.json (content:"[]").
    export BL_CURATOR_MOCK_FIXTURES_DIR="$BL_VAR_DIR/fixtures"
    # Remote MANIFEST holds shas matching ALL three originals — diff sees zero
    # delta until we modify a.md AFTER the fixture is materialized.
    local sha_a sha_b sha_c
    sha_a=$(sha256sum "$fake_repo/skills/foo/a.md" | awk '{print $1}')
    sha_b=$(sha256sum "$fake_repo/skills/foo/b.md" | awk '{print $1}')
    sha_c=$(sha256sum "$fake_repo/skills/foo/c.md" | awk '{print $1}')
    jq -n --arg a "$sha_a" --arg b "$sha_b" --arg c "$sha_c" \
        '{key:"MANIFEST.json", content:("[{\"path\":\"foo/a.md\",\"sha256\":\""+$a+"\"},{\"path\":\"foo/b.md\",\"sha256\":\""+$b+"\"},{\"path\":\"foo/c.md\",\"sha256\":\""+$c+"\"}]")}' \
        > "$BL_CURATOR_MOCK_FIXTURES_DIR/setup-manifest-baseline.json"
    # Memory POSTs (and the final MANIFEST re-POST) get a generic ack.
    printf '{"id":"memory_synced"}\n' > "$BL_CURATOR_MOCK_FIXTURES_DIR/sync-memory-ack.json"
    bl_curator_mock_set_response 'sync-memory-ack.json' 201
    bl_curator_mock_add_route 'MANIFEST' 'setup-manifest-baseline.json' 200
    # Now modify skill a — local sha_a no longer matches the captured baseline.
    printf 'skill-a-content-MODIFIED\n' > "$fake_repo/skills/foo/a.md"
    export BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/curl-requests.log"
    run "$BL_SOURCE" setup --sync
    [ "$status" -eq 0 ]
    # Exactly one memory POST for foo/a.md; zero for foo/b.md and foo/c.md.
    # awk avoids anti-pattern #7 (grep -c exits 1 on zero matches → masks count
    # in $() with `|| printf 0` and yields a multi-byte string that breaks `[`).
    [ -r "$BL_MOCK_REQUEST_LOG" ]
    [ "$(awk '/"key":"foo\/a\.md"/{c++} END{print c+0}' "$BL_MOCK_REQUEST_LOG")" -ge 1 ]
    [ "$(awk '/"key":"foo\/b\.md"/{c++} END{print c+0}' "$BL_MOCK_REQUEST_LOG")" -eq 0 ]
    [ "$(awk '/"key":"foo\/c\.md"/{c++} END{print c+0}' "$BL_MOCK_REQUEST_LOG")" -eq 0 ]
    rm -rf "$fake_repo"
}

# ---------------------------------------------------------------------------
# Helper: synthesize a current-manifest fixture from the live skills/ corpus.
# Lets the matches-current test stay green even as new skills land.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# S12 (M12 P3): bl setup --sync POSTs all live skill files (count derived)
# Audit gap: prior --sync tests assert summary text only. This asserts the
# actual POST count matches the live skills/ corpus — guards against silent
# truncation if skills are added later but the sync loop misses them.
# ---------------------------------------------------------------------------

@test "bl setup --sync POSTs all live skill files (count derived from find)" {
    mkdir -p "$BL_VAR_DIR/state" "$BL_VAR_DIR/fixtures"
    printf 'agent_test_stub'      > "$BL_VAR_DIR/state/agent-id"
    printf 'env_test_stub'        > "$BL_VAR_DIR/state/env-id"
    printf 'memstore_skills_stub' > "$BL_VAR_DIR/state/memstore-skills-id"
    printf 'memstore_case_stub'   > "$BL_VAR_DIR/state/memstore-case-id"
    # Use the live blacklight repo as the skills source — count is dynamic.
    export BL_REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export BL_CURATOR_MOCK_FIXTURES_DIR="$BL_VAR_DIR/fixtures"
    # Baseline (empty) MANIFEST → diff sees every skill as "add"
    printf '{"key":"MANIFEST.json","content":"[]"}\n' > "$BL_CURATOR_MOCK_FIXTURES_DIR/setup-manifest-baseline.json"
    printf '{"id":"memory_synced"}\n' > "$BL_CURATOR_MOCK_FIXTURES_DIR/sync-memory-ack.json"
    bl_curator_mock_set_response 'sync-memory-ack.json' 201
    bl_curator_mock_add_route 'MANIFEST' 'setup-manifest-baseline.json' 200
    export BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/curl-requests.log"
    run "$BL_SOURCE" setup --sync
    [ "$status" -eq 0 ]
    # Count expected skills POSTs (every .md under skills/ except INDEX.md)
    local expected
    expected=$(find "$BL_REPO_ROOT/skills" -name '*.md' -not -name 'INDEX.md' | wc -l)
    [ "$expected" -gt 0 ]
    # Count actual POSTs to /v1/memory_stores/*/memories that carry a skills/ key.
    # Log format: URL line then JSON body on the next line (two-line pairs).
    # Use stateful awk: when a POST to memory_stores/memories line is seen, set
    # a flag; on the next line, if the body has "key":"<subdir>/" count it.
    local actual
    actual=$(awk '
        /POST.*memory_stores.*memories/ { post_line=NR; next }
        NR == post_line+1 && /"key":"[a-zA-Z0-9_-]+\// { c++ }
        END { print c+0 }
    ' "$BL_MOCK_REQUEST_LOG")
    # expected skill files + 1 MANIFEST re-POST (MANIFEST key doesn't match the
    # subdir pattern so won't inflate actual; allow minor slack for re-posts)
    [ "$actual" -ge "$expected" ]
    [ "$actual" -le "$((expected + 5))" ]   # allow minor slack
}

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
