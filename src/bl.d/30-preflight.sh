# shellcheck shell=bash
bl_preflight() {
    # 1. API key
    if [[ -z "${ANTHROPIC_API_KEY+set}" ]]; then
        bl_error_envelope preflight "ANTHROPIC_API_KEY not set"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    if [[ -z "$ANTHROPIC_API_KEY" ]]; then
        bl_error_envelope preflight "ANTHROPIC_API_KEY empty"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    # 2. Required tools
    if ! command -v curl >/dev/null 2>&1; then   # curl is load-bearing
        bl_error_envelope preflight "curl not found (required for API calls)"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    if ! command -v jq >/dev/null 2>&1; then   # jq is load-bearing for response parsing
        bl_error_envelope preflight "jq not found (required for JSON parsing)"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    # 3. state/ dir — directly, NOT via bl_init_workdir
    if ! command mkdir -p "$BL_STATE_DIR" 2>/dev/null; then   # RO filesystem / perms
        bl_error_envelope preflight "$BL_VAR_DIR not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    # 4. Seed BL_MEMSTORE_CASE_ID from state.json if not already set.
    # Old per-key file (memstore-case-id) was removed in M15 state.json migration.
    if [[ -z "${BL_MEMSTORE_CASE_ID:-}" ]]; then
        BL_MEMSTORE_CASE_ID=$(jq -r '.case_memstores._default // empty' "$BL_STATE_DIR/state.json" 2>/dev/null || printf '')   # 2>/dev/null: missing state.json on first-run is normal; empty → per-verb checks handle
        bl_debug "bl_preflight: BL_MEMSTORE_CASE_ID=$BL_MEMSTORE_CASE_ID"
    fi

    # 5. Cached agent-id?
    if [[ -r "$BL_AGENT_ID_FILE" ]]; then
        BL_AGENT_ID="$(command cat "$BL_AGENT_ID_FILE")"
        if [[ -n "$BL_AGENT_ID" ]]; then
            bl_debug "bl_preflight: using cached agent-id $BL_AGENT_ID"
            return "$BL_EX_OK"
        fi
        bl_debug "bl_preflight: cached agent-id empty, re-probing"
    fi

    # 5. Probe GET /v1/agents — list all; filter client-side (?name= not supported)
    local resp
    resp=$(bl_api_call GET "/v1/agents") || return $?
    BL_AGENT_ID="$(printf '%s\n' "$resp" | jq -r '
        (.data[] | select(.name == "bl-curator") | .id)? // empty' | head -1)"
    if [[ -z "$BL_AGENT_ID" ]]; then
        BL_AGENT_ID="$(printf '%s\n' "$resp" | jq -r '
            (.data[] | select(.name | startswith("blacklight-curator")) | .id)? // empty' | head -1)"
    fi

    if [[ -z "$BL_AGENT_ID" ]]; then
        command cat >&2 <<'BOOTSTRAP_EOF'
blacklight: this Anthropic workspace has not been seeded.

Run one of the following (one-time per workspace):

  # Local clone:
  bl setup

  # Direct from OSS repo:
  curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/bl | bash -s setup

After setup completes the first host's worth of provisioning,
every subsequent host running 'bl' against the same API key
finds the workspace pre-seeded and skips this step.
BOOTSTRAP_EOF
        return "$BL_EX_WORKSPACE_NOT_SEEDED"
    fi

    printf '%s' "$BL_AGENT_ID" > "$BL_AGENT_ID_FILE"
    bl_debug "bl_preflight: seeded agent-id $BL_AGENT_ID cached to $BL_AGENT_ID_FILE"
    # M12 P3: age-gated outbox drain (idempotent; only fires when entries are stale).
    # Without the age gate, every preflight drains — entries enqueued seconds ago
    # consume work on every subsequent CLI invocation. Gate via bl_outbox_should_drain
    # (returns 0 iff non-empty AND oldest age ≥ BL_OUTBOX_AGE_WARN_SECS = 3600s).
    # Soft-fail: rc=69 (no session yet) is normal mid-provision; do not 66-exit.
    if bl_outbox_should_drain 2>/dev/null; then   # 2>/dev/null: predicate failures (EACCES on outbox dir) → skip drain, do not block preflight
        bl_info "preflight: outbox has aged entries — draining"
        bl_outbox_drain --max "$BL_OUTBOX_DRAIN_DEFAULT_MAX" --deadline "$BL_OUTBOX_DRAIN_DEFAULT_DEADLINE_SECS" >/dev/null 2>&1 || bl_warn "outbox drain returned $? — entries remain queued for next preflight"   # 2>/dev/null: drain emits per-entry chatter that pollutes preflight — only the rc matters here
    fi

    # 6. Operator config tree (M14): load allowlisted keys + register notify channels
    _bl_load_blacklight_conf || true   # || true: malformed conf logs + falls back to defaults; never blocks preflight
    _bl_notify_register_channels || bl_warn "preflight: notify channel registration returned non-zero (proceeding)"

    return "$BL_EX_OK"
}

# ----------------------------------------------------------------------------
# M14: operator config tree at /etc/blacklight/blacklight.conf
# ----------------------------------------------------------------------------

# _bl_load_blacklight_conf — parse allowlisted shell-source-able conf, export
# BL_* env vars. Fail-soft: returns 0 even on parse fail (logs + skip).
# Allowlist (lowercase conf-key → BL_<UPPER> env var):
#   Core dispatch:    unattended_mode notify_channels_enabled notify_severity_floor
#                     notify_dir log_level disable_llm
#   LMD trigger:      lmd_trigger_dedup_window_hours lmd_conf_path
#   cPanel lock-in:   cpanel_lockin cpanel_lockin_timeout_seconds cpanel_dir
#   Defend tunables:  defend_extra_cdn_asns defend_fw_allow_broad_ip
#                     defend_fp_corpus defend_asn_cache
#   Clean tunables:   clean_dryrun_ttl_secs clean_proc_grace_secs
#   Observe tunables: obs_journal_max
#   Scanner sig dirs: lmd_sig_dir clamav_sig_dir yara_rules_dir
#   Skill source:     repo_url
# Env-only (cannot live in conf — bootstrap or runtime):
#   BL_VAR_DIR, BL_BLACKLIGHT_DIR, BL_BLACKLIGHT_CONF (chicken-and-egg with load order)
#   BL_HOST_LABEL (auto-detect), BL_INVOKED_BY, BL_UNATTENDED, BL_UNATTENDED_FLAG
_bl_load_blacklight_conf() {
    local conf="${BL_BLACKLIGHT_CONF:-/etc/blacklight/blacklight.conf}"
    [[ -r "$conf" ]] || return "$BL_EX_OK"   # absent conf is normal; defaults apply

    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip blank + comment lines
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Strip leading whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        # Match key="value" or key='value' or key=value
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # Strip surrounding quotes
            value="${value%\"}"; value="${value#\"}"
            value="${value%\'}"; value="${value#\'}"
            # Allowlist key
            case "$key" in
                unattended_mode|notify_channels_enabled|notify_severity_floor|notify_dir|log_level|disable_llm) ;;
                lmd_trigger_dedup_window_hours|lmd_conf_path) ;;
                cpanel_lockin|cpanel_lockin_timeout_seconds|cpanel_dir) ;;
                defend_extra_cdn_asns|defend_fw_allow_broad_ip|defend_fp_corpus|defend_asn_cache) ;;
                clean_dryrun_ttl_secs|clean_proc_grace_secs) ;;
                obs_journal_max) ;;
                lmd_sig_dir|clamav_sig_dir|yara_rules_dir) ;;
                repo_url) ;;
                *)
                    bl_warn "blacklight.conf: unknown key '$key' (line: $line)"
                    continue
                    ;;
            esac
            # Reject metacharacters
            if [[ "$value" =~ [\;\|\&\$\(\)\{\}\`\<\>] ]]; then
                bl_warn "blacklight.conf: $key value rejected (metacharacter): $value"
                continue
            fi
            # Export as BL_<KEY-UPPERCASE>
            local upper
            upper=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
            export "BL_${upper}=$value"
        else
            bl_warn "blacklight.conf: malformed line (skipped): $line"
        fi
    done < "$conf"

    # Map known keys to runtime BL_* names that other parts read
    [[ -n "${BL_NOTIFY_SEVERITY_FLOOR:-}" ]] || \
        export BL_NOTIFY_SEVERITY_FLOOR="${BL_NOTIFY_SEVERITY_FLOOR:-info}"
    [[ -n "${BL_LMD_TRIGGER_DEDUP_WINDOW_HOURS:-}" ]] || \
        export BL_LMD_TRIGGER_DEDUP_WINDOW_HOURS="24"

    return "$BL_EX_OK"
}

# bl_is_unattended — resolution chain (most-explicit-wins):
# 1. --unattended CLI flag (caller sets BL_UNATTENDED_FLAG=1 before calling)
# 2. BL_UNATTENDED env (=1 forces unattended; =0 forces attended, suppressing auto-detect)
# 3. /etc/blacklight/blacklight.conf unattended_mode="1" (exported as BL_UNATTENDED_MODE)
# 4. BL_INVOKED_BY non-empty (lmd-hook, cron, future hooks)
# 5. No controlling TTY on stdin AND stdout (auto-detect — overridden by explicit BL_UNATTENDED=0)
# Returns 0 if any layer fires; 1 otherwise.
bl_is_unattended() {
    [[ "${BL_UNATTENDED_FLAG:-}" == "1" ]] && return 0
    [[ "${BL_UNATTENDED:-}" == "1" ]] && return 0
    [[ "${BL_UNATTENDED_MODE:-}" == "1" ]] && return 0
    [[ -n "${BL_INVOKED_BY:-}" ]] && return 0
    [[ "${BL_UNATTENDED:-}" == "0" ]] && return 1   # explicit attended override before TTY auto-detect
    if [[ ! -t 0 ]] && [[ ! -t 1 ]]; then
        return 0
    fi
    return 1
}

# ----------------------------------------------------------------------------
# Usage / version surfaces — bypass preflight (help should work unseeded)
# ----------------------------------------------------------------------------

bl_usage() {
    command cat <<'USAGE_EOF'
bl — blacklight operator CLI

Usage: bl <command> [options]
       bl <command> --help      per-verb help

Commands:
  observe   Read-only evidence extraction (logs/fs/crons/htaccess/substrate)
  consult   Open / attach an investigation case via the curator agent
  run       Execute an agent-prescribed step (tier-gated)
  defend    Apply a defensive payload (modsec / firewall / signature)
  clean     Apply remediation (diff-confirmed; quarantine preserved)
  case      Inspect / log / close / reopen cases
  setup     Provision or sync the Anthropic workspace
  trigger   Open a case from a hook-fired event source (LMD post_scan_hook)
  flush     Drain queued outbox records

Options:
  -h, --help       show this message
  -v, --version    show bl version

Environment:
  ANTHROPIC_API_KEY  (required)  your Anthropic workspace API key
  BL_LOG_LEVEL       (optional)  one of {debug,info,warn,error}
  BL_REPO_URL        (optional)  alternate git repo for skill content

Exit codes: docs/exit-codes.md
Design spec: DESIGN.md
USAGE_EOF
}

bl_version() {
    printf 'bl %s\n' "$BL_VERSION"
}

# ----------------------------------------------------------------------------
# Per-verb help surfaces — bypass preflight (help should work unseeded).
# Called from main() when the second argument is --help / -h / help.
# ----------------------------------------------------------------------------

bl_help_observe() {
    command cat <<'HELP_EOF'
bl observe — read-only evidence extraction into the case bundle.

Usage: bl observe <verb> [options]

Verbs:
  apache     collect access_log / error_log / modsec2 audit windows
  fs         enumerate mtime-clustered paths under a root
  crons      snapshot crontabs (system + user) with diff vs baseline
  htaccess   walk .htaccess trees under a web root
  bundle     assemble all collected artifacts into a single case bundle

Options:
  --case <id>        case id (default: current case from /var/lib/bl/state)
  --from / --to      time window for log collectors (ISO 8601)
  --root <path>      root for fs/htaccess walkers
  --json             emit JSONL summary instead of human log lines

Exit codes: docs/exit-codes.md
HELP_EOF
}

bl_help_consult() {
    command cat <<'HELP_EOF'
bl consult — open or attach to an investigation case with the curator agent.

Usage: bl consult "<case description>" [--case <id>]
       bl consult --attach <id>

Posts the current case bundle (observed artifacts, prior ledger entries)
to the bl-curator Managed Agent and receives an action-tier recommendation.

See DESIGN.md §5.
HELP_EOF
}

bl_help_run() {
    command cat <<'HELP_EOF'
bl run — execute an agent-prescribed step (tier-gated).

Usage: bl run [--yes] [--tier <auto|suggested|destructive>]

Pulls the next pending step from the curator, validates against action-
tiers.md policy, prompts for confirmation (unless --yes and tier permits),
executes, appends ledger + memstore entries.

Tier policy: docs/action-tiers.md
HELP_EOF
}

bl_help_defend() {
    command cat <<'HELP_EOF'
bl defend — apply an agent-authored defensive payload.

Usage: bl defend <backend> <subcommand> [options]

Backends:
  modsec      ModSecurity rule apply / --remove / rollback
  firewall    iptables / nftables add / remove (CDN-safelist aware)
  sig         ClamAV / LMD signature append (FP-corpus gated)

All subcommands emit ledger events to /var/lib/bl/ledger and are
safe to roll back via 'bl defend <backend> --rollback <event-id>'.
HELP_EOF
}

bl_help_clean() {
    command cat <<'HELP_EOF'
bl clean — apply agent-prescribed remediation (diff-confirmed).

Usage: bl clean <kind> [options]
       bl clean --undo <backup-id>
       bl clean --unquarantine <entry-id>

Kinds:
  file          unlink file (diff pre-shown, quarantine preserved)
  htaccess      revert .htaccess to clean template
  cron          remove injected crontab entry
  proc          SIGTERM + verify argv match

Options:
  --undo <backup-id>       restore a previous clean operation from backup
  --unquarantine <entry-id>  restore a quarantined file to original path

All clean operations quarantine originals under /var/lib/bl/quarantine.
HELP_EOF
}

bl_help_case() {
    command cat <<'HELP_EOF'
bl case — inspect, log, close, reopen cases.

Usage: bl case <verb> [options]

Verbs:
  open <id>     open a new case
  list          list cases on this host
  log [<id>] [--audit]
                show ledger entries; --audit appends per-kind summary
                + decoded fence-wrapped wake entries from outbox
                (consumes bl_fence_kind for forensic review)
  show <id>     print case summary + ledger tail
  note "..."    append a manual note to the current case
  close <id>    mark case closed; persists memstore record
  reopen <id>   reopen a closed case
HELP_EOF
}

bl_help_setup() {
    command cat <<'HELP_EOF'
bl setup — provision or sync the Anthropic workspace.

Usage: bl setup [--sync | --reset | --gc | --eval | --check] [opts]

One-time per workspace: creates bl-curator agent, bl-curator-env
environment, bl-case memory store, uploads workspace corpora to the
Files API, and registers six routing Skills.

--sync [--dry-run]   delta-push routing Skills + workspace corpora; idempotent
--reset [--force]    tear down agent + Skills + workspace Files (destructive)
--gc                 purge files_pending_deletion when no live sessions reference
--eval [--promote]   run skill-routing eval-cases (BL_EVAL_LIVE=1 gated)
--check              print state.json snapshot + per-resource health

Spec: DESIGN.md §8 / docs/setup-flow.md.
HELP_EOF
}

bl_help_flush() {
    command cat <<'HELP_EOF'
bl flush — drain queued outbox records.

Usage: bl flush --outbox

Best-effort cron-driven drain of /var/lib/bl/outbox against the
curator's memory-store API. Safe to invoke manually.
HELP_EOF
}
