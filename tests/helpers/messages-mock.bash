# tests/helpers/messages-mock.bash — curl-shim for /v1/messages routing
#
# Lighter than curator-mock.bash: no Managed-Agents endpoints, single-route
# per-test setup. Exposes BL_MESSAGES_MOCK_LAST_BODY for shape assertions.

bl_messages_mock_init() {
    BL_MOCK_BIN="${BL_MOCK_BIN:-$(mktemp -d)/mock-bin}"
    mkdir -p "$BL_MOCK_BIN"
    BL_MESSAGES_MOCK_FIXTURE="${BL_MESSAGES_MOCK_FIXTURE:-messages-sonnet-summary.json}"
    BL_MESSAGES_MOCK_STATUS="${BL_MESSAGES_MOCK_STATUS:-200}"
    BL_MESSAGES_MOCK_BODY_CAPTURE="$(mktemp -u)"
    cat > "$BL_MOCK_BIN/curl" <<'MOCKEOF'
#!/bin/bash
# messages-mock: capture body, return fixture
url=""
body_file=""
next_is_data=""
for arg in "$@"; do
    if [[ -n "$next_is_data" ]]; then
        body_file="${arg#@}"
        next_is_data=""
        continue
    fi
    case "$arg" in
        --data-binary) next_is_data="yes" ;;
        https://*|http://*) url="$arg" ;;
    esac
done
if [[ -n "$body_file" && -r "$body_file" && -n "${BL_MESSAGES_MOCK_BODY_CAPTURE:-}" ]]; then
    cat "$body_file" > "$BL_MESSAGES_MOCK_BODY_CAPTURE"
fi
fixture_path="$BL_CURATOR_MOCK_FIXTURES_DIR/${BL_MESSAGES_MOCK_FIXTURE:-messages-sonnet-summary.json}"
if [[ "$url" == *"/v1/messages"* && -r "$fixture_path" ]]; then
    body=$(< "$fixture_path")
    printf '%s\n%s' "$body" "${BL_MESSAGES_MOCK_STATUS:-200}"
    exit 0
fi
# Non-/v1/messages calls: return empty 404
printf '{}\n404'
exit 0
MOCKEOF
    chmod +x "$BL_MOCK_BIN/curl"
    PATH="$BL_MOCK_BIN:$PATH"
    BL_CURATOR_MOCK_FIXTURES_DIR="${BL_CURATOR_MOCK_FIXTURES_DIR:-$BATS_TEST_DIRNAME/fixtures}"
    export PATH BL_CURATOR_MOCK_FIXTURES_DIR BL_MESSAGES_MOCK_FIXTURE BL_MESSAGES_MOCK_STATUS BL_MESSAGES_MOCK_BODY_CAPTURE
}

bl_messages_mock_set_fixture() {
    BL_MESSAGES_MOCK_FIXTURE="$1"
    BL_MESSAGES_MOCK_STATUS="${2:-200}"
    export BL_MESSAGES_MOCK_FIXTURE BL_MESSAGES_MOCK_STATUS
}

bl_messages_mock_last_request_model() {
    [[ -r "$BL_MESSAGES_MOCK_BODY_CAPTURE" ]] || return 1
    jq -r '.model' < "$BL_MESSAGES_MOCK_BODY_CAPTURE"
}

bl_messages_mock_teardown() {
    [[ -n "${BL_MOCK_BIN:-}" ]] && rm -rf "${BL_MOCK_BIN%/mock-bin}"
    [[ -n "${BL_MESSAGES_MOCK_BODY_CAPTURE:-}" ]] && rm -f "$BL_MESSAGES_MOCK_BODY_CAPTURE"
    unset BL_MOCK_BIN BL_MESSAGES_MOCK_FIXTURE BL_MESSAGES_MOCK_STATUS BL_MESSAGES_MOCK_BODY_CAPTURE
}
