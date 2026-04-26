# shellcheck shell=bash
bl_consult() {
    # bl_consult <args> — route to _new/_attach/_sweep_mode. Mutually exclusive.
    local mode="" trigger="" case_id="" cve="" notes="" dedup=""
    while (( $# > 0 )); do
        case "$1" in
            --new)         mode="new"; shift ;;
            --attach)      mode="attach"; case_id="$2"; shift 2 ;;
            --sweep-mode)  mode="sweep_mode"; shift ;;
            --trigger)     trigger="$2"; shift 2 ;;
            --cve)         cve="$2"; shift 2 ;;
            --notes)       notes="$2"; shift 2 ;;
            --dedup)       dedup="yes"; shift ;;
            *)
                bl_error_envelope consult "unknown flag: $1" "(use one of --new --attach <id> --sweep-mode)"
                return "$BL_EX_USAGE"
                ;;
        esac
    done
    case "$mode" in
        new)         bl_consult_new "$trigger" "$notes" "$dedup"; return $? ;;
        attach)      bl_consult_attach "$case_id"; return $? ;;
        sweep_mode)  bl_consult_sweep_mode "$cve"; return $? ;;
        "")
            bl_error_envelope consult "missing mode" "(use one of --new --attach <id> --sweep-mode)"
            return "$BL_EX_USAGE"
            ;;
    esac
}

# ----------------------------------------------------------------------------
# bl_consult_* — case-lifecycle open/attach/inventory (M5)
# Spec: docs/specs/2026-04-24-M5-consult-run-case.md §5.1
# ----------------------------------------------------------------------------

bl_consult_allocate_case_id() {
    # bl_consult_allocate_case_id — prints CASE-YYYY-NNNN on stdout; 0/65/71
    local counter_file="$BL_STATE_DIR/case-id-counter"
    local year new_n
    year=$(date -u +%Y)
    if ! command mkdir -p "$BL_STATE_DIR" 2>/dev/null; then   # RO fs / perms
        bl_error_envelope consult "$BL_STATE_DIR not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    if ! command touch "$counter_file" 2>/dev/null; then   # RO fs / perms
        bl_error_envelope consult "$counter_file not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    # flock FD 201 to avoid re-entry conflict with bl_ledger_append (FD 200)
    exec 201<>"$counter_file"
    if ! flock -x -w 30 201; then
        exec 201<&-
        bl_error_envelope consult "flock timeout on $counter_file"
        return "$BL_EX_CONFLICT"
    fi
    local raw cur_year cur_n
    raw=$(command cat "$counter_file" 2>/dev/null || printf '')   # missing/empty → reset path below
    cur_year=$(printf '%s' "$raw" | jq -r '.year // empty' 2>/dev/null || printf '')
    cur_n=$(printf '%s' "$raw" | jq -r '.n // empty' 2>/dev/null || printf '')
    if [[ -z "$cur_year" || -z "$cur_n" ]] || [[ "$cur_year" != "$year" ]]; then
        cur_n=0
    fi
    new_n=$((cur_n + 1))
    local tmp="$counter_file.tmp.$$"
    printf '{"year":%s,"n":%s}\n' "$year" "$new_n" > "$tmp"
    command mv "$tmp" "$counter_file"
    exec 201<&-
    printf 'CASE-%s-%04d\n' "$year" "$new_n"
    return "$BL_EX_OK"
}

bl_consult_fingerprint_trigger() {
    # bl_consult_fingerprint_trigger <artifact> — prints 16-hex on stdout; 0/65
    local artifact="$1"
    local fp=""
    if [[ "$artifact" == /* || "$artifact" == */* ]]; then
        if [[ ! -e "$artifact" ]]; then
            bl_error_envelope consult "trigger artifact not found: $artifact"
            return "$BL_EX_USAGE"
        fi
        fp=$(sha256sum "$artifact" | cut -c1-16)
    else
        fp=$(printf '%s' "$artifact" | sha256sum | cut -c1-16)
    fi
    printf '%s\n' "$fp"
    return "$BL_EX_OK"
}

bl_consult_materialize_case() {
    # bl_consult_materialize_case <case-id> <fingerprint> <notes> — 0/65/69
    # Posts template files to memstore under bl-case/<case-id>/.
    local case_id="$1"
    local fp="$2"
    local notes="${3:-}"
    local memstore_prefix="bl-case/$case_id"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # BL_REPO_ROOT: derived from $0 so templates are found at install path
    local repo_root="${BL_REPO_ROOT:-$(dirname "$(readlink -f "$0")" 2>/dev/null || printf '.')}"
    local templates=(hypothesis open-questions attribution ip-clusters url-patterns file-patterns defense-hits)
    local tmpl content body_file rc
    for tmpl in "${templates[@]}"; do
        local tpl_path="$repo_root/case-templates/$tmpl.md"
        [[ -r "$tpl_path" ]] || tpl_path="case-templates/$tmpl.md"
        content=$(command cat "$tpl_path") || return "$BL_EX_PREFLIGHT_FAIL"
        if [[ "$tmpl" == "hypothesis" ]]; then
            content="<!-- trigger_fingerprint: $fp -->"$'\n'"$content"
        fi
        body_file=$(mktemp)
        printf '%s' "$content" > "$body_file"
        bl_mem_post "${BL_MEMSTORE_CASE_ID}" "$memstore_prefix/$tmpl.md" "$body_file"
        rc=$?
        command rm -f "$body_file"
        (( rc == 0 )) || return "$rc"
    done
    body_file=$(mktemp)
    printf '0' > "$body_file"
    bl_mem_post "${BL_MEMSTORE_CASE_ID}" "$memstore_prefix/STEP_COUNTER" "$body_file" || {
        command rm -f "$body_file"
        return "$BL_EX_UPSTREAM_ERROR"
    }
    command rm -f "$body_file"
    bl_consult_update_index_row_append "$case_id" "$now" "$notes" "$fp" || return $?
    return "$BL_EX_OK"
}

bl_consult_register_curator() {
    # bl_consult_register_curator <case-id> <fingerprint> — 0/69/70
    local case_id="$1"
    local fp="$2"
    local session_id_file="$BL_STATE_DIR/session-$case_id"
    local session_id=""
    [[ -r "$session_id_file" ]] && session_id=$(command cat "$session_id_file")
    [[ -z "$session_id" ]] && session_id="${BL_SESSION_ID:-}"
    if [[ -z "$session_id" ]]; then
        # Path C: create a session for this case, attaching workspace + per-case Files.
        # Falls back to outbox path if session-create fails (spec R6 — hot-attach safety).
        session_id=$(bl_consult_create_session "$case_id") || {
            bl_warn "bl_consult_create_session failed; falling back to outbox wake"
            local trigger_payload_file fenced_trigger
            trigger_payload_file=$(command mktemp)
            printf '%s %s' "$case_id" "$fp" > "$trigger_payload_file"
            fenced_trigger=$(bl_fence_wrap "$case_id" wake_trigger "$trigger_payload_file")
            command rm -f "$trigger_payload_file"
            local wake_payload
            wake_payload=$(jq -n --arg c "$case_id" --arg f "$fp" --arg ft "$fenced_trigger" \
                '{type:"user.message", case:$c, content:[{type:"text", text:("case opened: "+$c+"; trigger_fingerprint="+$f)}], trigger_fingerprint_fenced:$ft}')
            bl_outbox_enqueue wake "$wake_payload" || bl_warn "outbox enqueue failed; wake event lost for $case_id"
            return "$BL_EX_OK"
        }
        # Persist session-id to legacy per-key path (consumed by 60-run.sh + 70-case.sh until M14 migration)
        printf '%s' "$session_id" > "$BL_STATE_DIR/session-$case_id"
        bl_info "bl consult: created session $session_id for $case_id (workspace + per-case Files attached)"
    fi
    local body_file
    body_file=$(mktemp)
    # Direct-session wake path sends fingerprint UNFENCED in the prose. Design asymmetry
    # vs P5 outbox path — the outbox path fences trigger via bl_fence_wrap kind=wake_trigger
    # because it carries the full trigger payload; here only the trigger_fingerprint
    # (sha256[:16] of the operator artifact) is conveyed. Operator-derived input has lower
    # injection surface than raw payload bytes — an attacker would need to control the
    # operator's local artifact to influence it. Hardening tracked for M11+.
    # API shape: POST /v1/sessions/<id>/events requires {events:[...]} wrapper.
    jq -n --arg c "$case_id" --arg f "$fp" \
        '{events:[{type:"user.message", content:[{type:"text", text:("case opened: "+$c+"; trigger_fingerprint="+$f+"; read first per system-prompt §3")}]}]}' \
        > "$body_file"
    bl_api_call POST "/v1/sessions/$session_id/events" "$body_file" >/dev/null
    local rc=$?
    command rm -f "$body_file"
    return "$rc"
}

# bl_consult_create_session <case-id> — POST /v1/sessions with resources[] for workspace corpora + per-case Files.
# Returns session_id on stdout. 0/65/69/70.
bl_consult_create_session() {
    local case_id="$1"
    [[ -z "$case_id" ]] && { bl_error_envelope consult "bl_consult_create_session: case-id required"; return "$BL_EX_USAGE"; }
    local state_file="$BL_STATE_DIR/state.json"
    [[ -f "$state_file" ]] || { bl_error_envelope consult "state.json missing; run 'bl setup --sync' first"; return "$BL_EX_PREFLIGHT_FAIL"; }
    local agent_id env_id
    agent_id=$(jq -r '.agent.id // empty' "$state_file")
    env_id=$(jq -r '.env_id // empty' "$state_file")
    [[ -z "$agent_id" ]] && { bl_error_envelope consult "agent.id missing in state.json; run 'bl setup --sync'"; return "$BL_EX_PREFLIGHT_FAIL"; }
    [[ -z "$env_id" ]] && { bl_error_envelope consult "env_id missing in state.json; run 'bl setup --sync'"; return "$BL_EX_PREFLIGHT_FAIL"; }
    # Build resources[] array — workspace files + per-case files for this case_id
    local resources_json
    resources_json=$(jq -c \
        --arg c "$case_id" \
        '
        ([.files // {} | to_entries[] | {type:"file", file_id:.value.file_id, mount_path:.key}])
        + ([.case_files[$c] // {} | to_entries[] | {type:"file", file_id:.value.workspace_file_id, mount_path:.key}])
        ' "$state_file")
    local body_file
    body_file=$(command mktemp)
    # Sessions.create requires 'agent' (not 'agent_id') and 'environment_id'.
    jq -n \
        --arg aid "$agent_id" \
        --arg eid "$env_id" \
        --argjson rs "$resources_json" \
        '{agent: $aid, environment_id: $eid, resources: $rs}' > "$body_file"
    local resp rc session_id
    resp=$(bl_api_call POST "/v1/sessions" "$body_file")
    rc=$?
    command rm -f "$body_file"
    (( rc != 0 )) && return $rc
    session_id=$(printf '%s' "$resp" | jq -r '.id // empty')
    if [[ -z "$session_id" ]]; then
        bl_error_envelope consult "sessions.create returned empty id"
        return "$BL_EX_UPSTREAM_ERROR"
    fi
    # Persist session_id to state.json
    local tmp_state="$state_file.tmp.$$"
    jq --arg c "$case_id" --arg s "$session_id" '.session_ids[$c] = $s' "$state_file" > "$tmp_state"
    command mv "$tmp_state" "$state_file"
    printf '%s\n' "$session_id"
    return "$BL_EX_OK"
}

bl_consult_find_open_case_by_fingerprint() {
    # bl_consult_find_open_case_by_fingerprint <16hex> — prints case-id or empty on miss; 0/69
    # Fast path: parse the trigger-fingerprint column (col 7) directly from the
    # INDEX.md row. Fallback to per-hypothesis GET only when the row lacks the
    # fp column (legacy INDEX written before M9.5 P7) — keeps cross-version
    # operator workspaces resolvable.
    local fp="$1"
    local index_body
    index_body=$(bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/INDEX.md" 2>/dev/null) || return "$BL_EX_OK"   # missing INDEX → no prior cases
    local index_content
    index_content=$(printf '%s' "$index_body" | jq -r '.content')

    # awk -F'|' on `| a | b | c | d | e |` gives NF=7 (1 empty leader + 5 cells
    # + 1 empty trailer). 6-cell row → NF=8. We use NF as the legacy/new
    # discriminator since the only-distinguishing-feature of the new schema
    # is the trailing fingerprint column.
    #
    # Fast path: NF>=8 rows with non-empty $7 carry a fingerprint; match.
    local case_id_match
    # Literal-class regex (no `{4}` quantifier) — mawk default on Debian /
    # Ubuntu does not parse interval quantifiers; gawk 3.1.7 (CentOS 6) needs
    # --re-interval. Literal repetition is portable across all awk variants.
    case_id_match=$(printf '%s' "$index_content" | command awk -v want="$fp" -F'|' '
        /^\| CASE-[0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9] \|/ {
            status=$4; gsub(/^[ \t]+|[ \t]+$/, "", status)
            if (status != "active") next
            if (NF < 8) next   # legacy 5-cell row → fall through to slow path
            cell=$7; gsub(/^[ \t]+|[ \t]+$/, "", cell)
            if (cell == want) {
                row=$2; gsub(/^[ \t]+|[ \t]+$/, "", row)
                print row; exit
            }
        }')
    if [[ -n "$case_id_match" ]]; then
        printf '%s\n' "$case_id_match"
        return "$BL_EX_OK"
    fi

    # Legacy fallback: rows without fp column (NF<8) → fan out per-case GET.
    # Once all rows carry fp, this loop body never executes.
    local active_cases
    active_cases=$(printf '%s' "$index_content" \
        | command awk -F'|' '
            /^\| CASE-[0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9] \|/ {
                status=$4; gsub(/^[ \t]+|[ \t]+$/, "", status)
                if (status != "active") next
                if (NF >= 8) next   # has fp column — fast path already handled
                row=$2; gsub(/^[ \t]+|[ \t]+$/, "", row)
                print row
            }')
    local case_id hyp_body hyp_fp
    while IFS= read -r case_id; do
        [[ -z "$case_id" ]] && continue
        hyp_body=$(bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/hypothesis.md" 2>/dev/null) || continue   # skip unreadable row
        hyp_fp=$(printf '%s' "$hyp_body" | jq -r '.content' | grep -oE 'trigger_fingerprint: [a-f0-9]{16}' | awk '{print $2}')
        if [[ "$hyp_fp" == "$fp" ]]; then
            printf '%s\n' "$case_id"
            return "$BL_EX_OK"
        fi
    done <<< "$active_cases"
    return "$BL_EX_OK"
}

bl_consult_update_index_row_append() {
    # bl_consult_update_index_row_append <case-id> <iso-ts> <notes> [<fp>] — 0/69/70/71
    local case_id="$1"
    local ts="$2"
    local notes="${3:-investigation open, no hypothesis yet}"
    local fp="${4:-}"
    local preview
    preview=$(printf '%.30s' "$notes")
    local new_row="| $case_id | $ts | active | $preview | — | ${fp:-—} |"
    local attempt=0 index_body current_content new_content body_file rc
    local repo_root="${BL_REPO_ROOT:-$(dirname "$(readlink -f "$0")" 2>/dev/null || printf '.')}"
    while (( attempt < 3 )); do
        index_body=$(bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/INDEX.md" 2>/dev/null) || {
            current_content=$(command cat "$repo_root/case-templates/INDEX.md" 2>/dev/null || command cat "case-templates/INDEX.md" 2>/dev/null || printf '')
            new_content=$(printf '%s\n%s\n' "$current_content" "$new_row")
            body_file=$(mktemp)
            printf '%s' "$new_content" > "$body_file"
            bl_mem_post "${BL_MEMSTORE_CASE_ID}" "bl-case/INDEX.md" "$body_file"
            rc=$?
            command rm -f "$body_file"
            (( rc == 0 )) && return "$BL_EX_OK"
            attempt=$((attempt + 1))
            continue
        }
        current_content=$(printf '%s' "$index_body" | jq -r '.content')
        if printf '%s' "$current_content" | grep -q '<!-- WRAPPER-APPEND -->'; then
            new_content=$(printf '%s' "$current_content" | sed "s|<!-- WRAPPER-APPEND -->|$new_row\n<!-- WRAPPER-APPEND -->|")
        else
            new_content=$(printf '%s\n%s\n' "$current_content" "$new_row")
        fi
        body_file=$(mktemp)
        printf '%s' "$new_content" > "$body_file"
        bl_mem_patch "${BL_MEMSTORE_CASE_ID}" "bl-case/INDEX.md" "$body_file"   # last-write-wins; if_content_sha256 no longer supported
        rc=$?
        command rm -f "$body_file"
        (( rc == 0 )) && return "$BL_EX_OK"
        attempt=$((attempt + 1))
        bl_debug "bl_consult_update_index_row_append: retry $attempt/3"
    done
    bl_error_envelope consult "INDEX.md update exhausted 3 retries"
    return "$BL_EX_CONFLICT"
}

bl_consult_new() {
    # bl_consult_new — open a new case (or attach via dedup gate).
    # Positional form (preserved for existing callers):
    #   bl_consult_new <trigger> <notes> <dedup>      — 0/64/65/71
    # Flag form (M14 — bl_trigger_lmd uses this):
    #   bl_consult_new --trigger <path> --notes <str> --dedup <yes|""> \
    #                  [--fingerprint <hex>] [--dedup-window-hours <N>]
    # Returns: emits case-id to stdout on 0; emits ledger trigger_dedup_attached
    # on within-window match.
    local trigger="" notes="" dedup="" fingerprint_override="" dedup_window_hours=0

    if [[ "${1:-}" == --* ]]; then
        # Flag form
        while (( $# > 0 )); do
            case "$1" in
                --trigger)              trigger="$2"; shift 2 ;;
                --notes)                notes="$2"; shift 2 ;;
                --dedup)                dedup="$2"; shift 2 ;;
                --fingerprint)          fingerprint_override="$2"; shift 2 ;;
                --dedup-window-hours)   dedup_window_hours="$2"; shift 2 ;;
                *) bl_error_envelope consult "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            esac
        done
    else
        # Positional form (existing semantic preserved)
        trigger="${1:-}"
        notes="${2:-}"
        dedup="${3:-}"
    fi

    BL_MEMSTORE_CASE_ID="${BL_MEMSTORE_CASE_ID:-$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf 'memstore_bl_case')}"   # 2>/dev/null: state file may be absent on first invocation; default id
    if [[ -z "$trigger" ]]; then
        bl_error_envelope consult "missing --trigger <artifact>"
        return "$BL_EX_USAGE"
    fi

    # Fingerprint: use override (M14 cluster-fp injected by bl_trigger_lmd) or
    # fall through to existing file-content fingerprint
    local fp
    if [[ -n "$fingerprint_override" ]]; then
        fp="$fingerprint_override"
    else
        fp=$(bl_consult_fingerprint_trigger "$trigger") || return $?
    fi

    if [[ "$dedup" == "yes" ]]; then
        local existing=""
        existing=$(bl_consult_find_open_case_by_fingerprint "$fp") || existing=""   # miss → empty string, not error
        if [[ -n "$existing" ]]; then
            # M14: time-bound the dedup match if --dedup-window-hours > 0
            if (( dedup_window_hours > 0 )); then
                local ledger_path="$BL_VAR_DIR/ledger/${existing}.jsonl"
                if [[ -r "$ledger_path" ]]; then
                    local opened_ts now_epoch opened_epoch age_hours
                    opened_ts=$(jq -rs '.[] | select(.kind=="case_opened") | .ts' "$ledger_path" 2>/dev/null | head -1)   # 2>/dev/null: malformed JSONL falls through to fresh-case path
                    if [[ -n "$opened_ts" ]]; then
                        now_epoch=$(date -u +%s)
                        opened_epoch=$(date -u -d "$opened_ts" +%s 2>/dev/null) || opened_epoch=0   # 2>/dev/null: BSD date may not parse ISO Z; treat as stale → fall through
                        age_hours=$(( (now_epoch - opened_epoch) / 3600 ))
                        if (( age_hours > dedup_window_hours )); then
                            bl_debug "dedup: existing case $existing is ${age_hours}h old, > ${dedup_window_hours}h window — treating as not-found"
                            existing=""
                        fi
                    fi
                fi
            fi
            if [[ -n "$existing" ]]; then
                bl_info "dedup: attaching to existing open case $existing (fingerprint $fp)"
                # Skip probe: INDEX fp-column match already proved the case is active.
                bl_consult_attach "$existing" yes
                local rc=$?
                if (( rc == 0 )); then
                    # M14: emit trigger_dedup_attached ledger event
                    bl_ledger_append "$existing" \
                        "$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$existing" --arg f "$fp" \
                            '{ts:$ts, case:$c, kind:"trigger_dedup_attached", payload:{fingerprint:$f, attached_to_case:$c}}')" || \
                        bl_warn "ledger append failed for trigger_dedup_attached"
                fi
                return $rc
            fi
        fi
    elif [[ -z "$dedup" ]]; then
        local existing=""
        existing=$(bl_consult_find_open_case_by_fingerprint "$fp") || existing=""   # miss → empty, non-fatal
        [[ -n "$existing" ]] && bl_warn "trigger fingerprint $fp already open in $existing (use --dedup to attach, or proceed for new)"
    fi

    # Retry limit is generous: fresh workspaces with a pre-populated shared memstore
    # (same API key, prior sessions) produce 409 conflicts for each already-used case-id.
    # The counter fast-forwards past them; each retry costs only a counter increment.
    local max_attempts="${BL_CONSULT_ALLOC_MAX_RETRIES:-50}"
    local case_id attempt=0
    while (( attempt < max_attempts )); do
        case_id=$(bl_consult_allocate_case_id) || return $?
        if bl_consult_materialize_case "$case_id" "$fp" "$notes"; then
            printf '%s' "$case_id" > "$BL_CASE_CURRENT_FILE"
            bl_consult_register_curator "$case_id" "$fp" || true   # || true: non-fatal; outbox queued
            bl_ledger_append "$case_id" \
                "$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$case_id" --arg f "$fp" \
                    '{ts:$ts, case:$c, kind:"case_opened", payload:{trigger_fingerprint:$f}}')"
            bl_info "allocated $case_id"
            printf '%s\n' "$case_id"
            return "$BL_EX_OK"
        fi
        attempt=$((attempt + 1))
        bl_debug "bl_consult_new: materialize conflict (attempt $attempt/$max_attempts); retrying"
    done
    bl_error_envelope consult "case-id allocation exhausted $max_attempts retries"
    return "$BL_EX_CONFLICT"
}

bl_consult_attach() {
    # bl_consult_attach <case-id> [skip_probe] — 0/64/65/69/72
    # skip_probe="yes" bypasses the hypothesis.md GET when caller has already
    # validated case existence (e.g. dedup fast path via INDEX fp column).
    local case_id="$1"
    local skip_probe="${2:-no}"
    BL_MEMSTORE_CASE_ID="${BL_MEMSTORE_CASE_ID:-$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf 'memstore_bl_case')}"
    if [[ -z "$case_id" ]]; then
        bl_error_envelope consult "missing <case-id> for --attach"
        return "$BL_EX_USAGE"
    fi
    # Format guard: defense-in-depth against operator typo / shell-history accident
    # propagating to ledger paths, quarantine paths, memstore-key URL-encoding.
    if ! [[ "$case_id" =~ ^CASE-[0-9]{4}-[0-9]{4}$ ]]; then
        bl_error_envelope consult "case-id format invalid (expected CASE-YYYY-NNNN): $case_id"
        return "$BL_EX_USAGE"
    fi
    if [[ "$skip_probe" != "yes" ]]; then
        local probe_rc=0
        bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/hypothesis.md" >/dev/null || probe_rc=$?
        if (( probe_rc == 65 )); then
            local list_rc=0 list_out
            list_out=$(bl_mem_list "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/") || list_rc=$?
            if (( list_rc != 0 )) || [[ -z "$(printf '%s' "${list_out:-}" | jq -r '.data[0].id // empty' 2>/dev/null)" ]]; then
                bl_error_envelope consult "case not found: $case_id"
                return "$BL_EX_NOT_FOUND"
            fi
        elif (( probe_rc != 0 )); then
            return "$probe_rc"
        fi
    fi
    printf '%s' "$case_id" > "$BL_CASE_CURRENT_FILE"
    bl_ledger_append "$case_id" \
        "$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$case_id" \
            '{ts:$ts, case:$c, kind:"case_attached", payload:{}}')"
    bl_info "attached to $case_id"
    return "$BL_EX_OK"
}

bl_consult_sweep_mode() {
    # bl_consult_sweep_mode [cve] — 0/64/69; read-only inventory
    local cve="${1:-}"
    BL_MEMSTORE_CASE_ID="${BL_MEMSTORE_CASE_ID:-$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf 'memstore_bl_case')}"
    local list_body
    list_body=$(bl_mem_list "${BL_MEMSTORE_CASE_ID}" "bl-case/") || return $?
    local closed_cases
    closed_cases=$(printf '%s' "$list_body" | jq -r '.data[] | select(.key | test("^bl-case/CASE-[^/]+/closed\\.md$")) | .key' 2>/dev/null || printf '')
    if [[ -z "$closed_cases" ]]; then
        printf 'No closed cases in workspace.\n'
        return "$BL_EX_OK"
    fi
    printf '%-18s  %-20s  %s\n' "Case" "Closed" "Brief (md)"
    local key case_id body
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        case_id=$(printf '%s' "$key" | sed 's|bl-case/||; s|/closed.md||')
        body=$(bl_mem_get "${BL_MEMSTORE_CASE_ID}" "$key" 2>/dev/null) || continue   # skip unreadable
        if [[ -n "$cve" ]]; then
            local hyp
            hyp=$(bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/hypothesis.md" 2>/dev/null) || continue   # skip unreadable
            printf '%s' "$hyp" | grep -qi "$cve" || continue   # no match → skip row
        fi
        local closed_at fid_md
        closed_at=$(printf '%s' "$body" | jq -r '.content' | grep '^closed_at:' | cut -d' ' -f2-)
        fid_md=$(printf '%s' "$body" | jq -r '.content' | grep '^brief_file_id_md:' | cut -d' ' -f2-)
        printf '%-18s  %-20s  %s\n' "$case_id" "$closed_at" "$fid_md"
    done <<< "$closed_cases"
    return "$BL_EX_OK"
}

# ----------------------------------------------------------------------------
# bl_run_* — tier-gated step execution (M5)
# Spec: docs/specs/2026-04-24-M5-consult-run-case.md §5.2 + §5.2.1 flow
# Tier matrix: docs/action-tiers.md §5 + spec §7.5
# ----------------------------------------------------------------------------

