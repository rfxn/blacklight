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

bl_setup_provision() {
    # Per setup-flow.md §3 happy path, idempotent per §5.
    # agent_id/env_id/case_id are populated via printf -v indirection inside the
    # ensure_* helpers; shellcheck cannot trace name-ref writes through $_out.
    # shellcheck disable=SC2034  # set indirectly via printf -v "$_out"
    local agent_id env_id skills_id case_id
    bl_setup_ensure_agent agent_id        || return $?
    bl_setup_ensure_env env_id            || return $?
    bl_setup_ensure_memstore skills_id "bl-skills"  'setup-memstore-create-skills.json' || return $?
    bl_setup_ensure_memstore case_id   "bl-case"    'setup-memstore-create-case.json'   || return $?
    bl_setup_seed_skills "$skills_id"     || return $?
    bl_setup_print_exports
    return "$BL_EX_OK"
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
    list_resp=$(bl_api_call GET "/v1/agents?name=bl-curator") || return $?
    probed_id=$(printf '%s' "$list_resp" | jq -r '.data[0].id // empty')
    if [[ -n "$probed_id" ]]; then
        bl_info "bl setup: agent bl-curator already exists ($probed_id) — caching"
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
        list_resp=$(bl_api_call GET "/v1/agents?name=bl-curator") || return $?
        probed_id=$(printf '%s' "$list_resp" | jq -r '.data[0].id // empty')
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
    probed_id=$(printf '%s' "$list_resp" | jq -r '.data[0].id // empty')
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

# bl_setup_seed_skills — Phase 3 expands; Phase 2 lands a no-op stub so
# provisioning succeeds end-to-end without skill writes.
bl_setup_seed_skills() {
    bl_debug "bl_setup_seed_skills: Phase 3 will replace with MANIFEST-driven POST loop"
    return "$BL_EX_OK"
}

# bl_setup_check / bl_setup_sync — Phase 4 replaces with real implementations.
bl_setup_check() { bl_error_envelope setup "--check not yet implemented (Phase 4)"; return "$BL_EX_USAGE"; }
bl_setup_sync()  { bl_error_envelope setup "--sync not yet implemented (Phase 3)";  return "$BL_EX_USAGE"; }

bl_setup_print_exports() {
    printf '\n'
    printf 'export BL_READY=1\n'
    printf '\n'
    printf '# blacklight workspace provisioned. Persistent IDs written to %s/\n' "$BL_STATE_DIR"
    return "$BL_EX_OK"
}
