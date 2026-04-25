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

    # 4. Cached agent-id?
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
    return "$BL_EX_OK"
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

Usage: bl setup [--sync | --check]

One-time per workspace: creates bl-curator agent, bl-curator-env
environment, bl-skills + bl-case memory stores, seeds skills/.

--sync      delta-push skills/*.md against bl-skills memstore
--check     verify workspace state; no writes

Spec: DESIGN.md §8.
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
