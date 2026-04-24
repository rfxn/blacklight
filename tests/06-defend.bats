#!/usr/bin/env bats
# tests/06-defend.bats — M6 bl defend coverage (modsec, firewall, sig)
#
# Fixture-driven; no live API, no real scanner daemons. Netfilter-apply
# scenarios gate on $BL_DEFEND_PRIVILEGED.

load 'helpers/bl-preflight-mock.bash'
load 'helpers/defend-fixture.bash'
load 'helpers/assert-jsonl.bash'

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    BL_VAR_DIR="$(mktemp -d)"
    export BL_VAR_DIR
    export BL_REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export ANTHROPIC_API_KEY="sk-ant-test"
    # Netfilter actually-applies assertions gate on capability probe.
    BL_DEFEND_PRIVILEGED="no"
    [[ -w /proc/sys/net/ipv4/ip_forward ]] 2>/dev/null && BL_DEFEND_PRIVILEGED="yes"   # unprivileged container returns EPERM on write test; default "no" is correct
    export BL_DEFEND_PRIVILEGED
    # Preflight mock: curl shim returns agent_test_stub for GET /v1/agents probe
    bl_mock_init
    bl_mock_set_response populated
    bl_defend_fixture_init "shared"
    # Seed state dir: agent-id (preflight cache bypass) + active case (ledger case-tag)
    mkdir -p "$BL_VAR_DIR/state"
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
    printf 'CASE-2026-0042' > "$BL_VAR_DIR/state/case.current"
}

teardown() {
    bl_mock_teardown 2>/dev/null || true   # idempotent; mock init may be partial
    bl_defend_fixture_teardown
}

# ---------------------------------------------------------------------------
# modsec
# ---------------------------------------------------------------------------

@test "bl defend modsec applies rule + configtest + symlink swap (happy path)" {
    bl_defend_fixture_mock_apachectl pass
    run "$BL_SOURCE" defend modsec "$BATS_TEST_DIRNAME/fixtures/defend-modsec-rule.conf" --reason "apsb25-94 eval"
    [ "$status" -eq 0 ]
    [ -L "$BL_DEFEND_APACHE_CONFDIR/bl-rules.conf" ]
    local target
    target=$(readlink "$BL_DEFEND_APACHE_CONFDIR/bl-rules.conf")
    [[ "$target" == "bl-rules-v1.conf" ]]
    [ -f "$BL_DEFEND_APACHE_CONFDIR/bl-rules-v1.conf" ]
}

@test "bl defend modsec configtest-fail rolls back (no leftover file)" {
    bl_defend_fixture_mock_apachectl fail
    run "$BL_SOURCE" defend modsec "$BATS_TEST_DIRNAME/fixtures/defend-modsec-rule.conf"
    [ "$status" -eq 65 ]   # BL_EX_PREFLIGHT_FAIL
    # The new versioned file must not exist — rollback cleaned it up
    [ ! -f "$BL_DEFEND_APACHE_CONFDIR/bl-rules-v1.conf" ]
    # No live symlink created on first-apply rollback
    [ ! -L "$BL_DEFEND_APACHE_CONFDIR/bl-rules.conf" ]
}

@test "bl defend modsec version increments across applies" {
    bl_defend_fixture_mock_apachectl pass
    run "$BL_SOURCE" defend modsec "$BATS_TEST_DIRNAME/fixtures/defend-modsec-rule.conf"
    [ "$status" -eq 0 ]
    run "$BL_SOURCE" defend modsec "$BATS_TEST_DIRNAME/fixtures/defend-modsec-rule.conf"
    [ "$status" -eq 0 ]
    local target
    target=$(readlink "$BL_DEFEND_APACHE_CONFDIR/bl-rules.conf")
    [[ "$target" == "bl-rules-v2.conf" ]]
}

@test "bl defend modsec --remove without --yes refuses" {
    bl_defend_fixture_mock_apachectl pass
    "$BL_SOURCE" defend modsec "$BATS_TEST_DIRNAME/fixtures/defend-modsec-rule.conf" >/dev/null 2>&1   # seed v1
    run "$BL_SOURCE" defend modsec 900001 --remove
    [ "$status" -eq 68 ]   # BL_EX_TIER_GATE_DENIED
}

@test "bl defend modsec --remove --yes removes rule by id" {
    bl_defend_fixture_mock_apachectl pass
    "$BL_SOURCE" defend modsec "$BATS_TEST_DIRNAME/fixtures/defend-modsec-rule.conf" >/dev/null 2>&1   # seed v1 (id:900001)
    run "$BL_SOURCE" defend modsec 900001 --remove --yes --reason "false positive"
    [ "$status" -eq 0 ]
    local target
    target=$(readlink "$BL_DEFEND_APACHE_CONFDIR/bl-rules.conf")
    [[ "$target" == "bl-rules-v2.conf" ]]
    ! grep -q "id:900001" "$BL_DEFEND_APACHE_CONFDIR/bl-rules-v2.conf"
}

@test "bl defend modsec emits schema-conforming ledger entry" {
    bl_defend_fixture_mock_apachectl pass
    run "$BL_SOURCE" defend modsec "$BATS_TEST_DIRNAME/fixtures/defend-modsec-rule.conf" --reason "apsb25-94"
    [ "$status" -eq 0 ]
    local ledger="$BL_VAR_DIR/ledger/CASE-2026-0042.jsonl"
    [ -s "$ledger" ]
    # Validate last line against schema via jq subset
    local last_record schema="$BL_REPO_ROOT/schemas/ledger-entry.json"
    last_record=$(tail -n1 "$ledger")
    printf '%s' "$last_record" | jq -e '
        .ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
    ' >/dev/null
    printf '%s' "$last_record" | jq -e '.case | test("^CASE-[0-9]{4}-[0-9]{4}$")' >/dev/null
    printf '%s' "$last_record" | jq -e '.kind == "defend_applied"' >/dev/null
    printf '%s' "$last_record" | jq -e '.payload.verb == "defend.modsec"' >/dev/null
}

# ---------------------------------------------------------------------------
# firewall (M6 P3)
# ---------------------------------------------------------------------------

@test "bl defend firewall applies via iptables with case-tag" {
    # Mock iptables into PATH-injected bin to capture invocation.
    # Use --backend iptables to bypass auto-detection (system may have nft).
    cat > "$BL_DEFEND_SCANNER_BIN/iptables" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$BL_VAR_DIR/iptables.log"
exit 0
EOF
    chmod +x "$BL_DEFEND_SCANNER_BIN/iptables"
    export PATH="$BL_DEFEND_SCANNER_BIN:$PATH"
    run "$BL_SOURCE" defend firewall 203.0.113.42 --backend iptables --reason "apsb25-94 scanner"
    [ "$status" -eq 0 ]
    grep -q 'INPUT -s 203.0.113.42 -j DROP' "$BL_VAR_DIR/iptables.log"
    grep -q "bl-CASE-2026-0042:apsb25-94 scanner" "$BL_VAR_DIR/iptables.log"
}

@test "bl defend firewall CDN-safelist refuses Cloudflare IP (ASN cache hit)" {
    # Seed ASN cache with Cloudflare hit for 1.1.1.1
    bl_defend_fixture_mock_whois 1.1.1.1 '{"asn":"AS13335","org":"CLOUDFLARENET"}'
    # Pre-populate cache with fresh timestamp
    touch "$BL_DEFEND_ASN_CACHE/1.1.1.1.json"
    # Provide an iptables shim (must not be invoked — safelist should short-circuit)
    cat > "$BL_DEFEND_SCANNER_BIN/iptables" <<'EOF'
#!/bin/bash
printf 'UNEXPECTED: %s\n' "$*" >> "$BL_VAR_DIR/iptables.log"
exit 0
EOF
    chmod +x "$BL_DEFEND_SCANNER_BIN/iptables"
    export PATH="$BL_DEFEND_SCANNER_BIN:$PATH"
    run "$BL_SOURCE" defend firewall 1.1.1.1 --reason "bad actor"
    [ "$status" -eq 68 ]   # BL_EX_TIER_GATE_DENIED
    [ ! -s "$BL_VAR_DIR/iptables.log" ]   # apply must not have run
    # Ledger must show a defend_refused record
    local ledger="$BL_VAR_DIR/ledger/CASE-2026-0042.jsonl"
    grep -q '"kind":"defend_refused"' "$ledger"
    grep -q '"reason":"cdn_safelist"' "$ledger"
}

@test "bl defend firewall backend auto-detection prefers APF > iptables" {
    # Provide both apf and iptables shims; expect apf to be chosen
    cat > "$BL_DEFEND_SCANNER_BIN/apf" <<'EOF'
#!/bin/bash
printf 'apf:%s\n' "$*" >> "$BL_VAR_DIR/backend.log"
exit 0
EOF
    cat > "$BL_DEFEND_SCANNER_BIN/iptables" <<'EOF'
#!/bin/bash
printf 'iptables:%s\n' "$*" >> "$BL_VAR_DIR/backend.log"
exit 0
EOF
    chmod +x "$BL_DEFEND_SCANNER_BIN/apf" "$BL_DEFEND_SCANNER_BIN/iptables"
    export PATH="$BL_DEFEND_SCANNER_BIN:$PATH"
    run "$BL_SOURCE" defend firewall 198.51.100.77 --reason "test"
    [ "$status" -eq 0 ]
    grep -q '^apf:' "$BL_VAR_DIR/backend.log"
    ! grep -q '^iptables:' "$BL_VAR_DIR/backend.log"
}

@test "bl defend firewall emits schema-conforming ledger entry on success" {
    # Use --backend iptables to bypass auto-detection (system may have nft).
    cat > "$BL_DEFEND_SCANNER_BIN/iptables" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$BL_DEFEND_SCANNER_BIN/iptables"
    export PATH="$BL_DEFEND_SCANNER_BIN:$PATH"
    run "$BL_SOURCE" defend firewall 203.0.113.50 --backend iptables --reason "test" --retire 7d
    [ "$status" -eq 0 ]
    local ledger="$BL_VAR_DIR/ledger/CASE-2026-0042.jsonl"
    local last
    last=$(tail -n1 "$ledger")
    printf '%s' "$last" | jq -e '.kind == "defend_applied"' >/dev/null
    printf '%s' "$last" | jq -e '.payload.verb == "defend.firewall"' >/dev/null
    printf '%s' "$last" | jq -e '.payload.retire_hint == "7d"' >/dev/null
}

# ---------------------------------------------------------------------------
# sig (M6 P4)
# ---------------------------------------------------------------------------

@test "bl defend sig FP-gate-trip rejects on corpus match (TODO P4)" { skip "implemented in M6 P4"; }
@test "bl defend sig happy-path appends to scanner sig file (TODO P4)" { skip "implemented in M6 P4"; }
@test "bl defend sig auto-tier only if FP-gate passes (TODO P4)" { skip "implemented in M6 P4"; }
