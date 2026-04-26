#!/usr/bin/env bats
# tests/skill-routing/eval-runner.bats — M13 P11: live promotion eval gate.
#
# Orchestrates 50 case fixtures (30 mainline / 15 distractor / 5 ambiguous)
# against the live Anthropic Sessions API via bl_setup_eval.
#
# GATING: BL_EVAL_LIVE=1 required to exercise live paths.
# Default CI behaviour (BL_EVAL_LIVE unset): every test skips cleanly → exit 0.
#
# Metrics output: the final test writes a JSON report to $BL_EVAL_REPORT_FILE.
# bl_setup_eval reads this file after bats exits.
#
# Promotion bar (spec §11 G11):
#   per-Skill precision    ≥ 0.85
#   cross-Skill recall     ≥ 0.75
#   distractor specificity ≥ 0.95
#
# Portability: works locally (CWD = repo root) and in Docker container (CWD = /opt).
# BATS_REPO_ROOT resolver in setup() handles both contexts.
#
# Running the opt-in eval:
#   BL_EVAL_LIVE=1 ANTHROPIC_API_KEY=... make -C tests test-skill-routing-eval
#   BL_EVAL_LIVE=1 ANTHROPIC_API_KEY=... bats tests/skill-routing/eval-runner.bats
# Targeted subset (one Skill):
#   BL_EVAL_LIVE=1 BL_EVAL_FILTER=synthesizing-evidence bats tests/skill-routing/eval-runner.bats

# ---------------------------------------------------------------------------
# Global skip guard — checked in every test body (BATS setup() skip is 1.13+)
# ---------------------------------------------------------------------------

EVAL_SKIP_MSG="BL_EVAL_LIVE=1 required (live API)"

_eval_skip_unless_live() {
    [[ -n "${BL_EVAL_LIVE:-}" ]] || skip "$EVAL_SKIP_MSG"
}

# ---------------------------------------------------------------------------
# Setup — resolve repo root, set scratch dir for running tallies
# ---------------------------------------------------------------------------

setup() {
    if [[ -d /opt/routing-skills && -d /opt/skills-corpus ]]; then
        BATS_REPO_ROOT="/opt"
    else
        BATS_REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    fi
    export BATS_REPO_ROOT

    EVAL_CASES_DIR="$BATS_REPO_ROOT/tests/skill-routing/eval-cases"
    export EVAL_CASES_DIR

    # Scratch dir persists across tests within this run — use a stable tmpdir
    # keyed to the bats suite PID so parallel runs don't collide.
    EVAL_METRICS_DIR="${BATS_RUN_TMPDIR:-/tmp/bats-eval-$$}/metrics"
    mkdir -p "$EVAL_METRICS_DIR"
    export EVAL_METRICS_DIR

    VALID_SKILLS=(
        "synthesizing-evidence"
        "prescribing-defensive-payloads"
        "curating-cases"
        "gating-false-positives"
        "extracting-iocs"
        "authoring-incident-briefs"
    )
    export VALID_SKILLS
}

# ---------------------------------------------------------------------------
# Test 1 — fixture count (structural; runs in both live and non-live mode)
# ---------------------------------------------------------------------------

@test "eval-runner finds all 50 fixtures" {
    local total
    total=$(find "$EVAL_CASES_DIR" -name '*.json' | wc -l)
    [[ "$total" -eq 50 ]] || {
        echo "expected 50 fixtures, found $total" >&3
        echo "  mainline: $(find "$EVAL_CASES_DIR/mainline" -name '*.json' | wc -l)" >&3
        echo "  distractor: $(find "$EVAL_CASES_DIR/distractor" -name '*.json' | wc -l)" >&3
        echo "  ambiguous: $(find "$EVAL_CASES_DIR/ambiguous" -name '*.json' | wc -l)" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# Test 2 — mainline schema validation (structural)
# ---------------------------------------------------------------------------

@test "every mainline fixture has expected_skill matching one of 6 routing Skills" {
    local f skill matched
    for f in "$EVAL_CASES_DIR/mainline"/*.json; do
        skill=$(jq -r '.expected_skill // empty' "$f")
        [[ -n "$skill" ]] || {
            echo "FAIL: $f missing expected_skill" >&3
            return 1
        }
        matched=0
        local s
        for s in "${VALID_SKILLS[@]}"; do
            [[ "$skill" == "$s" ]] && { matched=1; break; }
        done
        [[ "$matched" -eq 1 ]] || {
            echo "FAIL: $f expected_skill '$skill' is not one of the 6 routing Skills" >&3
            return 1
        }
    done
}

# ---------------------------------------------------------------------------
# Test 3 — distractor schema validation (structural)
# ---------------------------------------------------------------------------

@test "every distractor fixture has expected_no_skill matching one of 6 routing Skills" {
    local f skill matched
    for f in "$EVAL_CASES_DIR/distractor"/*.json; do
        skill=$(jq -r '.expected_no_skill // empty' "$f")
        [[ -n "$skill" ]] || {
            echo "FAIL: $f missing expected_no_skill" >&3
            return 1
        }
        matched=0
        local s
        for s in "${VALID_SKILLS[@]}"; do
            [[ "$skill" == "$s" ]] && { matched=1; break; }
        done
        [[ "$matched" -eq 1 ]] || {
            echo "FAIL: $f expected_no_skill '$skill' is not one of the 6 routing Skills" >&3
            return 1
        }
    done
}

# ---------------------------------------------------------------------------
# Test 4 — ambiguous schema validation (structural)
# ---------------------------------------------------------------------------

@test "every ambiguous fixture has candidate_skills array with 2 entries" {
    local f count
    for f in "$EVAL_CASES_DIR/ambiguous"/*.json; do
        count=$(jq -r '.candidate_skills | length' "$f" 2>/dev/null || echo 0)
        [[ "$count" -ge 2 ]] || {
            echo "FAIL: $f has $count candidate_skills (need ≥2)" >&3
            return 1
        }
    done
}

# ---------------------------------------------------------------------------
# Test 5 — ANTHROPIC_API_KEY gate (live path prerequisite)
# ---------------------------------------------------------------------------

@test "ANTHROPIC_API_KEY required for live runner" {
    _eval_skip_unless_live
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] || {
        echo "ANTHROPIC_API_KEY is not set — cannot run live eval" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# Test 6 — live: synthesizing-evidence mainline fixtures
# ---------------------------------------------------------------------------

@test "live: synthesizing-evidence mainline fixtures load correct Skill" {
    _eval_skip_unless_live

    local precision_hits=0 precision_total=0
    local f evidence_summary session_resp loaded_skill

    for f in "$EVAL_CASES_DIR/mainline"/synthesizing-evidence-*.json; do
        [[ -n "${BL_EVAL_FILTER:-}" && "${BL_EVAL_FILTER}" != "synthesizing-evidence" ]] && continue
        evidence_summary=$(jq -r '.evidence_summary' "$f")
        precision_total=$((precision_total + 1))

        # Invoke curator session with the evidence_summary; assert synthesizing-evidence Skill is loaded.
        # bl_skills_get output is consulted via the session tool_use response.
        session_resp=$(BL_REPO_ROOT="$BATS_REPO_ROOT" "$BATS_REPO_ROOT/bl" consult \
            --case EVAL-PROBE --message "$evidence_summary" 2>/dev/null) || true
        loaded_skill=$(printf '%s' "$session_resp" | jq -r '.skill_loaded // empty' 2>/dev/null || echo "")

        if [[ "$loaded_skill" == "synthesizing-evidence" ]]; then
            precision_hits=$((precision_hits + 1))
        else
            echo "MISS: $(basename "$f") → loaded '$loaded_skill' (expected synthesizing-evidence)" >&3
        fi
    done

    # Record running tallies for final metrics aggregation (test 13)
    printf '%d/%d\n' "$precision_hits" "$precision_total" \
        > "$EVAL_METRICS_DIR/synthesizing-evidence.tally"

    (( precision_total == 0 )) || [[ "$precision_hits" -ge 1 ]] || {
        echo "FAIL: 0 of $precision_total synthesizing-evidence fixtures matched" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# Test 7 — live: distractor fixtures do not load the wrong Skill
# ---------------------------------------------------------------------------

@test "live: distractor fixture does NOT load the wrong Skill" {
    _eval_skip_unless_live

    local specificity_clean=0 specificity_total=0
    local f evidence_summary wrong_skill session_resp loaded_skill

    for f in "$EVAL_CASES_DIR/distractor"/*.json; do
        evidence_summary=$(jq -r '.evidence_summary' "$f")
        wrong_skill=$(jq -r '.expected_no_skill' "$f")
        specificity_total=$((specificity_total + 1))

        session_resp=$(BL_REPO_ROOT="$BATS_REPO_ROOT" "$BATS_REPO_ROOT/bl" consult \
            --case EVAL-PROBE --message "$evidence_summary" 2>/dev/null) || true
        loaded_skill=$(printf '%s' "$session_resp" | jq -r '.skill_loaded // empty' 2>/dev/null || echo "")

        if [[ "$loaded_skill" != "$wrong_skill" ]]; then
            specificity_clean=$((specificity_clean + 1))
        else
            echo "MISFIRED: $(basename "$f") → loaded '$loaded_skill' (should NOT have fired)" >&3
        fi
    done

    printf '%d/%d\n' "$specificity_clean" "$specificity_total" \
        > "$EVAL_METRICS_DIR/distractor.tally"

    (( specificity_total == 0 )) || [[ "$specificity_clean" -ge 1 ]] || {
        echo "FAIL: 0 of $specificity_total distractor fixtures passed specificity check" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# Test 8 — live: ambiguous fixtures are tracked but not failed
# ---------------------------------------------------------------------------

@test "live: ambiguous fixture is reported but not failed" {
    _eval_skip_unless_live

    local ambiguous_count=0
    local f evidence_summary session_resp loaded_skill

    for f in "$EVAL_CASES_DIR/ambiguous"/*.json; do
        evidence_summary=$(jq -r '.evidence_summary' "$f")
        ambiguous_count=$((ambiguous_count + 1))

        session_resp=$(BL_REPO_ROOT="$BATS_REPO_ROOT" "$BATS_REPO_ROOT/bl" consult \
            --case EVAL-PROBE --message "$evidence_summary" 2>/dev/null) || true
        loaded_skill=$(printf '%s' "$session_resp" | jq -r '.skill_loaded // empty' 2>/dev/null || echo "")

        echo "AMBIGUOUS: $(basename "$f") → loaded '$loaded_skill'" >&3
    done

    printf '%d\n' "$ambiguous_count" > "$EVAL_METRICS_DIR/ambiguous.count"

    # Warn-only: ambiguous fixtures inform but do not block promotion
    true
}

# ---------------------------------------------------------------------------
# Test 9 — live: per-Skill precision across all 30 mainline fixtures
# ---------------------------------------------------------------------------

@test "live: per-Skill precision computed across 30 mainline fixtures" {
    _eval_skip_unless_live

    local -A skill_hits
    local -A skill_totals
    local s
    for s in "${VALID_SKILLS[@]}"; do
        skill_hits[$s]=0
        skill_totals[$s]=0
    done

    local f skill evidence_summary session_resp loaded_skill
    for f in "$EVAL_CASES_DIR/mainline"/*.json; do
        skill=$(jq -r '.expected_skill' "$f")
        evidence_summary=$(jq -r '.evidence_summary' "$f")
        skill_totals[$skill]=$(( ${skill_totals[$skill]:-0} + 1 ))

        session_resp=$(BL_REPO_ROOT="$BATS_REPO_ROOT" "$BATS_REPO_ROOT/bl" consult \
            --case EVAL-PROBE --message "$evidence_summary" 2>/dev/null) || true
        loaded_skill=$(printf '%s' "$session_resp" | jq -r '.skill_loaded // empty' 2>/dev/null || echo "")

        [[ "$loaded_skill" == "$skill" ]] && skill_hits[$skill]=$(( ${skill_hits[$skill]:-0} + 1 ))
    done

    local below_bar=0
    for s in "${VALID_SKILLS[@]}"; do
        local total=${skill_totals[$s]:-0}
        local hits=${skill_hits[$s]:-0}
        (( total == 0 )) && continue
        # Use integer arithmetic: precision_pct = (hits * 100) / total
        local pct=$(( (hits * 100) / total ))
        printf '%s: %d/%d (%d%%)\n' "$s" "$hits" "$total" "$pct" >> "$EVAL_METRICS_DIR/precision.log"
        if (( pct < 85 )); then
            below_bar=$((below_bar + 1))
            echo "BELOW BAR: $s precision $pct% < 85%" >&3
        fi
    done

    # Persist per-Skill tallies for final report (test 13)
    for s in "${VALID_SKILLS[@]}"; do
        printf '%d/%d\n' "${skill_hits[$s]:-0}" "${skill_totals[$s]:-0}" \
            > "$EVAL_METRICS_DIR/skill-${s}.tally"
    done

    # Warn on below-bar but record for report — gate is enforced at promotion step
    (( below_bar == 0 )) || echo "WARNING: $below_bar Skill(s) below 0.85 precision bar" >&3
    true
}

# ---------------------------------------------------------------------------
# Test 10 — live: cross-Skill recall
# ---------------------------------------------------------------------------

@test "live: cross-Skill recall computed" {
    _eval_skip_unless_live

    # Cross-Skill recall: fraction of the 30 mainline cases where the
    # correct Skill was loaded (any Skill correctly identified).
    local recall_hits=0 recall_total=0
    local f skill evidence_summary session_resp loaded_skill

    for f in "$EVAL_CASES_DIR/mainline"/*.json; do
        skill=$(jq -r '.expected_skill' "$f")
        evidence_summary=$(jq -r '.evidence_summary' "$f")
        recall_total=$((recall_total + 1))

        session_resp=$(BL_REPO_ROOT="$BATS_REPO_ROOT" "$BATS_REPO_ROOT/bl" consult \
            --case EVAL-PROBE --message "$evidence_summary" 2>/dev/null) || true
        loaded_skill=$(printf '%s' "$session_resp" | jq -r '.skill_loaded // empty' 2>/dev/null || echo "")

        [[ "$loaded_skill" == "$skill" ]] && recall_hits=$((recall_hits + 1))
    done

    local recall_pct=0
    (( recall_total > 0 )) && recall_pct=$(( (recall_hits * 100) / recall_total ))

    printf '%d/%d\n' "$recall_hits" "$recall_total" > "$EVAL_METRICS_DIR/recall.tally"

    echo "cross-Skill recall: $recall_hits/$recall_total ($recall_pct%)" >&3
    (( recall_pct >= 75 )) || echo "WARNING: cross-Skill recall $recall_pct% < 75% bar" >&3
    true
}

# ---------------------------------------------------------------------------
# Test 11 — live: distractor specificity
# ---------------------------------------------------------------------------

@test "live: distractor specificity computed" {
    _eval_skip_unless_live

    local spec_hits=0 spec_total=0
    local f wrong_skill evidence_summary session_resp loaded_skill

    for f in "$EVAL_CASES_DIR/distractor"/*.json; do
        wrong_skill=$(jq -r '.expected_no_skill' "$f")
        evidence_summary=$(jq -r '.evidence_summary' "$f")
        spec_total=$((spec_total + 1))

        session_resp=$(BL_REPO_ROOT="$BATS_REPO_ROOT" "$BATS_REPO_ROOT/bl" consult \
            --case EVAL-PROBE --message "$evidence_summary" 2>/dev/null) || true
        loaded_skill=$(printf '%s' "$session_resp" | jq -r '.skill_loaded // empty' 2>/dev/null || echo "")

        [[ "$loaded_skill" != "$wrong_skill" ]] && spec_hits=$((spec_hits + 1))
    done

    local spec_pct=0
    (( spec_total > 0 )) && spec_pct=$(( (spec_hits * 100) / spec_total ))

    printf '%d/%d\n' "$spec_hits" "$spec_total" > "$EVAL_METRICS_DIR/specificity.tally"

    echo "distractor specificity: $spec_hits/$spec_total ($spec_pct%)" >&3
    (( spec_pct >= 95 )) || echo "WARNING: specificity $spec_pct% < 95% bar" >&3
    true
}

# ---------------------------------------------------------------------------
# Test 12 — live: bl_setup_eval JSON shape conforms to spec §5b.5
# ---------------------------------------------------------------------------

@test "live: bl setup --eval emits JSON conforming to spec §5b.5 shape" {
    _eval_skip_unless_live

    # Point BL_EVAL_REPORT_FILE to a fresh tmp file so bl_setup_eval reads it
    local tmp_report
    tmp_report=$(mktemp)
    export BL_EVAL_REPORT_FILE="$tmp_report"

    run BL_REPO_ROOT="$BATS_REPO_ROOT" "$BATS_REPO_ROOT/bl" setup --eval
    # bl setup --eval may return non-zero when promotion bar not met; allow it
    # (the JSON shape is what we are checking, not the exit code here)

    # Verify output contains the required top-level keys
    local json_out="$output"
    printf '%s' "$json_out" | jq -e '.per_skill_precision' >/dev/null 2>&1 || {
        echo "FAIL: per_skill_precision key missing from bl setup --eval output" >&3
        echo "output: $json_out" >&3
        return 1
    }
    printf '%s' "$json_out" | jq -e 'has("cross_skill_recall")' >/dev/null 2>&1 || {
        echo "FAIL: cross_skill_recall key missing" >&3
        return 1
    }
    printf '%s' "$json_out" | jq -e 'has("distractor_specificity")' >/dev/null 2>&1 || {
        echo "FAIL: distractor_specificity key missing" >&3
        return 1
    }
    printf '%s' "$json_out" | jq -e 'has("promotion_pass")' >/dev/null 2>&1 || {
        echo "FAIL: promotion_pass key missing" >&3
        return 1
    }
    printf '%s' "$json_out" | jq -e 'has("below_bar")' >/dev/null 2>&1 || {
        echo "FAIL: below_bar key missing" >&3
        return 1
    }

    rm -f "$tmp_report"
}

# ---------------------------------------------------------------------------
# Test 13 — live: emit metrics report to BL_EVAL_REPORT_FILE
# Final test — file-write contract. bl_setup_eval reads this after bats exits.
# Assembles the JSON report from running tallies written by tests 6-11.
# ---------------------------------------------------------------------------

@test "live: emit metrics report to BL_EVAL_REPORT_FILE" {
    _eval_skip_unless_live

    # BL_EVAL_REPORT_FILE must be set by bl_setup_eval before invoking this runner
    [[ -n "${BL_EVAL_REPORT_FILE:-}" ]] || {
        echo "FAIL: BL_EVAL_REPORT_FILE not set — bl_setup_eval must export it before running bats" >&3
        return 1
    }

    # Read per-Skill tallies (written by test 9)
    local -A per_skill_precision
    local s hits total
    for s in "${VALID_SKILLS[@]}"; do
        local tally_file="$EVAL_METRICS_DIR/skill-${s}.tally"
        if [[ -f "$tally_file" ]]; then
            local tally
            tally=$(cat "$tally_file")
            hits="${tally%%/*}"
            total="${tally##*/}"
            if (( total > 0 )); then
                # Store as integer percentage; caller can divide by 100
                per_skill_precision[$s]=$(( (hits * 100) / total ))
            else
                per_skill_precision[$s]=0
            fi
        else
            per_skill_precision[$s]=0
        fi
    done

    # Read recall tally (test 10)
    local recall_hits=0 recall_total=0 recall_float=0
    if [[ -f "$EVAL_METRICS_DIR/recall.tally" ]]; then
        local rt
        rt=$(cat "$EVAL_METRICS_DIR/recall.tally")
        recall_hits="${rt%%/*}"
        recall_total="${rt##*/}"
        (( recall_total > 0 )) && recall_float=$(( (recall_hits * 100) / recall_total ))
    fi

    # Read specificity tally (test 11)
    local spec_hits=0 spec_total=0 spec_float=0
    if [[ -f "$EVAL_METRICS_DIR/specificity.tally" ]]; then
        local st
        st=$(cat "$EVAL_METRICS_DIR/specificity.tally")
        spec_hits="${st%%/*}"
        spec_total="${st##*/}"
        (( spec_total > 0 )) && spec_float=$(( (spec_hits * 100) / spec_total ))
    fi

    # Determine promotion_pass and below_bar
    local promotion_pass="true"
    local below_bar_json="[]"

    # Build per_skill_precision JSON object and check bars
    local psp_json="{"
    local first=1
    for s in "${VALID_SKILLS[@]}"; do
        local pct=${per_skill_precision[$s]:-0}
        [[ "$first" -eq 0 ]] && psp_json+=","
        psp_json+="\"$s\":$pct"
        first=0
        if (( pct < 85 )); then
            promotion_pass="false"
            below_bar_json=$(printf '%s' "$below_bar_json" | jq \
                --arg entry "per_skill_precision[$s]=${pct}% (bar 85%)" '. += [$entry]')
        fi
    done
    psp_json+="}"

    # Check recall bar
    if (( recall_float < 75 )); then
        promotion_pass="false"
        below_bar_json=$(printf '%s' "$below_bar_json" | jq \
            --arg entry "cross_skill_recall=${recall_float}% (bar 75%)" '. += [$entry]')
    fi

    # Check specificity bar
    if (( spec_float < 95 )); then
        promotion_pass="false"
        below_bar_json=$(printf '%s' "$below_bar_json" | jq \
            --arg entry "distractor_specificity=${spec_float}% (bar 95%)" '. += [$entry]')
    fi

    # Collect ambiguous results
    local ambiguous_results="[]"
    for f in "$EVAL_CASES_DIR/ambiguous"/*.json; do
        local cid
        cid=$(jq -r '.case_id' "$f")
        ambiguous_results=$(printf '%s' "$ambiguous_results" | jq \
            --arg id "$cid" '. += [$id]')
    done

    # Write the report
    jq -n \
        --argjson psp "$psp_json" \
        --argjson recall "$recall_float" \
        --argjson spec "$spec_float" \
        --argjson ambiguous "$ambiguous_results" \
        --argjson promo "$promotion_pass" \
        --argjson below "$below_bar_json" \
        '{
            per_skill_precision: $psp,
            cross_skill_recall: ($recall / 100.0),
            median_input_tokens: 0,
            distractor_specificity: ($spec / 100.0),
            ambiguous_results: $ambiguous,
            promotion_pass: $promo,
            below_bar: $below
        }' > "${BL_EVAL_REPORT_FILE:?BL_EVAL_REPORT_FILE not set}"

    [[ -s "$BL_EVAL_REPORT_FILE" ]] || {
        echo "FAIL: report file $BL_EVAL_REPORT_FILE is empty after write" >&3
        return 1
    }

    echo "metrics report written → $BL_EVAL_REPORT_FILE" >&3
    jq '.' "$BL_EVAL_REPORT_FILE" >&3
}
