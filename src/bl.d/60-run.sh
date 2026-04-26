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
    # test-isolation env hatch — see tests/14-unattended.bats; never set in production
    # shellcheck disable=SC1090
    [[ -n "${BL_RUN_PRELOAD:-}" ]] && [[ -r "$BL_RUN_PRELOAD" ]] && source "$BL_RUN_PRELOAD"
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
    resp=$(bl_mem_get "${BL_MEMSTORE_CASE_ID}" "$memstore_key") || rc=$?
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
    local args_json diff reasoning
    args_json=$(jq -c '.args' "$pending_tmp")
    diff=$(jq -r '.diff // ""' "$pending_tmp")
    reasoning=$(jq -r '.reasoning // ""' "$pending_tmp")
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
            # M14 G5: unattended-mode tier policy
            if bl_is_unattended; then
                if [[ "$tier" == "destructive" ]]; then
                    # Destructive: ALWAYS queue + notify under unattended (even with --yes)
                    bl_run_queue_unattended "$pending_tmp" "$step_id" "$case_id" "$verb" "$tier"
                    bl_notify "$case_id" warn \
                        "Cleanup operation queued: $verb" \
                        "step_id=$step_id verb=$verb tier=destructive — operator approval required (bl run --batch $step_id --yes)" || true   # || true: notify-fail must not mask the load-bearing queue + decline path
                    command rm -f "$pending_tmp"
                    return "$BL_EX_TIER_GATE_DENIED"
                fi
                # Suggested under unattended: only defend.modsec auto-applies (preflight gate already passed).
                # All other suggested verbs (case.close, case.reopen, etc.) queue for operator review.
                if [[ "$tier" == "suggested" && "$verb" != "defend.modsec" ]]; then
                    bl_run_queue_unattended "$pending_tmp" "$step_id" "$case_id" "$verb" "$tier"
                    bl_notify "$case_id" warn \
                        "Suggested-tier operation queued: $verb" \
                        "step_id=$step_id verb=$verb — operator approval required" || true   # || true: notify-fail non-blocking
                    command rm -f "$pending_tmp"
                    return "$BL_EX_TIER_GATE_DENIED"
                fi
                # else: suggested defend.modsec under unattended → fall through to apply (no prompt)
                bl_debug "unattended: $verb tier=$tier auto-applying (preflight gate passed)"
            elif [[ "$yes" != "yes" && "$dry_run" != "yes" ]]; then
                # Existing interactive prompt path
                if ! bl_run_prompt_operator "$step_id" "$tier" "$diff" "$reasoning"; then
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
        local body_file custom_tool_use_id summary_text
        body_file=$(mktemp)
        # M16 P4: when the bridge enriched the pending step with custom_tool_use_id,
        # the curator's session is awaiting user.custom_tool_result against that
        # tool-use id. Sending user.message here would be rejected with HTTP 400
        # ('only user.tool_confirmation, user.custom_tool_result, or user.interrupt
        # may be sent'). When the field is absent — legacy step paths, mocked-step
        # BATS tests pre-dating the bridge, manually-staged pending entries — fall
        # back to user.message which is what the session expects pre-handshake.
        custom_tool_use_id=$(jq -r '.custom_tool_use_id // empty' "$pending_tmp")
        summary_text="result landed: $step_id rc=$exec_rc"
        if [[ -n "$custom_tool_use_id" ]]; then
            jq -n --arg id "$custom_tool_use_id" --arg t "$summary_text" \
                '{events:[{type:"user.custom_tool_result", custom_tool_use_id:$id, content:[{type:"text", text:$t}]}]}' > "$body_file"
        else
            jq -n --arg t "$summary_text" \
                '{events:[{type:"user.message", content:[{type:"text", text:$t}]}]}' > "$body_file"
        fi
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
    # bl_run_prompt_operator <step-id> <tier> <diff> <reasoning> — 0 on approve, 68 on decline
    local step_id="$1"
    local tier="$2"
    local diff="$3"
    local reasoning="$4"
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
                if [[ -n "$reasoning" ]]; then
                    printf '[reasoning]\n%s\n' "$reasoning" >&2
                else
                    printf '(no reasoning recorded for this step)\n' >&2
                fi
                ;;
            *)
                printf 'invalid; type y, N, diff-full, explain, or abort\n' >&2
                ;;
        esac
    done
}

# bl_run_queue_unattended <pending-path> <step-id> <case-id> <verb> <tier>
# — move the pending step body to queued/ subpath in the case memstore for
# later operator-confirmed batch execution; emit operator_decline ledger event
# with policy:"unattended" tag to disambiguate from interactive prompt declines.
bl_run_queue_unattended() {
    local pending_path="$1" step_id="$2" case_id="$3" verb="$4" tier="$5"
    local memstore_id
    memstore_id="${BL_MEMSTORE_CASE_ID:-$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf 'memstore_bl_case')}"   # 2>/dev/null: state file absent on first invocation; use canonical default

    # Move pending step → queued path in memstore.
    # Operator can still run: bl run --batch <step-id> --yes after approval.
    local body
    body=$(jq -c '.' "$pending_path") || {
        bl_warn "queue-unattended: failed to read pending body for $step_id"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    local body_file
    body_file=$(command mktemp)
    printf '%s' "$body" > "$body_file"
    bl_mem_patch "$memstore_id" "bl-case/$case_id/actions/queued/$step_id.json" "$body_file" || \
        bl_warn "queue-unattended: failed to write queued/$step_id.json for $case_id"
    command rm -f "$body_file"
    bl_mem_delete_by_key "$memstore_id" "bl-case/$case_id/actions/pending/$step_id.json" 2>/dev/null || true   # 2>/dev/null + || true: pending entry may be transient; cleanup best-effort

    bl_ledger_append "$case_id" \
        "$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$case_id" --arg s "$step_id" --arg v "$verb" --arg t "$tier" \
            '{ts:$ts, case:$c, kind:"operator_decline", payload:{step_id:$s, verb:$v, tier:$t, policy:"unattended"}}')" || \
        bl_warn "ledger append failed for unattended queue of $step_id"
    bl_info "queued $step_id ($verb tier=$tier) for operator review"
    return "$BL_EX_OK"
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
    # bl_run_dispatch_verb <verb> <args-json> — dispatches to bl_<ns>_<action>.
    # M16 P5: prefer <handler>_from_args adapter when present. The adapter
    # translates curator-authored {key,value}[] args to the collector's
    # native flag form (--key value), splits comma-separated multi-values,
    # converts relative timespecs ("72h") to ISO timestamps, and drops
    # unknown keys with a warning. Without the adapter, the legacy
    # passthrough hands the args_json blob to a collector that parses $1
    # as a single flag — guaranteed BL_EX_USAGE on every curator-prescribed
    # step.
    local verb="$1"
    local args_json="$2"
    local func_name adapter
    func_name="bl_$(printf '%s' "$verb" | tr '.' '_')"
    adapter="${func_name}_from_args"
    if declare -f "$adapter" >/dev/null 2>&1; then
        "$adapter" "$args_json"
        return $?
    fi
    if ! declare -f "$func_name" >/dev/null 2>&1; then   # handler not landed yet (M4/M6/M7 pre-merge)
        bl_error_envelope run "$verb handler not yet landed" "(see M4 for observe.*, M6 for defend.*, M7 for clean.*)"
        return "$BL_EX_USAGE"
    fi
    "$func_name" "$args_json"
    return $?
}

# ----------------------------------------------------------------------------
# Args-translation helpers — used by every observe.<verb>_from_args adapter.
# M16 P5.
# ----------------------------------------------------------------------------

bl_run_args_get() {
    # bl_run_args_get <args-json> <key> — prints value to stdout (empty on miss).
    local args_json="$1" key="$2"
    printf '%s' "$args_json" | jq -r --arg k "$key" '.[] | select(.key == $k) | .value' | head -1
}

bl_run_args_keys() {
    # bl_run_args_keys <args-json> — prints one key per line.
    printf '%s' "$1" | jq -r '.[].key'
}

bl_run_args_warn_unknown() {
    # bl_run_args_warn_unknown <args-json> <verb> <known-keys-space-separated>
    # Emits one bl_warn line per unknown key. Non-fatal.
    local args_json="$1" verb="$2" known="$3"
    local key
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        case " $known " in
            *" $key "*) : ;;
            *) bl_warn "$verb: unknown adapter arg '$key' (dropped — collector does not honor it)" ;;
        esac
    done < <(bl_run_args_keys "$args_json")
}

bl_run_args_relative_to_iso() {
    # bl_run_args_relative_to_iso <spec> — "72h"|"30m"|"2d"|"45s" → ISO-8601 UTC
    # timestamp <spec> ago. ISO input is passed through unchanged.
    local spec="$1"
    if [[ "$spec" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        printf '%s' "$spec"   # already ISO; pass through
        return 0
    fi
    if [[ "$spec" =~ ^([0-9]+)([hmds])$ ]]; then
        local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}"
        local secs
        case "$u" in
            h) secs=$((n * 3600))   ;;
            m) secs=$((n * 60))     ;;
            d) secs=$((n * 86400))  ;;
            s) secs="$n"            ;;
        esac
        local now_epoch then_epoch
        now_epoch=$(date -u +%s)
        then_epoch=$((now_epoch - secs))
        date -u -d "@$then_epoch" +'%Y-%m-%dT%H:%M:%SZ'
        return 0
    fi
    # Unrecognized — pass through verbatim and let the collector reject it.
    printf '%s' "$spec"
}

# ----------------------------------------------------------------------------
# Per-verb adapters — bl_observe_<v>_from_args. Each adapter:
#   1. Extracts curator-emitted args (semantic key names).
#   2. Maps them to collector-native flag names.
#   3. Fans out comma-separated multi-values where the collector takes single.
#   4. Drops unknown keys with bl_warn (non-fatal).
#   5. Calls the underlying collector once per axis-value and returns first non-zero rc.
# Curator-vocabulary key set is observed from CASE-2026-0022 emissions; future
# curator versions may emit additional keys — extend the warn-unknown list per
# verb when adding.
# ----------------------------------------------------------------------------

bl_observe_file_from_args() {
    local args_json="$1"
    bl_run_args_warn_unknown "$args_json" "observe.file" "path attribution_from"
    local path attr
    path=$(bl_run_args_get "$args_json" "path")
    attr=$(bl_run_args_get "$args_json" "attribution_from")
    [[ -z "$path" ]] && { bl_error_envelope run "observe.file: missing 'path' arg"; return "$BL_EX_USAGE"; }
    if [[ -n "$attr" ]]; then
        bl_observe_file --attribution-from "$attr" "$path"
    else
        bl_observe_file "$path"
    fi
}

bl_observe_log_apache_from_args() {
    local args_json="$1"
    bl_run_args_warn_unknown "$args_json" "observe.log_apache" "around path since window scope filters summarize site"
    local around window site since
    around=$(bl_run_args_get "$args_json" "around")
    [[ -z "$around" ]] && around=$(bl_run_args_get "$args_json" "path")
    window=$(bl_run_args_get "$args_json" "window")
    [[ -z "$window" ]] && window=$(bl_run_args_get "$args_json" "since")   # curator commonly says "since=72h"
    site=$(bl_run_args_get "$args_json" "site")
    if [[ -z "$around" ]]; then
        bl_error_envelope run "observe.log_apache: missing 'around' or 'path' arg (collector requires --around <log-path>)"
        return "$BL_EX_USAGE"
    fi
    local cmd=( bl_observe_log_apache --around "$around" )
    [[ -n "$window" ]] && cmd+=( --window "$window" )
    [[ -n "$site" ]]   && cmd+=( --site "$site" )
    "${cmd[@]}"
}

bl_observe_log_modsec_from_args() {
    local args_json="$1"
    bl_run_args_warn_unknown "$args_json" "observe.log_modsec" "around path window since txn rule scope summarize"
    local around window txn rule
    around=$(bl_run_args_get "$args_json" "around")
    [[ -z "$around" ]] && around=$(bl_run_args_get "$args_json" "path")
    window=$(bl_run_args_get "$args_json" "window")
    [[ -z "$window" ]] && window=$(bl_run_args_get "$args_json" "since")
    txn=$(bl_run_args_get "$args_json" "txn")
    rule=$(bl_run_args_get "$args_json" "rule")
    if [[ -z "$around" ]]; then
        bl_error_envelope run "observe.log_modsec: missing 'around' or 'path' arg"
        return "$BL_EX_USAGE"
    fi
    local cmd=( bl_observe_log_modsec --around "$around" )
    [[ -n "$window" ]] && cmd+=( --window "$window" )
    [[ -n "$txn" ]]    && cmd+=( --txn "$txn" )
    [[ -n "$rule" ]]   && cmd+=( --rule "$rule" )
    "${cmd[@]}"
}

bl_observe_log_journal_from_args() {
    local args_json="$1"
    bl_run_args_warn_unknown "$args_json" "observe.log_journal" "since grep unit"
    local since grep_pat
    since=$(bl_run_args_get "$args_json" "since")
    grep_pat=$(bl_run_args_get "$args_json" "grep")
    # curator's "since=72h" relative form → collector accepts both ISO and relative; pass through
    local cmd=( bl_observe_log_journal )
    [[ -n "$since" ]]    && cmd+=( --since "$since" )
    [[ -n "$grep_pat" ]] && cmd+=( --grep "$grep_pat" )
    "${cmd[@]}"
}

bl_observe_cron_from_args() {
    local args_json="$1"
    bl_run_args_warn_unknown "$args_json" "observe.cron" "scope user system from_file from-file include_anacron"
    local scope user from_file
    scope=$(bl_run_args_get "$args_json" "scope")
    user=$(bl_run_args_get "$args_json" "user")
    from_file=$(bl_run_args_get "$args_json" "from_file")
    [[ -z "$from_file" ]] && from_file=$(bl_run_args_get "$args_json" "from-file")
    if [[ -n "$from_file" ]]; then
        bl_observe_cron --from-file "$from_file"
        return $?
    fi
    # scope handling: "system+per-user", "system", "per-user", "user"
    local rc=0 first_rc=0
    case "$scope" in
        *system*|*"per-user"*|*user*|"")
            if [[ "$scope" == *system* || -z "$scope" ]]; then
                bl_observe_cron --system || { rc=$?; (( first_rc == 0 )) && first_rc=$rc; }
            fi
            if [[ -n "$user" ]]; then
                bl_observe_cron --user "$user" || { rc=$?; (( first_rc == 0 )) && first_rc=$rc; }
            fi
            ;;
    esac
    return "$first_rc"
}

bl_observe_proc_from_args() {
    local args_json="$1"
    bl_run_args_warn_unknown "$args_json" "observe.proc" "user verify_argv verify-argv"
    local user verify
    user=$(bl_run_args_get "$args_json" "user")
    verify=$(bl_run_args_get "$args_json" "verify_argv")
    [[ -z "$verify" ]] && verify=$(bl_run_args_get "$args_json" "verify-argv")
    [[ -z "$user" ]] && { bl_error_envelope run "observe.proc: missing 'user' arg"; return "$BL_EX_USAGE"; }
    if [[ "$verify" == "true" || "$verify" == "yes" || "$verify" == "1" ]]; then
        bl_observe_proc --user "$user" --verify-argv
    else
        bl_observe_proc --user "$user"
    fi
}

bl_observe_htaccess_from_args() {
    local args_json="$1"
    bl_run_args_warn_unknown "$args_json" "observe.htaccess" "root roots dir recursive include_disabled"
    local roots recursive
    roots=$(bl_run_args_get "$args_json" "roots")
    [[ -z "$roots" ]] && roots=$(bl_run_args_get "$args_json" "root")
    [[ -z "$roots" ]] && roots=$(bl_run_args_get "$args_json" "dir")
    recursive=$(bl_run_args_get "$args_json" "recursive")
    [[ -z "$roots" ]] && { bl_error_envelope run "observe.htaccess: missing 'root' or 'roots' arg"; return "$BL_EX_USAGE"; }
    local first_rc=0 root rc
    while IFS= read -r root; do
        [[ -z "$root" ]] && continue
        if [[ "$recursive" == "true" || "$recursive" == "yes" || "$recursive" == "1" ]]; then
            bl_observe_htaccess --recursive "$root" || { rc=$?; (( first_rc == 0 )) && first_rc=$rc; }
        else
            bl_observe_htaccess "$root" || { rc=$?; (( first_rc == 0 )) && first_rc=$rc; }
        fi
    done < <(printf '%s\n' "$roots" | tr ',' '\n')
    return "$first_rc"
}

bl_observe_fs_mtime_cluster_from_args() {
    local args_json="$1"
    bl_run_args_warn_unknown "$args_json" "observe.fs_mtime_cluster" "path under root window cluster_window_secs ext name_filter"
    local path window ext
    path=$(bl_run_args_get "$args_json" "path")
    [[ -z "$path" ]] && path=$(bl_run_args_get "$args_json" "under")
    [[ -z "$path" ]] && path=$(bl_run_args_get "$args_json" "root")
    window=$(bl_run_args_get "$args_json" "window")
    [[ -z "$window" ]] && window=$(bl_run_args_get "$args_json" "cluster_window_secs")
    ext=$(bl_run_args_get "$args_json" "ext")
    [[ -z "$ext" ]] && ext=$(bl_run_args_get "$args_json" "name_filter")
    [[ -z "$path" ]] && { bl_error_envelope run "observe.fs_mtime_cluster: missing 'path' or 'under'"; return "$BL_EX_USAGE"; }
    # First-extension only: collector takes single --ext. Drop comma-tail with warn.
    if [[ "$ext" == *,* ]]; then
        bl_warn "observe.fs_mtime_cluster: collector takes single --ext; using first of comma-list ('${ext%%,*}')"
        ext="${ext%%,*}"
    fi
    # Strip leading "*." glob prefix — collector takes bare extension
    ext="${ext#\*.}"
    local cmd=( bl_observe_fs_mtime_cluster )
    [[ -n "$window" ]] && cmd+=( --window "$window" )
    [[ -n "$ext" ]]    && cmd+=( --ext "$ext" )
    cmd+=( "$path" )
    "${cmd[@]}"
}

bl_observe_fs_mtime_since_from_args() {
    local args_json="$1"
    bl_run_args_warn_unknown "$args_json" "observe.fs_mtime_since" "since under roots root ext name_filter include_hidden"
    local since roots ext
    since=$(bl_run_args_get "$args_json" "since")
    roots=$(bl_run_args_get "$args_json" "roots")
    [[ -z "$roots" ]] && roots=$(bl_run_args_get "$args_json" "under")
    [[ -z "$roots" ]] && roots=$(bl_run_args_get "$args_json" "root")
    ext=$(bl_run_args_get "$args_json" "ext")
    [[ -z "$ext" ]] && ext=$(bl_run_args_get "$args_json" "name_filter")
    [[ -z "$since" ]] && { bl_error_envelope run "observe.fs_mtime_since: missing 'since'"; return "$BL_EX_USAGE"; }
    [[ -z "$roots" ]] && { bl_error_envelope run "observe.fs_mtime_since: missing 'under' or 'roots'"; return "$BL_EX_USAGE"; }
    # Convert curator-relative ("72h") → ISO; collector accepts both forms but
    # being explicit avoids any future collector tightening.
    since=$(bl_run_args_relative_to_iso "$since")
    if [[ "$ext" == *,* ]]; then
        bl_warn "observe.fs_mtime_since: collector takes single --ext; using first of comma-list ('${ext%%,*}')"
        ext="${ext%%,*}"
    fi
    ext="${ext#\*.}"
    local first_rc=0 root rc
    while IFS= read -r root; do
        [[ -z "$root" ]] && continue
        local cmd=( bl_observe_fs_mtime_since --since "$since" --under "$root" )
        [[ -n "$ext" ]] && cmd+=( --ext "$ext" )
        "${cmd[@]}" || { rc=$?; (( first_rc == 0 )) && first_rc=$rc; }
    done < <(printf '%s\n' "$roots" | tr ',' '\n')
    return "$first_rc"
}

bl_observe_firewall_from_args() {
    local args_json="$1"
    bl_run_args_warn_unknown "$args_json" "observe.firewall" "backend"
    local backend
    backend=$(bl_run_args_get "$args_json" "backend")
    if [[ -n "$backend" ]]; then
        bl_observe_firewall --backend "$backend"
    else
        bl_observe_firewall
    fi
}

bl_observe_sigs_from_args() {
    local args_json="$1"
    bl_run_args_warn_unknown "$args_json" "observe.sigs" "scanner root signature_db"
    local scanner
    scanner=$(bl_run_args_get "$args_json" "scanner")
    if [[ -n "$scanner" ]]; then
        bl_observe_sigs --scanner "$scanner"
    else
        bl_observe_sigs
    fi
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
    bl_mem_get "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/pending/$step_id.json" 2>/dev/null | jq -r '.content' > "$pending_tmp" || true   # transient miss

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
    printf '%s' "$result_content" > "$body_file"
    bl_mem_post "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/results/$step_id.json" "$body_file"
    local post_rc=$?
    command rm -f "$body_file"
    (( post_rc != 0 )) && { command rm -f "$pending_tmp"; return "$post_rc"; }
    bl_mem_delete_by_key "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/pending/$step_id.json" || bl_warn "pending delete failed; manual cleanup may be needed"
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
    list_body=$(bl_mem_list "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/pending/") || return $?
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
    list_body=$(bl_mem_list "${BL_MEMSTORE_CASE_ID}" "bl-case/$case_id/pending/") || return $?
    local keys
    keys=$(printf '%s' "$list_body" | jq -r '.data[].key' | sort)
    if [[ -z "$keys" ]]; then
        bl_info "no pending steps"
        return "$BL_EX_OK"
    fi
    printf '%-8s  %-24s  %-11s  %s\n' "step_id" "verb" "tier" "reasoning"
    local key body sid verb tier reasoning
    while IFS= read -r key; do
        body=$(bl_mem_get "${BL_MEMSTORE_CASE_ID}" "$key" 2>/dev/null | jq -r '.content') || continue   # skip unreadable
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

