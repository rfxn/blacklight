#!/usr/bin/env bats
# tests/04-observe-scale.bats — M12 P2 large-corpus assembly + determinism
# Validates the tools/synth-corpus.sh + exhibits/fleet-01/large-corpus pair.
# Three gates: 300k-400k token band, byte-deterministic regeneration, zero
# operator-local-token leakage.

setup() {
    BL_REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export BL_REPO_ROOT
}

@test "synth-corpus emits deterministic 300k-400k token bundle" {
    local out
    out=$(mktemp -d)
    run "$BL_REPO_ROOT/tools/synth-corpus.sh" --seed 42 --out "$out"
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
    "$BL_REPO_ROOT/tools/synth-corpus.sh" --seed 42 --out "$out1" >/dev/null
    "$BL_REPO_ROOT/tools/synth-corpus.sh" --seed 42 --out "$out2" >/dev/null
    local sha1 sha2
    sha1=$(sha256sum "$out1/apache.access.log" | awk '{print $1}')
    sha2=$(sha256sum "$out2/apache.access.log" | awk '{print $1}')
    [ "$sha1" = "$sha2" ]
    rm -rf "$out1" "$out2"
}

@test "synth-corpus has zero operator-local-token leakage" {
    local out
    out=$(mktemp -d)
    "$BL_REPO_ROOT/tools/synth-corpus.sh" --seed 42 --out "$out" >/dev/null
    # grep returns 1 on no-match — that is the success path for this gate
    run grep -rE '(rfxn|liquidweb|sigforge|polyshell|customer)' "$out"
    [ "$status" -ne 0 ]
    rm -rf "$out"
}
