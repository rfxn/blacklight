# shellcheck shell=bash
bl_observe_log_apache() {
    unset _BL_OBS_ID _BL_OBS_CLUSTER_N
    local around_path="" window_spec="6h" site=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --around) around_path="$2"; shift 2 ;;
            --window) window_spec="$2"; shift 2 ;;
            --site)   site="$2"; shift 2 ;;
            *)        bl_error_envelope observe "log apache: unknown option: $1"; return "$BL_EX_USAGE" ;;
        esac
    done
    if [[ -z "$around_path" ]]; then
        bl_error_envelope observe "log apache: --around <path> required"
        return "$BL_EX_USAGE"
    fi

    # Parse window spec
    local win_re='^([0-9]+)([hmds])$'
    local window_secs=21600
    if [[ "$window_spec" =~ $win_re ]]; then
        local wn="${BASH_REMATCH[1]}" wu="${BASH_REMATCH[2]}"
        case "$wu" in
            h) window_secs=$(( wn * 3600 )) ;;
            m) window_secs=$(( wn * 60 )) ;;
            d) window_secs=$(( wn * 86400 )) ;;
            s) window_secs="$wn" ;;
        esac
    else
        bl_error_envelope observe "log apache: malformed --window (use e.g. 6h, 30m, 2d)"
        return "$BL_EX_USAGE"
    fi

    # Anchor mtime
    local anchor
    anchor=$(command stat -c '%Y' "$around_path" 2>/dev/null) || anchor=$(command stat -f '%m' "$around_path" 2>/dev/null) || {   # GNU stat first; BSD -f fallback; both fail → missing/unreadable path
        bl_error_envelope observe "log apache: cannot stat anchor path: $around_path"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    local window_start=$(( anchor - window_secs ))
    local window_end=$(( anchor + window_secs ))

    # Locate log file: --around path doubles as log when it looks like a log file or no system log found
    local log_path=""
    if [[ -r "$around_path" && -f "$around_path" ]]; then
        log_path="$around_path"   # --around path is a readable file; use it directly (fixture / non-standard paths)
    elif [[ -n "$site" ]]; then
        local candidate
        for candidate in \
            "/var/log/apache2/${site}.access.log" \
            "/var/log/httpd/${site}-access_log" \
            "/var/log/nginx/${site}.access.log"; do
            if [[ -r "$candidate" ]]; then log_path="$candidate"; break; fi
        done
        # Also try per-user log paths
        if [[ -z "$log_path" ]]; then
            while IFS= read -r f; do
                if [[ -r "$f" ]]; then log_path="$f"; break; fi
            done < <(command find /home -maxdepth 3 -name "${site}.log" -type f 2>/dev/null) # EACCES on locked home dirs
        fi
    else
        for candidate in \
            "/var/log/apache2/access.log" \
            "/var/log/httpd/access_log" \
            "/var/log/nginx/access.log"; do
            if [[ -r "$candidate" ]]; then log_path="$candidate"; break; fi
        done
    fi

    if [[ -z "$log_path" ]]; then
        bl_error_envelope observe "log apache: no readable access log found"
        return "$BL_EX_NOT_FOUND"
    fi

    local stream_path
    stream_path="$(_bl_obs_open_stream 'log-apache')"

    local tmpfile summary_file
    tmpfile=$(command mktemp)
    summary_file=$(command mktemp)

    # awk parses the combined log with mktime-based --window filtering and
    # accumulates summary counters at END. Records out of [ws, we] are
    # dropped (audit M8 fix; prior version computed ws/we but never applied
    # them, emitting every record). Histogram counters live awk-side
    # (audit M7 fix; prior bash post-emit jq queried `.record.is_post_to_php`
    # against the unwrapped awk output → always null → counters always 0).
    # SUMMARY emitted at END to summary_file via fd3.
    command awk \
        -v ws="$window_start" \
        -v we="$window_end" \
        -v site_label="${site:-unknown}" \
        -v summary_path="$summary_file" \
        'BEGIN {
            months["Jan"]="01"; months["Feb"]="02"; months["Mar"]="03";
            months["Apr"]="04"; months["May"]="05"; months["Jun"]="06";
            months["Jul"]="07"; months["Aug"]="08"; months["Sep"]="09";
            months["Oct"]="10"; months["Nov"]="11"; months["Dec"]="12";
            total=0; post_to_php=0; s2xx=0; s3xx=0; s4xx=0; s5xx=0
        }
        {
            # Combined log: IP - - [dd/Mon/yyyy:HH:MM:SS +off] "METHOD path HTTP/x" status bytes "ref" "ua"
            if ($0 ~ /^[0-9a-f.:]+[ \t]/) {
                client_ip=$1
                ts_raw=$4; sub(/^\[/,"",ts_raw)
                # ts_raw = dd/Mon/yyyy:HH:MM:SS
                split(ts_raw, ta, /[\/:]/)
                day=ta[1]; mon=months[ta[2]]; yr=ta[3]; hh=ta[4]; mm=ta[5]; ss=ta[6]
                # mktime expects "YYYY MM DD HH MM SS" (gawk extension; not POSIX
                # awk). On mawk/BSD-awk where mktime is absent, the call returns
                # -1 and the window check below falls through to emit-all (safe
                # behavior; matches pre-fix). gawk on Debian/Rocky/CentOS-EPEL
                # is the dominant case.
                rec_epoch = mktime(yr " " mon " " day " " hh " " mm " " ss)
                if (rec_epoch != -1 && (rec_epoch < ws || rec_epoch > we)) next
                ts_iso = yr "-" mon "-" day "T" hh ":" mm ":" ss "Z"
                method_path=$6; sub(/^"/,"",method_path)
                method=method_path
                sub(/ .*/,"",method)
                path_field=$7
                status=$9
                bytes=$10; if (bytes=="-") bytes="0"
                referer=$11; sub(/^"/,"",referer); sub(/"$/,"",referer)
                ua=""; for(i=12;i<=NF;i++){ua=ua (i>12?" ":"") $i}; sub(/^"/,"",ua); sub(/"$/,"",ua)
                path_class="normal"
                if (path_field ~ /\.(php|phtml)\/.*\.(jpg|png|gif|svg)$/) path_class="double_ext_jpg"
                else if (path_field ~ /\.(jpg|png|gif|svg)\?.*php/) path_class="img_with_php_param"
                is_post="false"
                if (method=="POST" && path_field ~ /\.(php|phtml)/) is_post="true"
                sb="other"; if (status~/^2/) sb="2xx"; else if(status~/^3/) sb="3xx"; else if(status~/^4/) sb="4xx"; else if(status~/^5/) sb="5xx"
                # accumulate awk-side; bash counters were silently zero (M7 bug)
                total++
                if (is_post=="true") post_to_php++
                if (sb=="2xx") s2xx++; else if (sb=="3xx") s3xx++; else if (sb=="4xx") s4xx++; else if (sb=="5xx") s5xx++
                printf "{\"client_ip\":\"%s\",\"method\":\"%s\",\"path\":\"%s\",\"status\":\"%s\",\"bytes\":%s,\"ua\":\"%s\",\"referer\":\"%s\",\"site\":\"%s\",\"ts_source\":\"%s\",\"path_class\":\"%s\",\"is_post_to_php\":%s,\"status_bucket\":\"%s\"}\n",
                    client_ip, method, path_field, status, bytes, ua, referer, site_label, ts_iso, path_class, is_post, sb
            }
        }
        END {
            printf "%d %d %d %d %d %d\n", total, post_to_php, s2xx, s3xx, s4xx, s5xx > summary_path
        }' "$log_path" > "$tmpfile"

    # Emit each record through the shared envelope wrapper. Useless cat-subshell
    # passthrough (`done < <(while ... done < tmpfile)`) collapsed to direct
    # file read (audit m17).
    local line total=0 post_to_php=0 s2xx=0 s3xx=0 s4xx=0 s5xx=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _bl_obs_emit_jsonl 'apache.transfer' "$line" "$stream_path" || { command rm -f "$tmpfile" "$summary_file"; return "$BL_EX_SCHEMA_VALIDATION_FAIL"; }
    done < "$tmpfile"

    # Read awk-emitted summary line: "total post_to_php s2xx s3xx s4xx s5xx".
    if [[ -s "$summary_file" ]]; then
        read -r total post_to_php s2xx s3xx s4xx s5xx < "$summary_file"
    fi
    command rm -f "$tmpfile" "$summary_file"

    local summary
    summary=$(jq -n -c \
        --arg site "$site" \
        --argjson total "${total:-0}" \
        --argjson post_to_php "${post_to_php:-0}" \
        --argjson s2xx "${s2xx:-0}" --argjson s3xx "${s3xx:-0}" \
        --argjson s4xx "${s4xx:-0}" --argjson s5xx "${s5xx:-0}" \
        '{source:"apache.transfer",total_records:$total,post_to_php_count:$post_to_php,status_histogram:{s2xx:$s2xx,s3xx:$s3xx,s4xx:$s4xx,s5xx:$s5xx},site:$site}')
    _bl_obs_close_stream "$stream_path" 'apache.transfer' "$summary"
}

# ---------------------------------------------------------------------------
# bl_observe_log_modsec — parse ModSec Serial or Concurrent audit log
# ---------------------------------------------------------------------------
bl_observe_log_modsec() {
    unset _BL_OBS_ID _BL_OBS_CLUSTER_N
    local txn_filter="" rule_filter="" around_path="" window_spec="6h"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --txn)    txn_filter="$2"; shift 2 ;;
            --rule)   rule_filter="$2"; shift 2 ;;
            --around) around_path="$2"; shift 2 ;;
            --window) window_spec="$2"; shift 2 ;;
            *)        bl_error_envelope observe "log modsec: unknown option: $1"; return "$BL_EX_USAGE" ;;
        esac
    done

    # Locate log
    local log_path=""
    local concurrent_dir=""
    if [[ -d /var/log/modsec_audit ]]; then
        concurrent_dir="/var/log/modsec_audit"
    else
        for candidate in \
            "/var/log/modsec_audit.log" \
            "/var/log/apache2/modsec_audit.log" \
            "/var/log/httpd/modsec_audit.log" \
            "/var/log/nginx/modsec_audit.log"; do
            if [[ -r "$candidate" ]]; then log_path="$candidate"; break; fi
        done
    fi

    if [[ -z "$log_path" && -z "$concurrent_dir" ]]; then
        bl_error_envelope observe "log modsec: no readable modsec audit log found"
        return "$BL_EX_NOT_FOUND"
    fi

    local stream_path
    stream_path="$(_bl_obs_open_stream 'log-modsec')"

    local total=0
    _parse_modsec_serial() {
        local file="$1"
        command awk '
        /^--[0-9a-fA-F]+-A--$/ { in_txn=1; uid=""; ts_src=""; reset_rec(); next }
        /^--[0-9a-fA-F]+-Z--$/ {
            if (in_txn && uid!="") {
                printf "{\"unique_id\":\"%s\",\"ts_source\":\"%s\",\"client_ip\":\"%s\",\"method\":\"%s\",\"path\":\"%s\",\"response_status\":\"%s\",\"rule_ids\":\"%s\",\"rule_msgs\":\"%s\"}\n",
                    uid, ts_src, client_ip, method, path, resp_status, rule_ids, rule_msgs
            }
            in_txn=0; next
        }
        in_txn && /^[A-Z]$/ { section=$0; next }
        in_txn && section=="A" && /^[A-Za-z0-9+\/=]+$/ && uid=="" { uid=$0; next }
        in_txn && section=="A" && /^[0-9]/ && ts_src=="" { ts_src=$1" "$2; next }
        in_txn && section=="B" && /^(GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS)/ {
            method=$1; path=$2; next
        }
        in_txn && section=="B" && /^X-Forwarded-For:|^X-Real-IP:/ { client_ip=$2; next }
        in_txn && section=="F" && /^HTTP\// { resp_status=$2; next }
        in_txn && section=="H" && /^Rule id:/ { rule_ids=rule_ids (rule_ids?",":"") $3; next }
        in_txn && section=="H" && /^Message:/ { msg=$0; sub(/^Message: /,"",msg); rule_msgs=rule_msgs (rule_msgs?"|":"") msg; next }
        function reset_rec() { uid=""; ts_src=""; client_ip=""; method=""; path=""; resp_status=""; rule_ids=""; rule_msgs=""; section="" }
        ' "$file"
    }

    local records_file
    records_file=$(command mktemp)

    if [[ -n "$concurrent_dir" ]]; then
        while IFS= read -r f; do
            _parse_modsec_serial "$f" >> "$records_file"
        done < <(command find "$concurrent_dir" -type f 2>/dev/null | command sort)   # EACCES on locked dirs — partial results acceptable
    else
        _parse_modsec_serial "$log_path" >> "$records_file"
    fi

    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        if [[ -n "$txn_filter" ]]; then
            local uid_val
            uid_val=$(printf '%s' "$rec" | jq -r '.unique_id // ""' 2>/dev/null)   # jq field extraction; non-fatal
            [[ "$uid_val" != *"$txn_filter"* ]] && continue
        fi
        if [[ -n "$rule_filter" ]]; then
            local rule_val
            rule_val=$(printf '%s' "$rec" | jq -r '.rule_ids // ""' 2>/dev/null)   # jq field extraction; non-fatal
            [[ "$rule_val" != *"$rule_filter"* ]] && continue
        fi
        _bl_obs_emit_jsonl 'modsec.audit' "$rec" "$stream_path" || { command rm -f "$records_file"; return "$BL_EX_SCHEMA_VALIDATION_FAIL"; }
        total=$((total + 1))
    done < "$records_file"

    command rm -f "$records_file"
    unset -f _parse_modsec_serial

    local summary
    summary=$(jq -n -c --argjson total "$total" '{source:"modsec.audit",total_records:$total}')
    _bl_obs_close_stream "$stream_path" 'modsec.audit' "$summary"
}

# ---------------------------------------------------------------------------
# bl_observe_log_journal — parse systemd journal via journalctl
# ---------------------------------------------------------------------------
bl_observe_log_journal() {
    unset _BL_OBS_ID _BL_OBS_CLUSTER_N
    local since_arg="" grep_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --since) since_arg="$2"; shift 2 ;;
            --grep)  grep_arg="$2"; shift 2 ;;
            *)       bl_error_envelope observe "log journal: unknown option: $1"; return "$BL_EX_USAGE" ;;
        esac
    done

    if [[ -z "$since_arg" ]]; then
        bl_error_envelope observe "log journal: --since <timestamp> required"
        return "$BL_EX_USAGE"
    fi

    if ! command -v journalctl >/dev/null 2>&1; then   # journalctl is required; no syslog fallback (NG5)
        bl_error_envelope observe "log journal: journalctl not available (systemd required)"
        return "$BL_EX_NOT_FOUND"
    fi

    local stream_path
    stream_path="$(_bl_obs_open_stream 'log-journal')"

    local jctl_args=( journalctl -o json --since "$since_arg" )
    [[ -n "$grep_arg" ]] && jctl_args+=( -g "$grep_arg" )

    local total=0
    local tmpfile
    tmpfile=$(command mktemp)

    command "${jctl_args[@]}" 2>/dev/null > "$tmpfile" || true   # journalctl exits non-zero when no entries match

    while IFS= read -r jline; do
        [[ -z "$jline" ]] && continue
        local rec
        rec=$(printf '%s' "$jline" | jq -c '{unit:(._SYSTEMD_UNIT // "unknown"),pid:(._PID // null | tonumber? // null),message:(.MESSAGE // ""),priority:(.PRIORITY // ""),ts_source:(.__REALTIME_TIMESTAMP // null | if . then (tonumber / 1000000 | todate) else null end)}' 2>/dev/null) || continue   # jq parse per line; skip malformed journal entries
        _bl_obs_emit_jsonl 'journal.entry' "$rec" "$stream_path" || { command rm -f "$tmpfile"; return "$BL_EX_SCHEMA_VALIDATION_FAIL"; }
        total=$((total + 1))
    done < "$tmpfile"

    command rm -f "$tmpfile"

    local summary
    summary=$(jq -n -c --argjson total "$total" '{source:"journal.entry",total_records:$total}')
    _bl_obs_close_stream "$stream_path" 'journal.entry' "$summary"
}

# ---------------------------------------------------------------------------
# bl_observe_file — triage a single file: hash, strings, magic
# ---------------------------------------------------------------------------
bl_observe_file() {
    unset _BL_OBS_ID _BL_OBS_CLUSTER_N
    local path="${1:-}"
    if [[ -z "$path" ]]; then
        bl_error_envelope observe "file: <path> required"
        return "$BL_EX_USAGE"
    fi
    if [[ -d "$path" ]]; then
        bl_error_envelope observe "file: <path> is a directory (use htaccess or fs sub-verbs for directory walks)"
        return "$BL_EX_USAGE"
    fi
    if [[ ! -e "$path" ]]; then
        bl_error_envelope observe "file: not found: $path"
        return "$BL_EX_NOT_FOUND"
    fi
    if [[ ! -r "$path" ]]; then
        bl_error_envelope observe "file: unreadable: $path"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    _bl_obs_size_guard "$path" $((64 * 1024 * 1024)) || return "$?"

    # Hash
    local sha256=""
    if command -v sha256sum >/dev/null 2>&1; then
        sha256=$(command sha256sum "$path" | command awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        sha256=$(command shasum -a 256 "$path" | command awk '{print $1}')
    else
        bl_error_envelope observe "file: sha256sum/shasum not available"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    # Magic
    local magic="null"
    if command -v file >/dev/null 2>&1; then
        magic="\"$(command file -b "$path" | jq -Rr '.' 2>/dev/null || command file -b "$path")\""   # jq error output suppressed; file -b fallback handles failure
    fi

    # Strings
    local strings_sample="[]" strings_total=0
    if command -v strings >/dev/null 2>&1; then
        strings_total=$(command strings -n 6 "$path" 2>/dev/null | command wc -l | command awk '{print $1}')   # strings output on unreadable files silently empty
        local stmp
        stmp=$(command strings -n 6 "$path" 2>/dev/null | command sort -u | command head -n 32 | jq -Rsc 'split("\n") | map(select(. != ""))' 2>/dev/null) || stmp='[]'   # strings errors silently ignored; missing tool handled above
        strings_sample="$stmp"
    fi

    local size
    size=$(command stat -c '%s' "$path" 2>/dev/null) || size=$(command stat -f '%z' "$path" 2>/dev/null) || size=0   # BSD stat fallback

    local stream_path
    stream_path="$(_bl_obs_open_stream 'file')"

    local rec
    rec=$(jq -n -c \
        --arg path "$path" \
        --arg sha256 "$sha256" \
        --argjson magic "$magic" \
        --argjson strings_sample "$strings_sample" \
        --argjson strings_total "$strings_total" \
        --argjson size_bytes "$size" \
        '{path:$path,sha256:$sha256,magic:$magic,strings_sample:$strings_sample,strings_total:$strings_total,size_bytes:$size_bytes}')
    _bl_obs_emit_jsonl 'file.triage' "$rec" "$stream_path" || return "$BL_EX_SCHEMA_VALIDATION_FAIL"

    local summary
    summary=$(jq -n -c --arg path "$path" --arg sha256 "$sha256" --argjson size_bytes "$size" '{source:"file.triage",path:$path,sha256:$sha256,size_bytes:$size_bytes}')
    _bl_obs_close_stream "$stream_path" 'file.triage' "$summary"
}

# ---------------------------------------------------------------------------
# bl_observe_htaccess — scan directory tree for injected .htaccess directives
# ---------------------------------------------------------------------------
bl_observe_htaccess() {
    unset _BL_OBS_ID _BL_OBS_CLUSTER_N
    local dir="${1:-}"
    local recursive=0
    if [[ "$dir" == "--recursive" ]]; then
        recursive=1; shift
        dir="${1:-}"
    fi
    # Also accept --recursive after dir
    if [[ $# -gt 1 && "$2" == "--recursive" ]]; then
        recursive=1
    fi
    if [[ -z "$dir" ]]; then
        bl_error_envelope observe "htaccess: <dir> required"
        return "$BL_EX_USAGE"
    fi
    if [[ ! -d "$dir" ]]; then
        bl_error_envelope observe "htaccess: not a directory: $dir"
        return "$BL_EX_NOT_FOUND"
    fi

    local stream_path
    stream_path="$(_bl_obs_open_stream 'htaccess')"

    local total=0
    local files_list
    files_list=$(command mktemp)
    if (( recursive )); then
        command find "$dir" -name .htaccess -type f 2>/dev/null > "$files_list"   # EACCES on locked home dirs — partial results acceptable
    else
        [[ -f "$dir/.htaccess" ]] && printf '%s\n' "$dir/.htaccess" > "$files_list"
    fi

    while IFS= read -r hfile; do
        [[ -z "$hfile" || ! -r "$hfile" ]] && continue
        while IFS= read -r htline; do
            [[ -z "$htline" ]] && continue
            # Match against closed vocabulary
            local reason=""
            local ht_re_1='AddHandler[[:space:]]+application/x-httpd-php[[:space:]].*\.(jpg|png|gif|svg)'
            local ht_re_2='AddType[[:space:]]+application/x-httpd-php[[:space:]]+\.[^p]'
            local ht_re_3='<FilesMatch.*\.(jpg|png|gif)'
            local ht_re_4='DirectoryIndex[[:space:]]+(shell|cmd|adminer|[a-z0-9]{8,}\.php)'
            local ht_re_5='RewriteRule.*php'
            if [[ "$htline" =~ $ht_re_1 ]]; then
                reason="addhandler_image_to_php"
            elif [[ "$htline" =~ $ht_re_2 ]]; then
                reason="addtype_nonstandard_ext_to_php"
            elif [[ "$htline" =~ $ht_re_3 ]]; then
                reason="filesmatch_php_in_image"
            elif [[ "$htline" =~ $ht_re_4 ]]; then
                reason="directoryindex_webshell_heuristic"
            elif [[ "$htline" =~ $ht_re_5 ]]; then
                reason="rewriterule_php_injection"
            fi
            [[ -z "$reason" ]] && continue
            local rec
            rec=$(jq -n -c \
                --arg file "$hfile" \
                --arg directive "$htline" \
                --arg reason "$reason" \
                '{file:$file,directive:$directive,reason:$reason}')
            _bl_obs_emit_jsonl 'htaccess.directive' "$rec" "$stream_path" || { command rm -f "$files_list"; return "$BL_EX_SCHEMA_VALIDATION_FAIL"; }
            total=$((total + 1))
        done < "$hfile"
    done < "$files_list"

    command rm -f "$files_list"

    local summary
    summary=$(jq -n -c --argjson total "$total" '{source:"htaccess.directive",total_flagged:$total}')
    _bl_obs_close_stream "$stream_path" 'htaccess.directive' "$summary"
}

# ---------------------------------------------------------------------------
# bl_observe_fs_mtime_cluster — find temporally clustered file modifications
# ---------------------------------------------------------------------------
bl_observe_fs_mtime_cluster() {
    unset _BL_OBS_ID _BL_OBS_CLUSTER_N
    local path="" window_secs="" ext_filter=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --window) window_secs="$2"; shift 2 ;;
            --ext)    ext_filter="$2"; shift 2 ;;
            --)       shift; path="${1:-}"; break ;;
            -*)       bl_error_envelope observe "fs_mtime_cluster: unknown option: $1"; return "$BL_EX_USAGE" ;;
            *)        path="$1"; shift ;;
        esac
    done

    if [[ -z "$path" ]]; then
        bl_error_envelope observe "fs mtime-cluster: <path> required"
        return "$BL_EX_USAGE"
    fi
    if [[ -z "$window_secs" ]]; then
        bl_error_envelope observe "fs mtime-cluster: --window <seconds> required"
        return "$BL_EX_USAGE"
    fi
    if ! [[ "$window_secs" =~ ^[0-9]+$ ]] || (( window_secs == 0 )); then
        bl_error_envelope observe "fs mtime-cluster: --window must be a positive integer (seconds)"
        return "$BL_EX_USAGE"
    fi
    if [[ ! -d "$path" ]]; then
        bl_error_envelope observe "fs mtime-cluster: not a directory: $path"
        return "$BL_EX_NOT_FOUND"
    fi

    # Build ext regex if provided
    local ext_regex=""
    if [[ -n "$ext_filter" ]]; then
        local ext_pattern="${ext_filter//,/|}"
        ext_regex=".*\\.(${ext_pattern})$"
    fi

    local stream_path
    stream_path="$(_bl_obs_open_stream 'fs-mtime-cluster')"

    # Detect GNU find vs BSD
    local use_gnu_find=0
    if command find --version 2>/dev/null | command grep -q 'GNU find'; then   # BSD find has no --version
        use_gnu_find=1
    fi

    local tmpfile
    tmpfile=$(command mktemp)

    if (( use_gnu_find )); then
        local find_args=( find "$path" -type f )
        [[ -n "$ext_regex" ]] && find_args+=( -regex "$ext_regex" )
        find_args+=( -printf '%T@\t%s\t%m\t%U\t%p\n' )
        command "${find_args[@]}" 2>/dev/null | command sort -n > "$tmpfile"   # EACCES on restricted paths — partial results acceptable
    else
        # BSD: use stat per file
        local find_args2=( find "$path" -type f )
        [[ -n "$ext_regex" ]] && find_args2+=( -name "*" )   # BSD find -regex not always available
        command "${find_args2[@]}" 2>/dev/null | while IFS= read -r f; do   # EACCES on restricted paths — partial results acceptable
            local mt sz
            mt=$(command stat -f '%m' "$f" 2>/dev/null) || continue   # BSD stat
            sz=$(command stat -f '%z' "$f" 2>/dev/null) || sz=0   # BSD stat; missing file handled by continue
            printf '%s\t%s\t%s\t%s\t%s\n' "$mt" "$sz" "755" "0" "$f"
        done | command sort -n > "$tmpfile"
    fi

    # Cluster algorithm
    local clusters_file
    clusters_file=$(command mktemp)
    local cluster_start_t=""
    local cluster_files=()
    local cluster_files_t=()

    # Flush helper — writes cluster to clusters_file if cluster has >=2 members
    _bl_obs_flush_cluster() {
        if (( ${#cluster_files[@]} >= 2 )); then
            local cid cspan i
            cid="$(_bl_obs_allocate_cluster_id)"
            cspan=$(( cluster_files_t[${#cluster_files_t[@]}-1] - cluster_files_t[0] ))
            for (( i=0; i<${#cluster_files[@]}; i++ )); do
                printf '%s\t%s\t%s\t%s\t%s\n' \
                    "${cluster_files_t[$i]}" "${cluster_files[$i]}" \
                    "$cid" "${#cluster_files[@]}" "$cspan" >> "$clusters_file"
            done
        fi
        cluster_files=()
        cluster_files_t=()
        cluster_start_t=""
    }

    while IFS=$'\t' read -r epoch_raw _sz _mode _uid fpath; do
        local epoch="${epoch_raw%%.*}"   # strip fractional part
        [[ -z "$epoch" || -z "$fpath" ]] && continue
        if [[ -z "$cluster_start_t" ]]; then
            cluster_start_t="$epoch"
            cluster_files=("$fpath")
            cluster_files_t=("$epoch")
        elif (( epoch - cluster_start_t <= window_secs )); then
            cluster_files+=("$fpath")
            cluster_files_t+=("$epoch")
        else
            _bl_obs_flush_cluster
            cluster_start_t="$epoch"
            cluster_files=("$fpath")
            cluster_files_t=("$epoch")
        fi
    done < "$tmpfile"
    _bl_obs_flush_cluster

    unset -f _bl_obs_flush_cluster
    command rm -f "$tmpfile"

    local total=0
    while IFS=$'\t' read -r epoch fpath cid csize cspan; do
        [[ -z "$fpath" ]] && continue
        local rec
        rec=$(jq -n -c \
            --arg path "$fpath" \
            --argjson mtime "$epoch" \
            --arg cluster_id "$cid" \
            --argjson cluster_size "$csize" \
            --argjson cluster_span_secs "$cspan" \
            '{path:$path,mtime:$mtime,cluster_id:$cluster_id,cluster_size:$cluster_size,cluster_span_secs:$cluster_span_secs}')
        _bl_obs_emit_jsonl 'fs.mtime_cluster' "$rec" "$stream_path" || { command rm -f "$clusters_file"; return "$BL_EX_SCHEMA_VALIDATION_FAIL"; }
        total=$((total + 1))
    done < "$clusters_file"

    command rm -f "$clusters_file"
    unset -f flush_cluster

    local summary
    summary=$(jq -n -c --argjson total "$total" '{source:"fs.mtime_cluster",total_records:$total}')
    _bl_obs_close_stream "$stream_path" 'fs.mtime_cluster' "$summary"
}

# ---------------------------------------------------------------------------
# bl_observe_fs_mtime_since — files modified after a given timestamp
# ---------------------------------------------------------------------------
bl_observe_fs_mtime_since() {
    unset _BL_OBS_ID _BL_OBS_CLUSTER_N
    local since_arg="" under_path="" ext_filter=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --since) since_arg="$2"; shift 2 ;;
            --under) under_path="$2"; shift 2 ;;
            --ext)   ext_filter="$2"; shift 2 ;;
            *)       bl_error_envelope observe "fs mtime-since: unknown option: $1"; return "$BL_EX_USAGE" ;;
        esac
    done

    if [[ -z "$since_arg" ]]; then
        bl_error_envelope observe "fs mtime-since: --since <timestamp> required"
        return "$BL_EX_USAGE"
    fi
    if [[ -z "$under_path" ]]; then
        bl_error_envelope observe "fs mtime-since: --under <path> required"
        return "$BL_EX_USAGE"
    fi
    if [[ ! -d "$under_path" ]]; then
        bl_error_envelope observe "fs mtime-since: not a directory: $under_path"
        return "$BL_EX_NOT_FOUND"
    fi

    local stream_path
    stream_path="$(_bl_obs_open_stream 'fs-mtime-since')"

    # GNU -newermt; BSD fallback via touch + -newer
    local use_gnu_find=0
    if command find --version 2>/dev/null | command grep -q 'GNU find'; then   # BSD find has no --version
        use_gnu_find=1
    fi

    local find_args
    local tmpfile
    tmpfile=$(command mktemp)

    if (( use_gnu_find )); then
        find_args=( find "$under_path" -type f -newermt "$since_arg" )
        [[ -n "$ext_filter" ]] && find_args+=( -name "*.${ext_filter}" )
        command "${find_args[@]}" 2>/dev/null > "$tmpfile"   # EACCES on restricted paths — partial scan acceptable
    else
        local ref
        ref=$(command mktemp)
        command touch -d "$since_arg" "$ref" 2>/dev/null || command touch -t "$(printf '%s' "$since_arg" | command tr -d 'TZ:-')" "$ref" 2>/dev/null || true   # BSD touch fallback
        find_args=( find "$under_path" -type f -newer "$ref" )
        [[ -n "$ext_filter" ]] && find_args+=( -name "*.${ext_filter}" )
        command "${find_args[@]}" 2>/dev/null > "$tmpfile"   # BSD touch fallback; errors produce empty ref file
        command rm -f "$ref"
    fi

    local total=0
    while IFS= read -r fpath; do
        [[ -z "$fpath" ]] && continue
        local mt sz
        mt=$(command stat -c '%Y' "$fpath" 2>/dev/null) || mt=$(command stat -f '%m' "$fpath" 2>/dev/null) || mt=0   # BSD stat fallback
        sz=$(command stat -c '%s' "$fpath" 2>/dev/null) || sz=$(command stat -f '%z' "$fpath" 2>/dev/null) || sz=0   # BSD stat fallback
        local rec
        rec=$(jq -n -c \
            --arg path "$fpath" \
            --argjson mtime "$mt" \
            --argjson size_bytes "$sz" \
            '{path:$path,mtime:$mtime,size_bytes:$size_bytes}')
        _bl_obs_emit_jsonl 'fs.mtime_since' "$rec" "$stream_path" || { command rm -f "$tmpfile"; return "$BL_EX_SCHEMA_VALIDATION_FAIL"; }
        total=$((total + 1))
    done < "$tmpfile"

    command rm -f "$tmpfile"

    local summary
    summary=$(jq -n -c --argjson total "$total" --arg since "$since_arg" '{source:"fs.mtime_since",total_records:$total,since:$since}')
    _bl_obs_close_stream "$stream_path" 'fs.mtime_since' "$summary"
}

# ---------------------------------------------------------------------------
# bl_observe_cron — inspect crontab entries for ANSI-obscured / malicious lines
# ---------------------------------------------------------------------------
bl_observe_cron() {
    unset _BL_OBS_ID _BL_OBS_CLUSTER_N
    local user_arg="" do_system=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)   user_arg="$2"; shift 2 ;;
            --system) do_system=1; shift ;;
            *)        bl_error_envelope observe "cron: unknown option: $1"; return "$BL_EX_USAGE" ;;
        esac
    done

    local stream_path
    stream_path="$(_bl_obs_open_stream 'cron')"
    local total=0

    _emit_cron_lines() {
        local src="$1"
        local content="$2"
        local line catv ansi_obs
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            catv=$(printf '%s' "$line" | command cat -v)
            ansi_obs="false"
            [[ "$catv" == *"^["* ]] && ansi_obs="true"
            local rec
            rec=$(jq -n -c \
                --arg source_file "$src" \
                --arg raw_line "$line" \
                --arg cat_v_repr "$catv" \
                --argjson ansi_obscured "$ansi_obs" \
                '{source_file:$source_file,raw_line:$raw_line,cat_v_repr:$cat_v_repr,ansi_obscured:$ansi_obscured}')
            _bl_obs_emit_jsonl 'cron.entry' "$rec" "$stream_path" || return "$BL_EX_SCHEMA_VALIDATION_FAIL"
            total=$((total + 1))
        done <<< "$content"
    }

    if [[ -n "$user_arg" ]]; then
        local cron_out cron_rc
        cron_out=$(command crontab -u "$user_arg" -l 2>&1) || cron_rc=$?
        local cron_rc="${cron_rc:-0}"
        if (( cron_rc != 0 )); then
            # "no crontab for X" = no entries; "user 'X' unknown" = user not found; both → 72
            if [[ "$cron_out" == *"no crontab for"* || "$cron_out" == *"unknown"* ]]; then
                bl_error_envelope observe "cron: no crontab for $user_arg"
                return "$BL_EX_NOT_FOUND"
            fi
            bl_error_envelope observe "cron: crontab -l failed: $cron_out"
            return "$BL_EX_PREFLIGHT_FAIL"
        fi
        _emit_cron_lines "crontab:$user_arg" "$cron_out" || return "$?"
    fi

    if (( do_system )); then
        local sys_files=( /etc/crontab )
        local f
        while IFS= read -r f; do
            sys_files+=("$f")
        done < <(command find /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly -type f 2>/dev/null) # EACCES on restricted dirs

        for f in "${sys_files[@]}"; do
            [[ -r "$f" ]] || continue
            local content
            content=$(command cat -v "$f")
            _emit_cron_lines "$f" "$content" || return "$?"
        done
    fi

    unset -f _emit_cron_lines

    local summary
    summary=$(jq -n -c --argjson total "$total" '{source:"cron.entry",total_records:$total}')
    _bl_obs_close_stream "$stream_path" 'cron.entry' "$summary"
}

# ---------------------------------------------------------------------------
# bl_observe_proc — inspect running processes for argv-spoof indicators
# ---------------------------------------------------------------------------
bl_observe_proc() {
    unset _BL_OBS_ID _BL_OBS_CLUSTER_N
    local user_arg="" verify_argv=0
    # Check for fixture override first (test affordance)
    local fixture_file="${BL_PROC_FIXTURE_FILE:-}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)         user_arg="$2"; shift 2 ;;
            --verify-argv)  verify_argv=1; shift ;;
            *)              bl_error_envelope observe "proc: unknown option: $1"; return "$BL_EX_USAGE" ;;
        esac
    done

    if [[ -z "$user_arg" ]]; then
        bl_error_envelope observe "proc: --user <user> required"
        return "$BL_EX_USAGE"
    fi
    # POSIX user-name guard — reject comma-lists, leading-dash flag forms, and
    # other shapes that ps -u would accept silently with broader scope than
    # the curator step intended.
    if ! [[ "$user_arg" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        bl_error_envelope observe "proc: --user format invalid (POSIX user-name): $user_arg"
        return "$BL_EX_USAGE"
    fi

    # Linux-only — /proc/<pid>/exe not available elsewhere
    if [[ "$(command uname -s 2>/dev/null)" != "Linux" ]]; then   # uname unavailable in some minimal containers
        bl_error_envelope observe "proc: /proc/<pid>/exe not available (Linux kernel required)"
        return "$BL_EX_NOT_FOUND"
    fi

    local stream_path
    stream_path="$(_bl_obs_open_stream 'proc')"

    local tmpfile
    tmpfile=$(command mktemp)

    if [[ -n "$fixture_file" && -r "$fixture_file" ]]; then
        command cat "$fixture_file" > "$tmpfile"
    else
        command ps -u "$user_arg" -o pid=,user=,args= 2>/dev/null > "$tmpfile" || true   # empty output is OK — zero processes
    fi

    local total=0
    while IFS= read -r psline; do
        [[ -z "$psline" || "$psline" =~ ^[[:space:]]*# ]] && continue   # skip blank lines and fixture comment headers
        local pid user_ps argv
        read -r pid user_ps argv <<< "$psline"
        [[ -z "$pid" ]] && continue
        local argv0_basename="${argv%% *}"
        argv0_basename="${argv0_basename##*/}"
        local exe_basename=""
        local cwd=""
        local start_time_ts=""
        if [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]]; then
            exe_basename=$(command readlink "/proc/$pid/exe" 2>/dev/null) || true   # PID may reap between ps and readlink; non-existent PID → empty, not fatal
            exe_basename="${exe_basename##*/}"
            cwd=$(command readlink "/proc/$pid/cwd" 2>/dev/null) || true   # same race as exe readlink; tolerate missing /proc entry
            start_time_ts=$(command stat -c '%Y' "/proc/$pid" 2>/dev/null) || true   # same race; tolerate missing /proc entry
        fi
        local argv_spoof="false"
        if (( verify_argv )) && [[ -n "$exe_basename" && "$exe_basename" != "$argv0_basename" ]]; then
            argv_spoof="true"
        fi
        local rec_args=(
            --arg pid "$pid"
            --arg user_ps "$user_ps"
            --arg argv "$argv"
            --arg argv0_basename "$argv0_basename"
            --argjson argv_spoof "$argv_spoof"
        )
        # shellcheck disable=SC2016  # $pid etc. are jq --arg named variables, not shell variables
        local rec_jq='{pid:$pid,user:$user_ps,argv:$argv,argv0_basename:$argv0_basename,argv_spoof:$argv_spoof'
        if (( verify_argv )); then
            rec_args+=( --arg exe_basename "$exe_basename" )
            rec_jq="${rec_jq},exe_basename:\$exe_basename"
        fi
        if [[ -n "$cwd" ]]; then
            rec_args+=( --arg cwd "$cwd" )
            rec_jq="${rec_jq},cwd:\$cwd"
        fi
        if [[ -n "$start_time_ts" ]]; then
            rec_args+=( --argjson start_time_ts "$start_time_ts" )
            rec_jq="${rec_jq},start_time_ts:\$start_time_ts"
        fi
        rec_jq="${rec_jq}}"
        local rec
        rec=$(jq -n -c "${rec_args[@]}" "$rec_jq" 2>/dev/null) || continue   # jq -n builds; malformed args yield empty; caller skips with || continue
        _bl_obs_emit_jsonl 'proc.snapshot' "$rec" "$stream_path" || { command rm -f "$tmpfile"; return "$BL_EX_SCHEMA_VALIDATION_FAIL"; }
        total=$((total + 1))
    done < "$tmpfile"

    command rm -f "$tmpfile"

    local summary
    summary=$(jq -n -c --argjson total "$total" --arg user "$user_arg" '{source:"proc.snapshot",total_records:$total,user:$user}')
    _bl_obs_close_stream "$stream_path" 'proc.snapshot' "$summary"
}

# ---------------------------------------------------------------------------
# bl_observe_firewall — dump current firewall ruleset
# ---------------------------------------------------------------------------
bl_observe_firewall() {
    unset _BL_OBS_ID _BL_OBS_CLUSTER_N
    local backend_arg="auto"
    local fixture_file="${BL_FIREWALL_DUMP_FIXTURE:-}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backend) backend_arg="$2"; shift 2 ;;
            *)         bl_error_envelope observe "firewall: unknown option: $1"; return "$BL_EX_USAGE" ;;
        esac
    done

    local backend
    if [[ "$backend_arg" == "auto" ]]; then
        backend="$(_bl_obs_detect_firewall)" || {
            bl_error_envelope observe "firewall: no supported backend detected (apf|csf|nftables|iptables)"
            return "$BL_EX_NOT_FOUND"
        }
    else
        backend="$backend_arg"
    fi

    local stream_path
    stream_path="$(_bl_obs_open_stream 'firewall')"

    local tmpfile
    tmpfile=$(command mktemp)

    if [[ -n "$fixture_file" && -r "$fixture_file" ]]; then
        command cat "$fixture_file" > "$tmpfile"
    else
        case "$backend" in
            iptables)
                command iptables -L -n --line-numbers -v 2>/dev/null > "$tmpfile" || {   # requires root
                    bl_error_envelope observe "firewall: iptables dump requires root (backend=iptables)"
                    command rm -f "$tmpfile"; return "$BL_EX_PREFLIGHT_FAIL"
                }
                ;;
            nftables)
                command nft -a list ruleset 2>/dev/null > "$tmpfile" || {   # requires root
                    bl_error_envelope observe "firewall: nft dump requires root (backend=nftables)"
                    command rm -f "$tmpfile"; return "$BL_EX_PREFLIGHT_FAIL"
                }
                ;;
            apf)
                if [[ -r /etc/apf/deny_hosts.rules ]]; then
                    command cat /etc/apf/deny_hosts.rules > "$tmpfile"
                else
                    bl_error_envelope observe "firewall: apf rules not readable"
                    command rm -f "$tmpfile"; return "$BL_EX_PREFLIGHT_FAIL"
                fi
                ;;
            csf)
                if [[ -r /etc/csf/csf.deny ]]; then
                    command cat /etc/csf/csf.deny > "$tmpfile"
                else
                    bl_error_envelope observe "firewall: csf deny list not readable"
                    command rm -f "$tmpfile"; return "$BL_EX_PREFLIGHT_FAIL"
                fi
                ;;
            *)
                bl_error_envelope observe "firewall: unknown backend: $backend"
                command rm -f "$tmpfile"; return "$BL_EX_USAGE"
                ;;
        esac
    fi

    local total=0
    local bl_case_tag_re='bl-case (CASE-[0-9]{4}-[0-9]{4})'
    while IFS= read -r rule_line; do
        [[ -z "$rule_line" ]] && continue
        local bl_tag="null"
        if [[ "$rule_line" =~ $bl_case_tag_re ]]; then
            bl_tag="\"${BASH_REMATCH[1]}\""
        fi
        local rec
        rec=$(jq -n -c \
            --arg backend "$backend" \
            --arg rule "$rule_line" \
            --argjson bl_case_tag "$bl_tag" \
            '{backend:$backend,rule:$rule,bl_case_tag:$bl_case_tag}')
        _bl_obs_emit_jsonl 'firewall.rule' "$rec" "$stream_path" || { command rm -f "$tmpfile"; return "$BL_EX_SCHEMA_VALIDATION_FAIL"; }
        total=$((total + 1))
    done < "$tmpfile"

    command rm -f "$tmpfile"

    local summary
    summary=$(jq -n -c \
        --arg backend "$backend" \
        --argjson total "$total" \
        '{source:"firewall.rule",backend_meta:{backend:$backend},total_records:$total}')
    _bl_obs_close_stream "$stream_path" 'firewall.rule' "$summary"
}

# ---------------------------------------------------------------------------
# bl_observe_sigs — enumerate loaded scanner signatures
# ---------------------------------------------------------------------------
bl_observe_sigs() {
    unset _BL_OBS_ID _BL_OBS_CLUSTER_N
    local scanner_filter=""
    local fixture_dir="${BL_SIGS_FIXTURE_DIR:-}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scanner) scanner_filter="$2"; shift 2 ;;
            *)         bl_error_envelope observe "sigs: unknown option: $1"; return "$BL_EX_USAGE" ;;
        esac
    done

    local stream_path
    stream_path="$(_bl_obs_open_stream 'sigs')"

    local scanners_present=() scanners_missing=()
    local total=0

    _probe_scanner() {
        local name="$1"
        [[ -n "$scanner_filter" && "$scanner_filter" != "$name" ]] && return 0
        local sig_file=""
        case "$name" in
            lmd)
                # Fixture override path
                if [[ -n "$fixture_dir" && -r "$fixture_dir/maldet-sigs.hdb" ]]; then
                    sig_file="$fixture_dir/maldet-sigs.hdb"
                elif [[ -r /usr/local/maldetect/sigs/maldet.hdb ]]; then
                    sig_file="/usr/local/maldetect/sigs/maldet.hdb"
                elif [[ -r /var/lib/maldet/sigs/maldet.hdb ]]; then
                    sig_file="/var/lib/maldet/sigs/maldet.hdb"
                fi
                if [[ -z "$sig_file" ]]; then
                    scanners_missing+=("lmd"); return 0
                fi
                scanners_present+=("lmd")
                while IFS= read -r sigline; do
                    [[ -z "$sigline" || "$sigline" =~ ^# ]] && continue
                    local rec
                    rec=$(jq -n -c --arg scanner "lmd" --arg sig "$sigline" --arg sig_file "$sig_file" '{scanner:$scanner,sig:$sig,sig_file:$sig_file}')
                    _bl_obs_emit_jsonl 'sig.loaded' "$rec" "$stream_path" || return "$BL_EX_SCHEMA_VALIDATION_FAIL"
                    total=$((total + 1))
                done < "$sig_file"
                ;;
            clamav)
                local clam_db=""
                if [[ -n "$fixture_dir" && -r "$fixture_dir/main.cvd" ]]; then
                    clam_db="$fixture_dir/main.cvd"
                elif [[ -r /var/lib/clamav/main.cvd ]]; then
                    clam_db="/var/lib/clamav/main.cvd"
                elif [[ -r /var/lib/clamav/main.cld ]]; then
                    clam_db="/var/lib/clamav/main.cld"
                fi
                if [[ -z "$clam_db" ]]; then
                    scanners_missing+=("clamav"); return 0
                fi
                scanners_present+=("clamav")
                local db_version
                db_version=$(command sigtool --info "$clam_db" 2>/dev/null | command grep '^Version:' | command awk '{print $2}') || db_version="unknown"   # sigtool may be absent on older ClamAV — db_version falls back to unknown
                local rec
                rec=$(jq -n -c --arg scanner "clamav" --arg db_path "$clam_db" --arg db_version "$db_version" '{scanner:$scanner,db_path:$db_path,db_version:$db_version}')
                _bl_obs_emit_jsonl 'sig.loaded' "$rec" "$stream_path" || return "$BL_EX_SCHEMA_VALIDATION_FAIL"
                total=$((total + 1))
                ;;
            yara)
                local yara_rules_dir=""
                if [[ -n "$fixture_dir" && -d "$fixture_dir/yara" ]]; then
                    yara_rules_dir="$fixture_dir/yara"
                elif [[ -d /etc/yara/rules ]]; then
                    yara_rules_dir="/etc/yara/rules"
                elif [[ -d /usr/share/yara ]]; then
                    yara_rules_dir="/usr/share/yara"
                fi
                if [[ -z "$yara_rules_dir" ]]; then
                    scanners_missing+=("yara"); return 0
                fi
                scanners_present+=("yara")
                local rule_count
                rule_count=$(command find "$yara_rules_dir" -name '*.yar' -o -name '*.yara' 2>/dev/null | command wc -l | command awk '{print $1}')   # EACCES on locked rule dirs — zero count acceptable
                local rec
                rec=$(jq -n -c --arg scanner "yara" --arg rules_dir "$yara_rules_dir" --argjson rule_count "$rule_count" '{scanner:$scanner,rules_dir:$rules_dir,rule_count:$rule_count}')
                _bl_obs_emit_jsonl 'sig.loaded' "$rec" "$stream_path" || return "$BL_EX_SCHEMA_VALIDATION_FAIL"
                total=$((total + 1))
                ;;
        esac
    }

    if [[ -n "$scanner_filter" ]]; then
        case "$scanner_filter" in
            lmd|clamav|yara) _probe_scanner "$scanner_filter" || return "$?" ;;
            *)
                bl_error_envelope observe "sigs: unknown scanner: $scanner_filter (use lmd|clamav|yara)"
                unset -f _probe_scanner; return "$BL_EX_NOT_FOUND"
                ;;
        esac
    else
        _probe_scanner lmd || return "$?"
        _probe_scanner clamav || return "$?"
        _probe_scanner yara || return "$?"
    fi

    unset -f _probe_scanner

    if [[ ${#scanners_present[@]} -eq 0 ]]; then
        if [[ -n "$scanner_filter" ]]; then
            bl_error_envelope observe "sigs: scanner not found: $scanner_filter (sig database absent or unreadable)"
        else
            bl_error_envelope observe "sigs: no supported scanner found (checked: lmd, clamav, yara)"
        fi
        return "$BL_EX_NOT_FOUND"
    fi

    local present_json missing_json
    present_json=$(printf '%s\n' "${scanners_present[@]+"${scanners_present[@]}"}" | jq -Rsc 'split("\n")|map(select(.!=""))' 2>/dev/null) || present_json='[]'   # jq may fail on empty array; fallback to [] is safe
    missing_json=$(printf '%s\n' "${scanners_missing[@]+"${scanners_missing[@]}"}" | jq -Rsc 'split("\n")|map(select(.!=""))' 2>/dev/null) || missing_json='[]'   # jq may fail on empty array; fallback to [] is safe

    local summary
    summary=$(jq -n -c \
        --argjson total "$total" \
        --argjson present "$present_json" \
        --argjson missing "$missing_json" \
        '{source:"sig.loaded",total_records:$total,sig_scanners_present:$present,sig_scanners_missing:$missing}')
    _bl_obs_close_stream "$stream_path" 'sig.loaded' "$summary"
}

# ---------------------------------------------------------------------------
# bl_observe_substrate — host-substrate enumeration (12 categories, read-only)
# ---------------------------------------------------------------------------
# Emits one substrate.category record per axis the curator reasons about
# before authoring defense: kernel, libc, init, web, firewall, scanner,
# log_surface, cron, package_mgr, integrity, panel, virtualization. The
# substrate report is the curator's action-menu — without it every defend.*
# step is guesswork. Read-only: zero filesystem writes, zero network calls.
# Test affordance: BL_SUBSTRATE_PROBE_ROOT prefixes filesystem reads so a
# stripped-PATH + empty-root run exercises the missing-tool degradation path.
bl_observe_substrate() {
    unset _BL_OBS_ID _BL_OBS_CLUSTER_N

    if [[ $# -gt 0 ]]; then
        bl_error_envelope observe "substrate: no options accepted (got: $1)"
        return "$BL_EX_USAGE"
    fi

    local R="${BL_SUBSTRATE_PROBE_ROOT:-}"
    local stream_path
    stream_path="$(_bl_obs_open_stream 'substrate')"

    local start_s end_s
    start_s=$(command date +%s)

    local categories_present=()
    local categories_absent=()

    _emit_substrate() {
        local category="$1"
        local present_str="$2"   # "true" or "false" — JSON literal
        local extra_json="$3"    # additional fields object
        if [[ "$present_str" == "true" ]]; then
            categories_present+=("$category")
        else
            categories_absent+=("$category")
        fi
        local rec
        rec=$(jq -n -c \
            --arg category "$category" \
            --argjson present "$present_str" \
            --argjson extra "$extra_json" \
            '$extra + {category:$category, present:$present}') || return "$BL_EX_SCHEMA_VALIDATION_FAIL"
        _bl_obs_emit_jsonl 'substrate.category' "$rec" "$stream_path" || return "$?"
    }

    # 1. kernel + distro
    local os_id="" os_version_id="" kernel_release="" kernel_machine=""
    kernel_release=$(command uname -r 2>/dev/null) || true   # uname missing on stripped PATH — empty acceptable
    kernel_machine=$(command uname -m 2>/dev/null) || true   # uname missing on stripped PATH — empty acceptable
    if [[ -r "$R/etc/os-release" ]]; then
        os_id=$(command grep -E '^ID=' "$R/etc/os-release" | command head -1 | command sed -E 's/^ID=//;s/^"//;s/"$//') || true   # grep exit 1 when missing — empty acceptable
        os_version_id=$(command grep -E '^VERSION_ID=' "$R/etc/os-release" | command head -1 | command sed -E 's/^VERSION_ID=//;s/^"//;s/"$//') || true   # grep exit 1 when missing — empty acceptable
    fi
    local kernel_extra
    kernel_extra=$(jq -n -c \
        --arg os_id "$os_id" \
        --arg os_version_id "$os_version_id" \
        --arg kernel_release "$kernel_release" \
        --arg kernel_machine "$kernel_machine" \
        '{os_id:$os_id,os_version_id:$os_version_id,kernel_release:$kernel_release,kernel_machine:$kernel_machine,detected:[]}')
    if [[ -n "$kernel_release" || -n "$os_id" ]]; then
        _emit_substrate "kernel" true "$kernel_extra"
    else
        _emit_substrate "kernel" false "$kernel_extra"
    fi

    # 2. libc
    local libc_flavor="unknown" libc_version=""
    if command -v ldd >/dev/null 2>&1; then
        local ldd_out
        ldd_out=$(command ldd --version 2>&1 | command head -1) || true   # ldd --version exits 1 on musl — fallthrough handles it
        # GNU/glibc ldd output varies: "ldd (GNU libc) 2.39" / "ldd (Ubuntu GLIBC 2.35-...)" / "ldd (Debian GLIBC 2.36-...)"
        if [[ "$ldd_out" == *"GLIBC"* || "$ldd_out" == *"GNU libc"* || "$ldd_out" == *"GNU C Library"* || "$ldd_out" == *"glibc"* ]]; then
            libc_flavor="glibc"
            libc_version=$(printf '%s' "$ldd_out" | command grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | command head -1) || true   # version extraction may fail on unexpected output — empty acceptable
        elif [[ "$ldd_out" == *"musl"* ]]; then
            libc_flavor="musl"
            libc_version=$(printf '%s' "$ldd_out" | command grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | command head -1) || true   # version extraction may fail — empty acceptable
        fi
    fi
    local libc_extra
    libc_extra=$(jq -n -c --arg flavor "$libc_flavor" --arg version "$libc_version" '{flavor:$flavor,version:$version,detected:[]}')
    if [[ "$libc_flavor" != "unknown" ]]; then
        _emit_substrate "libc" true "$libc_extra"
    else
        _emit_substrate "libc" false "$libc_extra"
    fi

    # 3. init system
    local init_flavor="unknown"
    if [[ -d "$R/run/systemd/system" ]]; then
        init_flavor="systemd"
    elif command -v openrc-init >/dev/null 2>&1 || [[ -d "$R/etc/runlevels" ]]; then
        init_flavor="openrc"
    elif [[ -f "$R/etc/inittab" && -d "$R/etc/init" ]]; then
        init_flavor="upstart"
    elif [[ -f "$R/etc/inittab" || -d "$R/etc/init.d" ]]; then
        init_flavor="sysvinit"
    fi
    local init_extra
    init_extra=$(jq -n -c --arg flavor "$init_flavor" '{flavor:$flavor,detected:[]}')
    if [[ "$init_flavor" != "unknown" ]]; then
        _emit_substrate "init" true "$init_extra"
    else
        _emit_substrate "init" false "$init_extra"
    fi

    # 4. web server + modsec
    local web_detected='[]' web_present="false" modsec_loaded="false"
    local _web_probe
    for _web_probe in httpd apache2 nginx lighttpd openlitespeed litespeed; do
        if command -v "$_web_probe" >/dev/null 2>&1; then
            local _path
            _path=$(command -v "$_web_probe")
            web_detected=$(printf '%s' "$web_detected" | jq -c --arg n "$_web_probe" --arg p "$_path" '. + [{name:$n,version:null,path:$p,evidence:"command -v"}]')
            web_present="true"
        fi
    done
    if [[ -f "$R/etc/httpd/modules/mod_security2.so" \
       || -f "$R/etc/apache2/mods-enabled/security2.load" \
       || -d "$R/etc/modsecurity" \
       || -d "$R/etc/apache2/modsecurity.d" ]]; then
        modsec_loaded="true"
    fi
    local web_extra
    web_extra=$(jq -n -c --argjson detected "$web_detected" --argjson modsec_loaded "$modsec_loaded" '{detected:$detected,modsec_loaded:$modsec_loaded}')
    _emit_substrate "web" "$web_present" "$web_extra"

    # 5. firewall — reuse helper
    local fw_backend
    if fw_backend=$(_bl_obs_detect_firewall 2>/dev/null); then
        local fw_extra
        fw_extra=$(jq -n -c --arg backend "$fw_backend" '{backend:$backend,detected:[{name:$backend,version:null,path:null,evidence:"_bl_obs_detect_firewall"}]}')
        _emit_substrate "firewall" true "$fw_extra"
    else
        local fw_extra
        fw_extra=$(jq -n -c '{backend:"none",detected:[]}')
        _emit_substrate "firewall" false "$fw_extra"
    fi

    # 6. scanner stack (presence-only)
    local scanner_present_list='[]' scanner_present="false"
    local _sc_probe _sc_pairs="maldet:lmd clamscan:clamav yara:yara rkhunter:rkhunter"
    for _sc_probe in $_sc_pairs; do
        local _bin="${_sc_probe%%:*}" _name="${_sc_probe##*:}"
        if command -v "$_bin" >/dev/null 2>&1; then
            scanner_present_list=$(printf '%s' "$scanner_present_list" | jq -c --arg n "$_name" '. + [$n]')
            scanner_present="true"
        fi
    done
    local scanner_extra
    scanner_extra=$(jq -n -c --argjson present_list "$scanner_present_list" '{present_list:$present_list,detected:[]}')
    _emit_substrate "scanner" "$scanner_present" "$scanner_extra"

    # 7. log surface
    local log_flavor="none" log_journalctl_avail="false"
    if command -v journalctl >/dev/null 2>&1; then
        log_journalctl_avail="true"
        log_flavor="journald"
    elif [[ -d "$R/etc/rsyslog.d" || -f "$R/etc/rsyslog.conf" ]]; then
        log_flavor="rsyslog"
    elif [[ -f "$R/etc/syslog-ng/syslog-ng.conf" ]]; then
        log_flavor="syslog-ng"
    elif [[ -f "$R/etc/syslog.conf" ]]; then
        log_flavor="syslog"
    fi
    local log_extra
    log_extra=$(jq -n -c --arg flavor "$log_flavor" --argjson journalctl_available "$log_journalctl_avail" '{flavor:$flavor,journalctl_available:$journalctl_available,detected:[]}')
    if [[ "$log_flavor" != "none" ]]; then
        _emit_substrate "log_surface" true "$log_extra"
    else
        _emit_substrate "log_surface" false "$log_extra"
    fi

    # 8. cron
    local cron_flavors='[]' cron_present="false"
    if [[ -d "$R/etc/cron.d" ]]; then
        cron_flavors=$(printf '%s' "$cron_flavors" | jq -c '. + ["cron.d"]'); cron_present="true"
    fi
    if command -v crontab >/dev/null 2>&1; then
        cron_flavors=$(printf '%s' "$cron_flavors" | jq -c '. + ["crontab"]'); cron_present="true"
    fi
    if [[ -d "$R/etc/systemd/system" ]] && command -v systemctl >/dev/null 2>&1; then
        if command find "$R/etc/systemd/system" -maxdepth 2 -name '*.timer' 2>/dev/null | command head -1 | command grep -q .; then
            cron_flavors=$(printf '%s' "$cron_flavors" | jq -c '. + ["systemd-timers"]'); cron_present="true"
        fi
    fi
    if command -v fcron >/dev/null 2>&1; then
        cron_flavors=$(printf '%s' "$cron_flavors" | jq -c '. + ["fcron"]'); cron_present="true"
    fi
    local cron_extra
    cron_extra=$(jq -n -c --argjson flavors "$cron_flavors" '{flavors:$flavors,detected:[]}')
    _emit_substrate "cron" "$cron_present" "$cron_extra"

    # 9. package manager
    local pkg_flavor="unknown"
    if command -v rpm >/dev/null 2>&1; then pkg_flavor="rpm"
    elif command -v dpkg >/dev/null 2>&1; then pkg_flavor="dpkg"
    elif command -v apk >/dev/null 2>&1; then pkg_flavor="apk"
    elif command -v emerge >/dev/null 2>&1; then pkg_flavor="portage"
    elif command -v pkg >/dev/null 2>&1; then pkg_flavor="pkg"
    fi
    local pkg_extra
    pkg_extra=$(jq -n -c --arg flavor "$pkg_flavor" '{flavor:$flavor,detected:[]}')
    if [[ "$pkg_flavor" != "unknown" ]]; then
        _emit_substrate "package_mgr" true "$pkg_extra"
    else
        _emit_substrate "package_mgr" false "$pkg_extra"
    fi

    # 10. integrity tooling
    local integrity_tools='[]' integrity_present="false"
    if command -v rpm >/dev/null 2>&1; then
        integrity_tools=$(printf '%s' "$integrity_tools" | jq -c '. + ["rpm-V"]'); integrity_present="true"
    fi
    if command -v dpkg >/dev/null 2>&1; then
        integrity_tools=$(printf '%s' "$integrity_tools" | jq -c '. + ["dpkg-verify"]'); integrity_present="true"
    fi
    if command -v debsums >/dev/null 2>&1; then
        integrity_tools=$(printf '%s' "$integrity_tools" | jq -c '. + ["debsums"]'); integrity_present="true"
    fi
    if command -v aide >/dev/null 2>&1; then
        integrity_tools=$(printf '%s' "$integrity_tools" | jq -c '. + ["aide"]'); integrity_present="true"
    fi
    if command -v tripwire >/dev/null 2>&1; then
        integrity_tools=$(printf '%s' "$integrity_tools" | jq -c '. + ["tripwire"]'); integrity_present="true"
    fi
    local integrity_extra
    integrity_extra=$(jq -n -c --argjson tools "$integrity_tools" '{tools:$tools,detected:[]}')
    _emit_substrate "integrity" "$integrity_present" "$integrity_extra"

    # 11. shared-hosting panel
    local panel_flavor="none" panel_version=""
    if [[ -d "$R/usr/local/cpanel" ]]; then
        panel_flavor="cpanel"
        # shellcheck disable=SC2015  # A && B || true is intentional: empty version is acceptable when file is absent/unreadable
        [[ -r "$R/usr/local/cpanel/version" ]] && panel_version=$(command head -1 "$R/usr/local/cpanel/version" 2>/dev/null) || true   # version file may be absent on partial installs — empty acceptable
    elif [[ -d "$R/usr/local/psa" || -d "$R/opt/psa" ]]; then
        panel_flavor="plesk"
    elif [[ -d "$R/usr/local/directadmin" ]]; then
        panel_flavor="directadmin"
    elif [[ -d "$R/usr/local/CyberCP" ]]; then
        panel_flavor="cyberpanel"
    elif [[ -d "$R/usr/local/cwpsrv" ]]; then
        panel_flavor="cwp"
    elif [[ -d "$R/usr/local/vesta" ]]; then
        panel_flavor="vesta"
    fi
    local panel_extra
    panel_extra=$(jq -n -c --arg flavor "$panel_flavor" --arg version "$panel_version" '{flavor:$flavor,version:$version,detected:[]}')
    if [[ "$panel_flavor" != "none" ]]; then
        _emit_substrate "panel" true "$panel_extra"
    else
        _emit_substrate "panel" false "$panel_extra"
    fi

    # 12. virtualization
    local virt_flavor="bare"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local _v
        _v=$(command systemd-detect-virt 2>/dev/null) || _v="none"
        case "$_v" in
            none) virt_flavor="bare" ;;
            kvm|qemu) virt_flavor="kvm" ;;
            lxc|lxc-libvirt) virt_flavor="lxc" ;;
            docker) virt_flavor="docker" ;;
            vmware) virt_flavor="vmware" ;;
            *) [[ -n "$_v" && "$_v" != "none" ]] && virt_flavor="$_v" ;;
        esac
    elif [[ -e "$R/.dockerenv" ]]; then
        virt_flavor="docker"
    elif [[ -d "$R/proc/vz" ]]; then
        virt_flavor="openvz"
    elif [[ -r "$R/proc/1/cgroup" ]]; then
        if command grep -qE 'docker|kubepods' "$R/proc/1/cgroup" 2>/dev/null; then virt_flavor="docker"
        elif command grep -q 'lxc' "$R/proc/1/cgroup" 2>/dev/null; then virt_flavor="lxc"
        fi
    fi
    local virt_extra
    virt_extra=$(jq -n -c --arg flavor "$virt_flavor" '{flavor:$flavor,detected:[]}')
    _emit_substrate "virtualization" true "$virt_extra"

    end_s=$(command date +%s)
    local elapsed_ms=$(( (end_s - start_s) * 1000 ))

    local present_json missing_json
    present_json=$(printf '%s\n' "${categories_present[@]+"${categories_present[@]}"}" | jq -Rsc 'split("\n")|map(select(.!=""))' 2>/dev/null) || present_json='[]'   # jq fails on empty array — fallback safe
    missing_json=$(printf '%s\n' "${categories_absent[@]+"${categories_absent[@]}"}" | jq -Rsc 'split("\n")|map(select(.!=""))' 2>/dev/null) || missing_json='[]'   # jq fails on empty array — fallback safe

    local summary
    summary=$(jq -n -c \
        --argjson total 12 \
        --argjson present "$present_json" \
        --argjson missing "$missing_json" \
        --argjson elapsed_ms "$elapsed_ms" \
        '{source:"substrate.category",total_records:$total,categories_present:$present,categories_absent:$missing,elapsed_ms:$elapsed_ms}')
    _bl_obs_close_stream "$stream_path" 'substrate.category' "$summary"

    unset -f _emit_substrate
    return "$BL_EX_OK"
}

# ---------------------------------------------------------------------------
# bl_bundle_build — package current case evidence into a .tgz bundle
# ---------------------------------------------------------------------------
