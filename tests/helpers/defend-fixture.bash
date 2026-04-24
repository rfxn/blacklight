# tests/helpers/defend-fixture.bash — M6 bl defend test scaffolding
#
# Materializes per-test Apache conf dir, FP-corpus, mock scanner binaries,
# and firewall-backend stubs under $BL_VAR_DIR. Consumed by 06-defend.bats.

bl_defend_fixture_init() {
    # $1 = scenario name (modsec|firewall|sig)
    local scenario="$1"
    BL_DEFEND_APACHE_CONFDIR="$BL_VAR_DIR/apache-confd"
    BL_DEFEND_FP_CORPUS="$BL_VAR_DIR/fp-corpus"
    BL_DEFEND_SCANNER_BIN="$BL_VAR_DIR/scanner-bin"
    BL_DEFEND_ASN_CACHE="$BL_VAR_DIR/asn-cache"
    mkdir -p "$BL_DEFEND_APACHE_CONFDIR" "$BL_DEFEND_FP_CORPUS" \
             "$BL_DEFEND_SCANNER_BIN" "$BL_DEFEND_ASN_CACHE"
    # Seed FP-corpus from fixtures
    cp "$BATS_TEST_DIRNAME/fixtures/defend-fp-corpus/"* "$BL_DEFEND_FP_CORPUS/"
    export BL_DEFEND_APACHE_CONFDIR BL_DEFEND_FP_CORPUS \
           BL_DEFEND_SCANNER_BIN BL_DEFEND_ASN_CACHE
}

bl_defend_fixture_mock_apachectl() {
    # $1 = pass|fail — controls apachectl -t exit code
    local mode="$1"
    cat > "$BL_DEFEND_SCANNER_BIN/apachectl" <<EOF
#!/bin/bash
case "\$1" in
    configtest|-t)  [ "$mode" = pass ] ; exit \$? ;;
    graceful)       exit 0 ;;
    *)              exit 0 ;;
esac
EOF
    chmod +x "$BL_DEFEND_SCANNER_BIN/apachectl"
    # PATH-inject BEFORE system paths
    export PATH="$BL_DEFEND_SCANNER_BIN:$PATH"
}

bl_defend_fixture_mock_whois() {
    # $1 = ip   $2 = asn-json (e.g., '{"asn":"AS13335","org":"CLOUDFLARENET"}' for safelist hit)
    local ip="$1" asn_json="$2"
    printf '%s' "$asn_json" > "$BL_DEFEND_ASN_CACHE/$ip.json"
    cat > "$BL_DEFEND_SCANNER_BIN/whois" <<EOF
#!/bin/bash
# Mock whois: prints fixture-shaped output so ASN lookup succeeds.
# Real lookup is bypassed by $BL_DEFEND_ASN_CACHE/$ip.json cache.
exit 0
EOF
    chmod +x "$BL_DEFEND_SCANNER_BIN/whois"
    export PATH="$BL_DEFEND_SCANNER_BIN:$PATH"
}

bl_defend_fixture_teardown() {
    # Paranoia: unset exports that may bleed between tests
    unset BL_DEFEND_APACHE_CONFDIR BL_DEFEND_FP_CORPUS \
          BL_DEFEND_SCANNER_BIN BL_DEFEND_ASN_CACHE
}
