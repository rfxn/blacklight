# shellcheck shell=bash
# ----------------------------------------------------------------------------
# Workdir helpers — $BL_VAR_DIR lazy init and case-current reader
# bl_init_workdir is consumed by M4-M8 handlers, NOT by bl_preflight.
# ----------------------------------------------------------------------------

bl_init_workdir() {
    # Creates 5 subdirs under $BL_VAR_DIR. state/ is preflight's job.
    # Returns 0 on success, 65 on writability failure.
    if ! command mkdir -p "$BL_VAR_DIR" 2>/dev/null; then   # RO filesystem / perms
        bl_error_envelope preflight "$BL_VAR_DIR not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    if ! command touch "$BL_VAR_DIR/.wtest" 2>/dev/null; then   # filesystem mounted RO
        bl_error_envelope preflight "$BL_VAR_DIR not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    command rm -f "$BL_VAR_DIR/.wtest"
    local d
    for d in backups quarantine fp-corpus outbox ledger; do
        command mkdir -p "$BL_VAR_DIR/$d"
        bl_debug "bl_init_workdir: ensured $BL_VAR_DIR/$d"
    done
    return "$BL_EX_OK"
}

bl_case_current() {
    # Reads $BL_CASE_CURRENT_FILE. Prints empty string on miss (not an error).
    if [[ -r "$BL_CASE_CURRENT_FILE" ]]; then
        command cat "$BL_CASE_CURRENT_FILE"
    fi
    return "$BL_EX_OK"
}
