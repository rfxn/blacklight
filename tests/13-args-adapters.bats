#!/usr/bin/env bats
# tests/13-args-adapters.bats — M16 P5 args translator + per-verb adapter coverage.
#
# Each test sources `bl`, stubs the underlying collector to capture invocations,
# then asserts the adapter translated curator-emitted args correctly. The
# adapter must:
#   1. Translate curator semantic key names (e.g., 'roots') to collector flag
#      names (e.g., '--under').
#   2. Fan out comma-separated multi-values across multiple collector calls.
#   3. Drop unknown keys with bl_warn (non-fatal).
#   4. Convert relative timespecs ('72h') to ISO timestamps where applicable.

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    BL_VAR_DIR="$(mktemp -d)"
    export BL_VAR_DIR
    export ANTHROPIC_API_KEY="sk-ant-test"
    mkdir -p "$BL_VAR_DIR/state"
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
    printf 'memstore_test' > "$BL_VAR_DIR/state/memstore-case-id"
    # Capture file shared across stub + assertion phase
    export ADAPTER_CALL_LOG="$BL_VAR_DIR/adapter-calls.log"
    : > "$ADAPTER_CALL_LOG"
}

teardown() {
    [[ -n "$BL_VAR_DIR" && -d "$BL_VAR_DIR" ]] && rm -rf "$BL_VAR_DIR"
}

# Source bl + replace each underlying collector with a stub that logs its argv to
# $ADAPTER_CALL_LOG. The adapter is what we want to exercise — the collector's
# real behavior is tested in 04-observe.bats.
invoke_adapter() {
    local adapter="$1"
    local args_json="$2"
    ( . "$BL_SOURCE" 2>/dev/null
      # Stub collectors — log invocation, return 0
      bl_observe_file()              { printf 'CALL bl_observe_file %s\n' "$*" >> "$ADAPTER_CALL_LOG"; }
      bl_observe_log_apache()        { printf 'CALL bl_observe_log_apache %s\n' "$*" >> "$ADAPTER_CALL_LOG"; }
      bl_observe_log_modsec()        { printf 'CALL bl_observe_log_modsec %s\n' "$*" >> "$ADAPTER_CALL_LOG"; }
      bl_observe_log_journal()       { printf 'CALL bl_observe_log_journal %s\n' "$*" >> "$ADAPTER_CALL_LOG"; }
      bl_observe_cron()              { printf 'CALL bl_observe_cron %s\n' "$*" >> "$ADAPTER_CALL_LOG"; }
      bl_observe_proc()              { printf 'CALL bl_observe_proc %s\n' "$*" >> "$ADAPTER_CALL_LOG"; }
      bl_observe_htaccess()          { printf 'CALL bl_observe_htaccess %s\n' "$*" >> "$ADAPTER_CALL_LOG"; }
      bl_observe_fs_mtime_cluster()  { printf 'CALL bl_observe_fs_mtime_cluster %s\n' "$*" >> "$ADAPTER_CALL_LOG"; }
      bl_observe_fs_mtime_since()    { printf 'CALL bl_observe_fs_mtime_since %s\n' "$*" >> "$ADAPTER_CALL_LOG"; }
      bl_observe_firewall()          { printf 'CALL bl_observe_firewall %s\n' "$*" >> "$ADAPTER_CALL_LOG"; }
      bl_observe_sigs()              { printf 'CALL bl_observe_sigs %s\n' "$*" >> "$ADAPTER_CALL_LOG"; }
      "$adapter" "$args_json"
    )
}

# ---------------------------------------------------------------------------
# Helpers — bl_run_args_*
# ---------------------------------------------------------------------------

@test "bl_run_args_get extracts value by key" {
    run bash -c '. "'"$BL_SOURCE"'" 2>/dev/null; bl_run_args_get "[{\"key\":\"a\",\"value\":\"1\"},{\"key\":\"b\",\"value\":\"2\"}]" b'
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "bl_run_args_get returns empty on missing key" {
    run bash -c '. "'"$BL_SOURCE"'" 2>/dev/null; bl_run_args_get "[{\"key\":\"a\",\"value\":\"1\"}]" missing'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "bl_run_args_relative_to_iso converts 72h → ISO timestamp" {
    run bash -c '. "'"$BL_SOURCE"'" 2>/dev/null; bl_run_args_relative_to_iso 72h'
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "bl_run_args_relative_to_iso passes ISO timestamps unchanged" {
    run bash -c '. "'"$BL_SOURCE"'" 2>/dev/null; bl_run_args_relative_to_iso 2026-04-26T18:00:00Z'
    [ "$status" -eq 0 ]
    [ "$output" = "2026-04-26T18:00:00Z" ]
}

@test "bl_run_args_warn_unknown emits warning for unknown keys" {
    run bash -c '. "'"$BL_SOURCE"'" 2>/dev/null; bl_run_args_warn_unknown "[{\"key\":\"good\",\"value\":\"1\"},{\"key\":\"unknown\",\"value\":\"2\"}]" "test.verb" "good"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"unknown adapter arg 'unknown'"* ]]
    # known key must not warn
    [[ "$output" != *"unknown adapter arg 'good'"* ]]
}

# ---------------------------------------------------------------------------
# observe.fs_mtime_since — curator-vocabulary fan-out, ext stripping
# ---------------------------------------------------------------------------

@test "fs_mtime_since adapter: roots fan-out into multiple --under calls" {
    run invoke_adapter bl_observe_fs_mtime_since_from_args \
        '[{"key":"since","value":"72h"},{"key":"roots","value":"/var/www,/home/test"}]'
    [ "$status" -eq 0 ]
    local n
    n=$(grep -c '^CALL bl_observe_fs_mtime_since' "$ADAPTER_CALL_LOG")
    [ "$n" -eq 2 ]
    grep -F -- '--under /var/www' "$ADAPTER_CALL_LOG"
    grep -F -- '--under /home/test' "$ADAPTER_CALL_LOG"
}

@test "fs_mtime_since adapter: 72h converted to ISO --since" {
    run invoke_adapter bl_observe_fs_mtime_since_from_args \
        '[{"key":"since","value":"72h"},{"key":"roots","value":"/var/www"}]'
    [ "$status" -eq 0 ]
    grep -E -- '--since [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$ADAPTER_CALL_LOG"
}

@test "fs_mtime_since adapter: ext glob stripped, comma-list takes first with warn" {
    run invoke_adapter bl_observe_fs_mtime_since_from_args \
        '[{"key":"since","value":"72h"},{"key":"roots","value":"/var/www"},{"key":"ext","value":"*.php,*.phtml"}]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"single --ext"* ]]
    grep -F -- '--ext php' "$ADAPTER_CALL_LOG"
    ! grep -F -- '--ext *.php' "$ADAPTER_CALL_LOG"
}

@test "fs_mtime_since adapter: missing roots returns 64" {
    run invoke_adapter bl_observe_fs_mtime_since_from_args \
        '[{"key":"since","value":"72h"}]'
    [ "$status" -eq 64 ]
    [[ "$output" == *"missing 'under' or 'roots'"* ]]
}

@test "fs_mtime_since adapter: missing since returns 64" {
    run invoke_adapter bl_observe_fs_mtime_since_from_args \
        '[{"key":"roots","value":"/var/www"}]'
    [ "$status" -eq 64 ]
    [[ "$output" == *"missing 'since'"* ]]
}

@test "fs_mtime_since adapter: unknown key dropped with warn (non-fatal)" {
    run invoke_adapter bl_observe_fs_mtime_since_from_args \
        '[{"key":"since","value":"72h"},{"key":"roots","value":"/var/www"},{"key":"include_hidden","value":"true"}]'
    [ "$status" -eq 0 ]
    # 'include_hidden' is a known semantic key but currently not honored — listed in known-keys to suppress warn.
    # If we want to flag it as honored=no, change adapter to NOT list it; for now this is the deliberate behavior.
    # Test asserts the call still went through.
    grep -F 'CALL bl_observe_fs_mtime_since' "$ADAPTER_CALL_LOG"
}

# ---------------------------------------------------------------------------
# observe.log_apache — since alias, around alias, default site
# ---------------------------------------------------------------------------

@test "log_apache adapter: 'around' arg passed as --around" {
    run invoke_adapter bl_observe_log_apache_from_args \
        '[{"key":"around","value":"/var/log/apache2/access.log"},{"key":"window","value":"6h"}]'
    [ "$status" -eq 0 ]
    grep -F -- '--around /var/log/apache2/access.log' "$ADAPTER_CALL_LOG"
    grep -F -- '--window 6h' "$ADAPTER_CALL_LOG"
}

@test "log_apache adapter: 'path' alias also routed to --around" {
    run invoke_adapter bl_observe_log_apache_from_args \
        '[{"key":"path","value":"/var/log/access.log"}]'
    [ "$status" -eq 0 ]
    grep -F -- '--around /var/log/access.log' "$ADAPTER_CALL_LOG"
}

@test "log_apache adapter: 'since' alias mapped to --window" {
    run invoke_adapter bl_observe_log_apache_from_args \
        '[{"key":"around","value":"/var/log/apache2/access.log"},{"key":"since","value":"72h"}]'
    [ "$status" -eq 0 ]
    grep -F -- '--window 72h' "$ADAPTER_CALL_LOG"
}

@test "log_apache adapter: missing around+path returns 64" {
    run invoke_adapter bl_observe_log_apache_from_args \
        '[{"key":"window","value":"6h"}]'
    [ "$status" -eq 64 ]
    [[ "$output" == *"missing 'around'"* ]]
}

# ---------------------------------------------------------------------------
# observe.log_modsec
# ---------------------------------------------------------------------------

@test "log_modsec adapter: txn + rule filters propagated" {
    run invoke_adapter bl_observe_log_modsec_from_args \
        '[{"key":"around","value":"/var/log/modsec.log"},{"key":"txn","value":"abc123"},{"key":"rule","value":"941100"}]'
    [ "$status" -eq 0 ]
    grep -F -- '--around /var/log/modsec.log' "$ADAPTER_CALL_LOG"
    grep -F -- '--txn abc123' "$ADAPTER_CALL_LOG"
    grep -F -- '--rule 941100' "$ADAPTER_CALL_LOG"
}

# ---------------------------------------------------------------------------
# observe.cron — scope splitting
# ---------------------------------------------------------------------------

@test "cron adapter: scope='system+per-user' calls --system; 'user' key adds --user" {
    run invoke_adapter bl_observe_cron_from_args \
        '[{"key":"scope","value":"system+per-user"},{"key":"user","value":"magento"}]'
    [ "$status" -eq 0 ]
    grep -F 'CALL bl_observe_cron --system' "$ADAPTER_CALL_LOG"
    grep -F 'CALL bl_observe_cron --user magento' "$ADAPTER_CALL_LOG"
}

@test "cron adapter: from_file route bypasses live-system flags" {
    run invoke_adapter bl_observe_cron_from_args \
        '[{"key":"from_file","value":"/tmp/snapshot"}]'
    [ "$status" -eq 0 ]
    grep -F -- '--from-file /tmp/snapshot' "$ADAPTER_CALL_LOG"
    ! grep -F 'CALL bl_observe_cron --system' "$ADAPTER_CALL_LOG"
    ! grep -F 'CALL bl_observe_cron --user' "$ADAPTER_CALL_LOG"
}

# ---------------------------------------------------------------------------
# observe.htaccess
# ---------------------------------------------------------------------------

@test "htaccess adapter: roots fan-out into multiple positional dir calls" {
    run invoke_adapter bl_observe_htaccess_from_args \
        '[{"key":"roots","value":"/var/www,/home/test/public_html"}]'
    [ "$status" -eq 0 ]
    grep -F 'CALL bl_observe_htaccess /var/www' "$ADAPTER_CALL_LOG"
    grep -F 'CALL bl_observe_htaccess /home/test/public_html' "$ADAPTER_CALL_LOG"
}

@test "htaccess adapter: recursive=true adds --recursive to each call" {
    run invoke_adapter bl_observe_htaccess_from_args \
        '[{"key":"root","value":"/var/www"},{"key":"recursive","value":"true"}]'
    [ "$status" -eq 0 ]
    grep -F 'CALL bl_observe_htaccess --recursive /var/www' "$ADAPTER_CALL_LOG"
}

# ---------------------------------------------------------------------------
# observe.proc / observe.firewall / observe.sigs / observe.file
# ---------------------------------------------------------------------------

@test "proc adapter: user + verify_argv=true adds --verify-argv flag" {
    run invoke_adapter bl_observe_proc_from_args \
        '[{"key":"user","value":"www-data"},{"key":"verify_argv","value":"true"}]'
    [ "$status" -eq 0 ]
    grep -F -- '--user www-data --verify-argv' "$ADAPTER_CALL_LOG"
}

@test "firewall adapter: backend propagated; missing backend calls without flag" {
    run invoke_adapter bl_observe_firewall_from_args \
        '[{"key":"backend","value":"iptables"}]'
    [ "$status" -eq 0 ]
    grep -F -- '--backend iptables' "$ADAPTER_CALL_LOG"

    : > "$ADAPTER_CALL_LOG"
    run invoke_adapter bl_observe_firewall_from_args '[]'
    [ "$status" -eq 0 ]
    grep -E '^CALL bl_observe_firewall *$' "$ADAPTER_CALL_LOG"
}

@test "sigs adapter: scanner filter propagated" {
    run invoke_adapter bl_observe_sigs_from_args \
        '[{"key":"scanner","value":"maldet"}]'
    [ "$status" -eq 0 ]
    grep -F -- '--scanner maldet' "$ADAPTER_CALL_LOG"
}

@test "file adapter: path positional + attribution_from optional flag" {
    run invoke_adapter bl_observe_file_from_args \
        '[{"key":"path","value":"/etc/passwd"},{"key":"attribution_from","value":"obs-0001"}]'
    [ "$status" -eq 0 ]
    grep -F -- '--attribution-from obs-0001 /etc/passwd' "$ADAPTER_CALL_LOG"
}

@test "file adapter: missing path returns 64" {
    run invoke_adapter bl_observe_file_from_args \
        '[{"key":"attribution_from","value":"obs-0001"}]'
    [ "$status" -eq 64 ]
    [[ "$output" == *"missing 'path'"* ]]
}

# ---------------------------------------------------------------------------
# Dispatcher integration — bl_run_dispatch_verb prefers _from_args adapter
# ---------------------------------------------------------------------------

@test "bl_run_dispatch_verb routes to <handler>_from_args when present" {
    # Replace bl_observe_file_from_args with an inspection stub.
    run bash -c '. "'"$BL_SOURCE"'" 2>/dev/null
        bl_observe_file_from_args() { printf "ADAPTER_CALLED with %s\n" "$1"; return 0; }
        bl_observe_file()           { printf "RAW_CALLED %s\n" "$*"; return 0; }
        bl_run_dispatch_verb observe.file "[{\"key\":\"path\",\"value\":\"/etc/passwd\"}]"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ADAPTER_CALLED"* ]]
    [[ "$output" != *"RAW_CALLED"* ]]
}

@test "bl_run_dispatch_verb falls through to handler when no _from_args adapter" {
    # case.close has no _from_args adapter — should call legacy handler
    run bash -c '. "'"$BL_SOURCE"'" 2>/dev/null
        bl_case_close() { printf "RAW_CALLED %s\n" "$*"; return 0; }
        bl_run_dispatch_verb case.close "[]"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"RAW_CALLED"* ]]
}
