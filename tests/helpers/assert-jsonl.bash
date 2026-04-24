#!/usr/bin/env bash
# tests/helpers/assert-jsonl.bash — JSONL preamble + per-source record field validator
# Consumed by tests/04-observe.bats.
# Validates against schemas/evidence-envelope.md §1 preamble + §3 per-source record fields.

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
