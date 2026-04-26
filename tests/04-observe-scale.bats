#!/usr/bin/env bats
# tests/04-observe-scale.bats — M12 P2 large-corpus assembly + determinism;
# M13 P7 threshold-rotate lifecycle for fs + cron collectors.
# Three synth-corpus gates: 300k-400k token band, byte-deterministic regeneration, zero
# operator-local-token leakage. Two threshold-rotate gates: first-call rotate fires;
# per-call sources (cron) rotate on every call.

load 'helpers/curator-mock'
load 'helpers/observe-fixture-setup'
load 'helpers/bl-preflight-mock'

setup() {
    BL_REPO_ROOT="$BATS_TEST_DIRNAME/.."
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    export BL_REPO_ROOT BL_SOURCE
    setup_observe_case CASE-2026-0001
    bl_mock_init
    bl_mock_set_response populated
}

teardown() {
    bl_mock_teardown
    teardown_observe_case
}

@test "synth-corpus emits deterministic 300k-400k token bundle" {
    local out
    out=$(mktemp -d)
    run "$BL_REPO_ROOT/scripts/dev/synth-corpus.sh" --seed 42 --out "$out"
    [ "$status" -eq 0 ]
    # token band check: 1.2M-1.7M chars at ~4 chars/token = 300k-425k tokens
    local total
    total=$(find "$out" -type f -print0 | xargs -0 wc -c | tail -1 | awk '{print $1}')
    [ "$total" -ge 1200000 ]
    [ "$total" -le 1700000 ]
    rm -rf "$out"
}

@test "synth-corpus regeneration with same seed is byte-identical" {
    local out1 out2
    out1=$(mktemp -d)
    out2=$(mktemp -d)
    "$BL_REPO_ROOT/scripts/dev/synth-corpus.sh" --seed 42 --out "$out1" >/dev/null
    "$BL_REPO_ROOT/scripts/dev/synth-corpus.sh" --seed 42 --out "$out2" >/dev/null
    local sha1 sha2
    sha1=$(sha256sum "$out1/apache.access.log" | awk '{print $1}')
    sha2=$(sha256sum "$out2/apache.access.log" | awk '{print $1}')
    [ "$sha1" = "$sha2" ]
    rm -rf "$out1" "$out2"
}

@test "synth-corpus has zero operator-local-token leakage" {
    local out
    out=$(mktemp -d)
    "$BL_REPO_ROOT/scripts/dev/synth-corpus.sh" --seed 42 --out "$out" >/dev/null
    # grep returns 1 on no-match — that is the success path for this gate
    run grep -rE '(rfxn|liquidweb|sigforge|polyshell|customer)' "$out"
    [ "$status" -ne 0 ]
    rm -rf "$out"
}

# ---------------------------------------------------------------------------
# Threshold-rotate gates (M13 P7) — first-call rotate fires for fs + cron
# ---------------------------------------------------------------------------

@test "bl observe fs mtime-since: first-call threshold fires → upload.json written" {
    # Route Files API → valid file_id response so rotate completes
    bl_curator_mock_init
    bl_curator_mock_set_response 'files-api-create.json' 200

    local since_dir
    since_dir="$BL_VAR_DIR/since_threshold"
    mkdir -p "$since_dir"
    touch -d "2026-04-24 00:00:01 UTC" "$since_dir/new_file.php"

    # Pre-seed the stable evidence accumulator that bl_observe_evidence_threshold_check
    # reads. Without it the check returns 1 (no evidence yet). First-call path (no upload.json)
    # triggers rotate regardless of line count; at least 1 line required for file to exist.
    local ev_file="$BL_VAR_DIR/cases/CASE-2026-0001/evidence/fs.json"
    printf '{"ts":"2026-04-24T00:00:01Z","source":"fs.mtime_since","record":{"n":1}}\n' > "$ev_file"

    run env BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="sk-ant-test" BL_HOST_LABEL="fleet-01-host-99" \
        "$BL_SOURCE" observe fs --mtime-since \
            --since "2026-04-23T23:00:00Z" \
            --under "$since_dir"
    [ "$status" -eq 0 ]
    # First-call rotate: upload.json must exist (source label is "fs" for both fs sub-verbs)
    [ -f "$BL_VAR_DIR/cases/CASE-2026-0001/evidence/fs.upload.json" ]
}

@test "bl observe cron: per-call threshold fires every invocation → upload.json written" {
    # cron is a per-call source (count_threshold=1); rotate fires on every call
    bl_curator_mock_init
    bl_curator_mock_set_response 'files-api-create.json' 200

    # Pre-seed stable evidence accumulator for cron (threshold=1 line)
    local ev_file="$BL_VAR_DIR/cases/CASE-2026-0001/evidence/cron.json"
    printf '{"ts":"2026-04-24T00:00:01Z","source":"cron.entry","record":{"n":1}}\n' > "$ev_file"

    run env BL_VAR_DIR="$BL_VAR_DIR" ANTHROPIC_API_KEY="sk-ant-test" BL_HOST_LABEL="fleet-01-host-99" \
        "$BL_SOURCE" observe cron --system
    [ "$status" -eq 0 ]
    # After first call: upload.json must exist (per-call threshold = 1)
    [ -f "$BL_VAR_DIR/cases/CASE-2026-0001/evidence/cron.upload.json" ]
}
