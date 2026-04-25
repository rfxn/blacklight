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
    # M9 P4: mirror to bl-case/actions/applied/ best-effort (never affects return code)
    bl_ledger_mirror_remote "$case_id" "$compact_record" >/dev/null 2>&1 || true   # mirror is best-effort
    return "$BL_EX_OK"
}

bl_ledger_mirror_remote() {
    # bl_ledger_mirror_remote <case-id> <jsonl-record> — 0 (best-effort; no ledger emission)
    # Cycle-break invariant per spec §4.5 rule 2: the validated-append helper is never invoked from this path.
    local case_id="$1" record="$2"
    local ts kind event_id
    ts=$(printf '%s' "$record" | jq -r '.ts')
    kind=$(printf '%s' "$record" | jq -r '.kind')
    event_id=$(printf '%s%s%s' "$ts" "$case_id" "$kind" | sha256sum | cut -c1-16)
    local target_key="bl-case/$case_id/actions/applied/$event_id.json"
    local body_tmp
    body_tmp=$(mktemp)
    printf '%s' "$record" > "$body_tmp"
    if ! bl_mem_post "${BL_MEMSTORE_CASE_ID:-memstore_bl_case}" "$target_key" "$body_tmp" >/dev/null 2>&1; then   # mirror best-effort; remote may be unreachable
        # Mirror failed → enqueue to outbox (best-effort; no ledger emission for this failure)
        local mirror_payload
        mirror_payload=$(jq -n --argjson r "$record" --arg k "$target_key" '{record:$r, target_key:$k}')
        bl_outbox_enqueue action_mirror "$mirror_payload" >/dev/null 2>&1 || true   # outbox enqueue best-effort
    fi
    command rm -f "$body_tmp"
    return "$BL_EX_OK"
}
