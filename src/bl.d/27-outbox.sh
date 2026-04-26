# shellcheck shell=bash
# ----------------------------------------------------------------------------
# Outbox — DESIGN.md §13.5 rate-limit queue + §13.4 action-mirror fallback.
# Filename convention: YYYYMMDDTHHMMSSZ-NNNN-<kind>-<case>.json
# Kinds: wake, signal_upload, action_mirror.
# Cycle-break invariant (spec §4.5 rule 1): enqueue MUST NOT call the validated
# ledger-append helper — backpressure_reject uses direct printf to the JSONL file.
# Drain MAY call the ledger-append helper (exactly one outbox_drain event).
# ----------------------------------------------------------------------------

readonly BL_OUTBOX_WATERMARK_HIGH=1000
readonly BL_OUTBOX_WATERMARK_WARN=500
readonly BL_OUTBOX_DRAIN_DEFAULT_MAX=16
readonly BL_OUTBOX_DRAIN_DEFAULT_DEADLINE_SECS=5
readonly BL_OUTBOX_AGE_WARN_SECS=3600
readonly BL_OUTBOX_RETRY_MAX=3

bl_outbox_depth() {
    # bl_outbox_depth — prints integer queue depth on stdout
    local outbox_dir="$BL_VAR_DIR/outbox"
    if [[ ! -d "$outbox_dir" ]]; then
        printf '0'
        return "$BL_EX_OK"
    fi
    local n
    n=$(command find "$outbox_dir" -maxdepth 1 -name '*.json' 2>/dev/null | command wc -l)   # 2>/dev/null: EACCES on outbox dir → depth 0 fallback
    printf '%d' "$n"
    return "$BL_EX_OK"
}

bl_outbox_oldest_age_secs() {
    # bl_outbox_oldest_age_secs — prints age in seconds of oldest entry, 0 if empty
    local outbox_dir="$BL_VAR_DIR/outbox"
    if [[ ! -d "$outbox_dir" ]]; then
        printf '0'
        return "$BL_EX_OK"
    fi
    local oldest
    oldest=$(command find "$outbox_dir" -maxdepth 1 -name '*.json' -printf '%T@\n' 2>/dev/null | command sort -n | command head -n1)   # 2>/dev/null: BSD find lacks -printf → empty oldest, age=0
    if [[ -z "$oldest" ]]; then
        printf '0'
        return "$BL_EX_OK"
    fi
    local now
    now=$(date +%s)
    printf '%d' "$((now - ${oldest%.*}))"
    return "$BL_EX_OK"
}

bl_outbox_should_drain() {
    # bl_outbox_should_drain — returns 0 iff drain is warranted (non-empty AND aged)
    # Idempotency guard: only fires when oldest entry is at least
    # BL_OUTBOX_AGE_WARN_SECS old (default 3600s = 1h). Recently-enqueued events
    # sit until either the operator runs `bl outbox drain --force` or the age
    # threshold trips on the next preflight.
    local depth age
    depth=$(bl_outbox_depth)
    (( depth == 0 )) && return 1
    age=$(bl_outbox_oldest_age_secs)
    (( age >= BL_OUTBOX_AGE_WARN_SECS )) && return 0
    return 1
}

bl_outbox_enqueue() {
    # bl_outbox_enqueue <kind> <payload-json> — 0/64/65/67/70/71
    local kind="$1" payload="$2"
    local outbox_dir="$BL_VAR_DIR/outbox"
    local counter_file="$outbox_dir/.counter"
    local schema_file
    schema_file="${BL_REPO_ROOT:-$(command dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "$0")" 2>/dev/null || printf '.')}/schemas/outbox-$kind.json"   # 2>/dev/null × 2: readlink fails when BASH_SOURCE empty under bash -c; falls through to literal "schemas/" path on next line
    [[ -r "$schema_file" ]] || schema_file="schemas/outbox-$kind.json"

    if ! command mkdir -p "$outbox_dir" 2>/dev/null; then   # RO fs / perms
        bl_error_envelope outbox "$outbox_dir not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    if ! command touch "$counter_file" 2>/dev/null; then   # RO fs / perms
        bl_error_envelope outbox "$counter_file not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    local depth
    depth=$(bl_outbox_depth)
    if (( depth >= BL_OUTBOX_WATERMARK_HIGH )); then
        # Direct-printf to ledger (no validated-append call) — spec §4.5 rule 1
        # blocks ledger recursion through P4 mirror_remote → outbox fallback.
        local reject_line case_id ledger_dir ledger_file
        case_id=$(bl_case_current)
        [[ -z "$case_id" ]] && case_id="global"
        ledger_dir="$BL_VAR_DIR/ledger"
        ledger_file="$ledger_dir/$case_id.jsonl"
        command mkdir -p "$ledger_dir" 2>/dev/null || true   # ledger dir may already exist or be RO; reject record best-effort
        reject_line=$(jq -n -c \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg c "$case_id" \
            --argjson d "$depth" \
            --arg k "$kind" \
            '{ts:$ts, case:$c, kind:"backpressure_reject", payload:{queue_depth:$d, outbox_kind:$k}}')
        printf '%s\n' "$reject_line" >> "$ledger_file" 2>/dev/null || true   # RO ledger should not mask the BL_EX_RATE_LIMITED return
        bl_error_envelope outbox "backpressure (depth=$depth >= $BL_OUTBOX_WATERMARK_HIGH)"
        return "$BL_EX_RATE_LIMITED"
    fi
    (( depth >= BL_OUTBOX_WATERMARK_WARN )) && bl_warn "outbox depth=$depth (warn threshold=$BL_OUTBOX_WATERMARK_WARN)"

    # Validate payload is well-formed JSON before structural / schema checks.
    if ! printf '%s' "$payload" | jq empty 2>/dev/null; then   # 2>/dev/null: jq parse-error stderr is noise here — explicit error envelope below
        bl_error_envelope outbox "payload is not valid JSON"
        return "$BL_EX_SCHEMA_VALIDATION_FAIL"
    fi

    if [[ -r "$schema_file" ]]; then
        local payload_tmp
        payload_tmp=$(mktemp)
        printf '%s' "$payload" > "$payload_tmp"
        if ! bl_jq_schema_check "$schema_file" "$payload_tmp"; then
            command rm -f "$payload_tmp"
            bl_error_envelope outbox "payload failed $schema_file"
            return "$BL_EX_SCHEMA_VALIDATION_FAIL"
        fi
        command rm -f "$payload_tmp"
        # Pattern enforcement — bl_jq_schema_check covers required/enum/additionalProperties
        # but not "pattern". Per-kind pattern guards that callers depend on:
        case "$kind" in
            action_mirror)
                local tk
                tk=$(printf '%s' "$payload" | jq -r '.target_key // ""')
                if [[ ! "$tk" =~ ^bl-case/CASE-[0-9]{4}-[0-9]{4}/actions/applied/ ]]; then
                    bl_error_envelope outbox "action_mirror.target_key fails pattern (got: $tk)"
                    return "$BL_EX_SCHEMA_VALIDATION_FAIL"
                fi
                ;;
            signal_upload)
                local sc
                sc=$(printf '%s' "$payload" | jq -r '.case // ""')
                if [[ ! "$sc" =~ ^CASE-[0-9]{4}-[0-9]{4}$ ]]; then
                    bl_error_envelope outbox "signal_upload.case fails pattern (got: $sc)"
                    return "$BL_EX_SCHEMA_VALIDATION_FAIL"
                fi
                ;;
            wake)
                # Wake-payload `case` field newly required (audit m5). Filename
                # routing in bl_outbox_enqueue partitions outbox files by
                # case-id; missing field collapsed every wake to
                # `*-wake-global.json` and broke per-case audit grep-ability.
                local wc
                wc=$(printf '%s' "$payload" | jq -r '.case // ""')
                if [[ ! "$wc" =~ ^CASE-[0-9]{4}-[0-9]{4}$ ]]; then
                    bl_error_envelope outbox "wake.case fails pattern (got: $wc)"
                    return "$BL_EX_SCHEMA_VALIDATION_FAIL"
                fi
                ;;
        esac
    fi

    # FD 202 (registry: 00-header.sh) — flock counter for per-second monotonic NNNN.
    exec 202<>"$counter_file"
    if ! flock -x -w 5 202; then
        exec 202<&-
        bl_error_envelope outbox "flock timeout on $counter_file"
        return "$BL_EX_CONFLICT"
    fi
    local raw cur_ts cur_n new_n ts_now
    ts_now=$(date -u +%Y%m%dT%H%M%SZ)
    raw=$(command cat "$counter_file" 2>/dev/null || printf '')   # empty counter on first invocation
    cur_ts=$(printf '%s' "$raw" | jq -r '.ts // empty' 2>/dev/null || printf '')   # 2>/dev/null: counter file may be empty/non-JSON on first invocation → empty cur_ts → reset path
    cur_n=$(printf '%s' "$raw" | jq -r '.n // empty' 2>/dev/null || printf '')   # 2>/dev/null: same as cur_ts above — empty raw produces empty cur_n → first-of-second branch
    if [[ -z "$cur_ts" || "$cur_ts" != "$ts_now" ]]; then
        new_n=1
    else
        new_n=$((cur_n + 1))
    fi
    printf '{"ts":"%s","n":%d}' "$ts_now" "$new_n" > "$counter_file.tmp.$$"
    command mv "$counter_file.tmp.$$" "$counter_file"
    exec 202<&-

    # Resolve case-id from payload — best-effort; falls back to "global".
    local case_id
    case_id=$(printf '%s' "$payload" | jq -r '.case // .target_key // empty' 2>/dev/null | command sed -n 's|.*\(CASE-[0-9]\{4\}-[0-9]\{4\}\).*|\1|p' | command head -n1)   # 2>/dev/null: malformed payload → jq stderr noise; case_id falls through to "global"
    [[ -z "$case_id" ]] && case_id="global"

    local outbox_file
    outbox_file=$(printf '%s/%s-%04d-%s-%s.json' "$outbox_dir" "$ts_now" "$new_n" "$kind" "$case_id")
    printf '%s' "$payload" > "$outbox_file.tmp.$$"
    command mv "$outbox_file.tmp.$$" "$outbox_file"
    return "$BL_EX_OK"
}

bl_outbox_drain() {
    # bl_outbox_drain [--max N] [--deadline SECS] [--kind K] — 0/64/70
    local max="$BL_OUTBOX_DRAIN_DEFAULT_MAX"
    local deadline="$BL_OUTBOX_DRAIN_DEFAULT_DEADLINE_SECS"
    local kind_filter=""
    while (( $# > 0 )); do
        case "$1" in
            --max)      max="$2"; shift 2 ;;
            --deadline) deadline="$2"; shift 2 ;;
            --kind)     kind_filter="$2"; shift 2 ;;
            *)          bl_error_envelope outbox "unknown flag: $1"; return "$BL_EX_USAGE" ;;
        esac
    done

    local outbox_dir="$BL_VAR_DIR/outbox"
    [[ -d "$outbox_dir" ]] || return "$BL_EX_OK"

    # Snapshot file list at start — §11b edge: new enqueues during drain are
    # not replayed mid-run; they wait for the next drain.
    local files
    if [[ -n "$kind_filter" ]]; then
        files=$(command find "$outbox_dir" -maxdepth 1 -name "*-$kind_filter-*.json" 2>/dev/null | command sort)   # 2>/dev/null: EACCES on entries → drain skips them
    else
        files=$(command find "$outbox_dir" -maxdepth 1 -name '*.json' 2>/dev/null | command sort)   # 2>/dev/null: EACCES on entries → drain skips them
    fi

    local drained=0 failed=0 remaining=0 halt_reason="" start_secs="$SECONDS"
    local f basename_part kind payload rc retry_n new_f sid sid_file body_tmp mime path
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if (( drained + failed >= max )); then
            remaining=$((remaining + 1))
            continue
        fi
        # $SECONDS — bash 4.1+ builtin per CLAUDE.md (never $EPOCHREALTIME/$EPOCHSECONDS).
        if (( deadline > 0 )) && (( SECONDS - start_secs >= deadline )); then
            remaining=$((remaining + 1))
            halt_reason="deadline"
            continue
        fi
        basename_part=$(command basename "$f")
        kind=$(printf '%s' "$basename_part" | command sed -n 's/^[0-9TZ-]*-[0-9]*-\([a-z_]*\)-.*\.json$/\1/p')
        payload=$(command cat "$f" 2>/dev/null || printf '{}')   # 2>/dev/null: file may have been removed by concurrent drain or EACCES — empty payload routes to default kind branch

        rc=0
        case "$kind" in
            wake)
                sid_file="$BL_STATE_DIR/session-$(printf '%s' "$payload" | jq -r '.case // empty' 2>/dev/null || printf '')"   # 2>/dev/null: malformed wake payload → empty .case → sid_file path becomes session- (unreadable) → rc=69 defer
                sid=""
                [[ -r "$sid_file" ]] && sid=$(command cat "$sid_file")
                if [[ -n "$sid" ]]; then
                    body_tmp=$(mktemp)
                    printf '%s' "$payload" > "$body_tmp"
                    bl_api_call POST "/v1/sessions/$sid/events" "$body_tmp" >/dev/null || rc=$?
                    command rm -f "$body_tmp"
                else
                    rc=69   # no session yet; defer to a later drain
                fi
                ;;
            signal_upload)
                mime=$(printf '%s' "$payload" | jq -r '.mime')
                path=$(printf '%s' "$payload" | jq -r '.path')
                bl_files_create "$mime" "$path" >/dev/null || rc=$?
                ;;
            action_mirror)
                body_tmp=$(mktemp)
                local mirror_key
                mirror_key=$(printf '%s' "$payload" | jq -r '.target_key // empty')
                printf '%s' "$payload" | jq -c '.record' > "$body_tmp"
                if [[ -n "$mirror_key" ]]; then
                    bl_mem_post "${BL_MEMSTORE_CASE_ID:-memstore_bl_case}" "$mirror_key" "$body_tmp" >/dev/null || rc=$?
                fi
                command rm -f "$body_tmp"
                ;;
            *)
                command mkdir -p "$outbox_dir/failed"
                command mv "$f" "$outbox_dir/failed/"
                failed=$((failed + 1))
                continue
                ;;
        esac

        if (( rc == 0 )); then
            command rm -f "$f"
            drained=$((drained + 1))
        elif (( rc == 70 )); then
            halt_reason="rate_limit"
            remaining=$((remaining + 1))
            break
        else
            retry_n=$(printf '%s' "$basename_part" | command sed -n 's/.*-r\([0-9]*\)\.json$/\1/p')
            [[ -z "$retry_n" ]] && retry_n=0
            if (( retry_n >= BL_OUTBOX_RETRY_MAX )); then
                command mkdir -p "$outbox_dir/failed"
                command mv "$f" "$outbox_dir/failed/"
                bl_error "outbox: $basename_part exhausted retries (rc=$rc); moved to failed/"
                failed=$((failed + 1))
            else
                new_f=$(printf '%s' "$f" | command sed "s/\(\.json\)$/-r$((retry_n + 1))\1/")
                command mv "$f" "$new_f"
                failed=$((failed + 1))
            fi
        fi
    done <<< "$files"

    # Drain event — spec §4.5 documents drain MAY call ledger-append exactly once.
    local drain_case_id drain_record
    drain_case_id=$(bl_case_current)
    [[ -z "$drain_case_id" ]] && drain_case_id="global"
    drain_record=$(jq -n -c \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg c "$drain_case_id" \
        --argjson d "$drained" \
        --argjson f "$failed" \
        --argjson r "$remaining" \
        --arg h "$halt_reason" \
        '{ts:$ts, case:$c, kind:"outbox_drain", payload:{drained:$d, failed:$f, remaining:$r, halt_reason:$h}}')
    bl_ledger_append "$drain_case_id" "$drain_record" || true   # drain reporting must not fail the drain itself

    [[ "$halt_reason" == "rate_limit" ]] && return "$BL_EX_RATE_LIMITED"
    return "$BL_EX_OK"
}
