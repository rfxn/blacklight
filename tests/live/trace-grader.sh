#!/usr/bin/env bash
#
# tests/live/trace-grader.sh EVIDENCE_FILE — score the live-trace 6-point rubric.
# Pass threshold: >=5/6.
#
# Usage:
#   bash tests/live/trace-grader.sh <evidence-file>
#     or
#   EVIDENCE=path make live-trace-grade

set -euo pipefail

EVIDENCE="${1:-${EVIDENCE:-}}"
if [[ -z "$EVIDENCE" || ! -r "$EVIDENCE" ]]; then
    printf 'usage: trace-grader.sh <evidence-file>\n   or  EVIDENCE=path make live-trace-grade\n' >&2
    exit 64
fi

# Rubric state
declare -i pass=0 fail=0
declare -a results=()

# check label result — record a rubric point outcome
check() {
    local label="$1" result="$2"
    if [[ "$result" == "pass" ]]; then
        pass=$((pass+1))
        results+=("PASS $label")
    else
        fail=$((fail+1))
        results+=("FAIL $label")
    fi
}

# ── Rubric point 1 ────────────────────────────────────────────────────────────
# Hypothesis names the .cache/<x>.php polyglot pattern from the APSB25-94 corpus.
if /usr/bin/grep -qE '\.cache/[a-z0-9_]+\.php' "$EVIDENCE"; then
    check "Hypothesis names .cache/*.php polyglot pattern" pass
else
    check "Hypothesis names .cache/*.php polyglot pattern" fail
fi

# ── Rubric point 2 ────────────────────────────────────────────────────────────
# Cross-stream correlation: the same C2 IP (203.0.113.42) appears in both
# the apache section and the cron section of the evidence.
C2_IN_APACHE="$(/usr/bin/grep -cE 'apache.access.*203\.0\.113\.42' "$EVIDENCE" 2>/dev/null || /usr/bin/echo 0)" # grep -c exits 1 on no match; || echo 0 normalizes to count
C2_IN_CRON="$(/usr/bin/grep -cE 'cron.*203\.0\.113\.42' "$EVIDENCE" 2>/dev/null || /usr/bin/echo 0)"          # same; 2>/dev/null suppresses file-not-found on first access
if (( C2_IN_APACHE > 0 && C2_IN_CRON > 0 )); then
    check "C2 IP correlated across apache + cron" pass
else
    check "C2 IP correlated across apache + cron (apache=$C2_IN_APACHE cron=$C2_IN_CRON)" fail
fi

# ── Rubric point 3 ────────────────────────────────────────────────────────────
# Step tier distribution: curator must have emitted all three tiers so the
# harness covers the full safety-gate model.
AUTO="$(/usr/bin/grep -cE '\[auto' "$EVIDENCE" 2>/dev/null || /usr/bin/echo 0)"       # grep -c exits 1 on no match; || echo 0 normalizes to count
SUGG="$(/usr/bin/grep -cE '\[suggested' "$EVIDENCE" 2>/dev/null || /usr/bin/echo 0)"  # same
DEST="$(/usr/bin/grep -cE '\[destructive' "$EVIDENCE" 2>/dev/null || /usr/bin/echo 0)" # same
if (( AUTO > 0 && SUGG > 0 && DEST > 0 )); then
    check "Step tier distribution covers auto/suggested/destructive" pass
else
    check "Step tier distribution covers auto/suggested/destructive (auto=$AUTO sugg=$SUGG dest=$DEST)" fail
fi

# ── Rubric point 4 ────────────────────────────────────────────────────────────
# Sim-day-2 hypothesis (Scene 8) references at least one prior obs ID,
# proving the curator resumed from persisted memory rather than starting fresh.
if /usr/bin/grep -qE "Sim-day-2.*obs-[0-9]{4}" "$EVIDENCE" \
   || /usr/bin/grep -qE "Scene 8.*obs-[0-9]{4}" "$EVIDENCE"; then
    check "Sim-day-2 hypothesis cites prior obs IDs" pass
else
    check "Sim-day-2 hypothesis cites prior obs IDs" fail
fi

# ── Rubric point 5 ────────────────────────────────────────────────────────────
# Curator turn input must land in the 300k-500k token band, confirming the
# full corpus reached the 1M-context window.
TOKENS="$(/usr/bin/grep -oE 'input [0-9,]+ tok' "$EVIDENCE" | \
          /usr/bin/head -1 | \
          /usr/bin/tr -d ',' | \
          /usr/bin/awk '{print $2}')"
TOKENS="${TOKENS:-0}"
if (( TOKENS >= 300000 && TOKENS <= 500000 )); then
    check "Curator turn input in 300k-500k token band ($TOKENS)" pass
else
    check "Curator turn input in 300k-500k token band (saw $TOKENS; expect 300000-500000)" fail
fi

# ── Rubric point 6 ────────────────────────────────────────────────────────────
# Wall-clock for the hypothesis turn must be <= 90s, meeting demo pacing.
WALL="$(/usr/bin/grep -oE 'Wall-clock for hypothesis turn:.*[0-9]+s' "$EVIDENCE" | \
        /usr/bin/head -1 | \
        /usr/bin/grep -oE '[0-9]+' | \
        /usr/bin/head -1)"
WALL="${WALL:-0}"
if [[ -n "${WALL}" ]] && (( WALL > 0 && WALL <= 90 )); then
    check "Curator wall-clock <=90s ($WALL)" pass
else
    check "Curator wall-clock <=90s (saw ${WALL}s)" fail
fi

# ── Emit grade ───────────────────────────────────────────────────────────────
printf '\n=== live-trace grader ===\n'
for r in "${results[@]}"; do printf '  %s\n' "$r"; done
printf '\nResult: %d/6 pass\n' "$pass"

# Append rubric summary to the evidence file for committed record
{
    printf '\n\n## Grader rubric (%d/6 pass)\n\n' "$pass"
    for r in "${results[@]}"; do printf -- '- %s\n' "$r"; done
} >> "$EVIDENCE"

if (( pass >= 5 )); then
    printf '\nPASS — evidence: %s\n' "$EVIDENCE"
    exit 0
else
    printf '\nFAIL — see %s for details\n' "$EVIDENCE"
    exit 1
fi
