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
        jq -n --arg k "$memstore_prefix/$tmpl.md" --arg c "$content" \
            '{key: $k, content: $c, metadata: {}}' > "$body_file"
        bl_api_call POST "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories" "$body_file" >/dev/null
        rc=$?
        command rm -f "$body_file"
        (( rc == 0 )) || return "$rc"
    done
    body_file=$(mktemp)
    jq -n --arg k "$memstore_prefix/STEP_COUNTER" --arg c "0" \
        '{key: $k, content: $c, metadata: {}}' > "$body_file"
    bl_api_call POST "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories" "$body_file" >/dev/null || {
        command rm -f "$body_file"
        return "$BL_EX_UPSTREAM_ERROR"
    }
    command rm -f "$body_file"
    bl_consult_update_index_row_append "$case_id" "$now" "$notes" || return $?
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
        bl_warn "no bl-curator session; wake event queued to outbox"
        # M9 P5: fence the trigger-fingerprint + case as untrusted (kind=wake_trigger)
        local trigger_payload_file fenced_trigger
        trigger_payload_file=$(mktemp)
        printf '%s %s' "$case_id" "$fp" > "$trigger_payload_file"
        fenced_trigger=$(bl_fence_wrap "$case_id" wake_trigger "$trigger_payload_file")
        command rm -f "$trigger_payload_file"
        local wake_payload
        wake_payload=$(jq -n --arg c "$case_id" --arg f "$fp" --arg ft "$fenced_trigger" \
            '{type:"user.message", content:[{type:"text", text:("case opened: "+$c+"; trigger_fingerprint="+$f)}], trigger_fingerprint_fenced:$ft}')
        bl_outbox_enqueue wake "$wake_payload" || bl_warn "outbox enqueue failed; wake event lost for $case_id"
        return "$BL_EX_OK"
    fi
    local body_file
    body_file=$(mktemp)
    # Direct-session wake path sends fingerprint UNFENCED in the prose. Design asymmetry
    # vs P5 outbox path — the outbox path fences trigger via bl_fence_wrap kind=wake_trigger
    # because it carries the full trigger payload; here only the trigger_fingerprint
    # (sha256[:16] of the operator artifact) is conveyed. Operator-derived input has lower
    # injection surface than raw payload bytes — an attacker would need to control the
    # operator's local artifact to influence it. Hardening tracked for M11+.
    jq -n --arg c "$case_id" --arg f "$fp" \
        '{type:"user.message", content:[{type:"text", text:("case opened: "+$c+"; trigger_fingerprint="+$f+"; read first per system-prompt §3")}]}' \
        > "$body_file"
    bl_api_call POST "/v1/sessions/$session_id/events" "$body_file" >/dev/null
    local rc=$?
    command rm -f "$body_file"
    return "$rc"
}

bl_consult_find_open_case_by_fingerprint() {
    # bl_consult_find_open_case_by_fingerprint <16hex> — prints case-id or empty on miss; 0/69
    local fp="$1"
    local index_body
    index_body=$(bl_api_call GET "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories/bl-case%2FINDEX.md" 2>/dev/null) || return "$BL_EX_OK"   # missing INDEX → no prior cases
    local active_cases
    active_cases=$(printf '%s' "$index_body" | jq -r '.content' | grep -E '^\| CASE-[0-9]{4}-[0-9]{4} \|.*\| active \|' | awk -F'|' '{print $2}' | tr -d ' ')
    local case_id hyp_body hyp_fp
    while IFS= read -r case_id; do
        [[ -z "$case_id" ]] && continue
        hyp_body=$(bl_api_call GET "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories/bl-case%2F$case_id%2Fhypothesis.md" 2>/dev/null) || continue   # skip unreadable row
        hyp_fp=$(printf '%s' "$hyp_body" | jq -r '.content' | grep -oE 'trigger_fingerprint: [a-f0-9]{16}' | awk '{print $2}')
        if [[ "$hyp_fp" == "$fp" ]]; then
            printf '%s\n' "$case_id"
            return "$BL_EX_OK"
        fi
    done <<< "$active_cases"
    return "$BL_EX_OK"
}

bl_consult_update_index_row_append() {
    # bl_consult_update_index_row_append <case-id> <iso-ts> <notes> — 0/69/70/71
    local case_id="$1"
    local ts="$2"
    local notes="${3:-investigation open, no hypothesis yet}"
    local preview
    preview=$(printf '%.30s' "$notes")
    local new_row="| $case_id | $ts | active | $preview | — |"
    local attempt=0 index_body current_content new_content body_file rc
    local repo_root="${BL_REPO_ROOT:-$(dirname "$(readlink -f "$0")" 2>/dev/null || printf '.')}"
    while (( attempt < 3 )); do
        index_body=$(bl_api_call GET "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories/bl-case%2FINDEX.md" 2>/dev/null) || {
            current_content=$(command cat "$repo_root/case-templates/INDEX.md" 2>/dev/null || command cat "case-templates/INDEX.md" 2>/dev/null || printf '')
            new_content=$(printf '%s\n%s\n' "$current_content" "$new_row")
            body_file=$(mktemp)
            jq -n --arg k "bl-case/INDEX.md" --arg c "$new_content" \
                '{key:$k, content:$c, metadata:{}}' > "$body_file"
            bl_api_call POST "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories" "$body_file" >/dev/null
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
        local current_sha
        current_sha=$(printf '%s' "$index_body" | jq -r '.content_sha256 // empty')
        body_file=$(mktemp)
        jq -n --arg c "$new_content" --arg s "$current_sha" \
            '{content:$c, if_content_sha256:$s}' > "$body_file"
        bl_api_call PATCH "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories/bl-case%2FINDEX.md" "$body_file" >/dev/null
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
    # bl_consult_new <trigger> <notes> <dedup> — 0/64/65/71; emits case-id to stdout
    local trigger="$1"
    local notes="$2"
    local dedup="$3"
    # BL_MEMSTORE_CASE_ID: read from state file per MUST-FIX 6.2
    BL_MEMSTORE_CASE_ID="${BL_MEMSTORE_CASE_ID:-$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf 'memstore_bl_case')}"
    if [[ -z "$trigger" ]]; then
        bl_error_envelope consult "missing --trigger <artifact>"
        return "$BL_EX_USAGE"
    fi
    local fp
    fp=$(bl_consult_fingerprint_trigger "$trigger") || return $?
    if [[ "$dedup" == "yes" ]]; then
        local existing=""
        existing=$(bl_consult_find_open_case_by_fingerprint "$fp") || existing=""   # miss → empty string, not error
        if [[ -n "$existing" ]]; then
            bl_info "dedup: attaching to existing open case $existing (fingerprint $fp)"
            bl_consult_attach "$existing"
            return $?
        fi
    elif [[ -z "$dedup" ]]; then
        local existing=""
        existing=$(bl_consult_find_open_case_by_fingerprint "$fp") || existing=""   # miss → empty, non-fatal
        [[ -n "$existing" ]] && bl_warn "trigger fingerprint $fp already open in $existing (use --dedup to attach, or proceed for new)"
    fi
    local case_id attempt=0
    while (( attempt < 3 )); do
        case_id=$(bl_consult_allocate_case_id) || return $?
        if bl_consult_materialize_case "$case_id" "$fp" "$notes"; then
            printf '%s' "$case_id" > "$BL_CASE_CURRENT_FILE"
            bl_consult_register_curator "$case_id" "$fp" || true   # non-fatal; outbox queued
            bl_ledger_append "$case_id" \
                "$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$case_id" --arg f "$fp" \
                    '{ts:$ts, case:$c, kind:"case_opened", payload:{trigger_fingerprint:$f}}')"
            bl_info "allocated $case_id"
            printf '%s\n' "$case_id"
            return "$BL_EX_OK"
        fi
        attempt=$((attempt + 1))
        bl_debug "bl_consult_new: materialize conflict (attempt $attempt/3); retrying"
    done
    bl_error_envelope consult "case-id allocation exhausted 3 retries"
    return "$BL_EX_CONFLICT"
}

bl_consult_attach() {
    # bl_consult_attach <case-id> — 0/64/65/69/72
    local case_id="$1"
    BL_MEMSTORE_CASE_ID="${BL_MEMSTORE_CASE_ID:-$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf 'memstore_bl_case')}"
    if [[ -z "$case_id" ]]; then
        bl_error_envelope consult "missing <case-id> for --attach"
        return "$BL_EX_USAGE"
    fi
    local probe_rc=0
    bl_api_call GET "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories/bl-case%2F$case_id%2Fhypothesis.md" >/dev/null || probe_rc=$?
    if (( probe_rc == 65 )); then
        local list_rc=0
        bl_api_call GET "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories?key_prefix=bl-case/$case_id/" >/dev/null || list_rc=$?
        if (( list_rc != 0 )); then
            bl_error_envelope consult "case not found: $case_id"
            return "$BL_EX_NOT_FOUND"
        fi
    elif (( probe_rc != 0 )); then
        return "$probe_rc"
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
    list_body=$(bl_api_call GET "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories?key_prefix=bl-case/&depth=2") || return $?
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
        body=$(bl_api_call GET "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories/${key//\//%2F}" 2>/dev/null) || continue   # skip unreadable
        if [[ -n "$cve" ]]; then
            local hyp
            hyp=$(bl_api_call GET "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories/bl-case%2F$case_id%2Fhypothesis.md" 2>/dev/null) || continue   # skip unreadable
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

