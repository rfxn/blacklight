# tests/helpers/skills-mock.bash — curl-shim extension for Skills API (M17 P4)
#
# Extends curator-mock.bash with multipart-aware routing for:
#   POST /v1/skills              → skills-create-success.json
#   POST /v1/skills/<id>/versions → skills-version-bump-success.json
#   GET  /v1/skills              → skills-list-empty.json (or caller-overridden)
#
# Usage: load 'helpers/curator-mock.bash'; load 'helpers/skills-mock.bash'
# Call bl_skills_mock_init after bl_curator_mock_init — it adds routes on top
# of the existing curl shim and rebuilds it with multipart-body support.
#
# Multipart handling: the mock curl shim detects -F flags (multipart form) and
# routes on METHOD + URL identically to JSON calls. Fixture body is returned
# as-is; http_status from route table.

bl_skills_mock_init() {
    # Must be called AFTER bl_curator_mock_init (needs BL_MOCK_BIN set).
    [[ -z "${BL_MOCK_BIN:-}" ]] && {
        printf 'ERROR: skills-mock.bash requires bl_curator_mock_init to be called first\n' >&2
        return 1
    }

    # Register default Skills API routes (callers may override via bl_curator_mock_add_route).
    # Route order: POST /v1/skills/<id>/versions before POST /v1/skills to ensure specificity.
    bl_curator_mock_add_route 'POST.*/v1/skills/[^/]+/versions' \
        'skills-version-bump-success.json' 200
    bl_curator_mock_add_route 'POST.*/v1/skills$' \
        'skills-create-success.json' 201
    bl_curator_mock_add_route 'GET.*/v1/skills$' \
        'skills-list-empty.json' 200

    # Rebuild the curl shim to understand -F (multipart) flags in addition to
    # --data-binary. The shim already handles URL + method extraction; we add
    # multipart body capture for BL_MOCK_REQUEST_LOG and skip content-type checks.
    _bl_skills_mock_rebuild_curl
}

_bl_skills_mock_rebuild_curl() {
    # Rebuild the curl shim (replacing whatever curator-mock wrote) to handle
    # -F multipart args alongside --data-binary JSON args. The routing table
    # (pattern/fixture/status CSVs) is inherited from curator-mock unchanged.
    cat > "$BL_MOCK_BIN/curl" <<'MOCKEOF'
#!/bin/bash
# skills-mock: URL-routing curl shim with multipart -F support
url=""
method="GET"
body_file=""
multipart_fields=()
prev=""
for arg in "$@"; do
    case "$prev" in
        -X) method="$arg" ;;
        --data-binary)
            case "$arg" in
                @*) body_file="${arg#@}" ;;
                *)  body_file="" ;;
            esac
            ;;
        -F) multipart_fields+=("$arg") ;;
    esac
    case "$arg" in https://*|http://*) url="$arg" ;; esac
    prev="$arg"
done
# BL_MOCK_REQUEST_LOG: append method + url + body/multipart summary
if [[ -n "${BL_MOCK_REQUEST_LOG:-}" ]]; then
    {
        printf '%s %s\n' "$method" "$url"
        if [[ -n "$body_file" && -r "$body_file" ]]; then
            if command -v jq >/dev/null 2>&1; then
                jq -c '.' < "$body_file" 2>/dev/null || tr -d ' \t\n' < "$body_file"
            else
                tr -d ' \t\n' < "$body_file"
            fi
            printf '\n'
        elif (( ${#multipart_fields[@]} > 0 )); then
            printf 'multipart: %s\n' "${multipart_fields[*]}"
        fi
    } >> "$BL_MOCK_REQUEST_LOG"
fi
IFS='|' read -ra patterns <<< "${BL_CURATOR_MOCK_PATTERNS_CSV:-}"
IFS='|' read -ra fixtures <<< "${BL_CURATOR_MOCK_FIXTURES_CSV:-}"
IFS='|' read -ra statuses <<< "${BL_CURATOR_MOCK_STATUSES_CSV:-}"
matched=0
# Skills API multipart contract validator (M17 PR-feedback bug #1):
# Live Anthropic API rejects:
#   - POST /v1/skills* without `files[]=@...` (singular `file=@...` returns 400
#     "No files provided. Please provide files using 'files[]' field.")
#   - POST /v1/skills (create) without a non-empty `display_title=...` field.
# Hermetic tests previously matched on URL+method alone, so those bugs landed
# green. This validator simulates the real API contract: any multipart POST
# to /v1/skills* missing the required fields returns the canonical 400 body.
if [[ "$method" == "POST" && "$url" == *"/v1/skills"* && "${#multipart_fields[@]}" -gt 0 ]]; then
    has_files_array=0
    has_singular_file=0
    has_display_title=0
    for _f in "${multipart_fields[@]}"; do
        case "$_f" in
            'files[]=@'*)         has_files_array=1 ;;
            'file=@'*)            has_singular_file=1 ;;
            'display_title='?*)   has_display_title=1 ;;
        esac
    done
    if (( has_singular_file == 1 && has_files_array == 0 )); then
        printf '%s\n%s' '{"type":"error","error":{"type":"invalid_request_error","message":"No files provided. Please provide files using '"'"'files[]'"'"' field."}}' '400'
        exit 0
    fi
    if (( has_files_array == 0 )); then
        printf '%s\n%s' '{"type":"error","error":{"type":"invalid_request_error","message":"files[] field is required"}}' '400'
        exit 0
    fi
    # Create endpoint (POST /v1/skills with no /<id>/versions suffix): require display_title.
    if [[ "$url" =~ /v1/skills([?#].*)?$ ]] && (( has_display_title == 0 )); then
        printf '%s\n%s' '{"type":"error","error":{"type":"invalid_request_error","message":"display_title field is required"}}' '400'
        exit 0
    fi
fi
_mock_wrap_for_list() {
    local raw="$1" wrap_url="$2"
    case "$wrap_url" in
        *'?path_prefix='*|*'&path_prefix='*) : ;;
        *) printf '%s' "$raw"; return ;;
    esac
    if printf '%s' "$raw" | jq -e '.data | type == "array"' >/dev/null 2>&1; then
        printf '%s' "$raw"; return
    fi
    local path_value mem_id
    path_value=$(printf '%s' "$wrap_url" | sed -n 's/.*[?&]path_prefix=\([^&]*\).*/\1/p' \
        | sed 's/%2F/\//g; s/%20/ /g')
    [[ "$path_value" != /* ]] && path_value="/$path_value"
    mem_id="mem_mock$(printf '%s' "$path_value" | sed 's|/|%2F|g')"
    printf '%s' "$raw" | jq --arg p "$path_value" --arg id "$mem_id" \
        '{data: [(. + {id: $id, path: $p})]}' 2>/dev/null \
        || printf '{"data":[{"id":"%s","path":"%s"}]}' "$mem_id" "$path_value"
}
for i in "${!patterns[@]}"; do
    if [[ -n "${patterns[i]}" && "${method} ${url}" =~ ${patterns[i]} ]]; then
        fixture_path="$BL_CURATOR_MOCK_FIXTURES_DIR/${fixtures[i]}"
        if [[ -r "$fixture_path" ]]; then
            body=$(< "$fixture_path")
        else
            body="{}"
        fi
        body=$(_mock_wrap_for_list "$body" "$url")
        printf '%s\n%s' "$body" "${statuses[i]}"
        matched=1
        break
    fi
done
if (( matched == 0 )); then
    default_fixture="${BL_CURATOR_MOCK_FIXTURES_DIR}/${BL_CURATOR_MOCK_DEFAULT_FIXTURE:-files-api-upload.json}"
    default_status="${BL_CURATOR_MOCK_DEFAULT_STATUS:-200}"
    if [[ -r "$default_fixture" ]]; then
        body=$(< "$default_fixture")
    else
        body="{}"
    fi
    body=$(_mock_wrap_for_list "$body" "$url")
    printf '%s\n%s' "$body" "$default_status"
fi
exit 0
MOCKEOF
    chmod +x "$BL_MOCK_BIN/curl"
}
