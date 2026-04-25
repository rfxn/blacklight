# shellcheck shell=bash

# _bl_obs_render_summary_deterministic stage_dir case_id host_label now_ts hypothesis ts_min ts_max — fallback summary.md (Sonnet bypass / failure path).
# File scope (not nested) — bash function definitions inside another function leak to global on each invocation.
_bl_obs_render_summary_deterministic() {
    local stage_dir="$1" case_id="$2" host_label="$3" now_ts="$4"
    local hypothesis="$5" ts_min="$6" ts_max="$7"
    {
        printf '# Bundle summary\n\n'
        printf '**Case:** %s\n' "$case_id"
        printf '**Host:** %s\n' "$host_label"
        printf '**Generated:** %s\n\n' "$now_ts"
        printf '## Trigger / hypothesis\n\n%s\n\n' "$hypothesis"
        printf '## Evidence window\n\n- From: %s\n- To:   %s\n\n' "$ts_min" "$ts_max"
        printf '## Sources present\n\n'
        local sf sname rcnt
        while IFS= read -r sf; do
            sname=$(command basename "$sf" .jsonl)
            rcnt=$(command wc -l < "$sf" | command awk '{print $1}')
            printf -- '- %s (%s records)\n' "$sname" "$rcnt"
        done < <(command find "$stage_dir" -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null | command sort)   # EACCES on stage jsonl files — partial entries acceptable
    } > "$stage_dir/summary.md"
}

bl_bundle_build() {
    local format_arg="auto" since_arg="" out_dir_arg=""
    local no_llm=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format)         format_arg="$2"; shift 2 ;;
            --since)          since_arg="$2"; shift 2 ;;
            --out-dir)        out_dir_arg="$2"; shift 2 ;;
            --no-llm-summary) no_llm="yes"; shift ;;
            *)                bl_error_envelope observe "bundle: unknown option: $1"; return "$BL_EX_USAGE" ;;
        esac
    done

    bl_init_workdir || return "$?"

    local case_id
    case_id="$(bl_case_current)"
    if [[ -z "$case_id" ]]; then
        bl_error_envelope observe "bundle: no active case (run bl consult --new first)"
        return "$BL_EX_NOT_FOUND"
    fi

    local out_dir="${out_dir_arg:-$BL_VAR_DIR/outbox}"
    command mkdir -p "$out_dir"

    local codec
    codec="$(_bl_obs_codec_detect "$format_arg")" || return "$?"

    local stage_dir
    stage_dir=$(command mktemp -d)
    # Explicit cleanup before each return; trap as belt-and-suspenders
    # shellcheck disable=SC2064  # stage_dir must expand now — value set before trap, cleanup is correct
    trap "command rm -rf '$stage_dir'" EXIT

    local evidence_dir="$BL_VAR_DIR/cases/$case_id/evidence"
    if [[ ! -d "$evidence_dir" ]]; then
        bl_error_envelope observe "bundle: no evidence directory at $evidence_dir"
        command rm -rf "$stage_dir"
        return "$BL_EX_NOT_FOUND"
    fi

    # Filter by --since if provided
    local since_epoch=0
    if [[ -n "$since_arg" ]]; then
        # CentOS 6 coreutils (date 8.4) rejects ISO-8601 "T...Z" — normalize to
        # the space-form that parses on c6 and modern coreutils alike.
        local since_norm="${since_arg/T/ }"; since_norm="${since_norm/%Z/ UTC}"
        # GNU date -d parses ISO strings; BSD date -j -f is the portable fallback
        since_epoch=$(command date -d "$since_norm" +%s 2>/dev/null) || since_epoch=$(command date -j -f '%Y-%m-%dT%H:%M:%SZ' "$since_arg" +%s 2>/dev/null) || since_epoch=0   # GNU date -d first; BSD -j -f fallback; zero disables since filter
    fi

    # Enumerate evidence files ordered by mtime
    local file_list
    file_list=$(command find "$evidence_dir" -maxdepth 1 -name 'obs-*.json' -type f -printf '%T@\t%p\n' 2>/dev/null | command sort -n | command cut -f2)   # BSD find lacks -printf; fallback on next line reads each file
    if [[ -z "$file_list" ]]; then
        # BSD fallback: no -printf
        file_list=$(command find "$evidence_dir" -maxdepth 1 -name 'obs-*.json' -type f 2>/dev/null | while IFS= read -r f; do   # BSD fallback find without -printf; EACCES on locked files skipped
            local mt
            mt=$(command stat -c '%Y' "$f" 2>/dev/null) || mt=$(command stat -f '%m' "$f" 2>/dev/null) || mt=0   # GNU stat; BSD -f fallback; zero on error acceptable
            printf '%s\t%s\n' "$mt" "$f"
        done | command sort -n | command cut -f2)
    fi

    # Group evidence records by source taxonomy (13 types per schemas/evidence-envelope.md §2)
    # Grouping is dynamic via jq .source field; no static enumeration needed here.
    local total_size=0
    while IFS= read -r evidence_file; do
        [[ -z "$evidence_file" || ! -r "$evidence_file" ]] && continue
        # Apply --since filter
        if (( since_epoch > 0 )); then
            local file_mt
            # GNU stat -c '%Y'; BSD fallback -f '%m'
            file_mt=$(command stat -c '%Y' "$evidence_file" 2>/dev/null) || file_mt=$(command stat -f '%m' "$evidence_file" 2>/dev/null) || file_mt=0   # GNU stat first; BSD -f fallback; zero skips since filter
            (( file_mt < since_epoch )) && continue
        fi
        while IFS= read -r jline; do
            [[ -z "$jline" ]] && continue
            local src
            src=$(printf '%s' "$jline" | jq -r '.source // ""' 2>/dev/null) || continue   # jq source field extraction; malformed lines skipped
            [[ -z "$src" ]] && continue
            local target_file="$stage_dir/${src}.jsonl"
            printf '%s\n' "$jline" >> "$target_file"
        done < "$evidence_file"
    done <<< "$file_list"

    # Remove zero-byte staged files
    while IFS= read -r sf; do
        [[ -s "$sf" ]] || command rm -f "$sf"
    done < <(command find "$stage_dir" -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null)   # EACCES on restricted stage files — partial results acceptable

    # Accumulate size
    while IFS= read -r sf; do
        local sz
        sz=$(command stat -c '%s' "$sf" 2>/dev/null) || sz=$(command stat -f '%z' "$sf" 2>/dev/null) || sz=0   # GNU stat; BSD fallback; zero on error acceptable
        total_size=$(( total_size + sz ))
    done < <(command find "$stage_dir" -maxdepth 1 -type f 2>/dev/null)   # EACCES on stage dir files — partial results acceptable

    if (( total_size > 500 * 1024 * 1024 )); then
        bl_error_envelope observe "bundle: uncompressed bundle exceeds 500 MB hard cap ($((total_size / 1024 / 1024)) MB)"
        command rm -rf "$stage_dir"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    if (( total_size > 100 * 1024 * 1024 )); then
        bl_warn "bundle large ($((total_size / 1024 / 1024)) MB) — curator Files API upload may reject"
    fi

    # Window derivation
    local ts_min="" ts_max=""
    while IFS= read -r sf; do
        local t_min t_max
        t_min=$(jq -rs 'map(.ts) | min // empty' "$sf" 2>/dev/null) || continue   # jq may fail on empty file; skip with || continue
        t_max=$(jq -rs 'map(.ts) | max // empty' "$sf" 2>/dev/null) || continue   # jq may fail on empty file; skip with || continue
        [[ -z "$ts_min" || "$t_min" < "$ts_min" ]] && ts_min="$t_min"
        [[ -z "$ts_max" || "$t_max" > "$ts_max" ]] && ts_max="$t_max"
    done < <(command find "$stage_dir" -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null)   # EACCES on stage jsonl files — skip with || continue

    # summary.md
    local hypothesis="ad-hoc observation bundle (no active hypothesis)"
    local hyp_file="$BL_VAR_DIR/cases/$case_id/hypothesis.md"
    if [[ -r "$hyp_file" && -s "$hyp_file" ]]; then
        hypothesis=$(command grep -m 1 -v '^[[:space:]]*$' "$hyp_file" | command head -1) || hypothesis="ad-hoc observation bundle"
    fi

    local now_ts
    now_ts="$(_bl_obs_ts_iso8601)"
    local host_label
    host_label="$(_bl_obs_host_label)"

    # Sonnet 4.6 path: render summary.md via bl_messages_call (M11 P3).
    # Falls back to deterministic helper on --no-llm-summary, BL_DISABLE_LLM=1,
    # missing system prompt, or any non-zero rc / empty output from the API.
    if [[ "$no_llm" == "yes" || "${BL_DISABLE_LLM:-}" == "1" ]]; then
        _bl_obs_render_summary_deterministic "$stage_dir" "$case_id" "$host_label" "$now_ts" "$hypothesis" "${ts_min:-unknown}" "${ts_max:-unknown}"
    else
        local repo_root="${BL_REPO_ROOT:-$(command dirname "$(readlink -f "$0" 2>/dev/null || printf '.')" 2>/dev/null)}"   # 2>/dev/null: readlink may fail under bash -c with empty $0 → cwd fallback
        local sys_prompt="$repo_root/prompts/bundle-summary-system.md"
        if [[ ! -r "$sys_prompt" ]]; then
            bl_warn "bundle: prompts/bundle-summary-system.md missing — fallback to deterministic summary"
            _bl_obs_render_summary_deterministic "$stage_dir" "$case_id" "$host_label" "$now_ts" "$hypothesis" "${ts_min:-unknown}" "${ts_max:-unknown}"
        else
            local user_msg
            user_msg=$(command mktemp)
            {
                printf 'Case: %s\nHost: %s\nGenerated: %s\nHypothesis: %s\nWindow: %s → %s\n\nSources present:\n' \
                    "$case_id" "$host_label" "$now_ts" "$hypothesis" "${ts_min:-unknown}" "${ts_max:-unknown}"
                while IFS= read -r sf; do
                    local sname rcnt
                    sname=$(command basename "$sf" .jsonl)
                    rcnt=$(command wc -l < "$sf" | command awk '{print $1}')
                    printf -- '- %s (%s records)\n' "$sname" "$rcnt"
                done < <(command find "$stage_dir" -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null | command sort)   # EACCES on stage jsonl files — partial entries acceptable
                printf '\nFirst 50 records (concatenated, JSONL):\n'
                command find "$stage_dir" -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null \
                    | command sort | command head -1 \
                    | { while IFS= read -r f; do command head -50 "$f"; done; }
            } > "$user_msg"
            local sonnet_out="" sonnet_rc=0
            # `|| sonnet_rc=$?` neutralizes set -e for the API call so non-zero
            # rc (auth/5xx/429) routes through the explicit fallback below.
            sonnet_out=$(bl_messages_call claude-sonnet-4-6 "$sys_prompt" "$user_msg" 1500) || sonnet_rc=$?
            command rm -f "$user_msg"
            if (( sonnet_rc == 0 )) && [[ -n "$sonnet_out" ]]; then
                # Truncate at line boundary near 2KB to avoid mid-UTF-8 byte split (DESIGN.md §10.3 size budget).
                printf '%s\n' "$sonnet_out" | command awk 'BEGIN{n=0} {if (n+length($0)+1 <= 2048) {print; n+=length($0)+1} else exit}' > "$stage_dir/summary.md"
                bl_debug "bundle: summary.md rendered by claude-sonnet-4-6"
            else
                bl_warn "bundle: Sonnet summary unavailable (rc=$sonnet_rc) — fallback to deterministic"
                _bl_obs_render_summary_deterministic "$stage_dir" "$case_id" "$host_label" "$now_ts" "$hypothesis" "${ts_min:-unknown}" "${ts_max:-unknown}"
            fi
        fi
    fi

    # Build entries array for MANIFEST
    local entries_json='[]'
    while IFS= read -r sf; do
        local sname sha sz rcnt
        sname=$(command basename "$sf")
        sha=""
        if command -v sha256sum >/dev/null 2>&1; then
            sha=$(command sha256sum "$sf" | command awk '{print $1}')
        elif command -v shasum >/dev/null 2>&1; then
            sha=$(command shasum -a 256 "$sf" | command awk '{print $1}')
        fi
        sz=$(command stat -c '%s' "$sf" 2>/dev/null) || sz=$(command stat -f '%z' "$sf" 2>/dev/null) || sz=0   # GNU stat; BSD fallback; zero on error acceptable
        rcnt=$(command wc -l < "$sf" | command awk '{print $1}')
        entries_json=$(printf '%s' "$entries_json" | jq -c \
            --arg path "$sname" \
            --arg source "${sname%.jsonl}" \
            --arg sha256 "$sha" \
            --argjson size_bytes "$sz" \
            --argjson record_count "$rcnt" \
            '. + [{path:$path,source:$source,sha256:$sha256,size_bytes:$size_bytes,record_count:$record_count}]' 2>/dev/null) || true   # jq append may fail if entries_json malformed; || true skips gracefully
    done < <(command find "$stage_dir" -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null | command sort)   # EACCES on stage jsonl files — partial entries acceptable

    # Window string for filename
    local window_str="full"
    if [[ -n "$since_arg" ]]; then
        local now_safe
        now_safe=$(command date -u +%Y-%m-%dT%H-%M-%SZ 2>/dev/null)   # BSD date -u; may lack %3N format; fallback uses second precision
        local since_safe="${since_arg//:/-}"
        window_str="${since_safe}-to-${now_safe}"
    fi

    local host_safe="${host_label//./_}"
    local bundle_path="$out_dir/bundle-${host_safe}-${window_str}.tgz"

    # MANIFEST.json
    jq -n -c \
        --arg bl_version "$BL_VERSION" \
        --arg codec "$codec" \
        --arg host "$host_label" \
        --arg case_id "$case_id" \
        --arg generated_at "$now_ts" \
        --arg window_from "${ts_min:-}" \
        --arg window_to "${ts_max:-}" \
        --argjson entries "$entries_json" \
        --argjson total_size_bytes "$total_size" \
        '{bl_version:$bl_version,codec:$codec,host:$host,case_id:$case_id,generated_at:$generated_at,window:{from:$window_from,to:$window_to},entries:$entries,total_size_bytes:$total_size_bytes,total_record_count:($entries | map(.record_count) | add // 0)}' \
        > "$stage_dir/MANIFEST.json"

    # Compress
    case "$codec" in
        gz)  command tar -cf - -C "$stage_dir" . | command gzip -5 > "$bundle_path" ;;
        zst) command tar -cf - -C "$stage_dir" . | command zstd -3 -o "$bundle_path" ;;
    esac

    command rm -rf "$stage_dir"
    trap - EXIT   # disarm trap after explicit cleanup

    local final_size
    final_size=$(command stat -c '%s' "$bundle_path" 2>/dev/null) || final_size=$(command stat -f '%z' "$bundle_path" 2>/dev/null) || final_size=0   # GNU stat; BSD fallback; zero on error acceptable
    bl_info "bundle: $bundle_path ($((final_size / 1024)) KB)"
    printf '%s\n' "$bundle_path"
    return "$BL_EX_OK"
}

# === M4-HANDLERS-END ===

# ---------------------------------------------------------------------------
# bl_observe — top-level dispatcher (replaces M1 stub)
# ---------------------------------------------------------------------------
bl_observe() {
    local sub="${1:-}"
    if [[ -z "$sub" ]]; then
        bl_error_envelope observe "missing sub-verb (use \`bl --help\` for usage)"
        return "$BL_EX_USAGE"
    fi
    shift
    case "$sub" in
        file)     bl_observe_file "$@"; return $? ;;
        log)
            local kind="${1:-}"
            if [[ -z "$kind" ]]; then
                bl_error_envelope observe "missing log kind (use apache|modsec|journal)"
                return "$BL_EX_USAGE"
            fi
            shift
            case "$kind" in
                apache)  bl_observe_log_apache "$@"; return $? ;;
                modsec)  bl_observe_log_modsec "$@"; return $? ;;
                journal) bl_observe_log_journal "$@"; return $? ;;
                *)
                    bl_error_envelope observe "unknown log kind: $kind (use apache|modsec|journal)"
                    return "$BL_EX_USAGE"
                    ;;
            esac
            ;;
        cron)     bl_observe_cron "$@"; return $? ;;
        proc)     bl_observe_proc "$@"; return $? ;;
        htaccess) bl_observe_htaccess "$@"; return $? ;;
        fs)
            case "${1:-}" in
                --mtime-cluster) shift; bl_observe_fs_mtime_cluster "$@"; return $? ;;
                --mtime-since)   shift; bl_observe_fs_mtime_since   "$@"; return $? ;;
                *)
                    bl_error_envelope observe "fs requires --mtime-cluster or --mtime-since"
                    return "$BL_EX_USAGE"
                    ;;
            esac
            ;;
        firewall) bl_observe_firewall "$@"; return $? ;;
        sigs)     bl_observe_sigs "$@"; return $? ;;
        substrate) bl_observe_substrate "$@"; return $? ;;
        bundle)   bl_bundle_build "$@"; return $? ;;
        *)
            bl_error_envelope observe "unknown sub-verb: $sub"
            return "$BL_EX_USAGE"
            ;;
    esac
}
