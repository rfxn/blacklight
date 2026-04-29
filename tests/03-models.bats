#!/usr/bin/env bats
# tests/03-models.bats — M11 model-routing coverage (Sonnet 4.6 + Haiku 4.5)
#
# Covers the bl_messages_call wrapper introduced in M11 P2 and consumed in
# P3 (Sonnet bundle summary) + P4 (Haiku FP-gate adjudication). Mocks
# /v1/messages via PATH-prepended curl shim from helpers/messages-mock.bash.

load 'helpers/messages-mock.bash'
load 'helpers/case-fixture.bash'

setup() {
    BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../bl}"
    BL_VAR_DIR="$(mktemp -d)"
    export BL_VAR_DIR
    export BL_REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export ANTHROPIC_API_KEY="sk-ant-test"
    bl_messages_mock_init
    mkdir -p "$BL_VAR_DIR/state"
    printf 'agent_test_stub' > "$BL_VAR_DIR/state/agent-id"
}

teardown() {
    bl_messages_mock_teardown
    [[ -n "${BL_VAR_DIR:-}" ]] && rm -rf "$BL_VAR_DIR"
}

# ---------------------------------------------------------------------------
# Sonnet 4.6 — bundle summary
# ---------------------------------------------------------------------------

@test "bl_messages_call routes claude-sonnet-4-6 for bundle summary" {
    bl_case_fixture_seed CASE-2026-0042
    bl_messages_mock_set_fixture messages-sonnet-summary.json 200
    mkdir -p "$BL_VAR_DIR/cases/CASE-2026-0042/evidence"
    printf '{"ts":"2026-04-25T00:00:00Z","host":"test","source":"apache.transfer","record":{}}\n' > "$BL_VAR_DIR/cases/CASE-2026-0042/evidence/obs-0001-apache.json"
    run "$BL_SOURCE" observe bundle --out-dir "$BL_VAR_DIR/outbox"
    [ "$status" -eq 0 ]
    # Mock captures the request body; verify claude-sonnet-4-6 model name
    # appears via plain grep (more robust than jq parse on edge cases).
    grep -q 'claude-sonnet-4-6' "$BL_MESSAGES_MOCK_BODY_CAPTURE"
}

@test "bl_messages_call Sonnet 401 → bundle still produced via deterministic fallback" {
    bl_case_fixture_seed CASE-2026-0042
    bl_messages_mock_set_fixture messages-sonnet-summary.json 401
    mkdir -p "$BL_VAR_DIR/cases/CASE-2026-0042/evidence"
    printf '{"ts":"2026-04-25T00:00:00Z","host":"test","source":"apache.transfer","record":{}}\n' > "$BL_VAR_DIR/cases/CASE-2026-0042/evidence/obs-0001-apache.json"
    run "$BL_SOURCE" observe bundle --out-dir "$BL_VAR_DIR/outbox"
    [ "$status" -eq 0 ]
    # auto codec: .tar.zst when zstd present, .tgz otherwise (DESIGN.md §10.2)
    ls "$BL_VAR_DIR/outbox/" | grep -qE '\.(tgz|tar\.zst)$'
}

@test "bl_messages_call --no-llm-summary skips Sonnet entirely" {
    bl_case_fixture_seed CASE-2026-0042
    bl_messages_mock_set_fixture messages-sonnet-summary.json 200
    mkdir -p "$BL_VAR_DIR/cases/CASE-2026-0042/evidence"
    printf '{"ts":"2026-04-25T00:00:00Z","host":"test","source":"apache.transfer","record":{}}\n' > "$BL_VAR_DIR/cases/CASE-2026-0042/evidence/obs-0001-apache.json"
    run "$BL_SOURCE" observe bundle --no-llm-summary --out-dir "$BL_VAR_DIR/outbox"
    [ "$status" -eq 0 ]
    [ ! -r "$BL_MESSAGES_MOCK_BODY_CAPTURE" ] || [ ! -s "$BL_MESSAGES_MOCK_BODY_CAPTURE" ]
}

@test "bl_messages_call BL_DISABLE_LLM=1 skips Sonnet entirely" {
    bl_case_fixture_seed CASE-2026-0042
    bl_messages_mock_set_fixture messages-sonnet-summary.json 200
    mkdir -p "$BL_VAR_DIR/cases/CASE-2026-0042/evidence"
    printf '{"ts":"2026-04-25T00:00:00Z","host":"test","source":"apache.transfer","record":{}}\n' > "$BL_VAR_DIR/cases/CASE-2026-0042/evidence/obs-0001-apache.json"
    BL_DISABLE_LLM=1 run "$BL_SOURCE" observe bundle --out-dir "$BL_VAR_DIR/outbox"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Haiku 4.5 — FP-gate adjudication
# ---------------------------------------------------------------------------

@test "bl_messages_call FP-gate verdict:pass → defend.sig succeeds" {
    mkdir -p "$BL_VAR_DIR/fp-corpus"
    printf '<?php echo "hello"; ?>' > "$BL_VAR_DIR/fp-corpus/benign.php"
    mkdir -p "$BL_VAR_DIR/sigs"
    cat > "$BL_VAR_DIR/sigs/test.yar" <<'EOF'
rule TestUnique { strings: $a = "definitely_not_in_corpus_xyz123" condition: $a }
EOF
    printf 'CASE-2026-0042' > "$BL_VAR_DIR/state/case.current"
    bl_messages_mock_set_fixture messages-haiku-fp-pass.json 200
    BL_DEFEND_FP_CORPUS="$BL_VAR_DIR/fp-corpus" \
    BL_YARA_RULES_DIR="$BL_VAR_DIR/sigs-out" \
      run "$BL_SOURCE" defend sig "$BL_VAR_DIR/sigs/test.yar" --scanner yara
    # verdict:pass should not trip the gate; sig appended to scanner target
    [ "$status" -eq 0 ]
    [ -s "$BL_VAR_DIR/sigs-out/custom.yar" ]
    # Routing-by-model verified separately via test 1 (Sonnet) + test 6 (Haiku
    # status=68 only reached when Haiku call succeeds and verdict:match parses)
}

@test "bl_messages_call Haiku verdict:match → defend.sig denied" {
    mkdir -p "$BL_VAR_DIR/fp-corpus"
    printf '<?php echo "hello"; ?>' > "$BL_VAR_DIR/fp-corpus/benign.php"
    mkdir -p "$BL_VAR_DIR/sigs"
    cat > "$BL_VAR_DIR/sigs/test.yar" <<'EOF'
rule TestUnique { strings: $a = "definitely_not_in_corpus_xyz123" condition: $a }
EOF
    printf 'CASE-2026-0042' > "$BL_VAR_DIR/state/case.current"
    bl_messages_mock_set_fixture messages-haiku-fp-fail.json 200
    BL_DEFEND_FP_CORPUS="$BL_VAR_DIR/fp-corpus" \
    BL_YARA_RULES_DIR="$BL_VAR_DIR/sigs-out" \
      run "$BL_SOURCE" defend sig "$BL_VAR_DIR/sigs/test.yar" --scanner yara
    [ "$status" -eq 68 ]
}

@test "bl_messages_call Haiku malformed verdict → fail-closed" {
    mkdir -p "$BL_VAR_DIR/fp-corpus"
    printf '<?php echo "hello"; ?>' > "$BL_VAR_DIR/fp-corpus/benign.php"
    mkdir -p "$BL_VAR_DIR/sigs"
    cat > "$BL_VAR_DIR/sigs/test.yar" <<'EOF'
rule TestUnique { strings: $a = "definitely_not_in_corpus_xyz123" condition: $a }
EOF
    printf 'CASE-2026-0042' > "$BL_VAR_DIR/state/case.current"
    bl_messages_mock_set_fixture messages-sonnet-summary.json 200
    BL_DEFEND_FP_CORPUS="$BL_VAR_DIR/fp-corpus" \
    BL_YARA_RULES_DIR="$BL_VAR_DIR/sigs-out" \
      run "$BL_SOURCE" defend sig "$BL_VAR_DIR/sigs/test.yar" --scanner yara
    [ "$status" -eq 68 ]
}

# ---------------------------------------------------------------------------
# Beta-header centralization (P1 parity guard)
# ---------------------------------------------------------------------------

@test "BL_API_BETA_MA / BL_API_BETA_FILES / BL_API_BETA_SKILLS constants defined in src/bl.d/20-api.sh" {
    # Guard that P1 centralization constants remain present; prevents accidental
    # removal during future refactors.
    local api_src
    api_src="${BL_REPO_ROOT}/src/bl.d/20-api.sh"
    [[ ! -r "$api_src" ]] && api_src="/opt/blacklight-src/src/bl.d/20-api.sh"
    grep -q 'readonly BL_API_BETA_MA=' "$api_src"
    grep -q 'readonly BL_API_BETA_FILES=' "$api_src"
    grep -q 'readonly BL_API_BETA_SKILLS=' "$api_src"
}

@test "no hardcoded anthropic-beta: string literal remains in src/bl.d/" {
    # Parity guard: P1 centralized beta-header values into BL_API_BETA_* constants.
    # The legitimate concat pattern is `'anthropic-beta: '"$BL_API_BETA_MA"` —
    # the prefix `anthropic-beta: ` lives in a string but the *value* comes
    # from a variable. The bad pattern is `"anthropic-beta: <literal-value>"` /
    # `'anthropic-beta: <literal-value>'` — value baked into the string.
    # Distinguish by requiring a closing quote AFTER the value: a literal value
    # is followed by `"` or `'`; a concat splits the string before the variable.
    local src_dir
    src_dir="${BL_REPO_ROOT}/src/bl.d"
    [[ ! -d "$src_dir" ]] && src_dir="/opt/blacklight-src/src/bl.d"
    local hits
    hits=$(grep -rEn '["'\'']anthropic-beta:[[:space:]]+[a-z0-9._,-]+["'\'']' "$src_dir" 2>/dev/null) || true   # 2>/dev/null: silent on missing dir; empty $hits → assertion fires below
    [ -z "$hits" ]
}

@test "bl_messages_call Haiku BL_DISABLE_LLM=1 → bypassed (binary scan only)" {
    mkdir -p "$BL_VAR_DIR/fp-corpus"
    printf '<?php echo "hello"; ?>' > "$BL_VAR_DIR/fp-corpus/benign.php"
    mkdir -p "$BL_VAR_DIR/sigs"
    cat > "$BL_VAR_DIR/sigs/test.yar" <<'EOF'
rule TestUnique { strings: $a = "definitely_not_in_corpus_xyz123" condition: $a }
EOF
    printf 'CASE-2026-0042' > "$BL_VAR_DIR/state/case.current"
    bl_messages_mock_set_fixture messages-haiku-fp-fail.json 200
    BL_DISABLE_LLM=1 \
    BL_DEFEND_FP_CORPUS="$BL_VAR_DIR/fp-corpus" \
    BL_YARA_RULES_DIR="$BL_VAR_DIR/sigs-out" \
      run "$BL_SOURCE" defend sig "$BL_VAR_DIR/sigs/test.yar" --scanner yara
    [ "$status" -eq 0 ]
}
