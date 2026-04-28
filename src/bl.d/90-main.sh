# shellcheck shell=bash
main() {
    # Pre-case flag sniff: help, version, setup all bypass preflight.
    if (( $# == 0 )); then
        bl_error_envelope usage "no command (use \`bl --help\` for a list)"
        return "$BL_EX_USAGE"
    fi

    case "$1" in
        -h|--help|help)
            bl_usage
            return "$BL_EX_OK"
            ;;
        -v|--version)
            bl_version
            return "$BL_EX_OK"
            ;;
    esac

    # Per-verb help bubble-up — 'bl <verb> [...] --help' at any depth routes
    # to the verb's help. Avoids authoring per-subcommand help blocks; setup
    # MUST be matched here (before the setup) bypass below) so it does not
    # route to bl_setup() and reject --help as an unknown flag.
    local _bl_help_seen=0 _bl_arg
    for _bl_arg in "${@:2}"; do
        case "$_bl_arg" in -h|--help|help) _bl_help_seen=1; break ;; esac
    done
    if (( _bl_help_seen )); then
        case "$1" in
            observe)  bl_help_observe;  return "$BL_EX_OK" ;;
            consult)  bl_help_consult;  return "$BL_EX_OK" ;;
            run)      bl_help_run;      return "$BL_EX_OK" ;;
            defend)   bl_help_defend;   return "$BL_EX_OK" ;;
            clean)    bl_help_clean;    return "$BL_EX_OK" ;;
            case)     bl_help_case;     return "$BL_EX_OK" ;;
            setup)    bl_help_setup;    return "$BL_EX_OK" ;;
            flush)    bl_help_flush;    return "$BL_EX_OK" ;;
            trigger)  bl_help_trigger;  return "$BL_EX_OK" ;;
            *)
                bl_error_envelope usage "unknown command: $1" "(use \`bl --help\` for a list of commands)"
                return "$BL_EX_USAGE"
                ;;
        esac
    fi

    # Setup bypass (must come AFTER per-verb --help match for setup).
    case "$1" in
        setup)
            shift
            bl_setup "$@"
            return $?
            ;;
    esac

    # Non-bypassed verbs → preflight first
    bl_preflight || return $?

    case "$1" in
        observe)  shift; bl_observe  "$@"; return $? ;;
        consult)  shift; bl_consult  "$@"; return $? ;;
        run)      shift; bl_run      "$@"; return $? ;;
        defend)   shift; bl_defend   "$@"; return $? ;;
        clean)    shift; bl_clean    "$@"; return $? ;;
        case)     shift; bl_case     "$@"; return $? ;;
        trigger)  shift; bl_trigger  "$@"; return $? ;;
        flush)
            shift
            local flush_target="" flush_case_id=""
            while (( $# > 0 )); do
                case "$1" in
                    --outbox)         flush_target="outbox"; shift ;;
                    --session-events) flush_target="session-events"; shift ;;
                    --case)           flush_case_id="$2"; shift 2 ;;
                    *) bl_error_envelope flush "unknown flag: $1"; return "$BL_EX_USAGE" ;;
                esac
            done
            case "$flush_target" in
                outbox)
                    bl_outbox_drain
                    return $?
                    ;;
                session-events)
                    if [[ -n "$flush_case_id" ]]; then
                        bl_bridge_session_to_memstore "$flush_case_id"
                    else
                        bl_bridge_flush_all_open_cases
                    fi
                    return $?
                    ;;
                "")
                    bl_error_envelope flush "missing target (--outbox or --session-events [--case <id>])"
                    return "$BL_EX_USAGE"
                    ;;
            esac
            ;;
        *)
            bl_error_envelope usage "unknown command: $1" "(use \`bl --help\` for a list of commands)"
            return "$BL_EX_USAGE"
            ;;
    esac
}

# Source-execute guard: skip `main` (and the strict-mode flags it relies on)
# when bl is sourced — required so unit tests can access bl_* functions
# without inheriting errexit. Bash 4.1 on CentOS 6 propagates `set -e` from
# a sourced file's top level even when the caller masks with `|| true`, so
# strict-mode lives behind the guard rather than at file head.
if (return 0 2>/dev/null); then
    return 0
fi

set -euo pipefail
main "$@"
