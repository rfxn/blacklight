# shellcheck shell=bash
# ----------------------------------------------------------------------------
# bl_messages_call — Messages API wrapper (POST /v1/messages, non-Managed-Agents).
# Used by:
#   - bl_bundle_build  → Sonnet 4.6 summary.md render (src/bl.d/42-observe-router.sh)
#   - _bl_defend_sig_fp_gate → Haiku 4.5 FP-corpus adjudication (src/bl.d/82-defend.sh)
# Distinct from bl_api_call (src/bl.d/20-api.sh) — that wrapper targets
# Managed Agents endpoints and carries the anthropic-beta header. Messages
# API is GA — no beta header. Same retry/backoff shape (4 attempts: 2s, 5s,
# 10s, 30s).
# ----------------------------------------------------------------------------

bl_messages_call() {
    # bl_messages_call <model> <system-prompt-file> <user-message-file> [max-tokens]
    # Returns response text (concatenated text content blocks) on stdout.
    # Exit codes: 0=ok; 65=auth/4xx; 69=upstream/5xx-after-retry; 70=429-after-retry;
    # 67=schema-validation-fail (response missing .content[].text).
    local model="$1"
    local sys_file="$2"
    local user_file="$3"
    local max_tokens="${4:-1024}"

    if [[ -z "$model" || -z "$sys_file" || -z "$user_file" ]]; then
        bl_error_envelope models "bl_messages_call: model + system + user files required"
        return "$BL_EX_USAGE"
    fi
    if [[ ! -r "$sys_file" || ! -r "$user_file" ]]; then
        bl_error_envelope models "bl_messages_call: prompt file unreadable"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    local body_file
    body_file=$(command mktemp)
    jq -n \
        --arg model "$model" \
        --rawfile sys "$sys_file" \
        --rawfile usr "$user_file" \
        --argjson max "$max_tokens" \
        '{
            model: $model,
            max_tokens: $max,
            system: $sys,
            messages: [{role:"user", content:[{type:"text", text:$usr}]}]
        }' > "$body_file"

    local attempt=0
    local backoffs=(2 5 10 30)
    local resp http_status body
    while (( attempt < 4 )); do
        resp=$(curl -sS --max-time 30 -w '\n%{http_code}' -X POST \
            -H "x-api-key: $ANTHROPIC_API_KEY" \
            -H "anthropic-version: 2023-06-01" \
            -H "content-type: application/json" \
            --data-binary "@$body_file" \
            "https://api.anthropic.com/v1/messages" 2>&1) || true   # retry handles curl exit
        http_status="${resp##*$'\n'}"
        body="${resp%$'\n'*}"
        case "$http_status" in
            2??)
                command rm -f "$body_file"
                local text
                text=$(printf '%s' "$body" | jq -r '.content // [] | map(select(.type=="text")) | map(.text) | join("\n")' 2>/dev/null) || {   # malformed response → fail-closed
                    bl_error_envelope models "bl_messages_call: response missing .content[].text"
                    return "$BL_EX_SCHEMA_VALIDATION_FAIL"
                }
                [[ -z "$text" ]] && {
                    bl_error_envelope models "bl_messages_call: empty response text"
                    return "$BL_EX_SCHEMA_VALIDATION_FAIL"
                }
                printf '%s' "$text"
                return "$BL_EX_OK"
                ;;
            401|403)
                command rm -f "$body_file"
                bl_error_envelope models "messages auth failed (HTTP $http_status)"
                bl_debug "bl_messages_call: body=$body"
                return "$BL_EX_PREFLIGHT_FAIL"
                ;;
            429)
                attempt=$((attempt + 1))
                (( attempt >= 4 )) && { command rm -f "$body_file"; bl_error_envelope models "messages rate limited after retries"; return "$BL_EX_RATE_LIMITED"; }
                bl_debug "bl_messages_call: 429, backing off ${backoffs[attempt-1]}s"
                sleep "${backoffs[attempt-1]}"
                ;;
            5??)
                attempt=$((attempt + 1))
                (( attempt >= 4 )) && { command rm -f "$body_file"; bl_error_envelope models "messages upstream error (HTTP $http_status) after retries"; return "$BL_EX_UPSTREAM_ERROR"; }
                sleep "${backoffs[attempt-1]}"
                ;;
            4??)
                command rm -f "$body_file"
                bl_error_envelope models "messages client error (HTTP $http_status)"
                bl_debug "bl_messages_call: body=$body"
                return "$BL_EX_PREFLIGHT_FAIL"
                ;;
            *)
                attempt=$((attempt + 1))
                (( attempt >= 4 )) && { command rm -f "$body_file"; bl_error_envelope models "messages unexpected response (HTTP ${http_status:-?}) after retries"; return "$BL_EX_UPSTREAM_ERROR"; }
                sleep "${backoffs[attempt-1]}"
                ;;
        esac
    done
    command rm -f "$body_file"
    return "$BL_EX_UPSTREAM_ERROR"
}
