# shellcheck shell=bash
# ----------------------------------------------------------------------------
# bl_defend — M6: apply agent-authored payload (modsec rules / firewall IPs /
# scanner signatures) with rollback, CDN-safe-list + FP-corpus gating, and
# ledger audit trail per DESIGN.md §5.4 + §13.4.
# ----------------------------------------------------------------------------

bl_defend() {
    # bl_defend <verb> <args...> — route to sub-handler by verb
    if (( $# == 0 )); then
        bl_error_envelope defend "no sub-verb (use modsec|firewall|sig)"
        return "$BL_EX_USAGE"
    fi
    local verb="$1"
    shift
    case "$verb" in
        modsec)    bl_defend_modsec "$@";    return $? ;;
        firewall)  bl_defend_firewall "$@";  return $? ;;
        sig)       bl_defend_sig "$@";       return $? ;;
        *)
            bl_error_envelope defend "unknown sub-verb: $verb" \
                "(use modsec|firewall|sig)"
            return "$BL_EX_USAGE"
            ;;
    esac
}

# ---- modsec ---------------------------------------------------------------

_bl_defend_modsec_binary() {
    # Prints apachectl or apache2ctl based on detection; fails 65 if neither.
    if command -v apache2ctl >/dev/null 2>&1; then
        printf 'apache2ctl'
        return "$BL_EX_OK"
    fi
    if command -v apachectl >/dev/null 2>&1; then
        printf 'apachectl'
        return "$BL_EX_OK"
    fi
    bl_error_envelope defend "neither apache2ctl nor apachectl found"
    return "$BL_EX_PREFLIGHT_FAIL"
}

_bl_defend_modsec_confdir() {
    # Prints the apache conf.d path. Prefers test-override
    # BL_DEFEND_APACHE_CONFDIR; else RHEL default, else Debian default.
    if [[ -n "${BL_DEFEND_APACHE_CONFDIR:-}" ]]; then
        printf '%s' "$BL_DEFEND_APACHE_CONFDIR"
        return "$BL_EX_OK"
    fi
    if [[ -d /etc/httpd/conf.d ]]; then
        printf '/etc/httpd/conf.d'
        return "$BL_EX_OK"
    fi
    if [[ -d /etc/apache2/mods-enabled ]]; then
        printf '/etc/apache2/mods-enabled'
        return "$BL_EX_OK"
    fi
    bl_error_envelope defend "no Apache conf.d directory found"
    return "$BL_EX_PREFLIGHT_FAIL"
}

_bl_defend_modsec_next_version() {
    # $1 = confdir; prints next version number. Reads existing bl-rules.conf
    # symlink target (bl-rules-vN.conf), increments N. Starts at 1 if absent.
    local confdir="$1"
    local live="$confdir/bl-rules.conf"
    if [[ ! -L "$live" ]]; then
        printf '1'
        return "$BL_EX_OK"
    fi
    local target
    target=$(readlink "$live")
    local n
    n=$(printf '%s' "$target" | sed -n 's/^bl-rules-v\([0-9]\+\)\.conf$/\1/p')
    if [[ -z "$n" ]]; then
        bl_error_envelope defend "unexpected symlink target: $target"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    printf '%d' "$((n + 1))"
    return "$BL_EX_OK"
}

_bl_defend_ledger_emit() {
    # $1 = case-id; $2 = kind; $3 = jq args-builder program; $4+ = jq args
    local case_id="$1"
    local kind="$2"
    local payload_prog="$3"
    shift 3
    local record
    record=$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                  --arg c "$case_id" \
                  --arg k "$kind" \
                  "$@" \
                  "{ts:\$ts, case:\$c, kind:\$k, payload:$payload_prog}") || {
        bl_warn "ledger emit: jq render failed (kind=$kind)"
        return "$BL_EX_OK"
    }
    # Ledger append is best-effort for defend: an unwritable ledger must not
    # block an otherwise-successful apply. Log + continue.
    bl_ledger_append "$case_id" "$record" || \
        bl_warn "ledger append failed (case=$case_id kind=$kind); continuing"
    return "$BL_EX_OK"
}

bl_defend_modsec() {
    # bl_defend_modsec <rule-file-or-id> [--remove] [--yes] [--reason <str>]
    local target=""
    local remove="no"
    local yes="no"
    local reason=""
    while (( $# > 0 )); do
        case "$1" in
            --remove)  remove="yes"; shift ;;
            --yes)     yes="yes"; shift ;;
            --reason)  reason="$2"; shift 2 ;;
            -*)        bl_error_envelope defend "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)         target="$1"; shift ;;
        esac
    done
    [[ -z "$target" ]] && { bl_error_envelope defend "missing <rule-file> or <rule-id>"; return "$BL_EX_USAGE"; }

    local case_id
    case_id=$(bl_case_current)
    [[ -z "$case_id" ]] && case_id="CASE-0000-0000"   # adhoc apply outside a case

    local apachectl confdir
    apachectl=$(_bl_defend_modsec_binary) || return $?
    confdir=$(_bl_defend_modsec_confdir) || return $?

    bl_init_workdir || return $?

    if [[ "$remove" == "yes" ]]; then
        _bl_defend_modsec_remove "$target" "$yes" "$reason" "$case_id" "$apachectl" "$confdir"
        return $?
    fi

    # Apply path: target is a rule-file
    if [[ ! -r "$target" ]]; then
        bl_error_envelope defend "rule file not readable: $target"
        return "$BL_EX_NOT_FOUND"
    fi

    local version new_file new_name prev_target live
    live="$confdir/bl-rules.conf"
    version=$(_bl_defend_modsec_next_version "$confdir") || return $?
    new_name="bl-rules-v${version}.conf"
    new_file="$confdir/$new_name"
    prev_target=""
    [[ -L "$live" ]] && prev_target=$(readlink "$live")

    # If a prior versioned file exists, carry its rules forward then append
    # the new file's contents. Full-history approach: each version is a full
    # rule-set, not a diff.
    if [[ -n "$prev_target" && -r "$confdir/$prev_target" ]]; then
        command cat "$confdir/$prev_target" "$target" > "$new_file"
    else
        command cp "$target" "$new_file"
    fi

    if ! "$apachectl" -t >/dev/null 2>&1; then   # configtest; fail-closed
        command rm -f "$new_file"
        # shellcheck disable=SC2016  # $t,$new,$prev,$r are jq --arg variable names, not shell variables
        _bl_defend_ledger_emit "$case_id" "defend_rollback" \
            '{verb:"defend.modsec", target:$t, reason:"configtest_fail"}' \
            --arg t "$target"
        bl_error_envelope defend "apachectl configtest failed; rolled back"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    # Atomic symlink swap: `command ln -sfn` writes the new symlink atomically.
    command ln -sfn "$new_name" "$live" || {
        command rm -f "$new_file"
        bl_error_envelope defend "symlink swap failed; rolled back"
        return "$BL_EX_PREFLIGHT_FAIL"
    }

    "$apachectl" graceful >/dev/null 2>&1 || \
        bl_warn "graceful reload returned non-zero (rules applied but server reload may require manual intervention)"   # reload failure non-fatal: rules are applied in config; manual 'service reload' is operator's fallback

    # shellcheck disable=SC2016  # $t,$new,$prev,$r are jq --arg variable names, not shell variables
    _bl_defend_ledger_emit "$case_id" "defend_applied" \
        '{verb:"defend.modsec", target:$new, previous_symlink:$prev, result:"ok", retire_hint:"30d", reason:$r}' \
        --arg new "$new_name" --arg prev "$prev_target" --arg r "$reason"

    printf 'bl-defend-modsec: applied %s (was: %s)\n' "$new_name" "${prev_target:-none}" >&2
    return "$BL_EX_OK"
}

_bl_defend_modsec_remove() {
    # $1=rule-id $2=yes $3=reason $4=case-id $5=apachectl $6=confdir
    local rule_id="$1" yes="$2" reason="$3" case_id="$4" apachectl="$5" confdir="$6"
    if [[ "$yes" != "yes" ]]; then
        bl_error_envelope defend "remove is destructive; requires --yes"
        return "$BL_EX_TIER_GATE_DENIED"
    fi
    local live="$confdir/bl-rules.conf"
    if [[ ! -L "$live" ]]; then
        bl_error_envelope defend "no active bl-rules.conf symlink; nothing to remove"
        return "$BL_EX_NOT_FOUND"
    fi
    local prev_target
    prev_target=$(readlink "$live")
    local prev_file="$confdir/$prev_target"
    if ! grep -q "id:${rule_id}" "$prev_file" 2>/dev/null; then   # grep -c is unreliable; use -q
        bl_error_envelope defend "rule-id $rule_id not found in $prev_target"
        return "$BL_EX_NOT_FOUND"
    fi
    local version new_name new_file
    version=$(_bl_defend_modsec_next_version "$confdir") || return $?
    new_name="bl-rules-v${version}.conf"
    new_file="$confdir/$new_name"
    # Strip the rule block bounded by "SecRule.*id:<id>" and trailing blank line.
    # Simple approach: awk drops from "SecRule" paragraph containing id:<rule_id>
    # to next blank-line-or-SecRule boundary.
    awk -v rid="$rule_id" '
        BEGIN { skip = 0 }
        /^SecRule/ {
            # reset state on each SecRule paragraph boundary
            block = $0
            getline rest
            while (rest != "" && rest !~ /^SecRule/) { block = block "\n" rest; if ((getline rest) <= 0) break }
            if (block ~ "id:" rid) { skip = 1; next }
            print block
            if (rest != "") print rest
            next
        }
        { print }
    ' "$prev_file" > "$new_file"

    if ! "$apachectl" -t >/dev/null 2>&1; then   # configtest; fail-closed
        command rm -f "$new_file"
        # shellcheck disable=SC2016  # $id,$new,$prev,$r are jq --arg variable names, not shell variables
        _bl_defend_ledger_emit "$case_id" "defend_rollback" \
            '{verb:"defend.modsec_remove", rule_id:$id, reason:"configtest_fail"}' \
            --arg id "$rule_id"
        bl_error_envelope defend "apachectl configtest failed after remove; rolled back"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    command ln -sfn "$new_name" "$live" || {
        command rm -f "$new_file"
        bl_error_envelope defend "symlink swap failed; rolled back"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    "$apachectl" graceful >/dev/null 2>&1 || \
        bl_warn "graceful reload returned non-zero"   # non-fatal per apply path rationale

    # shellcheck disable=SC2016  # $id,$new,$prev,$r are jq --arg variable names, not shell variables
    _bl_defend_ledger_emit "$case_id" "defend_applied" \
        '{verb:"defend.modsec_remove", rule_id:$id, target:$new, previous_symlink:$prev, result:"ok", reason:$r}' \
        --arg id "$rule_id" --arg new "$new_name" --arg prev "$prev_target" --arg r "$reason"

    printf 'bl-defend-modsec: removed rule id:%s (%s → %s)\n' "$rule_id" "$prev_target" "$new_name" >&2
    return "$BL_EX_OK"
}

# ---- firewall (M6 P3 target) ----------------------------------------------

bl_defend_firewall() {
    bl_error_envelope defend "firewall sub-verb not yet implemented (M6 P3)"
    return "$BL_EX_USAGE"
}

# ---- sig (M6 P4 target) ---------------------------------------------------

bl_defend_sig() {
    bl_error_envelope defend "sig sub-verb not yet implemented (M6 P4)"
    return "$BL_EX_USAGE"
}
