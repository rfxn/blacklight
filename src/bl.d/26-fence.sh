# shellcheck shell=bash
# ----------------------------------------------------------------------------
# Fence primitive — DESIGN.md §13.2 prompt-injection hardening.
# Token derivation: sha256(case_id || payload || nonce)[:16] (64-bit entropy).
# Wrap envelope: <untrusted fence="TOKEN" kind="KIND" case="CASE">…</untrusted-TOKEN>
# Closing tag is token-bound — fixed </untrusted> would permit payload escape.
# ----------------------------------------------------------------------------

readonly BL_FENCE_MAX_REDERIVE=4
readonly BL_FENCE_TOKEN_LEN=16

bl_fence_derive() {
    # bl_fence_derive <case-id> <payload> [nonce] — 0/*
    local case_id="$1" payload="$2" nonce="${3:-}"
    if [[ -z "$nonce" ]]; then
        # bash 4.1+ floor: never use $EPOCHREALTIME/$EPOCHSECONDS (bash 5.0+, prohibited)
        nonce="$(date +%s%N)-$RANDOM$RANDOM"
    fi
    printf '%s%s%s' "$case_id" "$payload" "$nonce" | command sha256sum | command cut -c1-"$BL_FENCE_TOKEN_LEN"
}

bl_fence_wrap() {
    # bl_fence_wrap <case-id> <kind> <payload-file> — 0/71 (collision)
    local case_id="$1" kind="$2" payload_file="$3"
    [[ -r "$payload_file" ]] || { bl_error_envelope fence "payload not readable: $payload_file"; return "$BL_EX_PREFLIGHT_FAIL"; }
    local payload token attempts=0
    payload=$(command cat "$payload_file")   # preserves bytes incl. trailing newline semantics
    while (( attempts < BL_FENCE_MAX_REDERIVE )); do
        token=$(bl_fence_derive "$case_id" "$payload")
        # Collision scan: token-literal AND close-tag-literal
        if ! printf '%s' "$payload" | command grep -qF "$token" && \
           ! printf '%s' "$payload" | command grep -qF "</untrusted-$token>"; then
            printf '<untrusted fence="%s" kind="%s" case="%s">%s</untrusted-%s>\n' \
                "$token" "$kind" "$case_id" "$payload" "$token"
            return "$BL_EX_OK"
        fi
        attempts=$((attempts + 1))
        bl_debug "bl_fence_wrap: collision attempt $attempts/$BL_FENCE_MAX_REDERIVE (token=$token)"
    done
    bl_error_envelope fence "fence-collision after $BL_FENCE_MAX_REDERIVE attempts"
    # shellcheck disable=SC2154  # BL_EX_CONFLICT defined in 00-header.sh
    return "$BL_EX_CONFLICT"
}

bl_fence_unwrap() {
    # bl_fence_unwrap <envelope> — stdout payload / 0/67
    # Envelope may be multi-line; sed single-line mode cannot span — use awk.
    local envelope="$1"
    # Extract TOKEN from opening tag (first line match is fine — open tag is single-line)
    local token
    # Explicit 16-class regex (no `{16}` quantifier) — mawk default on Debian
    # / Ubuntu does not parse interval quantifiers, and gawk 3.1.7 (CentOS 6)
    # needs --re-interval. Literal repetition is portable across all three.
    token=$(printf '%s' "$envelope" | command awk 'match($0, /<untrusted fence="[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]"/) { s=substr($0,RSTART+18,16); print s; exit }')   # +18: length("<untrusted fence=\"")
    [[ -z "$token" || ! "$token" =~ ^[a-f0-9]{16}$ ]] && { bl_error_envelope fence "malformed envelope: no fence attr"; return "$BL_EX_SCHEMA_VALIDATION_FAIL"; }
    # Validate matching close tag </untrusted-TOKEN> appears anywhere in envelope
    printf '%s' "$envelope" | command grep -qF "</untrusted-$token>" || {
        bl_error_envelope fence "open-fence != close-fence suffix (token=$token)"
        return "$BL_EX_SCHEMA_VALIDATION_FAIL"
    }
    # Extract payload between open tag's closing `>` and close tag's opening `<` — awk multi-line extraction.
    # Algorithm: strip from start through the first `>` that closes the <untrusted ...> open tag;
    #            then strip from the start of </untrusted-TOKEN> to end.
    printf '%s' "$envelope" | command awk -v tok="$token" '
        BEGIN { opened=0 }
        {
            if (!opened) {
                idx = index($0, "<untrusted fence=\"" tok "\"")
                if (idx > 0) {
                    gt = index(substr($0, idx), ">")
                    if (gt > 0) { $0 = substr($0, idx + gt); opened=1 }
                    else next
                } else next
            }
            close_tag = "</untrusted-" tok ">"
            ci = index($0, close_tag)
            if (ci > 0) { printf "%s", substr($0, 1, ci - 1); exit }
            printf "%s\n", $0
        }'
    return "$BL_EX_OK"
}

bl_fence_kind() {
    # bl_fence_kind <envelope> — stdout kind / 0/67
    local envelope="$1" kind
    kind=$(printf '%s' "$envelope" | command sed -n 's/.*<untrusted [^>]*kind="\([^"]*\)".*/\1/p' | command head -n1)
    [[ -z "$kind" ]] && { bl_error_envelope fence "malformed envelope: no kind attr"; return "$BL_EX_SCHEMA_VALIDATION_FAIL"; }
    printf '%s' "$kind"
    return "$BL_EX_OK"
}
