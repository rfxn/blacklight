# shellcheck shell=bash
# ============================================================================
# M7 clean handlers — spec: DESIGN.md §5.5 + §11
# ----------------------------------------------------------------------------
# Region layout (top-down reading order = call depth):
#   1. Private helpers (_bl_clean_*) — backup, quarantine, dry-run gate
#   2. Verb handlers (bl_clean_*) — htaccess, cron, proc, file, undo, unquarantine
#   3. Top-level dispatcher (bl_clean) — replaces 80-stubs.sh stub
# ============================================================================

# === M7-HELPERS-BEGIN ===

# ---------------------------------------------------------------------------
# _bl_clean_ts_iso8601 — ISO-8601 UTC second-precision timestamp (canonical form)
# ---------------------------------------------------------------------------
_bl_clean_ts_iso8601() {
    command date -u +%Y-%m-%dT%H:%M:%SZ
}

# ---------------------------------------------------------------------------
# _bl_clean_ts_iso8601_fsafe — same but colons replaced with hyphens for
# filesystem-safe backup-id filenames. Mirrors M4 _bl_obs_open_stream pattern.
# ---------------------------------------------------------------------------
_bl_clean_ts_iso8601_fsafe() {
    _bl_clean_ts_iso8601 | command tr ':' '-'
}

# ---------------------------------------------------------------------------
# _bl_clean_sha256_content — full 64-hex sha256 of file content
# ---------------------------------------------------------------------------
_bl_clean_sha256_content() {
    local path="$1"
    if [[ ! -r "$path" ]]; then
        bl_error_envelope clean "sha256_content: path not readable: $path"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    # shellcheck disable=SC2005   # printf of cut output is intentional — keeps return-value pipeline shape
    printf '%s' "$(command sha256sum < "$path" | command cut -d' ' -f1)"
}

# ---------------------------------------------------------------------------
# _bl_clean_sha256_path — first 8 hex of sha256 of the PATH STRING (not content)
# Used for backup-id hash field per DESIGN.md §11.2 filename format.
# ---------------------------------------------------------------------------
_bl_clean_sha256_path() {
    local path="$1"
    printf '%s' "$path" | command sha256sum | command cut -c1-8
}

# ---------------------------------------------------------------------------
# _bl_clean_sanitize_basename — strip path components and replace whitespace
# with underscores; keep alnum + [-._]; drop everything else.
# ---------------------------------------------------------------------------
_bl_clean_sanitize_basename() {
    local input="$1"
    local base
    base="${input##*/}"
    # shellcheck disable=SC2001   # parameter expansion cannot express character-class sub
    base=$(printf '%s' "$base" | command sed 's|[^A-Za-z0-9._-]|_|g')
    printf '%s' "$base"
}

# ---------------------------------------------------------------------------
# _bl_clean_dry_run_emit — write dry-run receipt + print diff to stdout.
# Caller: the verb handler's --dry-run branch, after computing the diff.
# Returns 0 on success; 65 if /var/lib/bl/state/dry-run/ not writable.
# ---------------------------------------------------------------------------
_bl_clean_dry_run_emit() {
    local verb="$1"
    local target="$2"
    local diff_text="$3"
    local dir="$BL_VAR_DIR/state/dry-run"
    if ! command mkdir -p "$dir" 2>/dev/null; then   # RO fs / perms
        bl_error_envelope clean "dry-run state dir not writable: $dir"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    local sha receipt
    sha=$(_bl_clean_sha256_path "$target")
    receipt="$dir/${verb}-${sha}.ok"
    _bl_clean_ts_iso8601 > "$receipt"
    printf '%s\n' "$diff_text"
    return "$BL_EX_OK"
}

# ---------------------------------------------------------------------------
# _bl_clean_dry_run_check — enforce dry-run-before-apply gate per DESIGN §11.3.
# Returns 0 if a non-expired receipt exists (and consumes it); 68 otherwise.
# TTL: $BL_CLEAN_DRYRUN_TTL_SECS (default 300s).
# ---------------------------------------------------------------------------
_bl_clean_dry_run_check() {
    local verb="$1"
    local target="$2"
    local ttl="${BL_CLEAN_DRYRUN_TTL_SECS:-300}"
    local dir="$BL_VAR_DIR/state/dry-run"
    local sha receipt
    sha=$(_bl_clean_sha256_path "$target")
    receipt="$dir/${verb}-${sha}.ok"
    if [[ ! -r "$receipt" ]]; then
        bl_error_envelope clean "dry-run gate: receipt missing" "(run with --dry-run first, within ${ttl}s)"
        return "$BL_EX_TIER_GATE_DENIED"
    fi
    local now epoch age
    now=$(command date -u +%s)
    epoch=$(command date -u -d "$(command cat "$receipt")" +%s 2>/dev/null || printf '0')   # malformed receipt → age=now (fails age check)
    age=$(( now - epoch ))
    if (( age > ttl )); then
        command rm -f "$receipt"
        bl_error_envelope clean "dry-run gate: receipt expired (${age}s > ${ttl}s)" "(re-run with --dry-run)"
        return "$BL_EX_TIER_GATE_DENIED"
    fi
    command rm -f "$receipt"
    return "$BL_EX_OK"
}

# ---------------------------------------------------------------------------
# _bl_clean_prompt_operator — DESIGN.md §11.1 prompt semantics.
# Adapted from bl_run_prompt_operator (src/bl.d/60-run.sh:156) with clean-
# specific header text. Returns 0 on approve, 68 on decline.
# ---------------------------------------------------------------------------
_bl_clean_prompt_operator() {
    local verb="$1"
    local target="$2"
    local diff_text="$3"
    local backup_path="$4"   # may be empty for proc/file verbs
    local explain_text="$5"  # may be empty; overrides stub "explain"
    local ans
    printf 'bl-clean %s — target: %s\n' "$verb" "$target" >&2
    [[ -n "$diff_text" ]] && printf '[diff]\n%s\n' "$diff_text" >&2
    [[ -n "$backup_path" ]] && printf 'Backup will be written to: %s\n' "$backup_path" >&2
    while :; do
        printf 'Apply? [y/N/diff-full/explain/abort] ' >&2
        IFS= read -r ans || ans="${BL_PROMPT_DEFAULT:-N}"
        ans="${ans:-${BL_PROMPT_DEFAULT:-N}}"
        ans=$(printf '%s' "$ans" | command tr '[:upper:]' '[:lower:]')
        case "$ans" in
            y|yes)         return "$BL_EX_OK" ;;
            n|no|abort|'') return "$BL_EX_TIER_GATE_DENIED" ;;   # operator declined
            diff-full)
                printf '%s\n' "$diff_text" >&2
                ;;
            explain)
                if [[ -n "$explain_text" ]]; then
                    printf '%s\n' "$explain_text" >&2
                else
                    printf '(no curator reasoning field available for this step)\n' >&2
                fi
                ;;
            *)
                printf 'invalid; type y, N, diff-full, explain, or abort\n' >&2
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# _bl_clean_write_backup — copy source → /var/lib/bl/backups/<id>; write
# sidecar .meta.json validated against schemas/backup-manifest.json at Phase-4
# test time. Prints backup-id (basename) on stdout; returns 0 / 65 / 71.
# Callers: bl_clean_htaccess, bl_clean_cron.
# ---------------------------------------------------------------------------
_bl_clean_write_backup() {
    local source_path="$1"
    local verb="$2"
    local case_id="$3"   # may be empty for operator-local dry-run exploration (§backup-manifest.md)
    local backup_root="$BL_VAR_DIR/backups"
    if ! command mkdir -p "$backup_root" 2>/dev/null; then   # RO fs / perms
        bl_error_envelope clean "backup root not writable: $backup_root"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    if [[ ! -r "$source_path" ]]; then
        bl_error_envelope clean "backup source not readable: $source_path"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    local ts_fsafe ts_canonical path_hash base backup_id backup_path meta_path
    ts_fsafe=$(_bl_clean_ts_iso8601_fsafe)
    ts_canonical=$(_bl_clean_ts_iso8601)
    path_hash=$(_bl_clean_sha256_path "$source_path")
    base=$(_bl_clean_sanitize_basename "$source_path")
    backup_id="${ts_fsafe}.${path_hash}.${base}"
    backup_path="$backup_root/$backup_id"
    meta_path="$backup_path.meta.json"
    if [[ -e "$backup_path" ]]; then
        bl_error_envelope clean "backup_id collision: $backup_id"
        return "$BL_EX_CONFLICT"
    fi
    # Capture metadata BEFORE copy so the manifest reflects pre-edit state
    local uid gid perms mtime size sha_pre
    uid=$(command stat -c '%u' "$source_path" 2>/dev/null || command stat -f '%u' "$source_path")   # BSD fallback
    gid=$(command stat -c '%g' "$source_path" 2>/dev/null || command stat -f '%g' "$source_path")   # BSD fallback
    perms=$(command stat -c '%a' "$source_path" 2>/dev/null || command stat -f '%A' "$source_path")   # BSD fallback
    mtime=$(command stat -c '%Y' "$source_path" 2>/dev/null || command stat -f '%m' "$source_path")   # BSD fallback
    size=$(command stat -c '%s' "$source_path" 2>/dev/null || command stat -f '%z' "$source_path")   # BSD fallback
    sha_pre=$(_bl_clean_sha256_content "$source_path") || return $?
    # perms may come back as e.g. "644" (no leading zero); pad to 4 digits
    local perms_octal
    perms_octal=$(printf '%04d' "$perms")
    # command cp -p preserves mode/ownership/timestamps on the backup copy
    command cp -p "$source_path" "$backup_path" || {   # copy failure invalidates backup
        bl_error_envelope clean "backup cp failed: $source_path → $backup_path"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    # Emit sidecar meta.json
    jq -n \
        --arg id "$backup_id" \
        --arg op "$source_path" \
        --arg sha "$sha_pre" \
        --argjson sz "$size" \
        --argjson u "$uid" \
        --argjson g "$gid" \
        --arg perms "$perms_octal" \
        --argjson m "$mtime" \
        --arg cid "$case_id" \
        --arg v "$verb" \
        --arg ts "$ts_canonical" \
        '{
            backup_id:$id,
            original_path:$op,
            sha256_pre:$sha,
            size_bytes:$sz,
            uid:$u,
            gid:$g,
            perms_octal:$perms,
            mtime_epoch:$m,
            case_id:(if $cid=="" then null else $cid end),
            verb:$v,
            iso_ts:$ts
        }' > "$meta_path"
    printf '%s' "$backup_id"
    return "$BL_EX_OK"
}

# ---------------------------------------------------------------------------
# _bl_clean_write_quarantine — move source → /var/lib/bl/quarantine/<case>/
# <sha256>-<basename>; write sidecar .meta.json. Prints entry-id on stdout.
# Returns 0 / 65 / 71 / 72.
# Callers: bl_clean_file.
# ---------------------------------------------------------------------------
_bl_clean_write_quarantine() {
    local source_path="$1"
    local case_id="$2"
    local reason="$3"
    if [[ -z "$case_id" ]]; then
        bl_error_envelope clean "quarantine requires active case-id"
        return "$BL_EX_NOT_FOUND"
    fi
    if [[ ! -r "$source_path" ]]; then
        bl_error_envelope clean "quarantine source not readable: $source_path"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    local quar_root="$BL_VAR_DIR/quarantine/$case_id"
    if ! command mkdir -p "$quar_root" 2>/dev/null; then   # RO fs / perms
        bl_error_envelope clean "quarantine dir not writable: $quar_root"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    local sha base entry_id entry_path meta_path
    sha=$(_bl_clean_sha256_content "$source_path") || return $?
    base=$(_bl_clean_sanitize_basename "$source_path")
    entry_id="${sha}-${base}"
    entry_path="$quar_root/$entry_id"
    meta_path="$entry_path.meta.json"
    if [[ -e "$entry_path" ]]; then
        bl_error_envelope clean "quarantine entry_id collision: $entry_id"
        return "$BL_EX_CONFLICT"
    fi
    local uid gid perms mtime size perms_octal ts_canonical
    uid=$(command stat -c '%u' "$source_path" 2>/dev/null || command stat -f '%u' "$source_path")   # BSD fallback
    gid=$(command stat -c '%g' "$source_path" 2>/dev/null || command stat -f '%g' "$source_path")   # BSD fallback
    perms=$(command stat -c '%a' "$source_path" 2>/dev/null || command stat -f '%A' "$source_path")   # BSD fallback
    mtime=$(command stat -c '%Y' "$source_path" 2>/dev/null || command stat -f '%m' "$source_path")   # BSD fallback
    size=$(command stat -c '%s' "$source_path" 2>/dev/null || command stat -f '%z' "$source_path")   # BSD fallback
    perms_octal=$(printf '%04d' "$perms")
    ts_canonical=$(_bl_clean_ts_iso8601)
    # mv (not cp + rm) for atomicity on same filesystem; falls back to cp+rm
    # across filesystems automatically (coreutils mv does this internally)
    command mv "$source_path" "$entry_path" || {   # move failure — target still exists, abort
        bl_error_envelope clean "quarantine mv failed: $source_path → $entry_path"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    jq -n \
        --arg id "$entry_id" \
        --arg op "$source_path" \
        --arg sha "$sha" \
        --argjson sz "$size" \
        --argjson u "$uid" \
        --argjson g "$gid" \
        --arg perms "$perms_octal" \
        --argjson m "$mtime" \
        --arg cid "$case_id" \
        --arg r "$reason" \
        --arg ts "$ts_canonical" \
        '{
            entry_id:$id,
            original_path:$op,
            sha256:$sha,
            size_bytes:$sz,
            uid:$u,
            gid:$g,
            perms_octal:$perms,
            mtime_epoch:$m,
            case_id:$cid,
            reason:(if $r=="" then null else $r end),
            iso_ts:$ts
        }' > "$meta_path"
    printf '%s' "$entry_id"
    return "$BL_EX_OK"
}

# === M7-HELPERS-END ===

# === M7-HANDLERS-BEGIN ===
# Phase 3 lands bl_clean_* handlers + dispatcher here.
# === M7-HANDLERS-END ===
