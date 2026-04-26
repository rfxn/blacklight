# shellcheck shell=bash
# ----------------------------------------------------------------------------
# 24-skills.sh — Anthropic Skills API wrappers for blacklight routing Skills.
# Depends on: 10-log (bl_error_envelope, bl_debug), 20-api (bl_api_call).
# All functions return BL_EX_OK / BL_EX_UPSTREAM_ERROR / BL_EX_RATE_LIMITED per shared adapter contract.
# ----------------------------------------------------------------------------

bl_skills_create() {
    # bl_skills_create <name> <description-file> <body-file> — prints skill_id; 0/65/69/70
    local name="$1" desc_file="$2" body_file="$3"
    [[ -z "$name" || ! -r "$desc_file" || ! -r "$body_file" ]] && {
        bl_error_envelope skills "bl_skills_create: name + readable description + body required"
        return "$BL_EX_USAGE"
    }
    # Description size cap per spec §11b row 6 — Anthropic Skills API hard cap is 1024 chars
    local desc_size
    desc_size=$(command wc -c < "$desc_file" | command awk '{print $1}')
    if (( desc_size > 1024 )); then
        bl_error_envelope skills "description.txt exceeds 1024 chars: $desc_file ($desc_size)"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    local req_body
    req_body=$(command mktemp)
    jq -n \
        --arg n "$name" \
        --rawfile d "$desc_file" \
        --rawfile b "$body_file" \
        '{name:$n, description:$d, body:$b}' > "$req_body"
    local resp rc skill_id
    resp=$(bl_api_call POST "/v1/skills" "$req_body")
    rc=$?
    command rm -f "$req_body"
    (( rc != 0 )) && return $rc
    skill_id=$(printf '%s' "$resp" | jq -r '.id // empty')
    if [[ -z "$skill_id" ]]; then
        bl_error_envelope skills "skills.create returned empty id"
        return "$BL_EX_UPSTREAM_ERROR"
    fi
    printf '%s\n' "$skill_id"
    return "$BL_EX_OK"
}

bl_skills_versions_create() {
    # bl_skills_versions_create <skill-id> <description-file> <body-file> — prints version (epoch ms); 0/65/69/70
    local skill_id="$1" desc_file="$2" body_file="$3"
    [[ -z "$skill_id" || ! -r "$desc_file" || ! -r "$body_file" ]] && {
        bl_error_envelope skills "bl_skills_versions_create: skill-id + readable description + body required"
        return "$BL_EX_USAGE"
    }
    local desc_size
    desc_size=$(command wc -c < "$desc_file" | command awk '{print $1}')
    if (( desc_size > 1024 )); then
        bl_error_envelope skills "description.txt exceeds 1024 chars: $desc_file ($desc_size)"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    local req_body
    req_body=$(command mktemp)
    jq -n \
        --rawfile d "$desc_file" \
        --rawfile b "$body_file" \
        '{description:$d, body:$b}' > "$req_body"
    local resp rc version
    resp=$(bl_api_call POST "/v1/skills/$skill_id/versions" "$req_body")
    rc=$?
    command rm -f "$req_body"
    (( rc != 0 )) && return $rc
    version=$(printf '%s' "$resp" | jq -r '.version // empty')
    if [[ -z "$version" ]]; then
        bl_error_envelope skills "skills.versions.create returned empty version"
        return "$BL_EX_UPSTREAM_ERROR"
    fi
    printf '%s\n' "$version"
    return "$BL_EX_OK"
}

bl_skills_get() {
    # bl_skills_get <skill-id> — prints JSON metadata; 0/65/69/72
    local skill_id="$1"
    [[ -z "$skill_id" ]] && { bl_error_envelope skills "bl_skills_get: skill-id required"; return "$BL_EX_USAGE"; }
    bl_api_call GET "/v1/skills/$skill_id"
    return $?
}

bl_skills_delete() {
    # bl_skills_delete <skill-id> — idempotent (404→0); 0/65/69
    local skill_id="$1"
    [[ -z "$skill_id" ]] && { bl_error_envelope skills "bl_skills_delete: skill-id required"; return "$BL_EX_USAGE"; }
    local rc=0
    bl_api_call DELETE "/v1/skills/$skill_id" >/dev/null || rc=$?
    if (( rc == 0 )) || (( rc == 72 )); then
        return "$BL_EX_OK"
    fi
    return $rc
}
