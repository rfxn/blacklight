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
    # bl_skills_delete <skill-id> — cascade-delete versions then skill; idempotent on 404.
    # Skills API requires:
    #   1. The Skills beta header (`skills-2025-10-02,...`) on every endpoint;
    #      MA header returns 404 even on existing skills (different namespace).
    #   2. All versions deleted before the skill itself: `Cannot delete skill with
    #      existing versions. Delete all versions first.` (HTTP 400).
    # 404 (skill already gone) → treat as success so reset / gc paths are idempotent
    # against partial prior runs.
    local skill_id="$1"
    [[ -z "$skill_id" ]] && { bl_error_envelope skills "bl_skills_delete: skill-id required"; return "$BL_EX_USAGE"; }
    local list_resp version_id versions_rc=0
    list_resp=$(bl_api_call GET "/v1/skills/$skill_id/versions" "" "$BL_API_BETA_SKILLS" 2>/dev/null) || versions_rc=$?   # 2>/dev/null + capture rc: 404 means the skill is already gone — treat as success below
    if (( versions_rc == 0 )); then
        while IFS= read -r version_id; do
            [[ -z "$version_id" ]] && continue
            bl_api_call DELETE "/v1/skills/$skill_id/versions/$version_id" "" "$BL_API_BETA_SKILLS" >/dev/null || true   # || true: skip-and-continue is intentional; the final skill-delete will surface any genuine residue with a real error code
        done < <(printf '%s' "$list_resp" | jq -r '.data[]?.version // empty' 2>/dev/null)   # 2>/dev/null: malformed list response → empty stream → empty cascade, defer error to skill-delete
    fi
    local rc=0
    bl_api_call DELETE "/v1/skills/$skill_id" "" "$BL_API_BETA_SKILLS" >/dev/null || rc=$?
    # 404 (BL_EX_PREFLIGHT_FAIL=65 from generic-4xx mapping) → idempotent success when
    # the skill no longer exists (another reset already removed it, or workspace was
    # GC'd between adoption and delete).
    if (( rc == 0 )); then
        return "$BL_EX_OK"
    fi
    if (( rc == BL_EX_PREFLIGHT_FAIL )); then
        # Confirm the skill is genuinely gone (vs. an auth/4xx other than 404) by GET-probing.
        if ! bl_api_call GET "/v1/skills/$skill_id" "" "$BL_API_BETA_SKILLS" >/dev/null 2>&1; then
            return "$BL_EX_OK"
        fi
    fi
    return "$rc"
}
