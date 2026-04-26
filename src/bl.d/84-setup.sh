# shellcheck shell=bash
# ----------------------------------------------------------------------------
# bl_setup — workspace bootstrap (DESIGN.md §8.2-§8.5; spec §4.2, §5.4).
# Replaces old provision/memstore-manifest approach with Skills+Files API
# variant (Path C). Verb dispatcher per spec §5.4:
#   bl setup --sync [--dry-run]   — provision + Skills + Files (idempotent)
#   bl setup --reset [--force]    — delete agent + Skills + workspace Files
#   bl setup --gc                 — delete files_pending_deletion
#   bl setup --eval [--promote]   — live promotion eval (M13 P11: real implementation)
#   bl setup --check              — print state.json snapshot
#   bl setup --help               — usage text
# Bypasses bl_preflight (90-main.sh routes setup pre-preflight). Carries its
# own ANTHROPIC_API_KEY + curl + jq + state-dir checks.
# FD 203 = $BL_STATE_DIR/state.json.lock (concurrent --sync serialization)
# ----------------------------------------------------------------------------

bl_setup() {
    local subcmd="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "$subcmd" in
        --sync)
            local dry_run=0
            [[ "${1:-}" == "--dry-run" ]] && dry_run=1
            bl_setup_local_preflight || return $?
            bl_setup_sync "$dry_run"
            return $?
            ;;
        --reset)
            local force=0
            [[ "${1:-}" == "--force" ]] && force=1
            bl_setup_local_preflight || return $?
            bl_setup_reset "$force"
            return $?
            ;;
        --gc)
            bl_setup_local_preflight || return $?
            bl_setup_gc
            return $?
            ;;
        --eval)
            local promote=0
            [[ "${1:-}" == "--promote" ]] && promote=1
            bl_setup_local_preflight || return $?
            bl_setup_eval "$promote"
            return $?
            ;;
        --check)
            bl_setup_local_preflight || return $?
            bl_setup_check
            return $?
            ;;
        --install-hook)
            local hook_source="${1:-}"
            [[ -z "$hook_source" ]] && { bl_error_envelope setup "missing --install-hook <source>"; return "$BL_EX_USAGE"; }
            case "$hook_source" in
                lmd)
                    bl_setup_local_preflight || return $?
                    bl_setup_install_hook_lmd
                    return $?
                    ;;
                *)
                    bl_error_envelope setup "unknown hook source: $hook_source (only 'lmd' supported)"
                    return "$BL_EX_USAGE"
                    ;;
            esac
            ;;
        --import-from-lmd)
            bl_setup_local_preflight || return $?
            bl_setup_import_from_lmd
            return $?
            ;;
        ""|--help)
            bl_setup_help
            return "$BL_EX_OK"
            ;;
        *)
            bl_error_envelope setup "unknown subcommand: $subcmd; see 'bl setup --help'"
            return "$BL_EX_USAGE"
            ;;
    esac
}

bl_setup_help() {
    command cat <<'HELP'
Usage: bl setup [SUBCOMMAND] [OPTIONS]

Subcommands:
  --sync [--dry-run]      Provision agent + Skills + Files (idempotent default)
                          --dry-run prints diff without API mutation
  --reset [--force]       Delete agent + Skills + workspace Files (destructive)
                          --force skips confirmation prompt
  --gc                    Delete files_pending_deletion when no live sessions reference
  --eval [--promote]      Run 50-case live promotion eval; gated --promote bumps versions
  --check                 Print state.json snapshot + per-resource health
  --install-hook lmd      Install bl-lmd-hook adapter into /etc/blacklight/hooks/
                          and wire LMD conf.maldet post_scan_hook (idempotent)
  --import-from-lmd       Parse /usr/local/maldetect/conf.maldet notify keys and write
                          to /etc/blacklight/notify.d/* with chmod 0600 (idempotent)
  --help                  This message
HELP
}

bl_setup_local_preflight() {
    # Setup bypasses bl_preflight (would 66 on unseeded state). Carry the
    # same ANTHROPIC_API_KEY + curl + jq + state-dir checks here.
    if [[ -z "${ANTHROPIC_API_KEY+set}" || -z "$ANTHROPIC_API_KEY" ]]; then
        bl_error_envelope setup "ANTHROPIC_API_KEY not set"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    command -v curl >/dev/null 2>&1 || {   # curl missing → preflight-fail; absence is the diagnostic
        bl_error_envelope setup "curl not found"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    command -v jq >/dev/null 2>&1 || {   # jq missing → preflight-fail; absence is the diagnostic
        bl_error_envelope setup "jq not found"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    command mkdir -p "$BL_STATE_DIR" 2>/dev/null || {   # RO fs / perms — surface as preflight-fail
        bl_error_envelope setup "$BL_VAR_DIR not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    return "$BL_EX_OK"
}

# bl_setup_load_state — populate BL_STATE_* shell vars from state.json.
# First-run migration: if state.json absent AND any per-key files exist,
# read each, populate state.json, atomically delete old files. One-time per workspace.
# Returns 0 on success, 65 on malformed state.json.
# shellcheck disable=SC2034  # BL_STATE_LAST_SYNC consumed by bl_setup_sync callers
bl_setup_load_state() {
    local state_file="$BL_STATE_DIR/state.json"
    command mkdir -p "$BL_STATE_DIR" 2>/dev/null || {   # RO fs / perms
        bl_error_envelope setup "$BL_VAR_DIR not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    if [[ -f "$state_file" ]]; then
        # Validate JSON shape
        if ! jq -e '.schema_version == 1' "$state_file" >/dev/null 2>&1; then   # 2>/dev/null: jq diagnostic vs schema mismatch — both surface as malformed
            bl_error_envelope setup "state.json malformed or schema_version != 1: $state_file"
            return "$BL_EX_PREFLIGHT_FAIL"
        fi
        BL_STATE_AGENT_ID=$(jq -r '.agent.id // empty' "$state_file")
        BL_STATE_AGENT_VERSION=$(jq -r '.agent.version // 0' "$state_file")
        BL_STATE_ENV_ID=$(jq -r '.env_id // empty' "$state_file")
        BL_STATE_MEMSTORE_CASE_ID=$(jq -r '.case_memstores | to_entries[0].value // empty' "$state_file")
        BL_STATE_LAST_SYNC=$(jq -r '.last_sync // empty' "$state_file")
        return "$BL_EX_OK"
    fi
    # First-run migration path — read old per-key files if present
    local old_agent old_env old_skills old_case old_counter old_current
    old_agent=$(command cat "$BL_STATE_DIR/agent-id" 2>/dev/null || printf '')          # missing → empty (new workspace)
    old_env=$(command cat "$BL_STATE_DIR/env-id" 2>/dev/null || printf '')              # missing → empty (new workspace)
    old_skills=$(command cat "$BL_STATE_DIR/memstore-skills-id" 2>/dev/null || printf '') # missing → empty (new workspace)
    old_case=$(command cat "$BL_STATE_DIR/memstore-case-id" 2>/dev/null || printf '')   # missing → empty (new workspace)
    old_counter=$(command cat "$BL_STATE_DIR/case-id-counter" 2>/dev/null || printf '') # missing → empty (new workspace)
    old_current=$(command cat "$BL_STATE_DIR/case.current" 2>/dev/null || printf '')    # missing → empty (new workspace)
    if [[ -z "$old_agent" && -z "$old_env" && -z "$old_skills" && -z "$old_case" ]]; then
        # Truly fresh workspace — initialize empty state.json
        BL_STATE_AGENT_ID=""
        BL_STATE_AGENT_VERSION=0
        BL_STATE_ENV_ID=""
        BL_STATE_MEMSTORE_CASE_ID=""
        BL_STATE_LAST_SYNC=""
        bl_setup_save_state || return $?
        return "$BL_EX_OK"
    fi
    # Migrate: populate shell vars from old files, write state.json, delete old files atomically
    bl_info "bl setup: migrating per-key state files → state.json"
    BL_STATE_AGENT_ID="$old_agent"
    BL_STATE_AGENT_VERSION=0   # version unknown pre-Path C; first --sync will probe
    BL_STATE_ENV_ID="$old_env"
    BL_STATE_MEMSTORE_CASE_ID="$old_case"
    BL_STATE_LAST_SYNC=""

    # F1 fix — defence in depth: copy legacy files to a timestamped backup
    # BEFORE any destructive cleanup. Recovery anchor if migration fails.
    local backup_dir
    backup_dir="$BL_STATE_DIR/migration-backup-$(command date -u +%s)"
    command mkdir -p "$backup_dir" 2>/dev/null || {   # 2>/dev/null: RO fs / perms — fail-fast surfaces below as malformed-state
        bl_error_envelope setup "$BL_STATE_DIR/migration-backup not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    local legacy
    for legacy in agent-id env-id memstore-skills-id memstore-case-id case-id-counter case.current; do
        [[ -f "$BL_STATE_DIR/$legacy" ]] && command cp "$BL_STATE_DIR/$legacy" "$backup_dir/" 2>/dev/null   # 2>/dev/null: missing → skip; backup is best-effort recovery anchor
    done

    # F1 fix — validate counter content before --argjson; bash brace-default
    # ${var:-{}} alone is fragile because the file's normal payload
    # ({"year":2026,"n":2}) reaches jq through unpredictable bash quoting.
    # Validate explicitly; substitute empty object on any parse failure.
    local counter_validated='{}'
    if [[ -n "$old_counter" ]]; then
        if printf '%s' "$old_counter" | jq -e '.' >/dev/null 2>&1; then   # 2>/dev/null: jq diagnostic redundant; the validator's only signal is exit code
            counter_validated="$old_counter"
        else
            bl_warn "bl setup: case-id-counter content rejected by jq; substituting {} (counter resets to 0 on next case open)"
        fi
    fi

    # Build state.json with both old fields preserved
    local tmp_state="$state_file.tmp.$$"
    if ! jq -n \
        --arg aid "$old_agent" \
        --arg env "$old_env" \
        --arg cmid "$old_case" \
        --arg cur "$old_current" \
        --argjson counter "$counter_validated" \
        '{
            schema_version: 1,
            agent: {id: $aid, version: 0, skill_versions: {}},
            env_id: $env,
            skills: {},
            files: {},
            files_pending_deletion: [],
            case_memstores: (if $cmid != "" then {"_legacy": $cmid} else {} end),
            case_files: {},
            case_id_counter: $counter,
            case_current: $cur,
            session_ids: {},
            last_sync: ""
        }' > "$tmp_state"; then
        # F1 fix — abort migration cleanly: do NOT mv tmp into place, do NOT delete legacy files
        command rm -f "$tmp_state" 2>/dev/null   # 2>/dev/null: tmp may not exist if jq failed before creating it
        bl_error_envelope setup "state.json compose failed during migration; legacy files preserved at $BL_STATE_DIR (backup at $backup_dir)"
        return "$BL_EX_UPSTREAM_ERROR"
    fi
    # F1 fix — verify the composed state.json is parseable before committing it
    if ! jq -e '.schema_version == 1' "$tmp_state" >/dev/null 2>&1; then   # 2>/dev/null: jq diagnostic redundant in pass/fail check
        command rm -f "$tmp_state" 2>/dev/null   # 2>/dev/null: best-effort; tmp existence already proven by jq -n above
        bl_error_envelope setup "composed state.json failed schema_version check; legacy files preserved (backup at $backup_dir)"
        return "$BL_EX_UPSTREAM_ERROR"
    fi
    command mv "$tmp_state" "$state_file"

    # Delete old per-key files only AFTER state.json is committed and validated
    # (skills-id is intentionally orphaned — bl-skills memstore retired)
    command rm -f "$BL_STATE_DIR/agent-id" "$BL_STATE_DIR/env-id" \
                  "$BL_STATE_DIR/memstore-skills-id" "$BL_STATE_DIR/memstore-case-id" \
                  "$BL_STATE_DIR/case-id-counter" "$BL_STATE_DIR/case.current"
    bl_info "bl setup: state migrated; legacy files removed (backup at $backup_dir)"
    return "$BL_EX_OK"
}

# bl_setup_save_state — atomically write current BL_STATE_* shell vars to state.json.
# Caller must have populated BL_STATE_* (load_state initializes empty if first-run).
bl_setup_save_state() {
    local state_file="$BL_STATE_DIR/state.json"
    local tmp_state="$state_file.tmp.$$"
    local now
    now=$(command date -u +%Y-%m-%dT%H:%M:%SZ)
    # Preserve existing skills/files/files_pending_deletion/case_files/session_ids/case_id_counter/case_current
    # if state.json already exists; only overwrite top-level identity fields here.
    local existing="{}"
    [[ -f "$state_file" ]] && existing=$(command cat "$state_file")
    jq -n \
        --arg aid "${BL_STATE_AGENT_ID:-}" \
        --argjson av "${BL_STATE_AGENT_VERSION:-0}" \
        --arg env "${BL_STATE_ENV_ID:-}" \
        --arg cmid "${BL_STATE_MEMSTORE_CASE_ID:-}" \
        --arg ts "$now" \
        --argjson existing "$existing" \
        '{
            schema_version: 1,
            agent: {
                id: $aid,
                version: $av,
                skill_versions: ($existing.agent.skill_versions // {})
            },
            env_id: $env,
            skills: ($existing.skills // {}),
            files: ($existing.files // {}),
            files_pending_deletion: ($existing.files_pending_deletion // []),
            case_memstores: (
                if $cmid != "" then
                    ($existing.case_memstores // {}) + {"_legacy": $cmid}
                else
                    ($existing.case_memstores // {})
                end
            ),
            case_files: ($existing.case_files // {}),
            case_id_counter: ($existing.case_id_counter // {}),
            case_current: ($existing.case_current // ""),
            session_ids: ($existing.session_ids // {}),
            last_sync: $ts
        }' > "$tmp_state"
    command mv "$tmp_state" "$state_file"
    return "$BL_EX_OK"
}

# bl_setup_seed_corpus <mode> — mode: dry-run | apply
# Hashes each skills-corpus/*.md, diffs vs state.json `.files`, uploads changed via bl_files_create.
# Marks superseded file_ids into files_pending_deletion[]. Returns 0 on success.
bl_setup_seed_corpus() {
    local mode="${1:-apply}"
    local repo_root
    repo_root=$(bl_setup_resolve_source) || return $?
    local corpus_dir="$repo_root/skills-corpus"
    [[ -d "$corpus_dir" ]] || {
        bl_error_envelope setup "skills-corpus/ not found at $corpus_dir; run 'make skills-corpus' first"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    local state_file="$BL_STATE_DIR/state.json"
    local existing_state="{}"
    [[ -f "$state_file" ]] && existing_state=$(command cat "$state_file")
    local upload_count=0 skip_count=0 supersede_count=0
    local f mount_path content_sha existing_fid existing_sha new_fid
    for f in "$corpus_dir"/*.md; do
        [[ -r "$f" ]] || continue
        mount_path="/skills/$(basename "$f")"
        content_sha=$(command sha256sum "$f" | command awk '{print $1}')
        existing_fid=$(printf '%s' "$existing_state" | jq -r --arg p "$mount_path" '.files[$p].file_id // empty')
        existing_sha=$(printf '%s' "$existing_state" | jq -r --arg p "$mount_path" '.files[$p].content_sha256 // empty')
        if [[ "$content_sha" == "$existing_sha" && -n "$existing_fid" ]]; then
            skip_count=$((skip_count + 1))
            bl_debug "bl_setup_seed_corpus: skip $mount_path (sha matches $existing_fid)"
            continue
        fi
        if [[ "$mode" == "dry-run" ]]; then
            printf 'would upload %s (sha %s)\n' "$mount_path" "${content_sha:0:8}"
            upload_count=$((upload_count + 1))
            continue
        fi
        new_fid=$(bl_files_create "text/markdown" "$f") || return $?
        bl_info "bl setup: uploaded $mount_path → $new_fid"
        # Update state.json in-memory representation
        existing_state=$(printf '%s' "$existing_state" | jq \
            --arg p "$mount_path" \
            --arg fid "$new_fid" \
            --arg sha "$content_sha" \
            --arg ts "$(command date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '.files[$p] = {file_id: $fid, content_sha256: $sha, uploaded_at: $ts}')
        # Mark old file_id for GC if present
        if [[ -n "$existing_fid" ]]; then
            existing_state=$(printf '%s' "$existing_state" | jq \
                --arg fid "$existing_fid" \
                --arg p "$mount_path" \
                --arg ts "$(command date -u +%Y-%m-%dT%H:%M:%SZ)" \
                --arg new "$new_fid" \
                '.files_pending_deletion += [{file_id: $fid, marked_at: $ts, reason: ("superseded by " + $new), previous_mount_path: $p}]')
            supersede_count=$((supersede_count + 1))
        fi
        upload_count=$((upload_count + 1))
    done
    # Persist updated state.json (preserves agent/skills/case_files via existing keys)
    if [[ "$mode" != "dry-run" ]]; then
        local tmp_state="$state_file.tmp.$$"
        printf '%s' "$existing_state" > "$tmp_state"
        command mv "$tmp_state" "$state_file"
    fi
    if [[ "$mode" == "dry-run" ]]; then
        bl_info "bl setup: corpus seed — would upload $upload_count, would skip $skip_count, would supersede $supersede_count"
    else
        bl_info "bl setup: corpus seed — $upload_count uploaded, $skip_count skipped, $supersede_count superseded"
    fi
    return "$BL_EX_OK"
}

# bl_setup_seed_skills <mode> — mode: dry-run | apply
# For each routing-skills/<name>/, hash description+body, diff vs state.json `.skills`.
# If skill_id absent: bl_skills_create. If sha changed: bl_skills_versions_create.
bl_setup_seed_skills() {
    local mode="${1:-apply}"
    local repo_root
    repo_root=$(bl_setup_resolve_source) || return $?
    local rs_dir="$repo_root/routing-skills"
    [[ -d "$rs_dir" ]] || {
        bl_error_envelope setup "routing-skills/ not found at $rs_dir"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    local count
    count=$(find "$rs_dir" -mindepth 1 -maxdepth 1 -type d | wc -l)
    if (( count == 0 )); then
        bl_error_envelope setup "no routing Skills found at $rs_dir; expected 6"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    local state_file="$BL_STATE_DIR/state.json"
    local existing_state="{}"
    [[ -f "$state_file" ]] && existing_state=$(command cat "$state_file")
    local d name desc_file body_file desc_sha body_sha existing_id existing_desc_sha existing_body_sha new_id new_version
    for d in "$rs_dir"/*/; do
        name=$(basename "$d")
        desc_file="$d/description.txt"
        body_file="$d/SKILL.md"
        [[ -r "$desc_file" && -r "$body_file" ]] || {
            bl_warn "bl setup: skipping $name — missing description.txt or SKILL.md"
            continue
        }
        desc_sha=$(command sha256sum "$desc_file" | command awk '{print $1}')
        body_sha=$(command sha256sum "$body_file" | command awk '{print $1}')
        existing_id=$(printf '%s' "$existing_state" | jq -r --arg n "$name" '.skills[$n].id // empty')
        existing_desc_sha=$(printf '%s' "$existing_state" | jq -r --arg n "$name" '.skills[$n].description_sha256 // empty')
        existing_body_sha=$(printf '%s' "$existing_state" | jq -r --arg n "$name" '.skills[$n].body_sha256 // empty')
        if [[ "$desc_sha" == "$existing_desc_sha" && "$body_sha" == "$existing_body_sha" && -n "$existing_id" ]]; then
            bl_debug "bl_setup_seed_skills: skip $name (no change)"
            continue
        fi
        if [[ "$mode" == "dry-run" ]]; then
            if [[ -z "$existing_id" ]]; then
                printf 'would skills.create %s\n' "$name"
            else
                printf 'would skills.versions.create %s (desc/body sha changed)\n' "$name"
            fi
            continue
        fi
        if [[ -z "$existing_id" ]]; then
            new_id=$(bl_skills_create "$name" "$desc_file" "$body_file") || return $?
            new_version=$(bl_skills_get "$new_id" | jq -r '.version // empty')
            bl_info "bl setup: created Skill $name → $new_id (version $new_version)"
            existing_state=$(printf '%s' "$existing_state" | jq \
                --arg n "$name" --arg id "$new_id" --arg v "$new_version" \
                --arg ds "$desc_sha" --arg bs "$body_sha" \
                '.skills[$n] = {id: $id, version: $v, description_sha256: $ds, body_sha256: $bs} | .agent.skill_versions[$n] = $v')
        else
            new_version=$(bl_skills_versions_create "$existing_id" "$desc_file" "$body_file") || return $?
            bl_info "bl setup: bumped Skill $name → version $new_version"
            existing_state=$(printf '%s' "$existing_state" | jq \
                --arg n "$name" --arg v "$new_version" \
                --arg ds "$desc_sha" --arg bs "$body_sha" \
                '.skills[$n].version = $v | .skills[$n].description_sha256 = $ds | .skills[$n].body_sha256 = $bs | .agent.skill_versions[$n] = $v')
        fi
    done
    if [[ "$mode" != "dry-run" ]]; then
        local tmp_state="$state_file.tmp.$$"
        printf '%s' "$existing_state" > "$tmp_state"
        command mv "$tmp_state" "$state_file"
    fi
    return "$BL_EX_OK"
}

# bl_setup_attach_session_resources <case-id> <session-id>
# Attach 8 workspace corpora (foundations + 6 routing-skill corpora + substrate-context)
# + per-case raw + summary Files to a fresh session via /v1/sessions/<id>/resources POST.
bl_setup_attach_session_resources() {
    local case_id="$1" session_id="$2"
    [[ -z "$case_id" || -z "$session_id" ]] && {
        bl_error_envelope setup "bl_setup_attach_session_resources: case-id + session-id required"
        return "$BL_EX_USAGE"
    }
    local state_file="$BL_STATE_DIR/state.json"
    [[ -f "$state_file" ]] || { bl_error_envelope setup "state.json missing; run 'bl setup --sync' first"; return "$BL_EX_PREFLIGHT_FAIL"; }
    # Workspace Files (8 entries from .files{})
    local mount_path file_id rc
    rc=0
    while IFS=$'\t' read -r mount_path file_id; do
        [[ -z "$mount_path" || -z "$file_id" ]] && continue
        bl_files_attach_to_session "$session_id" "$file_id" "$mount_path" >/dev/null || {
            rc=$?
            bl_warn "bl setup: failed to attach $mount_path → $session_id ($rc)"
            continue
        }
        bl_debug "bl setup: attached $mount_path"
    done < <(jq -r '.files | to_entries[] | "\(.key)\t\(.value.file_id)"' "$state_file")
    # Per-case Files (case_files[case_id])
    while IFS=$'\t' read -r mount_path file_id; do
        [[ -z "$mount_path" || -z "$file_id" ]] && continue
        bl_files_attach_to_session "$session_id" "$file_id" "$mount_path" >/dev/null || {
            rc=$?
            bl_warn "bl setup: failed to attach $mount_path → $session_id ($rc)"
            continue
        }
    done < <(jq -r --arg c "$case_id" '.case_files[$c] // {} | to_entries[] | "\(.key)\t\(.value.workspace_file_id)"' "$state_file")
    return "$BL_EX_OK"
}

bl_setup_dry_run() {
    bl_setup_load_state || return $?
    printf 'bl setup --dry-run: loaded state from %s\n' "$BL_STATE_DIR/state.json"
    bl_setup_seed_corpus dry-run
    bl_setup_seed_skills dry-run
    bl_setup_ensure_agent dry-run
    printf 'bl setup --dry-run: 0 mutations would be applied (preview mode)\n'
    return "$BL_EX_OK"
}

bl_setup_reset() {
    local force="${1:-0}"
    bl_setup_load_state || return $?
    local agent_id env_id
    agent_id="${BL_STATE_AGENT_ID:-}"
    env_id="${BL_STATE_ENV_ID:-}"
    local skills_count files_count case_memstores_count case_files_count
    skills_count=$(jq -r '.skills | length' "$BL_STATE_DIR/state.json")
    files_count=$(jq -r '.files | length' "$BL_STATE_DIR/state.json")
    case_memstores_count=$(jq -r '.case_memstores | length' "$BL_STATE_DIR/state.json")
    case_files_count=$(jq -r '[.case_files[] | length] | add // 0' "$BL_STATE_DIR/state.json")
    if [[ "$force" != "1" ]]; then
        printf 'bl setup --reset: this will DELETE %s + %d Skills + %d workspace Files.\n' \
            "${agent_id:-(none)}" "$skills_count" "$files_count"
        printf 'bl setup --reset: per-case Files (%d) and case memstores (%d) are PRESERVED.\n' "$case_files_count" "$case_memstores_count"
        printf 'bl setup --reset: continue? [y/N]: '
        read -r response
        [[ "$response" != "y" && "$response" != "Y" ]] && { printf 'bl setup --reset: aborted\n'; return "$BL_EX_OK"; }
    fi
    # F5 + F6 — archive (not delete) the agent; abort the reset if archive
    # fails so we never wipe state.json while the platform still has a live
    # agent. Empty `{}` body matches the documented archive verb shape.
    if [[ -n "$agent_id" ]]; then
        local empty_body
        empty_body=$(command mktemp)
        printf '{}' > "$empty_body"
        if bl_api_call POST "/v1/agents/$agent_id/archive" "$empty_body" >/dev/null; then
            bl_info "archived agent $agent_id"
            command rm -f "$empty_body"
        else
            command rm -f "$empty_body"
            bl_warn "agent archive failed; aborting reset to preserve state.json"
            return "$BL_EX_UPSTREAM_ERROR"
        fi
    fi
    local skill_id
    while IFS= read -r skill_id; do
        [[ -z "$skill_id" ]] && continue
        if bl_skills_delete "$skill_id" >/dev/null; then
            bl_debug "deleted skill $skill_id"
        else
            bl_warn "skill delete failed: $skill_id; aborting reset"
            return "$BL_EX_UPSTREAM_ERROR"
        fi
    done < <(jq -r '.skills[].id // empty' "$BL_STATE_DIR/state.json")
    local file_id
    while IFS= read -r file_id; do
        [[ -z "$file_id" ]] && continue
        if bl_files_delete "$file_id" >/dev/null; then
            bl_debug "deleted file $file_id"
        else
            bl_warn "file delete failed: $file_id; aborting reset"
            return "$BL_EX_UPSTREAM_ERROR"
        fi
    done < <(jq -r '.files[].file_id // empty' "$BL_STATE_DIR/state.json")
    # Wipe state.json: preserve case_memstores + case_files only
    local tmp_state="$BL_STATE_DIR/state.json.tmp.$$"
    jq '{
        schema_version: 1,
        agent: {id: "", version: 0, skill_versions: {}},
        env_id: .env_id,
        skills: {},
        files: {},
        files_pending_deletion: [],
        case_memstores: .case_memstores,
        case_files: .case_files,
        case_id_counter: .case_id_counter,
        case_current: .case_current,
        session_ids: {},
        last_sync: ""
    }' "$BL_STATE_DIR/state.json" > "$tmp_state"
    command mv "$tmp_state" "$BL_STATE_DIR/state.json"
    bl_info "bl setup --reset: state.json reset (preserved case_memstores + case_files)"
    return "$BL_EX_OK"
}

bl_setup_gc() {
    bl_setup_load_state || return $?
    local pending_count
    pending_count=$(jq -r '.files_pending_deletion | length' "$BL_STATE_DIR/state.json")
    (( pending_count == 0 )) && { printf 'bl setup --gc: no files pending deletion\n'; return "$BL_EX_OK"; }
    printf 'bl setup --gc: %d file(s) pending deletion\n' "$pending_count"
    local file_id
    local deleted=0 skipped=0
    while IFS= read -r file_id; do
        [[ -z "$file_id" ]] && continue
        # NOTE: Anthropic does not currently expose sessions.resources.list per-session enumeration
        # of file_id usage. Conservative posture: delete only if state.json shows no live session
        # holds the file. Future: when API exposes per-file usage, query it here.
        local in_use
        in_use=$(jq -r --arg f "$file_id" '[.session_ids | to_entries[] | .value] | map(select(. != "")) | length' "$BL_STATE_DIR/state.json")
        if (( in_use > 0 )); then
            bl_info "bl setup --gc: skip $file_id (live sessions present — conservative)"
            skipped=$((skipped + 1))
            continue
        fi
        bl_files_delete "$file_id" || { bl_warn "delete failed: $file_id"; continue; }
        deleted=$((deleted + 1))
        # Remove from files_pending_deletion[]
        local tmp_state="$BL_STATE_DIR/state.json.tmp.$$"
        jq --arg f "$file_id" '.files_pending_deletion |= map(select(.file_id != $f))' "$BL_STATE_DIR/state.json" > "$tmp_state"
        command mv "$tmp_state" "$BL_STATE_DIR/state.json"
    done < <(jq -r '.files_pending_deletion[].file_id // empty' "$BL_STATE_DIR/state.json")
    printf 'bl setup --gc: deleted %d, skipped %d\n' "$deleted" "$skipped"
    return "$BL_EX_OK"
}

bl_setup_eval() {
    local promote="${1:-0}"
    local fixtures_dir="${BL_REPO_ROOT:-$(pwd)}/tests/skill-routing/eval-cases"
    [[ -d "$fixtures_dir" ]] || {
        bl_error_envelope setup "eval fixtures missing: $fixtures_dir"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    local mainline_count distractor_count ambiguous_count
    mainline_count=$(find "$fixtures_dir/mainline" -name '*.json' 2>/dev/null | wc -l)   # 2>/dev/null: missing subdir → 0 (handled by sum below)
    distractor_count=$(find "$fixtures_dir/distractor" -name '*.json' 2>/dev/null | wc -l)   # 2>/dev/null: missing subdir → 0
    ambiguous_count=$(find "$fixtures_dir/ambiguous" -name '*.json' 2>/dev/null | wc -l)   # 2>/dev/null: missing subdir → 0
    bl_info "bl setup --eval: loading $((mainline_count + distractor_count + ambiguous_count)) case fixtures ($mainline_count mainline / $distractor_count distractor / $ambiguous_count ambiguous)"
    # Communicate metrics out of bats via a tmp file. bats 1.13.0 formatters are
    # pretty/tap/tap13/junit only — structured JSON output cannot ride bats stdout.
    # eval-runner.bats's final test writes the metrics blob to $BL_EVAL_REPORT_FILE which we set here.
    local report_file
    report_file="$BL_STATE_DIR/eval-$(command date -u +%Y-%m-%dT%H:%MZ).json"
    export BL_EVAL_REPORT_FILE="$report_file"
    local runner_log
    runner_log=$(command mktemp)
    if ! BL_EVAL_LIVE=1 bats tests/skill-routing/eval-runner.bats --formatter tap > "$runner_log" 2>&1; then
        bl_error_envelope setup "eval-runner failed; see $runner_log"
        command tail -50 "$runner_log" >&2
        return "$BL_EX_UPSTREAM_ERROR"
    fi
    command rm -f "$runner_log"
    # Read the metrics report eval-runner.bats wrote to $BL_EVAL_REPORT_FILE
    [[ -s "$report_file" ]] || {
        bl_error_envelope setup "eval-runner did not write metrics to $report_file"
        return "$BL_EX_UPSTREAM_ERROR"
    }
    command cat "$report_file" | jq '.'
    printf 'bl setup --eval: report saved → %s\n' "$report_file"
    local promotion_pass below_bar
    promotion_pass=$(jq -r '.promotion_pass // false' "$report_file")
    below_bar=$(jq -r '.below_bar // [] | join(", ")' "$report_file")
    if (( promote == 1 )); then
        if [[ "$promotion_pass" != "true" ]]; then
            bl_error_envelope setup "promotion bar not met: $below_bar"
            return "$BL_EX_PREFLIGHT_FAIL"
        fi
        # Promote: bump agent.skill_versions to current state-tracked versions
        bl_setup_ensure_agent apply || return $?
        bl_info "bl setup --eval --promote: agent updated to current Skill versions"
    fi
    return "$BL_EX_OK"
}

# bl_setup_ensure_agent <mode> — mode: apply | dry-run
# Creates or updates the bl-curator Managed Agent. On first-run: POST /v1/agents.
# On subsequent: POST /v1/agents/<id> with {version, ...} CAS body (F9 fix).
bl_setup_ensure_agent() {
    local mode="${1:-apply}"
    local state_file="$BL_STATE_DIR/state.json"
    local cached_id
    cached_id=$(jq -r '.agent.id // empty' "$state_file" 2>/dev/null || printf '')   # missing state → empty → first-run path
    if [[ -n "$cached_id" ]] && [[ "$mode" == "apply" ]]; then
        # F9 fix — agents are versioned; the API uses POST, not PATCH.
        # Update via POST /v1/agents/<id> with optimistic-CAS body
        # {version: <current>, ...}.
        # On 409 ("Concurrent modification detected"), refetch GET, update
        # cached version in state.json, retry once.
        bl_setup_update_agent_cas "$cached_id"
        return $?
    fi
    if [[ "$mode" == "dry-run" ]]; then
        if [[ -z "$cached_id" ]]; then
            printf 'would agents.create bl-curator\n'
        else
            printf 'would agents.update %s (skill_versions diff)\n' "$cached_id"
        fi
        return "$BL_EX_OK"
    fi
    # First-run agent creation — attempt POST directly; on 409 re-probe via GET.
    # Avoids a GET+POST TOCTOU race while keeping 409 recovery deterministic.
    # Pattern: capture rc separately to survive set -e (command-substitution exit aborts on non-zero).
    local body_file create_resp created_id created_version rc
    body_file=$(command mktemp)
    bl_setup_compose_agent_body > "$body_file" || { command rm -f "$body_file"; return "$BL_EX_PREFLIGHT_FAIL"; }
    rc=0
    create_resp=$(bl_api_call POST "/v1/agents" "$body_file") || rc=$?
    command rm -f "$body_file"
    if (( rc == 71 )); then
        # 409: agent already exists (race or untracked prior run) — probe and cache
        bl_info "bl setup: agent already exists (409) — re-probing"
        local list_resp probed_id
        list_resp=$(bl_api_call GET "/v1/agents") || return $?   # API rejects ?name= filter — list all, filter client-side
        probed_id=$(printf '%s' "$list_resp" | jq -r '.data[] | select(.name == "bl-curator") | .id' | head -1)
        [[ -z "$probed_id" ]] && { bl_error_envelope setup "agent created elsewhere but probe still empty"; return "$BL_EX_NOT_FOUND"; }
        BL_STATE_AGENT_ID="$probed_id"
        BL_STATE_AGENT_VERSION=$(printf '%s' "$list_resp" | jq -r --arg id "$probed_id" '.data[] | select(.id == $id) | .version // 1')
        bl_setup_save_state || return $?
        return "$BL_EX_OK"
    fi
    (( rc != 0 )) && return $rc
    created_id=$(printf '%s' "$create_resp" | jq -r '.id // empty')
    created_version=$(printf '%s' "$create_resp" | jq -r '.version // 1')
    [[ -z "$created_id" ]] && { bl_error_envelope setup "agent create returned no id"; return "$BL_EX_UPSTREAM_ERROR"; }
    bl_info "bl setup: agent created ($created_id, version $created_version)"
    BL_STATE_AGENT_ID="$created_id"
    BL_STATE_AGENT_VERSION="$created_version"
    bl_setup_save_state || return $?
    return "$BL_EX_OK"
}

# bl_setup_update_agent_cas <agent-id> — POST /v1/agents/<id> with {version, ...}.
# On 409 (conflict), GET to refresh version, retry once. Persists new version
# to state.json on success.
bl_setup_update_agent_cas() {
    local cached_id="$1"
    local state_file="$BL_STATE_DIR/state.json"
    local current_version
    current_version=$(jq -r '.agent.version // 0' "$state_file")

    local attempt
    for attempt in 1 2; do
        local body_file
        body_file=$(command mktemp)
        if ! bl_setup_compose_agent_update_body "$current_version" > "$body_file"; then
            command rm -f "$body_file"
            return "$BL_EX_PREFLIGHT_FAIL"
        fi
        local resp rc
        rc=0
        resp=$(bl_api_call POST "/v1/agents/$cached_id" "$body_file") || rc=$?
        command rm -f "$body_file"
        if (( rc == 0 )); then
            local new_version
            new_version=$(printf '%s' "$resp" | jq -r '.version // 0')
            local tmp_state="$state_file.tmp.$$"
            jq --argjson v "$new_version" '.agent.version = $v' "$state_file" > "$tmp_state"
            command mv "$tmp_state" "$state_file"
            BL_STATE_AGENT_ID="$cached_id"
            BL_STATE_AGENT_VERSION="$new_version"
            bl_info "bl setup: agent updated ($cached_id, version $current_version → $new_version)"
            return "$BL_EX_OK"
        fi
        # 71 = BL_EX_CONFLICT (HTTP 409). bl_api_call (20-api.sh:55-57) returns
        # rc=71 without printing the body to stdout — so $resp is empty here.
        # rc is the only reliable signal of "Concurrent modification detected".
        # Do NOT pattern-match on $resp content; the upstream spec sketch's
        # `if [[ "$resp" == *"Concurrent modification"* ]]` would silently
        # never match.
        if (( rc == 71 )) && (( attempt == 1 )); then
            # 409 on first try — refetch and retry once
            bl_warn "bl setup: agent update conflicted (concurrent modification); refetching version"
            local fresh_resp fresh_version
            fresh_resp=$(bl_api_call GET "/v1/agents/$cached_id") || return $?
            fresh_version=$(printf '%s' "$fresh_resp" | jq -r '.version // 0')
            if [[ "$fresh_version" == "$current_version" ]]; then
                bl_error_envelope setup "agent CAS conflict but server version matches local; cannot reconcile"
                return "$BL_EX_UPSTREAM_ERROR"
            fi
            current_version="$fresh_version"
            continue
        fi
        # Non-409 error or 409 on retry — surface
        return $rc
    done
    bl_error_envelope setup "agent update failed after CAS retry; manual intervention required"
    return "$BL_EX_UPSTREAM_ERROR"
}

# bl_setup_compose_agent_update_body <current-version> — emits POST /v1/agents/<id> body.
# Same shape as bl_setup_compose_agent_body but adds {version: <current-version>}
# for optimistic-CAS gating. Replacement semantics: the server fully overwrites
# the agent body with these fields on success.
bl_setup_compose_agent_update_body() {
    local current_version="$1"
    [[ -z "$current_version" ]] && { bl_error_envelope setup "compose_agent_update_body: current-version required"; return "$BL_EX_USAGE"; }
    # Emit the same body shape as bl_setup_compose_agent_body, then merge in
    # {version: <current>} via a second jq pass.
    local base_body
    base_body=$(bl_setup_compose_agent_body) || return $?
    printf '%s' "$base_body" | jq --argjson ver "$current_version" '. + {version: $ver}'
}

# bl_setup_ensure_env <out-var> — same shape as old ensure_env; targets /v1/environments.
# Reads env_id from state.json if present; otherwise creates it.
bl_setup_ensure_env() {
    local _out="$1"
    # Check state.json first; fall back to legacy env-id file during migration window
    local state_file="$BL_STATE_DIR/state.json"
    local cached_env=""
    [[ -f "$state_file" ]] && cached_env=$(jq -r '.env_id // empty' "$state_file")
    if [[ -z "$cached_env" ]]; then
        local id_file="$BL_STATE_DIR/env-id"
        [[ -r "$id_file" ]] && cached_env=$(command cat "$id_file")
    fi
    if [[ -n "$cached_env" ]]; then
        BL_STATE_ENV_ID="$cached_env"
        [[ -n "$_out" ]] && printf -v "$_out" '%s' "$cached_env"
        return "$BL_EX_OK"
    fi
    local body_file create_resp created_id rc
    body_file=$(command mktemp)
    bl_setup_compose_env_body > "$body_file" || { command rm -f "$body_file"; return "$BL_EX_PREFLIGHT_FAIL"; }
    rc=0
    create_resp=$(bl_api_call POST "/v1/environments" "$body_file") || rc=$?
    command rm -f "$body_file"
    (( rc != 0 )) && return $rc
    created_id=$(printf '%s' "$create_resp" | jq -r '.id // empty')
    [[ -z "$created_id" ]] && { bl_error_envelope setup "env create returned no id"; return "$BL_EX_UPSTREAM_ERROR"; }
    bl_info "bl setup: env created ($created_id)"
    BL_STATE_ENV_ID="$created_id"
    [[ -n "$_out" ]] && printf -v "$_out" '%s' "$created_id"
    return "$BL_EX_OK"
}

# bl_setup_ensure_memstore <out-var> <name> <create-fixture-shape> — list-then-create.
bl_setup_ensure_memstore() {
    local _out="$1"
    local name="$2"
    # third arg unused at runtime — fixture filename is for test docs only
    local id_file_basename
    case "$name" in
        bl-case)   id_file_basename="memstore-case-id"   ;;
        *)         bl_error_envelope setup "unknown memstore name: $name"; return "$BL_EX_USAGE" ;;
    esac
    # Check state.json first
    local state_file="$BL_STATE_DIR/state.json"
    local cached_id=""
    if [[ -f "$state_file" ]]; then
        cached_id=$(jq -r '.case_memstores["_default"] // empty' "$state_file")
    fi
    if [[ -z "$cached_id" ]]; then
        local id_file="$BL_STATE_DIR/$id_file_basename"
        if [[ -r "$id_file" ]]; then
            local from_file
            from_file=$(command cat "$id_file")
            [[ -n "$from_file" ]] && cached_id="$from_file"
        fi
    fi
    if [[ -n "$cached_id" ]]; then
        [[ -n "$_out" ]] && printf -v "$_out" '%s' "$cached_id"
        return "$BL_EX_OK"
    fi
    local list_resp probed_id
    list_resp=$(bl_api_call GET "/v1/memory_stores?name=$name") || return $?
    # Filter client-side by exact name — API ?name= may do prefix match or return all
    probed_id=$(printf '%s' "$list_resp" | jq -r --arg n "$name" '.data[] | select(.name == $n) | .id' | head -1)
    if [[ -n "$probed_id" ]]; then
        bl_info "bl setup: memstore $name already exists ($probed_id) — caching"
        [[ -n "$_out" ]] && printf -v "$_out" '%s' "$probed_id"
        return "$BL_EX_OK"
    fi
    local body_file create_resp created_id rc
    body_file=$(command mktemp)
    jq -n --arg n "$name" '{name:$n}' > "$body_file"
    rc=0
    create_resp=$(bl_api_call POST "/v1/memory_stores" "$body_file") || rc=$?
    command rm -f "$body_file"
    (( rc != 0 )) && return $rc
    created_id=$(printf '%s' "$create_resp" | jq -r '.id // empty')
    [[ -z "$created_id" ]] && { bl_error_envelope setup "memstore $name create returned no id"; return "$BL_EX_UPSTREAM_ERROR"; }
    bl_info "bl setup: memstore $name created ($created_id)"
    [[ -n "$_out" ]] && printf -v "$_out" '%s' "$created_id"
    return "$BL_EX_OK"
}

# bl_setup_compose_agent_body — emits agent-create JSON to stdout per setup-flow.md §4.2.
# Includes skill_versions field populated from state.json (Path C addition).
bl_setup_compose_agent_body() {
    local repo_root resolved
    resolved=$(readlink -f "$0" 2>/dev/null || printf '.')   # readlink -f may fail when $0 is relative / sourced — fallback to cwd
    repo_root="${BL_REPO_ROOT:-$(dirname "$resolved")}"
    local prompt_file="$repo_root/prompts/curator-agent.md"
    local step_schema="$repo_root/schemas/step.json"
    local def_schema="$repo_root/schemas/defense.json"
    local int_schema="$repo_root/schemas/intent.json"
    for f in "$prompt_file" "$step_schema" "$def_schema" "$int_schema"; do
        [[ -r "$f" ]] || { bl_error_envelope setup "input file missing: $f"; return "$BL_EX_PREFLIGHT_FAIL"; }
    done
    local sv_json='{}'
    local state_file="$BL_STATE_DIR/state.json"
    [[ -f "$state_file" ]] && sv_json=$(jq -c '.agent.skill_versions // {}' "$state_file" 2>/dev/null || printf '{}')
    jq -n \
        --rawfile prompt "$prompt_file" \
        --slurpfile stepRaw "$step_schema" \
        --slurpfile defRaw  "$def_schema" \
        --slurpfile intRaw  "$int_schema" \
        --argjson sv "$sv_json" \
        '{
            name: "bl-curator",
            model: "claude-opus-4-7",
            system: $prompt,
            skill_versions: $sv,
            tools: [
                {type: "agent_toolset_20260401"},
                {
                    type: "custom",
                    name: "report_step",
                    description: "Emit a proposed blacklight wrapper action. One call per step.",
                    input_schema: ($stepRaw[0] | del(.["$schema"], .["$id"], .title))
                },
                {
                    type: "custom",
                    name: "synthesize_defense",
                    description: "Propose a defensive payload for this case.",
                    input_schema: ($defRaw[0] | del(.["$schema"], .["$id"], .title))
                },
                {
                    type: "custom",
                    name: "reconstruct_intent",
                    description: "Walk obfuscation layers of a mounted shell sample.",
                    input_schema: ($intRaw[0] | del(.["$schema"], .["$id"], .title))
                }
            ]
        }'
}

# bl_setup_compose_env_body — emits env-create JSON per setup-flow.md §4.3.
bl_setup_compose_env_body() {
    jq -n '{
        name: "bl-curator-env",
        type: "cloud",
        packages: {
            apt: ["apache2","libapache2-mod-security2","modsecurity-crs","yara","jq","zstd","duckdb","pandoc","weasyprint"]
        },
        networking: {type: "unrestricted"}
    }'
}

# bl_setup_check — emit state.json snapshot + per-resource health; exit 0 if agent+env present.
bl_setup_check() {
    bl_setup_load_state || return $?
    local rr rr_label rr_canon pwd_canon
    rr=$(bl_setup_resolve_source 2>/dev/null) || rr="<unresolved>"   # check is operator-facing; never block on resolution
    # Label the discovery mechanism for operator clarity. Canonicalize both sides
    # so BL_REPO_ROOT="tests/.." resolves to the same path as pwd after cd.
    if [[ "$rr" == "<unresolved>" ]]; then
        rr_label="$rr"
    else
        rr_canon=$(cd "$rr" 2>/dev/null && pwd) || true   # cd may fail on bad path — fallback to raw label
        pwd_canon=$(pwd)
        if [[ -n "$rr_canon" && "$rr_canon" == "$pwd_canon" ]]; then
            rr_label="cwd ($rr)"
        else
            rr_label="$rr"
        fi
    fi
    printf 'bl setup --check (state=%s, source=%s):\n' "$BL_STATE_DIR" "$rr_label"
    local state_file="$BL_STATE_DIR/state.json"
    local missing=0
    if [[ -f "$state_file" ]]; then
        local agent_id env_id skills_count files_count
        agent_id=$(jq -r '.agent.id // empty' "$state_file")
        env_id=$(jq -r '.env_id // empty' "$state_file")
        skills_count=$(jq -r '.skills | length' "$state_file")
        files_count=$(jq -r '.files | length' "$state_file")
        if [[ -n "$agent_id" ]]; then
            printf '  agent: ok (%s v%s)\n' "$agent_id" "$(jq -r '.agent.version // 0' "$state_file")"
        else
            printf '  agent: missing\n'
            missing=$((missing + 1))
        fi
        if [[ -n "$env_id" ]]; then
            printf '  env: ok (%s)\n' "$env_id"
        else
            printf '  env: missing\n'
            missing=$((missing + 1))
        fi
        printf '  skills: %d provisioned\n' "$skills_count"
        printf '  files: %d workspace files\n' "$files_count"
        local pending_count
        pending_count=$(jq -r '.files_pending_deletion | length' "$state_file")
        (( pending_count > 0 )) && printf '  files_pending_deletion: %d (run bl setup --gc)\n' "$pending_count"
        printf '  last_sync: %s\n' "$(jq -r '.last_sync // "(never)"' "$state_file")"
    else
        printf '  agent: missing\n'
        printf '  env: missing\n'
        printf '  skills: 0 provisioned\n'
        printf '  files: 0 workspace files\n'
        missing=$((missing + 2))
    fi
    if (( missing > 0 )); then
        printf '\n%d resource(s) missing — run "bl setup --sync" to provision.\n' "$missing"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    printf '\nworkspace provisioned.\n'
    return "$BL_EX_OK"
}

bl_setup_sync() {
    local dry_run="${1:-0}"
    # Acquire flock on state.json to serialize concurrent --sync invocations (spec §11b row 4)
    local lock_file="$BL_STATE_DIR/state.json.lock"
    command touch "$lock_file" 2>/dev/null || {   # RO fs / perms — fail-fast diagnostic
        bl_error_envelope setup "$lock_file not writable"
        return "$BL_EX_PREFLIGHT_FAIL"
    }
    exec 203<>"$lock_file"
    if ! flock -x -w 30 203; then
        exec 203<&-
        bl_error_envelope setup "flock timeout on $lock_file (concurrent sync?)"
        return "$BL_EX_CONFLICT"
    fi
    # Pattern: save $? before exec 203<&- — exec resets $? to 0 so we must capture
    # the failed command's exit code first, then close FD, then propagate.
    local _rc=0
    bl_setup_load_state; _rc=$?
    if (( _rc != 0 )); then exec 203<&-; return "$_rc"; fi
    if (( dry_run == 1 )); then
        bl_setup_dry_run; _rc=$?
        exec 203<&-
        return "$_rc"
    fi
    bl_setup_ensure_env BL_STATE_ENV_ID; _rc=$?
    if (( _rc != 0 )); then exec 203<&-; return "$_rc"; fi
    bl_setup_save_state; _rc=$?
    if (( _rc != 0 )); then exec 203<&-; return "$_rc"; fi
    # bl-case memstore — needed for case working memory (bl-skills memstore retired in Path C)
    local case_memstore_id=""
    bl_setup_ensure_memstore case_memstore_id "bl-case" 'setup-memstore-create-case.json'; _rc=$?
    if (( _rc != 0 )); then exec 203<&-; return "$_rc"; fi
    BL_STATE_MEMSTORE_CASE_ID="$case_memstore_id"
    # Update case_memstores in state.json (singleton "_default" key for v1; multi-case future)
    local tmp_state="$BL_STATE_DIR/state.json.tmp.$$"
    jq --arg id "$case_memstore_id" '.case_memstores["_default"] = $id' "$BL_STATE_DIR/state.json" > "$tmp_state"
    command mv "$tmp_state" "$BL_STATE_DIR/state.json"
    bl_setup_seed_corpus apply; _rc=$?
    if (( _rc != 0 )); then exec 203<&-; return "$_rc"; fi
    bl_setup_seed_skills apply; _rc=$?
    if (( _rc != 0 )); then exec 203<&-; return "$_rc"; fi
    bl_setup_ensure_agent apply; _rc=$?
    if (( _rc != 0 )); then exec 203<&-; return "$_rc"; fi
    bl_setup_save_state; _rc=$?
    if (( _rc != 0 )); then exec 203<&-; return "$_rc"; fi
    printf 'bl setup --sync complete\n'
    printf '  agent           %s (version %s)\n' "${BL_STATE_AGENT_ID:-?}" "${BL_STATE_AGENT_VERSION:-0}"
    printf '  env             %s\n' "${BL_STATE_ENV_ID:-?}"
    printf '  case memstore   %s\n' "${BL_STATE_MEMSTORE_CASE_ID:-?}"
    exec 203<&-
    return "$BL_EX_OK"
}

# bl_setup_resolve_source — DESIGN.md §8.3 ordering:
#   0. honor BL_REPO_ROOT override (test infra + dev iteration)
#   1. cwd has skills/ + prompts/         → use cwd
#   2. $BL_REPO_URL set                   → shallow clone to $XDG_CACHE_HOME/blacklight/repo
#   3. default                            → clone https://github.com/rfxn/blacklight to cache
# Returns repo-root path on stdout; 0 on success, 65/69 on failure.
bl_setup_resolve_source() {
    if [[ -n "${BL_REPO_ROOT:-}" ]] && [[ -d "$BL_REPO_ROOT/skills" ]] && [[ -f "$BL_REPO_ROOT/prompts/curator-agent.md" ]]; then
        printf '%s' "$BL_REPO_ROOT"
        return "$BL_EX_OK"
    fi
    if [[ -d "./skills" ]] && [[ -f "./prompts/curator-agent.md" ]]; then
        printf '%s' "$(pwd)"
        return "$BL_EX_OK"
    fi
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/blacklight/repo"
    if [[ -n "${BL_REPO_URL:-}" ]]; then
        if [[ ! -d "$cache_dir/.git" ]]; then
            command mkdir -p "$(dirname "$cache_dir")"
            if ! git clone --depth 1 "$BL_REPO_URL" "$cache_dir" >/dev/null 2>&1; then   # network may be down — warn and fall through to default GitHub clone
                bl_warn "bl setup: BL_REPO_URL clone failed; falling through to default GitHub source"
            fi
        fi
        if [[ -d "$cache_dir/skills" ]] && [[ -f "$cache_dir/prompts/curator-agent.md" ]]; then
            printf '%s' "$cache_dir"
            return "$BL_EX_OK"
        fi
    fi
    if [[ ! -d "$cache_dir/.git" ]]; then
        command mkdir -p "$(dirname "$cache_dir")"
        if ! git clone --depth 1 https://github.com/rfxn/blacklight "$cache_dir" >/dev/null 2>&1; then   # network may be down — operator-facing remediation hint follows
            bl_error_envelope setup "default GitHub clone failed; check connectivity or set BL_REPO_URL"
            return "$BL_EX_UPSTREAM_ERROR"
        fi
    fi
    if [[ ! -d "$cache_dir/skills" ]] || [[ ! -f "$cache_dir/prompts/curator-agent.md" ]]; then
        bl_error_envelope setup "$cache_dir lacks skills/ + prompts/ after clone"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi
    printf '%s' "$cache_dir"
    return "$BL_EX_OK"
}

# bl_setup_install_hook_lmd — install bl-lmd-hook adapter into /etc/blacklight/hooks/
# and wire LMD's post_scan_hook to it. Idempotent.
bl_setup_install_hook_lmd() {
    local lmd_conf="${BL_LMD_CONF_PATH:-/usr/local/maldetect/conf.maldet}"
    # Test isolation hatch: BL_BLACKLIGHT_DIR redirects /etc/blacklight for unit tests.
    local blacklight_dir="${BL_BLACKLIGHT_DIR:-/etc/blacklight}"
    local hooks_dir="$blacklight_dir/hooks"
    local hook_target="$hooks_dir/bl-lmd-hook"

    # Verify LMD installed
    if [[ ! -d /usr/local/maldetect ]] && [[ "${BL_BLACKLIGHT_DIR:-}" == "" ]]; then
        bl_error_envelope setup "LMD not detected at /usr/local/maldetect"
        return "$BL_EX_NOT_FOUND"
    fi
    if [[ ! -f "$lmd_conf" ]]; then
        bl_error_envelope setup "LMD conf not found: $lmd_conf"
        return "$BL_EX_NOT_FOUND"
    fi

    # Locate hook source from repo (BL_REPO_ROOT or script dirname)
    local resolved
    resolved=$(readlink -f "$0" 2>/dev/null || printf '.')   # readlink may fail under bash -c — fallback to cwd
    local repo_root="${BL_REPO_ROOT:-$(dirname "$resolved")}"
    local hook_source="$repo_root/files/hooks/bl-lmd-hook"
    if [[ ! -r "$hook_source" ]]; then
        # Retry from cwd (common when sourced via 'source ./bl')
        hook_source="./files/hooks/bl-lmd-hook"
    fi
    if [[ ! -r "$hook_source" ]]; then
        bl_error_envelope setup "hook source not readable: $hook_source"
        return "$BL_EX_PREFLIGHT_FAIL"
    fi

    # Provision hooks dir (idempotent)
    command mkdir -p "$hooks_dir"
    command chmod 0755 "$hooks_dir"

    # Copy hook (idempotent — diff first to avoid no-op writes)
    if [[ -f "$hook_target" ]] && diff -q "$hook_source" "$hook_target" >/dev/null 2>&1; then   # 2>/dev/null: diff chatter irrelevant when only checking rc
        bl_info "bl-lmd-hook already up to date"
    else
        command cp "$hook_source" "$hook_target"
        command chmod 0755 "$hook_target"
        bl_info "installed bl-lmd-hook → $hook_target"
    fi

    # Wire post_scan_hook in conf.maldet (idempotent — flock-serialized)
    local lock_dir="${BL_VAR_DIR:-/var/lib/bl}/state"
    command mkdir -p "$lock_dir"
    local lock_file="$lock_dir/lmd-conf.lock"
    (
        flock -x 200
        if grep -qE '^post_scan_hook=' "$lmd_conf"; then
            command sed -i.bl-bak -E "s|^post_scan_hook=.*|post_scan_hook=\"$hook_target\"|" "$lmd_conf"
        else
            printf 'post_scan_hook="%s"\n' "$hook_target" >> "$lmd_conf"
        fi
    ) 200>"$lock_file"

    # Verify edit didn't break shell-source-ability (R1 mitigation)
    if ! bash -n "$lmd_conf" 2>/dev/null; then   # 2>/dev/null: bash -n stderr is diagnostic noise here; we check rc
        # Parse fail — restore backup
        if [[ -f "$lmd_conf.bl-bak" ]]; then
            command cp "$lmd_conf.bl-bak" "$lmd_conf"
            bl_error_envelope setup "post_scan_hook edit broke conf.maldet syntax; restored backup"
            return "$BL_EX_PREFLIGHT_FAIL"
        fi
    fi
    command rm -f "$lmd_conf.bl-bak"

    bl_info "bl-lmd-hook registered in $lmd_conf"
    return "$BL_EX_OK"
}

# bl_setup_import_from_lmd — read LMD conf.maldet notify keys, write to
# /etc/blacklight/notify.d/*. Idempotent. Skips empty values.
bl_setup_import_from_lmd() {
    local lmd_conf="${BL_LMD_CONF_PATH:-/usr/local/maldetect/conf.maldet}"
    # Test isolation hatch (matches bl_setup_install_hook_lmd)
    local blacklight_dir="${BL_BLACKLIGHT_DIR:-/etc/blacklight}"
    local notify_dir="$blacklight_dir/notify.d"

    [[ -r "$lmd_conf" ]] || { bl_error_envelope setup "LMD conf not readable: $lmd_conf"; return "$BL_EX_NOT_FOUND"; }

    command mkdir -p "$notify_dir"
    command chmod 0700 "$notify_dir"

    # Parse LMD conf with safe while-read + regex-match + metacharacter rejection.
    # Never eval operator-controlled file content (Anti-Pattern #12).
    local email_addr="" slack_token="" slack_channels=""
    local telegram_bot_token="" telegram_channel_id="" discord_webhook_url=""
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        line="${line#"${line%%[![:space:]]*}"}"
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # Strip surrounding quotes
            value="${value%\"}"; value="${value#\"}"
            value="${value%\'}"; value="${value#\'}"
            # Reject metacharacters (defense-in-depth even though file is root-owned)
            if [[ "$value" =~ [\;\|\&\$\(\)\{\}\`\<\>] ]]; then
                bl_warn "import-from-lmd: $key value rejected (metacharacter)"
                continue
            fi
            case "$key" in
                email_addr)            email_addr="$value" ;;
                slack_token)           slack_token="$value" ;;
                slack_channels)        slack_channels="$value" ;;
                telegram_bot_token)    telegram_bot_token="$value" ;;
                telegram_channel_id)   telegram_channel_id="$value" ;;
                discord_webhook_url)   discord_webhook_url="$value" ;;
            esac
        fi
    done < "$lmd_conf"

    # Email
    if [[ -n "$email_addr" ]]; then
        printf 'addr=%s\n' "$email_addr" > "$notify_dir/smtp.email"
        command chmod 0600 "$notify_dir/smtp.email"
        bl_info "imported: email_addr → $notify_dir/smtp.email (chmod 600)"
    else
        bl_info "not present: email_addr (skipped)"
    fi

    # Slack — bot mode requires both token AND channel; webhook mode if token looks like URL
    if [[ -n "$slack_token" ]]; then
        if [[ "$slack_token" =~ ^https?:// ]]; then
            # Webhook mode
            printf 'mode=webhook\nurl=%s\n' "$slack_token" > "$notify_dir/slack.token"
            bl_info "imported: slack_token (webhook) → $notify_dir/slack.token"
        elif [[ -n "$slack_channels" ]]; then
            # Bot mode (token + channel both required)
            local first_channel="${slack_channels%%,*}"
            printf 'mode=bot\ntoken=%s\nchannel=%s\n' "$slack_token" "$first_channel" > "$notify_dir/slack.token"
            bl_info "imported: slack_token + slack_channels=\"$first_channel\" → $notify_dir/slack.token (bot mode)"
        else
            bl_info "skipped: slack_token without slack_channels (bot-mode requires channel)"
        fi
        [[ -f "$notify_dir/slack.token" ]] && command chmod 0600 "$notify_dir/slack.token"
    else
        bl_info "not present: slack_token (skipped)"
    fi

    # Telegram (bot_token + channel_id both required)
    if [[ -n "$telegram_bot_token" && -n "$telegram_channel_id" ]]; then
        printf 'bot_token=%s\nchat_id=%s\n' "$telegram_bot_token" "$telegram_channel_id" > "$notify_dir/telegram.token"
        command chmod 0600 "$notify_dir/telegram.token"
        bl_info "imported: telegram_bot_token + telegram_channel_id → $notify_dir/telegram.token"
    else
        bl_info "not present: telegram_bot_token / telegram_channel_id (skipped)"
    fi

    # Discord
    if [[ -n "$discord_webhook_url" ]]; then
        printf '%s\n' "$discord_webhook_url" > "$notify_dir/discord.webhook"
        command chmod 0600 "$notify_dir/discord.webhook"
        bl_info "imported: discord_webhook_url → $notify_dir/discord.webhook"
    else
        bl_info "not present: discord_webhook_url (skipped)"
    fi

    bl_info "Done. Re-run bl setup --import-from-lmd to refresh."
    return "$BL_EX_OK"
}
