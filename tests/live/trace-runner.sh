#!/usr/bin/env bash
#
# tests/live/trace-runner.sh — live-fire end-to-end harness against real Anthropic API.
# Runs the §End-to-end CLI demo scenario from PLAN-M12.md top to bottom,
# captures every API call, emits a committed evidence file.
#
# Usage:
#   make live-trace
#     or
#   bash tests/live/trace-runner.sh [--dry-run] [--no-secrets]
#
# Requires:
#   .secrets/env  (sources ANTHROPIC_API_KEY)
#   exhibits/fleet-01/large-corpus/  (Phase 2 corpus)
#   bl-curator agent provisioned (or harness will provision via bl setup)
#
# Cost: ~$5-15 per run. Cap: $50 (warn at $25, abort at $50).
# Wall-clock: ~3-5 minutes.
#
# --no-secrets skips sourcing .secrets/env; used in acceptance-test path to
# prove the harness aborts correctly when ANTHROPIC_API_KEY is absent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT" || { printf 'trace-runner: cannot cd to %s\n' "$REPO_ROOT" >&2; exit 1; }

# Parse flags
DRY_RUN=""
NO_SECRETS=""
while (( $# > 0 )); do
    case "$1" in
        --dry-run)    DRY_RUN=1; shift ;;
        --no-secrets) NO_SECRETS=1; shift ;;
        *) printf 'usage: %s [--dry-run] [--no-secrets]\n' "$0" >&2; exit 64 ;;
    esac
done

# Preflight: source secrets unless suppressed
if [[ -z "$NO_SECRETS" ]] && [[ -r .secrets/env ]]; then
    set -a; . .secrets/env; set +a
fi

# Preflight: gawk required for cost-cap arithmetic (3-arg match)
if ! command -v gawk >/dev/null 2>&1; then # gawk required; plain awk lacks 3-arg match()
    printf 'trace-runner: gawk not found — install gawk and retry\n' >&2
    exit 65
fi

# Preflight: API key required
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    printf 'trace-runner: ANTHROPIC_API_KEY not set (source .secrets/env first, or remove --no-secrets)\n' >&2
    exit 65
fi

if [[ -n "$DRY_RUN" ]]; then
    printf 'trace-runner: dry-run preflight OK (API key present, would proceed)\n'
    exit 0
fi

# Preflight: corpus required (Phase 2 must have run)
if [[ ! -d exhibits/fleet-01/large-corpus ]] || [[ ! -s exhibits/fleet-01/large-corpus/apache.access.log ]]; then
    printf 'trace-runner: exhibits/fleet-01/large-corpus/ missing or empty — run scripts/dev/synth-corpus.sh first\n' >&2
    exit 65
fi

# Cost-cap thresholds (overridable via env)
BL_LIVE_TRACE_COST_WARN_USD="${BL_LIVE_TRACE_COST_WARN_USD:-25}"
BL_LIVE_TRACE_COST_ABORT_USD="${BL_LIVE_TRACE_COST_ABORT_USD:-50}"

# Output paths
TS="$(/usr/bin/date -u +%Y%m%d-%H%M)"
EVIDENCE_DIR="tests/live/evidence"
EVIDENCE_FILE="$EVIDENCE_DIR/live-trace-$TS.md"
TRACE_LOG="$EVIDENCE_DIR/.trace-$TS.jsonl"
/usr/bin/mkdir -p "$EVIDENCE_DIR"

# Expose trace log path so bl_api_call can tee request+response bodies
export BL_CURL_TRACE_LOG="$TRACE_LOG"

# bl_check_cost_cap — sum input/output tokens × per-1M price from trace log.
# Uses gawk 3-arg match() to extract token counts. Warns at $25, aborts at $50.
bl_check_cost_cap() {
    [[ ! -r "$TRACE_LOG" ]] && return 0
    local cost
    cost=$(gawk '
        BEGIN { c=0 }
        /usage.*input_tokens/ {
            match($0, /input_tokens"?: *([0-9]+)/, ai); inp=ai[1]+0
            match($0, /output_tokens"?: *([0-9]+)/, ao); out=ao[1]+0
            c += inp * 15 / 1000000 + out * 75 / 1000000
        }
        END { printf "%.2f", c }' "$TRACE_LOG")
    if /usr/bin/awk -v c="$cost" -v abort="$BL_LIVE_TRACE_COST_ABORT_USD" \
            'BEGIN{exit !(c+0 >= abort+0)}'; then
        printf 'trace-runner: cost %s USD >= abort cap %s USD — aborting run\n' \
            "$cost" "$BL_LIVE_TRACE_COST_ABORT_USD" >&2
        exit 70
    fi
    if /usr/bin/awk -v c="$cost" -v warn="$BL_LIVE_TRACE_COST_WARN_USD" \
            'BEGIN{exit !(c+0 >= warn+0)}'; then
        printf 'trace-runner: cost %s USD >= warn cap %s USD — continuing (will abort at %s USD)\n' \
            "$cost" "$BL_LIVE_TRACE_COST_WARN_USD" "$BL_LIVE_TRACE_COST_ABORT_USD"
    fi
}

# Tee all stdout+stderr into the evidence file from this point forward
exec > >(tee -a "$EVIDENCE_FILE") 2>&1

printf '# blacklight live-trace — %s\n\n' "$TS"
printf '**Repo HEAD:** %s\n' "$(/usr/bin/git rev-parse HEAD)"
printf '**Corpus seed:** 42\n'
printf '**Trace log:** %s\n\n' "$TRACE_LOG"

# ── Scene 0 — Setup ──────────────────────────────────────────────────────────
printf '## Scene 0 — Setup\n\n```bash\n'
"$REPO_ROOT/bl" setup
printf '```\n\n'

# ── Scene 1 — Open case ──────────────────────────────────────────────────────
printf '## Scene 1 — Open case\n\n```bash\n'
"$REPO_ROOT/bl" consult --new \
    --trigger CVE-2025-31324 \
    --notes "APSB25-94 — Magento polyglot webshell suspected on magento-prod-01"
printf '```\n\n'

CASE_ID="$(/usr/bin/cat /var/lib/bl/state/case.current 2>/dev/null || /usr/bin/echo "CASE-2026-0001")" # 2>/dev/null: file absent on first run; fallback matches CASE-YYYY-NNNN format guard

# ── Scene 2 — Substrate handoff (mixed observe verbs against synthetic exhibit) ──
# Hermetic isolation: every observe verb here either accepts --root pointing at
# the synth corpus, or operates on an explicit file path. No verb in this scene
# reads system defaults (no /var/log, no /etc/cron.d, no /var/spool/cron) — the
# data fence is enforced by the verb selection itself, not by additional flags.
# bl observe apache/crons hardcode /var/log paths and CANNOT be safely run
# against the synth exhibit without a CLI-surface change (tracked as M12.5).
printf '## Scene 2 — Substrate handoff\n\n```bash\n'
"$REPO_ROOT/bl" observe fs --mtime-since --since 2026-01-01 --under "$REPO_ROOT/exhibits/fleet-01/large-corpus"
"$REPO_ROOT/bl" observe file "$REPO_ROOT/exhibits/fleet-01/large-corpus/apache.access.log"
"$REPO_ROOT/bl" observe file "$REPO_ROOT/exhibits/fleet-01/large-corpus/modsec_audit.log"
"$REPO_ROOT/bl" observe file "$REPO_ROOT/exhibits/fleet-01/large-corpus/cron.snapshot"
"$REPO_ROOT/bl" observe file "$REPO_ROOT/exhibits/fleet-01/large-corpus/journal/auth.log"
"$REPO_ROOT/bl" observe file "$REPO_ROOT/exhibits/fleet-01/large-corpus/proc.snapshot"
printf '```\n\n'

# ── Scene 3 — Wake curator (Opus 4.7 + 1M context, single turn) ─────────────
printf '## Scene 3 — Wake curator (Opus 4.7 + 1M context, single turn)\n\n```bash\n'
T0="$(/usr/bin/date +%s)"
"$REPO_ROOT/bl" consult --attach "$CASE_ID"
T1="$(/usr/bin/date +%s)"
printf '```\n\n**Wall-clock for hypothesis turn:** %ds\n\n' "$((T1-T0))"

# Poll for hypothesis (default 120s; override via BL_LIVE_TRACE_HYPO_TIMEOUT)
HYPO_TIMEOUT="${BL_LIVE_TRACE_HYPO_TIMEOUT:-120}"
HYPO_FOUND=0
for i in $(seq 1 "$HYPO_TIMEOUT"); do
    if "$REPO_ROOT/bl" case show "$CASE_ID" 2>/dev/null | /usr/bin/grep -q "HIGH\|MEDIUM"; then # 2>/dev/null: case state may not exist during poll warm-up; stderr is noisy but non-fatal
        HYPO_FOUND=1
        printf '**Hypothesis received after %ds polling**\n\n' "$i"
        break
    fi
    /usr/bin/sleep 1
done
if (( HYPO_FOUND == 0 )); then
    printf '**FAIL:** hypothesis not received within %ds\n\n' "$HYPO_TIMEOUT"
fi

# Scene 3 is the dominant-cost turn; check cap before proceeding
bl_check_cost_cap

# ── Scene 4 — Pending step queue (gated on Scene 3 producing a hypothesis) ───
# Steady-state path: Scene 3 returns a hypothesis, the curator has emitted
# steps to the memstore, and `bl run --list` displays the queue. If the
# Scene-3 polling window happens to close before the hypothesis lands, we
# label-skip Scene 4 rather than emit an empty queue. The pending-step
# surface is independently exercised by the 348-test BATS suite under
# fixture mock.
if (( HYPO_FOUND == 1 )); then
    printf '## Scene 4 — Pending step queue\n\n```bash\n'
    "$REPO_ROOT/bl" run --list || true # non-fatal in trace; lists pending steps without execution. Auto-tier resolution is the wrapper default for `bl run <step-id>` per src/bl.d/60-run.sh:bl_run_evaluate_tier.
    printf '```\n\n'
else
    printf '## Scene 4 — Pending step queue (deferred)\n\n'
    printf '> Scene 3 polling window closed before a hypothesis surfaced; pending-step queue is gated on the curator emit. Re-run with a longer polling window (`BL_LIVE_TRACE_HYPO_TIMEOUT=240 make live-trace`) or inspect the fixture-mock coverage in `tests/05-consult-run-case.bats` and `tests/06-tier-resolve.bats` for the surface.\n\n'
fi

# ── Scenes 5-6 — Suggested + destructive (operator-confirm required; skipped) ─
printf '## Scene 5-6 — Suggested + destructive (skipped in live-trace; acknowledged)\n\n'
printf 'Tier-gated suggested + destructive steps require operator confirm; '
printf 'harness skips to avoid auto-applying defenses to the synthetic exhibit.\n\n'

# ── Scene 7 — Case state ──────────────────────────────────────────────────────
printf '## Scene 7 — Case state\n\n```bash\n'
"$REPO_ROOT/bl" case show "$CASE_ID"
printf '```\n\n'

# ── Scene 8 — Sim-day-2 (Managed Agents persistence proof) ───────────────────
printf '## Scene 8 — Sim-day-2 (Managed Agents persistence)\n\n'
SIMDAY_PAUSE="${BL_LIVE_TRACE_SIMDAY_PAUSE:-30}"
printf 'Sleeping %ds to simulate elapsed time...\n\n' "$SIMDAY_PAUSE"
/usr/bin/sleep "$SIMDAY_PAUSE"

printf '```bash\n'
"$REPO_ROOT/bl" consult --attach "$CASE_ID"
printf '```\n\n'

# Final cost check after sim-day-2 turn
bl_check_cost_cap

# ── Trace summary ─────────────────────────────────────────────────────────────
TOTAL_REQUESTS="$(/usr/bin/wc -l < "$TRACE_LOG" 2>/dev/null || /usr/bin/echo 0)" # trace log absent if no API calls were made (dry-run path); default to 0
printf '## Trace summary\n\n'
printf '%s\n' "- Total API requests: $TOTAL_REQUESTS"   # leading '-' in fmt-string trips 'invalid option' on some printf builtins; build the line as an arg, format is bare '%s\n'
printf '%s\n' "- Trace log: \`$TRACE_LOG\`"
printf '%s\n\n' "- Evidence file: \`$EVIDENCE_FILE\`"

printf 'Run grader: `make live-trace-grade EVIDENCE=%s`\n' "$EVIDENCE_FILE"
