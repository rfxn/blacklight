#!/usr/bin/env bats
# tests/01-cli-surface.bats — bl CLI surface (help/version/dispatch/unknown-verb)
# Consumed by tests/run-tests.sh via batsman infrastructure.

load 'helpers/capability-detect.bash'

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    export BL_REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export BL_VAR_DIR="$(mktemp -d)"
}

teardown() {
    [[ -n "${BL_VAR_DIR:-}" && -d "$BL_VAR_DIR" ]] && rm -rf "$BL_VAR_DIR"
}

@test "shellcheck is clean" {
    shellcheck_available || skip "shellcheck unavailable on this image (vault has no usable c6 build)"
    run shellcheck "$BL_SOURCE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "bl --help exits 0 and lists all command verbs" {
    run "$BL_SOURCE" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"observe"* ]]
    [[ "$output" == *"consult"* ]]
    [[ "$output" == *"run"* ]]
    [[ "$output" == *"case"* ]]
    [[ "$output" == *"defend"* ]]
    [[ "$output" == *"clean"* ]]
    [[ "$output" == *"setup"* ]]
    [[ "$output" == *"flush"* ]]
    [[ "$output" == *"trigger"* ]]
}

@test "bl --help includes trigger verb" {
    run "$BL_SOURCE" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"trigger"* ]]
}

@test "bl trigger --help: prints usage" {
    run "$BL_SOURCE" trigger --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"bl trigger lmd:"* ]]
    [[ "$output" == *"--scanid"* ]]
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

@test "bl setup dispatches to handler and bypasses bl_preflight (exits 65 on missing API key, not 66)" {
    # M8/M13 P6: setup is in the pre-case bypass list. Real handler now lands; the
    # bypass invariant is preserved (no preflight 66 on unseeded state) but
    # bl_setup_local_preflight surfaces missing ANTHROPIC_API_KEY as 65.
    # Verb required: bare 'bl setup' shows help (exit 0); --check invokes preflight.
    unset ANTHROPIC_API_KEY
    run "$BL_SOURCE" setup --check
    [ "$status" -eq 65 ]
    [[ "$output" == *"ANTHROPIC_API_KEY not set"* ]]
}

@test "bl observe + defend + clean are all real routers (post-M6+M7)" {
    # Pre-seed agent-id so preflight passes for non-setup verbs
    mkdir -p "$BL_VAR_DIR/state"
    printf '%s' "agent_test_stub" > "$BL_VAR_DIR/state/agent-id"
    export ANTHROPIC_API_KEY="sk-ant-test"
    # M4 landed: 'observe' is a real router (exits 64 with "missing sub-verb")
    run "$BL_SOURCE" observe
    [ "$status" -eq 64 ] || { echo "FAIL: observe returned $status"; return 1; }
    [[ "$output" == *"missing sub-verb"* ]] || { echo "FAIL: observe missing sub-verb msg"; return 1; }
    # M6 landed: 'defend' is a real router (exits 64 with "no sub-verb")
    run "$BL_SOURCE" defend
    [ "$status" -eq 64 ] || { echo "FAIL: defend returned $status"; return 1; }
    [[ "$output" == *"no sub-verb"* ]] || { echo "FAIL: defend missing no-sub-verb msg (got: $output)"; return 1; }
    # M7 landed: 'clean' is a real router (exits 64 with "missing subcommand")
    run "$BL_SOURCE" clean
    [ "$status" -eq 64 ] || { echo "FAIL: clean returned $status"; return 1; }
    [[ "$output" == *"missing subcommand"* ]] || { echo "FAIL: clean missing subcommand msg"; return 1; }
}

@test "bl consult/run/case dispatch to M5 handlers and exit 64 on missing args" {
    # M5 handlers implemented — no args → usage error (64), not stub message
    mkdir -p "$BL_VAR_DIR/state"
    printf '%s' "agent_test_stub" > "$BL_VAR_DIR/state/agent-id"
    printf '%s' "memstore_test_stub" > "$BL_VAR_DIR/state/memstore-case-id"
    export ANTHROPIC_API_KEY="sk-ant-test"
    export BL_VAR_DIR
    for ns in consult run; do
        run "$BL_SOURCE" "$ns"
        [ "$status" -eq 64 ] || { echo "FAIL: $ns returned $status (expected 64)"; return 1; }
    done
}

@test "bl flush --outbox routes to outbox drain" {
    # Pre-seed agent-id so preflight passes; flush is a non-bypass verb
    mkdir -p "$BL_VAR_DIR/state"
    printf '%s' "agent_test_stub" > "$BL_VAR_DIR/state/agent-id"
    export ANTHROPIC_API_KEY="sk-ant-test"
    run "$BL_SOURCE" flush --outbox
    [ "$status" -eq 0 ]
}

@test "bl flush without --outbox exits 64" {
    mkdir -p "$BL_VAR_DIR/state"
    printf '%s' "agent_test_stub" > "$BL_VAR_DIR/state/agent-id"
    export ANTHROPIC_API_KEY="sk-ant-test"
    run "$BL_SOURCE" flush
    [ "$status" -eq 64 ]
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

@test "bl <verb> --help dispatches per-verb (all verbs)" {
    for verb in observe consult run defend clean case setup flush trigger; do
        run "$BL_SOURCE" "$verb" --help
        [ "$status" -eq 0 ]
        [[ "$output" == bl*"$verb"*—* ]] || { echo "verb=$verb output=$output"; return 1; }
    done
}

@test "bl <verb> <subverb> --help bubbles up to verb-level help" {
    # Bubble-up shim: --help at any depth routes to bl_help_<verb>, so we
    # don't have to author per-subcommand help blocks. Sample the common
    # depth-2 / depth-3 invocations rather than enumerate every subverb.
    local cases=(
        "observe file --help"
        "observe log apache --help"
        "observe fs --mtime-cluster --help"
        "consult --new --help"
        "run observe.file --help"
        "defend firewall --help"
        "clean htaccess --help"
        "case show --help"
        "flush --outbox --help"
    )
    local c
    for c in "${cases[@]}"; do
        # shellcheck disable=SC2086 # intentional word-split on $c
        run "$BL_SOURCE" $c
        [ "$status" -eq 0 ] || { echo "case='$c' status=$status output=$output"; return 1; }
        local verb="${c%% *}"
        [[ "$output" == bl*"$verb"*—* ]] || { echo "case='$c' output=$output"; return 1; }
    done
}

@test "bl --version matches src/bl.d/00-header.sh BL_VERSION" {
    run "$BL_SOURCE" --version
    [ "$status" -eq 0 ]
    # Locate the source header; the container copies the full project to
    # /opt/blacklight-src while BL_SOURCE lives at /opt/bl.
    local header_file
    header_file="${BL_REPO_ROOT}/src/bl.d/00-header.sh"
    if [[ ! -r "$header_file" ]]; then
        header_file="/opt/blacklight-src/src/bl.d/00-header.sh"
    fi
    src_ver=$(grep -oE 'readonly BL_VERSION="[^"]+"' "$header_file" | awk -F'"' '{print $2}')
    [[ "$output" == "bl $src_ver" ]]
}

@test "bl unknown-verb --help rejects with usage error" {
    run "$BL_SOURCE" bogus-verb --help
    [ "$status" -eq 64 ]
    [[ "$output" == *"unknown command"* ]]
}
