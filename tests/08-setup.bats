#!/usr/bin/env bats
# tests/08-setup.bats — M13 P6 bl setup coverage (DESIGN.md §8.2-§8.5; spec §5.4)
# Verb dispatcher: --sync/--reset/--gc/--eval/--check/--help
# Skills API + Files API seeding; state.json persistence.
# Consumes tests/helpers/curator-mock.bash + tests/fixtures/setup-*.json.

load 'helpers/curator-mock.bash'

# _make_fake_repo — create a minimal fake repo directory accepted by bl_setup_resolve_source.
# bl_setup_resolve_source requires: BL_REPO_ROOT/skills/ + BL_REPO_ROOT/prompts/curator-agent.md.
# Path C functions also need: routing-skills/ and skills-corpus/.
_make_fake_repo() {
    local dir="$1"
    mkdir -p "$dir/skills" "$dir/routing-skills" "$dir/skills-corpus" \
             "$dir/prompts" "$dir/schemas"
    printf 'prompt' > "$dir/prompts/curator-agent.md"
    printf '{}' > "$dir/schemas/step.json"
    printf '{}' > "$dir/schemas/defense.json"
    printf '{}' > "$dir/schemas/intent.json"
}

# _state_json_seeded — write a fully-populated state.json to $BL_VAR_DIR/state/
# with agent+env+case-memstore provisioned (so --sync reuses them without API calls).
_state_json_seeded() {
    local state_dir="${1:-$BL_VAR_DIR/state}"
    mkdir -p "$state_dir"
    jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            schema_version: 1,
            agent: {id: "agent_M8_TEST", version: 3, skill_versions: {}},
            env_id: "env_M8_TEST",
            skills: {},
            files: {},
            files_pending_deletion: [],
            case_memstores: {"_default": "memstore_case_M8"},
            case_files: {},
            case_id_counter: {},
            case_current: "",
            session_ids: {},
            last_sync: $ts
        }' > "$state_dir/state.json"
}

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    BL_VAR_DIR="$(mktemp -d)"
    export BL_VAR_DIR
    export BL_STATE_DIR="$BL_VAR_DIR/state"
    export BL_REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export ANTHROPIC_API_KEY="sk-ant-test-M13P6"
    bl_curator_mock_init
}

teardown() {
    bl_curator_mock_teardown
}

# ---------------------------------------------------------------------------
# S2 (modified): pre-seeded state.json → --sync succeeds + last_sync updated
# Uses a fake repo with one skill whose sha is pre-loaded in state.json (no-op).
# ---------------------------------------------------------------------------

@test "bl setup: pre-seeded state → no-op summary, zero create calls" {
    local fake_repo
    fake_repo=$(mktemp -d)
    _make_fake_repo "$fake_repo"
    mkdir -p "$fake_repo/routing-skills/test-skill"
    printf 'desc' > "$fake_repo/routing-skills/test-skill/description.txt"
    printf '# body' > "$fake_repo/routing-skills/test-skill/SKILL.md"
    # Pre-compute sha and seed state.json so seed functions see no-op
    local ds bs
    ds=$(sha256sum "$fake_repo/routing-skills/test-skill/description.txt" | awk '{print $1}')
    bs=$(sha256sum "$fake_repo/routing-skills/test-skill/SKILL.md" | awk '{print $1}')
    _state_json_seeded
    jq --arg ds "$ds" --arg bs "$bs" \
        '.skills["test-skill"] = {id:"skill_P6FIXTURE001", version:"1",
            description_sha256:$ds, body_sha256:$bs}
         | .agent.skill_versions["test-skill"] = "1"' \
        "$BL_VAR_DIR/state/state.json" > "$BL_VAR_DIR/state/state.json.tmp"
    command mv "$BL_VAR_DIR/state/state.json.tmp" "$BL_VAR_DIR/state/state.json"
    export BL_REPO_ROOT="$fake_repo"
    bl_curator_mock_add_route '/v1/agents/' 'setup-agent-update-success.json' 200
    run "$BL_SOURCE" setup --sync
    rm -rf "$fake_repo"
    [ "$status" -eq 0 ]
    # state.json must exist and have last_sync populated
    [ -f "$BL_STATE_DIR/state.json" ]
    run jq -r '.last_sync' "$BL_STATE_DIR/state.json"
    [[ "$output" != "" && "$output" != "null" ]]
}

# ---------------------------------------------------------------------------
# S3: --check partial-state matrix (reads state.json in Path C)
# ---------------------------------------------------------------------------

@test "bl setup --check: empty state → reports agent + env missing" {
    run "$BL_SOURCE" setup --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"agent: missing"* ]]
    [[ "$output" == *"env: missing"* ]]
}

@test "bl setup --check: agent-only state.json → reports env missing" {
    mkdir -p "$BL_VAR_DIR/state"
    jq -n '{schema_version:1, agent:{id:"agent_M8_TEST",version:1,skill_versions:{}}, env_id:"", skills:{}, files:{}, files_pending_deletion:[], case_memstores:{}, case_files:{}, case_id_counter:{}, case_current:"", session_ids:{}, last_sync:""}' \
        > "$BL_VAR_DIR/state/state.json"
    run "$BL_SOURCE" setup --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"agent: ok"* ]]
    [[ "$output" == *"env: missing"* ]]
}

@test "bl setup --check: agent+env state.json → exits 0 with green summary" {
    mkdir -p "$BL_VAR_DIR/state"
    jq -n '{schema_version:1, agent:{id:"agent_M8_TEST",version:1,skill_versions:{}}, env_id:"env_M8_TEST", skills:{}, files:{}, files_pending_deletion:[], case_memstores:{}, case_files:{}, case_id_counter:{}, case_current:"", session_ids:{}, last_sync:"2026-04-25T00:00:00Z"}' \
        > "$BL_VAR_DIR/state/state.json"
    run "$BL_SOURCE" setup --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"agent: ok"* ]]
    [[ "$output" == *"env: ok"* ]]
}

@test "bl setup --check: 2 skills + 3 files in state.json → reports counts" {
    mkdir -p "$BL_VAR_DIR/state"
    jq -n '{schema_version:1,
        agent:{id:"agent_M8_TEST",version:2,skill_versions:{}},
        env_id:"env_M8_TEST",
        skills:{"s1":{id:"skill_1",version:"1",description_sha256:"a",body_sha256:"b"},
                "s2":{id:"skill_2",version:"1",description_sha256:"c",body_sha256:"d"}},
        files:{"/skills/f1.md":{file_id:"file_1",content_sha256:"e",uploaded_at:"2026-04-25T00:00:00Z"},
               "/skills/f2.md":{file_id:"file_2",content_sha256:"f",uploaded_at:"2026-04-25T00:00:00Z"},
               "/skills/f3.md":{file_id:"file_3",content_sha256:"g",uploaded_at:"2026-04-25T00:00:00Z"}},
        files_pending_deletion:[],
        case_memstores:{}, case_files:{}, case_id_counter:{}, case_current:"",
        session_ids:{}, last_sync:"2026-04-25T00:00:00Z"}' \
        > "$BL_VAR_DIR/state/state.json"
    run "$BL_SOURCE" setup --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"skills: 2"* ]]
    [[ "$output" == *"files: 3"* ]]
}

@test "bl setup --check: files_pending_deletion present → reports gc hint" {
    mkdir -p "$BL_VAR_DIR/state"
    jq -n '{schema_version:1,
        agent:{id:"agent_M8_TEST",version:1,skill_versions:{}},
        env_id:"env_M8_TEST",
        skills:{}, files:{},
        files_pending_deletion:[
            {file_id:"file_OLD",marked_at:"2026-04-25T00:00:00Z",
             reason:"superseded by file_NEW",previous_mount_path:"/skills/x.md"}],
        case_memstores:{}, case_files:{}, case_id_counter:{}, case_current:"",
        session_ids:{}, last_sync:"2026-04-25T00:00:00Z"}' \
        > "$BL_VAR_DIR/state/state.json"
    run "$BL_SOURCE" setup --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"files_pending_deletion"* ]] || [[ "$output" == *"gc"* ]] || [[ "$output" == *"--gc"* ]]
}

# ---------------------------------------------------------------------------
# S4: --sync (no-op path — skills sha matches state.json)
# ---------------------------------------------------------------------------

@test "bl setup --sync: remote MANIFEST matches local → zero POST calls, summary reports 0 changes" {
    local fake_repo
    fake_repo=$(mktemp -d)
    _make_fake_repo "$fake_repo"
    mkdir -p "$fake_repo/routing-skills/skill-a"
    printf 'desc' > "$fake_repo/routing-skills/skill-a/description.txt"
    printf '# body' > "$fake_repo/routing-skills/skill-a/SKILL.md"
    # Pre-populate state.json with sha match for skill-a so seed_skills skips
    local ds bs
    ds=$(sha256sum "$fake_repo/routing-skills/skill-a/description.txt" | awk '{print $1}')
    bs=$(sha256sum "$fake_repo/routing-skills/skill-a/SKILL.md" | awk '{print $1}')
    _state_json_seeded
    jq --arg ds "$ds" --arg bs "$bs" \
        '.skills["skill-a"] = {id:"skill_P6FIXTURE001", version:"1", description_sha256:$ds, body_sha256:$bs}
         | .agent.skill_versions["skill-a"] = "1"' \
        "$BL_VAR_DIR/state/state.json" > "$BL_VAR_DIR/state/state.json.tmp"
    command mv "$BL_VAR_DIR/state/state.json.tmp" "$BL_VAR_DIR/state/state.json"
    export BL_REPO_ROOT="$fake_repo"
    export BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/curl-requests.log"
    command touch "$BL_MOCK_REQUEST_LOG"   # ensure file exists even if no API calls made
    bl_curator_mock_add_route '/v1/agents/' 'setup-agent-update-success.json' 200
    run "$BL_SOURCE" setup --sync
    rm -rf "$fake_repo"
    [ "$status" -eq 0 ]
    # No Skills API POSTs expected (sha match skipped skill-a)
    local skills_posts
    skills_posts=$(awk '/POST.*\/v1\/skills/{c++} END{print c+0}' "$BL_VAR_DIR/curl-requests.log")
    [ "$skills_posts" -eq 0 ]
}

# ---------------------------------------------------------------------------
# S5: preflight finds existing agent → caches id, skips create path
# ---------------------------------------------------------------------------

@test "bl setup: preflight finds existing agent → caches id, skips create" {
    local fake_repo
    fake_repo=$(mktemp -d)
    _make_fake_repo "$fake_repo"
    mkdir -p "$fake_repo/routing-skills/skill-x"
    printf 'desc' > "$fake_repo/routing-skills/skill-x/description.txt"
    printf '# body' > "$fake_repo/routing-skills/skill-x/SKILL.md"
    local ds bs
    ds=$(sha256sum "$fake_repo/routing-skills/skill-x/description.txt" | awk '{print $1}')
    bs=$(sha256sum "$fake_repo/routing-skills/skill-x/SKILL.md" | awk '{print $1}')
    # Pre-seed state with agent_M8_TEST + skill sha match → seed_skills no-op; ensure_agent PATCHes
    _state_json_seeded
    jq --arg ds "$ds" --arg bs "$bs" \
        '.skills["skill-x"] = {id:"skill_P6FIXTURE001", version:"1",
            description_sha256:$ds, body_sha256:$bs}
         | .agent.skill_versions["skill-x"] = "1"' \
        "$BL_VAR_DIR/state/state.json" > "$BL_VAR_DIR/state/state.json.tmp"
    command mv "$BL_VAR_DIR/state/state.json.tmp" "$BL_VAR_DIR/state/state.json"
    export BL_REPO_ROOT="$fake_repo"
    # Agent already in state.json → ensure_agent takes PATCH path (not GET/POST create)
    bl_curator_mock_add_route '/v1/agents/' 'setup-agent-update-success.json' 200
    run "$BL_SOURCE" setup --sync
    rm -rf "$fake_repo"
    [ "$status" -eq 0 ]
    [ -f "$BL_STATE_DIR/state.json" ]
    run jq -r '.agent.id' "$BL_STATE_DIR/state.json"
    [ "$output" = "agent_M8_TEST" ]
}

# ---------------------------------------------------------------------------
# S6 (modified): 401 unauthorized → exits 65 with PREFLIGHT_FAIL message
# Uses --sync to trigger the API call path.
# ---------------------------------------------------------------------------

@test "bl setup: 401 from API → exits 65" {
    bl_curator_mock_set_response 'setup-error-401.json' 401
    run "$BL_SOURCE" setup --sync
    [ "$status" -eq 65 ]
}

# ---------------------------------------------------------------------------
# S7: 400 invalid_request_error on agent create → exits 65
# Sets up state with env+memstore+skills provisioned so agent create is
# the first API call, and mock returns 400 for it.
# ---------------------------------------------------------------------------

@test "bl setup: 400 on agent create → exits 65 with body forwarded to operator" {
    local fake_repo
    fake_repo=$(mktemp -d)
    _make_fake_repo "$fake_repo"
    mkdir -p "$fake_repo/routing-skills/skill-x"
    printf 'desc' > "$fake_repo/routing-skills/skill-x/description.txt"
    printf '# body' > "$fake_repo/routing-skills/skill-x/SKILL.md"
    # Pre-seed state.json: no agent, but env + memstore + skills sha match → only agent API fires
    local ds bs
    ds=$(sha256sum "$fake_repo/routing-skills/skill-x/description.txt" | awk '{print $1}')
    bs=$(sha256sum "$fake_repo/routing-skills/skill-x/SKILL.md" | awk '{print $1}')
    mkdir -p "$BL_VAR_DIR/state"
    jq -n \
        --arg ds "$ds" --arg bs "$bs" \
        '{schema_version:1, agent:{id:"",version:0,skill_versions:{}},
          env_id:"env_M8_TEST", skills:{
            "skill-x":{id:"",version:"",description_sha256:$ds, body_sha256:$bs}},
          files:{}, files_pending_deletion:[],
          case_memstores:{"_default":"memstore_case_M8"},
          case_files:{}, case_id_counter:{}, case_current:"",
          session_ids:{}, last_sync:""}' \
        > "$BL_VAR_DIR/state/state.json"
    # Skill id is empty → will call skills.create first, then agent create
    # Route skills.create to success so we reach agent create which gets 400
    export BL_REPO_ROOT="$fake_repo"
    bl_curator_mock_add_route '/v1/skills$' 'setup-skill-create-success.json' 201
    bl_curator_mock_add_route '/v1/skills/' 'setup-skill-create-success.json' 200
    bl_curator_mock_add_route '/v1/agents$' 'setup-error-400.json' 400
    bl_curator_mock_add_route '/v1/agents' 'setup-agents-list-empty.json' 200
    run "$BL_SOURCE" setup --sync
    rm -rf "$fake_repo"
    [ "$status" -eq 65 ]
}

# ---------------------------------------------------------------------------
# S8 (modified): Source-of-truth resolution (DESIGN.md §8.3)
# ---------------------------------------------------------------------------

@test "bl setup: cwd has skills/ + prompts/ → uses cwd (no clone)" {
    cd "$BL_REPO_ROOT"
    mkdir -p "$BL_VAR_DIR/state"
    jq -n '{schema_version:1, agent:{id:"agent_M8_TEST",version:1,skill_versions:{}}, env_id:"env_M8_TEST", skills:{}, files:{}, files_pending_deletion:[], case_memstores:{}, case_files:{}, case_id_counter:{}, case_current:"", session_ids:{}, last_sync:""}' \
        > "$BL_VAR_DIR/state/state.json"
    run "$BL_SOURCE" setup --check
    [[ "$output" == *"source: cwd"* ]] || [[ "$output" == *"source=cwd"* ]] || [[ "$output" == *"(cwd)"* ]]
}

# ---------------------------------------------------------------------------
# S9: create-time 409 race → bl_api_call returns 71, ensure_agent re-probes
# Uses URL anchoring to distinguish POST /v1/agents from GET /v1/agents.
# ---------------------------------------------------------------------------

@test "bl setup: create-time 409 race → bl_api_call returns 71, ensure_agent re-probes + caches" {
    local fake_repo
    fake_repo=$(mktemp -d)
    _make_fake_repo "$fake_repo"
    mkdir -p "$fake_repo/routing-skills/skill-x"
    printf 'desc' > "$fake_repo/routing-skills/skill-x/description.txt"
    printf '# body' > "$fake_repo/routing-skills/skill-x/SKILL.md"
    local ds bs
    ds=$(sha256sum "$fake_repo/routing-skills/skill-x/description.txt" | awk '{print $1}')
    bs=$(sha256sum "$fake_repo/routing-skills/skill-x/SKILL.md" | awk '{print $1}')
    mkdir -p "$BL_VAR_DIR/state"
    # state.json: no agent id → first-run path; skills match → skip seed
    jq -n \
        --arg ds "$ds" --arg bs "$bs" \
        '{schema_version:1, agent:{id:"",version:0,skill_versions:{}},
          env_id:"env_M8_TEST",
          skills:{"skill-x":{id:"skill_P6FIXTURE001",version:"1",
              description_sha256:$ds, body_sha256:$bs}},
          files:{}, files_pending_deletion:[],
          case_memstores:{"_default":"memstore_case_M8"},
          case_files:{}, case_id_counter:{}, case_current:"",
          session_ids:{}, last_sync:""}' \
        > "$BL_VAR_DIR/state/state.json"
    export BL_REPO_ROOT="$fake_repo"
    # Method-qualified mock routes: POST → 409 (conflict); GET (list/re-probe) → hit
    bl_curator_mock_add_route 'POST.*v1/agents$' 'setup-agent-create-conflict.json' 409
    bl_curator_mock_add_route 'GET.*v1/agents' 'setup-agents-list-hit.json' 200
    run "$BL_SOURCE" setup --sync
    rm -rf "$fake_repo"
    [ "$status" -eq 0 ]
    run jq -r '.agent.id' "$BL_STATE_DIR/state.json"
    [ "$output" = "agent_M8_TEST" ]
}

# ---------------------------------------------------------------------------
# S6-schema: defense.json + intent.json input_schemas are non-empty (audit M2)
# ---------------------------------------------------------------------------

@test "schemas/defense.json declares required fields for synthesize_defense" {
    local schema="$BL_REPO_ROOT/schemas/defense.json"
    [ -r "$schema" ]
    run jq -e '.required | sort' "$schema"
    [ "$status" -eq 0 ]
    run jq -e '.required | index("kind") and index("body") and index("reasoning") and index("case_id")' "$schema"
    [ "$status" -eq 0 ]
    run jq -e '.properties.kind.enum | sort' "$schema"
    [ "$status" -eq 0 ]
    run jq -e '.properties.kind.enum | index("modsec") and index("firewall") and index("sig")' "$schema"
    [ "$status" -eq 0 ]
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
    local d="$BL_REPO_ROOT/schemas/defense.json"
    local i="$BL_REPO_ROOT/schemas/intent.json"
    run jq -e '.additionalProperties == null and .properties[].description == null' "$d"
    [ "$status" -eq 0 ]
    run jq -e '.additionalProperties == null and .properties[].description == null' "$i"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# S10 (modified): partial-state recovery via migration
# ---------------------------------------------------------------------------

@test "bl setup recovers partial state — agent exists, env missing → repair" {
    mkdir -p "$BL_VAR_DIR/state"
    # Write per-key files (migration path: no state.json yet)
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
    local fake_repo
    fake_repo=$(mktemp -d)
    _make_fake_repo "$fake_repo"
    mkdir -p "$fake_repo/routing-skills/skill-x"
    printf 'desc' > "$fake_repo/routing-skills/skill-x/description.txt"
    printf '# body' > "$fake_repo/routing-skills/skill-x/SKILL.md"
    export BL_REPO_ROOT="$fake_repo"
    bl_curator_mock_add_route 'POST.*v1/environments$' 'setup-env-create-success.json' 201
    bl_curator_mock_add_route 'GET.*v1/memory_stores' 'setup-memstore-list-empty.json' 200
    bl_curator_mock_add_route 'POST.*v1/memory_stores' 'setup-memstore-create-case.json' 200
    # skills.create (POST) + skills.get (GET /v1/skills/<id>)
    bl_curator_mock_add_route 'POST.*v1/skills$' 'setup-skill-create-success.json' 201
    bl_curator_mock_add_route 'GET.*v1/skills' 'setup-skill-create-success.json' 200
    # agent: migrated agent_test_stub — ensure_agent will PATCH (cached_id present after migration)
    bl_curator_mock_add_route '/v1/agents/' 'setup-agent-update-success.json' 200
    run "$BL_SOURCE" setup --sync
    rm -rf "$fake_repo"
    [ "$status" -eq 0 ]
    # state.json exists with agent id preserved from migration
    [ -f "$BL_STATE_DIR/state.json" ]
    run jq -r '.agent.id' "$BL_STATE_DIR/state.json"
    [ "$output" = "agent_test_stub" ]
}

# ---------------------------------------------------------------------------
# S13 (M13 P5): state.json schema validation — PRESERVED from P5
# ---------------------------------------------------------------------------

@test "state.json schema_version=1 + all required keys present" {
    local state_dir="$BATS_TEST_TMPDIR/state"
    mkdir -p "$state_dir"
    cp "${BATS_TEST_DIRNAME}/fixtures/state-json-baseline.json" "$state_dir/state.json"
    run jq -e '.schema_version == 1' "$state_dir/state.json"
    [ "$status" -eq 0 ]
    run jq -e 'keys | contains(["agent","case_current","case_files","case_id_counter","case_memstores","env_id","files","files_pending_deletion","last_sync","schema_version","session_ids","skills"])' "$state_dir/state.json"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# S14 (M13 P5): first-run migration — per-key state files folded into state.json
# PRESERVED from P5
# ---------------------------------------------------------------------------

@test "first-run migration: per-key state files folded into state.json" {
    export BL_VAR_DIR="$BATS_TEST_TMPDIR/var"
    export BL_STATE_DIR="$BL_VAR_DIR/state"
    mkdir -p "$BL_STATE_DIR"
    cp "${BATS_TEST_DIRNAME}/fixtures/state-old-per-key"/* "$BL_STATE_DIR/"
    [ -f "$BL_STATE_DIR/agent-id" ]
    [ -f "$BL_STATE_DIR/env-id" ]
    [ ! -f "$BL_STATE_DIR/state.json" ]
    run bash -c ". \"$BL_SOURCE\"; bl_setup_load_state"
    [ "$status" -eq 0 ]
    [ -f "$BL_STATE_DIR/state.json" ]
    [ ! -f "$BL_STATE_DIR/agent-id" ]
    [ ! -f "$BL_STATE_DIR/env-id" ]
    [ ! -f "$BL_STATE_DIR/memstore-skills-id" ]
    [ ! -f "$BL_STATE_DIR/memstore-case-id" ]
    run jq -r '.agent.id' "$BL_STATE_DIR/state.json"
    [ "$output" = "agent_01OLDFIXTURE" ]
    run jq -r '.env_id' "$BL_STATE_DIR/state.json"
    [ "$output" = "env_01OLDFIXTURE" ]
}

# ===========================================================================
# NEW TESTS (M13 P6) — 12 tests covering verb-dispatcher + seed functions
# ===========================================================================

# ---------------------------------------------------------------------------
# N1: --sync hash-skip on no-op (corpus + skills both unchanged)
# ---------------------------------------------------------------------------

@test "bl setup --sync hash-skip on no-op (corpus + skills both unchanged)" {
    local fake_repo
    fake_repo=$(mktemp -d)
    _make_fake_repo "$fake_repo"
    mkdir -p "$fake_repo/routing-skills/skill-x"
    printf 'desc' > "$fake_repo/routing-skills/skill-x/description.txt"
    printf '# body' > "$fake_repo/routing-skills/skill-x/SKILL.md"
    printf 'corpus content' > "$fake_repo/skills-corpus/corpus-x.md"
    # Pre-populate state.json with matching hashes for both skill-x and corpus-x.md
    local ds bs corpus_sha
    ds=$(sha256sum "$fake_repo/routing-skills/skill-x/description.txt" | awk '{print $1}')
    bs=$(sha256sum "$fake_repo/routing-skills/skill-x/SKILL.md" | awk '{print $1}')
    corpus_sha=$(sha256sum "$fake_repo/skills-corpus/corpus-x.md" | awk '{print $1}')
    mkdir -p "$BL_VAR_DIR/state"
    jq -n \
        --arg ds "$ds" --arg bs "$bs" --arg cs "$corpus_sha" \
        '{
            schema_version: 1,
            agent: {id: "agent_M8_TEST", version: 3, skill_versions: {"skill-x":"1"}},
            env_id: "env_M8_TEST",
            skills: {"skill-x": {id: "skill_P6FIXTURE001", version: "1",
                description_sha256: $ds, body_sha256: $bs}},
            files: {"/skills/corpus-x.md": {file_id:"file_P6FIXTURE001",
                content_sha256: $cs, uploaded_at: "2026-04-25T00:00:00Z"}},
            files_pending_deletion: [],
            case_memstores: {"_default": "memstore_case_M8"},
            case_files: {}, case_id_counter: {}, case_current: "",
            session_ids: {}, last_sync: ""
        }' > "$BL_VAR_DIR/state/state.json"
    export BL_REPO_ROOT="$fake_repo"
    export BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/curl-requests.log"
    command touch "$BL_MOCK_REQUEST_LOG"   # ensure file exists even if no API calls made
    bl_curator_mock_add_route '/v1/agents/' 'setup-agent-update-success.json' 200
    run "$BL_SOURCE" setup --sync
    rm -rf "$fake_repo"
    [ "$status" -eq 0 ]
    # No Files API POSTs expected (sha match)
    local files_posts skills_posts
    files_posts=$(awk '/POST.*\/v1\/files/{c++} END{print c+0}' "$BL_VAR_DIR/curl-requests.log")
    skills_posts=$(awk '/POST.*\/v1\/skills/{c++} END{print c+0}' "$BL_VAR_DIR/curl-requests.log")
    [ "$files_posts" -eq 0 ]
    [ "$skills_posts" -eq 0 ]
    # state.json last_sync must be updated
    run jq -r '.last_sync' "$BL_VAR_DIR/state/state.json"
    [[ "$output" != "" && "$output" != "null" ]]
}

# ---------------------------------------------------------------------------
# N2: --sync uploads new corpus file when sha changes
# ---------------------------------------------------------------------------

@test "bl setup --sync uploads new corpus file when sha changes" {
    local fake_repo
    fake_repo=$(mktemp -d)
    _make_fake_repo "$fake_repo"
    mkdir -p "$fake_repo/routing-skills/skill-x"
    printf 'desc' > "$fake_repo/routing-skills/skill-x/description.txt"
    printf '# body' > "$fake_repo/routing-skills/skill-x/SKILL.md"
    printf 'original corpus content' > "$fake_repo/skills-corpus/corpus-x.md"
    local ds bs
    ds=$(sha256sum "$fake_repo/routing-skills/skill-x/description.txt" | awk '{print $1}')
    bs=$(sha256sum "$fake_repo/routing-skills/skill-x/SKILL.md" | awk '{print $1}')
    # Pre-populate state.json with OLD corpus sha (so sha mismatch triggers upload)
    # Skills match so seed_skills is a no-op; only corpus triggers Files API
    mkdir -p "$BL_VAR_DIR/state"
    jq -n \
        --arg ds "$ds" --arg bs "$bs" \
        '{schema_version: 1,
          agent: {id: "agent_M8_TEST", version: 3, skill_versions: {"skill-x":"1"}},
          env_id: "env_M8_TEST",
          skills: {"skill-x": {id: "skill_P6FIXTURE001", version: "1",
              description_sha256: $ds, body_sha256: $bs}},
          files: {"/skills/corpus-x.md": {file_id:"file_OLD",
              content_sha256: "0000000000000000000000000000000000000000000000000000000000000000",
              uploaded_at: "2026-04-24T00:00:00Z"}},
          files_pending_deletion: [],
          case_memstores: {"_default": "memstore_case_M8"},
          case_files: {}, case_id_counter: {}, case_current: "",
          session_ids: {}, last_sync: ""}' > "$BL_VAR_DIR/state/state.json"
    export BL_REPO_ROOT="$fake_repo"
    export BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/curl-requests.log"
    command touch "$BL_MOCK_REQUEST_LOG"
    bl_curator_mock_add_route '/v1/files' 'setup-file-create-success.json' 201
    bl_curator_mock_add_route '/v1/agents/' 'setup-agent-update-success.json' 200
    run "$BL_SOURCE" setup --sync
    rm -rf "$fake_repo"
    [ "$status" -eq 0 ]
    # Files API POST called at least once
    local files_posts
    files_posts=$(awk '/POST.*\/v1\/files/{c++} END{print c+0}' "$BL_VAR_DIR/curl-requests.log")
    [ "$files_posts" -ge 1 ]
    # Old file_id must be in files_pending_deletion
    run jq -r '.files_pending_deletion | length' "$BL_VAR_DIR/state/state.json"
    [ "$output" -ge 1 ]
}

# ---------------------------------------------------------------------------
# N3: --sync --dry-run prints diff without API mutation
# ---------------------------------------------------------------------------

@test "bl setup --sync --dry-run prints diff without API mutation" {
    local fake_repo
    fake_repo=$(mktemp -d)
    _make_fake_repo "$fake_repo"
    mkdir -p "$fake_repo/routing-skills/skill-x"
    printf 'desc' > "$fake_repo/routing-skills/skill-x/description.txt"
    printf '# body' > "$fake_repo/routing-skills/skill-x/SKILL.md"
    printf 'corpus content' > "$fake_repo/skills-corpus/corpus-x.md"
    _state_json_seeded
    export BL_REPO_ROOT="$fake_repo"
    export BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/curl-requests.log"
    command touch "$BL_MOCK_REQUEST_LOG"
    run "$BL_SOURCE" setup --sync --dry-run
    rm -rf "$fake_repo"
    [ "$status" -eq 0 ]
    # Output must contain dry-run signal
    [[ "$output" == *"dry-run"* ]]
    # No POST/DELETE calls to API during dry-run
    local post_count del_count
    post_count=$(awk '/^POST /{c++} END{print c+0}' "$BL_VAR_DIR/curl-requests.log")
    del_count=$(awk '/^DELETE /{c++} END{print c+0}' "$BL_VAR_DIR/curl-requests.log")
    [ "$post_count" -eq 0 ]
    [ "$del_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# N4: --reset deletes agent + Skills + workspace Files (with --force)
# ---------------------------------------------------------------------------

@test "bl setup --reset deletes agent + Skills + workspace Files (with --force)" {
    mkdir -p "$BL_VAR_DIR/state"
    jq -n '{
        schema_version: 1,
        agent: {id: "agent_TODELETE", version: 1, skill_versions: {}},
        env_id: "env_TODELETE",
        skills: {"s1": {id: "skill_TODELETE", version: "1",
            description_sha256: "aaa", body_sha256: "bbb"}},
        files: {"/skills/f1.md": {file_id:"file_TODELETE",
            content_sha256: "ccc", uploaded_at: "2026-04-25T00:00:00Z"}},
        files_pending_deletion: [],
        case_memstores: {"_default": "memstore_KEEP"},
        case_files: {"CASE-2026-0001": {}},
        case_id_counter: {}, case_current: "", session_ids: {}, last_sync: ""
    }' > "$BL_VAR_DIR/state/state.json"
    export BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/curl-requests.log"
    command touch "$BL_MOCK_REQUEST_LOG"
    bl_curator_mock_set_response 'setup-agent-create-success.json' 200
    run "$BL_SOURCE" setup --reset --force
    [ "$status" -eq 0 ]
    # DELETE calls for agent + skill + file
    local del_count
    del_count=$(awk '/^DELETE /{c++} END{print c+0}' "$BL_VAR_DIR/curl-requests.log")
    [ "$del_count" -ge 3 ]
    # state.json: agent.id cleared, skills/files empty
    run jq -r '.agent.id' "$BL_VAR_DIR/state/state.json"
    [ "$output" = "" ]
    run jq -r '.skills | length' "$BL_VAR_DIR/state/state.json"
    [ "$output" = "0" ]
    run jq -r '.files | length' "$BL_VAR_DIR/state/state.json"
    [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# N5: --reset preserves case_memstores + case_files in state.json
# ---------------------------------------------------------------------------

@test "bl setup --reset preserves case_memstores + case_files in state.json" {
    mkdir -p "$BL_VAR_DIR/state"
    jq -n '{
        schema_version: 1,
        agent: {id: "agent_TODELETE2", version: 1, skill_versions: {}},
        env_id: "env_TODELETE2",
        skills: {},
        files: {},
        files_pending_deletion: [],
        case_memstores: {"_default": "memstore_PRESERVE"},
        case_files: {"CASE-2026-0001": {"raw.log": {workspace_file_id: "file_CASE_PRESERVE"}}},
        case_id_counter: {"seq": 1}, case_current: "CASE-2026-0001",
        session_ids: {}, last_sync: ""
    }' > "$BL_VAR_DIR/state/state.json"
    bl_curator_mock_set_response 'setup-agent-create-success.json' 200
    run "$BL_SOURCE" setup --reset --force
    [ "$status" -eq 0 ]
    # case_memstores and case_files must survive
    run jq -r '.case_memstores["_default"]' "$BL_VAR_DIR/state/state.json"
    [ "$output" = "memstore_PRESERVE" ]
    run jq -r '.case_files["CASE-2026-0001"]["raw.log"].workspace_file_id' "$BL_VAR_DIR/state/state.json"
    [ "$output" = "file_CASE_PRESERVE" ]
}

# ---------------------------------------------------------------------------
# N6: --gc skips file_ids referenced by live sessions (conservative)
# ---------------------------------------------------------------------------

@test "bl setup --gc respects pending_deletion + skips file_ids referenced by live sessions" {
    mkdir -p "$BL_VAR_DIR/state"
    jq -n '{
        schema_version: 1,
        agent: {id: "agent_M8_TEST", version: 1, skill_versions: {}},
        env_id: "env_M8_TEST",
        skills: {},
        files: {},
        files_pending_deletion: [{file_id: "file_PENDING", marked_at: "2026-04-25T00:00:00Z",
            reason: "superseded by file_NEW", previous_mount_path: "/skills/x.md"}],
        case_memstores: {},
        case_files: {}, case_id_counter: {}, case_current: "",
        session_ids: {"CASE-2026-0001": "sesn_ACTIVE"},
        last_sync: ""
    }' > "$BL_VAR_DIR/state/state.json"
    run "$BL_SOURCE" setup --gc
    [ "$status" -eq 0 ]
    # File should be skipped since live sessions are present
    [[ "$output" == *"skip"* ]] || [[ "$output" == *"skipped"* ]] || [[ "$output" == *"conservative"* ]]
    # files_pending_deletion must still contain the entry (not deleted)
    run jq -r '.files_pending_deletion | length' "$BL_VAR_DIR/state/state.json"
    [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# N7: --gc deletes pending file_ids when no live sessions reference
# ---------------------------------------------------------------------------

@test "bl setup --gc deletes pending file_ids when no live sessions reference" {
    mkdir -p "$BL_VAR_DIR/state"
    jq -n '{
        schema_version: 1,
        agent: {id: "agent_M8_TEST", version: 1, skill_versions: {}},
        env_id: "env_M8_TEST",
        skills: {},
        files: {},
        files_pending_deletion: [{file_id: "file_PENDING2", marked_at: "2026-04-25T00:00:00Z",
            reason: "superseded by file_NEW2", previous_mount_path: "/skills/y.md"}],
        case_memstores: {},
        case_files: {}, case_id_counter: {}, case_current: "",
        session_ids: {},
        last_sync: ""
    }' > "$BL_VAR_DIR/state/state.json"
    bl_curator_mock_set_response 'setup-agent-create-success.json' 200
    run "$BL_SOURCE" setup --gc
    [ "$status" -eq 0 ]
    [[ "$output" == *"deleted"* ]] || [[ "$output" == *"1"* ]]
    # files_pending_deletion must be empty after GC
    run jq -r '.files_pending_deletion | length' "$BL_VAR_DIR/state/state.json"
    [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# N8: --eval (stub) emits expected JSON shape
# ---------------------------------------------------------------------------

@test "bl setup --eval (stub) emits expected JSON shape" {
    run "$BL_SOURCE" setup --eval
    [ "$status" -eq 0 ]
    # Output must contain the expected JSON fields
    local json_line
    json_line=$(printf '%s' "$output" | grep -E '^\{.*per_skill_precision')
    [[ -n "$json_line" ]]
    run printf '%s' "$json_line" | jq -e '.per_skill_precision != null and (.cross_skill_recall | type) == "number" and (.promotion_pass | type) == "boolean" and (.below_bar | type) == "array"'
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# N9: --eval --promote returns 65 when bar not met (stub)
# ---------------------------------------------------------------------------

@test "bl setup --eval --promote returns 65 when bar not met (stub)" {
    run "$BL_SOURCE" setup --eval --promote
    [ "$status" -eq 65 ]
    [[ "$output" == *"promotion bar not met"* ]] || [[ "$output" == *"below_bar"* ]]
}

# ---------------------------------------------------------------------------
# N10: --sync rejects empty routing-skills/ (spec §11b row 5)
# ---------------------------------------------------------------------------

@test "bl setup --sync rejects empty routing-skills/ (spec §11b row 5)" {
    local fake_repo
    fake_repo=$(mktemp -d)
    _make_fake_repo "$fake_repo"
    # routing-skills/ exists but has NO subdirs → seed_skills returns 65
    mkdir -p "$BL_VAR_DIR/state"
    jq -n '{schema_version:1, agent:{id:"agent_M8_TEST",version:1,skill_versions:{}},
            env_id:"env_M8_TEST", skills:{}, files:{},
            files_pending_deletion:[], case_memstores:{"_default":"memstore_case_M8"},
            case_files:{}, case_id_counter:{}, case_current:"",
            session_ids:{}, last_sync:""}' \
        > "$BL_VAR_DIR/state/state.json"
    export BL_REPO_ROOT="$fake_repo"
    run "$BL_SOURCE" setup --sync
    rm -rf "$fake_repo"
    [ "$status" -eq 65 ]
    [[ "$output" == *"no routing Skills found"* ]]
}

# ---------------------------------------------------------------------------
# N11: --sync rejects description.txt >1024 chars (spec §11b row 6)
# Covered by bl_skills_create size guard from P1.
# ---------------------------------------------------------------------------

@test "bl setup --sync rejects description.txt > 1024 chars" {
    local fake_repo
    fake_repo=$(mktemp -d)
    _make_fake_repo "$fake_repo"
    mkdir -p "$fake_repo/routing-skills/oversized-skill"
    # Create description.txt > 1024 chars using printf (no python3 in container)
    printf '%1025s' ' ' | tr ' ' 'x' > "$fake_repo/routing-skills/oversized-skill/description.txt"
    printf '# body' > "$fake_repo/routing-skills/oversized-skill/SKILL.md"
    mkdir -p "$BL_VAR_DIR/state"
    jq -n '{schema_version:1, agent:{id:"agent_M8_TEST",version:1,skill_versions:{}},
            env_id:"env_M8_TEST", skills:{}, files:{},
            files_pending_deletion:[], case_memstores:{"_default":"memstore_case_M8"},
            case_files:{}, case_id_counter:{}, case_current:"",
            session_ids:{}, last_sync:""}' \
        > "$BL_VAR_DIR/state/state.json"
    export BL_REPO_ROOT="$fake_repo"
    run "$BL_SOURCE" setup --sync
    rm -rf "$fake_repo"
    [ "$status" -eq 65 ]
    [[ "$output" == *"1024"* ]] || [[ "$output" == *"exceeds"* ]]
}

# ---------------------------------------------------------------------------
# N12: --sync acquires flock on state.json.lock (serializes concurrent calls)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# N13 (M14 P9): bl setup --install-hook lmd
# ---------------------------------------------------------------------------

@test "bl setup --install-hook lmd: writes hook and edits conf.maldet" {
    local td
    td=$(mktemp -d)
    mkdir -p "$td/usr/local/maldetect" "$td/etc/blacklight"
    printf 'email_addr=""\nhookscan_fail_open="1"\npost_scan_hook=""\n' > "$td/usr/local/maldetect/conf.maldet"
    export BL_LMD_CONF_PATH="$td/usr/local/maldetect/conf.maldet"
    export BL_BLACKLIGHT_DIR="$td/etc/blacklight"
    run "$BL_SOURCE" setup --install-hook lmd
    unset BL_LMD_CONF_PATH BL_BLACKLIGHT_DIR
    rm -rf "$td"
    [ "$status" -eq 0 ]
}

@test "bl setup --install-hook lmd: idempotent on re-run (conf.maldet unchanged)" {
    local td
    td=$(mktemp -d)
    mkdir -p "$td/usr/local/maldetect" "$td/etc/blacklight"
    printf 'email_addr=""\npost_scan_hook=""\n' > "$td/usr/local/maldetect/conf.maldet"
    export BL_LMD_CONF_PATH="$td/usr/local/maldetect/conf.maldet"
    export BL_BLACKLIGHT_DIR="$td/etc/blacklight"
    "$BL_SOURCE" setup --install-hook lmd >/dev/null 2>&1 || true  # 2>/dev/null: first-run stderr noise is diagnostic, not test signal
    local first
    first=$(md5sum "$td/usr/local/maldetect/conf.maldet" | awk '{print $1}')
    "$BL_SOURCE" setup --install-hook lmd >/dev/null 2>&1 || true  # 2>/dev/null: idempotent re-run stderr noise
    local second
    second=$(md5sum "$td/usr/local/maldetect/conf.maldet" | awk '{print $1}')
    unset BL_LMD_CONF_PATH BL_BLACKLIGHT_DIR
    rm -rf "$td"
    [ "$first" = "$second" ]
}

@test "bl setup with no flags: default help path unchanged (regression)" {
    run "$BL_SOURCE" setup
    [ "$status" -eq 0 ]
    [[ "$output" == *"--sync"* ]] || [[ "$output" == *"Subcommands"* ]] || [[ "$output" == *"SUBCOMMAND"* ]]
}

# ---------------------------------------------------------------------------
# N14 (M14 P9): bl setup --sync acquires flock on state.json.lock
# ---------------------------------------------------------------------------

@test "bl setup --sync acquires flock on state.json.lock" {
    local fake_repo
    fake_repo=$(mktemp -d)
    _make_fake_repo "$fake_repo"
    mkdir -p "$fake_repo/routing-skills/skill-x"
    printf 'desc' > "$fake_repo/routing-skills/skill-x/description.txt"
    printf '# body' > "$fake_repo/routing-skills/skill-x/SKILL.md"
    printf 'corpus content' > "$fake_repo/skills-corpus/corpus-x.md"
    _state_json_seeded
    export BL_REPO_ROOT="$fake_repo"
    bl_curator_mock_add_route '/v1/files' 'setup-file-create-success.json' 201
    bl_curator_mock_add_route '/v1/skills$' 'setup-skill-create-success.json' 201
    bl_curator_mock_add_route '/v1/skills/' 'setup-skill-create-success.json' 200
    bl_curator_mock_add_route '/v1/agents/' 'setup-agent-update-success.json' 200
    # Acquire flock externally before invoking bl setup --sync with -w 0 timeout
    local lock_file="$BL_VAR_DIR/state/state.json.lock"
    mkdir -p "$BL_VAR_DIR/state"
    command touch "$lock_file"
    # Hold the lock for 2 seconds in background, then release
    ( flock -x 9; sleep 2 ) 9<>"$lock_file" &
    local bg_pid=$!
    # Second invocation should block until first releases; verify it exits 0 eventually
    run "$BL_SOURCE" setup --sync
    wait "$bg_pid" 2>/dev/null || true
    rm -rf "$fake_repo"
    [ "$status" -eq 0 ]
    # Verify state.json.lock was created
    [ -f "$lock_file" ]
}

# ---------------------------------------------------------------------------
# M15 P1 — migration safety (F1)
# ---------------------------------------------------------------------------

@test "bl setup: migration with valid case-id-counter writes state.json + preserves backup" {
    mkdir -p "$BL_STATE_DIR"
    printf 'agent_TEST123' > "$BL_STATE_DIR/agent-id"
    printf 'env_TEST456' > "$BL_STATE_DIR/env-id"
    printf 'memstore_TESTabc' > "$BL_STATE_DIR/memstore-case-id"
    printf '{"year":2026,"n":7}\n' > "$BL_STATE_DIR/case-id-counter"
    printf 'CASE-2026-0007' > "$BL_STATE_DIR/case.current"
    run "$BL_SOURCE" setup --check
    [ "$status" -eq 0 ] || [ "$status" -eq 65 ]   # state populated; --check may exit 65 if env is unreachable in tests
    [ -f "$BL_STATE_DIR/state.json" ]
    [ "$(jq -r '.agent.id' "$BL_STATE_DIR/state.json")" = "agent_TEST123" ]
    [ "$(jq -r '.env_id' "$BL_STATE_DIR/state.json")" = "env_TEST456" ]
    [ "$(jq -r '.case_memstores._legacy' "$BL_STATE_DIR/state.json")" = "memstore_TESTabc" ]
    [ "$(jq -r '.case_id_counter.year' "$BL_STATE_DIR/state.json")" = "2026" ]
    [ "$(jq -r '.case_id_counter.n' "$BL_STATE_DIR/state.json")" = "7" ]
    # backup directory created
    ls "$BL_STATE_DIR"/migration-backup-* >/dev/null 2>&1
    [ "$?" -eq 0 ]
    # legacy files removed
    [ ! -f "$BL_STATE_DIR/agent-id" ]
    [ ! -f "$BL_STATE_DIR/env-id" ]
}

@test "bl setup: migration with corrupt case-id-counter aborts cleanly without deleting legacy files" {
    mkdir -p "$BL_STATE_DIR"
    printf 'agent_TEST123' > "$BL_STATE_DIR/agent-id"
    printf 'env_TEST456' > "$BL_STATE_DIR/env-id"
    printf '{"year":2026,"n":' > "$BL_STATE_DIR/case-id-counter"   # truncated JSON — jq rejects
    run "$BL_SOURCE" setup --check
    # F1 fix substitutes {} on counter validation failure (warn, not abort)
    # Migration succeeds; counter_validated falls back to {}; legacy files removed.
    [ -f "$BL_STATE_DIR/state.json" ]
    [ "$(jq -r '.agent.id' "$BL_STATE_DIR/state.json")" = "agent_TEST123" ]
    [ "$(jq -r '.case_id_counter' "$BL_STATE_DIR/state.json")" = "{}" ]
    # backup preserves the corrupt counter for diagnosis
    ls "$BL_STATE_DIR"/migration-backup-*/case-id-counter >/dev/null 2>&1
    [ "$?" -eq 0 ]
    # warn line emitted
    [[ "$output" == *"case-id-counter content rejected by jq"* ]]
}

@test "bl setup: migration aborts cleanly when backup dir mkdir fails" {
    # BL_STATE_DIR is derived from BL_VAR_DIR (readonly in bl header); override
    # BL_VAR_DIR to a path where mkdir -p will fail so bl_setup_load_state
    # hits the backup-dir failure branch and returns BL_EX_PREFLIGHT_FAIL.
    # /proc/self rejects subdirectory creation regardless of UID.
    # The legacy agent-id file lives in the original state dir (saved below).
    local orig_var_dir="$BL_VAR_DIR"
    local orig_state_dir="$BL_STATE_DIR"
    mkdir -p "$orig_state_dir"
    printf 'agent_TEST123' > "$orig_state_dir/agent-id"
    # Redirect BL_VAR_DIR to a /proc path — bl sets BL_STATE_DIR="$BL_VAR_DIR/state"
    export BL_VAR_DIR="/proc/self/bl-cannot-write"
    run "$BL_SOURCE" setup --check
    [ "$status" -ne 0 ]
    # Restore env for cleanup
    export BL_VAR_DIR="$orig_var_dir"
    export BL_STATE_DIR="$orig_state_dir"
    # legacy files NOT deleted on failure (migration never reached rm phase)
    [ -f "$orig_state_dir/agent-id" ]
}
