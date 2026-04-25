#!/usr/bin/env bash
# tests/helpers/observe-fixture-setup.bash — BL_VAR_DIR staging + case seed + per-fixture stagers
# Consumed by tests/04-observe.bats.
# Provides: setup_observe_case, teardown_observe_case, and 12 stage_* helpers.

setup_observe_case() {
    local case_id="${1:-CASE-2026-9999}"
    export BL_VAR_DIR
    BL_VAR_DIR="$(mktemp -d)"
    export ANTHROPIC_API_KEY="sk-ant-test"
    export BL_HOST_LABEL="fleet-01-host-99"
    mkdir -p "$BL_VAR_DIR/state"
    printf '%s' "$case_id" > "$BL_VAR_DIR/state/case.current"
    printf '%s' "agent_test_stub" > "$BL_VAR_DIR/state/agent-id"
    mkdir -p "$BL_VAR_DIR/cases/$case_id/evidence"
    mkdir -p "$BL_VAR_DIR/outbox"
}

teardown_observe_case() {
    [[ -n "${BL_VAR_DIR:-}" && -d "$BL_VAR_DIR" ]] && rm -rf "$BL_VAR_DIR"
    unset BL_VAR_DIR ANTHROPIC_API_KEY BL_HOST_LABEL
}

stage_apache_log() {
    # $1 = destination path to copy fixture to
    local dest="$1"
    cp "$BATS_TEST_DIRNAME/fixtures/apache-apsb25-94.log" "$dest"
    # Set mtime to 2026-04-23 14:22:07 UTC for --around anchor matching fixture
    # timestamps. Space-form (not ISO-T) for coreutils 8.4 (CentOS 6) which
    # rejects "YYYY-MM-DDTHH:MM:SSZ"; the form below parses on c6 and modern.
    touch -d "2026-04-23 14:22:07 UTC" "$dest"
}

stage_modsec_log() {
    local dest="$1"
    cp "$BATS_TEST_DIRNAME/fixtures/modsec-apsb25-94.log" "$dest"
}

stage_cron_injected() {
    local dest="$1"
    cp "$BATS_TEST_DIRNAME/fixtures/cron-injected.txt" "$dest"
}

stage_htaccess_injected() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    cp "$BATS_TEST_DIRNAME/fixtures/htaccess-injected" "$dest_dir/.htaccess"
}

stage_iptables_dump() {
    local dest="$1"
    cp "$BATS_TEST_DIRNAME/fixtures/iptables-dump.txt" "$dest"
}

stage_nftables_dump() {
    local dest="$1"
    cp "$BATS_TEST_DIRNAME/fixtures/nftables-dump.txt" "$dest"
}

stage_maldet_sigs() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    cp "$BATS_TEST_DIRNAME/fixtures/maldet-sigs.hdb" "$dest_dir/maldet-sigs.hdb"
}

stage_proc_verify_argv() {
    local dest="$1"
    cp "$BATS_TEST_DIRNAME/fixtures/proc-verify-argv.txt" "$dest"
}

stage_journal_entries() {
    local dest="$1"
    cp "$BATS_TEST_DIRNAME/fixtures/journal-entries.json" "$dest"
}

stage_file_triage_target() {
    local dest="$1"
    cp "$BATS_TEST_DIRNAME/fixtures/file-triage-target.php" "$dest"
}

stage_fs_mtime_cluster() {
    # $1 = destination directory; re-touches files with 4-second cluster spacing
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    # 7 files spanning 4 seconds (14:22:07 to 14:22:11 UTC on 2026-04-23).
    # Space-form (not ISO-T) — see stage_apache_log for the c6 coreutils note.
    touch -d "2026-04-23 14:22:07 UTC" "$dest_dir/a.php"
    touch -d "2026-04-23 14:22:08 UTC" "$dest_dir/b.php"
    touch -d "2026-04-23 14:22:08 UTC" "$dest_dir/c.php"
    touch -d "2026-04-23 14:22:09 UTC" "$dest_dir/d.php"
    touch -d "2026-04-23 14:22:10 UTC" "$dest_dir/e.php"
    touch -d "2026-04-23 14:22:10 UTC" "$dest_dir/f.php"
    touch -d "2026-04-23 14:22:11 UTC" "$dest_dir/g.php"
}

stage_substrate_fixture() {
    # $1 = probe-root directory (will be created); seeds /etc/os-release and
    # /run/systemd/system to look like a debian12 host. Tests that want
    # missing-tool degradation pass an empty mktemp -d directly without
    # calling this helper.
    local root="$1"
    mkdir -p "$root/etc" "$root/run/systemd/system"
    cat > "$root/etc/os-release" <<'EOF'
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
VERSION="12 (bookworm)"
ID=debian
EOF
}
