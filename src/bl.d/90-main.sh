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
