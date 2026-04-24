#!/usr/bin/env bats
# tests/01-cli-surface.bats — bl CLI surface (help/version/dispatch/unknown-verb)
# Consumed by tests/run-tests.sh via batsman infrastructure.

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    export BL_VAR_DIR="$(mktemp -d)"
}

teardown() {
    [[ -n "${BL_VAR_DIR:-}" && -d "$BL_VAR_DIR" ]] && rm -rf "$BL_VAR_DIR"
}

@test "shellcheck is clean" {
    run shellcheck "$BL_SOURCE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "bl --help exits 0 and lists all 7 namespaces" {
    run "$BL_SOURCE" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"observe"* ]]
    [[ "$output" == *"consult"* ]]
    [[ "$output" == *"run"* ]]
    [[ "$output" == *"case"* ]]
    [[ "$output" == *"defend"* ]]
    [[ "$output" == *"clean"* ]]
    [[ "$output" == *"setup"* ]]
}

@test "bl help exits 0 (positional form)" {
    run "$BL_SOURCE" help
    [ "$status" -eq 0 ]
}

@test "bl -h exits 0 (short form)" {
    run "$BL_SOURCE" -h
    [ "$status" -eq 0 ]
}

@test "bl --version exits 0 and prints version" {
    run "$BL_SOURCE" --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^bl\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "bl -v exits 0 (short form)" {
    run "$BL_SOURCE" -v
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^bl\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "bl setup dispatches to stub and exits 64 (bypasses preflight)" {
    # setup is in the pre-case bypass list; no API key / agent-id seed needed
    unset ANTHROPIC_API_KEY
    run "$BL_SOURCE" setup
    [ "$status" -eq 64 ]
    [[ "$output" == *"setup not yet implemented (M8)"* ]]
}

@test "bl observe/consult/run/defend/clean/case each dispatch to stub and exit 64 (parameterised)" {
    # Pre-seed agent-id so preflight passes for non-setup verbs
    mkdir -p "$BL_VAR_DIR/state"
    printf '%s' "agent_test_stub" > "$BL_VAR_DIR/state/agent-id"
    export ANTHROPIC_API_KEY="sk-ant-test"
    for ns in observe consult run defend clean case; do
        run "$BL_SOURCE" "$ns"
        [ "$status" -eq 64 ] || { echo "FAIL: $ns returned $status"; return 1; }
        [[ "$output" == *"not yet implemented"* ]] || { echo "FAIL: $ns missing stub msg"; return 1; }
    done
}

@test "bl <unknown-verb> exits 64 with usage hint" {
    mkdir -p "$BL_VAR_DIR/state"
    printf '%s' "agent_test_stub" > "$BL_VAR_DIR/state/agent-id"
    export ANTHROPIC_API_KEY="sk-ant-test"
    run "$BL_SOURCE" fnord
    [ "$status" -eq 64 ]
    [[ "$output" == *"unknown command: fnord"* ]]
}

@test "bl (no args) exits 64 with usage hint" {
    run "$BL_SOURCE"
    [ "$status" -eq 64 ]
    [[ "$output" == *"no command"* ]]
}
