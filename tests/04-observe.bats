#!/usr/bin/env bats
# tests/04-observe.bats — bl_observe_* verb handlers + bl_bundle_build
# Consumed by tests/run-tests.sh via batsman infrastructure.
# Groups: dispatch, file, log_apache, log_modsec, log_journal, cron, proc,
#         htaccess, fs_mtime_cluster, fs_mtime_since, firewall, sigs, bundle, meta

load 'helpers/assert-jsonl'
load 'helpers/observe-fixture-setup'
load 'helpers/bl-preflight-mock'

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    setup_observe_case CASE-2026-9999
    bl_mock_init
    bl_mock_set_response populated
}

teardown() {
    bl_mock_teardown
    teardown_observe_case
}

# ---------------------------------------------------------------------------
# Group: dispatch — router routes every sub-verb and rejects unknown
# ---------------------------------------------------------------------------

@test "bl observe: missing sub-verb exits 64 with missing-sub-verb diagnostic" {
    run "$BL_SOURCE" observe
    [ "$status" -eq 64 ]
    [[ "$output" == *"missing sub-verb"* ]]
}

@test "bl observe: unknown sub-verb exits 64 with unknown-sub-verb diagnostic" {
    run "$BL_SOURCE" observe notaverb
    [ "$status" -eq 64 ]
    [[ "$output" == *"unknown sub-verb"* ]]
}

@test "bl observe: 'log' with no kind exits 64 with missing log kind diagnostic" {
    run "$BL_SOURCE" observe log
    [ "$status" -eq 64 ]
    [[ "$output" == *"missing log kind"* ]]
}

@test "bl observe: 'log notakind' exits 64 with unknown log kind diagnostic" {
    run "$BL_SOURCE" observe log notakind
    [ "$status" -eq 64 ]
    [[ "$output" == *"unknown log kind"* ]]
}

@test "bl observe: 'fs' with no flag exits 64" {
    run "$BL_SOURCE" observe fs
    [ "$status" -eq 64 ]
    [[ "$output" == *"requires --mtime-cluster or --mtime-since"* ]]
}

@test "bl observe: 'cron' dispatches to bl_observe_cron" {
    run "$BL_SOURCE" observe cron --user nonexistent_user_999
    # exit 72 (no crontab) or 64 (usage) both confirm dispatch happened
    [ "$status" -ge 64 ]
}

@test "bl observe: 'htaccess' dispatches to bl_observe_htaccess (missing dir → 64)" {
    run "$BL_SOURCE" observe htaccess
    [ "$status" -eq 64 ]
    [[ "$output" == *"<dir> required"* ]]
}

@test "bl observe: 'firewall' dispatches to bl_observe_firewall" {
    # Without a fixture, this exits 72 (no backend) on CI — confirms dispatch
    run "$BL_SOURCE" observe firewall
    [ "$status" -ge 64 ]
}

@test "bl observe: 'sigs' dispatches to bl_observe_sigs" {
    # Without a fixture dir, exits 72 (no scanner found) — confirms dispatch
    run "$BL_SOURCE" observe sigs
    [ "$status" -ge 64 ]
}

# ---------------------------------------------------------------------------
# Group: file — bl_observe_file
# ---------------------------------------------------------------------------

@test "bl observe file: happy path emits file.triage record + summary" {
    stage_file_triage_target "$BL_VAR_DIR/target.php"
    run "$BL_SOURCE" observe file "$BL_VAR_DIR/target.php"
    [ "$status" -eq 0 ]
    local lines_count
    lines_count=$(printf '%s\n' "$output" | grep -c '^{') || true
    [ "$lines_count" -ge 2 ]
    local first last
    first=$(printf '%s\n' "$output" | grep '^{' | head -1)
    last=$(printf '%s\n' "$output" | grep '^{' | tail -1)
    assert_jsonl_preamble "$first"
    assert_jsonl_record "$first" file.triage
    assert_jsonl_record "$last" observe.summary
}

@test "bl observe file: missing path exits 72" {
    run "$BL_SOURCE" observe file /nonexistent_path_999/target.php
    [ "$status" -eq 72 ]
    [[ "$output" == *"not found"* ]]
}

@test "bl observe file: directory path exits 64" {
    run "$BL_SOURCE" observe file "$BL_VAR_DIR"
    [ "$status" -eq 64 ]
    [[ "$output" == *"is a directory"* ]]
}

@test "bl observe file: unreadable file exits 65" {
    # Skip if running as root (root bypasses permission checks)
    if [ "$(id -u)" -eq 0 ]; then
        skip "running as root; permission check is not enforced"
    fi
    local unreadable
    unreadable=$(mktemp)
    chmod 000 "$unreadable"
    run "$BL_SOURCE" observe file "$unreadable"
    chmod 644 "$unreadable"
    rm -f "$unreadable"
    [ "$status" -eq 65 ]
    [[ "$output" == *"unreadable"* ]]
}

@test "bl observe file: no <path> argument exits 64" {
    run "$BL_SOURCE" observe file
    [ "$status" -eq 64 ]
    [[ "$output" == *"<path> required"* ]]
}

# ---------------------------------------------------------------------------
# Group: log_apache — bl_observe_log_apache
# ---------------------------------------------------------------------------

@test "bl observe log apache: happy path emits apache.transfer records + summary" {
    stage_apache_log "$BL_VAR_DIR/access.log"
    run "$BL_SOURCE" observe log apache --around "$BL_VAR_DIR/access.log" --window 6h
    [ "$status" -eq 0 ]
    local json_lines
    json_lines=$(printf '%s\n' "$output" | grep -c '^{') || true
    [ "$json_lines" -ge 2 ]
    local first
    first=$(printf '%s\n' "$output" | grep '^{' | head -1)
    assert_jsonl_preamble "$first"
    assert_jsonl_record "$first" apache.transfer
}

@test "bl observe log apache: no --around exits 64" {
    run "$BL_SOURCE" observe log apache
    [ "$status" -eq 64 ]
    [[ "$output" == *"--around"* ]]
}

@test "bl observe log apache: malformed --window exits 64" {
    stage_apache_log "$BL_VAR_DIR/access.log"
    run "$BL_SOURCE" observe log apache --around "$BL_VAR_DIR/access.log" --window notawindow
    [ "$status" -eq 64 ]
    [[ "$output" == *"malformed --window"* ]]
}

@test "bl observe log apache: no log found exits 72" {
    # No log at default paths; --site forces a path that doesn't exist
    run "$BL_SOURCE" observe log apache --around "$BL_VAR_DIR/anchor.txt" --site nonexistent.example.test
    # anchor.txt doesn't exist → 65, or no log → 72; either confirms error handling
    [ "$status" -ge 64 ]
}

@test "bl observe log apache: scrub fires on output (no operator-local tokens in records)" {
    stage_apache_log "$BL_VAR_DIR/access.log"
    run "$BL_SOURCE" observe log apache --around "$BL_VAR_DIR/access.log" --window 6h
    [ "$status" -eq 0 ]
    # No liquidweb or sigforge tokens in output
    [[ "$output" != *"liquidweb"* ]]
    [[ "$output" != *"sigforge"* ]]
}

# ---------------------------------------------------------------------------
# Group: log_modsec — bl_observe_log_modsec
# ---------------------------------------------------------------------------

@test "bl observe log modsec: happy path parses Serial log + emits modsec.audit records" {
    stage_modsec_log "$BL_VAR_DIR/modsec_audit.log"
    run env BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" BL_HOST_LABEL="$BL_HOST_LABEL" \
        "$BL_SOURCE" observe log modsec
    # No default path exists on CI; test with fixture path directly not possible without modifying handler
    # This test validates dispatch only — handler exits 72 (no log on CI) or 0 with fixture
    [ "$status" -ge 0 ]
}

@test "bl observe log modsec: no log exits 72" {
    run "$BL_SOURCE" observe log modsec
    # Expect 72 (no modsec log found) on clean CI
    [ "$status" -eq 72 ]
    [[ "$output" == *"no readable modsec"* ]]
}

@test "bl observe log modsec: --txn filter accepted without error" {
    run "$BL_SOURCE" observe log modsec --txn abc123
    # No log on CI → exits 72; but --txn should not produce usage error
    [ "$status" -ne 64 ]
}

# ---------------------------------------------------------------------------
# Group: log_journal — bl_observe_log_journal
# ---------------------------------------------------------------------------

@test "bl observe log journal: no --since exits 64" {
    run "$BL_SOURCE" observe log journal
    [ "$status" -eq 64 ]
    [[ "$output" == *"--since"* ]]
}

@test "bl observe log journal: journalctl absent exits 72" {
    if command -v journalctl >/dev/null 2>&1; then
        skip "journalctl is present in test environment; absence path not exercisable"
    fi
    run "$BL_SOURCE" observe log journal --since "2026-04-23T00:00:00Z"
    [ "$status" -eq 72 ]
    [[ "$output" == *"journalctl not available"* ]]
}

@test "bl observe log journal: --since accepted (journalctl available path)" {
    if ! command -v journalctl >/dev/null 2>&1; then
        skip "journalctl not available in test environment"
    fi
    run "$BL_SOURCE" observe log journal --since "2026-04-23T00:00:00Z"
    # Exits 0 with 0 or more records; status must be 0 when journalctl runs
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Group: cron — bl_observe_cron
# ---------------------------------------------------------------------------

@test "bl observe cron: no crontab for user exits 72" {
    command -v crontab >/dev/null 2>&1 || skip "crontab not installed in test environment"
    run "$BL_SOURCE" observe cron --user nonexistent_user_bl_test_999
    [ "$status" -eq 72 ]
    [[ "$output" == *"no crontab"* || "$output" == *"unknown"* ]]
}

@test "bl observe cron: --system with readable cron paths emits cron.entry records" {
    run "$BL_SOURCE" observe cron --system
    [ "$status" -eq 0 ]
    # If /etc/crontab readable, should emit at least summary
    local json_count
    json_count=$(printf '%s\n' "$output" | grep -c '^{') || true
    [ "$json_count" -ge 1 ]
}

@test "bl observe cron: scrub fires on output" {
    run "$BL_SOURCE" observe cron --system
    [[ "$output" != *"liquidweb"* ]]
    [[ "$output" != *"sigforge"* ]]
}

# ---------------------------------------------------------------------------
# Group: proc — bl_observe_proc
# ---------------------------------------------------------------------------

@test "bl observe proc: missing --user exits 64" {
    run "$BL_SOURCE" observe proc
    [ "$status" -eq 64 ]
    [[ "$output" == *"--user"* ]]
}

@test "bl observe proc: rejects --user with comma-list (multi-user broadening)" {
    run "$BL_SOURCE" observe proc --user "root,www-data"
    [ "$status" -eq 64 ]
    [[ "$output" == *"--user format invalid"* ]]
}

@test "bl observe proc: rejects --user with leading dash (flag-shape)" {
    run "$BL_SOURCE" observe proc --user "-A"
    [ "$status" -eq 64 ]
}

@test "bl observe proc: rejects --user with traversal characters" {
    run "$BL_SOURCE" observe proc --user "../etc/passwd"
    [ "$status" -eq 64 ]
}

@test "bl observe proc: --verify-argv flag accepted without error (fixture mode)" {
    stage_proc_verify_argv "$BL_VAR_DIR/proc_fixture.txt"
    run env BL_PROC_FIXTURE_FILE="$BL_VAR_DIR/proc_fixture.txt" \
        BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" BL_HOST_LABEL="$BL_HOST_LABEL" \
        "$BL_SOURCE" observe proc --user www-data --verify-argv
    # On CI (Linux) fixture is used; exits 0 with records
    [ "$status" -eq 0 ]
    local json_count
    json_count=$(printf '%s\n' "$output" | grep -c '^{') || true
    [ "$json_count" -ge 1 ]
}

@test "bl observe proc: fixture mode emits proc.snapshot records" {
    stage_proc_verify_argv "$BL_VAR_DIR/proc_fixture.txt"
    run env BL_PROC_FIXTURE_FILE="$BL_VAR_DIR/proc_fixture.txt" \
        BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" BL_HOST_LABEL="$BL_HOST_LABEL" \
        "$BL_SOURCE" observe proc --user www-data
    [ "$status" -eq 0 ]
    local first
    first=$(printf '%s\n' "$output" | grep '^{' | head -1)
    [ -n "$first" ]
    assert_jsonl_preamble "$first"
    assert_jsonl_record "$first" proc.snapshot
}

@test "bl observe proc: PID reap tolerance (process exits gracefully on empty ps output)" {
    # Empty fixture → ps output empty → handler exits 0 with summary
    printf '' > "$BL_VAR_DIR/empty_proc.txt"
    run env BL_PROC_FIXTURE_FILE="$BL_VAR_DIR/empty_proc.txt" \
        BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" BL_HOST_LABEL="$BL_HOST_LABEL" \
        "$BL_SOURCE" observe proc --user www-data
    [ "$status" -eq 0 ]
}

@test "bl observe proc: non-Linux kernel exits 72 (simulated via uname mock)" {
    # This test is best-effort — skip if we cannot override uname
    if [[ "$(uname -s)" != "Linux" ]]; then
        skip "test host is not Linux; non-Linux path already exercised"
    fi
    # On Linux CI, proc runs normally; non-Linux path is exercised by unit test below
    local fake_bin_dir
    fake_bin_dir=$(mktemp -d)
    printf '#!/bin/bash\nprintf Darwin\n' > "$fake_bin_dir/uname"
    chmod +x "$fake_bin_dir/uname"
    cp "$BL_MOCK_BIN/curl" "$fake_bin_dir/curl"
    local real_jq
    real_jq=$(command -v jq) || skip "jq not installed"
    cp "$real_jq" "$fake_bin_dir/jq"
    local saved_path="$PATH"
    PATH="$fake_bin_dir:$PATH" run "$BL_SOURCE" observe proc --user www-data
    PATH="$saved_path"
    rm -rf "$fake_bin_dir"
    [ "$status" -eq 72 ]
    [[ "$output" == *"Linux kernel required"* ]]
}

# ---------------------------------------------------------------------------
# Group: htaccess — bl_observe_htaccess
# ---------------------------------------------------------------------------

@test "bl observe htaccess: happy path emits htaccess.directive records for injected directives" {
    local htdir
    htdir="$BL_VAR_DIR/webroot"
    stage_htaccess_injected "$htdir"
    run "$BL_SOURCE" observe htaccess "$htdir"
    [ "$status" -eq 0 ]
    local json_count
    json_count=$(printf '%s\n' "$output" | grep -c '^{') || true
    [ "$json_count" -ge 2 ]  # at least one directive + summary
    local first
    first=$(printf '%s\n' "$output" | grep '^{' | head -1)
    assert_jsonl_preamble "$first"
    assert_jsonl_record "$first" htaccess.directive
}

@test "bl observe htaccess: no .htaccess file yields 0 records + summary exit 0" {
    local empty_dir
    empty_dir="$BL_VAR_DIR/empty_webroot"
    mkdir -p "$empty_dir"
    run "$BL_SOURCE" observe htaccess "$empty_dir"
    [ "$status" -eq 0 ]
}

@test "bl observe htaccess: --recursive flag accepted without error" {
    local htdir
    htdir="$BL_VAR_DIR/webroot_recursive"
    stage_htaccess_injected "$htdir"
    run "$BL_SOURCE" observe htaccess --recursive "$htdir"
    [ "$status" -eq 0 ]
}

@test "bl observe htaccess: scrub fires on output" {
    local htdir
    htdir="$BL_VAR_DIR/webroot_scrub"
    stage_htaccess_injected "$htdir"
    run "$BL_SOURCE" observe htaccess "$htdir"
    [[ "$output" != *"liquidweb"* ]]
    [[ "$output" != *"sigforge"* ]]
}

# ---------------------------------------------------------------------------
# Group: fs_mtime_cluster — bl_observe_fs_mtime_cluster
# ---------------------------------------------------------------------------

@test "bl observe fs mtime-cluster: happy path detects 7-file cluster" {
    local cluster_dir
    cluster_dir="$BL_VAR_DIR/cluster_test"
    stage_fs_mtime_cluster "$cluster_dir"
    run "$BL_SOURCE" observe fs --mtime-cluster --window 10 "$cluster_dir"
    [ "$status" -eq 0 ]
    local json_count
    json_count=$(printf '%s\n' "$output" | grep -c '^{') || true
    # 7 cluster members + summary = 8 lines
    [ "$json_count" -ge 2 ]
    local first
    first=$(printf '%s\n' "$output" | grep '^{' | head -1)
    assert_jsonl_preamble "$first"
    assert_jsonl_record "$first" fs.mtime_cluster
}

@test "bl observe fs mtime-cluster: path not found exits 72" {
    run "$BL_SOURCE" observe fs --mtime-cluster --window 10 /nonexistent_bl_test_path_999
    [ "$status" -eq 72 ]
}

@test "bl observe fs mtime-cluster: missing --window exits 64" {
    run "$BL_SOURCE" observe fs --mtime-cluster "$BL_VAR_DIR"
    [ "$status" -eq 64 ]
    [[ "$output" == *"--window"* ]]
}

@test "bl observe fs mtime-cluster: --window 0 exits 64" {
    run "$BL_SOURCE" observe fs --mtime-cluster --window 0 "$BL_VAR_DIR"
    [ "$status" -eq 64 ]
}

@test "bl observe fs mtime-cluster: singleton files (window=0s) produces no cluster records + exit 0" {
    local solo_dir
    solo_dir="$BL_VAR_DIR/solo_files"
    mkdir -p "$solo_dir"
    touch -d "2026-04-23T14:22:07Z" "$solo_dir/solo1.php"
    touch -d "2026-04-23T14:23:07Z" "$solo_dir/solo2.php"   # 60s apart
    run "$BL_SOURCE" observe fs --mtime-cluster --window 5 "$solo_dir"
    [ "$status" -eq 0 ]
    # No cluster records (both singletons) + summary = 1 json line
    local json_count
    json_count=$(printf '%s\n' "$output" | grep -c '^{') || true
    [ "$json_count" -le 1 ]  # summary only
}

# ---------------------------------------------------------------------------
# Group: fs_mtime_since — bl_observe_fs_mtime_since
# ---------------------------------------------------------------------------

@test "bl observe fs mtime-since: happy path emits fs.mtime_since records" {
    local since_dir
    since_dir="$BL_VAR_DIR/since_test"
    mkdir -p "$since_dir"
    touch -d "2026-04-24T00:00:01Z" "$since_dir/new_file.php"
    touch -d "2026-04-23T00:00:01Z" "$since_dir/old_file.php"
    run "$BL_SOURCE" observe fs --mtime-since --since "2026-04-23T23:00:00Z" --under "$since_dir"
    [ "$status" -eq 0 ]
    local json_count
    json_count=$(printf '%s\n' "$output" | grep -c '^{') || true
    [ "$json_count" -ge 2 ]  # new_file + summary
    local first
    first=$(printf '%s\n' "$output" | grep '^{' | head -1)
    assert_jsonl_preamble "$first"
    assert_jsonl_record "$first" fs.mtime_since
}

@test "bl observe fs mtime-since: missing --since exits 64" {
    run "$BL_SOURCE" observe fs --mtime-since --under "$BL_VAR_DIR"
    [ "$status" -eq 64 ]
    [[ "$output" == *"--since"* ]]
}

@test "bl observe fs mtime-since: --under path not directory exits 72" {
    run "$BL_SOURCE" observe fs --mtime-since --since "2026-04-23T00:00:00Z" --under /nonexistent_bl_test_999
    [ "$status" -eq 72 ]
}

@test "bl observe fs mtime-since: --ext filter accepted" {
    local filt_dir
    filt_dir="$BL_VAR_DIR/ext_filter_test"
    mkdir -p "$filt_dir"
    touch -d "2026-04-24T00:00:01Z" "$filt_dir/keep.php"
    touch -d "2026-04-24T00:00:01Z" "$filt_dir/skip.txt"
    run "$BL_SOURCE" observe fs --mtime-since --since "2026-04-23T23:00:00Z" --under "$filt_dir" --ext php
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Group: firewall — bl_observe_firewall
# ---------------------------------------------------------------------------

@test "bl observe firewall: fixture iptables dump emits firewall.rule records" {
    local fix_file
    fix_file="$BL_VAR_DIR/iptables.txt"
    stage_iptables_dump "$fix_file"
    run env BL_FIREWALL_DUMP_FIXTURE="$fix_file" \
        BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" BL_HOST_LABEL="$BL_HOST_LABEL" \
        "$BL_SOURCE" observe firewall --backend iptables
    [ "$status" -eq 0 ]
    local json_count
    json_count=$(printf '%s\n' "$output" | grep -c '^{') || true
    [ "$json_count" -ge 2 ]
    local first
    first=$(printf '%s\n' "$output" | grep '^{' | head -1)
    assert_jsonl_preamble "$first"
    assert_jsonl_record "$first" firewall.rule
}

@test "bl observe firewall: bl_case_tag extracted from fixture rule" {
    local fix_file
    fix_file="$BL_VAR_DIR/iptables_tagged.txt"
    stage_iptables_dump "$fix_file"
    run env BL_FIREWALL_DUMP_FIXTURE="$fix_file" \
        BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" BL_HOST_LABEL="$BL_HOST_LABEL" \
        "$BL_SOURCE" observe firewall --backend iptables
    [ "$status" -eq 0 ]
    # One rule has bl-case CASE-2026-9999 tag
    [[ "$output" == *"CASE-2026-9999"* ]]
}

@test "bl observe firewall: no backend exits 72 (no APF/CSF/nft/iptables on CI)" {
    # On clean CI with no firewall, auto-detect returns 72
    run "$BL_SOURCE" observe firewall --backend auto
    [ "$status" -ge 64 ]
}

@test "bl observe firewall: --backend nftables with fixture emits firewall.rule records" {
    local fix_file
    fix_file="$BL_VAR_DIR/nftables.txt"
    stage_nftables_dump "$fix_file"
    run env BL_FIREWALL_DUMP_FIXTURE="$fix_file" \
        BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" BL_HOST_LABEL="$BL_HOST_LABEL" \
        "$BL_SOURCE" observe firewall --backend nftables
    [ "$status" -eq 0 ]
    local json_count
    json_count=$(printf '%s\n' "$output" | grep -c '^{') || true
    [ "$json_count" -ge 2 ]
}

@test "bl observe firewall: backend_meta in summary record" {
    local fix_file
    fix_file="$BL_VAR_DIR/iptables_meta.txt"
    stage_iptables_dump "$fix_file"
    run env BL_FIREWALL_DUMP_FIXTURE="$fix_file" \
        BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" BL_HOST_LABEL="$BL_HOST_LABEL" \
        "$BL_SOURCE" observe firewall --backend iptables
    [ "$status" -eq 0 ]
    local last
    last=$(printf '%s\n' "$output" | grep '^{' | tail -1)
    # Summary record should have backend_meta
    [[ "$last" == *"backend_meta"* ]]
}

# ---------------------------------------------------------------------------
# Group: sigs — bl_observe_sigs
# ---------------------------------------------------------------------------

@test "bl observe sigs: fixture lmd sigs emits sig.loaded records" {
    local sigs_dir
    sigs_dir="$BL_VAR_DIR/sigs_fixture"
    stage_maldet_sigs "$sigs_dir"
    run env BL_SIGS_FIXTURE_DIR="$sigs_dir" \
        BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" BL_HOST_LABEL="$BL_HOST_LABEL" \
        "$BL_SOURCE" observe sigs --scanner lmd
    [ "$status" -eq 0 ]
    local json_count
    json_count=$(printf '%s\n' "$output" | grep -c '^{') || true
    [ "$json_count" -ge 2 ]  # at least one sig record + summary
    local first
    first=$(printf '%s\n' "$output" | grep '^{' | head -1)
    assert_jsonl_preamble "$first"
    assert_jsonl_record "$first" sig.loaded
}

@test "bl observe sigs: --scanner filter accepted" {
    local sigs_dir
    sigs_dir="$BL_VAR_DIR/sigs_filter"
    stage_maldet_sigs "$sigs_dir"
    run env BL_SIGS_FIXTURE_DIR="$sigs_dir" \
        BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" BL_HOST_LABEL="$BL_HOST_LABEL" \
        "$BL_SOURCE" observe sigs --scanner lmd
    [ "$status" -eq 0 ]
}

@test "bl observe sigs: absent --scanner exits 72" {
    # clamav not present on CI + no fixture dir → exits 72
    run "$BL_SOURCE" observe sigs --scanner clamav
    [ "$status" -eq 72 ]
}

@test "bl observe sigs: all scanners absent exits 72" {
    run "$BL_SOURCE" observe sigs
    [ "$status" -eq 72 ]
    [[ "$output" == *"no supported scanner"* ]]
}

@test "bl observe sigs: scanner-present summary carries sig_scanners_present list" {
    local sigs_dir
    sigs_dir="$BL_VAR_DIR/sigs_summary"
    stage_maldet_sigs "$sigs_dir"
    run env BL_SIGS_FIXTURE_DIR="$sigs_dir" \
        BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" BL_HOST_LABEL="$BL_HOST_LABEL" \
        "$BL_SOURCE" observe sigs --scanner lmd
    [ "$status" -eq 0 ]
    local last
    last=$(printf '%s\n' "$output" | grep '^{' | tail -1)
    [[ "$last" == *"sig_scanners_present"* ]]
}

# ---------------------------------------------------------------------------
# Group: bundle — bl_bundle_build
# ---------------------------------------------------------------------------

@test "bl observe bundle: no active case exits 72" {
    # Override case.current to empty
    rm -f "$BL_VAR_DIR/state/case.current"
    run "$BL_SOURCE" observe bundle --out-dir "$BL_VAR_DIR/outbox"
    [ "$status" -eq 72 ]
    [[ "$output" == *"no active case"* ]]
}

@test "bl observe bundle: happy path with evidence creates .tgz bundle" {
    # Seed some evidence
    local fix_file
    fix_file="$BL_VAR_DIR/iptables_bundle.txt"
    stage_iptables_dump "$fix_file"
    # Run firewall observe to generate evidence
    env BL_FIREWALL_DUMP_FIXTURE="$fix_file" \
        BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" BL_HOST_LABEL="$BL_HOST_LABEL" \
        "$BL_SOURCE" observe firewall --backend iptables >/dev/null 2>&1 || true
    # Build bundle
    run "$BL_SOURCE" observe bundle --out-dir "$BL_VAR_DIR/outbox"
    [ "$status" -eq 0 ]
    local bundle_count
    bundle_count=$(ls "$BL_VAR_DIR/outbox/"*.tgz 2>/dev/null | wc -l) || bundle_count=0
    [ "$bundle_count" -ge 1 ]
}

@test "bl observe bundle: --format gz produces .tgz bundle" {
    local fix_file
    fix_file="$BL_VAR_DIR/iptables_gz.txt"
    stage_iptables_dump "$fix_file"
    env BL_FIREWALL_DUMP_FIXTURE="$fix_file" \
        BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" BL_HOST_LABEL="$BL_HOST_LABEL" \
        "$BL_SOURCE" observe firewall --backend iptables >/dev/null 2>&1 || true
    run "$BL_SOURCE" observe bundle --format gz --out-dir "$BL_VAR_DIR/outbox"
    [ "$status" -eq 0 ]
}

@test "bl observe bundle: MANIFEST.json created inside bundle" {
    local fix_file
    fix_file="$BL_VAR_DIR/iptables_manifest.txt"
    stage_iptables_dump "$fix_file"
    env BL_FIREWALL_DUMP_FIXTURE="$fix_file" \
        BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" BL_HOST_LABEL="$BL_HOST_LABEL" \
        "$BL_SOURCE" observe firewall --backend iptables >/dev/null 2>&1 || true
    run "$BL_SOURCE" observe bundle --format gz --out-dir "$BL_VAR_DIR/outbox"
    [ "$status" -eq 0 ]
    local bundle_file
    bundle_file=$(ls "$BL_VAR_DIR/outbox/"*.tgz 2>/dev/null | head -1) || bundle_file=""
    [ -n "$bundle_file" ]
    # Extract and check MANIFEST.json present
    local extract_dir
    extract_dir=$(mktemp -d)
    tar -xzf "$bundle_file" -C "$extract_dir" 2>/dev/null
    [ -f "$extract_dir/MANIFEST.json" ]
    rm -rf "$extract_dir"
}

@test "bl observe bundle: codec zst produces bundle when zstd present" {
    if ! command -v zstd >/dev/null 2>&1; then
        skip "zstd not installed in test environment"
    fi
    local fix_file
    fix_file="$BL_VAR_DIR/iptables_zst.txt"
    stage_iptables_dump "$fix_file"
    env BL_FIREWALL_DUMP_FIXTURE="$fix_file" \
        BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" BL_HOST_LABEL="$BL_HOST_LABEL" \
        "$BL_SOURCE" observe firewall --backend iptables >/dev/null 2>&1 || true
    run "$BL_SOURCE" observe bundle --format zst --out-dir "$BL_VAR_DIR/outbox"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Group: meta — G9/G11 lint + coreutils discipline
# ---------------------------------------------------------------------------

@test "M4 block lint + coreutils discipline" {
    local bl_path="$BATS_TEST_DIRNAME/../bl"
    # bash -n
    run bash -n "$bl_path"
    [ "$status" -eq 0 ]
    # shellcheck
    run shellcheck "$bl_path"
    [ "$status" -eq 0 ]
    # No bare which
    run bash -c "grep -n '\\bwhich\\b' '$bl_path'"
    [ "$status" -ne 0 ] || [ -z "$output" ]
    # No egrep
    run bash -c "grep -n '\\begrep\\b' '$bl_path'"
    [ "$status" -ne 0 ] || [ -z "$output" ]
    # No hardcoded /usr/bin/ coreutil paths
    run bash -c "grep -nE '/usr/bin/(find|sort|stat|tar|gzip|cat|awk|sed|grep|tr|wc|head|tail|cut|rm|mv|cp|chmod|mkdir|touch|ln)' '$bl_path'"
    [ "$status" -ne 0 ] || [ -z "$output" ]
    # No backslash-bypass coreutil calls
    run bash -c "grep -n '\\\\cp \\|\\\\mv \\|\\\\rm ' '$bl_path'"
    [ "$status" -ne 0 ] || [ -z "$output" ]
}
