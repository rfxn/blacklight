# tests/helpers/bl-preflight-mock.bash — curl-shim for bl_preflight() probes
#
# Provides a mock `curl` binary placed at $BL_MOCK_BIN (defaults to a mktemp
# directory prepended to PATH). The mock inspects the URL it's invoked with
# and returns one of three pre-configured responses for GET /v1/agents:
#
#   bl_mock_set_response empty     — HTTP 200 + {"data": []}  (triggers 66 path)
#   bl_mock_set_response populated — HTTP 200 + {"data": [{"id":"agent_test_stub"}]} (triggers cache+0)
#   bl_mock_set_response bad_key   — HTTP 401 (triggers 65 path)
#
# Response shape matches docs/setup-flow.md §8 provenance notes
# (live-probe 2026-04-24 HTTP transcript).

bl_mock_init() {
    BL_MOCK_BIN="${BL_MOCK_BIN:-$(mktemp -d)/mock-bin}"
    command mkdir -p "$BL_MOCK_BIN"
    BL_MOCK_RESPONSE="${BL_MOCK_RESPONSE:-empty}"
    cat > "$BL_MOCK_BIN/curl" <<'MOCKEOF'
#!/bin/bash
# bl-preflight-mock: curl shim
case "$BL_MOCK_RESPONSE" in
    empty)     printf '{"data": []}\n200'; exit 0 ;;
    populated) printf '{"data": [{"id": "agent_test_stub"}]}\n200'; exit 0 ;;
    bad_key)   printf '{"error": {"type": "authentication_error"}}\n401'; exit 0 ;;  # curl -w emits status to stdout, not stderr; exit 0 matches successful HTTP with 4xx body
    *)         printf 'bl-preflight-mock: unknown response config: %s\n' "$BL_MOCK_RESPONSE" >&2; exit 1 ;;
esac
MOCKEOF
    chmod +x "$BL_MOCK_BIN/curl"
    PATH="$BL_MOCK_BIN:$PATH"
    export PATH BL_MOCK_RESPONSE
}

bl_mock_set_response() {
    BL_MOCK_RESPONSE="$1"
    export BL_MOCK_RESPONSE
}

bl_mock_teardown() {
    [[ -n "${BL_MOCK_BIN:-}" ]] && command rm -rf "$BL_MOCK_BIN"
    unset BL_MOCK_BIN BL_MOCK_RESPONSE
}
