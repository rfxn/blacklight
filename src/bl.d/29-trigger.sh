# shellcheck shell=bash
# ----------------------------------------------------------------------------
# 29-trigger.sh — bl trigger verb (currently lmd only; future modsec-audit, imunify).
# Depends on: 10-log, 20-api, 25-ledger, 50-consult (extended in P6).
# Designed primarily for hook-driven invocation (BL_INVOKED_BY=lmd-hook); also
# supports operator manual invocation from TTY.
# ----------------------------------------------------------------------------

bl_trigger() {
    local sub_verb="${1:-}"
    shift || true   # || true: shift on empty argv is non-fatal here; usage handled below
    case "$sub_verb" in
        lmd) bl_trigger_lmd "$@"; return $? ;;
        "") bl_error_envelope trigger "missing sub-verb (use 'bl trigger lmd --help')"; return "$BL_EX_USAGE" ;;
        *)  bl_error_envelope trigger "unknown sub-verb: $sub_verb"; return "$BL_EX_USAGE" ;;
    esac
}

bl_trigger_lmd() {
    local scanid="" session_file="${LMD_SESSION_FILE:-}" unattended_flag=""
    local source_conf="/usr/local/maldetect/conf.maldet"
    while (( $# > 0 )); do
        case "$1" in
            --scanid)        scanid="$2"; shift 2 ;;
            --session-file)  session_file="$2"; shift 2 ;;
            --source-conf)   source_conf="$2"; shift 2 ;;
            --unattended)    unattended_flag="1"; shift ;;
            -*)              bl_error_envelope trigger "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)               bl_error_envelope trigger "unexpected argument: $1"; return "$BL_EX_USAGE" ;;
        esac
    done
    [[ -z "$scanid" ]] && { bl_error_envelope trigger "missing --scanid"; return "$BL_EX_USAGE"; }

    [[ -n "$unattended_flag" ]] && export BL_UNATTENDED_FLAG=1

    # Emit lmd_hook_received early — even degraded paths get this event
    bl_ledger_append "global" \
        "$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg s "$scanid" \
            '{ts:$ts, case:"global", kind:"lmd_hook_received", payload:{scanid:$s, source:"lmd-hook"}}')" || \
        bl_warn "ledger append failed for lmd_hook_received"

    # Read TSV → JSONL on stdout; stub on empty/missing
    local hits_jsonl
    hits_jsonl=$(command mktemp) || { bl_error_envelope trigger "mktemp failed"; return "$BL_EX_PREFLIGHT_FAIL"; }
    local read_rc=0
    _bl_trigger_lmd_read_session "$session_file" > "$hits_jsonl" || read_rc=$?

    # Degraded path: TSV unreadable/empty + LMD_HITS>0 mismatch
    if (( read_rc != 0 )) || [[ ! -s "$hits_jsonl" ]]; then
        bl_warn "trigger lmd: session-file unreadable or empty (path=$session_file); opening stub case"
        bl_ledger_append "global" \
            "$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg s "$scanid" --arg p "$session_file" \
                '{ts:$ts, case:"global", kind:"lmd_hit_degraded", payload:{scanid:$s, reason:"session_file_unreadable", partial_evidence:$p}}')" || \
            bl_warn "ledger append failed for lmd_hit_degraded"
        # Open stub case anyway for operator visibility (degraded fingerprint = scanid only)
        local stub_fp
        stub_fp=$(printf '%s' "$scanid" | sha256sum | head -c 16)
        bl_consult_new --trigger "$session_file" --notes "lmd hook degraded: empty/unreadable TSV" \
            --dedup yes --fingerprint "$stub_fp" --dedup-window-hours 24
        local rc=$?
        command rm -f "$hits_jsonl"
        return $rc
    fi

    # Compute cluster fingerprint from JSONL
    local cluster_fp
    cluster_fp=$(_bl_trigger_lmd_fingerprint "$scanid" < "$hits_jsonl") || {
        bl_error_envelope trigger "fingerprint computation failed"
        command rm -f "$hits_jsonl"
        return "$BL_EX_PREFLIGHT_FAIL"
    }

    # Default dedup window: from blacklight.conf, fallback 24
    local window="${BL_LMD_TRIGGER_DEDUP_WINDOW_HOURS:-24}"

    # Open (or attach) case via P6-extended bl_consult_new
    local case_out rc
    case_out=$(bl_consult_new --trigger "$session_file" \
        --notes "lmd cluster: scanid=$scanid hits=$(wc -l < "$hits_jsonl") source_conf=$source_conf" \
        --dedup yes --fingerprint "$cluster_fp" --dedup-window-hours "$window")
    rc=$?

    command rm -f "$hits_jsonl"
    (( rc == 0 )) && printf '%s\n' "$case_out"
    return $rc
}

# _bl_trigger_lmd_read_session <path> — parse LMD TSV, emit JSONL on stdout.
# Returns: 0 on success (1+ records); 65 on path unreadable; 0 with empty
# output on empty TSV (caller decides degraded vs new).
# LMD TSV format (per LMD lmd_hook.sh:163-182): tab-separated columns including
# ts, sigid, signame, hex-sig, path, hashes, flags, vhost-user.
_bl_trigger_lmd_read_session() {
    local path="$1"
    [[ -r "$path" ]] || { bl_error_envelope trigger "session-file unreadable: $path"; return "$BL_EX_PREFLIGHT_FAIL"; }
    # If file is empty (LMD reported hits but TSV empty — race)
    [[ -s "$path" ]] || return 0
    awk -F'\t' '
        /^[[:space:]]*$/ { next }
        /^#/ { next }
        {
            ts = $1
            sig = ($2 != "" ? $2 : "unknown")
            p = ($3 != "" ? $3 : "unknown")
            hash = ($4 != "" ? $4 : "")
            flags = ($5 != "" ? $5 : "")
            gsub(/"/, "\\\"", sig)
            gsub(/"/, "\\\"", p)
            printf "{\"ts\":\"%s\",\"sig\":\"%s\",\"path\":\"%s\",\"hash\":\"%s\",\"flags\":\"%s\"}\n", ts, sig, p, hash, flags
        }' "$path"
    return 0
}

# _bl_trigger_lmd_fingerprint <scanid> — read JSONL on stdin, compute
# 16-hex sha256(scanid|sorted-sigs|sorted-paths)[:16].
_bl_trigger_lmd_fingerprint() {
    local scanid="$1"
    local input
    input=$(command cat)   # capture stdin
    local sigs paths
    sigs=$(printf '%s' "$input" | jq -r '.sig' | sort -u | paste -sd '|' -)
    paths=$(printf '%s' "$input" | jq -r '.path' | sort -u | paste -sd '|' -)
    printf '%s|%s|%s' "$scanid" "$sigs" "$paths" | sha256sum | head -c 16
}

bl_help_trigger() {
    command cat <<'TRIGGER_HELP_EOF'
bl trigger — open a case from a hook-fired event source.

Usage: bl trigger <source> [options]

Sources:
  lmd        Open a cluster-scoped case from an LMD scan session.
             Called by /etc/blacklight/hooks/bl-lmd-hook (LMD post_scan_hook
             adapter); also operator-invokable from TTY.

bl trigger lmd:
  --scanid <id>           (required)  LMD_SCANID — fingerprint input
  --session-file <path>   default $LMD_SESSION_FILE; LMD's per-session TSV
  --source-conf <path>    default /usr/local/maldetect/conf.maldet
  --unattended            mark this trigger as hook-driven (no TTY prompts)

Exit codes: 0 (case opened/attached), 64 (missing --scanid), 65 (unreadable
session-file), 71 (allocator collision after retries).
TRIGGER_HELP_EOF
}
