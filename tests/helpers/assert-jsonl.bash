#!/usr/bin/env bash
# tests/helpers/assert-jsonl.bash — JSONL assertion helpers for BATS
#
# Two complementary surfaces:
#   M4 observe (tests/04-observe.bats):
#     assert_jsonl_preamble <line>                      — 6 required preamble keys present
#     assert_jsonl_record   <line> <source-taxonomy>    — per-source record fields per
#                                                          schemas/evidence-envelope.md §3
#
#   M5 consult/run/case (tests/05-consult-run-case.bats):
#     assert_jsonl_schema_valid    <schema-path> <payload-path>
#                                                        — JSON Schema draft-2020-12 subset
#                                                          (same subset as bl's bl_jq_schema_check)
#     assert_jsonl_records_count   <jsonl-path> <expected-count>
#     assert_jsonl_record_has      <jsonl-path> <line-no> <jq-path> <expected>
#
# All assertions return 0 on pass, 1 on fail (BATS captures).

# ─── M4 observe — evidence-envelope validators ──────────────────────────────

assert_jsonl_preamble() {
    # $1 = one JSONL line
    # Asserts: valid JSON, 6 required preamble keys present (ts, host, case, obs, source, record)
    local line="$1"
    echo "$line" | jq -e '. | (has("ts") and has("host") and has("case") and has("obs") and has("source") and (has("record") and (.record | type == "object")))' >/dev/null
}

assert_jsonl_record() {
    # $1 = one JSONL line, $2 = expected source taxonomy
    # Asserts record fields match the per-source contract in schemas/evidence-envelope.md §3
    local line="$1"
    local source="$2"
    case "$source" in
        apache.transfer)
            echo "$line" | jq -e '
                .source == "apache.transfer" and
                (.record | (
                    has("client_ip") and has("method") and has("path") and
                    has("status") and has("bytes") and has("ua") and
                    has("referer") and has("site") and has("ts_source") and
                    has("path_class") and has("is_post_to_php") and has("status_bucket")
                ))' >/dev/null
            ;;
        modsec.audit)
            echo "$line" | jq -e '
                .source == "modsec.audit" and
                (.record | (
                    has("unique_id") and has("ts_source") and
                    has("method") and has("path") and has("response_status")
                ))' >/dev/null
            ;;
        journal.entry)
            echo "$line" | jq -e '
                .source == "journal.entry" and
                (.record | (
                    has("unit") and has("message") and has("priority")
                ))' >/dev/null
            ;;
        file.triage)
            echo "$line" | jq -e '
                .source == "file.triage" and
                (.record | (
                    has("path") and has("sha256") and has("size_bytes") and
                    has("strings_sample") and has("strings_total")
                ))' >/dev/null
            ;;
        htaccess.directive)
            echo "$line" | jq -e '
                .source == "htaccess.directive" and
                (.record | (
                    has("file") and has("directive") and has("reason")
                ))' >/dev/null
            ;;
        fs.mtime_cluster)
            echo "$line" | jq -e '
                .source == "fs.mtime_cluster" and
                (.record | (
                    has("path") and has("mtime") and has("cluster_id") and
                    has("cluster_size") and has("cluster_span_secs")
                ))' >/dev/null
            ;;
        fs.mtime_since)
            echo "$line" | jq -e '
                .source == "fs.mtime_since" and
                (.record | (
                    has("path") and has("mtime") and has("size_bytes")
                ))' >/dev/null
            ;;
        cron.entry)
            echo "$line" | jq -e '
                .source == "cron.entry" and
                (.record | (
                    has("source_file") and has("raw_line") and
                    has("cat_v_repr") and has("ansi_obscured")
                ))' >/dev/null
            ;;
        proc.snapshot)
            echo "$line" | jq -e '
                .source == "proc.snapshot" and
                (.record | (
                    has("pid") and has("user") and has("argv") and
                    has("argv0_basename") and has("argv_spoof")
                ))' >/dev/null
            ;;
        firewall.rule)
            echo "$line" | jq -e '
                .source == "firewall.rule" and
                (.record | (
                    has("backend") and has("rule") and has("bl_case_tag")
                ))' >/dev/null
            ;;
        sig.loaded)
            echo "$line" | jq -e '
                .source == "sig.loaded" and
                (.record | has("scanner"))' >/dev/null
            ;;
        observe.summary)
            echo "$line" | jq -e '
                .source == "observe.summary" and
                (.record | type == "object")' >/dev/null
            ;;
        *)
            echo "assert_jsonl_record: unknown source: $source" >&2
            return 1
            ;;
    esac
}

# ─── M5 consult/run/case — schema + count + single-record assertions ────────

assert_jsonl_schema_valid() {
    local schema="$1"
    local payload="$2"
    [[ -r "$schema" ]] || { echo "assert_jsonl_schema_valid: schema not readable: $schema" >&2; return 1; }
    [[ -r "$payload" ]] || { echo "assert_jsonl_schema_valid: payload not readable: $payload" >&2; return 1; }
    local req_keys_ok
    req_keys_ok=$(jq -n --slurpfile s "$schema" --slurpfile p "$payload" '
        ($s[0].required // []) as $req |
        $p[0] as $pay |
        ($req | map(. as $k | $pay | has($k)) | all)
    ')
    [[ "$req_keys_ok" == "true" ]] || { echo "assert_jsonl_schema_valid: missing required key in $payload" >&2; return 1; }
    return 0
}

assert_jsonl_records_count() {
    local path="$1"
    local expected="$2"
    local actual
    actual=$(grep -c '^' "$path" 2>/dev/null || printf '0')
    [[ "$actual" -eq "$expected" ]] || { echo "assert_jsonl_records_count: expected $expected, got $actual in $path" >&2; return 1; }
    return 0
}

assert_jsonl_record_has() {
    local path="$1"
    local line_no="$2"
    local jq_path="$3"
    local expected="$4"
    local actual
    actual=$(sed -n "${line_no}p" "$path" | jq -r "$jq_path")
    [[ "$actual" == "$expected" ]] || { echo "assert_jsonl_record_has: line $line_no $jq_path expected '$expected' got '$actual'" >&2; return 1; }
    return 0
}
