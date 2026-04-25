# shellcheck shell=bash
bl_run() {
    # bl_run <args> — route to _step (default), _batch (--batch), _list (--list)
    local mode="step" step_id="" max=16 yes="" dry_run="" unsafe="" explain=""
    while (( $# > 0 )); do
        case "$1" in
            --batch)    mode="batch"; shift ;;
            --list)     mode="list"; shift ;;
            --max)      max="$2"; shift 2 ;;
            --yes)      yes="yes"; shift ;;
            --dry-run)  dry_run="yes"; shift ;;
            --unsafe)   unsafe="yes"; shift ;;
            --explain)  explain="yes"; shift ;;
            -*)         bl_error_envelope run "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)          step_id="$1"; shift ;;
        esac
    done
    case "$mode" in
        step)   bl_run_step "$step_id" "$yes" "$dry_run" "$unsafe" "$explain"; return $? ;;
        batch)  bl_run_batch "$max"; return $? ;;
        list)   bl_run_list; return $? ;;
    esac
}
bl_run_step() {
    # bl_run_step <step-id> <yes> <dry-run> <unsafe> <explain> — full 13-step flow
    local step_id="$1"
    local yes="$2"
    local dry_run="$3"
    local unsafe="$4"
    local explain="$5"
    BL_MEMSTORE_CASE_ID="${BL_MEMSTORE_CASE_ID:-$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf 'memstore_bl_case')}"   # 2>/dev/null: state file absent on first invocation → fallback to canonical default literal
    [[ -z "$step_id" ]] && { bl_error_envelope run "missing <step-id>"; return "$BL_EX_USAGE"; }
    # Format guard at the CLI/batch entry — protects `/tmp/bl-step-$step_id.out`
    # write target and the memstore-key path against curator-poisoned or
    # operator-typed traversal segments. Schema pattern in step.json validates
    # the step JSON's .step_id field; this guards the orthogonal dispatch arg.
    if ! [[ "$step_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
        bl_error_envelope run "step-id format invalid (expected [A-Za-z0-9_-]{1,64}): $step_id"
        return "$BL_EX_USAGE"
    fi
    local case_id
    case_id=$(bl_case_current)
    if [[ -z "$case_id" ]]; then
        bl_error_envelope run "no active case" "(bl consult --attach <id>)"
        return "$BL_EX_NOT_FOUND"
    fi
    local pending_tmp memstore_key
    pending_tmp=$(mktemp)
    memstore_key="bl-case/$case_id/pending/$step_id.json"
    local resp rc
    rc=0
    resp=$(bl_api_call GET "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories/${memstore_key//\//%2F}") || rc=$?
    if (( rc == 65 )); then
        command rm -f "$pending_tmp"
        bl_error_envelope run "step $step_id not found in pending/"
        return "$BL_EX_NOT_FOUND"
    elif (( rc != 0 )); then
        command rm -f "$pending_tmp"
        return "$rc"
    fi
    printf '%s' "$resp" | jq -r '.content' > "$pending_tmp"
    local repo_root="${BL_REPO_ROOT:-$(dirname "$(readlink -f "$0")" 2>/dev/null || printf '.')}"   # 2>/dev/null: readlink may fail under bash -c with empty $0 → cwd fallback (then schema_path retried as relative below)
    local schema_path="$repo_root/schemas/step.json"
    [[ -r "$schema_path" ]] || schema_path="schemas/step.json"
    if ! bl_jq_schema_check "$schema_path" "$pending_tmp" --strict; then
        bl_ledger_append "$case_id" \
            "$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$case_id" --arg s "$step_id" \
                '{ts:$ts, case:$c, kind:"schema_reject", payload:{step_id:$s}}')"
        command rm -f "$pending_tmp"
        return "$BL_EX_SCHEMA_VALIDATION_FAIL"
    fi
    local tier verb
    verb=$(jq -r '.verb' "$pending_tmp")
    tier=$(bl_run_evaluate_tier "$pending_tmp") || {
        command rm -f "$pending_tmp"
        return "$BL_EX_SCHEMA_VALIDATION_FAIL"
    }
    if [[ "$tier" == "unknown" ]]; then
        if [[ "$unsafe" != "yes" || "$yes" != "yes" ]]; then
            bl_error_envelope run "tier-gate denied (tier=unknown)" "override requires both --unsafe and --yes"
            bl_ledger_append "$case_id" \
                "$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$case_id" --arg s "$step_id" \
                    '{ts:$ts, case:$c, kind:"unknown_tier_deny", payload:{step_id:$s}}')"
            command rm -f "$pending_tmp"
            return "$BL_EX_TIER_GATE_DENIED"
        fi
    fi
    local args_json diff
    args_json=$(jq -c '.args' "$pending_tmp")
    diff=$(jq -r '.diff // ""' "$pending_tmp")
    case "$tier" in
        read-only|auto)
            : ;;
        suggested|destructive)
            if ! bl_run_preflight_tier "$tier" "$verb" "$args_json"; then
                bl_ledger_append "$case_id" \
                    "$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$case_id" --arg s "$step_id" --arg t "$tier" \
                        '{ts:$ts, case:$c, kind:"preflight_fail", payload:{step_id:$s, tier:$t}}')"
                command rm -f "$pending_tmp"
                return "$BL_EX_TIER_GATE_DENIED"
            fi
            if [[ "$yes" != "yes" && "$dry_run" != "yes" ]]; then
                if ! bl_run_prompt_operator "$step_id" "$tier" "$diff"; then
                    bl_ledger_append "$case_id" \
                        "$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$case_id" --arg s "$step_id" \
                            '{ts:$ts, case:$c, kind:"operator_decline", payload:{step_id:$s}}')"
                    command rm -f "$pending_tmp"
                    return "$BL_EX_TIER_GATE_DENIED"
                fi
            fi
            ;;
    esac
    if [[ "$dry_run" == "yes" ]]; then
        printf '%s\n' "$diff"
        command rm -f "$pending_tmp"
        return "$BL_EX_OK"
    fi
    # mktemp-allocated stdout buffer — predictable `/tmp/bl-step-$step_id.out`
    # was symlink-vulnerable on multi-user hosts (workspace standard: never
    # use `$$`/predictable temp names). The step-id format guard already
    # rejects traversal, but mktemp closes the predictable-name vector.
    local stdout_file
    stdout_file=$(command mktemp "/tmp/bl-step-${step_id}.XXXXXX") || {
        bl_error_envelope run "mktemp failed for stdout buffer"
        command rm -f "$pending_tmp"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    local exec_rc=0
    bl_run_dispatch_verb "$verb" "$args_json" > "$stdout_file" || exec_rc=$?
    local writeback_ok=1
    bl_run_writeback_result "$step_id" "$exec_rc" "$stdout_file" "$case_id" || {
        writeback_ok=0
        bl_warn "writeback failed; local file at $stdout_file preserved"
    }
    bl_ledger_append "$case_id" \
        "$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$case_id" --arg s "$step_id" --arg t "$tier" --arg v "$verb" --argjson rc "$exec_rc" \
            '{ts:$ts, case:$c, kind:"step_run", payload:{step_id:$s, tier:$t, verb:$v, rc:$rc}}')"
    local session_id_file="$BL_STATE_DIR/session-$case_id"
    if [[ -r "$session_id_file" ]]; then
        local session_id
        session_id=$(command cat "$session_id_file")
        local body_file
        body_file=$(mktemp)
        jq -n --arg s "$step_id" --argjson rc "$exec_rc" \
            '{type:"user.message", content:[{type:"text", text:("result landed: "+$s+" rc="+($rc|tostring))}]}' > "$body_file"
        bl_api_call POST "/v1/sessions/$session_id/events" "$body_file" >/dev/null || true   # non-fatal; ledger has the event
        command rm -f "$body_file"
    fi
    command rm -f "$pending_tmp"
    # Preserve $stdout_file when writeback failed so the operator can recover it
    # — the bl_warn above promises "preserved", and unconditional rm broke that contract.
    (( writeback_ok )) && command rm -f "$stdout_file"
    return "$exec_rc"
}

bl_run_evaluate_tier() {
    # bl_run_evaluate_tier <pending-path> — prints tier on stdout; 0/67
    local pending_path="$1"
    local declared_tier verb expected_tier
    declared_tier=$(jq -r '.action_tier' "$pending_path")
    verb=$(jq -r '.verb' "$pending_path")
    case "$verb" in
        observe.*)              expected_tier="read-only" ;;
        defend.firewall)        expected_tier="auto" ;;
        defend.sig)             expected_tier="auto" ;;
        defend.modsec)          expected_tier="suggested" ;;
        defend.modsec_remove)   expected_tier="destructive" ;;
        clean.*)                expected_tier="destructive" ;;
        case.close|case.reopen) expected_tier="suggested" ;;
        *)                      expected_tier="unknown" ;;
    esac
    if [[ "$declared_tier" != "$expected_tier" && "$declared_tier" != "unknown" ]]; then
        bl_warn "curator tier=$declared_tier overridden to $expected_tier per verb-class (verb=$verb)"
    fi
    [[ "$declared_tier" == "unknown" ]] && expected_tier="unknown"
    printf '%s' "$expected_tier"
    return "$BL_EX_OK"
}

bl_run_prompt_operator() {
    # bl_run_prompt_operator <step-id> <tier> <diff> — 0 on approve, 68 on decline
    local step_id="$1"
    local tier="$2"
    local diff="$3"
    local ans
    printf 'bl-run: step %s tier=%s\n' "$step_id" "$tier" >&2
    [[ -n "$diff" ]] && printf '[diff]\n%s\n' "$diff" >&2
    while :; do
        printf 'Apply? [y/N/diff-full/explain/abort] ' >&2
        IFS= read -r ans || ans="${BL_PROMPT_DEFAULT:-N}"
        ans="${ans:-${BL_PROMPT_DEFAULT:-N}}"
        ans=$(printf '%s' "$ans" | command tr '[:upper:]' '[:lower:]')
        case "$ans" in
            y|yes)        return 0 ;;
            n|no|abort|'') return "$BL_EX_TIER_GATE_DENIED" ;;   # operator declined → caller checks rc
            diff-full)
                printf '%s\n' "$diff" >&2
                ;;
            explain)
                printf '(explain — re-prints reasoning from step envelope; M5 stub shows tier+diff only)\n' >&2
                ;;
            *)
                printf 'invalid; type y, N, diff-full, explain, or abort\n' >&2
                ;;
        esac
    done
}

bl_run_preflight_tier() {
    # bl_run_preflight_tier <tier> <verb> <args-json> — 0 on pass, 68 on fail
    local tier="$1"
    local verb="$2"
    local args_json="$3"
    case "$verb" in
        defend.modsec)
            if command -v apachectl >/dev/null 2>&1; then   # optional tool; fail-closed if missing
                apachectl -t >/dev/null 2>&1 || {   # fail-closed: config test failed
                    bl_error_envelope preflight "apachectl -t failed; rule rejected"
                    return "$BL_EX_TIER_GATE_DENIED"
                }
            else
                bl_warn "apachectl not found; skipping preflight (M6 will enforce via backend-lock)"
            fi
            ;;
        defend.sig)
            bl_debug "bl_run_preflight_tier: defend.sig FP-gate deferred to M6"
            ;;
        defend.firewall)
            bl_debug "bl_run_preflight_tier: defend.firewall ASN check deferred to M6"
            ;;
        *)
            : ;;
    esac
    return "$BL_EX_OK"
}

bl_run_dispatch_verb() {
    # bl_run_dispatch_verb <verb> <args-json> — dispatches to bl_<ns>_<action>
    local verb="$1"
    local args_json="$2"
    local func_name
    func_name="bl_$(printf '%s' "$verb" | tr '.' '_')"
    if ! declare -f "$func_name" >/dev/null 2>&1; then   # handler not landed yet (M4/M6/M7 pre-merge)
        bl_error_envelope run "$verb handler not yet landed" "(see M4 for observe.*, M6 for defend.*, M7 for clean.*)"
        return "$BL_EX_USAGE"
    fi
    "$func_name" "$args_json"
    return $?
}

bl_run_writeback_result() {
    # bl_run_writeback_result <step-id> <rc> <stdout-path> <case-id> — 0/67/69/70
    local step_id="$1"
    local rc="$2"
    local stdout_path="$3"
    local case_id="$4"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # M9 P6: fence-wrap stdout (adversary-reachable — full stdout of observe.*)
    local fenced_stdout
    if [[ -s "$stdout_path" ]]; then
        fenced_stdout=$(bl_fence_wrap "$case_id" evidence "$stdout_path") || {
            bl_error_envelope run "fence wrap failed for step $step_id"
            return "$BL_EX_CONFLICT"
        }
    else
        # Empty/missing stdout: wrap empty payload so result envelope schema stays uniform.
        local empty_file
        empty_file=$(mktemp)
        : > "$empty_file"
        fenced_stdout=$(bl_fence_wrap "$case_id" evidence "$empty_file") || {
            command rm -f "$empty_file"
            bl_error_envelope run "fence wrap failed for empty stdout (step $step_id)"
            return "$BL_EX_CONFLICT"
        }
        command rm -f "$empty_file"
    fi

    local pending_tmp
    pending_tmp=$(mktemp)
    bl_api_call GET "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories/bl-case%2F$case_id%2Fpending%2F$step_id.json" 2>/dev/null | jq -r '.content' > "$pending_tmp" || true   # transient miss

    local result_content
    result_content=$(jq -n --slurpfile pending "$pending_tmp" --argjson rc "$rc" --arg stdout "$fenced_stdout" --arg now "$now" \
        '$pending[0] + {result: {rc:$rc, stdout:$stdout, applied_at:$now}}')

    # M9 P6: validate composed result envelope against schemas/result.json before POST.
    local repo_root="${BL_REPO_ROOT:-$(dirname "$(readlink -f "$0")" 2>/dev/null || printf '.')}"   # 2>/dev/null: readlink may fail under bash -c with empty $0 → cwd fallback (then schema_path retried as relative below)
    local schema_file="$repo_root/schemas/result.json"
    [[ -r "$schema_file" ]] || schema_file="schemas/result.json"
    if [[ -r "$schema_file" ]]; then
        local result_tmp
        result_tmp=$(mktemp)
        printf '%s' "$result_content" > "$result_tmp"
        if ! bl_jq_schema_check "$schema_file" "$result_tmp"; then
            command rm -f "$result_tmp" "$pending_tmp"
            bl_ledger_append "$case_id" \
                "$(jq -n --arg ts "$now" --arg c "$case_id" --arg s "$step_id" \
                    '{ts:$ts, case:$c, kind:"result_schema_reject", payload:{step_id:$s}}')"
            return "$BL_EX_SCHEMA_VALIDATION_FAIL"
        fi
        command rm -f "$result_tmp"
    fi

    local body_file
    body_file=$(mktemp)
    jq -n --arg k "bl-case/$case_id/results/$step_id.json" --arg c "$result_content" \
        '{key:$k, content:$c, metadata:{}}' > "$body_file"
    bl_api_call POST "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories" "$body_file" >/dev/null
    local post_rc=$?
    command rm -f "$body_file"
    (( post_rc != 0 )) && { command rm -f "$pending_tmp"; return "$post_rc"; }
    bl_api_call DELETE "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories/bl-case%2F$case_id%2Fpending%2F$step_id.json" >/dev/null || bl_warn "pending delete failed; manual cleanup may be needed"
    command rm -f "$pending_tmp"
    return "$BL_EX_OK"
}

bl_run_batch() {
    # bl_run_batch <max> — 0/64/68/72
    local max="$1"
    BL_MEMSTORE_CASE_ID="${BL_MEMSTORE_CASE_ID:-$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf 'memstore_bl_case')}"   # 2>/dev/null: state file absent on first invocation → fallback to canonical default literal
    local case_id
    case_id=$(bl_case_current)
    [[ -z "$case_id" ]] && { bl_error_envelope run "no active case"; return "$BL_EX_NOT_FOUND"; }
    local list_body step_ids
    list_body=$(bl_api_call GET "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories?key_prefix=bl-case/$case_id/pending/") || return $?
    step_ids=$(printf '%s' "$list_body" | jq -r '.data[].key' | sed "s|bl-case/$case_id/pending/||; s|\.json$||" | sort)
    if [[ -z "$step_ids" ]]; then
        bl_info "no pending steps for $case_id"
        return "$BL_EX_OK"
    fi
    local count=0 rc=0
    while IFS= read -r sid; do
        [[ -z "$sid" ]] && continue
        (( count >= max )) && { bl_info "batch max=$max reached"; break; }
        bl_run_step "$sid" "" "" "" "" || rc=$?
        (( rc == 68 )) && { bl_info "batch halted on tier-gate decline at $sid"; return "$rc"; }
        count=$((count + 1))
    done <<< "$step_ids"
    return "$BL_EX_OK"
}

bl_run_list() {
    # bl_run_list — 0/64/69/72; enumerates pending without execution
    BL_MEMSTORE_CASE_ID="${BL_MEMSTORE_CASE_ID:-$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf 'memstore_bl_case')}"   # 2>/dev/null: state file absent on first invocation → fallback to canonical default literal
    local case_id
    case_id=$(bl_case_current)
    [[ -z "$case_id" ]] && { bl_error_envelope run "no active case"; return "$BL_EX_NOT_FOUND"; }
    local list_body
    list_body=$(bl_api_call GET "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories?key_prefix=bl-case/$case_id/pending/") || return $?
    local keys
    keys=$(printf '%s' "$list_body" | jq -r '.data[].key' | sort)
    if [[ -z "$keys" ]]; then
        bl_info "no pending steps"
        return "$BL_EX_OK"
    fi
    printf '%-8s  %-24s  %-11s  %s\n' "step_id" "verb" "tier" "reasoning"
    local key body sid verb tier reasoning
    while IFS= read -r key; do
        body=$(bl_api_call GET "/v1/memory_stores/${BL_MEMSTORE_CASE_ID}/memories/${key//\//%2F}" 2>/dev/null | jq -r '.content') || continue   # skip unreadable
        sid=$(printf '%s' "$body" | jq -r '.step_id')
        verb=$(printf '%s' "$body" | jq -r '.verb')
        tier=$(printf '%s' "$body" | jq -r '.action_tier')
        reasoning=$(printf '%s' "$body" | jq -r '.reasoning' | cut -c1-60)
        printf '%-8s  %-24s  %-11s  %s\n' "$sid" "$verb" "$tier" "$reasoning"
    done <<< "$keys"
    return "$BL_EX_OK"
}

# ----------------------------------------------------------------------------
# bl_case_* — case inspection + lifecycle close/reopen (M5)
# Spec: docs/specs/2026-04-24-M5-consult-run-case.md §5.3 + §5.3.1 flow
# ----------------------------------------------------------------------------

