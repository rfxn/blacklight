# PLAN.md — blacklight v2 master plan

Drives the spec/plan/build cadence against DESIGN.md. Demo is a later checkbox, not the scoping axis. Human timeline/date constructs are deliberately absent — sequence by dependency, not by calendar.

---

## End-state target (not demo-scoped)

- Operator on any Linux host with bash 4.1+ runs the documented one-liner; `bl setup` provisions their Anthropic workspace (agent, env, memstores, skills).
- `bl consult --new --trigger <artifact>` opens a case. Curator polls pending-steps, operator confirms, wrapper executes, results write back, hypothesis revises, defense payloads author, remediation applies with diff+backup+rollback, case closes to a Files brief with retire schedule.
- All ~22 skills authored to the §9.2 bar.
- Curator hardened against injection per §13.2. Local ledger dual-write per §13.4. Rate-limit outbox per §13.5.
- Repo license-clean, copyright-consistent, `.gitattributes` correct, README a mature public document.

Demo is a later checkbox against this end-state. It adds no product surface, just narrative packaging.

---

## Motion map

```
M0 Contracts (spec-only) ─┐
                          │
                          ├──► M1 bl skeleton ──┬──► M4 observe ──┐
                          │                     │                 ├──► M5.5 component split ──┬──► M6 defend
                          │                     └──► M5 ──────────┘                            ├──► M7 clean         ──┐
                          │                                                                    └──► M8 setup            │
                          │                                                                                             │
                          ├──► M2 case templates ──────────────────────────────────────────────────────────────────────┤
                          │                                                                                             ├──► M9 hardening ──► M10 ship-ready
                          └──► M3 knowledge (skills + prompt) ────────────────────────────────────────────────────────┘
                                                                                                                      (M11 demo deferred)
```

| # | Motion | Depends on | Posture | Parallel-safe with |
|---|---|---|---|---|
| M0 | Shared contracts + setup-flow spec | — | spec-only | — (solo gate) |
| M1 | `bl` skeleton (dispatcher, preflight, poll loop, helpers) | M0 | plan | M2, M3 |
| M2 | Case-memstore scaffolding templates | M0 | plan | M1, M3 |
| M3 | Knowledge surface (skills + curator prompt) | M0 | plan | M1, M2 (and everything) |
| M4 | `bl observe` all verbs + bundle builder | M1 | plan | M2, M3, any other `bl` worktree |
| M5 | `bl consult` + `bl run` + `bl case` | M1, M2 | plan | M2, M3, other `bl` worktrees |
| M5.5 | Component extraction — `src/bl.d/` parts + assembly | M4, M5 | plan | (solo — merge-gate before M6/M7/M8) |
| M6 | `bl defend` | M1, M5.5 | plan | M7, M8 (disjoint part files) |
| M7 | `bl clean` | M1, M5.5 | plan | M6, M8 |
| M8 | `bl setup` implementation | M1, M0, M5.5 | plan | M6, M7 |
| M9 | Security hardening pass — **DONE** (`6595cda..eb6e4f3`) | M4, M5, M3 | spec-then-plan | (solo) |
| M10 | Ship-ready (README, install, packaging) | M9 | plan | (solo) |
| M11 | Demo + narrative | M10 | deferred | — |

**File-ownership contract for parallel `bl` work:**
- **Pre-M5.5 (M4 + M5):** each motion owns a disjoint function prefix (`bl_observe_*`, `bl_consult_*`, `bl_run_*`, `bl_case_*`) inside monolithic `bl`. Merge conflicts limited to shared helpers — resolvable, but real (commit `795bb5d` was a near-miss from the M4+M5 merge).
- **Post-M5.5 (M6 + M7 + M8 + M9):** each motion owns a disjoint `src/bl.d/NN-<motion>.sh` part file. Zero source-file overlap. Merge conflict surface collapses to the assembled `bl` itself, resolved by rerunning `make bl` post-merge. M1's dispatcher in `src/bl.d/90-main.sh` is pre-seeded with all namespace entries from M5.5 onward.

**Test accretion contract:** M0 lands `tests/` via batsman (submodule at `tests/infra/`) + 1 smoke test. Every motion after M0 adds one `.bats` file (numbered to match: `01-cli-surface`, `02-preflight`, `04-observe`, `05-consult-run-case`, `06-defend`, `07-clean`, `08-setup`, `09-hardening`, `10-install-paths`). **Exception:** M5.5 is a pure-mechanical refactor and adds no new `.bats` — it passes iff the existing M0–M5 suite stays green byte-identical. Pre-commit minimum for every motion: `make -C tests test` + `make -C tests test-rocky9` both green. No live Anthropic API in CI — `curator-mock.bash` + `tests/fixtures/` are the contract.

**Shared-lib adoptions:**
- `batsman` (submodule `tests/infra/`) — M0 wires; all subsequent motions consume.
- `pkg_lib` (install-time only; never sourced by runtime `bl`) — M10 consumes for OS-family detection + RPM/DEB packaging.
- No other rfxn `_lib` is in scope. New adoptions go through CLAUDE.md §License & origin before landing.

---

## 3-session dispatch schedule

```
Wave 0    (solo)              M0
Wave 1    (3 parallel)        M1  +  M2  +  M3
Wave 2    (2 parallel)        M4  +  M5                ⎫  after M1 + M2 land
Wave 2.5  (solo, merge gate)  M5.5                     ⎬  post-M4+M5 merge — component extraction
Wave 3    (3 parallel)        M6  +  M7  +  M8         ⎭  disjoint src/bl.d/ part files
Wave 4    (solo)              M9
Wave 5    (solo)              M10
Wave 6    (later)             M11
```

Merge cadence: after each wave closes, single-operator merge of the worktrees back to `main`. Next wave dispatches from the merged state. Wave 2.5 is the structural gate — Wave 3 parallelism is only safe once `src/bl.d/` exists and `make bl` is the canonical build step.

---

## Per-motion dispatch sketches

### M0 — Contracts (solo)

**Scope:** Lock shared contracts before any build fans out.

**Deliverables:**
- `schemas/step.json` — step-emit JSON schema (verb, args, action_tier, reasoning, diff, patch). Live-beta safe (no `oneOf`, no `minimum/maximum`, `additionalProperties: false`, array-of-keyed-maps for dict shapes).
- `schemas/evidence-envelope.md` — JSONL record preamble + source taxonomy (apache.transfer, modsec.audit, cron.user, fs.mtime-cluster, proc.verify, htaccess.walk, firewall.rule, sig.loaded, file.stat).
- `docs/action-tiers.md` — the 5-tier table with gate-behavior and authoring rules, promoted from DESIGN.md §6.
- `docs/setup-flow.md` — `bl setup` API call sequence spec: endpoints, headers, request bodies, expected responses, idempotency checks, error envelope. MUST re-probe Managed Agents beta live and resolve DESIGN.md §12.1 ⇄ MEMORY.md contradiction (agent `thinking`/`output_config` kwargs vs custom-tool pattern). Update DESIGN.md §12.1 or MEMORY.md in the same commit based on probe result.
- `docs/case-layout.md` — canonical per-case memstore directory contract (promoted + expanded from §7.2).
- `docs/exit-codes.md` — exit code taxonomy for `bl` (0=ok, 64=usage, 65=preflight fail, 66=workspace not seeded, 67=schema validation fail, 68=tier-gate denied, …).
- `tests/` scaffold:
  - `tests/infra/` — batsman submodule pinned to a release tag (`git submodule add https://github.com/rfxn/batsman.git tests/infra`).
  - `tests/Makefile` — sets `BATSMAN_PROJECT := blacklight`, `BATSMAN_OS_MODERN/LEGACY/EXTRA` per project CLAUDE.md Testing matrix, `include infra/include/Makefile.tests`.
  - `tests/run-tests.sh` — thin ~25-line batsman wrapper (pattern from `advanced-policy-firewall/tests/run-tests.sh`); no `--privileged` by default.
  - `tests/Dockerfile` — layers `bash curl jq awk sed tar gzip zstd coreutils` on batsman's debian12 base.
  - `tests/helpers/curator-mock.bash` — curl-shim returning fixture JSON for pending-steps poll + wake events. No live API in CI.
  - `tests/helpers/case-fixture.bash` — seeds `/var/lib/bl/{backups,quarantine,state,outbox,ledger}` + bl-case memstore layout in the container.
  - `tests/helpers/assert-jsonl.bash` — `jq`-based schema validation against `schemas/step.json` and `schemas/evidence-envelope.md`.
  - `tests/fixtures/step-*.json` — one fixture per action tier (read-only, auto, suggested, destructive, root-only).
  - `tests/00-smoke.bats` — single smoke test asserting `bash -n bl` + placeholder exit code; this is the floor everything else builds on.

**Ends when:** all seven artifact groups committed; DESIGN.md §12.1 and MEMORY.md in agreement; `make -C tests test` runs `00-smoke.bats` green on debian12 + rocky9.

---

### M1 — `bl` skeleton (solo)

**Scope:** The `bl` script frame that all handlers plug into.

**Deliverables:**
- `bl` with:
  - Shebang + version constant + license/copyright header
  - `bl_preflight()` per DESIGN.md §8.1 (probe workspace, cache agent-id, bootstrap error message)
  - Top-level dispatcher case statement with entries for all 7 namespaces routing to handler functions (handler functions declared empty, returning 64)
  - `--help`, `--version`, `-h`, `-v` surfaces
  - Common helpers: JSON API call wrapper (curl + jq + retry + backoff), logging (stderr at levels), error envelope formatter, step-poll loop skeleton (`bl_poll_pending`), `bl_case_current()` reading `/var/lib/bl/state/case.current`
  - `/var/lib/bl/` lazy init (`backups/`, `quarantine/`, `fp-corpus/`, `state/`, `outbox/`, `ledger/`)
- `bash -n` + `shellcheck` clean
- `tests/01-cli-surface.bats` — `--help`, `--version`, dispatcher routing for every namespace, exit codes per `docs/exit-codes.md`
- `tests/02-preflight.bats` — seeded-workspace success path, unseeded-workspace bootstrap-message path, partial-state recovery path

**Ends when:** `bl help` and `bl --version` work; every known namespace dispatches to its named-but-empty handler; preflight gives the correct message on unseeded workspaces; `make -C tests test` green on debian12 + rocky9.

---

### M2 — Case templates (solo, parallel with M1)

**Scope:** The per-case file skeletons the curator writes into on case open.

**Deliverables:**
- `case-templates/hypothesis.md` — seed (hypothesis + confidence + reasoning sections)
- `case-templates/open-questions.md` — seed
- `case-templates/attribution.md` — seed (kill-chain stanza headers)
- `case-templates/ip-clusters.md`, `url-patterns.md`, `file-patterns.md` — seeds keyed to §9.1 `ioc-aggregation/*` skills
- `case-templates/defense-hits.md` — append-log seed
- `case-templates/closed.md` — closed-case schema (brief file_ids, retirement schedule)
- `case-templates/INDEX.md` — workspace roster template
- `case-templates/README.md` — tells `bl_consult` which files to seed on case open

**Ends when:** templates match `docs/case-layout.md` contract exactly.

---

### M3 — Knowledge surface (solo, fully parallel)

**Scope:** Curator system prompt + full skills bundle.

**Deliverables:**
- `prompts/curator-agent.md`:
  - Injection-hardening preamble (§13.2 taxonomy: ignore-previous, role reassignment, schema override, verdict flip)
  - Step-emit contract citing `schemas/step.json`
  - Tier-authoring heuristics (when to mark a step `destructive` vs `suggested` vs `auto`)
  - Hypothesis revision instructions
  - Case-close criteria (open-questions resolved)
  - Synthesizer/intent-reconstructor invocation patterns
  - Read-first-ordering: summary.md → bl-skills/INDEX.md → bl-case/hypothesis.md → drill into evidence
- `skills/INDEX.md` (router)
- All 22 files from §9.1, each meeting §9.2 quality bar (scenario-first, non-obvious rule, public APSB25-94 example, failure mode). Grounded with operator-local shape-check only — never copy.
- Where a skill genuinely needs tribal knowledge to be non-slop, commit a skeleton with a `TODO(gap):` header naming the specific gap. Surface the list of gaps at end of motion.

**Ends when:** 22 files committed; INDEX references all of them; TODO gap list surfaced to operator.

---

### M4 — `bl observe` (worktree, post-M1)

**Scope:** DESIGN.md §5.1 — all observe verbs + evidence bundle builder (§10.2).

**Deliverables:**
- `bl_observe_*` functions: file, log-apache, log-modsec, log-journal, cron, proc (with `--verify-argv`), htaccess, fs-mtime-cluster, fs-mtime-since, firewall, sigs
- `bl_bundle_build()` — tar+gzip/zstd packager per §10.2 with MANIFEST.json + summary.md
- JSONL emissions conforming to `schemas/evidence-envelope.md`
- Each observe auto-runs (read-only tier), writes to `bl-case/evidence/obs-<ts>-<kind>.json`
- `tests/04-observe.bats` — one test group per verb; happy-path + malformed-input + schema-conformance via `assert-jsonl.bash`; log fixtures under `tests/fixtures/` (synthetic APSB25-94-shaped apache.log, modsec.log, cron contents, .htaccess samples)

**Ends when:** each `bl_observe_*` verb passes its test group green on debian12; bundle builder produces a tar with MANIFEST.json that `jq` parses clean.

---

### M5 — `bl consult` + `bl run` + `bl case` (worktree, post-M1+M2)

**Scope:** Case lifecycle — DESIGN.md §5.2, §5.3, §5.6.

**Deliverables:**
- `bl_consult_*`: --new, --attach, --sweep-mode (+ case-id allocation, trigger fingerprinting, seed templates from M2)
- `bl_run_*`: step-id, --batch, --list. Step-JSON validation (jq schema from M0). Tier enforcement from `docs/action-tiers.md`. Diff/explain/abort prompt.
- `bl_case_*`: show, log, list, close, reopen. Case close renders brief via Files API (PDF/HTML/MD), writes `closed.md`, schedules retire sweep.
- `tests/05-consult-run-case.bats` — fixture-driven: `curator-mock.bash` serves pending-steps from `tests/fixtures/step-*.json`; asserts tier-gate rejects destructive without `--yes`, schema-fail rejects malformed step, batch runs respect tier boundaries, case close writes `closed.md` + schedules retire.

**Ends when:** full mocked case lifecycle (new → observe batch → run → close) passes green; tier-gate matrix exhaustively covered.

---

### M5.5 — Component extraction (solo, post-M4+M5)

**Scope:** Pure-mechanical refactor. Decompose the monolithic `bl` (~3k LOC at end of Wave 2, projected ~4.5k by Wave 3) into numbered source parts assembled to a single shippable file at build time. Zero behavior change. Resolves open-call #2 (single-file vs assembled).

**Why this phase exists:**
- Post-M5, `bl` is 3048 LOC. M6+M7+M8 project to 4000+. Past the single-file review-load ceiling; every subsequent motion's diff skims worse, and Sentinel/QA passes get slower because context now re-loads the whole file.
- Wave 2 already produced a duplicate-stub near-miss (`795bb5d`) from M4+M5 merge. Wave 3 with three motions + monolithic `bl` multiplies that risk.
- Curl-pipe-bash install (DESIGN.md §8.3, M10) forbids runtime `source lib/*.sh` — `install.sh | bash` fetches a single `bl` from GitHub and cannot bring sibling files. **Build-time assembly** is the only shape that gets both maintainability and single-file ship.
- Weights check: Impact +1 (v2 continuation maintainability), Depth +1 (repo-skim legibility for judges). Two weights raised → passes the build-decision test.

**Shape — assembled at build time, single file shipped:**
- Edit: `src/bl.d/NN-*.sh` (numeric-prefix concat order, numeric sort).
- Build: `make bl` concatenates parts → writes `bl` at repo root.
- Ship: `bl` is committed. `install.sh` curl-fetches it unchanged.
- Drift guard: `make bl-check` fails if committed `bl` ≠ `make bl` output. Invoked by `make -C tests test` and by `make -C tests test-rocky9`.

**Deliverables:**

`src/bl.d/` layout (function counts from current `bl`):

| Part file | Content | Source LOC |
|-----------|---------|------------|
| `00-header.sh` | shebang, license header, `set -euo pipefail`, SC2094 directive, version + exit-code constants, bash 4.1+ floor check, path constants | ~60 |
| `10-log.sh` | `_bl_log_level_allows`, `bl_debug/info/warn/error`, `bl_error_envelope` | ~35 |
| `15-workdir.sh` | `bl_init_workdir`, `bl_case_current` | ~35 |
| `20-api.sh` | `bl_api_call`, `bl_poll_pending`, `bl_jq_schema_check`, `bl_files_api_upload` | ~220 |
| `25-ledger.sh` | `bl_ledger_append` | ~35 |
| `30-preflight.sh` | `bl_preflight`, `bl_usage`, `bl_version` | ~110 |
| `40-observe-helpers.sh` | 10 private `_bl_obs_*` helpers | ~180 |
| `41-observe-collectors.sh` | 11 `bl_observe_*` source handlers | ~1200 |
| `42-observe-router.sh` | `bl_observe` router + `bl_bundle_build` | ~260 |
| `50-consult.sh` | 9 `bl_consult_*` functions + router | ~300 |
| `60-run.sh` | 8 `bl_run_*` functions + router | ~290 |
| `70-case.sh` | 11 `bl_case_*` functions + router | ~350 |
| `80-stubs.sh` | `bl_defend`, `bl_clean`, `bl_setup` stubs (replaced by M6/M7/M8 with `82-defend.sh`, `83-clean.sh`, `84-setup.sh`) | ~25 |
| `90-main.sh` | `main()` dispatcher + final `main "$@"` | ~40 |

Generated `bl` at repo root:
- First two lines: shebang + `# GENERATED FILE — edit src/bl.d/NN-*.sh and run 'make bl'`.
- Followed by `# --- src/bl.d/NN-*.sh ---` separators before each part.
- Byte-identical to `make bl` output; `chmod +x`.

Root `Makefile` targets:
- `make bl` — assemble parts → `bl`; creates or updates.
- `make bl-check` — fail if drift between committed `bl` and `make bl` output; pass silently if parts missing (pre-M5.5 compatibility).
- `make bl-lint` — `bash -n bl` + `shellcheck bl` on assembled artifact.
- `make test` / `make test-rocky9` / `make test-all` — delegate to `tests/Makefile`.

`tests/Makefile` hook:
- `test` and `test-rocky9` targets gain an implicit `bl-check` dependency — drift fails test run before container build.

`scripts/assemble-bl.sh`:
- ~30-line bash script. Numeric-sorts `src/bl.d/[0-9]*.sh`, emits shebang + generated-banner, concatenates each part with a `# --- <path> ---` separator, strips part-local shebangs (if any).
- Exits 1 with clear message if `src/bl.d/` empty.

**Discipline primitives (committed alongside, active from merge):**
- Project `CLAUDE.md` gains a "`bl` source layout" section — the one-line rule: *"Never edit `bl` directly. Edit `src/bl.d/NN-*.sh` and run `make bl`. Commit both."*
- `bl` header banner reinforces it for anyone opening the file.
- `make bl-check` hard-fails any commit where parts drifted — operator sees the exact message "src/bl.d/ drifted from bl — run 'make bl' and re-commit".

**Tests:** No new `.bats` file. Refactor succeeds iff:
- Every existing `.bats` in `tests/00–05-*.bats` passes green on debian12 + rocky9 without fixture changes.
- `make bl-check` green.
- `make bl-lint` green (equivalent to pre-refactor `bash -n bl` + `shellcheck bl` against the assembled output).
- `diff <(cat src/bl.d/[0-9]*.sh | <assemble-transform>) bl` returns zero.

Any test delta = refactor introduced a bug; bisect the drift by comparing pre/post function bodies.

**Merge gate before Wave 3:** Wave 3 (M6+M7+M8) cannot dispatch until M5.5 merges. Wave 3 engineer briefs explicitly name the target part file (`src/bl.d/82-defend.sh` for M6, etc.); briefs also mandate `git commit -- src/bl.d/<part> bl Makefile` to keep commit attribution scoped (lesson from `57a699e` Wave 1 violation).

**Ends when:**
- `src/bl.d/` populated with 14 numbered part files (three of which — `bl_defend`/`bl_clean`/`bl_setup` inside `80-stubs.sh` — are temporary stubs replaced by M6/M7/M8 via dedicated `82-defend.sh`/`83-clean.sh`/`84-setup.sh` files).
- `bl` regenerates byte-exact from `make bl`; committed.
- `make bl-check` + `make bl-lint` green.
- Existing `tests/00–05-*.bats` green on debian12 + rocky9 without change.
- `CLAUDE.md` discipline rule active; `tests/Makefile` wired to `bl-check`.
- PLAN.md open-call #2 crossed out with pointer to this phase.

---

### M6 — `bl defend` (worktree, post-M1)

**Scope:** DESIGN.md §5.4.

**Deliverables:**
- `bl_defend_modsec`: rule copy → `apachectl configtest` → symlink swap → graceful reload; rollback on fail; `--remove` path
- `bl_defend_firewall`: backend detection (APF/CSF/iptables/nftables), CDN safe-list check (ASN lookup + cache), apply with case-tag comment, ledger entry with retire-hint
- `bl_defend_sig`: scanner detection (LMD/ClamAV/YARA), corpus FP gate against `/var/lib/bl/fp-corpus/`, append-and-reload
- `tests/06-defend.bats` — `tests/Dockerfile.m6` adds `apache2 mod_security2 iptables nftables yara` (privileged for netfilter tests); happy-path apply, configtest-fail rollback, FP-gate-trip reject, CDN safe-list bypass

**Ends when:** all three defend verbs pass green; rollback paths verified under deliberate failure injection.

---

### M7 — `bl clean` (worktree, post-M1)

**Scope:** DESIGN.md §5.5 + §11 safety disciplines.

**Deliverables:**
- `bl_clean_htaccess`, `bl_clean_cron` — diff display, `diff-full`/`explain`/`abort` prompt, backup to `/var/lib/bl/backups/<ISO>.<hash>.<basename>`, apply
- `bl_clean_proc` — `/proc/<pid>/*` + lsof capture to case evidence; SIGTERM → SIGKILL with grace window
- `bl_clean_file` — move to `/var/lib/bl/quarantine/<case>/<sha>-<basename>` with manifest entry; never unlink
- `--dry-run` contract on all four (enforced: dry-run success required before live apply)
- `bl clean --undo <backup-id>` and `bl clean --unquarantine <entry>` restore paths
- `tests/07-clean.bats` — each clean verb: dry-run-before-apply enforcement, backup integrity (sha256 matches pre-apply), undo restores exact bytes, unquarantine restores path + perms + owner; proc-kill grace window

**Ends when:** every verb has a roundtrip test (apply → undo → byte-identical); quarantine manifest schema-validates.

---

### M8 — `bl setup` implementation (worktree, post-M1+M0)

**Scope:** DESIGN.md §8.2–§8.5 per the `docs/setup-flow.md` spec from M0.

**Deliverables:**
- `bl_setup_*` functions: agent create (reconciled with MA SDK shape from M0), env create, memstores create, skills seed (MANIFEST.json sha256 delta tracking), --sync, --check
- Source-of-truth resolution: cwd → `$BL_REPO_URL` → default GitHub clone to `$XDG_CACHE_HOME/blacklight/repo`
- Persist IDs to `/var/lib/bl/state/{agent-id,env-id,memstore-skills-id,memstore-case-id}`
- Idempotency: re-run produces clean no-op with summary
- `tests/08-setup.bats` — curator-mock serves API responses per `docs/setup-flow.md`; assert `--check` detects each partial-state combination (agent-only, agent+env, agent+env+one-memstore), `--sync` updates skills hashes on fixture delta, `bl setup` twice back-to-back produces no-op summary

**Ends when:** partial-state matrix covered; skills-delta fixture produces expected sync summary; idempotency roundtrip green.

---

### M9 — Security hardening pass (solo, post-M4+M5+M3) — **COMPLETE**

**Status:** shipped 2026-04-24 — commits `6595cda..eb6e4f3` (P1-P8 build + P9 sentinel fixup). Tests 168/168 green debian12+rocky9.
**Spec:** `docs/specs/2026-04-24-M9-hardening-impl.md` (commit `3b24937`).
**Plan:** `PLAN-M9.md` (working file; not committed).
**Sentinel:** CONCERNS verdict, 0 MUST-FIX + 6 SHOULD-FIX + 2 INFO — all SHOULD-FIX cleared in P9 fixup `eb6e4f3`; INFO 2 (step_id pattern guard) deferred to M11+.

**Delivered:**
- Fence primitive (`src/bl.d/26-fence.sh`) — derive/wrap/unwrap/kind with token-bound `</untrusted-TOKEN>` close tag (closes payload-escape surface)
- Outbox primitives (`src/bl.d/27-outbox.sh`) — enqueue/drain/depth/oldest_age, backpressure (HIGH=1000), per-kind schemas (wake/signal_upload/action_mirror)
- Ledger schema (`schemas/ledger-event.json`, 18 kinds) + validated `bl_ledger_append` + `bl_ledger_mirror_remote` (best-effort dual-write to `bl-case/actions/applied/`)
- Run writeback fence-wrap + result envelope schema (`schemas/result.json`)
- Consult wake migration to `bl_outbox_enqueue` + fenced trigger
- `bl flush --outbox` CLI verb
- 4-class injection corpus (`tests/fixtures/injection-corpus/`) + 29-test hardening suite
- Cycle-break invariants verified at every call site (enqueue/mirror/drain)

**Original scope (preserved for reference):** Lift DESIGN.md §13 from spec to implementation. Spec-then-plan: spec at `docs/specs/2026-04-24-M9-hardening-impl.md`, plan at `PLAN-M9.md`. Tests: `tests/09-hardening.bats` injection corpus per §13.2 taxonomy (ignore-previous, role-reassignment, schema-override, verdict-flip).

---

### M10 — Ship-ready (solo, post-M9)

**Scope:** Repo polish + install path + packaged releases + public-face README.

**Deliverables:**
- `README.md` final: hero pitch + payoff + install block + "Why Managed Agents" + "Why Opus 4.7 + 1M" + skills-architecture reference + try-it walkthrough + model-choice rationale + FUTURE.md pointer. Lead with pain, never with AI.
- `install.sh` one-shot installer (curl-pipe-bash safe; verifies bash ≥4.1, curl, jq; copies `bl` to `/usr/local/bin/bl`; `bl setup` invocation prompt). Uses `pkg_lib` for OS-family detection + FHS install paths — not hand-rolled.
- `uninstall.sh` (remove binary, `/var/lib/bl/` with confirm, preserve backups) — also through `pkg_lib`.
- `pkg/` directory with `pkg_lib`-driven RPM spec + DEB rules + symlink manifest. Consumed pattern: `pkg_lib` is sourced at package-build time only (never by runtime `bl`). See `advanced-policy-firewall/pkg/` for the canonical shape.
- Packaged release validation: `.rpm` installs clean on rocky9 + centos7; `.deb` installs clean on debian12 + ubuntu2404; post-install `bl --version` + `bl setup --check` green on all four.
- Copyright header audit (every source file; current year only for new files)
- `.gitattributes` audit (export-ignore for dev-only paths including `pkg/` + `tests/`)
- LICENSE verification (GPL v2 at root)
- `bl --version` reports pinned version string grepped from `bl` source
- `bl --help` + subcommand help surfaces polished
- `tests/10-install-paths.bats` — install.sh → `bl --version` + uninstall.sh roundtrip; run per-OS to catch install-time path divergence that Docker-layered tests miss.

---

### M11 — Demo (deferred)

Picks up after M10. Fixture envelope + script + recording + 100–200 word summary. Scoped when we get there.

---

## Open calls — resolve before dispatching M0

Two calls. Both have reasonable defaults, but either could reshape downstream work:

1. **Fence-token scope** (relevant to M9, but contract surface touches M0): is fence-token derivation per-case or per-payload? Per-payload is stronger (attacker can't reuse a witnessed fence across payloads) but makes the curator prompt longer and less cache-friendly. Per-case is cheaper and still forges-resistant at 64-bit entropy.
2. ~~**`bl` single-file vs assembled-file**~~ — **RESOLVED → assembled at build time from `src/bl.d/NN-*.sh` parts; shipped `bl` at repo root is a single committed artifact generated by `make bl`.** Rationale: curl-pipe-bash install (DESIGN.md §8.3, M10) forbids runtime sourcing, but 3k+ LOC single-file review load is unsustainable past M5. Build-time assembly gets both. Wave 2 (M4+M5) proceeds with monolithic `bl` as originally planned; Wave 2.5 (M5.5) refactors; Wave 3 (M6+M7+M8) dispatches onto `src/bl.d/`. See M5.5 for layout.

Once those two are locked, M0 is fully dispatch-ready.
