# shellcheck shell=bash
_bl_ledger_event_json() {
    # _bl_ledger_event_json <ts> <case-id> <kind> <payload-json> — schema-conformant ledger event JSON; private (M9 P7)
    local ts="$1" case_id="$2" kind="$3" payload="$4"
    jq -n --arg ts "$ts" --arg c "$case_id" --arg k "$kind" --argjson p "$payload" \
        '{ts:$ts, case:$c, kind:$k, payload:$p}'
}

bl_case() {
    # bl_case <subcommand> [args] — route to _show/_log/_list/_close/_reopen
    local sub="${1:-show}"
    [[ "$sub" != -* && $# -ge 1 ]] && shift
    case "$sub" in
        show)    bl_case_show "$@"; return $? ;;
        log)     bl_case_log "$@"; return $? ;;
        list)    bl_case_list "$@"; return $? ;;
        close)   bl_case_close "$@"; return $? ;;
        reopen)  bl_case_reopen "$@"; return $? ;;
        -h|--help|help)
            printf 'Usage: bl case <show|log|list|close|reopen> [args]\n' >&2
            return "$BL_EX_OK"
            ;;
        *)
            bl_error_envelope case "unknown subcommand: $sub" "(use show / log / list / close / reopen)"
            return "$BL_EX_USAGE"
            ;;
    esac
}
bl_case_show() {
    # bl_case_show [case-id] — 6-section summary; 0/64/69/72
    local case_id="${1:-}"
    BL_MEMSTORE_CASE_ID="${BL_MEMSTORE_CASE_ID:-$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf 'memstore_bl_case')}"
    [[ -z "$case_id" ]] && case_id=$(bl_case_current)
    [[ -z "$case_id" ]] && { bl_error_envelope case "no active case"; return "$BL_EX_NOT_FOUND"; }
    printf '# Case %s\n' "$case_id"
    printf '\n## Hypothesis\n'
    bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/hypothesis.md" 2>/dev/null | jq -r '.content // "(not found)"' || printf '(not found)\n'
    printf '\n## Evidence\n'
    bl_mem_list "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/evidence/" 2>/dev/null | jq -r '.data[].key' || printf '(none)\n'
    printf '\n## Pending steps\n'
    bl_mem_list "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/pending/" 2>/dev/null | jq -r '.data[].key' || printf '(none)\n'
    printf '\n## Applied actions\n'
    bl_mem_list "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/actions/applied/" 2>/dev/null | jq -r '.data[].key' || printf '(none)\n'
    printf '\n## Defense hits\n'
    bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/defense-hits.md" 2>/dev/null | jq -r '.content // "(none)"' || printf '(none)\n'
    printf '\n## Open questions\n'
    bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/open-questions.md" 2>/dev/null | jq -r '.content // "(none)"' || printf '(none)\n'
    local closed_list
    closed_list=$(bl_mem_list "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/closed-" 2>/dev/null | jq -r '.data[].key' || printf '')
    if [[ -n "$closed_list" ]]; then
        printf '\n## Previous closures\n%s\n' "$closed_list"
    fi
    return "$BL_EX_OK"
}

bl_case_log() {
    # bl_case_log [case-id] [--audit] — JSONL to stdout; --audit appends per-kind summary + outbox fence decode (M11.1); 0/64/69/72
    local case_id="" audit=""
    while (( $# > 0 )); do
        case "$1" in
            --audit) audit="yes"; shift ;;
            -*)      bl_error_envelope case "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)       case_id="$1"; shift ;;
        esac
    done
    [[ -z "$case_id" ]] && case_id=$(bl_case_current)
    [[ -z "$case_id" ]] && { bl_error_envelope case "no active case"; return "$BL_EX_NOT_FOUND"; }
    local ledger_file="$BL_VAR_DIR/ledger/$case_id.jsonl"
    local all_events
    all_events=$(mktemp)
    [[ -r "$ledger_file" ]] && command cat "$ledger_file" >> "$all_events"
    command sort -t'"' -k4 "$all_events"
    if [[ "$audit" == "yes" ]]; then
        printf '\n=== Audit: %s ===\n' "$case_id"
        printf '\nLedger kinds:\n'
        if [[ -s "$all_events" ]]; then
            jq -r '.kind' < "$all_events" | command sort | command uniq -c | command awk '{printf "  %-25s : %d\n", $2, $1}'
        else
            printf '  (no ledger entries)\n'
        fi
        printf '\nOutbox fence audit (wake entries):\n'
        local outbox_dir="$BL_VAR_DIR/outbox"
        local found=0 f fenced kind
        if [[ -d "$outbox_dir" ]]; then
            local glob_pending="$outbox_dir/*-wake-${case_id}*.json"
            local glob_failed="$outbox_dir/failed/*-wake-${case_id}*.json"
            # shellcheck disable=SC2231  # intentional glob expansion; missing matches handled by [[ -r ]] guard
            for f in $glob_pending $glob_failed; do
                [[ -r "$f" ]] || continue
                fenced=$(jq -r '.trigger_fingerprint_fenced // empty' "$f" 2>/dev/null)   # 2>/dev/null: malformed JSON → empty fenced → skip
                [[ -z "$fenced" ]] && continue
                kind=$(bl_fence_kind "$fenced" 2>/dev/null) || kind="(decode failed)"   # 2>/dev/null: decode error envelope is captured separately via fallback string
                printf '  %s  fence_kind=%s\n' "$(command basename "$f")" "$kind"
                found=$((found + 1))
            done
        fi
        (( found == 0 )) && printf '  (no fence-wrapped wake entries in outbox)\n'
    fi
    command rm -f "$all_events"
    return "$BL_EX_OK"
}

bl_case_list() {
    # bl_case_list [--open|--closed|--all] — 0/64/69
    local filter="${1:---open}"
    BL_MEMSTORE_CASE_ID="${BL_MEMSTORE_CASE_ID:-$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf 'memstore_bl_case')}"
    local status_match
    case "$filter" in
        --open)    status_match="active" ;;
        --closed)  status_match="closed" ;;
        --all)     status_match=".*" ;;
        *)         bl_error_envelope case "unknown filter: $filter"; return "$BL_EX_USAGE" ;;
    esac
    local index_body
    index_body=$(bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/INDEX.md" 2>/dev/null | jq -r '.content')
    if [[ -z "$index_body" ]]; then
        bl_info "(no cases in workspace)"
        return "$BL_EX_OK"
    fi
    printf '%s' "$index_body" | grep -E '^\| CASE-[0-9]{4}-[0-9]{4} \|' | awk -F'|' -v s="$status_match" '$4 ~ s {print}'
    return "$BL_EX_OK"
}

bl_case_update_index_status() {
    # bl_case_update_index_status <case-id> <new-status> — 0/69/70/71
    # Shared helper: bl_case_close_update_index + bl_case_reopen use this.
    # MUST-FIX 5.2 resolution: extracted from close flow so reopen can call it too.
    local case_id="$1"
    local new_status="$2"
    local attempt=0
    while (( attempt < 3 )); do
        local index_body current_content new_content body_file rc
        index_body=$(bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/INDEX.md") || return $?
        current_content=$(printf '%s' "$index_body" | jq -r '.content')
        # Replace the status cell for this case row
        new_content=$(printf '%s' "$current_content" | sed -E "s|(\| $case_id \|[^|]+\|) [a-z]+ (\|.*\|)|\1 $new_status \2|")
        body_file=$(mktemp)
        printf '%s' "$new_content" > "$body_file"
        bl_mem_patch "${BL_MEMSTORE_CASE_ID}" "bl-case/INDEX.md" "$body_file"   # last-write-wins
        rc=$?
        command rm -f "$body_file"
        (( rc == 0 )) && return "$BL_EX_OK"
        attempt=$((attempt + 1))
    done
    return "$BL_EX_CONFLICT"
}

bl_case_close_validate_preconditions() {
    # bl_case_close_validate_preconditions <case-id> <force> — 0/68/69
    local case_id="$1"
    local force="$2"
    local oq_body oq_content
    oq_body=$(bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/open-questions.md" 2>/dev/null | jq -r '.content')
    oq_content=$(printf '%s' "$oq_body" | grep -vE '^<!--|^# |^$' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    if [[ -n "$oq_content" && "$oq_content" != "none" ]]; then
        bl_error_envelope case "open-questions.md has unresolved entries (expected 0 or 'none')"
        return "$BL_EX_TIER_GATE_DENIED"
    fi
    local pending results
    pending=$(bl_mem_list "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/pending/" 2>/dev/null | jq -r '.data[].key' | sed "s|bl-case/$case_id/pending/||")
    results=$(bl_mem_list "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/results/" 2>/dev/null | jq -r '.data[].key' | sed "s|bl-case/$case_id/results/||")
    local missing
    missing=$(comm -23 <(printf '%s\n' "$pending" | sort) <(printf '%s\n' "$results" | sort))
    if [[ -n "$missing" ]]; then
        bl_error_envelope case "pending steps without results: $(printf '%s' "$missing" | head -3 | tr '\n' ' ')"
        return "$BL_EX_TIER_GATE_DENIED"
    fi
    local applied_keys missing_hint=0
    applied_keys=$(bl_mem_list "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/actions/applied/" 2>/dev/null | jq -r '.data[].key')
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        local applied_content
        applied_content=$(bl_mem_get "${BL_MEMSTORE_CASE_ID}" "$k" 2>/dev/null | jq -r '.content')
        printf '%s' "$applied_content" | grep -q '^retire_hint:' || { missing_hint=1; break; }
    done <<< "$applied_keys"
    if (( missing_hint == 1 )); then
        bl_error_envelope case "at least one applied action lacks retire_hint"
        return "$BL_EX_TIER_GATE_DENIED"
    fi
    if [[ "$force" != "yes" ]]; then
        local hyp_body confidence
        hyp_body=$(bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/hypothesis.md" 2>/dev/null | jq -r '.content')
        confidence=$(printf '%s' "$hyp_body" | awk '/^## Confidence/{flag=1; next} flag && /^0?\.[0-9]+|^[0-9]+(\.[0-9]+)?/{print; exit}' | grep -oE '[0-9]+\.?[0-9]*' | head -1)
        if [[ -z "$confidence" ]] || awk "BEGIN{exit !($confidence < 0.7)}"; then
            bl_error_envelope case "hypothesis confidence < 0.7 (use --force to override)"
            return "$BL_EX_TIER_GATE_DENIED"
        fi
    fi
    return "$BL_EX_OK"
}

bl_case_close_render_brief_input() {
    # bl_case_close_render_brief_input <case-id> — prints brief-input path on stdout; 0/69
    local case_id="$1"
    local out
    # mktemp instead of `$$`-suffixed predictable name (workspace standard).
    out=$(command mktemp "/tmp/bl-brief-${case_id}.XXXXXX.md") || {
        bl_error_envelope case "mktemp failed for brief input"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    {
        printf '# Case %s\n\n' "$case_id"
        printf '## Executive summary\n'
        bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/hypothesis.md" 2>/dev/null | jq -r '.content' || printf '(hypothesis unavailable)\n'
        printf '\n## Kill chain\n'
        bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/attribution.md" 2>/dev/null | jq -r '.content' || printf '(not populated)\n'
        printf '\n## Indicators of compromise\n'
        for f in ip-clusters url-patterns file-patterns; do
            bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/$f.md" 2>/dev/null | jq -r '.content' || printf '\n'
        done
        printf '\n## Remediation applied\n'
        bl_mem_list "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/actions/applied/" 2>/dev/null | jq -r '.data[].key' || printf '(none)\n'
        printf '\n## Defense hits\n'
        bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/defense-hits.md" 2>/dev/null | jq -r '.content' | tail -30 || printf '(none)\n'
        printf '\n## Open questions resolved\nnone at close\n'
        printf '\n## Audit\nSee /var/lib/bl/ledger/%s.jsonl\n' "$case_id"
    } > "$out"
    printf '%s' "$out"
    return "$BL_EX_OK"
}

bl_case_close_write_closed_md() {
    # bl_case_close_write_closed_md <case-id> <fid-md> <fid-html> <fid-pdf> — 0/69/70
    local case_id="$1"
    local fid_md="$2"
    local fid_html="$3"
    local fid_pdf="$4"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local repo_root="${BL_REPO_ROOT:-$(dirname "$(readlink -f "$0")" 2>/dev/null || printf '.')}"
    local template_content
    template_content=$(command cat "$repo_root/case-templates/closed.md" 2>/dev/null || command cat "case-templates/closed.md")
    local closed_content
    closed_content=$(printf '%s' "$template_content" | \
        sed "s|{CASE_ID}|$case_id|g; s|{ISO_8601_TIMESTAMP}|$now|")
    closed_content=$(printf '%s' "$closed_content" | awk -v md="$fid_md" -v pdf="$fid_pdf" -v html="$fid_html" '
        /brief_file_id_md:/  { sub(/\{FILE_ID_OR_EMPTY\}/, md) }
        /brief_file_id_pdf:/ { sub(/\{FILE_ID_OR_EMPTY\}/, pdf) }
        /brief_file_id_html:/{ sub(/\{FILE_ID_OR_EMPTY\}/, html) }
        {print}')
    local body_file
    body_file=$(mktemp)
    printf '%s' "$closed_content" > "$body_file"
    bl_mem_post "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/closed.md" "$body_file"
    local rc=$?
    command rm -f "$body_file"
    return "$rc"
}

bl_case_close_schedule_retire() {
    # bl_case_close_schedule_retire <case-id> — 0/65; queues retire-hint entries
    local case_id="$1"
    local queue_file="$BL_VAR_DIR/state/retire-queue.jsonl"
    command mkdir -p "$BL_VAR_DIR/state" 2>/dev/null || return "$BL_EX_PREFLIGHT_FAIL"   # RO fs / perms
    local applied_keys
    applied_keys=$(bl_mem_list "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/actions/applied/" 2>/dev/null | jq -r '.data[].key')
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        local body act_id hint
        body=$(bl_mem_get "${BL_MEMSTORE_CASE_ID}" "$k" 2>/dev/null | jq -r '.content')
        act_id=$(printf '%s' "$body" | grep '^act_id:' | awk '{print $2}')
        hint=$(printf '%s' "$body" | grep '^retire_hint:' | cut -d' ' -f2-)
        [[ -n "$act_id" && -n "$hint" ]] || continue   # malformed → skip
        jq -n --arg c "$case_id" --arg a "$act_id" --arg h "$hint" \
            '{case:$c, act_id:$a, retire_when:$h, retire_cond:$h}' >> "$queue_file"
    done <<< "$applied_keys"
    return "$BL_EX_OK"
}

bl_case_close_stage2_render() {
    # bl_case_close_stage2_render <case-id> <fid-md> <out-html-var> <out-pdf-var> — 0/69/70
    # Polls files.list(scope_id=$session_id) for up to 60s for agent-produced brief.{html,pdf}.
    # Returns via printf '<html_id>|<pdf_id>' to stdout; caller uses IFS=| read.
    local case_id="$1"
    local fid_md="$2"
    local session_id=""
    [[ -r "$BL_STATE_DIR/session-$case_id" ]] && session_id=$(command cat "$BL_STATE_DIR/session-$case_id")
    if [[ -z "${session_id:-}" ]]; then
        bl_warn "no session for $case_id; skipping stage-2 render"
        printf '|'
        return "$BL_EX_UPSTREAM_ERROR"
    fi
    local wake_body
    wake_body=$(mktemp)
    jq -n --arg m "$fid_md" --arg c "$case_id" \
        '{type:"user.message", content:[{type:"text", text:("render file_id="+$m+" to HTML and PDF; write to /mnt/session/outputs/brief-"+$c+".{html,pdf}")}]}' > "$wake_body"
    bl_api_call POST "/v1/sessions/$session_id/events" "$wake_body" >/dev/null || {
        command rm -f "$wake_body"
        printf '|'
        return "$BL_EX_UPSTREAM_ERROR"
    }
    command rm -f "$wake_body"
    local attempts=0 files_body html_id="" pdf_id=""
    while (( attempts < 12 )); do
        sleep 5
        files_body=$(bl_api_call GET "/v1/files?scope_id=$session_id&limit=50" 2>/dev/null) || true   # transient miss
        html_id=$(printf '%s' "$files_body" | jq -r ".data[] | select(.filename == \"brief-$case_id.html\") | .id" | head -1)
        pdf_id=$(printf '%s' "$files_body" | jq -r ".data[] | select(.filename == \"brief-$case_id.pdf\") | .id" | head -1)
        [[ -n "$html_id" && -n "$pdf_id" ]] && break
        attempts=$((attempts + 1))
    done
    printf '%s|%s' "$html_id" "$pdf_id"
    if [[ -z "$html_id" || -z "$pdf_id" ]]; then
        bl_warn "curator render did not complete within 60s"
        return "$BL_EX_UPSTREAM_ERROR"
    fi
    return "$BL_EX_OK"
}

bl_case_close() {
    # bl_case_close [case-id] [--force] — 0/64/68/69/72; 12-step flow per spec §5.3.1
    local case_id="" force=""
    BL_MEMSTORE_CASE_ID="${BL_MEMSTORE_CASE_ID:-$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf 'memstore_bl_case')}"
    while (( $# > 0 )); do
        case "$1" in
            --force) force="yes"; shift ;;
            -*)      bl_error_envelope case "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)       case_id="$1"; shift ;;
        esac
    done
    [[ -z "$case_id" ]] && case_id=$(bl_case_current)
    [[ -z "$case_id" ]] && { bl_error_envelope case "no active case"; return "$BL_EX_NOT_FOUND"; }
    local checkpoint="$BL_STATE_DIR/close-checkpoint-$case_id.json"
    bl_case_close_validate_preconditions "$case_id" "$force" || return $?
    local brief_path
    brief_path=$(bl_case_close_render_brief_input "$case_id") || return $?
    local fid_md
    fid_md=$(bl_files_api_upload "text/markdown" "$brief_path")
    local up_rc=$?
    if (( up_rc != 0 )); then
        bl_error_envelope case "brief MD upload failed (rc=$up_rc)"
        command rm -f "$brief_path"
        return "$BL_EX_UPSTREAM_ERROR"
    fi
    bl_info "uploaded text/markdown → $fid_md"
    local fid_html="" fid_pdf=""
    if [[ "${BL_BRIEF_MIMES:-text/markdown,text/html,application/pdf}" =~ text/html|application/pdf ]]; then
        local render_out
        render_out=$(bl_case_close_stage2_render "$case_id" "$fid_md") || bl_warn "stage-2 render degraded; closing with MD only"
        if [[ -n "$render_out" ]]; then
            IFS='|' read -r fid_html fid_pdf <<< "$render_out"
        fi
    fi
    bl_case_close_write_closed_md "$case_id" "$fid_md" "$fid_html" "$fid_pdf" || {
        jq -n --arg c "$case_id" --arg m "$fid_md" --arg h "$fid_html" --arg p "$fid_pdf" \
            '{case:$c, fid_md:$m, fid_html:$h, fid_pdf:$p, phase:"closed_md_pending"}' > "$checkpoint"
        command rm -f "$brief_path"
        return "$BL_EX_UPSTREAM_ERROR"
    }
    bl_case_update_index_status "$case_id" "closed" || {
        jq -n --arg c "$case_id" '{case:$c, phase:"index_pending"}' > "$checkpoint"
        command rm -f "$brief_path"
        return "$BL_EX_CONFLICT"
    }
    bl_case_close_schedule_retire "$case_id"
    [[ -f "$BL_CASE_CURRENT_FILE" ]] && command rm -f "$BL_CASE_CURRENT_FILE"
    bl_ledger_append "$case_id" \
        "$(_bl_ledger_event_json "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$case_id" "case_closed" \
            "$(jq -n --arg m "$fid_md" --arg h "$fid_html" --arg p "$fid_pdf" '{brief_file_ids:{md:$m, html:$h, pdf:$p}}')")"
    [[ -f "$checkpoint" ]] && command rm -f "$checkpoint"
    command rm -f "$brief_path"
    bl_info "$case_id closed"
    return "$BL_EX_OK"
}

bl_case_reopen() {
    # bl_case_reopen <case-id> --reason <str> — 0/64/69/72
    local case_id="" reason=""
    BL_MEMSTORE_CASE_ID="${BL_MEMSTORE_CASE_ID:-$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf 'memstore_bl_case')}"
    while (( $# > 0 )); do
        case "$1" in
            --reason) reason="$2"; shift 2 ;;
            -*)       bl_error_envelope case "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)        case_id="$1"; shift ;;
        esac
    done
    [[ -z "$case_id" ]] && { bl_error_envelope case "missing <case-id>"; return "$BL_EX_USAGE"; }
    [[ -z "$reason" ]] && { bl_error_envelope case "missing --reason <str>"; return "$BL_EX_USAGE"; }
    local closed_body
    closed_body=$(bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/closed.md")
    local rc=$?
    (( rc != 0 )) && { bl_error_envelope case "case is not closed (closed.md not found)"; return "$BL_EX_USAGE"; }
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local archive_key="bl-case/$case_id/closed-$ts.md"
    local content body_file
    content=$(printf '%s' "$closed_body" | jq -r '.content')
    body_file=$(mktemp)
    printf '%s' "$content" > "$body_file"
    bl_mem_post "${BL_MEMSTORE_CASE_ID}" "$archive_key" "$body_file" || {
        command rm -f "$body_file"
        return "$BL_EX_UPSTREAM_ERROR"
    }
    command rm -f "$body_file"
    bl_mem_delete_by_key "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/closed.md" || bl_warn "original closed.md delete failed"
    # MUST-FIX 5.2: update INDEX status to reopened via shared helper
    bl_case_update_index_status "$case_id" "reopened" || bl_warn "INDEX update failed on reopen; manual correction may be needed"
    bl_ledger_append "$case_id" \
        "$(_bl_ledger_event_json "$ts" "$case_id" "case_reopened" \
            "$(jq -n --arg r "$reason" '{reason:$r}')")"
    bl_info "$case_id reopened"
    return "$BL_EX_OK"
}

# ----------------------------------------------------------------------------
# Main dispatcher — flag-sniff first (help/version/setup bypass preflight),
# else preflight → verb-case → handler.
# ----------------------------------------------------------------------------

