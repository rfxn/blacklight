# shellcheck shell=bash
bl_ledger_append() {
    # bl_ledger_append <case-id> <jsonl-record> — 0/65; flock-serialized
    local case_id="$1"
    local record="$2"
    local ledger_file="$BL_VAR_DIR/ledger/$case_id.jsonl"
    local ledger_dir="$BL_VAR_DIR/ledger"
    if ! command mkdir -p "$ledger_dir" 2>/dev/null; then   # RO fs / perms
        bl_error_envelope ledger "$ledger_dir not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    if ! command touch "$ledger_file" 2>/dev/null; then   # RO fs / perms
        bl_error_envelope ledger "$ledger_file not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    # Compact to single-line JSON for JSONL format (grep/jq consumers expect one record per line)
    local compact_record
    compact_record=$(printf '%s' "$record" | jq -c '.') || {
        bl_error_envelope ledger "record is not valid JSON"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    # FD 200 per spec §6.8; open RW for RO-mount-fallback safety
    exec 200<>"$ledger_file" || {
        bl_error_envelope ledger "cannot open lockfile $ledger_file"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    if ! flock -x -w 30 200; then
        exec 200<&-
        bl_error_envelope ledger "flock timeout on $ledger_file"
        return "$BL_EX_CONFLICT"
    fi
    printf '%s\n' "$compact_record" >> "$ledger_file"
    exec 200<&-
    return "$BL_EX_OK"
}

