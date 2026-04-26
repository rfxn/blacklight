# shellcheck shell=bash
# ----------------------------------------------------------------------------
# Bridge — session-event → memstore-pending sync (M16 P3, closes M12.5 gap).
#
# The curator emits report_step custom-tool calls inside its session. The
# operator-facing run-step contract reads from memstore bl-case/<case>/pending/
# (via bl_run_step). Without this bridge, those two stores are disconnected:
# the curator's prescriptions land in session.events and never reach the
# memstore, so `bl run <step-id>` returns 72 (not found).
#
# This bridge closes the gap:
#   1. GET /v1/sessions/<sid>/events?order=asc&limit=N&page=<cursor>
#   2. For each agent.custom_tool_use(name=report_step), POST the step body
#      (PLUS the custom_tool_use_id) to bl-case/<case>/pending/<step-id>.json
#   3. Save next_page cursor in state.json.session_cursors[<case-id>]
#
# Idempotent — re-runs with the saved cursor pull only new events; if a step
# was already POSTed (409 conflict), bl_bridge_post_step converts to success.
#
# API primitives:
#   - GET /v1/sessions/<sid>/events: opaque cursor pagination via ?page=
#     (response carries next_page). No ?after=<event-id>.
#   - POST memstore: 409 on duplicate path (bl_mem_post returns rc=71).
#
# The bridge is invoked explicitly via `bl flush --session-events [<case>]`,
# never implicitly. Failure mode is "stale pending/" — visible in `bl case
# show` — so the operator can re-run flush.
# ----------------------------------------------------------------------------

bl_bridge_post_step() {
    # bl_bridge_post_step <case-id> <step-body-json> — last-write-wins POST to memstore pending/.
    # Uses bl_mem_patch (DELETE + POST) instead of bl_mem_post so that curator
    # re-emissions of the same step_id with corrected content overwrite the
    # prior body. bl_mem_post returns rc=71 on 409 conflict but the memstore
    # retains the OLD body — that is the wrong semantic for a bridge whose job
    # is to keep memstore in sync with the latest session-event truth.
    # Sentinel finding M16 P3 #5.
    #
    # Skip when results/<step_id>.json already exists — the operator already
    # ran `bl run <step-id>` for this step and writeback persisted a result;
    # re-creating pending here would (a) reissue a step that's complete, and
    # (b) trigger a writeback HTTP 400 because the curator's session has
    # already received user.custom_tool_result for that custom_tool_use_id.
    # Sentinel finding M16 P5 #2.3.
    local case_id="$1"
    local step_body="$2"
    local step_id
    step_id=$(printf '%s' "$step_body" | jq -r '.step_id // empty')
    if [[ -z "$step_id" ]]; then
        bl_warn "bridge: skipping event with no step_id"
        return "$BL_EX_OK"
    fi
    # Step-id format guard — defense-in-depth against curator-poisoned step_id values.
    # bl_run_step has the same regex guard at its CLI dispatch boundary; this guard
    # closes the bridge-side path so polluted entries never land in memstore. Sentinel #8.
    if ! [[ "$step_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
        bl_warn "bridge: skipping event with malformed step_id: $step_id"
        return "$BL_EX_OK"
    fi
    # Skip if step has already been run (results/<step-id>.json exists).
    local results_key="bl-case/$case_id/results/$step_id.json"
    if bl_mem_get "${BL_MEMSTORE_CASE_ID}" "$results_key" >/dev/null 2>&1; then   # 2>/dev/null: bl_mem_get's "not found" stderr is the success-skip signal here
        bl_debug "bridge: step $step_id already has results/ — skipping pending re-creation"
        return "$BL_EX_OK"
    fi
    local key="bl-case/$case_id/pending/$step_id.json"
    local body_file
    body_file=$(command mktemp)
    printf '%s' "$step_body" > "$body_file"
    bl_mem_patch "${BL_MEMSTORE_CASE_ID}" "$key" "$body_file" >/dev/null
    local rc=$?
    command rm -f "$body_file"
    return "$rc"
}

bl_bridge_session_to_memstore() {
    # bl_bridge_session_to_memstore <case-id> — pull new report_step events
    # from the case's session and POST step bodies to memstore pending/.
    # Return-code map:
    #   0  success (including no-op when no new events or no session_id)
    #   64 missing/malformed case-id
    #   65 missing memstore id; bl_api_call 401/403/404/4xx propagation
    #   69 bl_api_call 5xx after retries
    #   70 bl_api_call 429 after retries
    # bl_mem_patch's underlying bl_mem_post 409 conversion returns 0 — the bridge
    # uses last-write-wins via patch (delete + post), so duplicate POSTs cannot
    # surface as 71 here.
    local case_id="$1"
    if [[ -z "$case_id" ]]; then
        bl_error_envelope bridge "case-id required"
        return "$BL_EX_USAGE"
    fi
    if ! [[ "$case_id" =~ ^CASE-[0-9]{4}-[0-9]{4}$ ]]; then
        bl_error_envelope bridge "case-id format invalid (expected CASE-YYYY-NNNN): $case_id"
        return "$BL_EX_USAGE"
    fi
    local state_file="$BL_STATE_DIR/state.json"
    if [[ ! -f "$state_file" ]]; then
        bl_debug "bridge: no state.json — workspace not seeded; no-op"
        return "$BL_EX_OK"
    fi
    local session_id
    session_id=$(jq -r --arg c "$case_id" '.session_ids[$c] // empty' "$state_file")
    if [[ -z "$session_id" ]]; then
        bl_debug "bridge: no session_id for $case_id (consult never registered curator); no-op"
        return "$BL_EX_OK"
    fi
    BL_MEMSTORE_CASE_ID="${BL_MEMSTORE_CASE_ID:-$(jq -r '.case_memstores._legacy // .case_memstores._default // empty' "$state_file")}"
    if [[ -z "$BL_MEMSTORE_CASE_ID" ]]; then
        bl_error_envelope bridge "no case-memstore id in state.json (run 'bl setup --sync')"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    local cursor
    cursor=$(jq -r --arg c "$case_id" '.session_cursors[$c] // empty' "$state_file" 2>/dev/null || printf '')   # 2>/dev/null: missing key on legacy state.json — empty cursor = pull from start
    local url_suffix="/v1/sessions/$session_id/events?order=asc&limit=100"
    [[ -n "$cursor" ]] && url_suffix="${url_suffix}&page=${cursor}"
    local resp rc
    resp=$(bl_api_call GET "$url_suffix") || rc=$?
    rc="${rc:-0}"
    (( rc != 0 )) && return "$rc"
    # Validate response is parseable JSON before downstream jq queries silently
    # treat parse failures as zero-event no-ops (sentinel finding #9).
    if ! printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then   # 2>/dev/null: jq parse-error diagnostic redundant; we surface the failure via the explicit error envelope below
        bl_error_envelope bridge "session events response is not valid JSON for $case_id"
        return "$BL_EX_UPSTREAM_ERROR"
    fi
    local event_count
    event_count=$(printf '%s' "$resp" | jq '.data | length // 0')
    # Save next_page cursor BEFORE the zero-event early return — otherwise a
    # zero-data-non-null-page response (sentinel finding #4) deadlocks: cursor
    # never advances, next invocation re-pulls the same window, never reaches
    # populated pages downstream. The Anthropic events endpoint pagination
    # invariant `next_page=null iff data=[]` is not documented in
    # ANTHROPIC-API-NOTES.md so we cannot assume it.
    local next_page
    next_page=$(printf '%s' "$resp" | jq -r '.next_page // empty')
    if [[ -n "$next_page" ]]; then
        local tmp_state="$state_file.tmp.$$"
        jq --arg c "$case_id" --arg p "$next_page" \
            '. + {session_cursors: ((.session_cursors // {}) + {($c): $p})}' "$state_file" > "$tmp_state"
        command mv "$tmp_state" "$state_file"
    fi
    if (( event_count == 0 )); then
        bl_debug "bridge: no new events for $case_id (cursor: $([[ -n "$next_page" ]] && printf 'advanced' || printf 'end-of-stream'))"
        return "$BL_EX_OK"
    fi
    # Process events in document order; only agent.custom_tool_use(report_step) drive POSTs.
    local i posted=0 skipped=0
    for (( i = 0; i < event_count; i++ )); do
        local etype ename eid einput
        etype=$(printf '%s' "$resp" | jq -r --argjson i "$i" '.data[$i].type // empty')
        if [[ "$etype" != "agent.custom_tool_use" ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        ename=$(printf '%s' "$resp" | jq -r --argjson i "$i" '.data[$i].name // empty')
        if [[ "$ename" != "report_step" ]]; then
            bl_debug "bridge: skipping non-report_step custom tool: $ename"
            skipped=$((skipped + 1))
            continue
        fi
        eid=$(printf '%s' "$resp" | jq -r --argjson i "$i" '.data[$i].id // empty')
        einput=$(printf '%s' "$resp" | jq -c --argjson i "$i" '.data[$i].input // {}')
        # Inject custom_tool_use_id into the step body so writeback (P4) can target the event.
        local step_body
        step_body=$(printf '%s' "$einput" | jq -c --arg id "$eid" '. + {custom_tool_use_id: $id}')
        bl_bridge_post_step "$case_id" "$step_body" || {
            bl_error_envelope bridge "step post failed for $case_id event $eid"
            return $?
        }
        posted=$((posted + 1))
    done
    bl_info "bridge: $case_id posted=$posted skipped=$skipped (cursor: $([[ -n "$next_page" ]] && printf 'advanced' || printf 'end-of-stream'))"
    return "$BL_EX_OK"
}

bl_bridge_flush_all_open_cases() {
    # bl_bridge_flush_all_open_cases — bridge every case in state.json.session_ids.
    # Returns 0 on all-success; first non-zero rc on partial failure (rest still attempted).
    local state_file="$BL_STATE_DIR/state.json"
    if [[ ! -f "$state_file" ]]; then
        bl_debug "bridge: no state.json — no-op"
        return "$BL_EX_OK"
    fi
    local cases
    cases=$(jq -r '.session_ids // {} | keys[]' "$state_file" 2>/dev/null)   # 2>/dev/null: missing field on legacy state — empty list, no-op
    if [[ -z "$cases" ]]; then
        bl_debug "bridge: no open sessions in state.json — no-op"
        return "$BL_EX_OK"
    fi
    local first_rc=0
    while IFS= read -r case_id; do
        [[ -z "$case_id" ]] && continue
        bl_bridge_session_to_memstore "$case_id" || {
            local rc=$?
            (( first_rc == 0 )) && first_rc="$rc"
            bl_warn "bridge: $case_id failed (rc=$rc); continuing"
        }
    done <<< "$cases"
    return "$first_rc"
}
