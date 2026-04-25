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

# ---------------------------------------------------------------------------
# bl_clean_htaccess <dir> [--patch <patch-file>] [--dry-run] [--yes]
# DESIGN.md §5.5 htaccess pattern: show diff → backup → apply. The patch file
# (agent-authored) contains the target diff in unified-diff format; the
# wrapper applies it via `patch -p0`. For operator-crafted cleanups without
# a curator patch, --patch can name a file the operator wrote by hand.
# ---------------------------------------------------------------------------
bl_clean_htaccess() {
    local dir="" patch_file="" dry_run="" yes=""
    while (( $# > 0 )); do
        case "$1" in
            --patch)    patch_file="$2"; shift 2 ;;
            --dry-run)  dry_run="yes"; shift ;;
            --yes)      yes="yes"; shift ;;
            -*)         bl_error_envelope clean "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)          dir="$1"; shift ;;
        esac
    done
    [[ -z "$dir" ]] && { bl_error_envelope clean "missing <dir>"; return "$BL_EX_USAGE"; }
    local target="$dir/.htaccess"
    if [[ ! -r "$target" ]]; then
        bl_error_envelope clean "no .htaccess in $dir"
        return "$BL_EX_NOT_FOUND"
    fi
    [[ -z "$patch_file" ]] && { bl_error_envelope clean "--patch <file> required for clean.htaccess"; return "$BL_EX_USAGE"; }
    if [[ ! -r "$patch_file" ]]; then
        bl_error_envelope clean "patch file not readable: $patch_file"
        return "$BL_EX_USAGE"
    fi
    local case_id
    case_id=$(bl_case_current)
    # Build the diff text for display: show what patch WOULD do via --dry-run
    local diff_text
    diff_text=$(command cat "$patch_file")
    if [[ "$dry_run" == "yes" ]]; then
        _bl_clean_dry_run_emit "clean.htaccess" "$target" "$diff_text"
        return $?
    fi
    _bl_clean_dry_run_check "clean.htaccess" "$target" || return $?
    if [[ "$yes" != "yes" ]]; then
        local backup_preview
        backup_preview="$BL_VAR_DIR/backups/<ISO-ts>.<hash>.$(_bl_clean_sanitize_basename "$target")"
        _bl_clean_prompt_operator "clean.htaccess" "$target" "$diff_text" "$backup_preview" "" || return $?
    fi
    local backup_id
    backup_id=$(_bl_clean_write_backup "$target" "clean.htaccess" "$case_id") || return $?
    # Apply patch. -p0 = no path stripping (patch paths are exactly what the curator emitted).
    # --forward = skip reversed/already-applied; --dry-run inside patch DOES NOT WRITE; we use real apply here.
    if ! command patch -p0 --forward -s "$target" < "$patch_file"; then   # bad patch → restore from backup
        command cp -p "$BL_VAR_DIR/backups/$backup_id" "$target"
        bl_error_envelope clean "patch apply failed; restored from $backup_id"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    [[ -n "$case_id" ]] && bl_ledger_append "$case_id" \
        "$(jq -n --arg ts "$(_bl_clean_ts_iso8601)" --arg c "$case_id" --arg t "$target" --arg b "$backup_id" \
            '{ts:$ts, case:$c, kind:"clean_apply", payload:{verb:"clean.htaccess", target:$t, backup_id:$b}}')"
    bl_info "clean.htaccess applied; backup=$backup_id"
    return "$BL_EX_OK"
}

# ---------------------------------------------------------------------------
# bl_clean_cron --user <user> [--patch <patch-file>] [--dry-run] [--yes]
# DESIGN.md §5.5 cron pattern: dump current crontab → diff against patched
# form → backup (crontab -l output) → crontab -u install patched.
# ---------------------------------------------------------------------------
bl_clean_cron() {
    local user="" patch_file="" dry_run="" yes=""
    while (( $# > 0 )); do
        case "$1" in
            --user)     user="$2"; shift 2 ;;
            --patch)    patch_file="$2"; shift 2 ;;
            --dry-run)  dry_run="yes"; shift ;;
            --yes)      yes="yes"; shift ;;
            -*)         bl_error_envelope clean "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)          bl_error_envelope clean "unexpected positional: $1"; return "$BL_EX_USAGE" ;;
        esac
    done
    [[ -z "$user" ]] && { bl_error_envelope clean "missing --user <user>"; return "$BL_EX_USAGE"; }
    [[ -z "$patch_file" ]] && { bl_error_envelope clean "--patch <file> required for clean.cron"; return "$BL_EX_USAGE"; }
    if [[ ! -r "$patch_file" ]]; then
        bl_error_envelope clean "patch file not readable: $patch_file"
        return "$BL_EX_USAGE"
    fi
    # Dump current crontab (may be empty)
    local cur_tmp
    cur_tmp=$(mktemp)
    command crontab -u "$user" -l > "$cur_tmp" 2>/dev/null || printf '' > "$cur_tmp"   # crontab -l exits 1 on no-crontab; treat as empty
    # Target "path" for dry-run receipt keying (not a real filesystem path but
    # functions as a stable key for _bl_clean_dry_run_{emit,check})
    local target="crontab:$user"
    local diff_text
    diff_text=$(command cat "$patch_file")
    if [[ "$dry_run" == "yes" ]]; then
        command rm -f "$cur_tmp"
        _bl_clean_dry_run_emit "clean.cron" "$target" "$diff_text"
        return $?
    fi
    local _rc
    _bl_clean_dry_run_check "clean.cron" "$target"; _rc=$?
    if (( _rc != 0 )); then command rm -f "$cur_tmp"; return "$_rc"; fi
    if [[ "$yes" != "yes" ]]; then
        local backup_preview="$BL_VAR_DIR/backups/<ISO-ts>.<hash>.crontab_${user}"
        _bl_clean_prompt_operator "clean.cron" "$target" "$diff_text" "$backup_preview" ""; _rc=$?
        if (( _rc != 0 )); then command rm -f "$cur_tmp"; return "$_rc"; fi
    fi
    # Write the current crontab dump as a backup source file first
    local cur_snapshot="$BL_VAR_DIR/state/cron-snapshot-${user}.txt"
    command mkdir -p "$BL_VAR_DIR/state"
    command cp "$cur_tmp" "$cur_snapshot"
    local case_id backup_id
    case_id=$(bl_case_current)
    backup_id=$(_bl_clean_write_backup "$cur_snapshot" "clean.cron" "$case_id"); _rc=$?
    if (( _rc != 0 )); then command rm -f "$cur_tmp" "$cur_snapshot"; return "$_rc"; fi
    # Apply patch to the snapshot; install result via crontab -u <user>
    if ! command patch -p0 --forward -s "$cur_snapshot" < "$patch_file"; then
        command rm -f "$cur_tmp" "$cur_snapshot"
        bl_error_envelope clean "cron patch apply failed; no changes made; backup=$backup_id"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    if ! command crontab -u "$user" "$cur_snapshot"; then   # crontab install failure is recoverable: backup still valid
        command rm -f "$cur_tmp" "$cur_snapshot"
        bl_error_envelope clean "crontab install failed; use bl clean --undo $backup_id to restore"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    command rm -f "$cur_tmp" "$cur_snapshot"
    [[ -n "$case_id" ]] && bl_ledger_append "$case_id" \
        "$(jq -n --arg ts "$(_bl_clean_ts_iso8601)" --arg c "$case_id" --arg u "$user" --arg b "$backup_id" \
            '{ts:$ts, case:$c, kind:"clean_apply", payload:{verb:"clean.cron", user:$u, backup_id:$b}}')"
    bl_info "clean.cron applied; user=$user; backup=$backup_id"
    return "$BL_EX_OK"
}

# ---------------------------------------------------------------------------
# bl_clean_proc <pid> [--capture] [--dry-run] [--yes]
# DESIGN.md §5.5 + §11.5: snapshot /proc/<pid>/{cmdline,environ,exe,cwd,
# maps,status} + `lsof -p <pid>` to case evidence → SIGTERM → grace-window
# → SIGKILL. Default: capture on. --capture=off disables (operator must pass
# --capture=off explicitly per DESIGN §11.5).
# ---------------------------------------------------------------------------
bl_clean_proc() {
    local pid="" dry_run="" yes="" capture="on"
    while (( $# > 0 )); do
        case "$1" in
            --capture)     capture="on"; shift ;;
            --capture=on)  capture="on"; shift ;;
            --capture=off) capture="off"; shift ;;
            --dry-run)     dry_run="yes"; shift ;;
            --yes)         yes="yes"; shift ;;
            -*)            bl_error_envelope clean "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)             pid="$1"; shift ;;
        esac
    done
    [[ -z "$pid" ]] && { bl_error_envelope clean "missing <pid>"; return "$BL_EX_USAGE"; }
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        bl_error_envelope clean "pid must be numeric: $pid"
        return "$BL_EX_USAGE"
    fi
    if [[ ! -d "/proc/$pid" ]]; then
        bl_error_envelope clean "pid not running: $pid"
        return "$BL_EX_NOT_FOUND"
    fi
    local case_id
    case_id=$(bl_case_current)
    local target="pid:$pid"
    # Dry-run: describe what would happen, write receipt
    local plan_text
    plan_text=$(printf 'Plan: capture /proc/%s/{cmdline,environ,exe,cwd,maps,status} + lsof → case evidence; SIGTERM; sleep %ss; SIGKILL if still alive.\ncapture=%s' \
        "$pid" "${BL_CLEAN_PROC_GRACE_SECS:-5}" "$capture")
    if [[ "$dry_run" == "yes" ]]; then
        _bl_clean_dry_run_emit "clean.proc" "$target" "$plan_text"
        return $?
    fi
    _bl_clean_dry_run_check "clean.proc" "$target" || return $?
    if [[ "$yes" != "yes" ]]; then
        _bl_clean_prompt_operator "clean.proc" "$target" "$plan_text" "" "" || return $?
    fi
    # Capture (always unless --capture=off)
    if [[ "$capture" == "on" ]]; then
        [[ -z "$case_id" ]] && { bl_error_envelope clean "capture requires active case-id (use --capture=off to skip)"; return "$BL_EX_NOT_FOUND"; }
        local evid_dir="$BL_VAR_DIR/cases/$case_id/evidence/proc-$pid"
        command mkdir -p "$evid_dir"
        local f
        for f in cmdline environ status maps; do
            command cat "/proc/$pid/$f" > "$evid_dir/$f" 2>/dev/null || printf '' > "$evid_dir/$f"   # proc reads race-on-exit
        done
        # exe / cwd are symlinks; readlink captures the target
        command readlink "/proc/$pid/exe" > "$evid_dir/exe" 2>/dev/null || printf '' > "$evid_dir/exe"   # readlink may EACCES on cross-uid proc
        command readlink "/proc/$pid/cwd" > "$evid_dir/cwd" 2>/dev/null || printf '' > "$evid_dir/cwd"   # same EACCES path
        if command -v lsof >/dev/null 2>&1; then   # lsof is optional but strongly preferred
            command lsof -p "$pid" > "$evid_dir/lsof" 2>/dev/null || printf '' > "$evid_dir/lsof"   # lsof may exit non-zero on disappearing pid
        else
            bl_warn "lsof not available; skipping lsof capture for pid=$pid"
        fi
    fi
    # SIGTERM → grace window → SIGKILL
    local grace="${BL_CLEAN_PROC_GRACE_SECS:-5}"
    command kill -TERM "$pid" 2>/dev/null || true   # pid may have exited between check and here
    sleep "$grace"
    if [[ -d "/proc/$pid" ]]; then
        command kill -KILL "$pid" 2>/dev/null || true   # same race; kill errors are benign at this point
    fi
    [[ -n "$case_id" ]] && bl_ledger_append "$case_id" \
        "$(jq -n --arg ts "$(_bl_clean_ts_iso8601)" --arg c "$case_id" --argjson p "$pid" --arg cap "$capture" --argjson g "$grace" \
            '{ts:$ts, case:$c, kind:"clean_apply", payload:{verb:"clean.proc", pid:$p, capture:$cap, grace_secs:$g}}')"
    bl_info "clean.proc applied; pid=$pid; grace=${grace}s; capture=$capture"
    return "$BL_EX_OK"
}

# ---------------------------------------------------------------------------
# bl_clean_file <path> [--reason <str>] [--dry-run] [--yes]
# DESIGN.md §5.5 + §11.4: never unlink. Move source → quarantine with
# manifest entry. Operator-rescue via `bl clean --unquarantine <entry>`.
# ---------------------------------------------------------------------------
bl_clean_file() {
    local path="" reason="" dry_run="" yes=""
    while (( $# > 0 )); do
        case "$1" in
            --reason)   reason="$2"; shift 2 ;;
            --dry-run)  dry_run="yes"; shift ;;
            --yes)      yes="yes"; shift ;;
            -*)         bl_error_envelope clean "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)          path="$1"; shift ;;
        esac
    done
    [[ -z "$path" ]] && { bl_error_envelope clean "missing <path>"; return "$BL_EX_USAGE"; }
    if [[ ! -e "$path" ]]; then
        bl_error_envelope clean "path not found: $path"
        return "$BL_EX_NOT_FOUND"
    fi
    local case_id
    case_id=$(bl_case_current)
    [[ -z "$case_id" ]] && { bl_error_envelope clean "quarantine requires active case-id"; return "$BL_EX_NOT_FOUND"; }
    local plan_text
    # shellcheck disable=SC2016   # $BL_VAR_DIR in single quotes is intentional — plan_text is display-only; literal $ communicates the variable name to the operator
    plan_text=$(printf 'Plan: move %s → $BL_VAR_DIR/quarantine/%s/<sha256>-<basename>; write sidecar meta.json.\nreason: %s' \
        "$path" "$case_id" "${reason:-(none)}")
    if [[ "$dry_run" == "yes" ]]; then
        _bl_clean_dry_run_emit "clean.file" "$path" "$plan_text"
        return $?
    fi
    _bl_clean_dry_run_check "clean.file" "$path" || return $?
    if [[ "$yes" != "yes" ]]; then
        local quar_preview
        quar_preview="$BL_VAR_DIR/quarantine/$case_id/<sha256>-$(_bl_clean_sanitize_basename "$path")"
        _bl_clean_prompt_operator "clean.file" "$path" "$plan_text" "$quar_preview" "" || return $?
    fi
    local entry_id
    entry_id=$(_bl_clean_write_quarantine "$path" "$case_id" "$reason") || return $?
    bl_ledger_append "$case_id" \
        "$(jq -n --arg ts "$(_bl_clean_ts_iso8601)" --arg c "$case_id" --arg p "$path" --arg e "$entry_id" --arg r "$reason" \
            '{ts:$ts, case:$c, kind:"clean_apply", payload:{verb:"clean.file", path:$p, entry_id:$e, reason:$r}}')"
    bl_info "clean.file quarantined; entry_id=$entry_id"
    return "$BL_EX_OK"
}

# ---------------------------------------------------------------------------
# bl_clean_undo <backup-id> [--yes]
# Restore the backup file to its original path; remove the backup + sidecar.
# Validates sidecar meta against schemas/backup-manifest.json (defense-in-depth).
# ---------------------------------------------------------------------------
bl_clean_undo() {
    local backup_id="" yes=""
    while (( $# > 0 )); do
        case "$1" in
            --yes)   yes="yes"; shift ;;
            -*)      bl_error_envelope clean "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)       backup_id="$1"; shift ;;
        esac
    done
    [[ -z "$backup_id" ]] && { bl_error_envelope clean "missing <backup-id>"; return "$BL_EX_USAGE"; }
    local backup_root="$BL_VAR_DIR/backups"
    local backup_path="$backup_root/$backup_id"
    local meta_path="$backup_path.meta.json"
    if [[ ! -r "$backup_path" ]]; then
        bl_error_envelope clean "backup not found: $backup_id"
        return "$BL_EX_NOT_FOUND"
    fi
    if [[ ! -r "$meta_path" ]]; then
        bl_error_envelope clean "backup meta not found: $meta_path"
        return "$BL_EX_NOT_FOUND"
    fi
    # Schema-validate meta (defense-in-depth; tests also validate separately)
    local repo_root schema_path
    repo_root="${BL_REPO_ROOT:-$(dirname "$(readlink -f "$0")" 2>/dev/null || printf '.')}"   # readlink -f absent on BSD / $0 may be 'bash' under curl|bash install — fall back to CWD; schema-check is defense-in-depth and skip-on-missing
    schema_path="$repo_root/schemas/backup-manifest.json"
    [[ -r "$schema_path" ]] || schema_path="schemas/backup-manifest.json"
    if [[ -r "$schema_path" ]]; then
        if ! bl_jq_schema_check "$schema_path" "$meta_path" --strict; then
            bl_error_envelope clean "backup meta failed schema: $meta_path"
            return "$BL_EX_SCHEMA_VALIDATION_FAIL"
        fi
    fi
    local original_path case_id verb sha_pre
    original_path=$(jq -r '.original_path' "$meta_path")
    case_id=$(jq -r '.case_id // empty' "$meta_path")
    verb=$(jq -r '.verb' "$meta_path")
    sha_pre=$(jq -r '.sha256_pre' "$meta_path")
    # Backup integrity: sha256 of backup file on disk must equal sha256_pre
    local sha_on_disk
    sha_on_disk=$(_bl_clean_sha256_content "$backup_path") || return $?
    if [[ "$sha_on_disk" != "$sha_pre" ]]; then
        bl_error_envelope clean "backup integrity fail: on-disk $sha_on_disk != manifest $sha_pre"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    if [[ "$yes" != "yes" ]]; then
        printf 'Restore %s → %s? [y/N] ' "$backup_id" "$original_path" >&2
        local ans
        IFS= read -r ans || ans="N"
        ans=$(printf '%s' "${ans:-N}" | command tr '[:upper:]' '[:lower:]')
        [[ "$ans" != "y" && "$ans" != "yes" ]] && return "$BL_EX_TIER_GATE_DENIED"
    fi
    # For clean.cron: restore means reinstall via crontab -u; for clean.htaccess: cp back
    case "$verb" in
        clean.htaccess)
            command cp -p "$backup_path" "$original_path" || {   # restore failure — backup still intact
                bl_error_envelope clean "restore cp failed: $original_path"
                return "$BL_EX_PREFLIGHT_FAIL"
            }
            ;;
        clean.cron)
            # original_path was the snapshot file; user embedded in filename not reliable,
            # so extract from backup meta's original_path (the snapshot path).
            # Snapshot path format: $BL_VAR_DIR/state/cron-snapshot-<user>.txt
            local user
            user=$(printf '%s' "$original_path" | command sed -nE 's|.*/cron-snapshot-(.+)\.txt$|\1|p')
            if [[ -z "$user" ]]; then
                bl_error_envelope clean "cannot derive user from backup original_path: $original_path"
                return "$BL_EX_PREFLIGHT_FAIL"
            fi
            command crontab -u "$user" "$backup_path" || {   # crontab install failure
                bl_error_envelope clean "crontab install failed during undo"
                return "$BL_EX_PREFLIGHT_FAIL"
            }
            ;;
        *)
            bl_error_envelope clean "unknown verb in backup meta: $verb"
            return "$BL_EX_SCHEMA_VALIDATION_FAIL"
            ;;
    esac
    # Remove backup + meta only after successful restore
    command rm -f "$backup_path" "$meta_path"
    [[ -n "$case_id" ]] && bl_ledger_append "$case_id" \
        "$(jq -n --arg ts "$(_bl_clean_ts_iso8601)" --arg c "$case_id" --arg b "$backup_id" --arg op "$original_path" \
            '{ts:$ts, case:$c, kind:"clean_undo", payload:{backup_id:$b, original_path:$op}}')"
    bl_info "clean.undo restored $backup_id → $original_path"
    return "$BL_EX_OK"
}

# ---------------------------------------------------------------------------
# bl_clean_unquarantine <entry-id> [--yes]
# Move quarantined file back to original_path; restore uid/gid/perms/mtime.
# entry-id format: <sha256>-<basename>; the case is inferred from the sidecar
# since entries are scoped per case.
# ---------------------------------------------------------------------------
bl_clean_unquarantine() {
    local entry_id="" yes=""
    while (( $# > 0 )); do
        case "$1" in
            --yes)   yes="yes"; shift ;;
            -*)      bl_error_envelope clean "unknown flag: $1"; return "$BL_EX_USAGE" ;;
            *)       entry_id="$1"; shift ;;
        esac
    done
    [[ -z "$entry_id" ]] && { bl_error_envelope clean "missing <entry-id>"; return "$BL_EX_USAGE"; }
    # Locate the entry across case directories
    local quar_root="$BL_VAR_DIR/quarantine"
    local found_entry="" found_meta="" found_case=""
    local case_dir
    for case_dir in "$quar_root"/*/; do
        [[ -d "$case_dir" ]] || continue
        if [[ -e "$case_dir$entry_id" && -r "$case_dir$entry_id.meta.json" ]]; then
            found_entry="$case_dir$entry_id"
            found_meta="$case_dir$entry_id.meta.json"
            found_case=$(command basename "$case_dir")
            break
        fi
    done
    if [[ -z "$found_entry" ]]; then
        bl_error_envelope clean "quarantine entry not found: $entry_id"
        return "$BL_EX_NOT_FOUND"
    fi
    # Schema-validate meta
    local repo_root schema_path
    repo_root="${BL_REPO_ROOT:-$(dirname "$(readlink -f "$0")" 2>/dev/null || printf '.')}"   # readlink -f absent on BSD / $0 may be 'bash' under curl|bash install — fall back to CWD; schema-check is defense-in-depth and skip-on-missing
    schema_path="$repo_root/schemas/quarantine-manifest.json"
    [[ -r "$schema_path" ]] || schema_path="schemas/quarantine-manifest.json"
    if [[ -r "$schema_path" ]]; then
        if ! bl_jq_schema_check "$schema_path" "$found_meta" --strict; then
            bl_error_envelope clean "quarantine meta failed schema: $found_meta"
            return "$BL_EX_SCHEMA_VALIDATION_FAIL"
        fi
    fi
    local original_path uid gid perms mtime sha
    original_path=$(jq -r '.original_path' "$found_meta")
    uid=$(jq -r '.uid' "$found_meta")
    gid=$(jq -r '.gid' "$found_meta")
    perms=$(jq -r '.perms_octal' "$found_meta")
    mtime=$(jq -r '.mtime_epoch' "$found_meta")
    sha=$(jq -r '.sha256' "$found_meta")
    # Path-shape guard: schema enforces absolute + non-NUL but path-traversal
    # segments slip through pure-pattern matching. Reject `..` segments at
    # the consumer to prevent restore landing outside the manifest's intent.
    if [[ "$original_path" != /* ]]; then
        bl_error_envelope clean "original_path must be absolute: $original_path"
        return "$BL_EX_SCHEMA_VALIDATION_FAIL"
    fi
    case "$original_path" in
        */../*|*/..|../*|..|*/.|.)
            bl_error_envelope clean "original_path contains traversal segment: $original_path"
            return "$BL_EX_SCHEMA_VALIDATION_FAIL"
            ;;
    esac
    # Content integrity: sha256 of quarantined file must equal meta.sha256
    local sha_on_disk
    sha_on_disk=$(_bl_clean_sha256_content "$found_entry") || return $?
    if [[ "$sha_on_disk" != "$sha" ]]; then
        bl_error_envelope clean "quarantine integrity fail: on-disk $sha_on_disk != manifest $sha"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    # Pre-rename TOCTOU guards: reject if destination is a symlink OR exists
    # as any kind of file. A local attacker with parent-dir write perms could
    # race a symlink between the existence check and rename — same-parent
    # staging below shrinks the window to one rename(2) syscall, and the
    # post-stage re-check catches a symlink raced in DURING the staging mv.
    if [[ -L "$original_path" ]]; then
        bl_error_envelope clean "original_path is a symlink (refusing restore to TOCTOU target): $original_path"
        return "$BL_EX_CONFLICT"
    fi
    if [[ -e "$original_path" ]]; then
        bl_error_envelope clean "original path already exists: $original_path" "(refusing to overwrite)"
        return "$BL_EX_CONFLICT"
    fi
    if [[ "$yes" != "yes" ]]; then
        printf 'Restore %s → %s? [y/N] ' "$entry_id" "$original_path" >&2
        local ans
        IFS= read -r ans || ans="N"
        ans=$(printf '%s' "${ans:-N}" | command tr '[:upper:]' '[:lower:]')
        [[ "$ans" != "y" && "$ans" != "yes" ]] && return "$BL_EX_TIER_GATE_DENIED"
    fi
    # Ensure parent dir exists (may have been removed between quarantine and unquarantine)
    local parent
    parent=$(command dirname "$original_path")
    command mkdir -p "$parent"
    # Stage into the same parent so the final move is rename(2), not cp+unlink.
    # Cross-filesystem failure modes are confined to the staging mv; the final
    # mv is atomic on a single filesystem (parent of original_path).
    local stage_path="$parent/.bl-restore.$entry_id.$$"
    command mv "$found_entry" "$stage_path" || {
        bl_error_envelope clean "unquarantine stage mv failed: $found_entry → $stage_path"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    # Re-check after staging: an attacker may have raced a symlink into place
    # during the staging mv. rename(2) replaces atomically, but if a symlink
    # is at $original_path now the operator's intent is suspect — abort + leave
    # the staged file for forensics rather than commit to a sniped target.
    if [[ -L "$original_path" || -e "$original_path" ]]; then
        bl_error_envelope clean "post-stage TOCTOU detected at $original_path; staged file preserved at $stage_path"
        return "$BL_EX_CONFLICT"
    fi
    command mv -T "$stage_path" "$original_path" || {
        command rm -f "$stage_path"
        bl_error_envelope clean "unquarantine final mv failed: $stage_path → $original_path"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    # Final paranoia: confirm post-rename target is not a symlink.
    if [[ -L "$original_path" ]]; then
        bl_warn "post-rename symlink at $original_path; restored file may be elsewhere — operator should audit"
    fi
    command chown "$uid:$gid" "$original_path" || bl_warn "chown failed (non-root invocation?)"
    command chmod "$perms" "$original_path" || bl_warn "chmod failed on $original_path"
    command touch -d "@$mtime" "$original_path" 2>/dev/null || bl_warn "mtime restore failed on $original_path"   # BSD touch lacks -d; non-fatal
    command rm -f "$found_meta"
    bl_ledger_append "$found_case" \
        "$(jq -n --arg ts "$(_bl_clean_ts_iso8601)" --arg c "$found_case" --arg e "$entry_id" --arg op "$original_path" \
            '{ts:$ts, case:$c, kind:"clean_unquarantine", payload:{entry_id:$e, original_path:$op}}')"
    bl_info "clean.unquarantine restored $entry_id → $original_path"
    return "$BL_EX_OK"
}

# ---------------------------------------------------------------------------
# bl_clean <args> — top-level dispatcher. Replaces the 80-stubs.sh stub.
# Flags --undo / --unquarantine route to restore handlers (operator-only;
# not enumerated in schemas/step.json verbs per schemas/step.md §3).
# Otherwise: first positional = subcommand (htaccess|cron|proc|file).
# ---------------------------------------------------------------------------
bl_clean() {
    if (( $# == 0 )); then
        bl_error_envelope clean "missing subcommand" "(use htaccess|cron|proc|file, or --undo|--unquarantine)"
        return "$BL_EX_USAGE"
    fi
    # Handle operator-only flags first (they consume their arg and return)
    case "$1" in
        --undo)
            shift
            [[ $# -eq 0 ]] && { bl_error_envelope clean "--undo requires <backup-id>"; return "$BL_EX_USAGE"; }
            bl_clean_undo "$@"
            return $?
            ;;
        --unquarantine)
            shift
            [[ $# -eq 0 ]] && { bl_error_envelope clean "--unquarantine requires <entry-id>"; return "$BL_EX_USAGE"; }
            bl_clean_unquarantine "$@"
            return $?
            ;;
        -h|--help|help)
            command cat >&2 <<'CLEAN_USAGE_EOF'
Usage: bl clean <subcommand> [options]

Subcommands:
  htaccess <dir> --patch <file>    Apply htaccess patch (diff-confirmed)
  cron --user <user> --patch <file>  Replace user's crontab (diff-confirmed)
  proc <pid>                       Snapshot /proc + lsof, SIGTERM, SIGKILL
  file <path> [--reason <str>]     Move to quarantine (never unlink)

Operator-only restore:
  --undo <backup-id>               Restore htaccess/cron backup
  --unquarantine <entry-id>        Restore quarantined file

Common options:
  --dry-run                        Show plan + write receipt; no mutations
  --yes                            Skip interactive prompt

Environment:
  BL_CLEAN_DRYRUN_TTL_SECS         Dry-run receipt TTL in seconds (default 300)
  BL_CLEAN_PROC_GRACE_SECS         SIGTERM→SIGKILL grace seconds (default 5)
CLEAN_USAGE_EOF
            return "$BL_EX_OK"
            ;;
    esac
    # Route subcommand
    local sub="$1"
    shift
    case "$sub" in
        htaccess)     bl_clean_htaccess "$@"; return $? ;;
        cron)         bl_clean_cron "$@"; return $? ;;
        proc)         bl_clean_proc "$@"; return $? ;;
        file)         bl_clean_file "$@"; return $? ;;
        *)
            bl_error_envelope clean "unknown subcommand: $sub" "(use htaccess|cron|proc|file)"
            return "$BL_EX_USAGE"
            ;;
    esac
}

# === M7-HANDLERS-END ===
