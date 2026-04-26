# shellcheck shell=bash
# ============================================================================
# M4 observe handlers — spec: docs/specs/2026-04-24-M4-bl-observe.md
# ----------------------------------------------------------------------------
# Region layout (top-down reading order = call depth):
#   1. Private helpers (_bl_obs_*) — 11 functions
#   2. Verb handlers (bl_observe_*) — 11 functions
#   3. Bundle builder (bl_bundle_build) — 1 function
#   4. Top-level router (bl_observe) — replaces M1 stub
# ============================================================================

# ---------------------------------------------------------------------------
# _bl_obs_ts_iso8601 — ISO-8601 UTC with ms precision (BSD fallback: second)
# ---------------------------------------------------------------------------
_bl_obs_ts_iso8601() {
    # BSD date lacks %3N; fall back to second-precision when first form fails
    command date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || command date -u +%Y-%m-%dT%H:%M:%SZ   # %3N not available on BSD; second form is portable fallback
}

# ---------------------------------------------------------------------------
# _bl_obs_host_label — envelope host field
# ---------------------------------------------------------------------------
_bl_obs_host_label() {
    printf '%s' "${BL_HOST_LABEL:-$(command hostname -s 2>/dev/null || printf 'unknown')}"   # hostname unavailable in some minimal containers
}

# ---------------------------------------------------------------------------
# _bl_obs_allocate_obs_id — monotonic per-invocation obs-NNNN counter
# ---------------------------------------------------------------------------
_bl_obs_allocate_obs_id() {
    local counter_file="$BL_STATE_DIR/obs_counter"
    local n
    command mkdir -p "$BL_STATE_DIR"
    if [[ ! -r "$counter_file" ]]; then
        n=1
    else
        n=$(command cat "$counter_file")
        n=$((n + 1))
    fi
    printf '%d' "$n" > "$counter_file"
    printf 'obs-%04d' "$n"
}

# ---------------------------------------------------------------------------
# _bl_obs_allocate_cluster_id — bash-local counter; resets per handler call
# ---------------------------------------------------------------------------
_bl_obs_allocate_cluster_id() {
    # Caller owns _BL_OBS_CLUSTER_N (handler-local). Increment + format.
    _BL_OBS_CLUSTER_N=$(( ${_BL_OBS_CLUSTER_N:-0} + 1 ))
    printf 'c-%04d' "$_BL_OBS_CLUSTER_N"
}

# ---------------------------------------------------------------------------
# _bl_obs_size_guard — exit 65 if file exceeds max bytes
# ---------------------------------------------------------------------------
_bl_obs_size_guard() {
    local path="$1"
    local max_bytes="$2"
    local size
    size=$(command stat -c '%s' "$path" 2>/dev/null)   # BSD stat uses -f; GNU uses -c
    if [[ -z "$size" ]]; then
        size=$(command stat -f '%z' "$path" 2>/dev/null) || return "$BL_EX_PREFLIGHT_FAIL"   # BSD fallback
    fi
    if (( size > max_bytes )); then
        bl_error_envelope observe "file oversize ($((size / 1024 / 1024)) MB > $((max_bytes / 1024 / 1024)) MB cap): $path"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    return "$BL_EX_OK"
}

# ---------------------------------------------------------------------------
# _bl_obs_codec_detect — gz | zst per spec §5.14 + DESIGN.md §10.4
# ---------------------------------------------------------------------------
_bl_obs_codec_detect() {
    local requested="${1:-auto}"
    case "$requested" in
        gz)   printf 'gz' ;;
        zst)
            if command -v zstd >/dev/null 2>&1; then   # zstd presence gates zst selection
                printf 'zst'
            else
                bl_error_envelope observe "--format zst requested but zstd not available"
                return "$BL_EX_PREFLIGHT_FAIL"
            fi
            ;;
        auto|"")
            if command -v zstd >/dev/null 2>&1; then   # prefer zstd when available
                printf 'zst'
            else
                printf 'gz'
            fi
            ;;
        *)
            bl_error_envelope observe "unknown --format: $requested (use gz|zst)"
            return "$BL_EX_USAGE"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# _bl_obs_detect_firewall — apf | csf | nftables | iptables per spec §5.12
# ---------------------------------------------------------------------------
_bl_obs_detect_firewall() {
    if command -v apf >/dev/null 2>&1 && [[ -r /etc/apf/conf.apf ]]; then
        printf 'apf'; return "$BL_EX_OK"
    fi
    if command -v csf >/dev/null 2>&1 && [[ -r /etc/csf/csf.conf ]]; then
        printf 'csf'; return "$BL_EX_OK"
    fi
    if command -v nft >/dev/null 2>&1 && [[ -n "$(command nft list tables 2>/dev/null)" ]]; then   # empty ruleset → iptables fallback
        printf 'nftables'; return "$BL_EX_OK"
    fi
    if command -v iptables >/dev/null 2>&1; then
        printf 'iptables'; return "$BL_EX_OK"
    fi
    return "$BL_EX_NOT_FOUND"
}

# ---------------------------------------------------------------------------
# _bl_obs_open_stream — case-scoped evidence file path
# ---------------------------------------------------------------------------
_bl_obs_open_stream() {
    local kind="$1"
    local case_id
    case_id="$(bl_case_current)"
    [[ -z "$case_id" ]] && return "$BL_EX_OK"   # no case → stdout-only; caller sees empty stream path
    local ts
    ts="$(_bl_obs_ts_iso8601 | command tr ':' '-')"
    local dir="$BL_VAR_DIR/cases/$case_id/evidence"
    command mkdir -p "$dir"
    local base="$dir/obs-${ts}-${kind}.json"
    local n=2
    local path="$base"
    while [[ -e "$path" ]]; do
        path="${dir}/obs-${ts}-${kind}.${n}.json"
        n=$((n + 1))
    done
    printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# _bl_obs_emit_jsonl — assemble preamble + scrub + write stdout + stream
# ---------------------------------------------------------------------------
_bl_obs_emit_jsonl() {
    local source="$1"
    local record="$2"
    local stream_path="${3:-}"
    local ts host case_id obs line
    ts="$(_bl_obs_ts_iso8601)"
    host="$(_bl_obs_host_label)"
    case_id="$(bl_case_current)"
    obs="${_BL_OBS_ID:-$(_bl_obs_allocate_obs_id)}"
    _BL_OBS_ID="$obs"   # handler-local; sticky within one invocation

    # Single jq invocation: wrap envelope + scrub operator-local tokens in one
    # pass. Prior version forked two jq processes (envelope assembly piped
    # through `_bl_obs_scrub`) per record — observable on log-parse hot paths
    # where N is per-line (audit M6).
    line=$(jq -n -c \
        --arg ts "$ts" \
        --arg host "$host" \
        --arg case_id "$case_id" \
        --arg obs "$obs" \
        --arg source "$source" \
        --argjson record "$record" \
        '{ts:$ts,host:$host,case:(if $case_id=="" then null else $case_id end),obs:$obs,source:$source,record:$record}
         | walk(
             if type == "string"
             then gsub("/home/[a-z][a-z0-9]{2,15}/"; "/home/<cpuser>/")
                  | gsub("\\.liquidweb\\.(com|local)"; ".example.test")
                  | gsub("sigforge[0-9]*"; "fleet-00-host")
                  | gsub("/home/sigforge/var/ioc/polyshell_out/"; "<OPERATOR_LOCAL>/")
             else .
             end
         )') || return "$BL_EX_SCHEMA_VALIDATION_FAIL"

    printf '%s\n' "$line"
    if [[ -n "$stream_path" ]]; then
        printf '%s\n' "$line" >> "$stream_path"
    fi
    return "$BL_EX_OK"
}

# ---------------------------------------------------------------------------
# _bl_obs_close_stream — write observe.summary trailer + finish stream
# ---------------------------------------------------------------------------
_bl_obs_close_stream() {
    local stream_path="$1"
    local source="$2"
    local summary_json="$3"
    _bl_obs_emit_jsonl 'observe.summary' "$summary_json" "$stream_path" || return "$?"
    # stream_path may be empty when no case is active — safe no-op
    return "$BL_EX_OK"
}

# === M4-HANDLERS-BEGIN ===
# Phase 2A/2B/2C land bl_observe_* handlers here.
# Phase 3 lands bl_bundle_build below the verb handlers.
# Insertion ordering within this region: log-parse → fs-walk → system-state → bundle.

# ---------------------------------------------------------------------------
# bl_observe_log_apache — parse combined-format apache/nginx access log
# ---------------------------------------------------------------------------

bl_observe_evidence_threshold_check() {
    # bl_observe_evidence_threshold_check <case-id> <source> — 0 if upload-due, 1 if not.
    # Threshold per spec §5.5 table: 10 events / 100 events / 100 paths / per-call OR 1 MB grown.
    # Reads bytes-since-last-upload from $BL_VAR_DIR/cases/<case-id>/evidence/<source>.upload.json
    # (created/updated by bl_observe_evidence_rotate). First-call returns 0 (always upload).
    local case_id="$1" source="$2"
    [[ -z "$case_id" || -z "$source" ]] && return 1
    local evidence_path="$BL_VAR_DIR/cases/$case_id/evidence/$source"
    local upload_meta_file="$evidence_path.upload.json"
    # Find evidence file by extension (.json for JSONL collectors, .txt for raw cron, etc.)
    local actual=""
    local ext
    for ext in json txt log; do
        if [[ -r "$evidence_path.$ext" ]]; then actual="$evidence_path.$ext"; break; fi
    done
    [[ -z "$actual" ]] && return 1   # no evidence written yet — nothing to upload
    [[ ! -r "$upload_meta_file" ]] && return 0   # never uploaded — first call always rotates
    local last_bytes last_count
    last_bytes=$(jq -r '.bytes_at_upload // 0' "$upload_meta_file" 2>/dev/null || printf '0')   # 2>/dev/null + fallback: malformed meta → treat as zero (force re-upload)
    last_count=$(jq -r '.count_at_upload // 0' "$upload_meta_file" 2>/dev/null || printf '0')
    local cur_bytes cur_count
    cur_bytes=$(command stat -c '%s' "$actual" 2>/dev/null || command stat -f '%z' "$actual" 2>/dev/null || printf '0')
    cur_count=$(command wc -l < "$actual" 2>/dev/null || printf '0')   # JSONL line count proxy for record count
    local bytes_delta=$(( cur_bytes - last_bytes ))
    local count_delta=$(( cur_count - last_count ))
    # Per-source threshold map (matches spec §5.5 table)
    local count_threshold
    case "$source" in
        apache|modsec)        count_threshold=10  ;;
        journal|fs)           count_threshold=100 ;;
        file|cron|proc|htaccess|firewall|sigs|substrate) count_threshold=1 ;;   # per-call sources
        *)                    count_threshold=10  ;;
    esac
    if (( count_delta >= count_threshold )) || (( bytes_delta >= 1048576 )); then
        return 0   # upload due
    fi
    return 1   # not yet
}

bl_observe_evidence_rotate() {
    # bl_observe_evidence_rotate <case-id> <source> — 0/65/69.
    # Full lifecycle: read prior case_files entry → upload-new → attach-new at same mount path
    # (if a live session for this case exists) → detach-old → write new state.json case_files entry.
    # Order preserves curator-visible path availability throughout the swap (spec R6). If no live
    # session exists yet (case opened before sessions.create), the upload + state.json write
    # still happen; bl_setup_attach_session_resources picks up the file at session-create time.
    local case_id="$1" source="$2"
    [[ -z "$case_id" || -z "$source" ]] && {
        bl_error_envelope observe "bl_observe_evidence_rotate: case-id + source required"
        return "$BL_EX_USAGE"
    }
    local evidence_path="$BL_VAR_DIR/cases/$case_id/evidence/$source"
    local actual="" ext
    for ext in json txt log; do
        if [[ -r "$evidence_path.$ext" ]]; then actual="$evidence_path.$ext"; break; fi
    done
    [[ -z "$actual" ]] && {
        bl_error_envelope observe "no evidence file at $evidence_path.{json,txt,log}"
        return "$BL_EX_NOT_FOUND"
    }
    local mime
    case "$ext" in
        json) mime="application/json" ;;
        log)  mime="text/plain"       ;;
        *)    mime="text/plain"       ;;
    esac
    local mount_path="/case/$case_id/raw/$source.$ext"
    local state_file="$BL_STATE_DIR/state.json"
    # Read prior workspace_file_id + session_resource_id (may be empty for first rotate)
    local old_file_id="" old_sesrsc_id="" session_id=""
    if [[ -f "$state_file" ]]; then
        old_file_id=$(jq -r --arg c "$case_id" --arg p "$mount_path" '.case_files[$c][$p].workspace_file_id // empty' "$state_file")
        old_sesrsc_id=$(jq -r --arg c "$case_id" --arg p "$mount_path" '.case_files[$c][$p].session_resource_id // empty' "$state_file")
        session_id=$(jq -r --arg c "$case_id" '.session_ids[$c] // empty' "$state_file")
    fi
    # Step 1: upload-new
    local new_file_id
    new_file_id=$(bl_files_create "$mime" "$actual") || return $?
    bl_debug "bl_observe_evidence_rotate: uploaded $actual → $new_file_id"
    # Step 2 (if live session): attach-new at same mount path → emit new sesrsc_id
    local new_sesrsc_id=""
    if [[ -n "$session_id" ]]; then
        new_sesrsc_id=$(bl_files_attach_to_session "$session_id" "$new_file_id" "$mount_path") || {
            bl_warn "bl_observe_evidence_rotate: attach-new failed; file_id $new_file_id will be GC'd"
            new_sesrsc_id=""
        }
        # Step 3: detach-old (only after new is attached) — preserves path availability
        if [[ -n "$new_sesrsc_id" && -n "$old_sesrsc_id" ]]; then
            bl_files_detach_from_session "$session_id" "$old_sesrsc_id" >/dev/null || bl_warn "detach-old failed for $old_sesrsc_id"
        fi
    fi
    # Step 4: write state.json case_files entry (queue old file_id for GC if changed)
    local cur_bytes cur_count now_ts content_sha
    cur_bytes=$(command stat -c '%s' "$actual" 2>/dev/null || command stat -f '%z' "$actual" 2>/dev/null || printf '0')   # GNU then BSD; both fail → 0 (defensive)
    cur_count=$(command wc -l < "$actual" 2>/dev/null || printf '0')
    now_ts=$(command date -u +%Y-%m-%dT%H:%M:%SZ)
    content_sha=$(command sha256sum "$actual" | command awk '{print $1}')
    if [[ -f "$state_file" ]]; then
        local tmp_state="$state_file.tmp.$$"
        jq \
            --arg c "$case_id" \
            --arg p "$mount_path" \
            --arg fid "$new_file_id" \
            --arg sid "$new_sesrsc_id" \
            --arg sha "$content_sha" \
            --argjson b "$cur_bytes" \
            --argjson n "$cur_count" \
            --arg old "$old_file_id" \
            --arg ts "$now_ts" \
            '
            .case_files //= {} |
            .case_files[$c] //= {} |
            .case_files[$c][$p] = {
                workspace_file_id: $fid,
                session_resource_id: $sid,
                content_sha256: $sha,
                obs_count_since_upload: 0,
                bytes_since_upload: 0,
                uploaded_at: $ts
            } |
            if $old != "" and $old != $fid then
                .files_pending_deletion += [{file_id: $old, marked_at: $ts, reason: ("rotated by " + $fid), previous_mount_path: $p}]
            else . end
            ' "$state_file" > "$tmp_state"
        command mv "$tmp_state" "$state_file"
    fi
    # Step 5: persist threshold-check metadata (bytes-at-upload + count-at-upload)
    local upload_meta_file="$evidence_path.upload.json"
    local tmp_meta="$upload_meta_file.tmp.$$"
    jq -n \
        --arg fid "$new_file_id" \
        --arg mp "$mount_path" \
        --argjson b "$cur_bytes" \
        --argjson c "$cur_count" \
        '{file_id:$fid, mount_path:$mp, bytes_at_upload:$b, count_at_upload:$c}' > "$tmp_meta"
    command mv "$tmp_meta" "$upload_meta_file"
    printf '%s\n' "$new_file_id"
    return "$BL_EX_OK"
}
