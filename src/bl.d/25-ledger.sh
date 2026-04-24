# shellcheck shell=bash
bl_ledger_append() {
    # bl_ledger_append <case-id> <jsonl-record> — 0/65/67/71; flock-serialized; schema-validated
    local case_id="$1"
    local record="$2"
    local ledger_file="$BL_VAR_DIR/ledger/$case_id.jsonl"
    local ledger_dir="$BL_VAR_DIR/ledger"
    local schema_file
    # readlink -f + dirname 2>/dev/null: fallbacks for sourced contexts where BASH_SOURCE/readlink may fail; schema lookup is optional (skip-if-unreadable below)
    schema_file="${BL_REPO_ROOT:-$(command dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "$0")" 2>/dev/null || printf '.')}/schemas/ledger-event.json"
    [[ -r "$schema_file" ]] || schema_file="schemas/ledger-event.json"

    if ! command mkdir -p "$ledger_dir" 2>/dev/null; then   # RO fs / perms
        bl_error_envelope ledger "$ledger_dir not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    if ! command touch "$ledger_file" 2>/dev/null; then   # RO fs / perms
        bl_error_envelope ledger "$ledger_file not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    # Compact to single-line JSON (JSONL format)
    local compact_record
    compact_record=$(printf '%s' "$record" | jq -c '.') || {
        bl_error_envelope ledger "record is not valid JSON"
        return "$BL_EX_SCHEMA_VALIDATION_FAIL"
    }

    # Schema-validate via jq_schema_check against schemas/ledger-event.json
    if [[ -r "$schema_file" ]]; then
        local payload_tmp
        payload_tmp=$(mktemp)
        printf '%s' "$compact_record" > "$payload_tmp"
        if ! bl_jq_schema_check "$schema_file" "$payload_tmp"; then
            # Non-conformant: write schema_reject notice via direct printf (bypass validation/mirror to avoid recursion)
            local reject_line
            reject_line=$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$case_id" \
                '{ts:$ts, case:$c, kind:"schema_reject", payload:{reason:"record failed ledger-event.json validation"}}' | jq -c '.')
            # Direct printf bypass — no flock, no mirror, no re-validate (see plan §4.5 rule 3)
            printf '%s\n' "$reject_line" >> "$ledger_file"
            command rm -f "$payload_tmp"
            return "$BL_EX_SCHEMA_VALIDATION_FAIL"
        fi
        command rm -f "$payload_tmp"
    fi

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
    # NOTE: bl_ledger_mirror_remote call added in Phase 4 (depends on 27-outbox.sh)
    return "$BL_EX_OK"
}
