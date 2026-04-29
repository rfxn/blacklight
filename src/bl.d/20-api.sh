# shellcheck shell=bash
# ----------------------------------------------------------------------------
# API helpers — HTTPS wrappers for Anthropic Managed Agents endpoints.
# ----------------------------------------------------------------------------

# Beta-header constants — update here when Anthropic revises a beta family.
# BL_API_BETA_MA:     core Managed Agents header (sessions, memory stores, agents) — used in bl_api_call default
# BL_API_BETA_FILES:  Files API header — consumed in 23-files.sh (bl_files_create)
# BL_API_BETA_SKILLS: Skills API header — consumed in 84-setup.sh P4 (bl_api_call_multipart)
readonly BL_API_BETA_MA="managed-agents-2026-04-01"
# shellcheck disable=SC2034  # consumed in 23-files.sh; assembled bl sees it but shellcheck per-file does not
readonly BL_API_BETA_FILES="files-api-2025-04-14"
# shellcheck disable=SC2034  # consumed in 84-setup.sh P4; not yet referenced in this file
readonly BL_API_BETA_SKILLS="skills-2025-10-02,code-execution-2025-08-25,files-api-2025-04-14"

bl_api_call() {
    # Usage: bl_api_call <method> <url-suffix> [body-file] [beta-header]
    # Returns: 0 on 2xx; 65 on 401/403/other 4xx; 69 on 5xx (after retry); 70 on 429 (after retry)
    local method="$1"
    local url_suffix="$2"
    local body_file="${3:-}"
    local beta_header="${4:-$BL_API_BETA_MA}"
    local attempt=0
    local backoffs=(2 5 10 30)
    local resp http_status body body_args=()

    [[ -n "$body_file" ]] && body_args=(--data-binary "@$body_file")
    local beta_hdr='anthropic-beta: '"${beta_header}"

    while (( attempt < 4 )); do
        resp=$(curl -sS --max-time 30 -w '\n%{http_code}' -X "$method" \
            -H "x-api-key: $ANTHROPIC_API_KEY" \
            -H "anthropic-version: 2023-06-01" \
            -H "$beta_hdr" \
            -H "content-type: application/json" \
            ${body_args[@]+"${body_args[@]}"} \
            "https://api.anthropic.com${url_suffix}" 2>&1) || true   # retry handles curl exit; ${arr[@]+"${arr[@]}"} guards bash 4.1 set -u trap on empty arrays (CentOS 6 floor)
        http_status="${resp##*$'\n'}"
        body="${resp%$'\n'*}"
        # Cost-cap wire-up — append compact 2xx response JSON to BL_CURL_TRACE_LOG when set;
        # trace-runner's bl_check_cost_cap awks the file for usage.{input,output}_tokens per line.
        if [[ -n "${BL_CURL_TRACE_LOG:-}" ]] && [[ "$http_status" =~ ^2 ]]; then
            printf '%s\n' "$body" | jq -c '.' >> "$BL_CURL_TRACE_LOG" 2>/dev/null || true   # 2>/dev/null + || true: trace-log write failure or non-JSON body must not break the API call (cost-cap is observational only)
        fi
        case "$http_status" in
            2??)
                printf '%s' "$body"
                return "$BL_EX_OK"
                ;;
            401|403)
                bl_error_envelope api "authentication failed (HTTP $http_status)"
                bl_debug "bl_api_call: body=$body"
                return "$BL_EX_PREFLIGHT_FAIL"
                ;;
            429)
                attempt=$((attempt + 1))
                (( attempt >= 4 )) && { bl_error_envelope api "rate limited (HTTP 429) after retries"; return "$BL_EX_RATE_LIMITED"; }
                bl_debug "bl_api_call: 429, backing off ${backoffs[attempt-1]}s"
                sleep "${backoffs[attempt-1]}"
                ;;
            5??)
                attempt=$((attempt + 1))
                (( attempt >= 4 )) && { bl_error_envelope api "upstream error (HTTP $http_status) after retries"; return "$BL_EX_UPSTREAM_ERROR"; }
                bl_debug "bl_api_call: ${http_status}, backing off ${backoffs[attempt-1]}s"
                sleep "${backoffs[attempt-1]}"
                ;;
            409)
                bl_debug "bl_api_call: 409 conflict (already-exists or race) — body=$body"
                return "$BL_EX_CONFLICT"
                ;;
            4??)
                bl_error_envelope api "client error (HTTP $http_status)"
                bl_debug "bl_api_call: body=$body"
                return "$BL_EX_PREFLIGHT_FAIL"
                ;;
            *)
                attempt=$((attempt + 1))
                (( attempt >= 4 )) && { bl_error_envelope api "unexpected response (HTTP ${http_status:-?}) after retries"; return "$BL_EX_UPSTREAM_ERROR"; }
                bl_debug "bl_api_call: unexpected status ${http_status:-?}, retrying"
                sleep "${backoffs[attempt-1]}"
                ;;
        esac
    done
    return "$BL_EX_UPSTREAM_ERROR"
}

bl_poll_pending() {
    # bl_poll_pending <case-id> [--timeout <seconds>] [--interval <seconds>]
    # Polls bl-case/<case-id>/pending/ every <interval>s (default 3s); emits
    # each new step_id on stdout exactly once (deduped via seen-set). Exits 0
    # on either 3 consecutive empty-listing cycles (curator end_turn proxy)
    # or --timeout elapsed; propagates bl_api_call rc on auth/upstream/429.
    # BL_POLL_DRY_RUN=1 skips the loop entirely (returns 0).
    local case_id="$1"
    shift || true   # tolerate missing arg; case_id check below returns 64
    local interval=3
    local timeout_s=0
    while (( $# > 0 )); do
        case "$1" in
            --timeout)   timeout_s="$2"; shift 2 ;;
            --interval)  interval="$2"; shift 2 ;;
            *)           bl_error_envelope api "bl_poll_pending: unknown flag: $1"; return "$BL_EX_USAGE" ;;
        esac
    done
    [[ -z "$case_id" ]] && { bl_error_envelope api "bl_poll_pending: case-id required"; return "$BL_EX_USAGE"; }
    [[ "${BL_POLL_DRY_RUN:-}" == "1" ]] && return "$BL_EX_OK"

    local memstore_id
    memstore_id="${BL_MEMSTORE_CASE_ID:-$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf '')}"   # missing state-file → empty → 72
    [[ -z "$memstore_id" ]] && { bl_error_envelope api "bl_poll_pending: memstore-case-id not set"; return "$BL_EX_NOT_FOUND"; }

    local start_epoch
    start_epoch=$(command date +%s)
    local empty_cycles=0
    local seen_set_file
    seen_set_file=$(command mktemp)

    while :; do
        if (( timeout_s > 0 )); then
            local now_epoch
            now_epoch=$(command date +%s)
            if (( now_epoch - start_epoch >= timeout_s )); then
                bl_debug "bl_poll_pending: --timeout=$timeout_s reached"
                command rm -f "$seen_set_file"
                return "$BL_EX_OK"
            fi
        fi
        local list_body rc
        list_body=$(bl_mem_list "$memstore_id" "bl-case/$case_id/pending/")
        rc=$?
        if (( rc != 0 )); then
            command rm -f "$seen_set_file"
            return "$rc"
        fi
        local keys
        keys=$(printf '%s' "$list_body" | jq -r '.data[].key' 2>/dev/null) || keys=""   # malformed JSON → treat as empty cycle
        if [[ -z "$keys" ]]; then
            empty_cycles=$((empty_cycles + 1))
            if (( empty_cycles >= 3 )); then   # end_turn proxy: curator stopped writing
                bl_debug "bl_poll_pending: 3 empty cycles → exit"
                command rm -f "$seen_set_file"
                return "$BL_EX_OK"
            fi
        else
            empty_cycles=0
            local key sid
            while IFS= read -r key; do
                [[ -z "$key" ]] && continue
                sid="${key##*/}"
                sid="${sid%.json}"
                if ! command grep -qFx "$sid" "$seen_set_file" 2>/dev/null; then   # absent file/no-match → emit
                    printf '%s\n' "$sid"
                    printf '%s\n' "$sid" >> "$seen_set_file"
                fi
            done <<< "$keys"
        fi
        sleep "$interval"
    done
}

# ----------------------------------------------------------------------------
# Common helpers — M5-authored, consumed by M5/M6/M7 handlers.
# bl_jq_schema_check: jq-validate a JSON payload against a subset of
#   JSON Schema Draft 2020-12 (type, required, enum, properties, items).
#   --strict enables unknown-key rejection (additionalProperties: false).
# bl_ledger_append: flock-protected append to /var/lib/bl/ledger/<case>.jsonl.
# Note: bl_files_api_upload relocated to 23-files.sh as bl_files_create (M13 P2).
# ----------------------------------------------------------------------------

bl_jq_schema_check() {
    # bl_jq_schema_check <schema-path> <payload-path> [--strict] — 0/67
    local schema_path="$1"
    local payload_path="$2"
    local strict=""
    [[ "${3:-}" == "--strict" ]] && strict="yes"
    if [[ ! -r "$schema_path" ]]; then
        bl_error_envelope schema "schema not readable: $schema_path"
        return "$BL_EX_SCHEMA_VALIDATION_FAIL"
    fi
    if [[ ! -r "$payload_path" ]]; then
        bl_error_envelope schema "payload not readable: $payload_path"
        return "$BL_EX_SCHEMA_VALIDATION_FAIL"
    fi
    # jq subset: check required keys present, enum values valid, no extra keys if --strict.
    # Uses --slurpfile so schema and payload are each wrapped in an array; access via [0].
    # shellcheck disable=SC2016  # jq program uses $ENV.BL_JQ_STRICT, not shell expansion
    local jq_prog='
        $payload[0] as $pay |
        $schema[0] as $sch |
        ($sch.required // []) as $req |
        ($sch.properties // {}) as $props |
        ($req | map(. as $k | $pay | has($k)) | all) as $req_ok |
        ([ $props | to_entries[] |
            select(.value.enum) |
            ($pay[.key] // null) as $v |
            if $v == null then true
            else (.value.enum | index($v)) != null end
          ] | all) as $enum_ok |
        ( if $ENV.BL_JQ_STRICT == "yes" then
              ($pay | keys) - ($props | keys) | length == 0
          else true end ) as $addl_ok |
        $req_ok and $enum_ok and $addl_ok
    '
    local result
    result=$(BL_JQ_STRICT="${strict:-no}" jq -n \
        --slurpfile payload "$payload_path" \
        --slurpfile schema "$schema_path" \
        "$jq_prog" 2>/dev/null) || {   # jq parse error in schema/payload → treat as fail
        bl_error_envelope schema "jq evaluation failed on $payload_path"
        return "$BL_EX_SCHEMA_VALIDATION_FAIL"
    }
    if [[ "$result" != "true" ]]; then
        bl_error_envelope schema "payload failed schema: $payload_path"
        return "$BL_EX_SCHEMA_VALIDATION_FAIL"
    fi
    return "$BL_EX_OK"
}

# ----------------------------------------------------------------------------
# Memory-store adapter — API schema migration shim (M12 P6).
# Sole consumer is bl-case under Path C (M13 P2); bl-skills consumer paths shed.
# The managed-agents API changed from key-based to path-based memories:
#   key="bl-case/foo" → path="/bl-case/foo" (absolute)
#   GET by key → list by path_prefix + GET by mem_id
#   PATCH with if_content_sha256 → DELETE + POST (last-write-wins)
#   ?key_prefix= → ?path_prefix=
#
# bl_mem_post <store_id> <key> <content_file> — 0/65/69/70/71
# bl_mem_get  <store_id> <key>               — prints body to stdout; 0/65
# bl_mem_patch <store_id> <key> <content_file> [_sha_ignored] — 0/65/69/70
# bl_mem_delete_by_key <store_id> <key>       — 0/65
# bl_mem_list <store_id> <key_prefix>         — prints normalized JSON to stdout; 0/65
#   Normalized: each item in .data has a .key field = path with leading / stripped.
# ----------------------------------------------------------------------------

bl_mem_post() {
    local store_id="$1" key="$2" content_file="$3"
    local body_file
    body_file=$(mktemp)
    jq -n --arg p "/$key" --rawfile c "$content_file" \
        '{path:$p, content:$c}' > "$body_file"
    local rc
    bl_api_call POST "/v1/memory_stores/$store_id/memories" "$body_file" >/dev/null
    rc=$?
    command rm -f "$body_file"
    return $rc
}

bl_mem_get() {
    # bl_mem_get <store_id> <key> — fetch memory by path; prints full API body (with .content)
    local store_id="$1" key="$2"
    local encoded_path
    encoded_path=$(printf '%s' "/$key" | sed 's|/|%2F|g; s| |%20|g; s|@|%40|g')
    local list_body mem_id
    list_body=$(bl_api_call GET "/v1/memory_stores/$store_id/memories?path_prefix=${encoded_path}&limit=1") || return $?
    mem_id=$(printf '%s' "$list_body" | jq -r \
        --arg p "/$key" '.data[] | select((.path == $p) or (.key == ($p | ltrimstr("/")))) | .id' | head -1)
    if [[ -z "$mem_id" ]]; then
        bl_error_envelope api "memory not found: $key"
        return "$BL_EX_PREFLIGHT_FAIL"  # matches old 404→65 behaviour
    fi
    bl_api_call GET "/v1/memory_stores/$store_id/memories/$mem_id"
    return $?
}

bl_mem_patch() {
    # bl_mem_patch <store_id> <key> <content_file> [_sha_ignored] — delete + re-POST (last-write-wins)
    local store_id="$1" key="$2" content_file="$3"
    # Find existing mem_id
    local encoded_path mem_id list_body
    encoded_path=$(printf '%s' "/$key" | sed 's|/|%2F|g; s| |%20|g; s|@|%40|g')
    list_body=$(bl_api_call GET "/v1/memory_stores/$store_id/memories?path_prefix=${encoded_path}&limit=1") || return $?
    mem_id=$(printf '%s' "$list_body" | jq -r \
        --arg p "/$key" '.data[] | select((.path == $p) or (.key == ($p | ltrimstr("/")))) | .id' | head -1)
    if [[ -n "$mem_id" ]]; then
        bl_api_call DELETE "/v1/memory_stores/$store_id/memories/$mem_id" >/dev/null || true   # best-effort delete; POST below fails with conflict if needed
    fi
    bl_mem_post "$store_id" "$key" "$content_file"
    return $?
}

bl_mem_delete_by_key() {
    # bl_mem_delete_by_key <store_id> <key> — find mem_id by path then DELETE
    local store_id="$1" key="$2"
    local encoded_path list_body mem_id
    encoded_path=$(printf '%s' "/$key" | sed 's|/|%2F|g; s| |%20|g; s|@|%40|g')
    list_body=$(bl_api_call GET "/v1/memory_stores/$store_id/memories?path_prefix=${encoded_path}&limit=1") || return $?
    mem_id=$(printf '%s' "$list_body" | jq -r \
        --arg p "/$key" '.data[] | select((.path == $p) or (.key == ($p | ltrimstr("/")))) | .id' | head -1)
    [[ -z "$mem_id" ]] && return "$BL_EX_OK"   # already gone — treat as success
    bl_api_call DELETE "/v1/memory_stores/$store_id/memories/$mem_id" >/dev/null
    return $?
}

bl_mem_list() {
    # bl_mem_list <store_id> <key_prefix> — list memories under prefix; normalizes .path→.key
    local store_id="$1" key_prefix="$2"
    local encoded_prefix list_body
    encoded_prefix=$(printf '%s' "/$key_prefix" | sed 's| |%20|g; s|@|%40|g')
    list_body=$(bl_api_call GET "/v1/memory_stores/$store_id/memories?path_prefix=${encoded_prefix}") || return $?
    # Normalize .key field — production emits .path (with /), mock fixtures emit .key (no /).
    # Prefer .path when present; fall back to existing .key; never overwrite a real .key with null.
    printf '%s' "$list_body" | jq '
        .data |= map(. + {key: (if .path then (.path | ltrimstr("/")) else (.key // "") end)})
        | . + {data: .data}'
    return $?
}

# ----------------------------------------------------------------------------
# Preflight — DESIGN.md §8.1 contract:
# 1. Verify ANTHROPIC_API_KEY set + non-empty
# 2. Verify curl + jq available
# 3. Create state/ directly (NOT via bl_init_workdir)
# 4. Read cached agent-id; if present, return 0
# 5. Else probe GET /v1/agents (filter client-side by name=bl-curator)
# ----------------------------------------------------------------------------

