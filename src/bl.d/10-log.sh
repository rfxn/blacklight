_bl_log_level_allows() {
    # $1 = message level (debug|info|warn|error)
    local msg_level="$1"
    local cur_level="${BL_LOG_LEVEL:-info}"
    case "$cur_level" in
        debug) return 0 ;;
        info)  [[ "$msg_level" != "debug" ]] ;;
        warn)  [[ "$msg_level" == "warn" || "$msg_level" == "error" ]] ;;
        error) [[ "$msg_level" == "error" ]] ;;
        *)     [[ "$msg_level" != "debug" ]] ;;   # unknown level → info-equivalent
    esac
}

bl_debug() { _bl_log_level_allows debug || return 0; printf '[bl] DEBUG: %s\n' "$*" >&2; }
bl_info()  { _bl_log_level_allows info  || return 0; printf '[bl] INFO: %s\n'  "$*" >&2; }
bl_warn()  { _bl_log_level_allows warn  || return 0; printf '[bl] WARN: %s\n'  "$*" >&2; }
bl_error() { printf '[bl] ERROR: %s\n' "$*" >&2; }

bl_error_envelope() {
    # $1 = phase, $2 = problem, $3 (optional) = remediation
    local phase="$1"
    local problem="$2"
    local remediation="${3:-}"
    printf 'blacklight: %s: %s\n' "$phase" "$problem" >&2
    [[ -n "$remediation" ]] && printf '%s\n' "$remediation" >&2
    return "$BL_EX_OK"
}

