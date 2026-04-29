#!/usr/bin/env bats
# tests/16-skills-native.bats — M17 P4: bl_setup_seed_skills_native coverage
#
# Tests: happy-path create, sha256 idempotency, version-bump on content change,
#        missing-id branch, existing-id branch, dry-run mode.
# Mock strategy: extends curator-mock + skills-mock; zip is exercised via
#   a real zip invocation against a minimal fake routing-skills directory.

load 'helpers/curator-mock.bash'
load 'helpers/skills-mock.bash'

# _make_fake_rs_dir — create a routing-skills/ subtree with N named skills.
# Each skill gets a minimal SKILL.md and foundations.md.
# Returns path in $BATS_TEST_TMPDIR.
_make_fake_rs_dir() {
    local rs_dir
    rs_dir=$(mktemp -d)
    local names=("$@")
    for name in "${names[@]}"; do
        mkdir -p "$rs_dir/$name"
        printf -- '---\nname: %s\ndescription: Test skill %s. Use when testing.\n---\n# %s\nSee [foundations.md](foundations.md) for IR-playbook lifecycle rules\n' \
            "$name" "$name" "$name" > "$rs_dir/$name/SKILL.md"
        printf 'IR playbook foundations for %s.\n' "$name" > "$rs_dir/$name/foundations.md"
    done
    printf '%s' "$rs_dir"
}

# _seed_state_with_skill — inject a skill entry into state.json.
_seed_state_with_skill() {
    local skill_name="$1" skill_id="$2" skill_sha="$3" skill_version="${4:-v20260428001}"
    local state_file="$BL_STATE_DIR/state.json"
    local tmp="$state_file.tmp.$$"
    jq --arg n "$skill_name" --arg id "$skill_id" \
       --arg sha "$skill_sha" --arg ver "$skill_version" \
       '.skills[$n] = {id: $id, version: $ver, sha256: $sha}' \
       "$state_file" > "$tmp"
    command mv "$tmp" "$state_file"
}

# _blank_state — write a minimal empty state.json.
_blank_state() {
    mkdir -p "$BL_STATE_DIR"
    jq -n '{
        schema_version: 1,
        agent: {id: "", version: 0, skill_versions: {}},
        env_id: "",
        skills: {},
        files: {},
        files_pending_deletion: [],
        case_memstores: {},
        case_files: {},
        case_id_counter: {},
        case_current: "",
        session_ids: {},
        last_sync: ""
    }' > "$BL_STATE_DIR/state.json"
}

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    BL_VAR_DIR="$(mktemp -d)"
    export BL_VAR_DIR
    export BL_STATE_DIR="$BL_VAR_DIR/state"
    export ANTHROPIC_API_KEY="sk-ant-test-M17P4"
    export BL_TMP_DIR="$BL_VAR_DIR/tmp"
    mkdir -p "$BL_TMP_DIR"
    bl_curator_mock_init
    bl_skills_mock_init
    _blank_state
}

teardown() {
    bl_curator_mock_teardown
}

# ---------------------------------------------------------------------------
# Helper: source bl and call bl_setup_seed_skills_native directly.
# We source bl (not run it) so we can call internal functions.
# ---------------------------------------------------------------------------
_source_bl() {
    # shellcheck disable=SC1090
    source "$BL_SOURCE"
}

# ---------------------------------------------------------------------------
# T1: happy-path create — skill not in state.json → POST /v1/skills
# ---------------------------------------------------------------------------

@test "bl_setup_seed_skills_native: happy-path create — new skill posted to API" {
    local rs_dir
    rs_dir=$(_make_fake_rs_dir "synthesizing-evidence")
    export BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/curl-requests.log"
    command touch "$BL_MOCK_REQUEST_LOG"

    _source_bl
    run bl_setup_seed_skills_native apply "$rs_dir"
    [ "$status" -eq 0 ]

    # POST to /v1/skills must appear in the request log
    grep -q 'POST.*v1/skills' "$BL_MOCK_REQUEST_LOG"

    # state.json must have the skill entry populated
    local skill_id
    skill_id=$(jq -r '.skills["synthesizing-evidence"].id // empty' "$BL_STATE_DIR/state.json")
    [ -n "$skill_id" ]
    # sha256 must be stored
    local skill_sha
    skill_sha=$(jq -r '.skills["synthesizing-evidence"].sha256 // empty' "$BL_STATE_DIR/state.json")
    [ -n "$skill_sha" ]
    rm -rf "$rs_dir"
}

# ---------------------------------------------------------------------------
# T2: sha256 idempotency — re-run with no content change → zero API writes
# ---------------------------------------------------------------------------

@test "bl_setup_seed_skills_native: idempotent re-run produces no API writes" {
    local rs_dir
    rs_dir=$(_make_fake_rs_dir "synthesizing-evidence")

    # Compute the expected sha256 for this skill's bundle
    local skill_dir="$rs_dir/synthesizing-evidence"
    local sha
    sha=$( ( cd "$skill_dir" && find . -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print $1}' ) )

    # Pre-seed state.json with matching sha256 and an id
    _seed_state_with_skill "synthesizing-evidence" "skill_EXISTING001" "$sha"

    export BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/curl-requests.log"
    command touch "$BL_MOCK_REQUEST_LOG"

    _source_bl
    run bl_setup_seed_skills_native apply "$rs_dir"
    [ "$status" -eq 0 ]

    # Zero Skills API POSTs expected (sha match → skip)
    # grep -c exits 1 when count=0 (Anti-Pattern #7) — use awk to count safely
    local posts
    posts=$(awk '/POST.*v1\/skills/{c++} END{print c+0}' "$BL_VAR_DIR/curl-requests.log")
    [ "$posts" -eq 0 ]

    # state.json skill id must remain unchanged
    local skill_id
    skill_id=$(jq -r '.skills["synthesizing-evidence"].id // empty' "$BL_STATE_DIR/state.json")
    [ "$skill_id" = "skill_EXISTING001" ]
    rm -rf "$rs_dir"
}

# ---------------------------------------------------------------------------
# T3: version-bump — existing id + sha changed → POST /v1/skills/<id>/versions
# ---------------------------------------------------------------------------

@test "bl_setup_seed_skills_native: version-bump on content change" {
    local rs_dir
    rs_dir=$(_make_fake_rs_dir "synthesizing-evidence")

    # Seed state with a stale sha (different from what's on disk)
    _seed_state_with_skill "synthesizing-evidence" "skill_EXISTING001" "stale_sha_differs"

    export BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/curl-requests.log"
    command touch "$BL_MOCK_REQUEST_LOG"

    _source_bl
    run bl_setup_seed_skills_native apply "$rs_dir"
    [ "$status" -eq 0 ]

    # Must call POST /v1/skills/<id>/versions (NOT POST /v1/skills bare)
    grep -q 'POST.*v1/skills/skill_EXISTING001/versions' "$BL_MOCK_REQUEST_LOG"
    # Must NOT call POST /v1/skills bare (create-new path)
    # grep -c exits 1 on count=0 (Anti-Pattern #7) — use awk
    local bare_creates
    bare_creates=$(awk '/POST.*v1\/skills$/{c++} END{print c+0}' "$BL_MOCK_REQUEST_LOG")
    [ "$bare_creates" -eq 0 ]

    # state.json sha256 must be updated to new value
    local new_sha
    new_sha=$(jq -r '.skills["synthesizing-evidence"].sha256 // empty' "$BL_STATE_DIR/state.json")
    [ "$new_sha" != "stale_sha_differs" ]
    [ -n "$new_sha" ]
    rm -rf "$rs_dir"
}

# ---------------------------------------------------------------------------
# T4: missing-id branch — state.skills.<name> null/missing → create-new path
# ---------------------------------------------------------------------------

@test "bl_setup_seed_skills_native: missing-id branch triggers create-new path" {
    local rs_dir
    rs_dir=$(_make_fake_rs_dir "extracting-iocs")

    # state.json has no entry for extracting-iocs (blank state from setup)
    export BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/curl-requests.log"
    command touch "$BL_MOCK_REQUEST_LOG"

    _source_bl
    run bl_setup_seed_skills_native apply "$rs_dir"
    [ "$status" -eq 0 ]

    # POST /v1/skills (create new) must appear
    grep -q 'POST.*v1/skills' "$BL_MOCK_REQUEST_LOG"

    # Must NOT have called POST /v1/skills/<id>/versions
    # grep -c exits 1 on count=0 (Anti-Pattern #7) — use awk
    local version_calls
    version_calls=$(awk '/POST.*v1\/skills\/.*\/versions/{c++} END{print c+0}' "$BL_MOCK_REQUEST_LOG")
    [ "$version_calls" -eq 0 ]
    rm -rf "$rs_dir"
}

# ---------------------------------------------------------------------------
# T5: existing-id branch — state has id + sha mismatch → version-bump path
# ---------------------------------------------------------------------------

@test "bl_setup_seed_skills_native: existing-id branch triggers version-bump" {
    local rs_dir
    rs_dir=$(_make_fake_rs_dir "gating-false-positives")

    # Seed with an existing id and mismatched sha
    _seed_state_with_skill "gating-false-positives" "skill_GFP_EXISTING" "old_sha_abc"

    export BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/curl-requests.log"
    command touch "$BL_MOCK_REQUEST_LOG"

    _source_bl
    run bl_setup_seed_skills_native apply "$rs_dir"
    [ "$status" -eq 0 ]

    # Must call versions endpoint for the existing id
    grep -q 'POST.*v1/skills/skill_GFP_EXISTING/versions' "$BL_MOCK_REQUEST_LOG"

    # state.json must record the new version from mock response
    local stored_ver
    stored_ver=$(jq -r '.skills["gating-false-positives"].version // empty' "$BL_STATE_DIR/state.json")
    [ -n "$stored_ver" ]
    rm -rf "$rs_dir"
}

# ---------------------------------------------------------------------------
# T6: dry-run mode — logs intent, zero API writes
# ---------------------------------------------------------------------------

@test "bl_setup_seed_skills_native: dry-run mode logs intent without API calls" {
    local rs_dir
    rs_dir=$(_make_fake_rs_dir "curating-cases")

    export BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/curl-requests.log"
    command touch "$BL_MOCK_REQUEST_LOG"

    _source_bl
    run bl_setup_seed_skills_native dry-run "$rs_dir"
    [ "$status" -eq 0 ]

    # Output must mention the skill and dry-run intent
    [[ "$output" == *"curating-cases"* ]]
    [[ "$output" == *"would"* || "$output" == *"dry-run"* || "$output" == *"dry_run"* ]] || \
    [[ "$output" == *"skills.create"* || "$output" == *"create"* ]]

    # Zero API calls in dry-run
    # grep -c exits 1 when count=0 (Anti-Pattern #7) — use awk to count safely
    local api_calls
    api_calls=$(awk '/v1\/skills/{c++} END{print c+0}' "$BL_VAR_DIR/curl-requests.log")
    [ "$api_calls" -eq 0 ]
    rm -rf "$rs_dir"
}

# ---------------------------------------------------------------------------
# T7: bl_api_call_multipart — basic invocation via mock; returns 0 on 2xx
# ---------------------------------------------------------------------------

@test "bl_api_call_multipart: returns 0 on 201 response from Skills API" {
    _source_bl

    # Create a temp file to act as the zip payload
    local tmp_zip
    tmp_zip=$(mktemp)
    printf 'fake-zip-payload' > "$tmp_zip"

    local files_arr=("file=@${tmp_zip};filename=test-skill.zip")
    run bl_api_call_multipart POST "/v1/skills" files_arr "$BL_API_BETA_SKILLS"
    rm -f "$tmp_zip"
    [ "$status" -eq 0 ]
    # Response body must be parseable JSON (skills-create-success.json)
    printf '%s' "$output" | jq -e '.id' > /dev/null
}

# ---------------------------------------------------------------------------
# T8: bl_setup_seed_skills routes to _native (not _as_files)
# ---------------------------------------------------------------------------

@test "bl_setup_seed_skills dispatcher: routes to _native when Skills API returns 2xx" {
    local rs_dir
    rs_dir=$(_make_fake_rs_dir "authoring-incident-briefs")

    # Mock GET /v1/skills to return 200 (Skills API available → _native path)
    # skills-mock already registered GET /v1/skills → skills-list-empty.json:200
    export BL_MOCK_REQUEST_LOG="$BL_VAR_DIR/curl-requests.log"
    command touch "$BL_MOCK_REQUEST_LOG"

    _source_bl
    export BL_REPO_ROOT="$rs_dir/.."
    # We call bl_setup_seed_skills with the rs_dir directly via BL_REPO_ROOT trick:
    # Mimic how bl_setup_seed_skills resolves rs_dir from BL_REPO_ROOT.
    # Create a fake repo-root wrapper so resolve_source returns rs_dir's parent
    local fake_repo
    fake_repo=$(mktemp -d)
    mkdir -p "$fake_repo/routing-skills" "$fake_repo/skills" "$fake_repo/prompts"
    # Copy the rs_dir contents into routing-skills
    cp -r "$rs_dir/." "$fake_repo/routing-skills/"
    printf 'prompt' > "$fake_repo/prompts/curator-agent.md"
    export BL_REPO_ROOT="$fake_repo"

    run bl_setup_seed_skills apply
    rm -rf "$rs_dir" "$fake_repo"
    [ "$status" -eq 0 ]

    # Must NOT have fallen back to _as_files (no /v1/files POST for routing-skill content)
    # grep -c exits 1 on count=0 (Anti-Pattern #7) — use awk
    local files_posts
    files_posts=$(awk '/POST.*v1\/files/{c++} END{print c+0}' "$BL_MOCK_REQUEST_LOG")
    [ "$files_posts" -eq 0 ]
}
