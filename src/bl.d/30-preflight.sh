bl_preflight() {
    # 1. API key
    if [[ -z "${ANTHROPIC_API_KEY+set}" ]]; then
        bl_error_envelope preflight "ANTHROPIC_API_KEY not set"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    if [[ -z "$ANTHROPIC_API_KEY" ]]; then
        bl_error_envelope preflight "ANTHROPIC_API_KEY empty"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    # 2. Required tools
    if ! command -v curl >/dev/null 2>&1; then   # curl is load-bearing
        bl_error_envelope preflight "curl not found (required for API calls)"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    if ! command -v jq >/dev/null 2>&1; then   # jq is load-bearing for response parsing
        bl_error_envelope preflight "jq not found (required for JSON parsing)"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    # 3. state/ dir — directly, NOT via bl_init_workdir
    if ! command mkdir -p "$BL_STATE_DIR" 2>/dev/null; then   # RO filesystem / perms
        bl_error_envelope preflight "$BL_VAR_DIR not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    # 4. Cached agent-id?
    if [[ -r "$BL_AGENT_ID_FILE" ]]; then
        BL_AGENT_ID="$(command cat "$BL_AGENT_ID_FILE")"
        if [[ -n "$BL_AGENT_ID" ]]; then
            bl_debug "bl_preflight: using cached agent-id $BL_AGENT_ID"
            return "$BL_EX_OK"
        fi
        bl_debug "bl_preflight: cached agent-id empty, re-probing"
    fi

    # 5. Probe GET /v1/agents?name=bl-curator
    local resp
    resp=$(bl_api_call GET "/v1/agents?name=bl-curator") || return $?
    BL_AGENT_ID="$(printf '%s\n' "$resp" | jq -r '.data[0].id // empty')"

    if [[ -z "$BL_AGENT_ID" ]]; then
        command cat >&2 <<'BOOTSTRAP_EOF'
blacklight: this Anthropic workspace has not been seeded.

Run one of the following (one-time per workspace):

  # Local clone:
  bl setup

  # Direct from OSS repo:
  curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/bl | bash -s setup

After setup completes the first host's worth of provisioning,
every subsequent host running 'bl' against the same API key
finds the workspace pre-seeded and skips this step.
BOOTSTRAP_EOF
        return "$BL_EX_WORKSPACE_NOT_SEEDED"
    fi

    printf '%s' "$BL_AGENT_ID" > "$BL_AGENT_ID_FILE"
    bl_debug "bl_preflight: seeded agent-id $BL_AGENT_ID cached to $BL_AGENT_ID_FILE"
    return "$BL_EX_OK"
}

# ----------------------------------------------------------------------------
# Usage / version surfaces — bypass preflight (help should work unseeded)
# ----------------------------------------------------------------------------

bl_usage() {
    command cat <<'USAGE_EOF'
bl — blacklight operator CLI

Usage: bl <command> [options]

Commands:
  observe   Read-only evidence extraction (logs, fs, crons, htaccess)  [M4]
  consult   Open / attach to an investigation case                      [M5]
  run       Execute an agent-prescribed step                            [M5]
  case      Inspect, log, close, reopen cases                           [M5]
  defend    Apply agent-authored defensive payload (ModSec, FW, sig)    [M6]
  clean     Apply agent-prescribed remediation (diff-confirmed)         [M7]
  setup     Provision or sync the Anthropic workspace                   [M8]

Options:
  -h, --help       show this message
  -v, --version    show bl version

Environment:
  ANTHROPIC_API_KEY  (required)  your Anthropic workspace API key
  BL_LOG_LEVEL       (optional)  one of {debug,info,warn,error} — default info
  BL_REPO_URL        (optional)  alternate git repo for skill content

Exit codes: docs/exit-codes.md
Design spec: DESIGN.md
USAGE_EOF
}

bl_version() {
    printf 'bl %s\n' "$BL_VERSION"
}
