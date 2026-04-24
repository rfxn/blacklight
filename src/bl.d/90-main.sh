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
        *)
            bl_error_envelope usage "unknown command: $1" "(use \`bl --help\` for a list of commands)"
            return "$BL_EX_USAGE"
            ;;
    esac
}

main "$@"
