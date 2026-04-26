# shellcheck shell=bash
# ----------------------------------------------------------------------------
# 23-files.sh — Anthropic Files API wrappers for blacklight workspace + per-case Files.
# Depends on: 10-log (bl_error_envelope, bl_debug), 20-api (bl_api_call).
# All functions return BL_EX_OK / BL_EX_UPSTREAM_ERROR / BL_EX_RATE_LIMITED per shared adapter contract.
# ----------------------------------------------------------------------------

bl_files_create() {
    # bl_files_create <mime> <file-path> — prints workspace file_id on stdout; 0/65/69/70
    # Replaces bl_files_api_upload from 20-api.sh (M12 era). Same multipart POST shape.
    local mime="$1"
    local path="$2"
    local attempt=0
    local backoffs=(2 5 10)
    local resp http_status body file_id
    if [[ ! -r "$path" ]]; then
        bl_error_envelope files "upload path not readable: $path"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    # Pre-upload size guard — refuse files >500 MB per spec §11b row 12.
    local size_bytes
    size_bytes=$(command stat -c '%s' "$path" 2>/dev/null || command stat -f '%z' "$path" 2>/dev/null || printf '0')   # GNU then BSD; both fail → 0 → succeed (defensive only)
    if (( size_bytes > 524288000 )); then
        bl_error_envelope files "file exceeds 500 MB cap: $path ($size_bytes bytes)"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    while (( attempt < 3 )); do
        resp=$(curl -sS --max-time 60 -w '\n%{http_code}' -X POST \
            -H "x-api-key: $ANTHROPIC_API_KEY" \
            -H "anthropic-version: 2023-06-01" \
            -H "anthropic-beta: files-api-2025-04-14,managed-agents-2026-04-01" \
            -F "file=@$path;type=$mime" \
            "https://api.anthropic.com/v1/files" 2>&1) || true   # retry handles curl exit
        http_status="${resp##*$'\n'}"
        body="${resp%$'\n'*}"
        if [[ -n "${BL_CURL_TRACE_LOG:-}" ]] && [[ "$http_status" =~ ^2 ]]; then
            printf '%s\n' "$body" | jq -c '.' >> "$BL_CURL_TRACE_LOG" 2>/dev/null || true   # 2>/dev/null + || true: trace-log write failure must not break the API call (cost-cap is observational)
        fi
        case "$http_status" in
            2??)
                file_id=$(printf '%s' "$body" | jq -r '.id // empty')
                if [[ -z "$file_id" ]]; then
                    bl_error_envelope files "files.create returned empty file_id"
                    return "$BL_EX_UPSTREAM_ERROR"
                fi
                printf '%s\n' "$file_id"
                return "$BL_EX_OK"
                ;;
            401|403)
                bl_error_envelope files "files.create auth failed (HTTP $http_status)"
                bl_debug "bl_files_create: body=$body"
                return "$BL_EX_PREFLIGHT_FAIL"
                ;;
            429)
                attempt=$((attempt + 1))
                (( attempt >= 3 )) && { bl_error_envelope files "files.create rate limited after retries"; return "$BL_EX_RATE_LIMITED"; }
                sleep "${backoffs[attempt-1]}"
                ;;
            5??)
                attempt=$((attempt + 1))
                (( attempt >= 3 )) && { bl_error_envelope files "files.create upstream error (HTTP $http_status) after retries"; return "$BL_EX_UPSTREAM_ERROR"; }
                sleep "${backoffs[attempt-1]}"
                ;;
            *)
                bl_error_envelope files "files.create failed (HTTP ${http_status:-?})"
                bl_debug "bl_files_create: body=$body"
                return "$BL_EX_UPSTREAM_ERROR"
                ;;
        esac
    done
    return "$BL_EX_UPSTREAM_ERROR"
}

bl_files_delete() {
    # bl_files_delete <file-id> — DELETE /v1/files/<id>; idempotent (404→0); 0/65/69
    local file_id="$1"
    [[ -z "$file_id" ]] && { bl_error_envelope files "bl_files_delete: file-id required"; return "$BL_EX_USAGE"; }
    local rc=0
    bl_api_call DELETE "/v1/files/$file_id" >/dev/null || rc=$?
    # Treat 404 (NOT_FOUND) and OK as success — idempotent delete semantics
    if (( rc == 0 )) || (( rc == 72 )); then
        return "$BL_EX_OK"
    fi
    return $rc
}

bl_files_attach_to_session() {
    # bl_files_attach_to_session <session-id> <file-id> <mount-path> — prints sesrsc_id; 0/65/69/71
    local session_id="$1" file_id="$2" mount_path="$3"
    [[ -z "$session_id" || -z "$file_id" || -z "$mount_path" ]] && {
        bl_error_envelope files "bl_files_attach_to_session: 3 args required"
        return "$BL_EX_USAGE"
    }
    local body_file
    body_file=$(command mktemp)
    jq -n --arg fid "$file_id" --arg mp "$mount_path" \
        '{type:"file", file_id:$fid, mount_path:$mp}' > "$body_file"
    local resp rc
    resp=$(bl_api_call POST "/v1/sessions/$session_id/resources" "$body_file")
    rc=$?
    command rm -f "$body_file"
    (( rc != 0 )) && return $rc
    local sesrsc_id
    sesrsc_id=$(printf '%s' "$resp" | jq -r '.id // empty')
    if [[ -z "$sesrsc_id" ]]; then
        bl_error_envelope files "sessions.resources.add returned empty id"
        return "$BL_EX_UPSTREAM_ERROR"
    fi
    printf '%s\n' "$sesrsc_id"
    return "$BL_EX_OK"
}

bl_files_detach_from_session() {
    # bl_files_detach_from_session <session-id> <sesrsc-id> — DELETE; idempotent (404→0); 0/65/69
    local session_id="$1" sesrsc_id="$2"
    [[ -z "$session_id" || -z "$sesrsc_id" ]] && {
        bl_error_envelope files "bl_files_detach_from_session: 2 args required"
        return "$BL_EX_USAGE"
    }
    local rc=0
    bl_api_call DELETE "/v1/sessions/$session_id/resources/$sesrsc_id" >/dev/null || rc=$?
    if (( rc == 0 )) || (( rc == 72 )); then
        return "$BL_EX_OK"
    fi
    return $rc
}

bl_files_list_workspace() {
    # bl_files_list_workspace [path-prefix] — prints JSON list; for setup --gc + dry-run; 0/65/69
    local path_prefix="${1:-}"
    local url="/v1/files"
    if [[ -n "$path_prefix" ]]; then
        # sed-only URL-encode: / → %2F, space → %20 (sufficient for mount-path prefixes)
        local encoded
        encoded=$(printf '%s' "$path_prefix" | sed 's|/|%2F|g; s| |%20|g')
        url="${url}?path_prefix=${encoded}"
    fi
    bl_api_call GET "$url"
    return $?
}
