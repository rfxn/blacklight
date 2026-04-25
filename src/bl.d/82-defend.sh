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
    # bl_defend_modsec <rule-file-or-id> [--remove] [--yes] [--reason <str>] [--from-action <act-id>]
    local target=""
    local remove="no"
    local yes="no"
    local reason=""
    local from_action=""
    while (( $# > 0 )); do
        case "$1" in
            --remove)       remove="yes"; shift ;;
            --yes)          yes="yes"; shift ;;
            --reason)       reason="$2"; shift 2 ;;
            --from-action)  from_action="$2"; shift 2 ;;
            -*)             bl_error_envelope defend "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)              target="$1"; shift ;;
        esac
    done

    local case_id
    case_id=$(bl_case_current)
    [[ -z "$case_id" ]] && case_id="CASE-0000-0000"   # adhoc apply outside a case

    local apachectl confdir
    apachectl=$(_bl_defend_modsec_binary) || return $?
    confdir=$(_bl_defend_modsec_confdir) || return $?

    bl_init_workdir || return $?

    if [[ "$remove" == "yes" ]]; then
        [[ -z "$target" ]] && { bl_error_envelope defend "missing <rule-id> for --remove"; return "$BL_EX_USAGE"; }
        _bl_defend_modsec_remove "$target" "$yes" "$reason" "$case_id" "$apachectl" "$confdir"
        return $?
    fi

    # M11 P7: --from-action <act-id> sources the rule body from the curator's
    # synthesize_defense payload at bl-case/<case>/actions/pending/<act-id>.json.
    # File-path mode (positional arg) remains the primary path. The .json
    # extension matches schemas/defense.json — bl_jq_schema_check is JSON-strict
    # via --slurpfile (DESIGN.md §12.2).
    if [[ -n "$from_action" ]]; then
        if ! [[ "$from_action" =~ ^act-[A-Za-z0-9_-]{1,64}$ ]]; then
            bl_error_envelope defend "from-action: malformed act_id (expected act-... pattern)"
            return "$BL_EX_USAGE"
        fi
        [[ -z "$case_id" || "$case_id" == "CASE-0000-0000" ]] && {
            bl_error_envelope defend "from-action: no active case"
            return "$BL_EX_NOT_FOUND"
        }
        local memstore_id
        memstore_id="${BL_MEMSTORE_CASE_ID:-$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf 'memstore_bl_case')}"   # 2>/dev/null: state file may be absent on first invocation; fall through to default id
        local action_body action_payload action_kind action_rule_body
        action_body=$(bl_api_call GET "/v1/memory_stores/$memstore_id/memories/bl-case%2F$case_id%2Factions%2Fpending%2F$from_action.json") || return $?
        action_payload=$(printf '%s' "$action_body" | jq -r '.content')
        local payload_tmp
        payload_tmp=$(command mktemp)
        printf '%s' "$action_payload" > "$payload_tmp"
        local repo_root="${BL_REPO_ROOT:-$(command dirname "$(readlink -f "$0" 2>/dev/null || printf '.')" 2>/dev/null || printf '.')}"   # 2>/dev/null × 2: readlink may fail under bash -c (BASH_SOURCE empty); dirname of stale arg → fall back to '.'
        if ! bl_jq_schema_check "$repo_root/schemas/defense.json" "$payload_tmp"; then
            command rm -f "$payload_tmp"
            return "$BL_EX_SCHEMA_VALIDATION_FAIL"
        fi
        action_kind=$(printf '%s' "$action_payload" | jq -r '.kind')
        if [[ "$action_kind" != "modsec" ]]; then
            command rm -f "$payload_tmp"
            bl_error_envelope defend "from-action: kind '$action_kind' != modsec"
            return "$BL_EX_SCHEMA_VALIDATION_FAIL"
        fi
        action_rule_body=$(printf '%s' "$action_payload" | jq -r '.body')
        target=$(command mktemp)
        printf '%s' "$action_rule_body" > "$target"
        command rm -f "$payload_tmp"
        bl_debug "bl_defend_modsec: rule body sourced from $from_action"
    fi

    [[ -z "$target" ]] && { bl_error_envelope defend "missing <rule-file> or --from-action <act-id>"; return "$BL_EX_USAGE"; }

    # Apply path: target is a rule-file (positional, or mktemp from --from-action)
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

# ---- firewall -------------------------------------------------------------

# CDN ASN allowlist (as-of 2026-04). Hardcoded to avoid a DNS dependency
# at defense-time. Operator-extensible via $BL_DEFEND_EXTRA_CDN_ASNS (space-sep).
_BL_DEFEND_CDN_ASNS="AS13335 AS54113 AS16509 AS20940 AS16625 AS32934"
#                    ^Cloudflare ^Fastly ^AWS    ^Akamai ^Akamai ^Facebook

_bl_defend_firewall_detect_backend() {
    # Prints the first detected backend (apf|csf|nft|iptables) or fails 65.
    if command -v apf >/dev/null 2>&1 || [[ -x /usr/local/sbin/apf ]]; then
        printf 'apf'
        return "$BL_EX_OK"
    fi
    if command -v csf >/dev/null 2>&1 || [[ -x /usr/sbin/csf ]]; then
        printf 'csf'
        return "$BL_EX_OK"
    fi
    if command -v nft >/dev/null 2>&1; then
        printf 'nft'
        return "$BL_EX_OK"
    fi
    if command -v iptables >/dev/null 2>&1; then
        printf 'iptables'
        return "$BL_EX_OK"
    fi
    bl_error_envelope defend "no firewall backend detected (apf|csf|nft|iptables)"
    return "$BL_EX_PREFLIGHT_FAIL"
}

_bl_defend_firewall_is_private_ip() {
    # $1 = ip; returns 0 if RFC1918/loopback/link-local, 1 otherwise.
    local ip="$1"
    # 10/8, 172.16-31/12, 192.168/16, 127/8, 169.254/16
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^127\. ]] && return 0
    [[ "$ip" =~ ^169\.254\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    return 1
}

_bl_defend_firewall_validate_ip() {
    # $1 = candidate IP/CIDR. Returns 0 if syntactically valid + not over-broad,
    # else BL_EX_USAGE. Rejects 0.0.0.0/* and CIDR mask < /16 IPv4 / < /48 IPv6
    # (catches "block the internet" misfires from curator hallucinations or
    # operator typos). Override via BL_DEFEND_FW_ALLOW_BROAD_IP=yes.
    local ip="$1"
    local v4='^(25[0-5]|2[0-4][0-9]|[01]?[0-9]{1,2})(\.(25[0-5]|2[0-4][0-9]|[01]?[0-9]{1,2})){3}(/(3[0-2]|[12]?[0-9]))?$'
    local v6='^[0-9a-fA-F:]+(/(12[0-8]|1[01][0-9]|[1-9]?[0-9]))?$'
    if [[ "$ip" =~ $v4 ]]; then
        # Reject 0.0.0.0 prefix entirely (unicast catch-all)
        [[ "$ip" =~ ^0\. || "$ip" == "0.0.0.0"* ]] && {
            bl_error_envelope defend "rejected 0.0.0.0 prefix: $ip"
            return "$BL_EX_USAGE"
        }
        # Mask floor: /16 unless override
        if [[ "$ip" == */* && "${BL_DEFEND_FW_ALLOW_BROAD_IP:-}" != "yes" ]]; then
            local mask="${ip##*/}"
            (( mask < 16 )) && {
                bl_error_envelope defend "CIDR /$mask too broad (floor /16; set BL_DEFEND_FW_ALLOW_BROAD_IP=yes to override): $ip"
                return "$BL_EX_USAGE"
            }
        fi
        return "$BL_EX_OK"
    fi
    if [[ "$ip" =~ $v6 ]]; then
        if [[ "$ip" == */* && "${BL_DEFEND_FW_ALLOW_BROAD_IP:-}" != "yes" ]]; then
            local mask="${ip##*/}"
            (( mask < 48 )) && {
                bl_error_envelope defend "IPv6 CIDR /$mask too broad (floor /48; set BL_DEFEND_FW_ALLOW_BROAD_IP=yes to override): $ip"
                return "$BL_EX_USAGE"
            }
        fi
        return "$BL_EX_OK"
    fi
    bl_error_envelope defend "malformed IP/CIDR: $ip"
    return "$BL_EX_USAGE"
}

_bl_defend_firewall_cdn_safelist_check() {
    # $1 = ip; returns 0 (allowed) if NOT a CDN; 68 (refused) if CDN match.
    local ip="$1"
    if _bl_defend_firewall_is_private_ip "$ip"; then
        return "$BL_EX_OK"
    fi
    local cache_dir="${BL_DEFEND_ASN_CACHE:-/var/cache/bl/asn}"
    local cache_file="$cache_dir/$ip.json"
    command mkdir -p "$cache_dir" 2>/dev/null || true   # best-effort; proceed even if uncached

    local asn=""
    if [[ -r "$cache_file" ]]; then
        # Cache freshness gate: 24h TTL.
        local age_s
        age_s=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || printf '0') ))   # stat may fail on race (file rotated); age=0 forces cache-bypass — safe
        if (( age_s < 86400 )); then
            asn=$(jq -r '.asn // empty' "$cache_file" 2>/dev/null)   # cache may be malformed; empty asn triggers whois fallback
        fi
    fi
    if [[ -z "$asn" ]] && command -v whois >/dev/null 2>&1; then
        # Real whois would be: whois "$ip" | grep -Ei '^(origin|origin-?as):' | ...
        # In test mode, $BL_DEFEND_ASN_CACHE is pre-populated by the fixture; whois shim is a no-op.
        asn=$(whois "$ip" 2>/dev/null | grep -iE '^(origin|origin-as):' | awk '{print $2}' | head -n1)   # whois network failure; empty asn → fail-open below
        if [[ -n "$asn" ]]; then
            printf '{"asn":"%s","cached_at":"%s"}' "$asn" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$cache_file" 2>/dev/null || true   # cache write best-effort; read-only cache dir non-fatal (fall-through to check)
        fi
    fi
    [[ -z "$asn" ]] && return "$BL_EX_OK"   # unknown ASN = allow (fail-open for unavailability)

    local cdn_asns="$_BL_DEFEND_CDN_ASNS ${BL_DEFEND_EXTRA_CDN_ASNS:-}"
    local a
    for a in $cdn_asns; do
        if [[ "$asn" == "$a" ]]; then
            bl_error_envelope defend "$ip belongs to CDN $asn; refused to block"
            return "$BL_EX_TIER_GATE_DENIED"
        fi
    done
    return "$BL_EX_OK"
}

_bl_defend_firewall_apply() {
    # $1=backend $2=ip $3=case-id $4=reason
    local backend="$1" ip="$2" case_id="$3" reason="$4"
    local tag="bl-${case_id}:${reason}"
    case "$backend" in
        apf)       apf -d "$ip" -c "$tag" ;;
        csf)       csf -d "$ip" "$tag" ;;
        nft)       nft add rule inet filter input ip saddr "$ip" drop comment "\"$tag\"" ;;
        iptables)  iptables -I INPUT -s "$ip" -j DROP -m comment --comment "$tag" ;;
        *)         bl_error_envelope defend "unsupported backend: $backend"; return "$BL_EX_USAGE" ;;
    esac
}

bl_defend_firewall() {
    # bl_defend_firewall <ip> [--backend auto|apf|csf|nft|iptables]
    #                        [--case <id>] [--reason <str>] [--retire <duration>]
    local ip="" backend="auto" case_override="" reason="agent-payload" retire="30d"
    while (( $# > 0 )); do
        case "$1" in
            --backend)  backend="$2"; shift 2 ;;
            --case)     case_override="$2"; shift 2 ;;
            --reason)   reason="$2"; shift 2 ;;
            --retire)   retire="$2"; shift 2 ;;
            -*)         bl_error_envelope defend "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)          ip="$1"; shift ;;
        esac
    done
    [[ -z "$ip" ]] && { bl_error_envelope defend "missing <ip>"; return "$BL_EX_USAGE"; }
    _bl_defend_firewall_validate_ip "$ip" || return "$BL_EX_USAGE"
    # Reason format guard — value lands in nft `comment "<tag>"` and iptables
    # `--comment "<tag>"`. Quoted shell-side, but firewall tokenizers see the
    # raw string. Embedded `"` or newlines break nft parse; comment parsers
    # downstream extract case-tag via regex (bl_observe_firewall) and lose
    # correlation on metacharacter-rich reasons.
    if ! [[ "$reason" =~ ^[A-Za-z0-9._:[:space:]-]{0,128}$ ]]; then
        bl_error_envelope defend "--reason invalid (allowed: [A-Za-z0-9._:-] + space, max 128): $reason"
        return "$BL_EX_USAGE"
    fi

    local case_id="$case_override"
    [[ -z "$case_id" ]] && case_id=$(bl_case_current)
    [[ -z "$case_id" ]] && case_id="CASE-0000-0000"

    bl_init_workdir || return $?

    if [[ "$backend" == "auto" ]]; then
        backend=$(_bl_defend_firewall_detect_backend) || return $?
    fi

    # CDN safe-list check BEFORE apply: refusal is not an "applied action",
    # so it does NOT write to ledger as defend_applied. It writes defend_refused.
    local safelist_rc=0
    _bl_defend_firewall_cdn_safelist_check "$ip" || safelist_rc=$?
    if (( safelist_rc != 0 )); then
        # shellcheck disable=SC2016  # $i is a jq --arg variable name, not a shell variable
        _bl_defend_ledger_emit "$case_id" "defend_refused" \
            '{verb:"defend.firewall", ip:$i, reason:"cdn_safelist"}' \
            --arg i "$ip"
        return "$BL_EX_TIER_GATE_DENIED"
    fi

    if ! _bl_defend_firewall_apply "$backend" "$ip" "$case_id" "$reason"; then
        # shellcheck disable=SC2016  # $i,$b are jq --arg variable names, not shell variables
        _bl_defend_ledger_emit "$case_id" "defend_rollback" \
            '{verb:"defend.firewall", ip:$i, backend:$b, reason:"backend_apply_fail"}' \
            --arg i "$ip" --arg b "$backend"
        bl_error_envelope defend "$backend apply failed for $ip"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    # shellcheck disable=SC2016  # $i,$b,$r,$re are jq --arg variable names, not shell variables
    _bl_defend_ledger_emit "$case_id" "defend_applied" \
        '{verb:"defend.firewall", ip:$i, backend:$b, result:"ok", retire_hint:$r, reason:$re}' \
        --arg i "$ip" --arg b "$backend" --arg r "$retire" --arg re "$reason"

    printf 'bl-defend-firewall: blocked %s via %s (retire: %s)\n' "$ip" "$backend" "$retire" >&2
    return "$BL_EX_OK"
}

# ---- sig ------------------------------------------------------------------

_bl_defend_sig_detect_scanners() {
    # Prints space-separated list of detected scanners (lmd clamav yara).
    local found=""
    [[ -x /usr/local/maldetect/maldet ]] && found="$found lmd"
    command -v clamscan >/dev/null 2>&1 && found="$found clamav"
    command -v yara >/dev/null 2>&1 && found="$found yara"
    printf '%s' "${found# }"
}

_bl_defend_sig_scanner_file() {
    # $1 = scanner name; prints absolute path to append target.
    case "$1" in
        lmd)    printf '%s/custom.hdb' "${BL_LMD_SIG_DIR:-/usr/local/maldetect/sigs}" ;;
        clamav) printf '%s/custom.ndb' "${BL_CLAMAV_SIG_DIR:-/var/lib/clamav}" ;;
        yara)   printf '%s/custom.yar' "${BL_YARA_RULES_DIR:-/etc/yara/rules}" ;;
    esac
}

_bl_defend_sig_fp_gate() {
    # $1 = sig-file; $2 = scanner (lmd|clamav|yara). Scans $BL_DEFEND_FP_CORPUS
    # (or /var/lib/bl/fp-corpus) for matches. Returns 0 if clean (0 FP),
    # 68 if FP hit, 65 on error.
    local sig_file="$1" scanner="$2"
    local corpus="${BL_DEFEND_FP_CORPUS:-/var/lib/bl/fp-corpus}"
    if [[ ! -d "$corpus" ]]; then
        bl_warn "FP-corpus directory missing: $corpus; gate bypassed"
        return "$BL_EX_OK"
    fi

    case "$scanner" in
        lmd)
            # LMD hdb format: <md5>:<size>:<name>. Compare md5/size of each
            # sig line against every corpus file. The `|| [[ -n "$md5" ]]`
            # tail-catch is SECURITY-LOAD-BEARING: without it a sig file
            # lacking a trailing newline bypasses the FP-gate entirely
            # (bash `read` returns non-zero on EOF-without-newline, so the
            # while body never executes for a single unterminated line).
            #
            # Performance: hash + stat the corpus once into associative arrays,
            # then sigs become O(1) lookups against the cache (audit M5: was
            # O(N_sigs × N_corpus) re-hashing per pair, ≥30s on 100×200 corpus).
            local -A f_md5_cache f_size_cache
            local f
            for f in "$corpus"/*; do
                [[ -f "$f" ]] || continue
                local _md5 _size
                _md5=$(command md5sum "$f" | command awk '{print $1}')
                _size=$(command stat -c %s "$f")
                f_md5_cache["$f"]="$_md5"
                f_size_cache["$f"]="$_size"
            done
            local md5 size
            while IFS=: read -r md5 size _ || [[ -n "$md5" ]]; do
                [[ -z "$md5" || "$md5" =~ ^# ]] && continue
                for f in "${!f_md5_cache[@]}"; do
                    if [[ "${f_md5_cache[$f]}" == "$md5" && "${f_size_cache[$f]}" == "$size" ]]; then
                        bl_warn "FP-gate hit: $f matches sig $md5:$size"
                        return "$BL_EX_TIER_GATE_DENIED"
                    fi
                done
            done < "$sig_file"
            ;;
        clamav)
            # ClamAV ndb scan against corpus: clamscan --database=<sig> <corpus>
            # Exit 0 = clean → pass; 1 = virus found (FP!) → reject; 2+ = error.
            # rc capture must precede the conditional — `if cmd; then ...; fi; rc=$?`
            # captures the if-statement's own exit (always 0 with no else branch),
            # not clamscan's status (audit M1).
            local rc=0
            command clamscan --database="$sig_file" --infected --no-summary "$corpus"/* >/dev/null 2>&1 || rc=$?
            case "$rc" in
                0)
                    return "$BL_EX_OK"
                    ;;
                1)
                    bl_warn "FP-gate hit: clamscan matched sig against FP-corpus"
                    return "$BL_EX_TIER_GATE_DENIED"
                    ;;
                *)
                    bl_warn "clamscan FP-gate error (rc=$rc); failing closed"
                    return "$BL_EX_PREFLIGHT_FAIL"
                    ;;
            esac
            ;;
        yara)
            if yara --no-warnings "$sig_file" "$corpus" 2>/dev/null | grep -q .; then   # --no-warnings (-w) is portable across yara 4.2.3 (debian12, lacks -q) and 4.5.2 (rocky9); 2>/dev/null silences per-file parse noise on mixed corpora — rule parse errors fall through to fail-closed below
                bl_warn "FP-gate hit: yara matched sig against FP-corpus"
                return "$BL_EX_TIER_GATE_DENIED"
            fi
            ;;
    esac
    return "$BL_EX_OK"
}

_bl_defend_sig_reload() {
    # $1 = scanner; best-effort reload. Failure is logged, not fatal.
    case "$1" in
        lmd)    : ;;   # LMD reads signatures on next scan invocation; no reload needed
        clamav)
            if command -v clamdscan >/dev/null 2>&1; then
                clamdscan --reload >/dev/null 2>&1 || \
                    bl_debug "clamdscan --reload failed or daemon not running (non-fatal)"   # reload failure is explicitly non-fatal; bl_debug logged for diagnostics only
            fi
            ;;
        yara)   : ;;   # YARA: rules re-compiled per-scan; no daemon reload
    esac
    return "$BL_EX_OK"
}

bl_defend_sig() {
    # bl_defend_sig <sig-file> [--scanner lmd|clamav|yara|all]
    local sig_file="" scanner="auto"
    while (( $# > 0 )); do
        case "$1" in
            --scanner)  scanner="$2"; shift 2 ;;
            -*)         bl_error_envelope defend "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)          sig_file="$1"; shift ;;
        esac
    done
    [[ -z "$sig_file" ]] && { bl_error_envelope defend "missing <sig-file>"; return "$BL_EX_USAGE"; }
    [[ ! -r "$sig_file" ]] && { bl_error_envelope defend "sig file not readable: $sig_file"; return "$BL_EX_NOT_FOUND"; }

    local case_id
    case_id=$(bl_case_current)
    [[ -z "$case_id" ]] && case_id="CASE-0000-0000"

    bl_init_workdir || return $?

    local scanners
    if [[ "$scanner" == "auto" || "$scanner" == "all" ]]; then
        scanners=$(_bl_defend_sig_detect_scanners)
    else
        scanners="$scanner"
    fi
    if [[ -z "$scanners" ]]; then
        bl_error_envelope defend "no scanners detected (lmd|clamav|yara)"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    local s gate_rc=0 append_count=0
    for s in $scanners; do
        gate_rc=0
        _bl_defend_sig_fp_gate "$sig_file" "$s" || gate_rc=$?
        if (( gate_rc != 0 )); then
            # shellcheck disable=SC2016  # $f,$s are jq --arg variable names, not shell variables
            _bl_defend_ledger_emit "$case_id" "defend_sig_rejected" \
                '{verb:"defend.sig", sig_file:$f, scanner:$s, reason:"fp_gate_trip"}' \
                --arg f "$sig_file" --arg s "$s"
            bl_error_envelope defend "FP-gate tripped for $s; not appending"
            # If --scanner was explicit-single, exit rejected. If auto/all, continue.
            [[ "$scanner" != "auto" && "$scanner" != "all" ]] && return "$BL_EX_TIER_GATE_DENIED"
            continue
        fi
        local target
        target=$(_bl_defend_sig_scanner_file "$s")
        command mkdir -p "$(dirname "$target")" 2>/dev/null || true   # scanner sig dir may be root-owned or read-only in tests
        command cat "$sig_file" >> "$target" || {
            # shellcheck disable=SC2016  # $f,$s are jq --arg variable names, not shell variables
            _bl_defend_ledger_emit "$case_id" "defend_rollback" \
                '{verb:"defend.sig", sig_file:$f, scanner:$s, reason:"append_failed"}' \
                --arg f "$sig_file" --arg s "$s"
            bl_error_envelope defend "append to $target failed"
            [[ "$scanner" != "auto" && "$scanner" != "all" ]] && return "$BL_EX_PREFLIGHT_FAIL"
            continue
        }
        _bl_defend_sig_reload "$s"
        # shellcheck disable=SC2016  # $f,$s,$t are jq --arg variable names, not shell variables
        _bl_defend_ledger_emit "$case_id" "defend_applied" \
            '{verb:"defend.sig", sig_file:$f, scanner:$s, target:$t, result:"ok", retire_hint:"30d"}' \
            --arg f "$sig_file" --arg s "$s" --arg t "$target"
        append_count=$((append_count + 1))
    done

    if (( append_count == 0 )); then
        bl_error_envelope defend "no scanners accepted sig (all FP-gate tripped or append-failed)"
        return "$BL_EX_TIER_GATE_DENIED"
    fi
    printf 'bl-defend-sig: appended to %d scanner(s)\n' "$append_count" >&2
    return "$BL_EX_OK"
}
