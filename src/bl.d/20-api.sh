# shellcheck shell=bash
# ----------------------------------------------------------------------------
# API helpers — HTTPS wrappers for Anthropic Managed Agents endpoints.
# bl_poll_pending is a skeleton; M5 drops in real read/write against
# bl-case/<case-id>/pending/.
# ----------------------------------------------------------------------------

bl_api_call() {
    # Usage: bl_api_call <method> <url-suffix> [body-file]
    # Returns: 0 on 2xx; 65 on 401/403/other 4xx; 69 on 5xx (after retry); 70 on 429 (after retry)
    local method="$1"
    local url_suffix="$2"
    local body_file="${3:-}"
    local attempt=0
    local backoffs=(2 5 10 30)
    local resp http_status body body_args=()

    [[ -n "$body_file" ]] && body_args=(--data-binary "@$body_file")

    while (( attempt < 4 )); do
        resp=$(curl -sS --max-time 30 -w '\n%{http_code}' -X "$method" \
            -H "x-api-key: $ANTHROPIC_API_KEY" \
            -H "anthropic-version: 2023-06-01" \
            -H "anthropic-beta: managed-agents-2026-04-01" \
            -H "content-type: application/json" \
            "${body_args[@]}" \
            "https://api.anthropic.com${url_suffix}" 2>&1) || true   # retry handles curl exit
        http_status="${resp##*$'\n'}"
        body="${resp%$'\n'*}"
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
    # Skeleton: 2s sleep-loop probing bl-case/<case-id>/pending/. M5 consumes.
    # $1 = case-id
    local case_id="$1"
    local cycles=0
    # shellcheck disable=SC2034  # consumed by M5
    local empty_cycles=0
    while (( cycles < 1 )); do   # M1: single-cycle skeleton; M5 widens to while true
        bl_debug "bl_poll_pending: probing case=$case_id (cycle=$cycles)"
        # M5 drops in: read bl-case/<case_id>/pending/ via bl_api_call;
        # for each new step, emit to stdout; on empty-pending-3-cycles or end_turn, break.
        empty_cycles=$((empty_cycles + 1))
        cycles=$((cycles + 1))
        sleep 0
    done
    return "$BL_EX_OK"
}

# ----------------------------------------------------------------------------
# Common helpers — M5-authored, consumed by M5/M6/M7 handlers.
# bl_jq_schema_check: jq-validate a JSON payload against a subset of
#   JSON Schema Draft 2020-12 (type, required, enum, properties, items).
#   --strict enables unknown-key rejection (additionalProperties: false).
# bl_ledger_append: flock-protected append to /var/lib/bl/ledger/<case>.jsonl.
# bl_files_api_upload: multipart POST to /v1/files; returns file_id.
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

bl_files_api_upload() {
    # bl_files_api_upload <mime> <file-path> — prints file_id on stdout; 0/69/70
    local mime="$1"
    local path="$2"
    local attempt=0
    local backoffs=(2 5 10)
    local resp http_status body
    if [[ ! -r "$path" ]]; then
        bl_error_envelope files "upload path not readable: $path"
        return "$BL_EX_UPSTREAM_ERROR"
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
        case "$http_status" in
            2??)
                printf '%s\n' "$body" | jq -r '.id'
                return "$BL_EX_OK"
                ;;
            429)
                attempt=$((attempt + 1))
                (( attempt >= 3 )) && { bl_error_envelope files "rate limited after retries"; return "$BL_EX_RATE_LIMITED"; }
                sleep "${backoffs[attempt-1]}"
                ;;
            5??)
                attempt=$((attempt + 1))
                (( attempt >= 3 )) && { bl_error_envelope files "upstream error (HTTP $http_status) after retries"; return "$BL_EX_UPSTREAM_ERROR"; }
                sleep "${backoffs[attempt-1]}"
                ;;
            *)
                bl_error_envelope files "files.create failed (HTTP ${http_status:-?})"
                bl_debug "bl_files_api_upload: body=$body"
                return "$BL_EX_UPSTREAM_ERROR"
                ;;
        esac
    done
    return "$BL_EX_UPSTREAM_ERROR"
}

# ----------------------------------------------------------------------------
# Preflight — DESIGN.md §8.1 contract:
# 1. Verify ANTHROPIC_API_KEY set + non-empty
# 2. Verify curl + jq available
# 3. Create state/ directly (NOT via bl_init_workdir)
# 4. Read cached agent-id; if present, return 0
# 5. Else probe GET /v1/agents?name=bl-curator; populated → cache; empty → 66
# ----------------------------------------------------------------------------

