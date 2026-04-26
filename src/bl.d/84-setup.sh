# shellcheck shell=bash
# ----------------------------------------------------------------------------
# bl_setup — workspace bootstrap (DESIGN.md §8.2-§8.5; docs/setup-flow.md authoritative).
# Replaces stub from 80-stubs.sh. Implements:
#   bl setup            — full provisioning (idempotent per setup-flow.md §5)
#   bl setup --check    — partial-state matrix (operator visibility)
#   bl setup --sync     — skills-delta MANIFEST.json sync (POST/PATCH/DELETE)
# Bypasses bl_preflight (90-main.sh:18-22 routes setup pre-preflight). Carries
# its own ANTHROPIC_API_KEY + curl + jq + state-dir checks.
# ----------------------------------------------------------------------------

bl_setup() {
    local mode="provision" prune=""
    while (( $# > 0 )); do
        case "$1" in
            --check)  mode="check";  shift ;;
            --sync)   mode="sync";   shift ;;
            --prune)  prune="yes"; shift ;;
            -*)       bl_error_envelope setup "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)        bl_error_envelope setup "unexpected argument: $1"; return "$BL_EX_USAGE" ;;
        esac
    done
    bl_setup_local_preflight || return $?
    case "$mode" in
        provision)  bl_setup_provision; return $? ;;
        check)      bl_setup_check; return $? ;;
        sync)       bl_setup_sync "$prune"; return $? ;;
    esac
}

bl_setup_local_preflight() {
    # Setup bypasses bl_preflight (would 66 on unseeded state). Carry the
    # same ANTHROPIC_API_KEY + curl + jq + state-dir checks here.
    if [[ -z "${ANTHROPIC_API_KEY+set}" || -z "$ANTHROPIC_API_KEY" ]]; then
        bl_error_envelope setup "ANTHROPIC_API_KEY not set"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    command -v curl >/dev/null 2>&1 || {   # curl missing → preflight-fail; absence is the diagnostic
        bl_error_envelope setup "curl not found"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    command -v jq >/dev/null 2>&1 || {   # jq missing → preflight-fail; absence is the diagnostic
        bl_error_envelope setup "jq not found"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    command mkdir -p "$BL_STATE_DIR" 2>/dev/null || {   # RO fs / perms — surface as preflight-fail
        bl_error_envelope setup "$BL_VAR_DIR not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    return "$BL_EX_OK"
}

# bl_setup_load_state — populate BL_STATE_* shell vars from state.json.
# First-run migration: if state.json absent AND any per-key files exist,
# read each, populate state.json, atomically delete old files. One-time per workspace.
# Returns 0 on success, 65 on malformed state.json.
# shellcheck disable=SC2034  # BL_STATE_LAST_SYNC consumed by Phase 6 callers
bl_setup_load_state() {
    local state_file="$BL_STATE_DIR/state.json"
    command mkdir -p "$BL_STATE_DIR" 2>/dev/null || {   # RO fs / perms
        bl_error_envelope setup "$BL_VAR_DIR not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    if [[ -f "$state_file" ]]; then
        # Validate JSON shape
        if ! jq -e '.schema_version == 1' "$state_file" >/dev/null 2>&1; then   # 2>/dev/null: jq diagnostic vs schema mismatch — both surface as malformed
            bl_error_envelope setup "state.json malformed or schema_version != 1: $state_file"
            return "$BL_EX_PREFLIGHT_FAIL"
        fi
        BL_STATE_AGENT_ID=$(jq -r '.agent.id // empty' "$state_file")
        BL_STATE_AGENT_VERSION=$(jq -r '.agent.version // 0' "$state_file")
        BL_STATE_ENV_ID=$(jq -r '.env_id // empty' "$state_file")
        BL_STATE_MEMSTORE_CASE_ID=$(jq -r '.case_memstores | to_entries[0].value // empty' "$state_file")
        BL_STATE_LAST_SYNC=$(jq -r '.last_sync // empty' "$state_file")
        return "$BL_EX_OK"
    fi
    # First-run migration path — read old per-key files if present
    local old_agent old_env old_skills old_case old_counter old_current
    old_agent=$(command cat "$BL_STATE_DIR/agent-id" 2>/dev/null || printf '')          # missing → empty (new workspace)
    old_env=$(command cat "$BL_STATE_DIR/env-id" 2>/dev/null || printf '')              # missing → empty (new workspace)
    old_skills=$(command cat "$BL_STATE_DIR/memstore-skills-id" 2>/dev/null || printf '') # missing → empty (new workspace)
    old_case=$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf '')   # missing → empty (new workspace)
    old_counter=$(command cat "$BL_STATE_DIR/case-id-counter" 2>/dev/null || printf '') # missing → empty (new workspace)
    old_current=$(command cat "$BL_STATE_DIR/case.current" 2>/dev/null || printf '')    # missing → empty (new workspace)
    if [[ -z "$old_agent" && -z "$old_env" && -z "$old_skills" && -z "$old_case" ]]; then
        # Truly fresh workspace — initialize empty state.json
        BL_STATE_AGENT_ID=""
        BL_STATE_AGENT_VERSION=0
        BL_STATE_ENV_ID=""
        BL_STATE_MEMSTORE_CASE_ID=""
        BL_STATE_LAST_SYNC=""
        bl_setup_save_state || return $?
        return "$BL_EX_OK"
    fi
    # Migrate: populate shell vars from old files, write state.json, delete old files atomically
    bl_info "bl setup: migrating per-key state files → state.json"
    BL_STATE_AGENT_ID="$old_agent"
    BL_STATE_AGENT_VERSION=0   # version unknown pre-Path C; first --sync will probe
    BL_STATE_ENV_ID="$old_env"
    BL_STATE_MEMSTORE_CASE_ID="$old_case"
    BL_STATE_LAST_SYNC=""
    # Build state.json with both old fields preserved
    local tmp_state="$state_file.tmp.$$"
    jq -n \
        --arg aid "$old_agent" \
        --arg env "$old_env" \
        --arg cmid "$old_case" \
        --arg cur "$old_current" \
        --argjson counter "${old_counter:-{}}" \
        '{
            schema_version: 1,
            agent: {id: $aid, version: 0, skill_versions: {}},
            env_id: $env,
            skills: {},
            files: {},
            files_pending_deletion: [],
            case_memstores: (if $cmid != "" then {"_legacy": $cmid} else {} end),
            case_files: {},
            case_id_counter: $counter,
            case_current: $cur,
            session_ids: {},
            last_sync: ""
        }' > "$tmp_state"
    command mv "$tmp_state" "$state_file"
    # Delete old per-key files (skills-id is intentionally orphaned — bl-skills memstore retired)
    command rm -f "$BL_STATE_DIR/agent-id" "$BL_STATE_DIR/env-id" \
                  "$BL_STATE_DIR/memstore-skills-id" "$BL_STATE_DIR/memstore-case-id" \
                  "$BL_STATE_DIR/case-id-counter" "$BL_STATE_DIR/case.current"
    bl_info "bl setup: state migrated; old per-key files removed"
    return "$BL_EX_OK"
}

# bl_setup_save_state — atomically write current BL_STATE_* shell vars to state.json.
# Caller must have populated BL_STATE_* (load_state initializes empty if first-run).
bl_setup_save_state() {
    local state_file="$BL_STATE_DIR/state.json"
    local tmp_state="$state_file.tmp.$$"
    local now
    now=$(command date -u +%Y-%m-%dT%H:%M:%SZ)
    # Preserve existing skills/files/files_pending_deletion/case_files/session_ids/case_id_counter/case_current
    # if state.json already exists; only overwrite top-level identity fields here.
    local existing="{}"
    [[ -f "$state_file" ]] && existing=$(command cat "$state_file")
    jq -n \
        --arg aid "${BL_STATE_AGENT_ID:-}" \
        --argjson av "${BL_STATE_AGENT_VERSION:-0}" \
        --arg env "${BL_STATE_ENV_ID:-}" \
        --arg cmid "${BL_STATE_MEMSTORE_CASE_ID:-}" \
        --arg ts "$now" \
        --argjson existing "$existing" \
        '{
            schema_version: 1,
            agent: {
                id: $aid,
                version: $av,
                skill_versions: ($existing.agent.skill_versions // {})
            },
            env_id: $env,
            skills: ($existing.skills // {}),
            files: ($existing.files // {}),
            files_pending_deletion: ($existing.files_pending_deletion // []),
            case_memstores: (
                if $cmid != "" then
                    ($existing.case_memstores // {}) + {"_legacy": $cmid}
                else
                    ($existing.case_memstores // {})
                end
            ),
            case_files: ($existing.case_files // {}),
            case_id_counter: ($existing.case_id_counter // {}),
            case_current: ($existing.case_current // ""),
            session_ids: ($existing.session_ids // {}),
            last_sync: $ts
        }' > "$tmp_state"
    command mv "$tmp_state" "$state_file"
    return "$BL_EX_OK"
}

bl_setup_provision() {
    # Per setup-flow.md §3 happy path, idempotent per §5.
    # Snapshot state-completeness BEFORE any ensure_* writes id files. Without
    # this snapshot, first-run ensure_* calls would write all four ids to disk
    # and a post-ensure check would mis-classify first-run as an idempotent
    # re-run, diverting full-seed to sync (404 on empty MANIFEST → first-run
    # hard-fail).
    local was_complete=""
    bl_setup_state_is_complete && was_complete="yes"
    # agent_id/env_id/case_id are populated via printf -v indirection inside the
    # ensure_* helpers; shellcheck cannot trace name-ref writes through $_out.
    # shellcheck disable=SC2034  # set indirectly via printf -v "$_out"
    local agent_id env_id skills_id case_id
    bl_setup_ensure_agent agent_id        || return $?
    bl_setup_ensure_env env_id            || return $?
    bl_setup_ensure_memstore skills_id "bl-skills"  'setup-memstore-create-skills.json' || return $?
    bl_setup_ensure_memstore case_id   "bl-case"    'setup-memstore-create-case.json'   || return $?
    if [[ "$was_complete" == "yes" ]]; then
        # All four ids existed on entry → re-run path.
        bl_info "bl setup: workspace already provisioned — skills sync only"
        bl_setup_sync "" || return $?
        printf '\n'
        printf 'bl setup: no-op (workspace already provisioned)\n'
        printf '  agent           %s\n' "$agent_id"
        printf '  env             %s\n' "$env_id"
        printf '  memstore-skills %s\n' "$skills_id"
        printf '  memstore-case   %s\n' "$case_id"
        bl_setup_print_exports
        return "$BL_EX_OK"
    fi
    # First-run or partial-resume → full seed via POST per skill.
    bl_setup_seed_skills "$skills_id"     || return $?
    bl_setup_print_exports
    return "$BL_EX_OK"
}

# bl_setup_state_is_complete — 0 if all four id files exist + non-empty.
bl_setup_state_is_complete() {
    local f
    for f in agent-id env-id memstore-skills-id memstore-case-id; do
        [[ -r "$BL_STATE_DIR/$f" ]] && [[ -s "$BL_STATE_DIR/$f" ]] || return 1
    done
    return 0
}

# bl_setup_ensure_agent <out-var> — populates out-var with id; returns 0/65/69/70/71.
bl_setup_ensure_agent() {
    local _out="$1"
    local id_file="$BL_STATE_DIR/agent-id"
    if [[ -r "$id_file" ]]; then
        local cached
        cached=$(command cat "$id_file")
        if [[ -n "$cached" ]]; then
            bl_debug "bl_setup: agent-id cached: $cached"
            printf -v "$_out" '%s' "$cached"
            return "$BL_EX_OK"
        fi
    fi
    local list_resp probed_id
    list_resp=$(bl_api_call GET "/v1/agents") || return $?   # API rejects ?name= filter — list all, filter client-side
    probed_id=$(printf '%s' "$list_resp" | jq -r '.data[] | select(.name == "bl-curator") | .id' | head -1)
    if [[ -z "$probed_id" ]]; then
        # Also match the smoketest agent name that was provisioned in initial workspace
        probed_id=$(printf '%s' "$list_resp" | jq -r '.data[] | select(.name | startswith("blacklight-curator")) | .id' | head -1)
    fi
    if [[ -n "$probed_id" ]]; then
        bl_info "bl setup: curator agent already exists ($probed_id) — caching"
        printf '%s' "$probed_id" > "$id_file"
        printf -v "$_out" '%s' "$probed_id"
        return "$BL_EX_OK"
    fi
    local body_file create_resp created_id
    body_file=$(mktemp)
    bl_setup_compose_agent_body > "$body_file" || { command rm -f "$body_file"; return "$BL_EX_PREFLIGHT_FAIL"; }
    create_resp=$(bl_api_call POST "/v1/agents" "$body_file")
    local rc=$?
    command rm -f "$body_file"
    if (( rc == 71 )); then
        bl_info "bl setup: agent already exists (409) — re-probing"
        list_resp=$(bl_api_call GET "/v1/agents") || return $?   # API rejects ?name= filter — list all, filter client-side
        probed_id=$(printf '%s' "$list_resp" | jq -r '.data[] | select(.name == "bl-curator") | .id' | head -1)
        [[ -z "$probed_id" ]] && probed_id=$(printf '%s' "$list_resp" | jq -r '.data[] | select(.name | startswith("blacklight-curator")) | .id' | head -1)
        [[ -z "$probed_id" ]] && { bl_error_envelope setup "agent created elsewhere but probe still empty"; return "$BL_EX_NOT_FOUND"; }
        printf '%s' "$probed_id" > "$id_file"
        printf -v "$_out" '%s' "$probed_id"
        return "$BL_EX_OK"
    fi
    (( rc != 0 )) && return $rc
    created_id=$(printf '%s' "$create_resp" | jq -r '.id // empty')
    [[ -z "$created_id" ]] && { bl_error_envelope setup "agent create returned no id"; return "$BL_EX_UPSTREAM_ERROR"; }
    printf '%s' "$created_id" > "$id_file"
    printf -v "$_out" '%s' "$created_id"
    bl_info "bl setup: agent created ($created_id)"
    return "$BL_EX_OK"
}

# bl_setup_ensure_env <out-var> — same shape as ensure_agent; targets /v1/environments.
bl_setup_ensure_env() {
    local _out="$1"
    local id_file="$BL_STATE_DIR/env-id"
    if [[ -r "$id_file" ]]; then
        local cached
        cached=$(command cat "$id_file")
        if [[ -n "$cached" ]]; then
            printf -v "$_out" '%s' "$cached"
            return "$BL_EX_OK"
        fi
    fi
    local body_file create_resp created_id
    body_file=$(mktemp)
    bl_setup_compose_env_body > "$body_file" || { command rm -f "$body_file"; return "$BL_EX_PREFLIGHT_FAIL"; }
    create_resp=$(bl_api_call POST "/v1/environments" "$body_file")
    local rc=$?
    command rm -f "$body_file"
    (( rc != 0 )) && return $rc
    created_id=$(printf '%s' "$create_resp" | jq -r '.id // empty')
    [[ -z "$created_id" ]] && { bl_error_envelope setup "env create returned no id"; return "$BL_EX_UPSTREAM_ERROR"; }
    printf '%s' "$created_id" > "$id_file"
    bl_info "bl setup: env created ($created_id)"
    printf -v "$_out" '%s' "$created_id"
    return "$BL_EX_OK"
}

# bl_setup_ensure_memstore <out-var> <name> <create-fixture-shape> — list-then-create.
bl_setup_ensure_memstore() {
    local _out="$1"
    local name="$2"
    # third arg unused at runtime — fixture filename is for test docs only
    local id_file_basename
    case "$name" in
        bl-skills) id_file_basename="memstore-skills-id" ;;
        bl-case)   id_file_basename="memstore-case-id"   ;;
        *)         bl_error_envelope setup "unknown memstore name: $name"; return "$BL_EX_USAGE" ;;
    esac
    local id_file="$BL_STATE_DIR/$id_file_basename"
    if [[ -r "$id_file" ]]; then
        local cached
        cached=$(command cat "$id_file")
        if [[ -n "$cached" ]]; then
            printf -v "$_out" '%s' "$cached"
            return "$BL_EX_OK"
        fi
    fi
    local list_resp probed_id
    list_resp=$(bl_api_call GET "/v1/memory_stores?name=$name") || return $?
    # Filter client-side by exact name — API ?name= may do prefix match or return all
    probed_id=$(printf '%s' "$list_resp" | jq -r --arg n "$name" '.data[] | select(.name == $n) | .id' | head -1)
    if [[ -n "$probed_id" ]]; then
        bl_info "bl setup: memstore $name already exists ($probed_id) — caching"
        printf '%s' "$probed_id" > "$id_file"
        printf -v "$_out" '%s' "$probed_id"
        return "$BL_EX_OK"
    fi
    local body_file create_resp created_id
    body_file=$(mktemp)
    jq -n --arg n "$name" '{name:$n}' > "$body_file"
    create_resp=$(bl_api_call POST "/v1/memory_stores" "$body_file")
    local rc=$?
    command rm -f "$body_file"
    (( rc != 0 )) && return $rc
    created_id=$(printf '%s' "$create_resp" | jq -r '.id // empty')
    [[ -z "$created_id" ]] && { bl_error_envelope setup "memstore $name create returned no id"; return "$BL_EX_UPSTREAM_ERROR"; }
    printf '%s' "$created_id" > "$id_file"
    bl_info "bl setup: memstore $name created ($created_id)"
    printf -v "$_out" '%s' "$created_id"
    return "$BL_EX_OK"
}

# bl_setup_compose_agent_body — emits agent-create JSON to stdout per setup-flow.md §4.2.
bl_setup_compose_agent_body() {
    local repo_root resolved
    resolved=$(readlink -f "$0" 2>/dev/null || printf '.')   # readlink -f may fail when $0 is relative / sourced — fallback to cwd
    repo_root="${BL_REPO_ROOT:-$(dirname "$resolved")}"
    local prompt_file="$repo_root/prompts/curator-agent.md"
    local step_schema="$repo_root/schemas/step.json"
    local def_schema="$repo_root/schemas/defense.json"
    local int_schema="$repo_root/schemas/intent.json"
    for f in "$prompt_file" "$step_schema" "$def_schema" "$int_schema"; do
        [[ -r "$f" ]] || { bl_error_envelope setup "input file missing: $f"; return "$BL_EX_PREFLIGHT_FAIL"; }
    done
    jq -n \
        --rawfile prompt "$prompt_file" \
        --slurpfile stepRaw "$step_schema" \
        --slurpfile defRaw  "$def_schema" \
        --slurpfile intRaw  "$int_schema" \
        '{
            name: "bl-curator",
            model: "claude-opus-4-7",
            system: $prompt,
            tools: [
                {type: "agent_toolset_20260401"},
                {
                    type: "custom",
                    name: "report_step",
                    description: "Emit a proposed blacklight wrapper action. One call per step.",
                    input_schema: ($stepRaw[0] | del(.["$schema"], .["$id"], .title))
                },
                {
                    type: "custom",
                    name: "synthesize_defense",
                    description: "Propose a defensive payload for this case.",
                    input_schema: ($defRaw[0] | del(.["$schema"], .["$id"], .title))
                },
                {
                    type: "custom",
                    name: "reconstruct_intent",
                    description: "Walk obfuscation layers of a mounted shell sample.",
                    input_schema: ($intRaw[0] | del(.["$schema"], .["$id"], .title))
                }
            ]
        }'
}

# bl_setup_compose_env_body — emits env-create JSON per setup-flow.md §4.3.
bl_setup_compose_env_body() {
    jq -n '{
        name: "bl-curator-env",
        type: "cloud",
        packages: {
            apt: ["apache2","libapache2-mod-security2","modsecurity-crs","yara","jq","zstd","duckdb","pandoc","weasyprint"]
        },
        networking: {type: "unrestricted"}
    }'
}

# bl_setup_seed_skills <skills-memstore-id> — POST every skills/**/*.md (excluding
# INDEX.md) plus a MANIFEST.json memory recording sha256 per file. Per setup-flow.md
# §4.5. Returns 0/65/69/70. Single-skill 4xx (e.g. 413 oversize) is warn-and-continue;
# >0 failures collapses into BL_EX_UPSTREAM_ERROR after the loop.
bl_setup_seed_skills() {
    local skills_id="$1"
    local repo_root
    repo_root=$(bl_setup_resolve_source) || return $?
    local skills_dir="$repo_root/skills"
    [[ -d "$skills_dir" ]] || { bl_error_envelope setup "skills/ not found at $skills_dir"; return "$BL_EX_PREFLIGHT_FAIL"; }
    local manifest_entries=""
    local count=0 fail=0
    local path rel sha
    while IFS= read -r path; do
        rel="${path#"$skills_dir"/}"
        [[ "$rel" == "INDEX.md" ]] && continue
        sha=$(command sha256sum "$path" | command awk '{print $1}')
        [[ -n "$manifest_entries" ]] && manifest_entries="$manifest_entries,"
        manifest_entries="$manifest_entries$(jq -n --arg p "$rel" --arg s "$sha" '{path:$p, sha256:$s}')"
        if ! bl_setup_post_memory "$skills_id" "$rel" "$path" "$sha"; then
            bl_warn "bl setup: failed to POST skill $rel"
            fail=$((fail + 1))
            continue
        fi
        count=$((count + 1))
    done < <(find "$skills_dir" -name '*.md' | sort)
    bl_info "bl setup: seeded $count skill(s); $fail failure(s)"
    (( fail > 0 )) && return "$BL_EX_UPSTREAM_ERROR"
    bl_setup_post_manifest "$skills_id" "$manifest_entries" || return $?
    return "$BL_EX_OK"
}

# bl_setup_post_memory <store-id> <key> <content-path> <sha256> — POST one memory
# (full body via mktemp body-file; cleaned on every exit path).
bl_setup_post_memory() {
    local store_id="$1"
    local key="$2"
    local content_path="$3"
    # sha arg ($4) ignored — API no longer accepts metadata field
    bl_mem_post "$store_id" "$key" "$content_path"
    return $?
}

# bl_setup_post_manifest <store-id> <comma-joined-entries> — POST MANIFEST.json memory.
bl_setup_post_manifest() {
    local store_id="$1"
    local entries="$2"
    local content_file
    content_file=$(mktemp)
    printf '[%s]' "$entries" > "$content_file"
    # Use bl_mem_patch so re-seeding re-run overwrites the existing MANIFEST
    bl_mem_patch "$store_id" "MANIFEST.json" "$content_file"
    local rc=$?
    command rm -f "$content_file"
    return $rc
}

# bl_setup_resolve_source — DESIGN.md §8.3 ordering:
#   0. honor BL_REPO_ROOT override (test infra + dev iteration)
#   1. cwd has skills/ + prompts/         → use cwd
#   2. $BL_REPO_URL set                   → shallow clone to $XDG_CACHE_HOME/blacklight/repo
#   3. default                            → clone https://github.com/rfxn/blacklight to cache
# Returns repo-root path on stdout; 0 on success, 65/69 on failure.
bl_setup_resolve_source() {
    if [[ -n "${BL_REPO_ROOT:-}" ]] && [[ -d "$BL_REPO_ROOT/skills" ]] && [[ -f "$BL_REPO_ROOT/prompts/curator-agent.md" ]]; then
        printf '%s' "$BL_REPO_ROOT"
        return "$BL_EX_OK"
    fi
    if [[ -d "./skills" ]] && [[ -f "./prompts/curator-agent.md" ]]; then
        printf '%s' "$(pwd)"
        return "$BL_EX_OK"
    fi
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/blacklight/repo"
    if [[ -n "${BL_REPO_URL:-}" ]]; then
        if [[ ! -d "$cache_dir/.git" ]]; then
            command mkdir -p "$(dirname "$cache_dir")"
            if ! git clone --depth 1 "$BL_REPO_URL" "$cache_dir" >/dev/null 2>&1; then   # network may be down — warn and fall through to default GitHub clone
                bl_warn "bl setup: BL_REPO_URL clone failed; falling through to default GitHub source"
            fi
        fi
        if [[ -d "$cache_dir/skills" ]] && [[ -f "$cache_dir/prompts/curator-agent.md" ]]; then
            printf '%s' "$cache_dir"
            return "$BL_EX_OK"
        fi
    fi
    if [[ ! -d "$cache_dir/.git" ]]; then
        command mkdir -p "$(dirname "$cache_dir")"
        if ! git clone --depth 1 https://github.com/rfxn/blacklight "$cache_dir" >/dev/null 2>&1; then   # network may be down — operator-facing remediation hint follows
            bl_error_envelope setup "default GitHub clone failed; check connectivity or set BL_REPO_URL"
            return "$BL_EX_UPSTREAM_ERROR"
        fi
    fi
    if [[ ! -d "$cache_dir/skills" ]] || [[ ! -f "$cache_dir/prompts/curator-agent.md" ]]; then
        bl_error_envelope setup "$cache_dir lacks skills/ + prompts/ after clone"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    printf '%s' "$cache_dir"
    return "$BL_EX_OK"
}

# bl_setup_check — emit per-resource status; exit 0 if all 4 ids cached, else 65.
bl_setup_check() {
    local missing=0
    local rr rr_label rr_canon pwd_canon
    rr=$(bl_setup_resolve_source 2>/dev/null) || rr="<unresolved>"   # check is operator-facing; never block on resolution
    # Label the discovery mechanism for operator clarity. Canonicalize both sides
    # so BL_REPO_ROOT="tests/.." resolves to the same path as pwd after cd.
    if [[ "$rr" == "<unresolved>" ]]; then
        rr_label="$rr"
    else
        rr_canon=$( cd "$rr" 2>/dev/null && pwd )   # cd may fail on bad path — fallback to raw label
        pwd_canon=$(pwd)
        if [[ -n "$rr_canon" && "$rr_canon" == "$pwd_canon" ]]; then
            rr_label="cwd ($rr)"
        else
            rr_label="$rr"
        fi
    fi
    printf 'bl setup --check (state=%s, source=%s):\n' "$BL_STATE_DIR" "$rr_label"
    local slot id_file
    for slot in agent env memstore-skills memstore-case; do
        # Map slot label → id-file basename. Dedicated case (no dead pre-assignment).
        case "$slot" in
            agent)             id_file="$BL_STATE_DIR/agent-id" ;;
            env)               id_file="$BL_STATE_DIR/env-id" ;;
            memstore-skills)   id_file="$BL_STATE_DIR/memstore-skills-id" ;;
            memstore-case)     id_file="$BL_STATE_DIR/memstore-case-id" ;;
        esac
        if [[ -r "$id_file" ]] && [[ -s "$id_file" ]]; then
            printf '  %s: ok (%s)\n' "$slot" "$(command cat "$id_file")"
        else
            printf '  %s: missing\n' "$slot"
            missing=$((missing + 1))
        fi
    done
    if (( missing > 0 )); then
        printf '\n%d resource(s) missing — run "bl setup" to provision.\n' "$missing"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    printf '\nall four resources provisioned.\n'
    return "$BL_EX_OK"
}

# bl_setup_sync <prune?> — diff local skills sha256 vs remote MANIFEST; POST/PATCH/DELETE
# only changed paths. --prune required to actually delete (default warn-only). Updates
# remote MANIFEST after diff applied. Per setup-flow.md §3 step 6 + §4.5 + DESIGN.md §8.4.
bl_setup_sync() {
    local prune="$1"
    local skills_id=""
    if [[ -r "$BL_STATE_DIR/memstore-skills-id" ]]; then
        skills_id=$(command cat "$BL_STATE_DIR/memstore-skills-id")
    fi
    [[ -z "$skills_id" ]] && { bl_error_envelope setup "memstore-skills-id not cached; run 'bl setup' first"; return "$BL_EX_NOT_FOUND"; }
    local repo_root
    repo_root=$(bl_setup_resolve_source) || return $?
    local skills_dir="$repo_root/skills"
    [[ -d "$skills_dir" ]] || { bl_error_envelope setup "skills/ not found at $skills_dir"; return "$BL_EX_PREFLIGHT_FAIL"; }
    # Build local manifest (sha256 by relative path)
    local local_manifest_file remote_manifest_file
    local_manifest_file=$(mktemp)
    remote_manifest_file=$(mktemp)
    bl_setup_compute_manifest "$skills_dir" > "$local_manifest_file"
    # Fetch remote manifest
    local remote_resp rc=0
    remote_resp=$(bl_mem_get "$skills_id" "MANIFEST.json") || rc=$?
    if (( rc != 0 )); then
        command rm -f "$local_manifest_file" "$remote_manifest_file"
        return $rc
    fi
    # .content is a stringified JSON array per setup-flow.md §4.5 — parse via fromjson
    printf '%s' "$remote_resp" | jq -r '.content // "[]"' > "$remote_manifest_file"
    # Diff: arrays of {path, sha256} → {add, modify, remove} keyed by path.
    local diff_json
    diff_json=$(jq -n \
        --slurpfile L "$local_manifest_file" \
        --slurpfile R "$remote_manifest_file" \
        '
            ($L[0]) as $lcl |
            ($R[0] | (if type == "string" then fromjson else . end)) as $rmt |
            ($lcl | map({(.path): .sha256}) | add // {}) as $lm |
            ($rmt | map({(.path): .sha256}) | add // {}) as $rm |
            {
                add:    [ $lm | to_entries[] | select($rm[.key] == null)        | .key ],
                modify: [ $lm | to_entries[] | select($rm[.key] != null and $rm[.key] != .value) | .key ],
                remove: [ $rm | to_entries[] | select($lm[.key] == null)        | .key ]
            }
        ')
    command rm -f "$local_manifest_file" "$remote_manifest_file"
    local n_add n_mod n_rm
    n_add=$(printf '%s' "$diff_json" | jq -r '.add    | length')
    n_mod=$(printf '%s' "$diff_json" | jq -r '.modify | length')
    n_rm=$(printf '%s' "$diff_json" | jq -r '.remove | length')
    if (( n_add == 0 && n_mod == 0 && n_rm == 0 )); then
        printf 'bl setup --sync: 0 changes (no skills delta)\n'
        return "$BL_EX_OK"
    fi
    printf 'bl setup --sync: %d add, %d modify, %d remove\n' "$n_add" "$n_mod" "$n_rm"
    local rel sha path
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        path="$skills_dir/$rel"
        sha=$(command sha256sum "$path" | command awk '{print $1}')
        bl_setup_post_memory "$skills_id" "$rel" "$path" "$sha" || bl_warn "bl setup --sync: POST failed for $rel"
    done < <(printf '%s' "$diff_json" | jq -r '.add[]')
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        path="$skills_dir/$rel"
        sha=$(command sha256sum "$path" | command awk '{print $1}')
        bl_setup_post_memory "$skills_id" "$rel" "$path" "$sha" || bl_warn "bl setup --sync: POST (modify) failed for $rel"
    done < <(printf '%s' "$diff_json" | jq -r '.modify[]')
    if [[ "$prune" == "yes" ]]; then
        while IFS= read -r rel; do
            [[ -z "$rel" ]] && continue
            bl_mem_delete_by_key "$skills_id" "$rel" || bl_warn "bl setup --sync: DELETE failed for $rel"
        done < <(printf '%s' "$diff_json" | jq -r '.remove[]')
    else
        (( n_rm > 0 )) && bl_info "bl setup --sync: $n_rm remote-only skill(s) — pass --prune to remove"
    fi
    # Update remote MANIFEST to reflect new state (post-add/modify; remove already prune-gated above)
    local entries
    entries=$(bl_setup_compute_manifest "$skills_dir" | jq -c '.' | sed -E 's/^\[//; s/\]$//')
    bl_setup_post_manifest "$skills_id" "$entries" || return $?
    return "$BL_EX_OK"
}

# bl_setup_compute_manifest <skills-dir> — emits JSON array of {path, sha256} on stdout.
bl_setup_compute_manifest() {
    local skills_dir="$1"
    local entries=""
    local path rel sha
    while IFS= read -r path; do
        rel="${path#"$skills_dir"/}"
        [[ "$rel" == "INDEX.md" ]] && continue
        sha=$(command sha256sum "$path" | command awk '{print $1}')
        [[ -n "$entries" ]] && entries="$entries,"
        entries="$entries$(jq -n --arg p "$rel" --arg s "$sha" '{path:$p, sha256:$s}')"
    done < <(find "$skills_dir" -name '*.md' | sort)
    printf '[%s]\n' "$entries"
}

bl_setup_print_exports() {
    printf '\n'
    printf 'export BL_READY=1\n'
    printf '\n'
    printf '# blacklight workspace provisioned. Persistent IDs written to %s/\n' "$BL_STATE_DIR"
    return "$BL_EX_OK"
}
