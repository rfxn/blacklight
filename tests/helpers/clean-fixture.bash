# tests/helpers/clean-fixture.bash — per-test clean-target seeder
#
# bl_clean_fixture_seed <case-id> : seeds $BL_VAR_DIR + a populated
#   $BL_VAR_DIR/bl-case/<case-id>/, primes case.current, copies the M2
#   case-templates into place (shared with case-fixture but independent).
#
# bl_clean_fixture_htaccess <dir> : materialises a .htaccess fixture into
#   <dir> by copying tests/fixtures/htaccess-clean-target.
#
# bl_clean_fixture_build_patch_htaccess <target-path> : writes a unified-diff
#   file ready for `patch -p0`, with its --- / +++ header pinned to the
#   caller's dynamic target (under mktemp -d no static fixture can encode it).
#
# bl_clean_fixture_spawn_sleeper : spawns a `sleep 120` subprocess, prints
#   its PID on stdout. Caller stores the pid to kill in teardown.
#
# bl_clean_fixture_teardown_sleeper <pid> : kills pid if still alive.

bl_clean_fixture_seed() {
    local case_id="${1:-CASE-2026-7001}"
    local repo_root="${BL_REPO_ROOT:-$BATS_TEST_DIRNAME/..}"
    mkdir -p "$BL_VAR_DIR"/{state,ledger,backups,quarantine,outbox,cases}
    mkdir -p "$BL_VAR_DIR/cases/$case_id/evidence"
    printf '%s' "$case_id" > "$BL_VAR_DIR/state/case.current"
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
    printf 'memstore_test_stub' > "$BL_VAR_DIR/state/memstore-case-id"
}

bl_clean_fixture_htaccess() {
    local dir="$1"
    local repo_root="${BL_REPO_ROOT:-$BATS_TEST_DIRNAME/..}"
    mkdir -p "$dir"
    cp "$BATS_TEST_DIRNAME/fixtures/htaccess-clean-target" "$dir/.htaccess"
}

bl_clean_fixture_build_patch_htaccess() {
    # Fixture htaccess-clean-target geometry:
    #   Line 1-6: benign Apache config
    #   Line 7  : blank separator
    #   Line 8-11: 4-line injected block
    # Patch removes lines 7-11 (1 blank + 4 injected = 5 lines removed, 0 added).
    # Correct unified-diff header: @@ -7,5 +7,0 @@
    local target="$1"
    local out
    out=$(mktemp)
    cat > "$out" <<PATCH_EOF
--- $target
+++ $target
@@ -7,5 +7,0 @@
-
-# --- INJECTED (apsb25-94 shape) ---
-<FilesMatch "\.jpg$">
-    SetHandler application/x-httpd-php
-</FilesMatch>
PATCH_EOF
    printf '%s' "$out"
}

bl_clean_fixture_spawn_sleeper() {
    # exec >/dev/null 2>&1 closes inherited pipe fds so the caller's $()
    # command substitution does not hang waiting for background proc to exit.
    ( exec >/dev/null 2>&1; sleep 120 ) &
    local pid=$!
    printf '%s' "$pid"
}

bl_clean_fixture_teardown_sleeper() {
    local pid="$1"
    [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true   # already dead = success
}
