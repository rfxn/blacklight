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
url=""
for arg in "$@"; do
    case "$arg" in https://*|http://*) url="$arg" ;; esac
done
IFS='|' read -ra patterns <<< "${BL_CURATOR_MOCK_PATTERNS_CSV:-}"
IFS='|' read -ra fixtures <<< "${BL_CURATOR_MOCK_FIXTURES_CSV:-}"
IFS='|' read -ra statuses <<< "${BL_CURATOR_MOCK_STATUSES_CSV:-}"
matched=0
for i in "${!patterns[@]}"; do
    if [[ -n "${patterns[i]}" && "$url" =~ ${patterns[i]} ]]; then
        fixture_path="$BL_CURATOR_MOCK_FIXTURES_DIR/${fixtures[i]}"
        if [[ -r "$fixture_path" ]]; then
            body=$(< "$fixture_path")
        else
            body="{}"
        fi
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
