# tests/helpers/case-fixture.bash — per-test case-tree seeder
#
# bl_case_fixture_seed <case-id> : materializes $BL_VAR_DIR/{state,ledger,backups,quarantine,outbox}
#   + $BL_VAR_DIR/bl-case/<case-id>/ with M2 case-templates/*.md copied in.
# bl_case_fixture_teardown : rm -rf $BL_VAR_DIR (caller's responsibility).
#
# Consumed by tests/05-consult-run-case.bats. Uses bare coreutils per
# CLAUDE.md §Testing (BATS helpers follow test-file convention).

bl_case_fixture_seed() {
    local case_id="${1:-CASE-2026-0001}"
    local repo_root="${BL_REPO_ROOT:-$BATS_TEST_DIRNAME/..}"
    mkdir -p "$BL_VAR_DIR"/{state,ledger,backups,quarantine,outbox}
    mkdir -p "$BL_VAR_DIR/bl-case/$case_id"
    mkdir -p "$BL_VAR_DIR/bl-case/$case_id"/{pending,results,history,evidence}
    mkdir -p "$BL_VAR_DIR/bl-case/$case_id/actions"/{pending,applied,retired}
    # M2 template seed — excludes closed.md (present-iff-closed) and README.md (contract-only)
    for tmpl in hypothesis open-questions attribution ip-clusters url-patterns file-patterns defense-hits; do
        if [[ -r "$repo_root/case-templates/$tmpl.md" ]]; then
            cp "$repo_root/case-templates/$tmpl.md" "$BL_VAR_DIR/bl-case/$case_id/$tmpl.md"
        fi
    done
    # INDEX.md is workspace-wide — seed one roster row
    if [[ -r "$repo_root/case-templates/INDEX.md" ]]; then
        cp "$repo_root/case-templates/INDEX.md" "$BL_VAR_DIR/bl-case/INDEX.md"
    fi
    # STEP_COUNTER init
    printf '0\n' > "$BL_VAR_DIR/bl-case/$case_id/STEP_COUNTER"
    # case.current
    printf '%s' "$case_id" > "$BL_VAR_DIR/state/case.current"
    # agent-id seed (preflight passthrough)
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
    # session-id for wake events
    printf 'sesn_test_stub' > "$BL_VAR_DIR/state/session-$case_id"
    # memstore-case-id (M5 MUST-FIX 6.2)
    printf 'memstore_test_stub' > "$BL_VAR_DIR/state/memstore-case-id"
}

bl_case_fixture_teardown() {
    [[ -n "${BL_VAR_DIR:-}" && -d "$BL_VAR_DIR" ]] && rm -rf "$BL_VAR_DIR"
}

bl_case_fixture_seed_closed() {
    # Seed a case with closed.md present (reopen / case-list tests)
    local case_id="$1"
    bl_case_fixture_seed "$case_id"
    cat > "$BL_VAR_DIR/bl-case/$case_id/closed.md" <<CLOSED_EOF
---
case_id: $case_id
closed_at: 2026-04-20T12:00:00Z
brief_file_id_md: file_01TESTmd
brief_file_id_pdf: file_01TESTpdf
brief_file_id_html: file_01TESTht
---

# Closed case: $case_id
CLOSED_EOF
}
