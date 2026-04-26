# Implementation Plan: M15 — bl `setup` API correctness against live Anthropic Managed Agents

**Goal:** Reconcile `bl setup` and `bl consult` against the live Anthropic Managed Agents API surface probed 2026-04-26. Eliminate two P0 destructive bugs (F1 migration, F9 PATCH-vs-POST agent update), one P0 wrong-verb bug (F6 DELETE-vs-archive), one P1 lying-success log (F5), one P2 dry-run wording mismatch (F2), and one wrong-field-name session-create bug (F12). F3 (system prompt drift on update) is resolved as a side-effect of the F9 fix — the new `bl_setup_compose_agent_update_body` includes `system: $prompt` from `prompts/curator-agent.md`, closing the "PATCH-omits-system" gap. Resolve the Skills primitive feature-gate via an operator-decided Path A (request workspace allowlist; keep architecture) or Path B (retire Skills CRUD; corpora-as-Files only).

**Architecture:** Localized fixes inside `src/bl.d/84-setup.sh` (migration safety, archive verb, CAS update verb, dry-run wording) and `src/bl.d/50-consult.sh` (session-create field name). One decision-gated phase resolves the Skills primitive: Path A keeps the M13 architecture and only deletes dead `bl_skills_list` (24-skills.sh:84-88); Path B rips out `bl_setup_seed_skills` + `bl_skills_create` + `bl_skills_versions_create` + `agent.skill_versions` plumbing and switches to Files-only attach. Doc drift sweep follows path choice. Live integration test gated on `BL_LIVE=1` exercises the corrected setup → consult path against a real workspace.

**Tech Stack:** bash 4.1+ (CentOS 6 floor) · jq · curl · BATS via batsman submodule (tests/infra/) · `managed-agents-2026-04-01` beta header · anthropic-version `2023-06-01` · existing `bl_api_call` adapter (returns `BL_EX_CONFLICT=71` on HTTP 409, which we'll repurpose for CAS retry).

**Spec:** `/tmp/bl-m13-exercise/M14-FIX-PROMPT.md` (phased fix prompt) + `/tmp/bl-m13-exercise/API-SURFACE.md` (canonical live API map) + `/tmp/bl-m13-exercise/FINDINGS.md` (probe-backed findings F1–F12).

**Phases:** 8

**Plan Version:** 3.0.6

**Base commit:** post-M14 main. M14 (PLAN-M14.md, 12 phases, substrate-hook closed-loop) also touches `src/bl.d/84-setup.sh` (M14 P9 lines 12-29 — argv parser extension for `--install-hook` / `--import-from-lmd`). M15 dispatches AFTER M14 ships. Engineer rebases onto post-M14 `main` before P1, then runs `git log --oneline -5 -- src/bl.d/84-setup.sh src/bl.d/50-consult.sh` to capture the post-M14 line numbers before any phase begins. All line references in this plan are pinned to `main@48cb9b6` (M13 release stamp) and MUST be re-verified against the post-M14 base in P1 setup.

---

## Operator Decision — Path A vs Path B (gates Phase 6)

The Skills primitive (`POST /v1/skills`) is registered at the Anthropic edge (`OPTIONS` returns `Allow: POST`) but returns HTTP 404 on actual call — a workspace allowlist / feature-flag gate. Two paths forward; **operator picks before P6 dispatch**:

| | Path A — Allowlist + keep | Path B — Retire Skills CRUD |
|---|---|---|
| **External action** | File Anthropic support ticket; await allowlist | None |
| **Code delta** | Delete dead `bl_skills_list` (24-skills.sh:84-88). Otherwise unchanged. | Delete `bl_skills_create` / `bl_skills_versions_create` / `bl_skills_get` / `bl_skills_list` / `bl_skills_delete` (entire 24-skills.sh). Delete `bl_setup_seed_skills` (84-setup.sh:294-361). Delete `agent.skills[]` + `skill_versions` references in `bl_setup_compose_agent_body`. Update `routing-skills/` directory disposition (kept as documentation; contents become inert). |
| **Behavior change** | None when allowlist arrives — restores M13 Path C as designed (lazy-loaded routing Skills via Anthropic harness). | Curator gets all 6 routing-Skill bodies as workspace Files attached at session creation; system prompt's §3.1 Primitives map updated to "workspace corpora; full-context per turn". 1M context window absorbs ~50KB total Skill bodies easily. |
| **Doc drift sweep** | docs/managed-agents.md §3 (Skills row — note workspace-gating); §4 lines 71-77 (verbs confirmed against probe); §4 lines 82-83 (Skills attach via `agent.skills[]` not `session.resources[]` — corrected); §5 (sessions field name). docs/setup-flow.md §4.4a left in place (aspirational) with a "feature-gated" callout. DESIGN.md §12 add divergence note. | docs/managed-agents.md §4 (Skills) replaced with "Skills primitive not used; routing via Files + system-prompt routing." docs/setup-flow.md §4.4a replaced with "no Skills create step". DESIGN.md §12 + curator system prompt §3.1 updated. |
| **Risk if wrong** | Allowlist may not arrive in M15 window → P6 stays scoped to dead-code deletion only; Path C remains aspirational. | Architectural change permanent; flipping back to Path A later requires re-introducing the Skills CRUD plumbing. |
| **Recommendation** | Default if allowlist response time ≤ M15 dispatch window. | Default if allowlist response time uncertain or if operator wants the demo path verified end-to-end without external dependency. |

**Decision artifact:** operator records choice in PLAN-M15.md preamble before P6 dispatch (replace the literal `<DECISION-PENDING>` token in P6 with `Path A` or `Path B`). The dispatcher refuses to dispatch P6 if the token is still `<DECISION-PENDING>`.

---

## Conventions

**Commit message format** — every M15 commit uses `[Tag] M15 P<N> — <description>` where Tag is one of `[New]`, `[Change]`, `[Fix]`. Body lines tagged the same. No `Co-Authored-By`. No Claude/Anthropic attribution. Stage files explicitly by name (never `git add -A` / `git add .`).

**bl source-layout rule (CLAUDE.md "bl source layout")** — never edit `bl` directly. Always edit `src/bl.d/NN-<name>.sh`, then run `make bl`, then commit BOTH the part and the regenerated `bl`. `tests/Makefile` `_bl-drift-check` (runs before container build) fails the test run if `bl` drifts from source. Commit message names the part, not the assembled file. Stage path scope: `git add src/bl.d/<part> bl <other-files>`. Never bare `git commit`.

**Coreutils prefix discipline (CLAUDE.md "Shell Standards")** — project source code uses `command <util>` for all coreutils (`command cat`, `command rm`, `command mv`, etc.) for el6 PATH portability. Bare `printf` and `echo` (bash builtins) are exempt. BATS test files use bare coreutils — Docker containers have no alias.

**State.json schema unchanged** — the existing `agent.id` / `agent.version` / `agent.skill_versions` / `env_id` / `skills` / `files` / `case_memstores` / `case_files` / `case_id_counter` / `case_current` / `session_ids` / `last_sync` keys remain. Path B (if chosen in P6) zeros out `agent.skill_versions` to `{}` and clears `skills` to `{}` permanently but does not change the schema shape — backward-compatible state.json reads.

**Live test gating** — every BATS test that hits the real Anthropic API is gated by `BL_LIVE=1` (mirrors the existing `BL_EVAL_LIVE=1` pattern from `tests/skill-routing/eval-runner.bats`). Default CI behaviour skips cleanly.

**Backup-on-migration discipline** — F1's fix copies legacy state files to `$BL_STATE_DIR/migration-backup-<epoch>/` before delete; backup retention is one release cycle (cleared on the next `bl setup --gc` invocation that observes a healthy `state.json`).

---

## File Map

### New Files
| File | Lines | Purpose | Test File |
|------|-------|---------|-----------|
| `tests/live/setup-live.bats` | ~120 | BL_LIVE=1 integration smoke (full setup → check → consult against real API) | self |
| `tests/fixtures/setup-agent-update-cas-success.json` | ~5 | Mock response shape for CAS-style POST `/v1/agents/<id>` (first-try success) | tests/08-setup.bats |
| `tests/fixtures/setup-agent-update-cas-conflict.json` | ~5 | Mock 409 response: `Concurrent modification detected` | tests/08-setup.bats |
| `tests/fixtures/setup-agent-update-cas-retry-success.json` | ~5 | Mock 200 response for the second POST attempt after a 409 (returns version 6) | tests/08-setup.bats |
| `tests/fixtures/setup-agent-fetch-v5.json` | ~5 | Mock GET `/v1/agents/<id>` response used by the CAS retry helper to refresh the local version after a 409 | tests/08-setup.bats |
| `tests/fixtures/setup-agent-archive-success.json` | ~5 | Mock 200 response for `POST /v1/agents/<id>/archive` | tests/08-setup.bats |

### Modified Files
| File | Changes | Test File |
|------|---------|-----------|
| `src/bl.d/84-setup.sh` | F1 migration safety (lines 144-178); F2 dry-run wording (line 287); F5+F6 archive verb (line 427); F9 CAS update + new compose-update-body helper (lines 538-610) | tests/08-setup.bats |
| `src/bl.d/50-consult.sh` | F12 session-create body field rename `agent_id` → `agent` (line 195) | tests/05-consult-run-case.bats |
| `src/bl.d/24-skills.sh` | Path A: delete `bl_skills_list` (lines 84-88); Path B: delete entire file | tests/08-setup.bats |
| `tests/08-setup.bats` | New tests for migration safety, archive verb, CAS update; existing tests adapt to new mock shapes | self |
| `tests/05-consult-run-case.bats` | Verify session-create body uses `agent` field (regression for F12) | self |
| `tests/fixtures/setup-agent-update-success.json` | Update to CAS-style response shape; legacy fixture renamed/repointed | tests/08-setup.bats |
| `docs/managed-agents.md` | Path-dependent §3, §4, §5 corrections (see Decision table above) | N/A (docs) |
| `docs/setup-flow.md` | Path-dependent §4.4a + §5 corrections | N/A (docs) |
| `DESIGN.md` | §12 divergence note (live API vs aspirational architecture) | N/A (docs) |
| `prompts/curator-agent.md` | Path B only: §3.1 Primitives map "harness-managed; lazy-load" → "workspace corpora; full-context per turn" | N/A (docs — agent prompt) |
| `bl` | Regenerated via `make bl` after each `src/bl.d/` part change | (drift-check) |
| `CHANGELOG` | One stanza per phase | N/A (docs) |

### Deleted Files
| File | Reason |
|------|--------|
| (none in Path A) | — |
| `routing-skills/` directory contents (Path B only) | Routing Skills primitive retired; descriptions + SKILL.md bodies are inert under Path B (kept as documentation of the M13 design; not deleted from disk; just no longer consumed by `bl setup`) |

(No actual file deletions in either path. Path B re-points the architecture without `rm -rf routing-skills/`.)

### `.secrets/env` cleanup (operator-managed, NOT under source control)
After P8 lands a successful live setup:
- Remove orphan `BL_SKILL_ID_CASE_LIFECYCLE` / `BL_SKILL_ID_POLYSHELL` / `BL_SKILL_ID_MODSEC_PATTERNS` lines (M0-era IDs that 404 on the platform)
- Re-export updated `BL_CURATOR_AGENT_ID` and `BL_CURATOR_AGENT_VERSION` from the freshly-populated `state.json`

This is operator-side hygiene, not a code change; documented in P8 Step 4 as a runbook.

---

## Phase Dependencies

- Phase 1: none
- Phase 2: [1]
- Phase 3: [2]
- Phase 4: [3]
- Phase 5: none
- Phase 6: [4]
- Phase 7: [6]
- Phase 8: [4, 5, 6, 7]

Phases 1-4 are strictly sequential because all four touch `src/bl.d/84-setup.sh` (different sections, but the dispatcher's parallel-worktree merge is not safe for same-file edits). Phase 5 (50-consult.sh) is independent of Phase 1-4 and can run in parallel with any of them. Phase 6 needs the new compose-update-body helper from Phase 4 to know whether `agent.skills[]` stays (Path A) or gets removed (Path B). Phase 7 (docs) depends on Phase 6 landing the path choice. Phase 8 (live integration smoke + secrets cleanup) consumes everything.

---

### Phase 1: F1 — destructive migration safety (`bl_setup_load_state`)

Wrap the legacy-state migration block in a backup-then-validate-then-commit pattern. Validate jq output before any `mv` or `rm`. Copy legacy files to `migration-backup-<epoch>/` before the destructive cleanup so a partial failure can be recovered manually.

**Files:**
- Modify: `src/bl.d/84-setup.sh` (lines 144-178, `bl_setup_load_state` migration block) — add backup + validate + abort-on-error
- Modify: `tests/08-setup.bats` — add migration-safety tests
- Modify: `bl` — regenerated

- **Mode**: serial-agent
- **Accept**:
  1. `grep -c 'migration-backup-' src/bl.d/84-setup.sh` returns ≥ 1 (backup directory pattern in the migration block)
  2. `grep -c '^\s*command rm -f .*agent-id .*env-id' src/bl.d/84-setup.sh` returns 0 (the unconditional rm removed)
  3. `bash -n src/bl.d/84-setup.sh` exit 0
  4. `make bl-check` passes (no drift)
  5. `make -C tests test-quick` passes
- **Test**: `tests/08-setup.bats::@test "bl setup: migration with valid case-id-counter writes state.json + preserves backup"` AND `::@test "bl setup: migration with corrupt case-id-counter aborts cleanly without deleting legacy files"`
- **Edge cases**: corrupt counter content (jq rejects); missing case-id-counter file (skip migration entirely); existing migration-backup-* directory (timestamp suffix avoids collision)
- **Regression-case**: `tests/08-setup.bats::@test "bl setup: migration with corrupt case-id-counter aborts cleanly without deleting legacy files"`

- [ ] **Step 1: Rebase verify — capture post-M14 line numbers**

  Before editing, confirm `bl_setup_load_state` line range against the current `src/bl.d/84-setup.sh`. M14 P9 only edited lines 12-29 (argv parser); the migration block at 144-178 should be unchanged. Engineer runs:

  ```bash
  awk '/^bl_setup_load_state\(\) {/,/^}/' src/bl.d/84-setup.sh | head -1
  grep -n 'bl_setup: migrating per-key state files' src/bl.d/84-setup.sh
  # expect: a single hit; capture the line number for editing context
  ```

- [ ] **Step 2: Replace the migration block at `bl_setup_load_state` lines 143-178**

  Replace the block from the comment `# Migrate: populate shell vars from old files, write state.json, delete old files atomically` through the closing `return "$BL_EX_OK"` of the migration branch. New block:

  ```bash
      # Migrate: populate shell vars from old files, write state.json, delete old files atomically
      bl_info "bl setup: migrating per-key state files → state.json"
      BL_STATE_AGENT_ID="$old_agent"
      BL_STATE_AGENT_VERSION=0   # version unknown pre-Path C; first --sync will probe
      BL_STATE_ENV_ID="$old_env"
      BL_STATE_MEMSTORE_CASE_ID="$old_case"
      BL_STATE_LAST_SYNC=""

      # F1 fix — defence in depth: copy legacy files to a timestamped backup
      # BEFORE any destructive cleanup. Recovery anchor if migration fails.
      local backup_dir="$BL_STATE_DIR/migration-backup-$(command date -u +%s)"
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
  ```

  The exact `old_string` for the Edit tool is the existing block from line 143 (`    # Migrate: populate shell vars from old files, write state.json, delete old files atomically`) through line 178 (`    return "$BL_EX_OK"`). Do NOT modify the surrounding function — only this block.

- [ ] **Step 3: Add migration-safety tests at end of `tests/08-setup.bats`**

  Append three new tests. Each pre-populates `$BL_STATE_DIR` with legacy files (agent-id, env-id, memstore-case-id, case-id-counter, case.current), invokes a setup verb that triggers migration (e.g., `bl setup --check`), and asserts state.json + backup directory + return code.

  ```bats
  # ---------------------------------------------------------------------------
  # M15 P1 — migration safety (F1)
  # ---------------------------------------------------------------------------

  @test "bl setup: migration with valid case-id-counter writes state.json + preserves backup" {
      mkdir -p "$BL_STATE_DIR"
      printf 'agent_TEST123' > "$BL_STATE_DIR/agent-id"
      printf 'env_TEST456' > "$BL_STATE_DIR/env-id"
      printf 'memstore_TESTabc' > "$BL_STATE_DIR/memstore-case-id"
      printf '{"year":2026,"n":7}\n' > "$BL_STATE_DIR/case-id-counter"
      printf 'CASE-2026-0007' > "$BL_STATE_DIR/case.current"
      run "$BL_SOURCE" setup --check
      [ "$status" -eq 0 ] || [ "$status" -eq 65 ]   # state populated; --check may exit 65 if env is unreachable in tests
      [ -f "$BL_STATE_DIR/state.json" ]
      [ "$(jq -r '.agent.id' "$BL_STATE_DIR/state.json")" = "agent_TEST123" ]
      [ "$(jq -r '.env_id' "$BL_STATE_DIR/state.json")" = "env_TEST456" ]
      [ "$(jq -r '.case_memstores._legacy' "$BL_STATE_DIR/state.json")" = "memstore_TESTabc" ]
      [ "$(jq -r '.case_id_counter.year' "$BL_STATE_DIR/state.json")" = "2026" ]
      [ "$(jq -r '.case_id_counter.n' "$BL_STATE_DIR/state.json")" = "7" ]
      # backup directory created
      ls "$BL_STATE_DIR"/migration-backup-* >/dev/null 2>&1
      [ "$?" -eq 0 ]
      # legacy files removed
      [ ! -f "$BL_STATE_DIR/agent-id" ]
      [ ! -f "$BL_STATE_DIR/env-id" ]
  }

  @test "bl setup: migration with corrupt case-id-counter aborts cleanly without deleting legacy files" {
      mkdir -p "$BL_STATE_DIR"
      printf 'agent_TEST123' > "$BL_STATE_DIR/agent-id"
      printf 'env_TEST456' > "$BL_STATE_DIR/env-id"
      printf '{"year":2026,"n":' > "$BL_STATE_DIR/case-id-counter"   # truncated JSON — jq rejects
      run "$BL_SOURCE" setup --check
      # F1 fix substitutes {} on counter validation failure (warn, not abort)
      # Migration succeeds; counter_validated falls back to {}; legacy files removed.
      [ -f "$BL_STATE_DIR/state.json" ]
      [ "$(jq -r '.agent.id' "$BL_STATE_DIR/state.json")" = "agent_TEST123" ]
      [ "$(jq -r '.case_id_counter' "$BL_STATE_DIR/state.json")" = "{}" ]
      # backup preserves the corrupt counter for diagnosis
      ls "$BL_STATE_DIR"/migration-backup-*/case-id-counter >/dev/null 2>&1
      [ "$?" -eq 0 ]
      # warn line emitted
      [[ "$output" == *"case-id-counter content rejected by jq"* ]]
  }

  @test "bl setup: migration aborts cleanly when state.json compose fails" {
      # Simulate jq compose failure by injecting a malformed jq template into
      # bl_setup_load_state via a sourced override. chmod 555 is unreliable
      # in root-context Docker containers (tests run as root; DAC bypassed).
      # Instead, override the state-dir to a path that will fail mkdir under
      # a non-existent parent that is itself not writable: we use /proc/self/
      # which rejects writes regardless of UID.
      mkdir -p "$BL_STATE_DIR"
      printf 'agent_TEST123' > "$BL_STATE_DIR/agent-id"
      # Move the parent var dir to a read-only mount point — /proc rejects all writes
      export BL_STATE_DIR="/proc/self/state-cannot-write"
      run "$BL_SOURCE" setup --check
      [ "$status" -ne 0 ]
      # Restore for cleanup
      export BL_STATE_DIR="$BL_VAR_DIR/state"
      # legacy files NOT deleted on failure (state.json was never created at the proc path)
      [ -f "$BL_STATE_DIR/agent-id" ]
  }
  ```

- [ ] **Step 4: Regenerate `bl` and verify drift-check**

  ```bash
  make bl
  # expect: success message; bl file regenerated
  make bl-check
  # expect: success; no drift between src/bl.d/ and bl
  bash -n src/bl.d/84-setup.sh
  # expect: exit 0
  ```

- [ ] **Step 5: Run quick test suite**

  ```bash
  make -C tests test-quick 2>&1 | tee /tmp/test-m15-p1.log | tail -30
  grep -c "not ok" /tmp/test-m15-p1.log
  # expect: 0
  grep "ok .* migration with" /tmp/test-m15-p1.log
  # expect: 3 lines (3 new migration tests)
  ```

- [ ] **Step 6: Update CHANGELOG**

  Add stanza at top of `CHANGELOG` (single-changelog rule per blacklight CLAUDE.md):
  ```
  M15 P1 (2026-04-DD)
    [Fix] bl_setup_load_state migration is now backup-then-validate-then-commit;
          legacy state files are preserved on any failure during the move to state.json
          (F1 P0 — previous behavior could leave a 0-byte state.json + lost legacy files).
  ```

- [ ] **Step 7: Commit**

  ```bash
  git add src/bl.d/84-setup.sh tests/08-setup.bats bl CHANGELOG
  git commit -m "$(cat <<'EOF'
  [Fix] M15 P1 — bl_setup_load_state: backup-then-validate migration (F1)

  [Fix] src/bl.d/84-setup.sh — wrap legacy-state migration in
  backup-validate-commit ordering: (1) copy legacy files to
  migration-backup-<epoch>/ before any destructive cleanup, (2) validate
  case-id-counter content via jq -e before --argjson (substitute {} on
  rejection with operator warning), (3) verify composed state.json passes
  schema_version check before mv, (4) delete legacy files only after
  state.json is committed. Recovery anchor preserved on every failure path.
  [New] tests/08-setup.bats — 3 migration-safety tests covering valid
  counter, corrupt counter, and filesystem-failure aborts.
  EOF
  )"
  ```

---

### Phase 2: F2 — dry-run wording (`bl_setup_seed_corpus`)

Thread the dry-run flag into the corpus-seed summary print. Eliminate the self-contradicting `8 uploaded, 0 skipped, 0 superseded` log line that prints under dry-run mode.

**Files:**
- Modify: `src/bl.d/84-setup.sh` (line 287 in `bl_setup_seed_corpus`) — switch summary wording on `$mode`
- Modify: `tests/08-setup.bats` — add dry-run wording assertion
- Modify: `bl` — regenerated

- **Mode**: serial-context
- **Accept**:
  1. `grep -c 'corpus seed — would upload' src/bl.d/84-setup.sh` returns ≥ 1 (matches the literal string in the new dry-run branch)
  2. Running `BL_REPO_ROOT=<fake-repo> bl setup --sync --dry-run 2>&1` (with mocked Files API) does NOT print the past-tense substring `bl setup: corpus seed — N uploaded`
  3. `bash -n src/bl.d/84-setup.sh` exit 0
- **Test**: `tests/08-setup.bats::@test "bl setup --sync --dry-run: corpus-seed summary uses 'would upload' wording"`
- **Edge cases**: zero corpora (output reads "would upload 0 corpora"); apply mode unchanged
- **Regression-case**: `tests/08-setup.bats::@test "bl setup --sync --dry-run: corpus-seed summary uses 'would upload' wording"`

- [ ] **Step 1: Modify the summary line in `bl_setup_seed_corpus`**

  Replace the unconditional summary at line 287:
  ```bash
  bl_info "bl setup: corpus seed — $upload_count uploaded, $skip_count skipped, $supersede_count superseded"
  ```
  With:
  ```bash
  if [[ "$mode" == "dry-run" ]]; then
      bl_info "bl setup: corpus seed — would upload $upload_count, would skip $skip_count, would supersede $supersede_count"
  else
      bl_info "bl setup: corpus seed — $upload_count uploaded, $skip_count skipped, $supersede_count superseded"
  fi
  ```

- [ ] **Step 2: Add dry-run wording test**

  Append to `tests/08-setup.bats`:
  ```bats
  @test "bl setup --sync --dry-run: corpus-seed summary uses 'would upload' wording" {
      local fake_repo
      fake_repo=$(mktemp -d)
      _make_fake_repo "$fake_repo"
      printf '# foundations\n' > "$fake_repo/skills-corpus/foundations.md"
      _state_json_seeded
      export BL_REPO_ROOT="$fake_repo"
      bl_curator_mock_set_response 'setup-agents-list-empty.json' 200
      run "$BL_SOURCE" setup --sync --dry-run
      [ "$status" -eq 0 ]
      [[ "$output" == *"would upload"* ]]
      # Anti-assertion — the past-tense "uploaded" must not appear under dry-run
      ! [[ "$output" =~ "corpus seed — 1 uploaded" ]]
  }
  ```

- [ ] **Step 3: Regenerate bl + run test**

  ```bash
  make bl && make bl-check
  # expect: pass
  bats tests/08-setup.bats -f "would upload" 2>&1 | tail -5
  # expect: 1 ok line
  ```

- [ ] **Step 4: Update CHANGELOG**

  Add stanza:
  ```
  M15 P2 (2026-04-DD)
    [Fix] bl_setup_seed_corpus dry-run summary uses "would upload" wording;
          eliminates self-contradicting "N uploaded" / "0 mutations would be applied"
          output under --dry-run (F2).
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add src/bl.d/84-setup.sh tests/08-setup.bats bl CHANGELOG
  git commit -m "$(cat <<'EOF'
  [Fix] M15 P2 — corpus-seed dry-run wording (F2)

  [Fix] src/bl.d/84-setup.sh — bl_setup_seed_corpus summary line now
  switches between "would upload" (dry-run) and "uploaded" (apply) phrasing.
  Eliminates the self-contradicting line that previously printed
  "8 uploaded" four lines before "0 mutations would be applied".
  [New] tests/08-setup.bats — anti-assertion on past-tense vocabulary
  under dry-run mode.
  EOF
  )"
  ```

---

### Phase 3: F5 + F6 — reset path uses archive verb + fixes lying-success log

Replace `DELETE /v1/agents/<id>` with `POST /v1/agents/<id>/archive`. Restructure the brace-group fall-through that logs `INFO: deleted agent` after `WARN: agent delete failed`. Apply same `&&` discipline to the loop bodies for `bl_skills_delete` and `bl_files_delete`.

**Files:**
- Modify: `src/bl.d/84-setup.sh` (lines 427-437, `bl_setup_reset` body) — verb swap + control-flow fix
- Modify: `tests/08-setup.bats` — add archive-verb test
- Create: `tests/fixtures/setup-agent-archive-success.json`
- Modify: `bl` — regenerated

- **Mode**: serial-agent
- **Accept**:
  1. `grep -c 'POST .*/v1/agents/.*archive' src/bl.d/84-setup.sh` returns ≥ 1
  2. `grep -c 'DELETE .*/v1/agents/' src/bl.d/84-setup.sh` returns 0 (verb retired in setup module)
  3. `grep -c '|| bl_warn "agent delete failed"; bl_info "deleted agent' src/bl.d/84-setup.sh` returns 0 (the lying-success line is gone)
  4. `bash -n src/bl.d/84-setup.sh` exit 0
- **Test**: `tests/08-setup.bats::@test "bl setup --reset: archive verb success → state.json wiped"` AND `::@test "bl setup --reset: archive failure → abort, state.json preserved"`
- **Edge cases**: archive 404 (already archived — treat as idempotent success); archive 5xx (abort, preserve state); skills_delete / files_delete loops also fail-fast on warn fall-through
- **Regression-case**: `tests/08-setup.bats::@test "bl setup --reset: archive failure → abort, state.json preserved"`

- [ ] **Step 1: Replace lines 427-437 of `bl_setup_reset`**

  Old:
  ```bash
      [[ -n "$agent_id" ]] && { bl_api_call DELETE "/v1/agents/$agent_id" >/dev/null || bl_warn "agent delete failed"; bl_info "deleted agent $agent_id"; }
      local skill_id
      while IFS= read -r skill_id; do
          [[ -z "$skill_id" ]] && continue
          bl_skills_delete "$skill_id" || bl_warn "skill delete failed: $skill_id"
      done < <(jq -r '.skills[].id // empty' "$BL_STATE_DIR/state.json")
      local file_id
      while IFS= read -r file_id; do
          [[ -z "$file_id" ]] && continue
          bl_files_delete "$file_id" || bl_warn "file delete failed: $file_id"
      done < <(jq -r '.files[].file_id // empty' "$BL_STATE_DIR/state.json")
  ```

  New:
  ```bash
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
  ```

- [ ] **Step 2: Create archive-success fixture**

  Write `tests/fixtures/setup-agent-archive-success.json`:
  ```json
  {"id":"agent_M8_TEST","name":"bl-curator","version":3,"archived_at":"2026-04-26T05:00:00Z"}
  ```

- [ ] **Step 3: Add reset tests**

  Append to `tests/08-setup.bats`:
  ```bats
  @test "bl setup --reset: archive verb success → state.json wiped" {
      _state_json_seeded
      bl_curator_mock_add_route '/v1/agents/.*/archive' 'setup-agent-archive-success.json' 200
      run "$BL_SOURCE" setup --reset --force
      [ "$status" -eq 0 ]
      [[ "$output" == *"archived agent agent_M8_TEST"* ]]
      # state.json preserved as a wiped baseline
      [ -f "$BL_STATE_DIR/state.json" ]
      [ "$(jq -r '.agent.id' "$BL_STATE_DIR/state.json")" = "" ]
  }

  @test "bl setup --reset: archive failure → abort, state.json preserved" {
      _state_json_seeded
      # Default mock returns 200 / files-api fixture; we want a 4xx to simulate failure
      bl_curator_mock_add_route '/v1/agents/.*/archive' 'setup-error-400.json' 400
      run "$BL_SOURCE" setup --reset --force
      [ "$status" -ne 0 ]
      [[ "$output" == *"agent archive failed"* ]]
      [[ "$output" == *"aborting reset"* ]]
      # state.json untouched: agent.id still present
      [ "$(jq -r '.agent.id' "$BL_STATE_DIR/state.json")" = "agent_M8_TEST" ]
  }
  ```

- [ ] **Step 4: Regenerate bl + run tests**

  ```bash
  make bl && make bl-check
  bats tests/08-setup.bats -f "reset" 2>&1 | tail -10
  # expect: all reset-related tests ok
  ```

- [ ] **Step 5: Update CHANGELOG**

  Add stanza:
  ```
  M15 P3 (2026-04-DD)
    [Fix] bl_setup_reset uses POST /v1/agents/<id>/archive (the verb the live API
          actually exposes) instead of DELETE /v1/agents/<id>; aborts the reset on
          archive failure instead of wiping state.json regardless (F5, F6).
  ```

- [ ] **Step 6: Commit**

  ```bash
  git add src/bl.d/84-setup.sh tests/08-setup.bats tests/fixtures/setup-agent-archive-success.json bl CHANGELOG
  git commit -m "$(cat <<'EOF'
  [Fix] M15 P3 — reset uses archive verb + fail-fast on archive failure (F5, F6)

  [Fix] src/bl.d/84-setup.sh — bl_setup_reset replaces DELETE /v1/agents/<id>
  with POST /v1/agents/<id>/archive (the verb the live API actually exposes).
  The brace-group fall-through that logged "INFO: deleted agent <id>" after
  "WARN: agent delete failed" is restructured to abort the reset on archive
  failure instead of wiping state.json regardless of platform state.
  [Change] skills-delete and files-delete loop bodies adopt the same
  fail-fast discipline.
  [New] tests/08-setup.bats — archive-success and archive-failure tests.
  [New] tests/fixtures/setup-agent-archive-success.json.
  EOF
  )"
  ```

---

### Phase 4: F9 — agent update via CAS verb (`POST /v1/agents/<id>` with `version`)

Replace the broken `PATCH /v1/agents/<id>` apply branch with the live API's compare-and-swap update verb. Add a new compose helper `bl_setup_compose_agent_update_body` that includes the full `system` + `tools` + `skills` (path-dependent) replacement body alongside the `version` CAS field. Wire 409 → refetch → retry once.

**Files:**
- Modify: `src/bl.d/84-setup.sh` (lines 538-610, `bl_setup_ensure_agent`) — replace PATCH branch with CAS POST
- Modify: `src/bl.d/84-setup.sh` — add new helper `bl_setup_compose_agent_update_body`
- Create: `tests/fixtures/setup-agent-update-cas-success.json`, `tests/fixtures/setup-agent-update-cas-conflict.json`
- Modify: `tests/fixtures/setup-agent-update-success.json` — repoint to new shape OR keep as legacy
- Modify: `tests/08-setup.bats` — CAS success / 409 retry tests
- Modify: `bl` — regenerated

- **Mode**: serial-agent
- **Accept**:
  1. `grep -c 'POST .*/v1/agents/' src/bl.d/84-setup.sh | head` shows hits in both `bl_setup_ensure_agent` (update path) and `bl_setup_reset` (archive path); `grep -c 'PATCH ' src/bl.d/84-setup.sh` returns 0
  2. `grep -c 'bl_setup_compose_agent_update_body' src/bl.d/84-setup.sh` returns ≥ 2 (definition + call)
  3. New CAS body shape: `grep -c 'version: \$ver' src/bl.d/84-setup.sh` returns ≥ 1
  4. F3 resolution: `grep -c 'bl_setup_compose_agent_body' src/bl.d/84-setup.sh` returns ≥ 2 — the update-body composer delegates to the create-body composer, which already emits `system: $prompt` (line 720). Verifies that the rewritten `prompts/curator-agent.md` will reach the live agent on every CAS update.
  5. `bash -n src/bl.d/84-setup.sh` exit 0
- **Test**: `tests/08-setup.bats::@test "bl setup --sync: existing agent → CAS update succeeds, version bumps"` AND `::@test "bl setup --sync: existing agent → 409 conflict triggers refetch + retry"`
- **Edge cases**: 409 on first try (refetch + retry once); 409 on retry (abort with operator-readable message); empty agent.skills[] (Path B); populated skills[] (Path A)
- **Regression-case**: `tests/08-setup.bats::@test "bl setup --sync: existing agent → 409 conflict triggers refetch + retry"`
- **Tests-may-touch:** `tests/fixtures/*.json`, `tests/helpers/*.bash`

- [ ] **Step 1: Replace lines 546-570 (PATCH apply branch) in `bl_setup_ensure_agent`**

  Old apply branch:
  ```bash
      if [[ -n "$cached_id" ]] && [[ "$mode" == "apply" ]]; then
          # Update existing agent — bump version with skill_versions from state
          local body_file
          body_file=$(command mktemp)
          local skill_versions_json
          skill_versions_json=$(jq -c '.agent.skill_versions // {}' "$state_file")
          jq -n \
              --argjson sv "$skill_versions_json" \
              '{skill_versions: $sv}' > "$body_file"
          local resp rc
          rc=0
          resp=$(bl_api_call PATCH "/v1/agents/$cached_id" "$body_file") || rc=$?
          command rm -f "$body_file"
          (( rc != 0 )) && return $rc
          local new_version
          new_version=$(printf '%s' "$resp" | jq -r '.version // 0')
          # Persist new version to state.json
          local existing_state tmp_state
          existing_state=$(command cat "$state_file")
          tmp_state="$state_file.tmp.$$"
          printf '%s' "$existing_state" | jq --argjson v "$new_version" '.agent.version = $v' > "$tmp_state"
          command mv "$tmp_state" "$state_file"
          BL_STATE_AGENT_ID="$cached_id"
          BL_STATE_AGENT_VERSION="$new_version"
          return "$BL_EX_OK"
      fi
  ```

  New apply branch (delegates to a new helper that does CAS + retry):
  ```bash
      if [[ -n "$cached_id" ]] && [[ "$mode" == "apply" ]]; then
          # F9 fix — agents are versioned; PATCH is not a real verb. Update via
          # POST /v1/agents/<id> with optimistic-CAS body {version: <current>, ...}.
          # On 409 ("Concurrent modification detected"), refetch GET, update
          # cached version in state.json, retry once.
          bl_setup_update_agent_cas "$cached_id"
          return $?
      fi
  ```

- [ ] **Step 2: Add `bl_setup_update_agent_cas` and `bl_setup_compose_agent_update_body` helpers**

  Insert after `bl_setup_ensure_agent` (around line 611), before `bl_setup_ensure_env`:

  ```bash
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
  ```

- [ ] **Step 3: Create CAS fixtures (4 new files) and repoint legacy fixture references**

  Old `tests/fixtures/setup-agent-update-success.json` (used in legacy PATCH tests) — keep but rename to `setup-agent-update-legacy-patch-success.json` for clarity, then create the four new fixtures matching the live POST `/v1/agents/<id>` response shapes:

  `tests/fixtures/setup-agent-update-cas-success.json` (first-try success: v3 → v4):
  ```json
  {"id":"agent_M8_TEST","name":"bl-curator","version":4,"system":"updated prompt","tools":[],"skills":[]}
  ```

  `tests/fixtures/setup-agent-update-cas-conflict.json` (409 body — note: `bl_api_call` consumes the body and returns rc=71 without surfacing it; mock still emits the body for fidelity to the live API, even though our code path inspects rc only):
  ```json
  {"type":"error","error":{"type":"invalid_request_error","message":"Concurrent modification detected. Please fetch the latest version and retry."}}
  ```

  `tests/fixtures/setup-agent-update-cas-retry-success.json` (post-refetch retry: v5 → v6):
  ```json
  {"id":"agent_M8_TEST","name":"bl-curator","version":6,"system":"updated prompt","tools":[],"skills":[]}
  ```

  `tests/fixtures/setup-agent-fetch-v5.json` (GET `/v1/agents/<id>` response after 409, server returns drifted version 5):
  ```json
  {"id":"agent_M8_TEST","name":"bl-curator","version":5,"system":"prompt","tools":[],"skills":[]}
  ```

  Update existing tests in `tests/08-setup.bats` that referenced `setup-agent-update-success.json` to point at `setup-agent-update-cas-success.json` (the route pattern stays `/v1/agents/` — only the fixture filename changes).

- [ ] **Step 4: Add CAS happy-path and 409-retry tests**

  Append to `tests/08-setup.bats`:
  ```bats
  @test "bl setup --sync: existing agent → CAS update succeeds, version bumps" {
      local fake_repo
      fake_repo=$(mktemp -d)
      _make_fake_repo "$fake_repo"
      _state_json_seeded
      export BL_REPO_ROOT="$fake_repo"
      bl_curator_mock_add_route 'POST /v1/agents/[^/]*$' 'setup-agent-update-cas-success.json' 200
      run "$BL_SOURCE" setup --sync
      [ "$status" -eq 0 ]
      [[ "$output" == *"agent updated"* ]]
      # version bumped 3 → 4
      [ "$(jq -r '.agent.version' "$BL_STATE_DIR/state.json")" = "4" ]
  }

  @test "bl setup --sync: existing agent → 409 conflict triggers refetch + retry" {
      local fake_repo
      fake_repo=$(mktemp -d)
      _make_fake_repo "$fake_repo"
      _state_json_seeded
      export BL_REPO_ROOT="$fake_repo"
      # First POST returns 409; GET returns version 5 (drift); second POST succeeds at v5→v6
      bl_curator_mock_add_route_sequence 'POST /v1/agents/[^/]*$' \
          'setup-agent-update-cas-conflict.json:409' \
          'setup-agent-update-cas-retry-success.json:200'
      bl_curator_mock_add_route 'GET /v1/agents/[^/]*$' 'setup-agent-fetch-v5.json' 200
      run "$BL_SOURCE" setup --sync
      [ "$status" -eq 0 ]
      [[ "$output" == *"refetching version"* ]]
      [ "$(jq -r '.agent.version' "$BL_STATE_DIR/state.json")" = "6" ]
  }
  ```
  Note: the `bl_curator_mock_add_route_sequence` helper does not exist yet — add it to `tests/helpers/curator-mock.bash` as a sibling of `bl_curator_mock_add_route`. Permitted under **Tests-may-touch:** `tests/helpers/*.bash` (Rule 8).
  Add fixtures `setup-agent-update-cas-retry-success.json` (`{"id":"agent_M8_TEST","version":6,...}`) and `setup-agent-fetch-v5.json` (`{"id":"agent_M8_TEST","version":5,...}`) under `tests/fixtures/`.

- [ ] **Step 5: Regenerate bl + run targeted tests**

  ```bash
  make bl && make bl-check
  bats tests/08-setup.bats -f "CAS\|409\|update" 2>&1 | tail -15
  # expect: all CAS-related tests ok
  ```

- [ ] **Step 6: Update CHANGELOG**

  Add stanza:
  ```
  M15 P4 (2026-04-DD)
    [Fix] bl_setup_ensure_agent apply branch replaces PATCH /v1/agents/<id>
          (HTTP 404 against the live API) with POST /v1/agents/<id> body
          {version: <current>, ...} CAS. New helper bl_setup_update_agent_cas
          handles 409 conflicts via refetch + retry once. Update body includes
          system: $prompt — fixes silent prompt drift (F3, F9).
  ```

- [ ] **Step 7: Commit**

  ```bash
  git add src/bl.d/84-setup.sh tests/08-setup.bats tests/helpers/curator-mock.bash \
          tests/fixtures/setup-agent-update-cas-success.json \
          tests/fixtures/setup-agent-update-cas-conflict.json \
          tests/fixtures/setup-agent-update-cas-retry-success.json \
          tests/fixtures/setup-agent-fetch-v5.json bl CHANGELOG
  git commit -m "$(cat <<'EOF'
  [Fix] M15 P4 — agent update via CAS POST verb + 409 retry (F9)

  [Fix] src/bl.d/84-setup.sh — bl_setup_ensure_agent apply branch replaces
  PATCH /v1/agents/<id> (HTTP 404 against the live API) with the actual
  update verb POST /v1/agents/<id> body {version: <current>, ...}.
  Optimistic-CAS gating: server bumps version+1 on success, returns 409
  with "Concurrent modification detected" on stale version. New helper
  bl_setup_update_agent_cas issues the POST, refetches+retries on 409.
  [New] bl_setup_compose_agent_update_body — same body shape as
  bl_setup_compose_agent_body plus {version: <current>}.
  [New] CAS-related test fixtures + tests covering happy path and conflict
  retry. tests/helpers/curator-mock.bash gains
  bl_curator_mock_add_route_sequence for sequential-response routes.
  [Change] previous PATCH-target tests repointed to CAS fixtures.
  EOF
  )"
  ```

---

### Phase 5: F12 — sessions.create field rename `agent_id` → `agent`

Single-line correction in `bl_consult_create_session`. Add a regression test on the session-create body shape.

**Files:**
- Modify: `src/bl.d/50-consult.sh` (line 195) — rename field
- Modify: `tests/05-consult-run-case.bats` — add session-body field assertion
- Modify: `bl` — regenerated

- **Mode**: serial-context
- **Accept**:
  1. `grep -c '"agent_id":' src/bl.d/50-consult.sh` returns 0 (only inside session-create body — verify; some occurrences may be jq selectors on response shapes)
  2. `grep -c "'{agent: \$aid" src/bl.d/50-consult.sh` returns 1
  3. `bash -n src/bl.d/50-consult.sh` exit 0
- **Test**: `tests/05-consult-run-case.bats::@test "bl consult: session-create body uses 'agent' field name (F12 regression)"`
- **Edge cases**: response parsing untouched (the API response carries `agent_id` in some shapes — only the request body field changed); resources[] untouched
- **Regression-case**: `tests/05-consult-run-case.bats::@test "bl consult: session-create body uses 'agent' field name (F12 regression)"`

- [ ] **Step 1: Verify scope of the rename**

  ```bash
  grep -n 'agent_id' src/bl.d/50-consult.sh
  # expect: line 195 in session-create body, possibly other matches in response parsing.
  # ONLY the session-create REQUEST body shape changes; do not touch response-parsing
  # jq selectors (those mirror server response key names which still use agent_id).
  ```

- [ ] **Step 2: Edit `bl_consult_create_session` line 192-195**

  Old:
  ```bash
      jq -n \
          --arg aid "$agent_id" \
          --argjson rs "$resources_json" \
          '{agent_id: $aid, resources: $rs}' > "$body_file"
  ```

  New:
  ```bash
      # F12 fix — live API rejects agent_id with "Did you mean 'agent'?".
      # Field name in sessions.create body is 'agent', not 'agent_id'. The
      # response shape is unrelated and may still carry agent_id.
      jq -n \
          --arg aid "$agent_id" \
          --argjson rs "$resources_json" \
          '{agent: $aid, resources: $rs}' > "$body_file"
  ```

- [ ] **Step 3: Add regression test in `tests/05-consult-run-case.bats`**

  Append (or insert near existing session-create coverage):
  ```bats
  @test "bl consult: session-create body uses 'agent' field name (F12 regression)" {
      _state_json_seeded
      jq '.agent.id = "agent_M8_TEST"' "$BL_STATE_DIR/state.json" > "$BL_STATE_DIR/state.json.tmp"
      mv "$BL_STATE_DIR/state.json.tmp" "$BL_STATE_DIR/state.json"
      bl_curator_mock_add_route 'POST /v1/sessions$' 'sessions-create.json' 200
      export BL_MOCK_REQUEST_LOG="$(mktemp)"
      run "$BL_SOURCE" consult --case CASE-2026-0001 --attach
      # Inspect the captured request body
      grep -E '"agent":"agent_M8_TEST"' "$BL_MOCK_REQUEST_LOG"
      [ "$?" -eq 0 ]
      # Anti-assertion — the wrong shape must not appear
      ! grep -E '"agent_id":"agent_M8_TEST"' "$BL_MOCK_REQUEST_LOG"
  }
  ```

  If `tests/fixtures/sessions-create.json` does not exist yet, create it under **Tests-may-touch:** `tests/fixtures/*.json`:
  ```json
  {"id":"session_M8_TEST","agent":{"id":"agent_M8_TEST"},"resources":[]}
  ```

- [ ] **Step 4: Regenerate bl + run targeted test**

  ```bash
  make bl && make bl-check
  bats tests/05-consult-run-case.bats -f "F12 regression" 2>&1 | tail -5
  # expect: 1 ok line
  ```

- [ ] **Step 5: Update CHANGELOG**

  Add stanza:
  ```
  M15 P5 (2026-04-DD)
    [Fix] bl_consult_create_session sessions.create body field renamed
          agent_id → agent (the live API rejects agent_id with "Did you mean
          'agent'?"). Was a silent fail on every consult (F12).
  ```

- [ ] **Step 6: Commit**

  ```bash
  git add src/bl.d/50-consult.sh tests/05-consult-run-case.bats tests/fixtures/sessions-create.json bl CHANGELOG
  git commit -m "$(cat <<'EOF'
  [Fix] M15 P5 — sessions.create body field 'agent_id' → 'agent' (F12)

  [Fix] src/bl.d/50-consult.sh — bl_consult_create_session jq body
  template renames {agent_id: $aid} to {agent: $aid}. Live API rejects
  the wrong field name with "agent_id: Extra inputs are not permitted.
  Did you mean 'agent'?"; this was a silent fail on every consult.
  [New] tests/05-consult-run-case.bats — regression test asserting the
  request-body field name via BL_MOCK_REQUEST_LOG capture.
  EOF
  )"
  ```

**Tests-may-touch:** `tests/fixtures/*.json`

---

### Phase 6: Skills primitive resolution — Path A or Path B

> **DECISION REQUIRED before dispatch:** replace the `<DECISION-PENDING>` token below with `Path A` (workspace allowlist arrived; keep architecture, delete dead `bl_skills_list`) or `Path B` (retire Skills CRUD; corpora-as-Files only). Dispatcher refuses to run P6 if the token is unmodified.

**Operator decision:** `<DECISION-PENDING>`

The two execution paths share a Files: declaration but diverge in the Steps below. Engineer reads the operator's recorded decision and executes the matching subsection.

**Files (both paths):**
- Modify: `src/bl.d/84-setup.sh` — `bl_setup_compose_agent_body` (lines 695-744; Path B prunes skills + skill_versions)
- Modify: `src/bl.d/24-skills.sh` — Path A: delete dead `bl_skills_list`; Path B: delete entire file (or shrink to a comment-only stub explaining retirement)
- Modify: `src/bl.d/84-setup.sh` — Path B: delete `bl_setup_seed_skills` (lines 294-361) and its callers (line 402, line 858)
- Modify: `prompts/curator-agent.md` — Path B only: §3.1 Primitives map wording
- Modify: `tests/08-setup.bats` — Path-dependent test deletions / additions
- Modify: `bl` — regenerated

- **Mode**: serial-agent
- **Accept**: Engineer applies the path-specific subset matching the operator's recorded decision. **Path A**: (1) `grep -c 'bl_skills_list' src/bl.d/24-skills.sh src/bl.d/84-setup.sh` returns 0; (2) `bl_setup_compose_agent_body` retains `skill_versions: $sv` and `agent.skills[]` plumbing; (3) `bash -n src/bl.d/{24-skills,84-setup}.sh` exit 0. **Path B**: (1) `grep -c 'bl_skills_create\|bl_skills_versions_create\|bl_skills_get\|bl_skills_delete\|bl_skills_list' src/bl.d/` (across all parts) returns 0; (2) `grep -c 'skill_versions\|agent.skills\[\]' src/bl.d/84-setup.sh` returns 0; (3) `grep -c 'workspace corpora; full-context per turn' prompts/curator-agent.md` returns 1; (4) `bash -n src/bl.d/{24-skills,84-setup}.sh` exit 0 (or 24-skills.sh deleted); (5) `make bl && make bl-check` passes.
- **Test**: `tests/08-setup.bats::@test "bl setup P6 — agent body shape matches recorded path"` — single test, body asserts either the Path-A invariants (`skill_versions` present, `skills[]` plumbing intact) or the Path-B invariants (`skill_versions` absent or empty, `skills` field absent or `[]`) per the recorded decision. Engineer writes the body that matches the chosen path.
- **Edge cases**: state.json with non-empty `agent.skill_versions` from prior runs (Path B sets to `{}`); routing-skills/ directory (kept on disk under Path B as inert documentation)
- **Regression-case**: `tests/08-setup.bats::@test "bl setup P6 — agent body shape matches recorded path"` — single test, written by the engineer using the Path-A or Path-B body-shape assertions per the recorded decision. The test name is stable across paths (only its body differs), so the regression-case reference is path-independent.

#### Path A steps (only if decision = Path A)

- [ ] **A.Step 1: Delete `bl_skills_list` from `src/bl.d/24-skills.sh`**

  Remove lines 84-88 (the `bl_skills_list` function definition + its leading comment).

- [ ] **A.Step 2: Verify no callers**

  ```bash
  grep -rn 'bl_skills_list' src/bl.d/ tests/
  # expect: no hits in src/bl.d/; tests may reference but only as mocks — verify they still compile
  ```

- [ ] **A.Step 3: Add Path A regression test under the unified test name**

  ```bats
  @test "bl setup P6 — agent body shape matches recorded path" {
      # Path A invariants — skill_versions present + skills[] is array
      local fake_repo body
      fake_repo=$(mktemp -d)
      _make_fake_repo "$fake_repo"
      export BL_REPO_ROOT="$fake_repo"
      body=$(bl_setup_compose_agent_body)
      printf '%s' "$body" | jq -e '.skill_versions'
      [ "$?" -eq 0 ]
      printf '%s' "$body" | jq -e '.skills | type == "array"'
      [ "$?" -eq 0 ]
  }
  ```

#### Path B steps (only if decision = Path B)

- [ ] **B.Step 1: Delete `bl_setup_seed_skills` from `src/bl.d/84-setup.sh`**

  Remove lines 294-361 (`bl_setup_seed_skills` function block).

- [ ] **B.Step 2: Delete callers in `bl_setup_dry_run` and `bl_setup_sync`**

  Remove the `bl_setup_seed_skills dry-run` line (currently line 402) and `bl_setup_seed_skills apply; _rc=$?` block (currently lines 857-858 + the rc-check that follows).

- [ ] **B.Step 3: Delete `src/bl.d/24-skills.sh` entirely**

  ```bash
  git rm src/bl.d/24-skills.sh
  ```
  Update `scripts/assemble-bl.sh` if it explicitly enumerates `24-skills.sh` (it concatenates by glob, so likely no change needed — verify).

- [ ] **B.Step 4: Strip `skill_versions` and `skills` from `bl_setup_compose_agent_body`**

  Old (lines 711-743 — the jq emit):
  ```bash
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
                  ...
  ```

  New:
  ```bash
      jq -n \
          --rawfile prompt "$prompt_file" \
          --slurpfile stepRaw "$step_schema" \
          --slurpfile defRaw  "$def_schema" \
          --slurpfile intRaw  "$int_schema" \
          '{
              name: "bl-curator",
              model: "claude-opus-4-7",
              system: $prompt,
              tools: [
                  {type: "agent_toolset_20260401"},
                  ...
  ```

  Also delete the `local sv_json='{}'` and `[[ -f "$state_file" ]] && sv_json=...` block (lines 708-710).

- [ ] **B.Step 5: Update curator system prompt §3.1 Primitives map**

  In `prompts/curator-agent.md`, replace the "Skills | Routing expertise bundles | Harness-managed; the Anthropic platform activates ..." row text with: "Skills | Workspace corpora; full-context per turn | Mounted at session creation as workspace Files; the curator reads `/skills/<name>-corpus.md` directly when evidence shape matches | Read by path. Foundations + 6 routing-skill corpora at `/skills/<name>-corpus.md`. The 6 names are: ...". Keep the §3.2 read-first ordering unchanged — those references already point at `/skills/foundations.md` and `/skills/<skill-name>-corpus.md`, which is the Files-attached path.

- [ ] **B.Step 6: Add Path B regression test under the unified test name**

  ```bats
  @test "bl setup P6 — agent body shape matches recorded path" {
      # Path B invariants — skill_versions absent + skills field absent or empty
      local fake_repo body
      fake_repo=$(mktemp -d)
      _make_fake_repo "$fake_repo"
      export BL_REPO_ROOT="$fake_repo"
      body=$(bl_setup_compose_agent_body)
      # Skills field is either absent or [] under Path B
      local skills_present
      skills_present=$(printf '%s' "$body" | jq 'has("skills")')
      [[ "$skills_present" == "false" ]] || [[ "$(printf '%s' "$body" | jq '.skills | length')" == "0" ]]
      # skill_versions field is absent
      [ "$(printf '%s' "$body" | jq 'has("skill_versions")')" = "false" ]
  }
  ```

- [ ] **A/B Step 7: Regenerate bl + targeted tests**

  ```bash
  make bl && make bl-check
  bats tests/08-setup.bats -f "P6 — agent body shape" 2>&1 | tail -5
  # expect: 1 ok line (the unified test for the recorded path)
  ```

- [ ] **A/B Step 8: Update CHANGELOG (path-specific stanza)**

  Path A:
  ```
  M15 P6 Path A (2026-04-DD)
    [Change] Delete dead bl_skills_list helper; M13 Path C architecture preserved
             (workspace allowlist for Skills CRUD arrived in M15 window).
  ```

  Path B:
  ```
  M15 P6 Path B (2026-04-DD)
    [Change] Retire Skills CRUD primitive; routing-Skill bodies ship as workspace
             Files only. Curator §3.1 Primitives map updated. bl_skills_* helpers
             removed; bl_setup_compose_agent_body strips skill_versions and skills
             fields. F8/F10/F11 resolved by deletion of unsupported code path.
  ```

- [ ] **A/B Step 9: Commit**

  Path A:
  ```bash
  git add src/bl.d/24-skills.sh tests/08-setup.bats bl CHANGELOG
  git commit -m "[Change] M15 P6 — Path A: delete dead bl_skills_list (workspace allowlist arrived)"
  ```

  Path B:
  ```bash
  git add src/bl.d/84-setup.sh prompts/curator-agent.md tests/08-setup.bats bl CHANGELOG
  git rm src/bl.d/24-skills.sh
  git commit -m "$(cat <<'EOF'
  [Change] M15 P6 — Path B: retire Skills CRUD primitive; corpora-as-Files only

  [Change] src/bl.d/84-setup.sh — delete bl_setup_seed_skills + its
  callers in bl_setup_dry_run / bl_setup_sync. Strip skill_versions and
  skills from bl_setup_compose_agent_body. The 6 routing-Skill bodies
  are still uploaded as workspace Files in P2 (corpus seed); they reach
  the curator via session.resources[file_id], not agent.skills[].
  [Change] prompts/curator-agent.md — §3.1 Primitives map updated:
  Skills row reframed from "harness-managed; lazy-load" to
  "workspace corpora; full-context per turn".
  [Change] src/bl.d/24-skills.sh — entire file retired (Skills CRUD
  endpoints not exposed to this workspace under managed-agents-2026-04-01).
  EOF
  )"
  ```

---

### Phase 7: Doc drift sweep (path-dependent)

Bring `docs/managed-agents.md`, `docs/setup-flow.md`, and `DESIGN.md` §12 into alignment with the live API surface mapped at `/tmp/bl-m13-exercise/API-SURFACE.md`. Path-dependent edits per Decision table; common edits ship under both paths.

**Files:**
- Modify: `docs/managed-agents.md` (§3 line 19 Skills row; §3 agent verb table; §4 lines 71-77 Skills CRUD; §4 lines 82-83 Skills attachment; §5 sessions field; §11 Path C Primitives map)
- Modify: `docs/setup-flow.md` (§4.4a Skills upload — annotate path choice; §5 sessions field)
- Modify: `DESIGN.md` §12 — add divergence note pointing at `/tmp/bl-m13-exercise/API-SURFACE.md`

- **Mode**: serial-context
- **Accept**:
  1. `grep -c 'POST /v1/agents/<id>$' docs/managed-agents.md` returns ≥ 1 (CAS update verb documented)
  2. `grep -c 'POST /v1/agents/<id>/archive' docs/managed-agents.md` returns ≥ 1 (archive verb documented)
  3. `grep -c '"type":"skill"' docs/managed-agents.md` returns 0 (the wrong session-resources shape removed)
  4. `grep -c 'agent: <id>' docs/managed-agents.md docs/setup-flow.md` returns ≥ 2 (sessions field corrected in both files)
  5. Path A: `grep -c 'workspace allowlist' docs/managed-agents.md` returns ≥ 1
  6. Path B: `grep -c 'Skills primitive retired' docs/managed-agents.md` returns ≥ 1
- **Test**: `grep` commands above (no BATS coverage for docs)
- **Edge cases**: same docs may also be touched by M14 P10/P11 if M14 also corrected divergence; engineer rebases on post-M14 main and merges any overlapping diffs preserving M14's edits where they don't contradict M15 findings
- **Regression-case**: N/A — docs — Path-dependent doc drift is the deliverable; no regression test applies because the changes are documentation-only

- [ ] **Step 1: Patch `docs/managed-agents.md` agent verb table**

  In §3 (Resource matrix table around line 19), update the row for **Agent** to enumerate the four verbs as probed live: `POST /v1/agents` (create), `POST /v1/agents/<id>` `{version, ...}` (CAS update), `POST /v1/agents/<id>/archive` (retire), `GET /v1/agents/<id>/versions` (history). Remove any reference to `PATCH /v1/agents/<id>` and `DELETE /v1/agents/<id>` as supported verbs.

- [ ] **Step 2: Patch `docs/managed-agents.md` Skills section**

  Path A: keep the §4 Skills section largely intact; add a callout under "Create" noting that the endpoint is registered (OPTIONS shows `Allow: POST`) but feature-gated per workspace; cite the 2026-04-26 probe as evidence of allowlist-required state. Update line 82-83 attachment claim — Skills attach via `agent.skills[]` (existing skill_id refs), NOT `session.resources[].type=skill`.

  Path B: replace the §4 Skills section with a short paragraph explaining Skills primitive retirement; cite that the 6 routing Skill bodies ship as workspace Files at `/skills/<name>-corpus.md` and reach the curator via session.resources[file_id]. Update §11 Path C Primitives map to match the new shape.

- [ ] **Step 3: Patch sessions field name in both docs**

  In `docs/managed-agents.md` §5 and `docs/setup-flow.md` §5 (or wherever `agent_id` appears in sessions.create body specifications), replace `agent_id` with `agent`. Add an inline citation to the live-probe rejection message ("Did you mean 'agent'?").

  Also patch the `resources[].type` enumeration in §5 (line 100-101): the live enum is `file | github_repository | memory_store`. Remove `skill` and `environment` entries (the latter was speculative and not probed accepted).

- [ ] **Step 4: Add `DESIGN.md` §12 divergence note**

  Insert a new sub-section after §12 closing paragraph: "Live API divergence — see `/tmp/bl-m13-exercise/API-SURFACE.md` for the canonical map. Three M15-fixed gaps: (1) PATCH agent → POST CAS verb (F9); (2) DELETE agent → POST archive (F6); (3) sessions field `agent_id` → `agent` (F12). Skills primitive resolution: <Path A: workspace-allowlist-pending | Path B: retired in favor of Files-as-corpora>."

- [ ] **Step 5: Verify no introduction of broken anchors**

  ```bash
  grep -n '^##' docs/managed-agents.md docs/setup-flow.md DESIGN.md
  # expect: section numbering still increments monotonically; no orphan anchors
  ```

- [ ] **Step 6: Update CHANGELOG**

  Add stanza:
  ```
  M15 P7 (2026-04-DD)
    [Change] Doc drift sweep: docs/managed-agents.md agent verb table now matches
             live API (POST <id> CAS update, POST archive); sessions field name
             corrected agent_id → agent; resources[].type enum corrected; Skills
             section reflects recorded path choice. docs/setup-flow.md and
             DESIGN.md §12 aligned to API-SURFACE.md.
  ```

- [ ] **Step 7: Commit**

  ```bash
  git add docs/managed-agents.md docs/setup-flow.md DESIGN.md CHANGELOG
  git commit -m "$(cat <<'EOF'
  [Change] M15 P7 — doc drift sweep against live API surface

  [Change] docs/managed-agents.md — agent verb table enumerates the
  four verbs as probed: POST create, POST <id> CAS update, POST archive,
  GET versions. Skills section <Path A: allowlist-callout | Path B: retired>.
  Sessions field name agent_id → agent. resources[].type enum corrected
  to file | github_repository | memory_store.
  [Change] docs/setup-flow.md — §4.4a annotated for path choice; §5
  sessions field corrected.
  [Change] DESIGN.md §12 — divergence note added; cites
  API-SURFACE.md for the canonical map.
  EOF
  )"
  ```

---

### Phase 8: Live integration smoke + .secrets/env cleanup runbook

Add `tests/live/setup-live.bats` (gated on `BL_LIVE=1`) that exercises the full setup → check → consult-create-session path against a real Anthropic workspace. Document the operator-side `.secrets/env` cleanup procedure in `docs/setup-flow.md` §11 (new section) — F4 is operator hygiene, not source.

**Files:**
- Create: `tests/live/setup-live.bats` (~120 lines)
- Modify: `docs/setup-flow.md` — new §11 ".secrets/env operator hygiene" section
- Modify: `tests/Makefile` — add `test-live` target (mirrors `test-skill-routing-eval` gating pattern)

- **Mode**: serial-agent
- **Accept**:
  1. Default CI run (without `BL_LIVE=1`) shows every test in `tests/live/setup-live.bats` skipping cleanly with `BL_LIVE=1 required (live API)` message
  2. With `BL_LIVE=1` + valid `ANTHROPIC_API_KEY`, the smoke test passes end-to-end on a fresh workspace: agent created, env created, memstore created, 8 corpora uploaded, state.json populated, `bl setup --check` exits 0
  3. `tests/Makefile` has a `test-live` target; `make -C tests test-live` shows skip messages by default
  4. `docs/setup-flow.md` §11 documents the orphan `BL_SKILL_ID_*` removal procedure
- **Test**: self (the live test IS the test); `make -C tests test-live` is the entry point
- **Edge cases**: ANTHROPIC_API_KEY missing under BL_LIVE=1 (test fails fast with a clear "set ANTHROPIC_API_KEY" message); workspace already provisioned (`bl setup --check` succeeds without re-provisioning); rate-limit hit (test surfaces the 429 + retry-after window)
- **Regression-case**: N/A — refactor — Pure test-addition phase + docs section; no production source change. Per Plan-Schema Rule 6, test-only phases use category `refactor`.

- [ ] **Step 1: Create `tests/live/setup-live.bats`**

  ```bats
  #!/usr/bin/env bats
  # tests/live/setup-live.bats — M15 P8: live integration smoke
  #
  # Exercises bl setup → check → consult-create-session against the real
  # Anthropic Managed Agents API. Mirrors the gating pattern from
  # tests/skill-routing/eval-runner.bats (BL_LIVE=1 + ANTHROPIC_API_KEY).
  #
  # GATING: BL_LIVE=1 required to exercise live paths.
  # Default CI behaviour (BL_LIVE unset): every test skips cleanly → exit 0.

  LIVE_SKIP_MSG="BL_LIVE=1 required (live API)"

  _live_skip_unless_live() {
      [[ -n "${BL_LIVE:-}" ]] || skip "$LIVE_SKIP_MSG"
      [[ -n "${ANTHROPIC_API_KEY:-}" ]] || { echo "ANTHROPIC_API_KEY required when BL_LIVE=1"; return 1; }
  }

  # Shared workspace dir across all tests in the file — tests 2-4 depend on
  # state.json provisioned by test 1. setup_file() runs once before any test;
  # setup() re-running mktemp -d per test would isolate state and trip the
  # `[ -f state.json ] || skip` guards in tests 2-4.
  setup_file() {
      export BL_VAR_DIR_LIVE="$(mktemp -d)"
  }

  teardown_file() {
      [[ -d "${BL_VAR_DIR_LIVE:-}" ]] && rm -rf "$BL_VAR_DIR_LIVE"
  }

  setup() {
      BL_SOURCE="${BL_SOURCE:-$BATS_TEST_DIRNAME/../../bl}"
      export BL_VAR_DIR="$BL_VAR_DIR_LIVE"
      export BL_STATE_DIR="$BL_VAR_DIR/state"
      export BL_REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  }

  @test "bl setup --sync: provisions agent + env + memstore + 8 corpora against live API" {
      _live_skip_unless_live
      run "$BL_SOURCE" setup --sync
      [ "$status" -eq 0 ]
      [[ "$output" == *"agent created"* ]] || [[ "$output" == *"agent updated"* ]]
      [ -f "$BL_STATE_DIR/state.json" ]
      [ -n "$(jq -r '.agent.id // empty' "$BL_STATE_DIR/state.json")" ]
      [ -n "$(jq -r '.env_id // empty' "$BL_STATE_DIR/state.json")" ]
      [ "$(jq -r '.files | length' "$BL_STATE_DIR/state.json")" -eq 8 ]
      [ -n "$(jq -r '.case_memstores._default // empty' "$BL_STATE_DIR/state.json")" ]
  }

  @test "bl setup --check: post-sync reports all resources present" {
      _live_skip_unless_live
      # state.json provisioned by the previous test in this file (shared
      # BL_VAR_DIR via setup_file). If absent, the previous test failed.
      [ -f "$BL_STATE_DIR/state.json" ] || skip "previous test (--sync) did not provision; cannot --check"
      run "$BL_SOURCE" setup --check
      [ "$status" -eq 0 ]
      [[ "$output" == *"agent: ok"* ]]
      [[ "$output" == *"env: ok"* ]]
      [[ "$output" == *"files: 8 workspace files"* ]]
  }

  @test "bl consult --new (smoke): creates session with corpora attached" {
      _live_skip_unless_live
      [ -f "$BL_STATE_DIR/state.json" ] || skip "prior test did not provision"
      # Open a fresh case; --attach creates the session bound to the agent
      run "$BL_SOURCE" consult --new --trigger "M15-P8-smoke" --attach
      [ "$status" -eq 0 ]
      local case_id session_id
      case_id=$(jq -r '.case_current // empty' "$BL_STATE_DIR/state.json")
      session_id=$(jq -r --arg c "$case_id" '.session_ids[$c] // empty' "$BL_STATE_DIR/state.json")
      [ -n "$case_id" ]
      [ -n "$session_id" ]
  }

  @test "bl setup --reset --force: archive verb retires the agent live" {
      _live_skip_unless_live
      [ -f "$BL_STATE_DIR/state.json" ] || skip "prior test did not provision"
      local agent_id
      agent_id=$(jq -r '.agent.id // empty' "$BL_STATE_DIR/state.json")
      run "$BL_SOURCE" setup --reset --force
      [ "$status" -eq 0 ]
      [[ "$output" == *"archived agent $agent_id"* ]]
      [ "$(jq -r '.agent.id' "$BL_STATE_DIR/state.json")" = "" ]
  }
  ```

- [ ] **Step 2: Add `tests/Makefile` target `test-live`**

  Insert after the existing `test-skill-routing-eval` target:
  ```makefile
  .PHONY: test-live
  test-live:
  	@echo "M15 P8: BL_LIVE=$${BL_LIVE:-unset} (set BL_LIVE=1 + ANTHROPIC_API_KEY to exercise live API)"
  	BL_LIVE=$${BL_LIVE:-} ANTHROPIC_API_KEY=$${ANTHROPIC_API_KEY:-} \
  	    bats tests/live/setup-live.bats
  ```

- [ ] **Step 3: Add `docs/setup-flow.md` §11 operator hygiene section**

  Append a new section:
  ```markdown
  ## 11. `.secrets/env` operator hygiene (M15 F4)

  Pre-M15 operator workspaces accumulated three orphan environment exports
  from the M0 era:

  ```
  export BL_SKILL_ID_CASE_LIFECYCLE=...
  export BL_SKILL_ID_POLYSHELL=...
  export BL_SKILL_ID_MODSEC_PATTERNS=...
  ```

  These IDs map to no source-side Skill (M13 retired the names; routing-skills/
  uses entirely different identifiers) and 404 individually on the platform.

  After running `bl setup --sync` against a fresh workspace, remove the three
  lines from `.secrets/env`. Keep `BL_CURATOR_AGENT_ID`, `BL_CURATOR_ENV_ID`,
  and `BL_CURATOR_AGENT_VERSION` — refresh them from the new `state.json`:

  ```bash
  jq -r '.agent | "export BL_CURATOR_AGENT_ID=\"" + .id + "\""' \
      /var/lib/bl/state/state.json
  jq -r '"export BL_CURATOR_AGENT_VERSION=\"" + (.agent.version | tostring) + "\""' \
      /var/lib/bl/state/state.json
  jq -r '"export BL_CURATOR_ENV_ID=\"" + .env_id + "\""' \
      /var/lib/bl/state/state.json
  ```

  `.secrets/env.example` carries the canonical template.
  ```

- [ ] **Step 4: Run default-mode (BL_LIVE unset) verification**

  ```bash
  make -C tests test-live 2>&1 | tee /tmp/test-m15-p8-default.log | tail -20
  grep -c 'BL_LIVE=1 required' /tmp/test-m15-p8-default.log
  # expect: ≥ 4 (one per skip-gated test)
  grep -c 'not ok' /tmp/test-m15-p8-default.log
  # expect: 0
  ```

- [ ] **Step 5: Run live-mode verification (operator-only; not in CI)**

  Operator runs (with valid API key sourced):
  ```bash
  set -a; . .secrets/env; set +a
  BL_LIVE=1 make -C tests test-live 2>&1 | tee /tmp/test-m15-p8-live.log | tail -30
  grep -c 'ok ' /tmp/test-m15-p8-live.log
  # expect: 4 (all four live tests pass)
  ```

  After live tests pass, operator manually edits `.secrets/env` per Step 3's runbook to remove orphan `BL_SKILL_ID_*` lines and refresh `BL_CURATOR_AGENT_*` from state.json. This is operator-side hygiene; not part of the commit.

- [ ] **Step 6: Update CHANGELOG**

  Add stanza:
  ```
  M15 P8 (2026-04-DD)
    [New] tests/live/setup-live.bats — BL_LIVE=1 gated full-stack smoke test
          covering setup --sync → --check → consult --new --attach → --reset
          against the real Anthropic Managed Agents API. Default CI skips cleanly.
    [New] docs/setup-flow.md §11 — operator runbook for orphan BL_SKILL_ID_*
          cleanup in .secrets/env (F4).
  ```

- [ ] **Step 7: Commit**

  ```bash
  git add tests/live/setup-live.bats tests/Makefile docs/setup-flow.md CHANGELOG
  git commit -m "$(cat <<'EOF'
  [New] M15 P8 — live integration smoke + operator-hygiene runbook

  [New] tests/live/setup-live.bats — BL_LIVE=1 gated full-stack smoke:
  setup --sync → setup --check → consult --new --attach → setup --reset
  --force against the real Anthropic Managed Agents API. Mirrors the
  gating pattern from tests/skill-routing/eval-runner.bats. Default CI
  behaviour skips every test cleanly.
  [New] tests/Makefile target test-live.
  [New] docs/setup-flow.md §11 — operator-side .secrets/env cleanup
  procedure for orphan BL_SKILL_ID_* lines (F4).
  EOF
  )"
  ```

---

## Post-merge sweep (controller responsibility)

After all 8 phases land in main, controller runs:

```bash
git status --porcelain
# expect: empty (no uncommitted drift)
git status --porcelain --ignored
# expect: empty or only .git/info/exclude-listed working files
git log --oneline main^8..main
# expect: 8 commits, one per phase, all tagged "M15 P<N> —"
make bl-check
# expect: pass
make -C tests test-quick 2>&1 | tail -10
# expect: clean
```

If any drift surfaces in main (stray edits to `PLAN-M14.md`, `MEMORY.md`, etc., per the parallel-worktree leak patterns documented in CLAUDE.md), discard via `git checkout -- <file>` before any tag/release operation.
