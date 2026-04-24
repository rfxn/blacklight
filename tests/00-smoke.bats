#!/usr/bin/env bats
# tests/00-smoke.bats — floor smoke tests for bl
# Consumed by tests/run-tests.sh via batsman infrastructure.

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
}

@test "bl parses clean with bash -n" {
    run bash -n "$BL_SOURCE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "bl --version prints expected format" {
    export BL_VAR_DIR="$(mktemp -d)"
    run "$BL_SOURCE" --version
    rm -rf "$BL_VAR_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^bl\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}
