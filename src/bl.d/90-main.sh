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

    # Per-verb help bypass — 'bl <verb> --help' must work pre-seed.
    # NOTE: setup MUST be in this list AND match BEFORE the setup) arm
    #       below, otherwise 'bl setup --help' routes to bl_setup()
    #       and is rejected as an unknown flag (BL_EX_USAGE=64).
    if (( $# >= 2 )); then
        case "$2" in
            -h|--help|help)
                case "$1" in
                    observe)  bl_help_observe;  return "$BL_EX_OK" ;;
                    consult)  bl_help_consult;  return "$BL_EX_OK" ;;
                    run)      bl_help_run;      return "$BL_EX_OK" ;;
                    defend)   bl_help_defend;   return "$BL_EX_OK" ;;
                    clean)    bl_help_clean;    return "$BL_EX_OK" ;;
                    case)     bl_help_case;     return "$BL_EX_OK" ;;
                    setup)    bl_help_setup;    return "$BL_EX_OK" ;;
                    flush)    bl_help_flush;    return "$BL_EX_OK" ;;
                    *)
                        bl_error_envelope usage "unknown command: $1" "(use \`bl --help\` for a list of commands)"
                        return "$BL_EX_USAGE"
                        ;;
                esac
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
        flush)
            shift
            local flush_target=""
            while (( $# > 0 )); do
                case "$1" in
                    --outbox) flush_target="outbox"; shift ;;
                    *) bl_error_envelope flush "unknown flag: $1"; return "$BL_EX_USAGE" ;;
                esac
            done
            if [[ "$flush_target" == "outbox" ]]; then
                bl_outbox_drain
                return $?
            fi
            bl_error_envelope flush "missing --outbox (nothing else to flush in M9)"
            return "$BL_EX_USAGE"
            ;;
        *)
            bl_error_envelope usage "unknown command: $1" "(use \`bl --help\` for a list of commands)"
            return "$BL_EX_USAGE"
            ;;
    esac
}

main "$@"
