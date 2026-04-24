# M5 — `bl consult` + `bl run` + `bl case` design spec

**Spec date:** 2026-04-24
**Motion:** M5 (PLAN.md lines 180–190)
**Wave:** 2 (worktree, post-M1+M2; parallel-safe with M4, M6, M7, M8 per PLAN.md file-ownership contract line 51)
**Author:** primary engineer (operator-absent autonomous progression per CLAUDE.md §Execution posture)
**Downstream plan:** `PLAN-M5.md` (named, uncommitted per `.git/info/exclude` `PLAN-*.md`)
**Companion anchors:** `DESIGN.md §5.2` (consult), `§5.3` (run), `§5.6` (case), `§6` (tiers), `§7.2` (memstore), `§12` (Managed Agents API), `§13.4` (ledger dual-write); `docs/action-tiers.md`, `docs/case-layout.md`, `docs/exit-codes.md`, `case-templates/README.md`, `prompts/curator-agent.md`, `schemas/step.json`; `docs/specs/2026-04-24-M{0,1,2}-*.md`.

---

## 0. Gate-blocking open calls (resolved + downstream binding)

PLAN.md §"Open calls" leaves two resolutions pinned at M0 (`docs/specs/2026-04-24-M0-contracts-lockdown.md §0`). M5 inherits both and extends them with motion-specific bindings. Neither is re-opened here.

### 0.1 Fence-token scope — per-payload (inherited from M0 §0.1; not M5-binding)

- **M0 resolution** (commit `4ec1c23`): fence-token derivation is `sha256(case-id || obs-id || payload)[:16]`, recomputed per envelope (`schemas/evidence-envelope.md §4`).
- **M5 binding:** M5 does NOT generate or verify fence tokens in its core path. Fence tokens wrap evidence records (`schemas/evidence-envelope.md §4`) emitted by `bl observe` (M4) and consumed by the curator's reasoning (M3 prompt). M5's `bl run` executes steps (`schemas/step.json` envelopes); step envelopes do NOT carry fences — the fence wraps the raw evidence, not the agent's step emission. Where M5 touches fences: if a `results/s-<id>.json` writeback includes an evidence excerpt as a field (e.g., captured stdout of an `observe.*` dispatch), the excerpt is verbatim from M4's fenced emit — M5 pass-throughs without re-fencing. Implication: M5 has zero fence-write and zero fence-verify surface in its critical path. Any fence-related hardening (strict verify on evidence ingest, corpus validation) lands in M9 per `DESIGN.md §13.2` + the M9 hardening spec. This is a clean separation — M5 does not block on fence infrastructure.
- **Downstream lock:** any change to `sha256(case || obs || payload)` derivation invalidates M5's verifier; M9 hardening work coordinates via `DESIGN.md §13.2` + `schemas/evidence-envelope.md §4` update in one commit.

### 0.2 `bl` layout — single-file (inherited from M0 §0.2)

- **M0 resolution:** `bl` ships as one file at repo root with disjoint function prefixes per motion.
- **M5 binding:** M5 adds three disjoint function prefixes — `bl_consult_*`, `bl_run_*`, `bl_case_*` — into the M1-seeded single-file `bl`. No new source files land at repo root. Dispatcher case-statement rows for `consult`, `run`, `case` already exist from M1 (`PLAN-M1.md` phase 10 lands them as stubs returning 64); M5 replaces the stub bodies with real handlers, does NOT move the case-statement lines, and does NOT reorder the top-of-file helpers. This preserves the M1 seeded shape and prevents merge conflicts with parallel M4/M6/M7/M8 worktrees (each owns a different stub body).
- **Downstream lock:** if M5 discovers a missing shared helper at build time (e.g., a `bl_jq_schema_check` needed by both M5 and M4/M6), the helper lands in the "common helpers" block M1 established at the top of `bl`, not inside an M5-prefix function. Reviewer flags cross-prefix leakage as MUST-FIX.

Both calls locked. M5 build may dispatch.

---

## 1. Problem statement

blacklight v2 has a dispatcher skeleton (`bl`, M1), case-open templates (`case-templates/`, M2), and a frozen wire-format contract (`schemas/step.json`, M0). What it does NOT have:

- **Case lifecycle management.** `bl consult --new` cannot allocate a case-id; `bl consult --attach` cannot flip the current-case pointer; `bl case show` cannot render case state; `bl case close` cannot render a brief.
- **Step execution.** The curator's `report_step` emits land in `bl-case/<case>/pending/s-<id>.json` (via the Managed Agents custom-tool surface — `DESIGN.md §12.1.1`), but no wrapper verb fetches, validates, tier-gates, prompts, executes, or writes-back. `bl_run` is the empty-stub from M1.
- **Case I/O.** `bl case log` cannot emit the append-log; `bl case list` cannot enumerate roster entries; `bl case reopen` cannot flip a `closed.md` back to active.

Every downstream demo narrative (`PLAN.md` end-state target line 10 — "curator polls pending-steps, operator confirms, wrapper executes, results write back") assumes these handlers. Without M5, the demo fixture shows a curator that emits steps into a void — the wrapper has no path to execute them. M4 (`bl observe`) produces evidence but has no case to attach it to. M6 (`bl defend`) and M7 (`bl clean`) both depend on `bl_run_step`'s tier-gate + diff/explain/abort UX to apply their proposals safely.

M5 is a Wave-2 gate. M4/M6/M7/M8 worktrees can land their namespace handlers independently, but the case-lifecycle + tier-gated step-execution substrate those handlers plug INTO is M5's deliverable.

Current state, measured:

| Surface | Status | Evidence |
|---|---|---|
| `bl_consult` handler stub | present (M1) | `bl_consult` returns 64 with "consult not yet implemented (M5)" per M1 spec §5.1 |
| `bl_run` handler stub | present (M1) | same pattern |
| `bl_case` handler stub | present (M1) | same pattern |
| `/var/lib/bl/state/case.current` | declared-but-not-created (M1 §7.3) | `bl_case_current` reads it; nothing writes it yet |
| `case-templates/` | landed (M2) | 10 files; manifest at `case-templates/README.md` §1 (8 on-open seeds) |
| `schemas/step.json` | landed (M0) | 66 lines; enum frozen; jq-validatable |
| `docs/action-tiers.md §5` gate behavior | landed (M0) | 5 tiers × per-tier contract |
| `docs/case-layout.md §3` writer-owner | landed (M0) | 18 paths × `{writer, when, cap, lifecycle}` |
| `docs/exit-codes.md` 67/68/71/72 | landed (M0) | M5 is primary emitter of 67, 68, 71, 72 per `docs/exit-codes.md §1` |
| `tests/helpers/curator-mock.bash` | **missing** | `tests/helpers/` has only `bl-preflight-mock.bash` (M1); M0 spec declared the full curator-mock but deferred authorship to M5 per M1 NG3 |
| `tests/fixtures/` directory | **missing** | M0 spec `tests/fixtures/step-*.json` deferred to the consuming motion (M5) |
| `tests/05-consult-run-case.bats` | **missing** | M5 authors |

---

## 2. Goals

Numbered, measurable. Each goal maps to ≥1 verification command in §10b and ≥1 `@test` in §10a.

| # | Goal | Verification |
|---|------|--------------|
| G1 | `bl_consult_new --trigger <artifact>` allocates a fresh case-id in `CASE-YYYY-NNNN` format, materializes the 8-file on-open template set from `case-templates/README.md §1` into `bl-case/CASE-<YYYY>-<NNNN>/`, seeds `STEP_COUNTER=0`, appends the `INDEX.md` roster row, writes `/var/lib/bl/state/case.current`, and POSTs a session wake event via `bl_api_call`. | `bl consult --new --trigger <path>` exits 0; subsequent `bl case show` prints the expected skeleton. |
| G2 | `bl_consult_attach --attach <case-id>` verifies the case directory exists (memstore probe via `bl_api_call`), flips `/var/lib/bl/state/case.current`, exits 0 on hit or 72 (`NOT_FOUND`) on miss. | `@test` hits both paths. |
| G3 | `bl_consult_sweep_mode --sweep-mode --cve <id>` runs an inventory sweep — enumerates all `CASE-*/closed.md` entries in the workspace, prints a retrospective posture readout, does NOT open a formal case, exits 0. | `@test` asserts output shape + no new `INDEX.md` row. |
| G4 | `bl_run_step <step-id>` fetches `pending/s-<id>.json`, jq-validates against `schemas/step.json` (defense-in-depth per `DESIGN.md §12.1.1`), evaluates `action_tier`, runs the tier-specific preflight + prompt per `docs/action-tiers.md §5`, executes the mapped verb (via `bl_observe_*` / `bl_defend_*` / `bl_clean_*` handlers landed by M4/M6/M7), writes `results/s-<id>.json`, POSTs a wake event. Exits 0 on success, 67 on schema fail, 68 on tier-gate decline/preflight-fail, 72 on step-not-found. | 4 `@test` entries, one per exit-code path. |
| G5 | `bl_run_batch --batch [--max N]` iterates contiguous pending steps in allocation order. `read-only` and `auto` steps auto-execute; `suggested` and `destructive` steps block for per-step confirm (NOT globally skipped by a `--yes` at batch level — per `docs/action-tiers.md §5.4` "no batch auto-confirm"). `--max N` caps the batch size (default 16). | `@test` asserts a mixed batch (auto + destructive) runs the auto and stops at the destructive for confirm. |
| G6 | `bl_run_list --list` enumerates pending steps for the current case in allocation order, showing `{step_id, verb, action_tier, reasoning[:60]}`, exits 0, does NOT execute any step. | `@test` asserts line count matches `ls pending/s-*.json \| wc -l`. |
| G7 | `bl_case_show [<case-id>]` reads the case subtree and renders a 6-section summary: hypothesis, evidence list, pending steps, applied actions, defense-hits, open questions. Uses `$(bl_case_current)` if no case-id passed; exits 72 if no current case and none passed. | `@test` asserts each section header appears + `bl case show <unknown-id>` exits 72. |
| G8 | `bl_case_log [<case-id>]` emits the full chronological ledger (observations → step emissions → actions applied → diffs confirmed → closures) by merging `bl-case/CASE-<id>/` memstore content with `/var/lib/bl/ledger/<case-id>.jsonl` per `DESIGN.md §13.4` dual-write. Output is JSONL (one record per event) for pipeline consumption. | `@test` asserts JSONL parseable by `jq -c '.'` + first-record timestamp matches case-open. |
| G9 | `bl_case_list [--open\|--closed\|--all]` reads `bl-case/INDEX.md`, filters by `Status` column, prints one row per matching case. Default is `--open`. | `@test` covers all three filters against a 3-case fixture. |
| G10 | `bl_case_close [<case-id>]` validates the 4 case-close preconditions per `docs/case-layout.md §5` (open-questions empty/none, all pending steps have paired results, all applied actions carry `retire_hint`, hypothesis confidence ≥ 0.7 or `--force`), renders the brief via Anthropic Files API in 3 MIME types (MD + HTML + PDF per `DESIGN.md §5.6` + §7.3), writes the rendered `closed.md` with frontmatter `brief_file_id_{md,pdf,html}` populated, updates `INDEX.md` row Status → `closed`, schedules retire sweep (writes `retire_hint`-triggered entries to `/var/lib/bl/state/retire-queue.jsonl`). Exits 0 on success, 68 on precondition fail, 69 on Files API upstream error (with local close still completing — §7.4). | Multi-`@test`: precondition fail, all-pass happy-path, Files-API-fail fallback. |
| G11 | `bl_case_reopen <case-id> --reason <str>` verifies `closed.md` exists, archives it to `closed-<ISO-ts>.md` (does NOT delete — audit trail), flips `INDEX.md` row Status → `reopened`, appends a wake event to the curator. Note: `docs/case-layout.md §5` names "case cannot be re-opened after close" as the default blocking condition; reopen is the explicit override with `--reason` mandatory. | `@test` covers happy-path + missing-reason (exits 64). |
| G12 | Case-id allocation is atomic and crash-safe. Concurrent `bl consult --new` invocations never allocate duplicate ids; a process killed between dir-create and INDEX-append leaves no half-initialized case (either fully present or fully absent). | `@test` uses `flock` + backgrounded concurrent invocations; asserts the two cases get sequential ids. |
| G13 | Trigger fingerprinting: `bl_consult_new` computes `sha256(trigger-content)[:16]` (file path → read; event string → string bytes) as the case's `trigger_fingerprint`, stored in `hypothesis.md` HTML-comment header. A second `bl consult --new --trigger <same>` within an already-open case produces a warning (stderr) + proceeds with a new case-id by default; `--dedup` flag attaches to the existing open case instead. | `@test` covers dedup-flag hit, dedup-flag miss (new id), no-dedup-flag (new id + warn). |
| G14 | `tests/helpers/curator-mock.bash` lands — serves fixture JSON for pending-steps poll, wake events, Files API upload (returns synthetic `file_id`). Zero live Anthropic API in CI per CLAUDE.md §Testing. | `@test` loads the mock; asserts `bl_api_call` returns fixture content. |
| G15 | `tests/05-consult-run-case.bats` lands with ≥14 `@test` entries (one per G1–G13 plus at least one full-lifecycle integration test: new → observe-batch → close). | `make -C tests test` green on debian12 + rocky9. |
| G16 | Every `exit`/`return` with a non-zero code in M5 handlers cites a `BL_EX_*` symbolic constant declared by M1; no numeric literals at call sites. | `grep -nE '\b(exit\|return) [0-9]+\b' bl` per-`BL_EX_`-matched line audit. |

---

## 3. Non-goals

- **NG1.** Implement the curator-side `report_step` emission. The curator emits via Managed Agents custom-tool — it is NOT wrapper code. M5 consumes what lands in `pending/`; M3 (curator prompt) + M8 (`bl setup` agent-create) own the emit surface.
- **NG2.** Implement `bl_observe_*`, `bl_defend_*`, `bl_clean_*` handler bodies. M5's `bl_run_step` dispatches into them by verb-class lookup; the handler bodies are M4/M6/M7 deliverables. M5 tests stub the executions via `curator-mock.bash` fixture results.
- **NG3.** Implement `bl_setup_*` idempotency logic. M8 owns. M5 consumes `bl_api_call` + `$BL_AGENT_ID` from the M1 preflight surface; it does not touch agent/env/memstore create.
- **NG4.** Render the brief body content. `bl_case_close` formats a rendering input from memstore content (hypothesis + attribution + ip-clusters + url-patterns + file-patterns + defense-hits + actions/applied/) and ships it to the Files API; the MD/HTML/PDF rendering happens in the Managed Agents platform (via `agent_toolset_20260401`'s render primitives) per `DESIGN.md §5.6` + §7.3. M5 is the client; the platform is the renderer.
- **NG5.** Author the full curator system prompt. M3 owns `prompts/curator-agent.md`; M5 references the existing commit.
- **NG6.** Implement injection-hardening corpus tests. M9 owns the corpus + tier-specific injection fixtures per `DESIGN.md §13.2`. M5's tests cover the happy/tier-gate/schema-fail paths; the adversarial corpus is M9.
- **NG7.** Implement fence-token verify or corpus validation. Per §0.1 binding, fences wrap evidence records (M4 emit surface, curator consumption); M5 has zero fence responsibility in its core path. M9 owns fence hardening per `DESIGN.md §13.2`.
- **NG8.** Migrate from `memver_` 30-day retention for the historical audit trail. `DESIGN.md §7.2` carries the platform contract; M5 consumes it as-is. Long-term audit lives in the local ledger per `DESIGN.md §13.4`.
- **NG9.** Implement the operator-veto 15-minute window for `auto`-tier actions. M6 (`bl defend`) owns the veto-window state machine per `docs/action-tiers.md §5.2`; M5 emits the notification but does not gate the veto timer.
- **NG10.** Packaging. M10 owns `.gitattributes` for `tests/fixtures/` export-ignore + RPM/DEB manifest updates for the new files (no runtime installs change in M5 — `tests/` is already export-ignored per M1).

---

## 4. Architecture

### 4.1 File map

| File | Status | Est. lines | Purpose |
|---|---|---|---|
| `bl` | **modify** | +~360 LOC | Fill the three M1-stub prefixes (`bl_consult_*`, `bl_run_*`, `bl_case_*`) with real handlers. Shared helpers added to M1 common-helpers block if and only if cross-prefix. |
| `tests/helpers/curator-mock.bash` | **new** | ~80 | `curl` shim serving fixture JSON for: pending-steps poll, wake-event POST, Files API upload (stage 1 MD), `files.list scope_id` (stage 2 HTML+PDF retrieval), memstore GET/POST. M0 deferred authorship to M5. |
| `docs/setup-flow.md` | **modify (+2 lines)** | — | §4.3 env packages `apt:` list adds `pandoc` + `weasyprint` per §9 "Dead code and cleanup" coordination. Lands in M5 commit. |
| `tests/helpers/case-fixture.bash` | **new** | ~60 | Seeds `/var/lib/bl/{backups,quarantine,state,outbox,ledger}` + a minimal `bl-case/CASE-2026-0001/` subtree using M2 templates. M0 `tests/helpers/case-fixture.bash` deferred to M5. |
| `tests/helpers/assert-jsonl.bash` | **new** | ~40 | `jq -e` schema check against `schemas/step.json` (pending-step path) and `schemas/evidence-envelope.md` (result path). M0 deferred to M5. |
| `tests/fixtures/step-read-only.json` | **new** | ~20 | One step envelope per tier (5 tiers). |
| `tests/fixtures/step-auto.json` | **new** | ~20 | |
| `tests/fixtures/step-suggested.json` | **new** | ~20 | |
| `tests/fixtures/step-destructive.json` | **new** | ~20 | |
| `tests/fixtures/step-unknown.json` | **new** | ~20 | |
| `tests/fixtures/step-schema-fail.json` | **new** | ~15 | Malformed envelope (missing `required` field) to exercise exit 67. |
| `tests/fixtures/pending-poll-empty.json` | **new** | ~5 | Mock response: empty pending queue. |
| `tests/fixtures/pending-poll-mixed.json` | **new** | ~40 | Mock response: 3 steps (auto + suggested + destructive) to exercise batch boundaries. |
| `tests/fixtures/files-api-upload.json` | **new** | ~10 | Mock response: `{"id": "file_01TESTxxxx", "filename": ..., "size_bytes": ...}`. |
| `tests/fixtures/memstore-get-empty.json` | **new** | ~5 | Mock response: empty memstore list. |
| `tests/fixtures/memstore-case-not-found.json` | **new** | ~5 | Mock response: 404 for attach-to-missing-case test. |
| `tests/05-consult-run-case.bats` | **new** | ~480 | ≥14 `@test` entries per G1–G13 + full-lifecycle integration. |

**Total:** 2 files modified (`bl` +~360 LOC, `docs/setup-flow.md` +2 lines), 14 files new (~835 LOC). No deletions.

### 4.2 Size comparison

| Surface | Before M5 | After M5 |
|---|---|---|
| `bl` LOC | ~515 (M1) | ~875 |
| `tests/*.bats` files | 3 (M1: 00, 01, 02) | 4 (add 05) |
| `tests/*.bats` LOC | ~220 (M1) | ~700 |
| `tests/helpers/*.bash` | 1 (`bl-preflight-mock.bash`) | 4 |
| `tests/fixtures/*.json` | 0 | 11 |
| Total `@test` entries | 21 (M1) | 21 + ≥14 = ≥35 |

### 4.3 Dependency tree

M5 consumes these M1 shared helpers (read-only — no modification):

```
bl  (post-M1, top-to-bottom)
│
├── [M1] bash 4.1+ floor, BL_EX_* constants, path constants
├── [M1] bl_info / bl_warn / bl_error / bl_debug / bl_error_envelope
├── [M1] bl_init_workdir   (M5 calls for /var/lib/bl/state/ + ledger/ + outbox/)
├── [M1] bl_case_current   (M5 reads)
├── [M1] bl_api_call       (M5 consumes for memstore + Files + wake events)
├── [M1] bl_poll_pending   (M5 replaces skeleton body with real polling loop — see §5.4)
├── [M1] bl_preflight      (M5 never invokes directly; dispatcher runs it once)
├── [M1] bl_usage / bl_version
│
├── [M4] bl_observe_*      ← dispatched into by bl_run_step via verb-class lookup
├── [M5] bl_consult_*      ← authored here
├── [M5] bl_run_*          ← authored here
├── [M5] bl_case_*         ← authored here
├── [M6] bl_defend_*       ← dispatched into by bl_run_step
├── [M7] bl_clean_*        ← dispatched into by bl_run_step
├── [M8] bl_setup_*        ← never dispatched by M5
│
└── main  (M1 dispatcher case-statement — untouched by M5)
```

**M5-to-M1 contract additions** (common-helpers block):

| Helper | Rationale | Consumer scope |
|---|---|---|
| `bl_jq_schema_check <schema-path> <payload-path>` | Defense-in-depth validation against `schemas/step.json`. Used by `bl_run_step` AND (future) `bl_defend` synthesize-defense result path. Lands in M1 common-helpers block to avoid cross-prefix authorship if M6 also needs it. | M5 primary; M6 secondary |
| `bl_ledger_append <case-id> <jsonl-record>` | Append-only write to `/var/lib/bl/ledger/<case-id>.jsonl` with `flock` + atomic rename. Dual-write partner to `bl-case/<case>/actions/applied/` per `DESIGN.md §13.4`. | M5 primary; M6, M7 secondary |
| `bl_files_api_upload <mime> <content-path>` | POST to `/v1/files` with multipart body + `files-api-2025-04-14` beta header per `docs/managed-agents.md §10`. Returns `file_id` on success. Used by `bl_case_close` for brief upload; M4 evidence bundles may consume later. | M5 primary |

These three helpers land in the M1 common-helpers block; the M5 worktree authors them. Any parallel worktree needing them coordinates via merge-review. The `SC2034 # consumed by M<N>` pattern from M1 applies if a helper is authored in M5's commit but not consumed until M6's merge.

**M5 internal dependency tree:**

```
bl_consult_new
  ├── bl_consult_allocate_case_id    (flock + STEP_COUNTER analog)
  ├── bl_consult_fingerprint_trigger (sha256[:16])
  ├── bl_consult_materialize_case    (cp case-templates/ → bl-case/CASE-<id>/)
  ├── bl_consult_register_curator    (bl_api_call POST wake event)
  └── bl_ledger_append
bl_consult_attach
  ├── bl_api_call GET memstore/bl-case/CASE-<id>/
  └── bl_ledger_append
bl_consult_sweep_mode
  ├── bl_api_call GET memstore/bl-case/CASE-*/closed.md  (list filter)
  └── (no ledger write — read-only inventory)

bl_run_step
  ├── bl_case_current  (get active case)
  ├── bl_api_call GET memstore/bl-case/CASE-<id>/pending/s-<id>.json
  ├── bl_jq_schema_check schemas/step.json <payload>
  ├── bl_run_evaluate_tier  (verb-class lookup + tier override check)
  ├── bl_run_prompt_operator  (diff/explain/abort/yes UX)
  ├── bl_run_preflight_tier  (apachectl -t for modsec; FP-gate for sig; …)
  ├── bl_run_dispatch_verb   (verb → bl_observe_*/bl_defend_*/bl_clean_*)
  ├── bl_run_writeback_result  (pending/ → results/ move + append)
  ├── bl_ledger_append
  └── bl_api_call POST wake event
bl_run_batch
  └── loop over bl_run_step with --max cap + tier-boundary break
bl_run_list
  └── bl_api_call GET memstore/bl-case/CASE-<id>/pending/  (list filter)

bl_case_show
  └── bl_api_call GET memstore/bl-case/CASE-<id>/*  (6 file reads)
bl_case_log
  ├── bl_api_call GET memstore/bl-case/CASE-<id>/results/ + actions/applied/ + history/
  └── local merge from /var/lib/bl/ledger/<case>.jsonl
bl_case_list
  └── bl_api_call GET memstore/bl-case/INDEX.md  (parse table rows)
bl_case_close
  ├── bl_case_close_validate_preconditions
  ├── bl_case_close_render_brief_input  (concat memstore files → /tmp/brief-<case>.md)
  ├── bl_files_api_upload application/pdf + text/html + text/markdown
  ├── bl_case_close_write_closed_md   (frontmatter substitution per case-templates/closed.md)
  ├── bl_case_close_update_index      (INDEX.md row mutation)
  ├── bl_case_close_schedule_retire   (append to /var/lib/bl/state/retire-queue.jsonl)
  └── bl_ledger_append
bl_case_reopen
  ├── bl_api_call memstore archive closed.md → closed-<ISO-ts>.md
  ├── bl_api_call memstore INDEX.md row mutation
  └── bl_ledger_append + wake event
```

### 4.4 Key changes

1. **Dispatcher untouched; three M1 stub bodies replaced.** `bl_consult` / `bl_run` / `bl_case` M1-stubs (print "not yet implemented" + return 64) are replaced with arg-parsing dispatchers that route to `bl_consult_new` / `bl_consult_attach` / `bl_consult_sweep_mode` and peers. The top-level `case "$1" in` statement M1 seeded is untouched — only the three empty handler bodies change.
2. **Three common helpers added.** `bl_jq_schema_check`, `bl_ledger_append`, `bl_files_api_upload` land in the M1 common-helpers block. Their shellcheck-SC2034 discipline (if unused in M5's own commit because of merge ordering) follows the M1 `# shellcheck disable=SC2034 # consumed by M<N>` pattern.
3. **Case-id allocation is file-flock-based, not remote.** The M0 memstore has no atomic counter primitive (platform `memver_` gives optimistic-concurrency preconditions per `docs/managed-agents.md §9`, not a counter). M5 runs allocation locally against `/var/lib/bl/state/case-id-counter` under `flock(1)` + atomic rename; the allocated id is then committed remotely via `bl-case/INDEX.md` append. Collision (two hosts allocate the same id concurrently across hosts) is bounded by the year rollover; cross-host collisions resolve via the INDEX.md `content_sha256` optimistic-concurrency precondition at memstore update time per `docs/managed-agents.md §9` — on 409 `CONFLICT`, M5 bumps the counter and retries. Exit 71 (`CONFLICT`) after 3 retries.
4. **Tier-gate enforcement is wrapper-side, double-validated.** `bl_run_step` validates `action_tier` twice: (a) against `schemas/step.json` enum (exit 67 if unknown string), (b) against the verb-class → expected-tier lookup table per `schemas/step.md` "Tier (typical)" column (exit 68 if curator tried to escalate `clean.*` → `auto`). The second check is the `docs/action-tiers.md §1` "agent cannot escalate itself" invariant.
5. **Brief-render flow is wrapper-side MD author + curator-session render.** The Files API per `docs/managed-agents.md §10` is blob-storage, NOT a renderer. `bl_case_close` authors the brief body locally as Markdown (`/tmp/brief-<case>.md`) from memstore content and uploads that single MD file via `bl_files_api_upload text/markdown`. For HTML + PDF output, `bl_case_close` sends a follow-up wake event to the curator session with the prompt `"render brief <file_id> to HTML and PDF; write to /mnt/session/outputs/; reply via user.custom_tool_result with the two new file_ids"` — the curator-env has `pandoc` + `weasyprint` preinstalled per M8 `bl setup --sync` (additive package request landed in M8's env create; M5 documents the requirement here and coordinates with M8 spec via `docs/setup-flow.md §4.3` env packages list addendum). The curator writes PDF + HTML to `/mnt/session/outputs/`; blacklight retrieves via `files.list(scope_id=$session_id)` per `docs/managed-agents.md §10` "retrieving files the agent produced"; both resulting `file_id`s are downloadable (`downloadable: true`). All three `file_id`s (MD uploaded + HTML & PDF agent-produced) land in `closed.md` frontmatter. On MD upload failure → exit 69 (close halts; MD is the source-of-truth). On HTML/PDF render timeout or failure → MD `file_id` populated, HTML/PDF carry empty-string sentinels in `closed.md`; close proceeds. Operator re-run of `bl case close` is idempotent post-close via the checkpoint file (R11 mitigation). The M5 minimum viable path is MD-only; HTML+PDF are opportunistic.
6. **Dual-write ledger per DESIGN.md §13.4.** Every `bl_run_step` success, every `bl_case_*` state transition, appends one JSONL record to `/var/lib/bl/ledger/<case-id>.jsonl` in parallel with the memstore write. Ledger format is one record per event with `{ts, case, kind, payload}`. `bl_case_log` merges memstore + ledger at read time.

### 4.5 `case.close` / `case.reopen` — dual entry paths

The verbs `case.close` and `case.reopen` in `schemas/step.json` enum are curator-emittable (per `prompts/curator-agent.md §5` rule 6 + §7 close criteria). They are ALSO operator-invoked CLI commands (`bl case close`, `bl case reopen`). Both paths converge on the same `bl_case_close` / `bl_case_reopen` implementation functions via two routes:

- **Operator CLI path** (`bl case close [<case-id>]`): dispatcher → `bl_case` → argparse flag match → `bl_case_close <case-id> [--force]`.
- **Curator step path** (`bl run <step-id>` where step-id's verb is `case.close`): dispatcher → `bl_run` → `bl_run_step` → schema + tier check → `bl_run_dispatch_verb` sees `verb="case.close"` → function-name mapping per flow step 9 → invokes `bl_case_close` with args from the step envelope.

Both paths validate the 4 close preconditions via `bl_case_close_validate_preconditions` — the precondition check is inside `bl_case_close`, not at the call site. This prevents two-call paths from diverging on precondition enforcement.

Implication: the curator can author `case.close` when its own close criteria are met (`prompts/curator-agent.md §7`); the wrapper still enforces the 4 preconditions from `docs/case-layout.md §5` — these are the same 4 conditions but from different sources. The curator's emitted `reasoning` field cites the conditions; the wrapper's precondition check verifies them programmatically. Agreement between the two is the happy path; disagreement (e.g., curator believes open-questions are resolved but the file has a stale entry the curator forgot to strike through) → wrapper rejects at precondition-validate → exit 68 → curator re-reads and revises on wake.

### 4.6 Dependency rules

- **Every `bl_*` M5 function cites `$BL_EX_*` constants** for exit/return codes. No numeric literals at call sites (G16). Applies to `return`, `exit`, and local-scope `local rc=$BL_EX_*` assignments.
- **No sourcing external files from `bl` runtime** (M1 §4.4 + M0 §0.2 single-file resolution). `tests/helpers/*.bash` are test-only; they source from the BATS environment, not from `bl`.
- **`bl_case_current` is the single-source-of-truth for "active case"** — every M5 handler that needs the case-id either accepts it as a positional arg or reads `bl_case_current` and exits 72 on empty. No env-var shadowing.
- **All memstore paths use the `bl-case/CASE-<id>/` prefix exactly** — never `bl-case/case-<id>/` or shortened variants. Case-id casing is `CASE-YYYY-NNNN` with zero-padded 4-digit sequence (M0 `case-layout.md §3` precedent).
- **`docs/case-layout.md §3` writer-owner table is normative.** M5 handlers writing to `results/`, `actions/applied/`, `INDEX.md`, `closed.md` must match. Cross-writes (e.g., M5 touching `hypothesis.md`) are policy violations and are logged as `bl_warn` events. `bl_case_reopen` is the sole exception — it archives `closed.md` without rewriting it (the archive path is fresh).

---

## 5. File contents

### 5.1 `bl_consult_*` — function inventory

| Function | Signature | Purpose | Exit |
|---|---|---|---|
| `bl_consult` | `(args...)` → exit | Dispatcher: parses `--new`/`--attach`/`--sweep-mode` mutually-exclusive flags; routes to implementation. Unknown flag → 64. | 0/64 |
| `bl_consult_new` | `(--trigger <artifact> [--notes <str>] [--dedup])` → exit | Allocate case-id, fingerprint trigger, materialize template set from `case-templates/`, register curator session via wake event, write `case.current`, append ledger. `--dedup` attaches to existing open case with same fingerprint (else new id + stderr warning). | 0/64/65/71 |
| `bl_consult_allocate_case_id` | `()` → stdout (`CASE-YYYY-NNNN`) | flock `/var/lib/bl/state/case-id-counter`, read + 1, atomic rename, emit new id. Format: `CASE-$(date +%Y)-$(printf '%04d' $n)`. Counter resets to 1 on Jan 1; crash-safety via `mv temp→final` + flock. | 0/65/71 |
| `bl_consult_fingerprint_trigger` | `(<artifact>)` → stdout (16-char hex) | If artifact is a file → `sha256sum <file>`. If artifact is a non-file string → `printf '%s' "$artifact" \| sha256sum`. Take first 16 hex chars. Store in `hypothesis.md` HTML-comment header (`<!-- trigger_fingerprint: <16hex> -->`) via sed-insert. | 0/65 |
| `bl_consult_materialize_case` | `(<case-id>)` → exit | `command cp -r case-templates/*.md bl-case/CASE-<id>/` excluding `README.md`, `closed.md`, and `INDEX.md` (latter goes workspace-level). `STEP_COUNTER` initialized to `0\n`. INDEX.md row appended before WRAPPER-APPEND anchor. All writes go through `bl_api_call POST memstore/`. | 0/65/69 |
| `bl_consult_register_curator` | `(<case-id>)` → exit | POST `user.message` wake event via `bl_api_call` with body `{"type":"user.message","content":[{"type":"text","text":"case opened: <case-id>; trigger_fingerprint=<fp>; read first per system-prompt §3"}]}`. | 0/69/70 |
| `bl_consult_attach` | `(--attach <case-id>)` → exit | GET `memstore/bl-case/CASE-<id>/hypothesis.md` to verify case exists. On 200 → write `/var/lib/bl/state/case.current`, `bl_info "attached to <case-id>"`. On 404 → exit 72. On any other failure → surface `bl_error_envelope`. | 0/64/65/69/72 |
| `bl_consult_sweep_mode` | `(--sweep-mode [--cve <id>])` → exit | List all `bl-case/CASE-*/closed.md` via `bl_api_call` memstore list with `path_prefix=bl-case/` + depth-filter. For each: parse frontmatter (`case_id`, `closed_at`, `brief_file_id_md`). Print tabulated inventory. Does NOT write `case.current`. Does NOT append ledger. `--cve` filter narrows to cases whose hypothesis.md mentions the CVE id. | 0/64/69 |

### 5.2 `bl_run_*` — function inventory

| Function | Signature | Purpose | Exit |
|---|---|---|---|
| `bl_run` | `(args...)` → exit | Dispatcher: routes to `_step` (default, positional step-id), `_batch` (on `--batch`), `_list` (on `--list`). | 0/64 |
| `bl_run_step` | `(<step-id> [--yes] [--dry-run] [--unsafe] [--explain])` → exit | End-to-end step execution. See §5.2.1 flow. | 0/64/67/68/69/70/72 |
| `bl_run_evaluate_tier` | `(<pending-path>)` → stdout (tier-slug), exit | jq-extract `action_tier` from envelope; lookup expected tier in verb-class table (embedded in bl); if mismatch → log `bl_warn "curator emitted tier=<declared>; verb-class forces tier=<expected>"` + use expected. Per `docs/action-tiers.md §1`. | 0/67 |
| `bl_run_prompt_operator` | `(<step-id> <tier> <diff-path>)` → exit | Per `DESIGN.md §11.1`, prints diff + `Apply? [y/N/diff-full/explain/abort]`. read from stdin; accepts `--yes` flag to skip. `explain` re-prints `reasoning`; `diff-full` shows whole before/after file; `abort` marks step operator-rejected. | 0/68 |
| `bl_run_preflight_tier` | `(<tier> <verb> <args-payload>)` → exit | Tier-specific preflight per `docs/action-tiers.md §5.3/§5.4`: `suggested` + `defend.modsec` → `apachectl -t`; `auto/suggested` + `defend.sig` → FP-gate scan; `suggested` + `defend.firewall` with CDN-safelist IP → ASN lookup. Failure → 68 with `reason:` string. | 0/65/68 |
| `bl_run_dispatch_verb` | `(<verb> <args-payload>)` → exit (stdout captured) | Parse verb namespace (`observe.*`/`defend.*`/`clean.*`/`case.*`); dispatch to `bl_observe_<action>` / `bl_defend_<action>` / `bl_clean_<action>` / `bl_case_<action>` handler with parsed kwargs. Captures stdout to `/tmp/bl-step-<step_id>.out` for writeback. | 0/64/65/72 |
| `bl_run_writeback_result` | `(<step-id> <rc> <stdout-path>)` → exit | Move `pending/s-<id>.json` → `results/s-<id>.json` with result payload merged: `{...original, result: {rc, stdout, applied_at}}`. Memstore write via `bl_api_call PATCH` (per `docs/managed-agents.md §9` update path). | 0/69/70 |
| `bl_run_batch` | `(--batch [--max N])` → exit | List pending steps (ordered), iterate. For each: run `bl_run_step` with operator-interactive mode. `read-only`/`auto` auto-execute (no prompt). `suggested`/`destructive` present prompt; declining → exit 68, batch halts. `--max N` caps iterations. | 0/64/68/72 |
| `bl_run_list` | `(--list)` → exit | GET `memstore/bl-case/CASE-<id>/pending/` list; for each step: parse JSON, print `{step_id, verb, action_tier, reasoning[:60]}`. | 0/64/69/72 |

#### 5.2.1 `bl_run_step` flow (canonical)

```
1. Parse step-id arg + flags (--yes, --dry-run, --unsafe, --explain).
2. case=$(bl_case_current); exit 72 if empty.
3. GET memstore bl-case/CASE-<case>/pending/s-<id>.json → /tmp/bl-pending-<id>.json
   (on 404 → exit 72)
4. bl_jq_schema_check schemas/step.json /tmp/bl-pending-<id>.json
   (on fail → exit 67; bl_ledger_append {kind: schema_reject, ...})
5. tier=$(bl_run_evaluate_tier /tmp/bl-pending-<id>.json)
   (on tier/verb-class mismatch → bl_warn + use verb-class tier)
6. If tier == "unknown" && ! (--unsafe && --yes) → exit 68
   (bl_ledger_append {kind: unknown_tier_deny, ...})
7. If tier == "read-only" || (tier == "auto" && ! --dry-run):
     execute (auto-no-prompt; notification for auto)
   Elif tier in {suggested, destructive}:
     bl_run_preflight_tier tier verb args
     (on preflight fail → exit 68; bl_ledger_append {kind: preflight_fail, reason})
     If --yes or --dry-run with diff-only:
        skip prompt
     Else:
        bl_run_prompt_operator step-id tier diff
        (on abort → exit 68; bl_ledger_append {kind: operator_decline})
8. If --dry-run: print diff + exit 0 (NO writeback, NO ledger).
9. bl_run_dispatch_verb verb args → /tmp/bl-step-<step_id>.out
   (capture rc; do NOT propagate rc up yet — writeback must happen regardless for audit)
   Verb→function mapping: verb "<ns>.<action>" → function "bl_<ns>_<action>" (dot → underscore).
   Example: observe.log_apache → bl_observe_log_apache; case.close → bl_case_close.
10. bl_run_writeback_result step-id rc /tmp/bl-step-<step_id>.out
    (on writeback-upload failure → local file stays; bl_warn about retry; exit 69/70)
11. bl_ledger_append {ts, case, kind: step_run, step_id, tier, verb, rc, result_size}
12. bl_api_call POST wake event
    {"type":"user.message","content":[{"type":"text","text":"result landed: s-<id> rc=<rc>"}]}
13. exit $rc (propagate executor exit; 0 on success).
```

### 5.3 `bl_case_*` — function inventory

| Function | Signature | Purpose | Exit |
|---|---|---|---|
| `bl_case` | `(args...)` → exit | Dispatcher: routes to `_show`/`_log`/`_list`/`_close`/`_reopen` based on positional-1 or flag. | 0/64 |
| `bl_case_show` | `([<case-id>])` → exit | GET 6 memstore files (`hypothesis.md`, `evidence/` list, `pending/` list, `actions/applied/` list, `defense-hits.md`, `open-questions.md`). Render 6-section summary to stdout. | 0/64/69/72 |
| `bl_case_log` | `([<case-id>])` → exit | Emit chronological JSONL log: merge `history/` + `results/` + `actions/applied/` from memstore with `/var/lib/bl/ledger/<case>.jsonl`. Sort by `ts`. | 0/64/69/72 |
| `bl_case_list` | `([--open\|--closed\|--all])` → exit | GET `bl-case/INDEX.md`; parse markdown table rows; filter by Status column; tabulate. | 0/64/69 |
| `bl_case_close` | `([<case-id>] [--force])` → exit | End-to-end close; see §5.3.1 flow. | 0/64/68/69/72 |
| `bl_case_reopen` | `(<case-id> --reason <str>)` → exit | Archive `closed.md` → `closed-<ISO-ts>.md`; mutate INDEX.md Status → `reopened`; append ledger + wake event. `--reason` is required (exit 64 if missing). | 0/64/69/72 |
| `bl_case_close_validate_preconditions` | `(<case-id>)` → exit | 4 checks per `docs/case-layout.md §5`: (a) `open-questions.md` empty or literal `none`; (b) every `pending/s-*.json` has paired `results/s-*.json`; (c) every `actions/applied/*.yaml` has `retire_hint` field; (d) hypothesis confidence ≥ 0.7 OR `--force`. Fail → exit 68 with per-check `reason`. | 0/68/69 |
| `bl_case_close_render_brief_input` | `(<case-id>)` → stdout (path to `/tmp/brief-<case>.md`) | Concat memstore files into single brief-input (shape per §7.4 "Bundled content"). Writes to `/tmp/brief-<case>-$$.md`. Also POSTs a copy to `bl-case/CASE-<id>/brief-source.md` in the memstore for audit-archival (per R6 mitigation). | 0/69 |
| `bl_case_close_write_closed_md` | `(<case-id> <file-id-md> <file-id-html> <file-id-pdf>)` → exit | Read `case-templates/closed.md`; substitute `{CASE_ID}`, `{ISO_8601_TIMESTAMP}`, `{FILE_ID_OR_EMPTY}` × 3; write result via `bl_api_call POST memstore/bl-case/CASE-<id>/closed.md`. Retirement schedule rows sourced from `actions/applied/*.yaml` `retire_hint` fields. | 0/69/70 |
| `bl_case_close_update_index` | `(<case-id>)` → exit | GET INDEX.md, find case row, rewrite Status column → `closed` + populate brief `file_id`, PATCH via content_sha256 optimistic-concurrency per `docs/managed-agents.md §9`. On 409 → retry once after re-GET; exit 71 after 3 retries. | 0/69/70/71 |
| `bl_case_close_schedule_retire` | `(<case-id>)` → exit | For each `actions/applied/*.yaml` with `retire_hint: <spec>`: append one JSONL record to `/var/lib/bl/state/retire-queue.jsonl` with `{case, act_id, retire_when, retire_cond}`. Does NOT set timers — retire sweep is M10 cron entry; M5 only queues. | 0/65 |

#### 5.3.1 `bl_case_close` flow

```
1. Parse case-id arg (default: $(bl_case_current)); --force flag.
2. bl_case_close_validate_preconditions case-id
   (on fail → exit 68 with specific reason; ledger entry)
3. input=$(bl_case_close_render_brief_input case-id)   # /tmp/brief-<case>.md (Markdown)
4. fid_md=$(bl_files_api_upload text/markdown $input)
   (on failure → exit 69; MD is source-of-truth, close halts here)
5. If $BL_BRIEF_MIMES contains "text/html" or "application/pdf":
     POST user.message wake event to curator session requesting render:
       "render file_id=$fid_md to HTML and PDF; write to /mnt/session/outputs/"
     Poll files.list(scope_id=$session_id) up to 60s for new agent-produced files
     If HTML file_id appears → fid_html=<id>; else fid_html="" (sentinel)
     If PDF file_id appears → fid_pdf=<id>;  else fid_pdf=""  (sentinel)
     (on render timeout → bl_warn "curator render did not complete; closing with MD only")
6. bl_case_close_write_closed_md case-id $fid_md $fid_html $fid_pdf
   (on memstore write failure → checkpoint for retry; exit 69)
7. bl_case_close_update_index case-id
   (on 409 retry loop; on exhaust → exit 71)
8. bl_case_close_schedule_retire case-id
9. unset /var/lib/bl/state/case.current (since the case is closed)
10. bl_ledger_append {kind: case_closed, case, brief_file_ids, closed_at}
11. bl_api_call POST wake event (final):
    {"type":"user.message","content":[...,"text":"CASE-<id> closed. Brief file_ids: ..."]}
12. exit 0
```

### 5.4 Shared-helper additions to M1 block

| Helper | Shape |
|---|---|
| `bl_jq_schema_check` | `bl_jq_schema_check <schema-path> <payload-path>` — uses `jq -e --slurpfile schema <schema-path> '...'` with a jq sub-program implementing JSON Schema Draft 2020-12 subset actually used (`type`, `required`, `enum`, `properties`, `items`). Returns 0 on pass, 67 on fail. Unknown-key check (the `additionalProperties: false` that M0 §NG2 notes the platform can't enforce) is opt-in via 2nd flag `--strict`. M5 `bl_run_step` passes `--strict`. |
| `bl_ledger_append` | `bl_ledger_append <case-id> <jsonl-record>` — opens `/var/lib/bl/ledger/<case-id>.jsonl` under `flock -x 200`, appends one newline-terminated record, fsyncs, releases flock. Concurrent writers serialize via the flock. Record format: `{"ts":"<ISO-8601>","case":"<case-id>","kind":"<one-of-enum>","payload":{...}}`. Kinds: `case_opened`, `case_attached`, `step_emitted`, `step_run`, `action_applied`, `action_retired`, `case_closed`, `case_reopened`, `schema_reject`, `preflight_fail`, `operator_decline`, `unknown_tier_deny`. |
| `bl_files_api_upload` | `bl_files_api_upload <mime> <file-path>` — `curl -sS -X POST -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-beta: files-api-2025-04-14,managed-agents-2026-04-01" -H "anthropic-version: 2023-06-01" -F "file=@<path>;type=<mime>" https://api.anthropic.com/v1/files`. Parse response `.id`; emit to stdout. Retry 3× on 5xx with 2s/5s/10s backoff. Per `docs/managed-agents.md §10`. On any 4xx → exit 69 with the response body in `bl_debug`. Used by `bl_case_close` for MD brief upload (stage 1 of §7.4 two-stage flow); HTML + PDF derive from curator render (stage 2) and are retrieved via `bl_files_api_list_scope` (future companion — M5 ships a minimal `bl_api_call GET /v1/files?scope_id=...` inline in `bl_case_close`). |

---

## 5b. Examples

### 5b.1 `bl consult --new --trigger /path/to/apsb25-94-staging-sample.htaccess`

```
$ bl consult --new --trigger /var/www/html/pub/media/.../.htaccess
[bl] INFO: allocated CASE-2026-0008
[bl] INFO: trigger fingerprint: a3f5c8...
[bl] INFO: materialized 7 on-open template files into bl-case/CASE-2026-0008/
[bl] INFO: INDEX.md roster row appended
[bl] INFO: case.current → CASE-2026-0008
[bl] INFO: wake event sent; curator session will read on next turn
CASE-2026-0008
$ echo $?
0
```

### 5b.2 `bl run s-0041` — `suggested` tier, operator accepts

```
$ bl run s-0041
bl-run 2026-04-24T19:14:08Z — CASE-2026-0008 step s-0041
Verb:    defend.modsec
Tier:    suggested
Reasoning:
  obs-0038 + obs-0041 confirm polyshell staging at /pub/media/.../a.php/banner.jpg.
  Rule targets REQUEST_FILENAME matching \.php/[^/]+\.(jpg|png|gif)$ in phase:2.
  apachectl -t passes against staged config.

[preflight] apachectl -t staged config... ok
[diff]
   --- a/etc/modsecurity/crs/REQUEST-941.conf
   +++ b/etc/modsecurity/crs/REQUEST-941.conf
   @@ ...
   +SecRule REQUEST_FILENAME "@rx \.php/[^/]+\.(jpg|png|gif)$" \
   +    "id:941999,phase:2,deny,log,msg:'polyshell double-ext staging'"

Apply? [y/N/diff-full/explain/abort] y
[bl] INFO: dispatching defend.modsec (M6 handler)
[bl] INFO: applied; writeback to results/s-0041.json (350 B)
[bl] INFO: ledger entry written (/var/lib/bl/ledger/CASE-2026-0008.jsonl)
[bl] INFO: wake event sent
$ echo $?
0
```

### 5b.3 `bl run s-0099` — unknown tier, operator has no `--unsafe --yes`

```
$ bl run s-0099
bl-run: step s-0099 has action_tier=unknown
blacklight: tier-gate denied (tier=unknown)
  override requires both --unsafe and --yes; neither provided
$ echo $?
68
```

### 5b.4 `bl case close` — precondition fail (open questions non-empty)

```
$ bl case close CASE-2026-0008
blacklight: case close denied (CASE-2026-0008)
  reason: open-questions.md has 3 unresolved entries (expected 0 or "none")
$ echo $?
68
```

### 5b.5 `bl case close` — happy path

```
$ bl case close CASE-2026-0008
[bl] INFO: preconditions satisfied (4/4)
[bl] INFO: rendering brief input (/tmp/brief-CASE-2026-0008-12847.md, 14 KB)
[bl] INFO: uploaded text/markdown → file_01X9Jh5z7m...
[bl] INFO: wake event sent; curator rendering HTML + PDF
[bl] INFO: polled files.list scope_id=sesn_... (attempt 3/12)
[bl] INFO: agent-produced brief-CASE-2026-0008.html → file_01X9Jh5zAB...
[bl] INFO: agent-produced brief-CASE-2026-0008.pdf → file_01X9Jh5zCD...
[bl] INFO: closed.md written with 3 brief file_ids
[bl] INFO: INDEX.md row mutated (Status: active → closed)
[bl] INFO: retire queue: 2 actions scheduled
[bl] INFO: ledger: case_closed
CASE-2026-0008 closed
$ echo $?
0
```

### 5b.6 `bl case log CASE-2026-0008` — JSONL output shape

```
$ bl case log CASE-2026-0008 | head -4
{"ts":"2026-04-24T19:00:02Z","case":"CASE-2026-0008","kind":"case_opened","payload":{"trigger_fingerprint":"a3f5c8..."}}
{"ts":"2026-04-24T19:14:08Z","case":"CASE-2026-0008","kind":"step_run","payload":{"step_id":"s-0041","verb":"defend.modsec","tier":"suggested","rc":0}}
{"ts":"2026-04-24T19:14:09Z","case":"CASE-2026-0008","kind":"action_applied","payload":{"act_id":"act-0003","backup_path":"/var/lib/bl/backups/CASE-2026-0008/...","retire_hint":"zero-hits-14d"}}
{"ts":"2026-04-24T19:55:42Z","case":"CASE-2026-0008","kind":"case_closed","payload":{"brief_file_ids":{"md":"file_01X9Jh5z7m...","html":"file_01X9Jh5zAB...","pdf":"file_01X9Jh5zCD..."}}}
```

---

## 6. Conventions

### 6.1 Case-id format

`CASE-YYYY-NNNN` where `YYYY` is the allocation year (4 digits) and `NNNN` is a zero-padded 4-digit sequence starting at 0001 per calendar year. Separator is ASCII hyphen `-` only. Casing is uppercase `CASE` (literal). Example: `CASE-2026-0008`. Year rollover is atomic at counter-file rotation boundary (`/var/lib/bl/state/case-id-counter` rewritten with `{"year":2027,"n":0}` on first Jan 1 allocation).

### 6.2 Trigger-fingerprint format

`trigger_fingerprint: <16-hex>` where `<16-hex>` is the first 16 lowercase hexadecimal characters of the sha256 of the trigger content (per §0.1 inherited fence-token format — case-level scope instead of per-payload). The fingerprint is stored as an HTML comment in `hypothesis.md` (first line after the case-layout writer-owner header). Grep-stable; greppable across the workspace for dedup.

### 6.3 Memstore path normalization

Every memstore path in M5 uses the forward-slash-delimited form `bl-case/CASE-<id>/<file>` exactly as it appears in `docs/case-layout.md §2` tree. No trailing slashes on paths used in `bl_api_call` GET/POST. Path segments are ASCII only.

### 6.4 Ledger record schema

```json
{
  "ts": "<ISO-8601 UTC with Z>",
  "case": "CASE-YYYY-NNNN",
  "kind": "<one of 12 enum values per §5.4>",
  "payload": { ... kind-specific ... }
}
```

One record per line; `jq -c` safe; append-only. No compaction. Local file is authoritative per `DESIGN.md §13.4` if memstore wipes.

### 6.5 Prompt UX text

Operator prompts use the M0 `docs/action-tiers.md §5` + `DESIGN.md §11.1` canonical form:

```
Apply? [y/N/diff-full/explain/abort]
```

Single-char + newline acceptable. Default is N (reject). Case-insensitive (`Y` == `y`). `explain` re-prints the step's `reasoning` field. `diff-full` shows the entire before/after (not just context). `abort` is synonymous with `n` + marks the step operator-rejected in the ledger.

### 6.6 Coreutils prefix

Per M1 §6.4 + project CLAUDE.md §Shell Standards: all coreutils in `bl` use `command` prefix (`command cp`, `command mkdir`, `command rm`, `command cat` except in heredocs). `printf` / `echo` are builtins and used bare. `jq` / `curl` / `flock` are Tier-2 deps per `DESIGN.md §14.2` — used bare (no `command` prefix) since they are discovered via PATH.

### 6.7 Exit-code discipline

Per M1 §6.3 + G16: every `exit`/`return` with non-zero code cites a `BL_EX_*` constant. Verification: `grep -nE '\b(exit\|return) [0-9]+\b' bl \| grep -vE 'BL_EX_\|return 0' ` returns zero lines.

### 6.8 Locking discipline

`flock(1)` usage: always `-x` (exclusive) + `-w 30` (timeout) + FD 200 (avoid stdin/stdout/stderr). Pattern:

```bash
exec 200<>"$lockfile"  # NB: open RW so unprivileged flock succeeds on read-only mount corners
flock -x -w 30 200 || { bl_error_envelope ... ; return "$BL_EX_CONFLICT"; }
# critical section
exec 200<&-
```

M1 §Shell Standards prohibits `flock` re-entry via different FDs on the same file in the same process; M5's helpers never nest.

---

## 7. Interface contracts

### 7.1 CLI surface additions (M5-owned)

- `bl consult --new --trigger <artifact> [--notes <str>] [--dedup]`
- `bl consult --attach <case-id>`
- `bl consult --sweep-mode [--cve <id>]`
- `bl run <step-id> [--yes] [--dry-run] [--unsafe] [--explain]`
- `bl run --batch [--max N]`
- `bl run --list`
- `bl case show [<case-id>]`
- `bl case log [<case-id>]`
- `bl case list [--open|--closed|--all]`
- `bl case close [<case-id>] [--force]`
- `bl case reopen <case-id> --reason <str>`

No collisions with M1-frozen flags (`-h`, `--help`, `-v`, `--version`). No new top-level flags; all M5 flags are namespace-scoped.

### 7.2 Environment variables

Introduced by M5:

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `BL_BRIEF_MIMES` | no | `text/markdown,text/html,application/pdf` | CSV of MIME types `bl_case_close` attempts. Operator can narrow (e.g., `BL_BRIEF_MIMES=text/markdown` for single-format closes) or skip all by setting empty. MD is always uploaded as stage 1 regardless of this list; this controls stage 2 HTML/PDF render. |
| `BL_PROMPT_DEFAULT` | no | `N` | Default answer for non-TTY prompts (`N` = reject). Operator sets to `y` for automated pipelines (not recommended for destructive tier). |

### 7.3 File contracts (local state)

Created or mutated by M5:

- `/var/lib/bl/state/case.current` — first-line plain-text case-id. Mutated by `bl_consult_new` + `bl_consult_attach`; cleared by `bl_case_close`.
- `/var/lib/bl/state/case-id-counter` — JSON `{"year":<4-digit>,"n":<int>}`. flock-protected.
- `/var/lib/bl/state/retire-queue.jsonl` — append-only JSONL; one record per queued retire action.
- `/var/lib/bl/ledger/<case-id>.jsonl` — append-only; dual-write per `DESIGN.md §13.4`.
- `/var/lib/bl/outbox/<serial>.json` — rate-limit queue (already declared by M1 §7.3; M5 consumes via `bl_api_call` retry on 429).

### 7.4 Files API brief-render contract

Per `DESIGN.md §5.6` + §7.3 + `docs/managed-agents.md §10` + §10.5:

**Two-stage flow** — wrapper-side upload (MD source-of-truth) + curator-session render (HTML + PDF opportunistic).

Stage 1 — MD upload (wrapper → Files API directly):
- **Method:** `POST /v1/files` with `multipart/form-data` body.
- **Headers:** `anthropic-beta: files-api-2025-04-14,managed-agents-2026-04-01` (both required; comma-separated); `x-api-key: $ANTHROPIC_API_KEY`; `anthropic-version: 2023-06-01`.
- **Body:** `file=@/tmp/brief-<case>.md;type=text/markdown`. Rendered by `bl_case_close_render_brief_input` from memstore content.
- **Response shape:** `{"id": "file_01...", "filename": "...", "mime_type": "text/markdown", "size_bytes": <int>, "created_at": "<ISO>", "downloadable": false}`. User-uploaded per `docs/managed-agents.md §10` "two provenance classes" — `downloadable: false`. Operator retrieves via the Anthropic Console if external archival needed, or via `bl case show --brief <case-id>` printing the `file_id`.
- **Failure:** 4xx → exit 69 with response body logged; 5xx → retry 3× with backoff, then exit 69. MD upload failure halts close — MD is the source-of-truth; HTML and PDF are derived.

Stage 2 — HTML + PDF render (curator session produces via agent_toolset_20260401):
- **Trigger:** `bl_case_close` POSTs a `user.message` wake event to the curator's active session with the prompt pointing at `fid_md`. The curator reads the MD (either from the `resources[]` attachment created by the wrapper via `sessions.resources.add(type="file", file_id=$fid_md)` or by `read` tool against the mount), invokes `pandoc` (Tier-3 env dep per `DESIGN.md §14.3`, augmented by M8 `bl setup` env create to include `pandoc` + `weasyprint` — M5 adds the package list addendum to `docs/setup-flow.md §4.3` in the M5 commit), writes `/mnt/session/outputs/brief-<case>.html` and `/mnt/session/outputs/brief-<case>.pdf`, emits `user.custom_tool_result` via a `report_render_complete` side-channel (or — simpler — just completes with `end_turn` after write and the wrapper picks up via `files.list(scope_id=$session_id)`).
- **Retrieval:** `bl_case_close` polls `GET /v1/files?scope_id=<session-id>&betas=files-api-2025-04-14,managed-agents-2026-04-01` every 5 seconds up to 60 seconds for new files. Match by filename (`brief-<case>.html`, `brief-<case>.pdf`). Agent-produced files are `downloadable: true` per `docs/managed-agents.md §10` — operator can retrieve via API download for true PDF archival.
- **Failure:** render timeout (60s) → `fid_html=""`, `fid_pdf=""` (empty-string sentinels in `closed.md`); case close proceeds. `bl_warn "curator render did not complete within 60s; closing with MD-only brief"`. Operator re-runs `bl case close <case-id>` to retry render (checkpoint state file in `/var/lib/bl/state/close-checkpoint-<case>.json` ensures MD upload is not duplicated).
- **Why this flow:** Files API is blob storage (no render capability per `docs/managed-agents.md §10`). The curator session's sandbox has the render tooling. Offloading render to the curator keeps the wrapper dep-light (no `pandoc` on fleet hosts) while producing proper PDFs via browser-engine-backed `weasyprint`. This is the `docs/managed-agents.md §10.5` "agent produces deliverable → write to `/mnt/session/outputs/` → external code retrieves via `files.list(scope_id=$session_id)`" pattern verbatim.

**Bundled content** (brief-input MD shape, authored by `bl_case_close_render_brief_input`):
- `# Case CASE-YYYY-NNNN` title
- `## Executive summary` — from `hypothesis.md` "Current" section
- `## Kill chain` — `attribution.md` stanzas verbatim
- `## Indicators of compromise` — `ip-clusters.md` + `url-patterns.md` + `file-patterns.md` tables concatenated
- `## Remediation applied` — summary table from `actions/applied/*.yaml` (act_id, applied_at, retire_hint, kind)
- `## Defense hits` — `defense-hits.md` tail (last 30 rows or all if fewer)
- `## Open questions resolved` — `open-questions.md` content (per close precondition: empty or "none"; prints "none at close" if the latter)
- `## Audit` — one-liner pointing to `/var/lib/bl/ledger/<case>.jsonl` (regulator-reachable if on-host)

### 7.5 Tier enforcement matrix (wrapper-side truth table)

Per `docs/action-tiers.md §5` + `schemas/step.md` tier-typical column:

| Verb family | Expected tier | Prompt? | Preflight? | `--yes` required? | `--unsafe` required? |
|---|---|---|---|---|---|
| `observe.*` | read-only | no | no | no | no |
| `defend.firewall` (new, off CDN) | auto | no (notification only) | ASN safelist check | no | no |
| `defend.firewall` (new, on CDN) | suggested | yes | ASN lookup | yes | no |
| `defend.sig` (FP-pass) | auto | no | FP-gate already passed | no | no |
| `defend.sig` (FP-fail) | suggested | yes | FP-gate | yes | no |
| `defend.modsec` (new) | suggested | yes | `apachectl -t` | yes | no |
| `defend.modsec_remove` | destructive | yes | none | yes | no |
| `clean.*` (all 4) | destructive | yes | none (backup written by handler) | yes | no |
| `case.close` | suggested | yes | precondition check | yes | no |
| `case.reopen` | suggested | yes | `closed.md` exists check | yes | no |
| (any verb, tier=unknown) | unknown | yes | none | yes | **yes** |

If curator emits a tier that disagrees with this table (e.g., `action_tier: auto` on `clean.htaccess`), wrapper logs `bl_warn "curator tier=auto overridden to destructive per verb-class"` and uses the expected tier. Per `docs/action-tiers.md §1` invariant.

### 7.6 Wake-event payload shape

Every memstore state transition emits one wake event via `bl_api_call POST /v1/sessions/<session-id>/events`:

```json
{
  "type": "user.message",
  "content": [{"type": "text", "text": "<human-readable cue pointing curator to fresh memstore paths>"}]
}
```

Session-id is read from `/var/lib/bl/state/session-<case-id>` (written by `bl_consult_new` and `bl_consult_attach`; session creation itself is an M8 detail that M5 consumes).

---

## 8. Migration safety

### 8.1 Upgrade path

**N/A** — M5 is greenfield (pre-v2 `bl-ctl` removed at M1). No prior M5 state exists on `main`. Fresh installs land M5 alongside M1–M4 in the Wave-2 merge.

### 8.2 Install path

No packaging impact. M5 modifies `bl` (already installed path) + adds `tests/*` (already export-ignored per M1 `.gitattributes`). M10 picks up `tests/fixtures/` for export-ignore if the pattern lands there (inherits from `tests/` parent ignore).

### 8.3 Uninstall

`rm -rf /var/lib/bl/{state,ledger,outbox}` + `rm /path/to/bl`. Memstore content persists in the workspace until operator archives the `bl-curator` agent per `docs/managed-agents.md §3` archive semantics (one-way). M5 does not add an `uninstall.sh` entry — M10 owns.

### 8.4 Rollback

`git revert` the M5 landing commit. Restores M1-era stubs. Any in-flight cases lose their wrapper-side handlers but persist in the memstore (30-day `memver_` retention per platform). Operator can `git revert` back M5 to resume; memstore state survives.

### 8.5 Backward compatibility

N/A. v1 Python curator archived at `legacy-pre-pivot` tag. v2 M5 greenfield.

---

## 9. Dead code and cleanup

No dead code removed in M5. Incidental findings during spec authoring:

| Surface | Observation | Disposition |
|---|---|---|
| `DESIGN.md §5.3` | Uses `--yes-auto-tier` flag for `bl run --batch`; `docs/action-tiers.md §5.4` forbids batch auto-confirm for destructive per "no batch auto-confirm" rule | M5 implementation ignores `--yes-auto-tier` semantically; batch runs auto/read-only automatically, prompts for suggested/destructive. No DESIGN.md edit needed — the flag is documented but its behavior per-step respects the tier contract. If a future operator uses `--yes-auto-tier`, batch mode maps it to `--yes` for `auto` only, NOT for destructive. Documented in §5.2 `bl_run_batch` row. |
| `DESIGN.md §5.6` `bl case close` | Says "writes precedent pointer to `bl-archive`"; §7.3 says "Precedent — a closed case accessible to future cases via `bl-archive/` (lives within `bl-case` memory store in v2, not a separate store)" | M5 writes precedent pointer INTO `bl-case/<case-id>/closed.md` frontmatter (unified with M2 `closed.md` shape). No separate `bl-archive/` memstore. Glossary `DESIGN.md §16` aligns. No DESIGN.md edit needed. |
| `docs/setup-flow.md §4.3` env packages | Current apt list: `[apache2, libapache2-mod-security2, modsecurity-crs, yara, jq, zstd, duckdb]`. M5's §7.4 brief-render flow needs `pandoc` + `weasyprint` in the curator env | Coordination item with M8: M5's build phase adds `pandoc` and `weasyprint` to `docs/setup-flow.md §4.3` apt list in the same commit that lands M5 runtime (so M8's `bl setup` creates the env with the brief-render deps available). Any parallel M8 worktree must re-read `docs/setup-flow.md` at build start. Flagged as Wave-2 merge reviewer checkpoint. |

Deferred: governance files (`.rdf/governance/*.md`) still reference v1 curator flow — out-of-scope per M1 §9 (M10 owns governance refresh).

---

## 10a. Test strategy

BATS via batsman (tests/infra/ submodule, landed M1). All tests use `tests/helpers/curator-mock.bash` as `PATH`-prepended curl shim — zero live Anthropic API in CI per CLAUDE.md §Testing.

Target file: `tests/05-consult-run-case.bats`. Target count: ≥14 `@test` entries (one per G1–G13 plus ≥1 full-lifecycle integration).

| Goal | `@test` description |
|---|---|
| G1 | `@test "bl consult --new allocates CASE-YYYY-NNNN, materializes templates, writes case.current"` |
| G1 (crash-safety sub-test) | `@test "bl consult --new killed mid-init leaves no partial case"` |
| G2 | `@test "bl consult --attach to existing case flips case.current"` + `@test "bl consult --attach to unknown case exits 72"` |
| G3 | `@test "bl consult --sweep-mode lists closed cases without opening one"` |
| G4 | `@test "bl run <step-id> validates schema, evaluates tier, executes, writes result"` |
| G4 (schema-fail) | `@test "bl run on malformed step exits 67 without execution"` |
| G4 (tier-gate) | `@test "bl run destructive without --yes exits 68 without execution"` |
| G4 (not-found) | `@test "bl run <unknown-step> exits 72"` |
| G4 (unknown-tier) | `@test "bl run on unknown-tier step without --unsafe --yes exits 68"` |
| G5 | `@test "bl run --batch respects tier boundaries; auto runs, destructive halts for prompt"` |
| G6 | `@test "bl run --list enumerates pending without execution"` |
| G7 | `@test "bl case show renders 6 sections from fixture subtree"` |
| G7 (not-found) | `@test "bl case show <unknown-id> exits 72"` |
| G8 | `@test "bl case log emits JSONL parseable by jq -c"` |
| G9 | `@test "bl case list --open/--closed/--all filters correctly"` |
| G10 (precond-fail) | `@test "bl case close fails on open-questions non-empty (exit 68)"` |
| G10 (happy) | `@test "bl case close happy-path writes closed.md with 3 brief file_ids, updates INDEX"` |
| G10 (Files-fail) | `@test "bl case close with Files API failure still closes locally; closed.md carries empty file_id sentinels"` |
| G11 | `@test "bl case reopen archives closed.md, flips INDEX Status"` |
| G11 (no-reason) | `@test "bl case reopen without --reason exits 64"` |
| G12 | `@test "two concurrent bl consult --new invocations allocate sequential case-ids (flock)"` |
| G13 | `@test "bl consult --new --dedup with matching trigger_fingerprint attaches to existing"` |
| G14 | `@test "curator-mock serves fixture JSON; bl_api_call returns expected body"` |
| G15 | (all above; integration `@test "full-lifecycle: new → observe → run → close → log"`) |
| G16 | N/A — source-level grep in §10b |

**Fixture contract:** `tests/fixtures/step-*.json` covers all 5 tiers. `pending-poll-mixed.json` drives the batch test. `files-api-upload.json` returns canned `file_01TEST` ids. `memstore-*.json` covers case-exists / case-missing paths. All fixtures authored in M5 per M0 deferral.

**No --privileged.** Per M1 `tests/run-tests.sh` + PLAN-M1 + project CLAUDE.md §Testing, blacklight M5 tests run unprivileged. `bl defend firewall` integration tests (M6) will run privileged; M5's stubbed verb-dispatch does not exercise real iptables.

---

## 10b. Verification commands

```bash
# G1 — case-id allocation, template materialization
export BL_VAR_DIR=$(mktemp -d)
export ANTHROPIC_API_KEY="sk-ant-test"
source tests/helpers/curator-mock.bash
bl_mock_set_response empty_case_probe
out=$(bl consult --new --trigger /tmp/test-trigger 2>&1)
rc=$?
[[ "$rc" -eq 0 ]] && echo "alloc OK"
grep -qE '^CASE-2026-[0-9]{4}$' <(printf '%s\n' "$out" | tail -1) && echo "id-format OK"
cat "$BL_VAR_DIR/state/case.current"
# expect: CASE-2026-0001
command rm -rf "$BL_VAR_DIR"

# G4 — schema validation fail (exit 67)
# (fixture step-schema-fail.json missing a required field)
out=$(bl run s-schema-fail 2>&1)
rc=$?
[[ "$rc" -eq 67 ]] && echo "schema-fail OK"

# G4 — tier-gate decline (exit 68) for destructive without --yes
out=$(bl run s-destructive-noyes 2>&1 <<< 'n')
rc=$?
[[ "$rc" -eq 68 ]] && echo "tier-gate OK"

# G10 — precondition fail
# (fixture case with open-questions.md non-empty)
out=$(bl case close CASE-2026-FAIL 2>&1)
rc=$?
[[ "$rc" -eq 68 ]] && grep -q 'open-questions' <(printf '%s' "$out") && echo "precond-fail OK"

# G12 — concurrent allocation
for i in 1 2; do (bl consult --new --trigger "/tmp/$i" &); done
wait
ls "$BL_VAR_DIR"/../bl-case/CASE-2026-*/ | sort -u
# expect: 2 distinct case-ids

# G14 — curator-mock lives
[[ -f tests/helpers/curator-mock.bash ]] && [[ -f tests/helpers/case-fixture.bash ]] && [[ -f tests/helpers/assert-jsonl.bash ]] && echo "helpers OK"
ls tests/fixtures/ | wc -l
# expect: 11

# G15 — test suite green on debian12 + rocky9
make -C tests test 2>&1 | tail -5
# expect: no "not ok"; aggregate shows all tests passing
make -C tests test-rocky9 2>&1 | tail -5
# expect: same

# G16 — no numeric exit literals in M5 handlers (global sweep)
grep -nE '\b(exit|return) [0-9]+\b' bl | grep -vE 'BL_EX_|return 0|# shellcheck'
# expect: (no output)

# G16 — every M5 function has BL_EX_* citations for nonzero exits
grep -nE '^bl_(consult|run|case)_' bl | head
# (sanity: confirm prefix coverage)
grep -c '^bl_consult' bl
# expect: 5+ (dispatcher + new + attach + sweep_mode + helpers)
grep -c '^bl_run' bl
# expect: 7+
grep -c '^bl_case' bl
# expect: 10+

# Common-helper existence
grep -c '^bl_jq_schema_check\b\|^bl_ledger_append\b\|^bl_files_api_upload\b' bl
# expect: 3
```

---

## 11. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | `flock` not available on minimal containers (alpine/busybox) | `DESIGN.md §14.1` mandates bash 4.1+ / CentOS 6+ / Rocky 8+ / Debian 12+ — all ship `flock(1)` via util-linux. M5 `bl_preflight` addition (runs before first `bl consult`) checks `command -v flock` and exits 65 `PREFLIGHT_FAIL` if missing. Listed as BL deps in `DESIGN.md §14.2` post-M5. |
| R2 | Case-id counter file corruption (`/var/lib/bl/state/case-id-counter`) | flock + atomic rename on every write. Read side: if file is missing or malformed JSON, reset to `{"year":$(date +%Y),"n":0}` with `bl_warn`. Corruption-to-reset is rare; the 30-day memstore ledger (`INDEX.md`) is a reconstruction source — M9 adds a `bl_consult_repair_counter` helper that re-derives the counter from the INDEX.md roster. |
| R3 | Files API rate limit 100 RPM during beta (`docs/managed-agents.md §10`) hits `bl case close` 3-MIME burst | Three uploads per close; 20 concurrent closes/minute across a fleet = 60 RPM, under limit. For bursty fleet-wide close operations, M5 uses the M1 `/var/lib/bl/outbox/` rate-limit queue: on 429 → queue the upload, retry with exponential backoff. Exit 70 `RATE_LIMITED` only after 3 retry cycles. |
| R4 | `bl_api_call` PATCH against memstore with content_sha256 precondition 409s on cross-host concurrent INDEX.md update | Retry up to 3× on 409; re-GET the INDEX.md, re-apply the row mutation, re-submit. On 3-retry exhaust → exit 71 `CONFLICT`. Documented in `docs/managed-agents.md §9` as the expected optimistic-concurrency pattern. |
| R5 | `case-id` allocator disagreement: two hosts allocate `CASE-2026-0008` concurrently with no cross-host lock | Local flock does not coordinate across hosts. Resolution: at `bl_consult_new` end, when `bl_api_call POST` of the new `INDEX.md` row fails with 409 (row already exists for this id from another host), M5 bumps local counter and retries the whole allocation flow. Two hosts converge to distinct ids via the memstore's optimistic concurrency. Exit 71 after 3 retries. |
| R6 | Files API returns `downloadable: false` for wrapper-uploaded MD brief (user-uploaded class), so external API download of the source MD is not available | Per `docs/managed-agents.md §10` contract — wrapper uploads are non-downloadable. Mitigated two ways: (a) agent-produced HTML + PDF files (stage 2 of §7.4) ARE `downloadable: true` and retrievable via `/v1/files/:id/content`; (b) blacklight preserves `/tmp/brief-<case>.md` → `bl-case/CASE-<id>/brief-source.md` in the memstore for local-side re-render. Operator gets true PDF archival via the curator-produced artifact; source-MD archival is in the memstore. |
| R7 | Curator's `report_step` emits arbitrary bash into `args.value` (attacker-reachable content) | Per `schemas/step.md` + `docs/action-tiers.md §5.4` + curator prompt §2 hardening: args values are opaque strings; verb-specific arg-handlers (M4/M6/M7) parse per `schemas/step.md` per-verb key table. No shell expansion in M5; M5 passes args as associative-array-equivalent indexed arrays to handlers. M9 hardening adds injection-corpus tests. |
| R8 | `bl_run_step` dispatches to `bl_observe_*` / `bl_defend_*` / `bl_clean_*` that don't exist yet (parallel worktree merge ordering) | M5 ships with a placeholder dispatch table: known verbs per `schemas/step.json` enum → handler function name. If the handler function is not yet defined (pre-merge state), `bl_run_dispatch_verb` emits `bl_error_envelope run "<verb> handler not yet landed (see M<N>)"` + exits 64. Post-merge, M4/M6/M7 handler bodies satisfy the dispatch. Verification: in M5-only tests, destructive/defend dispatches land in the placeholder; `curator-mock.bash` returns pre-canned results without needing the real handler. |
| R9 | Brief-render failure on 1-of-3 MIMEs leaves `closed.md` with empty-string sentinels that downstream `bl case show` treats as "missing brief" | `closed.md` frontmatter explicitly uses empty-string sentinels (per §4.4 key change 5 + `docs/setup-flow.md §4.2` rationale). `bl case show --brief` prints warning if any sentinel detected: `"brief (pdf): rendering failed; retry via bl case close --retry-brief CASE-... --mime pdf"` (retry flag deferred to M9). Operator-facing behavior is tolerable degradation, not silent loss. |
| R10 | Curator session not yet created (M8 unlands) → `bl_consult_new`'s wake event POST fails | M5 documents that `bl_consult_new` depends on an existing session (created by `bl setup --new-session <case-id>` — M8 deliverable). During M5 dev (pre-M8 merge): if `$BL_SESSION_ID` env var is set, M5 uses it; else `bl_consult_new` emits wake event with a best-effort target + `bl_warn "no bl-curator session; wake event queued"`. Queued events land in `/var/lib/bl/outbox/` for M8's `bl setup` to flush on first run. |
| R11 | `bl_case_close` renders brief → uploads → writes closed.md → INDEX.md update 409s → retry exhausts → exit 71; operator now has `closed.md` locally but INDEX.md says `active`. Half-closed state. | `bl_case_close` checkpoints each phase to `/var/lib/bl/state/close-checkpoint-<case>.json`. Re-run `bl case close` reads the checkpoint and skips completed phases. Exit 71 after 3 retry exhausts is rare (cross-host race on INDEX update); re-run resolves. Documented in §11b edge case 4. |
| R12 | `docs/case-layout.md §3` `open-questions.md must be empty or literal "none"` — curator writes `none\n` but `tail -1` gives `none` only if no trailing newlines; subtle whitespace issues | `bl_case_close_validate_preconditions` uses `tr -d '[:space:]'` on the file content and compares against empty-string or `none` (case-insensitive). Handles whitespace + case + mixed. M2 `case-templates/open-questions.md` tail is `none\n`, matches. |

---

## 11b. Edge cases

| # | Scenario | Expected behavior | Handling |
|---|---|---|---|
| E1 | `bl consult --new --trigger <missing-file>` | Exit 64; trigger artifact must exist if it's a path | `bl_consult_new` tests `[[ -e "$artifact" ]]` for path-like triggers (leading `/` or contains `/`); strings without path separators are treated as event descriptors and hashed directly. |
| E2 | `bl run` without a current case (`$BL_VAR_DIR/state/case.current` empty) | Exit 72; no step to run against unknown case | `bl_run_step` first line: `case=$(bl_case_current); [[ -z "$case" ]] && { bl_error_envelope run "no active case (bl consult --attach <id>)"; return "$BL_EX_NOT_FOUND"; }`. |
| E3 | `bl case close` on case with 0 applied actions | Proceeds to close (no retire schedule entries) | `bl_case_close_schedule_retire` handles empty `actions/applied/` list as no-op; ledger still writes the `case_closed` entry. |
| E4 | `bl case close` partially-landed (closed.md written, INDEX.md update 409-exhausts) | Re-run resolves | Per R11 mitigation; checkpoint state file in `/var/lib/bl/state/close-checkpoint-<case>.json`. |
| E5 | `bl consult --new` twice rapidly on same host | flock serializes; distinct case-ids | Per G12; counter bump is atomic. |
| E6 | `bl_api_call` returns malformed JSON (unexpected beta shape shift) | `bl_jq_schema_check` rejects; exit 67 | Any memstore response that doesn't parse to expected schema logs the body via `bl_debug` and exits 67. No silent acceptance. |
| E7 | Curator emits step with `action_tier: destructive` on a `observe.*` verb | Wrapper overrides to read-only per `docs/action-tiers.md §1`; bl_warn logs the override | `bl_run_evaluate_tier` catches; curator behavior is logged to `/var/lib/bl/ledger/<case>.jsonl` as `policy_event: tier_override_deescalate`. |
| E8 | Curator emits step with verb NOT in enum (e.g., `correlate.timeline`) | schema-check rejects on enum mismatch; exit 67; step never executes | `bl_jq_schema_check` includes enum-membership check. Curator prompt §9 anti-pattern 4 is enforced at the wrapper. |
| E9 | `bl case log` against case with no ledger file yet (case just opened; no writes landed) | Prints only memstore-side events (`case_opened`); no missing-file error | `bl_case_log` treats missing `/var/lib/bl/ledger/<case>.jsonl` as empty-events set, merges just memstore content, sorts by ts. |
| E10 | `bl case reopen` on case with `Status: active` in INDEX.md | Exit 64 with "case is not closed" | `bl_case_reopen` pre-reads INDEX.md row; exits 64 if Status != `closed`. |
| E11 | Files API `application/pdf` upload returns 413 (>500 MB) — unrealistic for brief but defensive | Exit 69; MD+HTML sentinels still populate | Brief-input size cap per `docs/managed-agents.md §10` is 500 MB. Realistic briefs are ~50 KB. 413 indicates a bug in brief-render (e.g., accidentally inlined raw evidence); `bl_warn` with size + exit 69. |
| E12 | `bl consult --sweep-mode` on a workspace with zero closed cases | Prints empty inventory header; exits 0 | `bl_consult_sweep_mode` handles empty list gracefully; no error. |
| E13 | `bl run --batch` on empty pending queue | Prints "no pending steps for current case"; exits 0 | `bl_run_batch` first-line list + exits 0 if empty. |
| E14 | `bl case show` on a reopened case (`Status: reopened` in INDEX, closed-<ts>.md exists) | Renders current active state + section noting previous close-ts | `bl_case_show` GET's `closed-*.md` list; if any present, prints `"previous closures: closed-<ts1>.md, closed-<ts2>.md"` in a 7th section. |
| E15 | `/var/lib/bl/state/` not writable at M5 time (unusual; M1 preflight creates it) | `bl_init_workdir` re-check at each M5 handler entry; exit 65 on writability fail | Preflight creates `state/` per M1; M5 does NOT re-assume writability. Each M5 handler that needs `state/*` writes calls `command touch "$BL_STATE_DIR/.wtest"` defensively on first invocation per-handler; on permission-denied → exit 65. |

---

## 12. Open questions

None. All load-bearing decisions resolved directionally per judging-weights + inherited M0 resolutions. Remaining judgment calls documented explicitly:

1. **`--dedup` semantics for `bl consult --new`** — §5.1 says match on `trigger_fingerprint` + attach to OPEN case only (never closed). Resolved: matching a closed case's fingerprint does NOT trigger dedup — operator should use `bl case reopen` or explicitly `--new` (fresh case). Reviewer reviews; if disagreement, spec updates before build phase lands.
2. **`bl_run_batch` global `--yes`** — §5.2 forbids global `--yes` (batch auto-confirm for destructive). DESIGN.md §5.3 allows `--yes-auto-tier` suggesting per-step auto for auto tier. Resolved: `--yes-auto-tier` maps to "auto-confirm read-only + auto tiers; still prompt for suggested/destructive" — consistent with `docs/action-tiers.md §5.4`. Documented in §9 dead-code table.
3. **Brief rendering — Managed Agents platform vs. local** — §4.4 key change 5 delegates rendering to the platform via Files API. Alternative considered: local render via `pandoc` (MD→PDF). Rejected: pandoc adds a Tier-2 dep not in `DESIGN.md §14.2`; Files-API path is native to the v2 architecture per `DESIGN.md §7.3`; platform rendering is the current beta norm.
4. **`closed.md` brief-source preservation** — R6 deferred-fix notes the user-uploaded `downloadable: false` gotcha. Resolved for M5: upload only; operator recovers via Console. M9/M10 may add local preservation of `/tmp/brief-<case>.md` to `bl-case/CASE-<id>/brief-source.md` if the retrieval gap is a real operator complaint.

---

## 13. Build-posture handoff

- **Plan naming:** `PLAN-M5.md` (excluded per `.git/info/exclude` `PLAN-*.md` glob).
- **Dispatch mode:** worktree-per-motion (Wave 2, parallel with M4/M6/M7/M8). Single worktree; decompose into ~8–10 phases:
  1. Common helpers (`bl_jq_schema_check`, `bl_ledger_append`, `bl_files_api_upload`) land in M1 common-helpers block.
  2. `tests/helpers/curator-mock.bash` + `case-fixture.bash` + `assert-jsonl.bash` + 11 fixtures.
  3. `bl_consult_*` handlers.
  4. `bl_run_step` + tier-gate flow.
  5. `bl_run_batch` + `bl_run_list`.
  6. `bl_case_show` + `bl_case_list` + `bl_case_log`.
  7. `bl_case_close` + `bl_case_reopen`.
  8. `tests/05-consult-run-case.bats` (≥14 `@test` entries).
  9. Verification sweep (G1–G16) + sentinel review.
- **Commit:** single commit on the M5 branch; merges into `main` after Wave-2 sentinel pass. Message: `[New] bl_consult_* + bl_run_* + bl_case_* — M5 case lifecycle + tier-gated step execution`.
- **End condition:** all §10b verification commands pass; `make -C tests test` + `make -C tests test-rocky9` both green; sentinel reviewer approves; no cross-prefix leakage flagged.

---

*End of M5 consult/run/case design spec. Handoff to `/r-plan` for decomposition into phases.*
