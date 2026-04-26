# tests/helpers/curator-mock.bash — curl-shim for M5 consult/run/case tests
#
# Consumed by tests/05-consult-run-case.bats. Routes by URL-regex against
# $BL_CURATOR_MOCK_ROUTE_PATTERNS[] and $BL_CURATOR_MOCK_ROUTE_FIXTURES[]
# parallel-indexed arrays. Returns fixture file content as the HTTP body,
# HTTP status from a $BL_CURATOR_MOCK_ROUTE_STATUS[] parallel array.
#
# Route priority: explicit patterns are checked in registration order first.
# If no pattern matches, the default fixture/status is used (set by
# bl_curator_mock_set_response). This ensures specific routes always win.
#
# M5 spec ref: tests/helpers/curator-mock.bash (spec §4.1 table row 2)

bl_curator_mock_init() {
    BL_MOCK_BIN="${BL_MOCK_BIN:-$(mktemp -d)/mock-bin}"
    mkdir -p "$BL_MOCK_BIN"
    BL_CURATOR_MOCK_FIXTURES_DIR="${BL_CURATOR_MOCK_FIXTURES_DIR:-$BATS_TEST_DIRNAME/fixtures}"
    BL_CURATOR_MOCK_ROUTE_PATTERNS=()
    BL_CURATOR_MOCK_ROUTE_FIXTURES=()
    BL_CURATOR_MOCK_ROUTE_STATUS=()
    # Reset CSV exports
    BL_CURATOR_MOCK_PATTERNS_CSV=""
    BL_CURATOR_MOCK_FIXTURES_CSV=""
    BL_CURATOR_MOCK_STATUSES_CSV=""
    # Default response when no explicit route matches
    BL_CURATOR_MOCK_DEFAULT_FIXTURE="files-api-upload.json"
    BL_CURATOR_MOCK_DEFAULT_STATUS="200"
    cat > "$BL_MOCK_BIN/curl" <<'MOCKEOF'
#!/bin/bash
# curator-mock: URL-routing curl shim
# Explicit patterns checked first; falls back to DEFAULT if none match.
# Optional: when BL_MOCK_REQUEST_LOG is set, every invocation appends a record
# of <METHOD> <URL> + the bound body (read from --data-binary @<file>) to that
# path. Used by --sync delta-verification tests to assert exactly which keys
# were POSTed (M11 P13).
url=""
method="GET"
body_file=""
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
    esac
    case "$arg" in https://*|http://*) url="$arg" ;; esac
    prev="$arg"
done
if [[ -n "${BL_MOCK_REQUEST_LOG:-}" ]]; then
    {
        printf '%s %s\n' "$method" "$url"
        if [[ -n "$body_file" && -r "$body_file" ]]; then
            # Compact via jq so consumers can grep '"key":"foo/a.md"' regardless
            # of whether the producer pretty-printed. Fallback: strip whitespace
            # if jq is missing or rejects the body.
            if command -v jq >/dev/null 2>&1; then
                jq -c '.' < "$body_file" 2>/dev/null || tr -d ' \t\n' < "$body_file"
            else
                tr -d ' \t\n' < "$body_file"
            fi
            printf '\n'
        fi
    } >> "$BL_MOCK_REQUEST_LOG"
fi
IFS='|' read -ra patterns <<< "${BL_CURATOR_MOCK_PATTERNS_CSV:-}"
IFS='|' read -ra fixtures <<< "${BL_CURATOR_MOCK_FIXTURES_CSV:-}"
IFS='|' read -ra statuses <<< "${BL_CURATOR_MOCK_STATUSES_CSV:-}"
matched=0
# M12 P5.5 compat: when adapter (bl_mem_*) issues list-style query (?path_prefix=), wrap
# single-object fixtures in {"data":[fixture+id+path]} so the new adapter can extract mem_id.
# Old fixtures stay untouched; mock auto-shapes the response based on URL form.
_mock_wrap_for_list() {
    local raw="$1" wrap_url="$2"
    case "$wrap_url" in
        *'?path_prefix='*|*'&path_prefix='*) : ;;
        *) printf '%s' "$raw"; return ;;
    esac
    if printf '%s' "$raw" | jq -e '.data | type == "array"' >/dev/null 2>&1; then
        printf '%s' "$raw"; return   # already list-shaped — leave alone
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
    default_fixture="$BL_CURATOR_MOCK_FIXTURES_DIR/${BL_CURATOR_MOCK_DEFAULT_FIXTURE:-files-api-upload.json}"
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
    PATH="$BL_MOCK_BIN:$PATH"
    export PATH BL_CURATOR_MOCK_FIXTURES_DIR
    export BL_CURATOR_MOCK_PATTERNS_CSV BL_CURATOR_MOCK_FIXTURES_CSV BL_CURATOR_MOCK_STATUSES_CSV
    export BL_CURATOR_MOCK_DEFAULT_FIXTURE BL_CURATOR_MOCK_DEFAULT_STATUS
}

bl_curator_mock_add_route() {
    # bl_curator_mock_add_route <url-regex> <fixture-filename> <http-status>
    BL_CURATOR_MOCK_ROUTE_PATTERNS+=("$1")
    BL_CURATOR_MOCK_ROUTE_FIXTURES+=("$2")
    BL_CURATOR_MOCK_ROUTE_STATUS+=("$3")
    # Rebuild CSV exports using printf to avoid IFS="$IFS" variable bleeding
    local old_ifs="$IFS"
    IFS='|'
    BL_CURATOR_MOCK_PATTERNS_CSV="${BL_CURATOR_MOCK_ROUTE_PATTERNS[*]}"
    BL_CURATOR_MOCK_FIXTURES_CSV="${BL_CURATOR_MOCK_ROUTE_FIXTURES[*]}"
    BL_CURATOR_MOCK_STATUSES_CSV="${BL_CURATOR_MOCK_ROUTE_STATUS[*]}"
    IFS="$old_ifs"
    export BL_CURATOR_MOCK_PATTERNS_CSV BL_CURATOR_MOCK_FIXTURES_CSV BL_CURATOR_MOCK_STATUSES_CSV
}

bl_curator_mock_add_route_sequence() {
    # bl_curator_mock_add_route_sequence <url-regex> <fixture:status> [<fixture:status> ...]
    # Registers a stateful route that serves responses in order on successive calls.
    # Each positional argument after the URL regex is "<fixture-filename>:<http-status>".
    # A per-route counter file in $BL_MOCK_BIN tracks which response is next.
    # After the last entry is consumed, the final entry repeats on further calls.
    local pattern="$1"; shift
    local seq_dir="$BL_MOCK_BIN/seq"
    mkdir -p "$seq_dir"
    # Derive a safe filename key from the pattern
    local key
    key=$(printf '%s' "$pattern" | tr -cs 'a-zA-Z0-9' '_')
    local seq_fixtures=() seq_statuses=()
    local entry fixture status
    for entry in "$@"; do
        fixture="${entry%%:*}"
        status="${entry##*:}"
        seq_fixtures+=("$fixture")
        seq_statuses+=("$status")
    done
    # Write the sequence file: one "fixture:status" per line
    local seq_file="$seq_dir/${key}.seq"
    printf '' > "$seq_file"
    for entry in "$@"; do
        printf '%s\n' "$entry" >> "$seq_file"
    done
    # Write the counter file (0-indexed)
    printf '0' > "$seq_dir/${key}.cnt"
    # Rewrite the curl shim to support sequence routes via per-route counter files.
    # Sequence routes are stored in $BL_MOCK_BIN/seq/<key>.seq and checked before
    # the standard pattern table. The key is derived the same way as above.
    export BL_MOCK_SEQ_DIR="$seq_dir"
    # Register the pattern in the standard table with a sentinel fixture so the
    # routing loop fires; actual fixture resolution happens via the seq override
    # in the extended curl shim below.
    _bl_curator_mock_rebuild_curl_with_seq
    # Also register in the standard route table with a special "__seq__:<key>" marker
    BL_CURATOR_MOCK_ROUTE_PATTERNS+=("$pattern")
    BL_CURATOR_MOCK_ROUTE_FIXTURES+=("__seq__:${key}")
    BL_CURATOR_MOCK_ROUTE_STATUS+=("200")
    local old_ifs="$IFS"
    IFS='|'
    BL_CURATOR_MOCK_PATTERNS_CSV="${BL_CURATOR_MOCK_ROUTE_PATTERNS[*]}"
    BL_CURATOR_MOCK_FIXTURES_CSV="${BL_CURATOR_MOCK_ROUTE_FIXTURES[*]}"
    BL_CURATOR_MOCK_STATUSES_CSV="${BL_CURATOR_MOCK_ROUTE_STATUS[*]}"
    IFS="$old_ifs"
    export BL_CURATOR_MOCK_PATTERNS_CSV BL_CURATOR_MOCK_FIXTURES_CSV BL_CURATOR_MOCK_STATUSES_CSV
}

_bl_curator_mock_rebuild_curl_with_seq() {
    # Rebuild the curl shim to handle __seq__:<key> fixture markers by reading
    # the per-route counter and advancing it on each call.
    cat > "$BL_MOCK_BIN/curl" <<'MOCKEOF'
#!/bin/bash
# curator-mock: URL-routing curl shim (sequence-aware)
url=""
method="GET"
body_file=""
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
    esac
    case "$arg" in https://*|http://*) url="$arg" ;; esac
    prev="$arg"
done
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
        fi
    } >> "$BL_MOCK_REQUEST_LOG"
fi
IFS='|' read -ra patterns <<< "${BL_CURATOR_MOCK_PATTERNS_CSV:-}"
IFS='|' read -ra fixtures <<< "${BL_CURATOR_MOCK_FIXTURES_CSV:-}"
IFS='|' read -ra statuses <<< "${BL_CURATOR_MOCK_STATUSES_CSV:-}"
matched=0
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
        fixture_entry="${fixtures[i]}"
        # Sequence route: __seq__:<key>
        if [[ "$fixture_entry" == __seq__:* ]]; then
            key="${fixture_entry#__seq__:}"
            seq_dir="${BL_MOCK_SEQ_DIR:-$BL_MOCK_BIN/seq}"
            seq_file="$seq_dir/${key}.seq"
            cnt_file="$seq_dir/${key}.cnt"
            cnt=$(cat "$cnt_file" 2>/dev/null || printf '0')
            total=$(wc -l < "$seq_file" 2>/dev/null || printf '1')
            # Clamp to last entry after sequence is exhausted
            (( cnt >= total )) && cnt=$(( total - 1 ))
            # Read line (1-indexed via sed)
            line=$(sed -n "$(( cnt + 1 ))p" "$seq_file")
            fixture_name="${line%%:*}"
            http_status="${line##*:}"
            # Advance counter (stay at last if exhausted)
            (( cnt + 1 < total )) && printf '%d' $(( cnt + 1 )) > "$cnt_file"
        else
            fixture_name="$fixture_entry"
            http_status="${statuses[i]}"
        fi
        fixture_path="${BL_CURATOR_MOCK_FIXTURES_DIR}/${fixture_name}"
        if [[ -r "$fixture_path" ]]; then
            body=$(< "$fixture_path")
        else
            body="{}"
        fi
        body=$(_mock_wrap_for_list "$body" "$url")
        printf '%s\n%s' "$body" "$http_status"
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
    export BL_MOCK_SEQ_DIR
}

bl_curator_mock_set_response() {
    # Set the default (catch-all) response used when no explicit route matches.
    # Does NOT clear existing specific routes — call this before add_route to set
    # the fallback, or after to just change the fallback.
    BL_CURATOR_MOCK_DEFAULT_FIXTURE="$1"
    BL_CURATOR_MOCK_DEFAULT_STATUS="${2:-200}"
    export BL_CURATOR_MOCK_DEFAULT_FIXTURE BL_CURATOR_MOCK_DEFAULT_STATUS
}

bl_curator_mock_reset_routes() {
    # Clear all explicit routes (leaves default unchanged).
    BL_CURATOR_MOCK_ROUTE_PATTERNS=()
    BL_CURATOR_MOCK_ROUTE_FIXTURES=()
    BL_CURATOR_MOCK_ROUTE_STATUS=()
    BL_CURATOR_MOCK_PATTERNS_CSV=""
    BL_CURATOR_MOCK_FIXTURES_CSV=""
    BL_CURATOR_MOCK_STATUSES_CSV=""
    export BL_CURATOR_MOCK_PATTERNS_CSV BL_CURATOR_MOCK_FIXTURES_CSV BL_CURATOR_MOCK_STATUSES_CSV
}

bl_curator_mock_teardown() {
    [[ -n "${BL_MOCK_BIN:-}" ]] && rm -rf "${BL_MOCK_BIN%/mock-bin}"
    unset BL_MOCK_BIN BL_CURATOR_MOCK_PATTERNS_CSV BL_CURATOR_MOCK_FIXTURES_CSV BL_CURATOR_MOCK_STATUSES_CSV
    unset BL_CURATOR_MOCK_ROUTE_PATTERNS BL_CURATOR_MOCK_ROUTE_FIXTURES BL_CURATOR_MOCK_ROUTE_STATUS
    unset BL_CURATOR_MOCK_FIXTURES_DIR BL_CURATOR_MOCK_DEFAULT_FIXTURE BL_CURATOR_MOCK_DEFAULT_STATUS
}

# Files API mocks — fixtures live in tests/fixtures/files-api-*.json

_mock_files_api_upload_call_count() {
    # Returns the number of times _mock_files_api_upload was invoked.
    # Counter file lives in BATS_TEST_TMPDIR so it is per-test isolated.
    local cfile="${BATS_TEST_TMPDIR:-/tmp}/_mock_files_upload_calls"
    if [[ -f "$cfile" ]]; then
        command wc -c < "$cfile" | command awk '{print $1}'
    else
        printf '0'
    fi
}

_mock_files_api_upload() {
    # Increment call counter (one byte per call)
    printf 'x' >> "${BATS_TEST_TMPDIR:-/tmp}/_mock_files_upload_calls"
    cat "${BATS_TEST_DIRNAME}/fixtures/files-api-create.json"
    printf '\n200'
}

_mock_files_api_attach_call_count() {
    # Returns the number of times _mock_files_api_attach was invoked.
    local cfile="${BATS_TEST_TMPDIR:-/tmp}/_mock_files_attach_calls"
    if [[ -f "$cfile" ]]; then
        command wc -c < "$cfile" | command awk '{print $1}'
    else
        printf '0'
    fi
}

_mock_files_api_attach() {
    # Increment call counter (one byte per call)
    printf 'x' >> "${BATS_TEST_TMPDIR:-/tmp}/_mock_files_attach_calls"
    cat "${BATS_TEST_DIRNAME}/fixtures/sessions-resources-add.json"
    printf '\n200'
}

_mock_files_api_detach() {
    printf '\n200'
}

# Skills API mocks — fixtures live in tests/fixtures/skills-api-*.json
_mock_skills_api_create() {
    cat "${BATS_TEST_DIRNAME}/fixtures/skills-api-create.json"
    printf '\n200'
}

_mock_skills_api_versions_create() {
    jq -n '{version:"1759178010641130"}'
    printf '\n200'
}

_mock_skills_api_get() {
    cat "${BATS_TEST_DIRNAME}/fixtures/skills-api-create.json"
    printf '\n200'
}

_mock_skills_api_list() {
    jq -n '{data: [{id:"skill_01ABCFIXTUREABC", name:"fixture-skill", version:"1759178010641129"}]}'
    printf '\n200'
}

_mock_skills_api_delete() {
    printf '\n200'
}

_mock_sessions_create() {
    jq -n '{id:"sesn_01ABCFIXTURESES", agent_id:"agent_01ABCFIXTUREAGT"}'
    printf '\n200'
}
