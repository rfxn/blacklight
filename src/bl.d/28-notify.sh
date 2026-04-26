# shellcheck shell=bash
# ----------------------------------------------------------------------------
# 28-notify.sh — bl_notify thin wrapper over alert_lib (multi-channel dispatch).
# Depends on: 05-vendor-alert (alert_dispatch + alert_channel_*), 25-ledger,
# 27-outbox. Called from 30-preflight (channel registration) and from M14
# consult/run/case/setup paths (operator + curator notifications).
#
# API divergence note: alert_dispatch(template_dir, subject, [channels], [attachment])
# requires a template directory. bl_notify bridges the simple subject+body+severity
# API by writing per-channel text templates to a mktemp dir before dispatch.
# alert_lib already auto-registers email/slack/telegram/discord at source time;
# _bl_notify_register_channels only calls alert_channel_enable — never re-registers.
# ----------------------------------------------------------------------------

# _bl_notify_handle_syslog subject text_file html_file [attachment] — syslog channel
# alert_lib does not ship a syslog handler; define one locally. Uses logger(1).
_bl_notify_handle_syslog() {
    local subject="$1" text_file="$2"
    local logger_bin
    logger_bin=$(command -v logger 2>/dev/null || true)   # 2>/dev/null + || true: logger absence is normal on minimal containers; handled by empty-bin check below
    [[ -z "$logger_bin" ]] && return 1
    local msg
    msg=$(command cat "$text_file" 2>/dev/null | head -1)   # 2>/dev/null: text_file may be absent in degraded preflight; empty msg falls through to log call
    "$logger_bin" -t blacklight -p user.notice -- "[$subject] ${msg:-<empty>}"
}

# bl_notify <case_id> <severity> <subject> <body>
# Severity vocabulary: info | warn | critical.
# Returns 0 if any enabled channel succeeded; 69 (BL_EX_UPSTREAM_ERROR) if all
# enabled channels failed; 64 (BL_EX_USAGE) on missing args.
bl_notify() {
    local case_id="$1" severity="$2" subject="$3" body="$4"
    [[ -z "$case_id" || -z "$severity" || -z "$subject" || -z "$body" ]] && {
        bl_error_envelope notify "missing args: bl_notify <case_id> <severity> <subject> <body>"
        return "$BL_EX_USAGE"
    }

    # Severity-floor gate
    local floor="${BL_NOTIFY_SEVERITY_FLOOR:-info}"
    case "$floor:$severity" in
        critical:info|critical:warn|warn:info)
            bl_debug "notify: severity $severity below floor $floor; suppress"
            return "$BL_EX_OK"
            ;;
    esac

    # Build a temp template dir — alert_dispatch(template_dir, subject, channel)
    # requires per-channel *.text.tpl files for template rendering.
    local tpl_dir
    tpl_dir=$(mktemp -d) || {
        bl_warn "notify: mktemp -d failed; cannot dispatch channels"
        return "$BL_EX_UPSTREAM_ERROR"
    }
    printf '%s\n' "$body" > "$tpl_dir/slack.text.tpl"
    printf '%s\n' "$body" > "$tpl_dir/email.text.tpl"
    printf '%s\n' "$body" > "$tpl_dir/telegram.text.tpl"
    printf '%s\n' "$body" > "$tpl_dir/discord.text.tpl"
    printf '%s\n' "$body" > "$tpl_dir/syslog.text.tpl"

    local channels_attempted=() channels_succeeded=() ch
    for ch in slack syslog email telegram discord; do
        alert_channel_enabled "$ch" || continue
        channels_attempted+=("$ch")
        local rc=0
        alert_dispatch "$tpl_dir" "$subject" "$ch" 2>/dev/null || rc=$?   # 2>/dev/null: alert_lib emits per-channel chatter that pollutes operator stderr; rc captures success/fail
        if (( rc == 0 )); then
            channels_succeeded+=("$ch")
        else
            _bl_notify_emit_failed "$case_id" "$ch" "$severity" "rc=$rc"
        fi
    done

    command rm -rf "$tpl_dir" 2>/dev/null || true   # 2>/dev/null: cleanup failure is non-fatal; tempdir is in TMPDIR which OS reclaims on reboot

    _bl_notify_emit_dispatched "$case_id" "${channels_attempted[*]}" "${channels_succeeded[*]}" "$severity"

    (( ${#channels_succeeded[@]} > 0 )) && return "$BL_EX_OK"
    (( ${#channels_attempted[@]} == 0 )) && {
        bl_warn "notify: no channels enabled; skipping"
        return "$BL_EX_OK"
    }
    return "$BL_EX_UPSTREAM_ERROR"
}

# _bl_notify_register_channels — called from bl_preflight after conf load.
# (1) Register syslog (alert_lib does not ship a syslog handler);
# (2) email/slack/telegram/discord are already registered by alert_lib at
#     source time — do NOT re-register; (3) enable channels whose token file
#     exists, is non-empty, and is chmod 0600 (R5 mitigation per spec §11).
_bl_notify_register_channels() {
    local notify_dir="${BL_NOTIFY_DIR:-/etc/blacklight/notify.d}"

    # Syslog — register local handler (not provided by alert_lib)
    alert_channel_register syslog "_bl_notify_handle_syslog" 2>/dev/null || true   # 2>/dev/null: register fails silently if called more than once (idempotent guard)
    # Syslog — enable if logger exists; no token file required
    command -v logger >/dev/null 2>&1 && alert_channel_enable syslog   # logger absence on minimal containers is safe; channel stays disabled

    # Slack
    if [[ -r "$notify_dir/slack.token" ]] && [[ -s "$notify_dir/slack.token" ]]; then
        local perms
        perms=$(command stat -c '%a' "$notify_dir/slack.token" 2>/dev/null) || perms=""   # 2>/dev/null: missing/race-removed file falls through to skip-enable
        if [[ "$perms" == "600" ]]; then
            _bl_notify_export_from_file "$notify_dir/slack.token" ALERT_SLACK
            alert_channel_enable slack
        else
            bl_warn "notify: slack.token perms ${perms:-unknown} != 600; skip-enable (R5)"
        fi
    fi

    # Email
    if [[ -r "$notify_dir/smtp.email" ]] && [[ -s "$notify_dir/smtp.email" ]]; then
        local perms
        perms=$(command stat -c '%a' "$notify_dir/smtp.email" 2>/dev/null) || perms=""   # 2>/dev/null: race
        if [[ "$perms" == "600" ]]; then
            _bl_notify_export_from_file "$notify_dir/smtp.email" ALERT_SMTP
            alert_channel_enable email
        else
            bl_warn "notify: smtp.email perms ${perms:-unknown} != 600; skip-enable (R5)"
        fi
    fi

    # Telegram
    if [[ -r "$notify_dir/telegram.token" ]] && [[ -s "$notify_dir/telegram.token" ]]; then
        local perms
        perms=$(command stat -c '%a' "$notify_dir/telegram.token" 2>/dev/null) || perms=""   # 2>/dev/null: race
        if [[ "$perms" == "600" ]]; then
            _bl_notify_export_from_file "$notify_dir/telegram.token" ALERT_TELEGRAM
            alert_channel_enable telegram
        else
            bl_warn "notify: telegram.token perms ${perms:-unknown} != 600; skip-enable (R5)"
        fi
    fi

    # Discord
    if [[ -r "$notify_dir/discord.webhook" ]] && [[ -s "$notify_dir/discord.webhook" ]]; then
        local perms
        perms=$(command stat -c '%a' "$notify_dir/discord.webhook" 2>/dev/null) || perms=""   # 2>/dev/null: race
        if [[ "$perms" == "600" ]]; then
            local webhook_url
            # Read first line of webhook file; command cat + head -1 via read builtin
            # avoids piping command to head (head not in command-prefix coreutils list)
            IFS= read -r webhook_url < "$notify_dir/discord.webhook"
            export ALERT_DISCORD_WEBHOOK_URL="$webhook_url"
            alert_channel_enable discord
        else
            bl_warn "notify: discord.webhook perms ${perms:-unknown} != 600; skip-enable (R5)"
        fi
    fi

    return "$BL_EX_OK"
}

# _bl_notify_export_from_file <file> <prefix> — parse key=value file, export
# each <prefix>_<KEY>=<value>. Reject metacharacters per same allowlist as
# _bl_load_blacklight_conf (defined in 30-preflight.sh).
_bl_notify_export_from_file() {
    local file="$1" prefix="$2"
    local line key value
    while IFS= read -r line; do
        # Skip blank + comment lines
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # Strip surrounding quotes (single or double)
            value="${value%\"}"; value="${value#\"}"
            value="${value%\'}"; value="${value#\'}"
            # Allowlist: reject metacharacters in value
            if [[ "$value" =~ [\;\|\&\$\(\)\{\}\`\<\>] ]]; then
                bl_warn "notify: $file key=$key value rejected (metacharacter)"
                continue
            fi
            local upper
            upper=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
            export "${prefix}_${upper}=$value"
        fi
    done < "$file"
}

# _bl_notify_emit_dispatched <case_id> <attempted-list> <succeeded-list> <severity>
_bl_notify_emit_dispatched() {
    local case_id="$1" attempted="$2" succeeded="$3" severity="$4"
    local record
    record=$(jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg c "$case_id" \
        --arg sev "$severity" \
        --arg att "$attempted" \
        --arg ok "$succeeded" \
        '{ts:$ts, case:$c, kind:"notify_dispatched", payload:{
            channels_attempted:($att|split(" ")),
            channels_succeeded:($ok|split(" ")),
            severity:$sev}}')
    bl_ledger_append "$case_id" "$record" || \
        bl_warn "notify: ledger append failed (case=$case_id)"   # ledger fail must not block notify return
}

# _bl_notify_emit_failed <case_id> <channel> <severity> <error>
_bl_notify_emit_failed() {
    local case_id="$1" channel="$2" severity="$3" error="$4"
    local record
    record=$(jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg c "$case_id" \
        --arg ch "$channel" \
        --arg sev "$severity" \
        --arg err "$error" \
        '{ts:$ts, case:$c, kind:"notify_failed", payload:{
            channel:$ch, severity:$sev, error:$err}}')
    bl_ledger_append "$case_id" "$record" || \
        bl_warn "notify: ledger append failed (case=$case_id, channel=$channel)"   # ledger fail non-blocking; outbox still tries
    local notify_payload
    notify_payload=$(jq -n \
        --arg c "$case_id" \
        --arg ch "$channel" \
        --arg sev "$severity" \
        '{case:$c, channel:$ch, severity:$sev}')
    bl_outbox_enqueue notify "$notify_payload" 2>/dev/null || true   # 2>/dev/null + || true: outbox can be unwritable mid-test; per-channel retry is opportunistic, not load-bearing for the notify-fail accounting itself
}
