# tests/helpers/lmd-mock.bash — LMD env injection + fixture pointer for 14-trigger-lmd.bats

_lmd_setup_session() {
    local fixture_name="${1:-lmd-session-tsv-7-hits.tsv}"
    export LMD_SCANID="SCAN-26-0414-2014-1234"
    export LMD_HITS="7"
    export LMD_SESSION_FILE="$BATS_TEST_DIRNAME/fixtures/$fixture_name"
}

_lmd_mock_unset() {
    unset LMD_SCANID LMD_HITS LMD_SESSION_FILE LMD_VERSION LMD_BASEDIR BL_INVOKED_BY
}

_lmd_seed_agent_id() {
    mkdir -p "$BL_VAR_DIR/state"
    printf 'test-agent-12345' > "$BL_VAR_DIR/state/agent-id"
}
