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
# _bl_obs_scrub — strip operator-local tokens from a JSONL record string
# ---------------------------------------------------------------------------
_bl_obs_scrub() {
    # Reads record-json on stdin; emits scrubbed compact record-json on stdout.
    jq -c 'walk(
        if type == "string"
        then gsub("/home/[a-z][a-z0-9]{2,15}/"; "/home/<cpuser>/")
             | gsub("\\.liquidweb\\.(com|local)"; ".example.test")
             | gsub("sigforge[0-9]*"; "fleet-00-host")
             | gsub("/home/sigforge/var/ioc/polyshell_out/"; "<OPERATOR_LOCAL>/")
        else .
        end
    )'
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

    line=$(jq -n -c \
        --arg ts "$ts" \
        --arg host "$host" \
        --arg case_id "$case_id" \
        --arg obs "$obs" \
        --arg source "$source" \
        --argjson record "$record" \
        '{ts:$ts,host:$host,case:(if $case_id=="" then null else $case_id end),obs:$obs,source:$source,record:$record}' \
        | _bl_obs_scrub) || return "$BL_EX_SCHEMA_VALIDATION_FAIL"

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
