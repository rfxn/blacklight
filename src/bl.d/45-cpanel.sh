# shellcheck shell=bash
# ----------------------------------------------------------------------------
# 45-cpanel.sh — cPanel EA4 apply paths for bl_defend_modsec Stage 4.
# Depends on: 10-log, 25-ledger, 28-notify (critical notify on rollback fail).
# Test isolation: BL_CPANEL_SCRIPT_DIR + BL_CPANEL_DIR redirect cPanel paths
# for unit tests; production hosts use defaults.
# ----------------------------------------------------------------------------

# _bl_cpanel_present — detect cPanel: dir + executable restartsrv_httpd both required.
_bl_cpanel_present() {
    local cpanel_dir="${BL_CPANEL_DIR:-/usr/local/cpanel}"
    local scripts_dir="${BL_CPANEL_SCRIPT_DIR:-/usr/local/cpanel/scripts}"
    [[ -d "$cpanel_dir" ]] && [[ -x "$scripts_dir/restartsrv_httpd" ]]
}

# _bl_cpanel_lockin_global <case_id> <conf_file> <backup_path>
# Stage 4 invoke for global ModSec config (modsec2.user.conf).
# Sequence: emit invoked → timeout-wrapped restartsrv_httpd → on fail, restore
# backup + retry once; on retry-fail emit rolled_back + critical notify.
_bl_cpanel_lockin_global() {
    local case_id="$1" conf_file="$2" backup_path="$3"
    local timeout_secs="${BL_CPANEL_LOCKIN_TIMEOUT_SECONDS:-60}"
    local scripts_dir="${BL_CPANEL_SCRIPT_DIR:-/usr/local/cpanel/scripts}"

    _bl_cpanel_emit_invoked "$case_id" "global" "$conf_file"

    local restartsrv_rc=0
    timeout "$timeout_secs" "$scripts_dir/restartsrv_httpd" --restart \
        >/tmp/bl-cpanel-restart.$$.log 2>&1 || restartsrv_rc=$?

    if (( restartsrv_rc == 0 )); then
        command rm -f /tmp/bl-cpanel-restart.$$.log
        return "$BL_EX_OK"
    fi

    # Stage 4 fail — capture diagnostics before removing log
    local err_tail
    err_tail=$(tail -10 /tmp/bl-cpanel-restart.$$.log 2>/dev/null | head -c 500) || err_tail=""   # 2>/dev/null: log may have rotated; tail-fail is non-blocking
    command rm -f /tmp/bl-cpanel-restart.$$.log
    _bl_cpanel_emit_failed "$case_id" "global" "$conf_file" "$restartsrv_rc" "$err_tail"

    # Two-stage rollback: restore backup → retry restart.
    # First-apply guard: empty backup_path means no prior version to roll back to;
    # emit warn+notify and return fail without a misleading cpanel_lockin_rolled_back.
    if [[ -z "$backup_path" ]]; then
        bl_warn "cpanel: Stage 4 failed on first apply (no backup to restore); manual operator intervention required"
        bl_notify "$case_id" "critical" "Stage 4 failed on first apply" \
            "restartsrv_httpd rc=$restartsrv_rc on first ModSec rule application; no prior version to restore — manual operator intervention required" || true   # || true: notify-fail must not mask the load-bearing Stage 4 fail return
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    if [[ -r "$backup_path" ]]; then
        command cp "$backup_path" "$conf_file" || {
            _bl_cpanel_emit_rolled_back "$case_id" "global" "$conf_file" "false"
            return "$BL_EX_PREFLIGHT_FAIL"
        }
    else
        bl_warn "cpanel rollback: backup unreadable at $backup_path"
        _bl_cpanel_emit_rolled_back "$case_id" "global" "$conf_file" "false"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    local retry_rc=0
    timeout "$timeout_secs" "$scripts_dir/restartsrv_httpd" --restart \
        >/dev/null 2>&1 || retry_rc=$?   # 2>/dev/null: retry diagnostics already captured above; further chatter pollutes operator stderr

    if (( retry_rc == 0 )); then
        _bl_cpanel_emit_rolled_back "$case_id" "global" "$conf_file" "true"
    else
        _bl_cpanel_emit_rolled_back "$case_id" "global" "$conf_file" "false"
        bl_notify "$case_id" "critical" "Stage 4 rollback failed" \
            "restartsrv_httpd retry rc=$retry_rc; manual intervention required" || true   # || true: notify-fail must not mask the load-bearing rolled-back ledger event
    fi

    return "$BL_EX_PREFLIGHT_FAIL"
}

# _bl_cpanel_lockin_uservhost <case_id> <user> <domain> <vhost_conf> <backup_path>
# Per-vhost path: ensure_vhost_includes → restartsrv_httpd; symmetric rollback.
_bl_cpanel_lockin_uservhost() {
    local case_id="$1" user="$2" vhost_conf="$4" backup_path="$5"
    # shellcheck disable=SC2034  # domain: reserved for per-vhost audit trail; not used in current restart path
    local domain="$3"
    local timeout_secs="${BL_CPANEL_LOCKIN_TIMEOUT_SECONDS:-60}"
    local scripts_dir="${BL_CPANEL_SCRIPT_DIR:-/usr/local/cpanel/scripts}"

    _bl_cpanel_emit_invoked "$case_id" "uservhost" "$vhost_conf"

    # Stage 3a: ensure_vhost_includes (idempotent; adds includes if missing)
    if ! "$scripts_dir/ensure_vhost_includes" --user="$user" >/dev/null 2>&1; then   # 2>/dev/null: per-user output noise; failure captured by rc
        _bl_cpanel_emit_failed "$case_id" "uservhost" "$vhost_conf" "$?" "ensure_vhost_includes failed"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    # Stage 4: restartsrv_httpd
    local restartsrv_rc=0
    timeout "$timeout_secs" "$scripts_dir/restartsrv_httpd" --restart \
        >/dev/null 2>&1 || restartsrv_rc=$?   # 2>/dev/null: chatter

    if (( restartsrv_rc == 0 )); then
        return "$BL_EX_OK"
    fi

    _bl_cpanel_emit_failed "$case_id" "uservhost" "$vhost_conf" "$restartsrv_rc" ""

    # Symmetric rollback — same first-apply + cp-guard discipline as global path
    if [[ -z "$backup_path" ]]; then
        bl_warn "cpanel uservhost: Stage 4 failed on first apply (no backup); manual operator intervention required"
        bl_notify "$case_id" "critical" "Stage 4 failed on first vhost apply" \
            "user=$user vhost=$vhost_conf restartsrv_rc=$restartsrv_rc; no prior version to restore" || true   # || true: notify-fail must not mask the load-bearing Stage 4 fail return
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    if [[ -r "$backup_path" ]]; then
        command cp "$backup_path" "$vhost_conf" || {
            _bl_cpanel_emit_rolled_back "$case_id" "uservhost" "$vhost_conf" "false"
            bl_notify "$case_id" "critical" "vhost backup-restore failed" \
                "user=$user vhost=$vhost_conf — manual intervention required" || true   # || true: notify-fail non-blocking
            return "$BL_EX_PREFLIGHT_FAIL"
        }
    else
        bl_warn "cpanel uservhost rollback: backup unreadable at $backup_path"
        _bl_cpanel_emit_rolled_back "$case_id" "uservhost" "$vhost_conf" "false"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    local retry_rc=0
    timeout "$timeout_secs" "$scripts_dir/restartsrv_httpd" --restart \
        >/dev/null 2>&1 || retry_rc=$?   # 2>/dev/null: chatter

    if (( retry_rc == 0 )); then
        _bl_cpanel_emit_rolled_back "$case_id" "uservhost" "$vhost_conf" "true"
    else
        _bl_cpanel_emit_rolled_back "$case_id" "uservhost" "$vhost_conf" "false"
        bl_notify "$case_id" "critical" "Stage 4 rollback failed (vhost)" \
            "user=$user vhost=$vhost_conf retry_rc=$retry_rc" || true   # || true: notify-fail non-blocking
    fi

    return "$BL_EX_PREFLIGHT_FAIL"
}

_bl_cpanel_emit_invoked() {
    local case_id="$1" scope="$2" target="$3"
    bl_ledger_append "$case_id" \
        "$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$case_id" \
            --arg sc "$scope" --arg t "$target" \
            '{ts:$ts, case:$c, kind:"cpanel_lockin_invoked", payload:{scope:$sc, target_path:$t}}')" || \
        bl_warn "ledger append failed for cpanel_lockin_invoked"
}

_bl_cpanel_emit_failed() {
    local case_id="$1" scope="$2" target="$3" rc="$4" err="$5"
    bl_ledger_append "$case_id" \
        "$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$case_id" \
            --arg sc "$scope" --arg t "$target" --argjson r "$rc" --arg e "$err" \
            '{ts:$ts, case:$c, kind:"cpanel_lockin_failed", payload:{scope:$sc, target_path:$t, restartsrv_rc:$r, error_log_tail:$e}}')" || \
        bl_warn "ledger append failed for cpanel_lockin_failed"
}

_bl_cpanel_emit_rolled_back() {
    local case_id="$1" scope="$2" target="$3" succeeded="$4"
    bl_ledger_append "$case_id" \
        "$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$case_id" \
            --arg sc "$scope" --arg t "$target" --argjson ok "$succeeded" \
            '{ts:$ts, case:$c, kind:"cpanel_lockin_rolled_back", payload:{scope:$sc, target_path:$t, rollback_succeeded:$ok}}')" || \
        bl_warn "ledger append failed for cpanel_lockin_rolled_back"
}
