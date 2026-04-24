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
                          ├──► M1 bl skeleton ──┬──► M4 observe
                          │                     ├──► M5 consult/run/case ──┐
                          │                     ├──► M6 defend             │
                          │                     ├──► M7 clean              │
                          │                     └──► M8 setup              │
                          │                                                 │
                          ├──► M2 case templates ───────────────────────────┤
                          │                                                 ├──► M9 hardening ──► M10 ship-ready
                          └──► M3 knowledge (skills + prompt) ──────────────┘
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
| M6 | `bl defend` | M1 | plan | same |
| M7 | `bl clean` | M1 | plan | same |
| M8 | `bl setup` implementation | M1, M0 | plan | same |
| M9 | Security hardening pass | M4, M5, M3 | spec-then-plan | (solo) |
| M10 | Ship-ready (README, install, packaging) | M9 | plan | (solo) |
| M11 | Demo + narrative | M10 | deferred | — |

**File-ownership contract for parallel `bl` work (M4–M8):** each motion owns a disjoint function prefix (`bl_observe_*`, `bl_defend_*`, `bl_clean_*`, `bl_consult_*`, `bl_run_*`, `bl_case_*`, `bl_setup_*`). M1 pre-seeds the dispatcher case statement with all namespace entries pointing to their handler. Each subsequent motion runs in its own worktree, adds its handler functions, merges back. Merge conflicts are limited to shared helpers — resolvable.

---

## 3-session dispatch schedule

```
Wave 0  (solo)              M0
Wave 1  (3 parallel)        M1  +  M2  +  M3
Wave 2  (3 parallel)        M4  +  M5  +  M6        ⎫  after M1 + M2 land
Wave 3  (2 parallel)        M7  +  M8               ⎬  worktrees on bl; merge between waves
Wave 4  (solo)              M9
Wave 5  (solo)              M10
Wave 6  (later)             M11
```

Merge cadence: after each wave closes, single-operator merge of the worktrees back to `main`. Next wave dispatches from the merged state.

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

**Ends when:** all six artifacts committed; DESIGN.md §12.1 and MEMORY.md in agreement.

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

**Ends when:** `bl help` and `bl --version` work; every known namespace dispatches to its named-but-empty handler; preflight gives the correct message on unseeded workspaces.

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

---

### M5 — `bl consult` + `bl run` + `bl case` (worktree, post-M1+M2)

**Scope:** Case lifecycle — DESIGN.md §5.2, §5.3, §5.6.

**Deliverables:**
- `bl_consult_*`: --new, --attach, --sweep-mode (+ case-id allocation, trigger fingerprinting, seed templates from M2)
- `bl_run_*`: step-id, --batch, --list. Step-JSON validation (jq schema from M0). Tier enforcement from `docs/action-tiers.md`. Diff/explain/abort prompt.
- `bl_case_*`: show, log, list, close, reopen. Case close renders brief via Files API (PDF/HTML/MD), writes `closed.md`, schedules retire sweep.

---

### M6 — `bl defend` (worktree, post-M1)

**Scope:** DESIGN.md §5.4.

**Deliverables:**
- `bl_defend_modsec`: rule copy → `apachectl configtest` → symlink swap → graceful reload; rollback on fail; `--remove` path
- `bl_defend_firewall`: backend detection (APF/CSF/iptables/nftables), CDN safe-list check (ASN lookup + cache), apply with case-tag comment, ledger entry with retire-hint
- `bl_defend_sig`: scanner detection (LMD/ClamAV/YARA), corpus FP gate against `/var/lib/bl/fp-corpus/`, append-and-reload

---

### M7 — `bl clean` (worktree, post-M1)

**Scope:** DESIGN.md §5.5 + §11 safety disciplines.

**Deliverables:**
- `bl_clean_htaccess`, `bl_clean_cron` — diff display, `diff-full`/`explain`/`abort` prompt, backup to `/var/lib/bl/backups/<ISO>.<hash>.<basename>`, apply
- `bl_clean_proc` — `/proc/<pid>/*` + lsof capture to case evidence; SIGTERM → SIGKILL with grace window
- `bl_clean_file` — move to `/var/lib/bl/quarantine/<case>/<sha>-<basename>` with manifest entry; never unlink
- `--dry-run` contract on all four (enforced: dry-run success required before live apply)
- `bl clean --undo <backup-id>` and `bl clean --unquarantine <entry>` restore paths

---

### M8 — `bl setup` implementation (worktree, post-M1+M0)

**Scope:** DESIGN.md §8.2–§8.5 per the `docs/setup-flow.md` spec from M0.

**Deliverables:**
- `bl_setup_*` functions: agent create (reconciled with MA SDK shape from M0), env create, memstores create, skills seed (MANIFEST.json sha256 delta tracking), --sync, --check
- Source-of-truth resolution: cwd → `$BL_REPO_URL` → default GitHub clone to `$XDG_CACHE_HOME/blacklight/repo`
- Persist IDs to `/var/lib/bl/state/{agent-id,env-id,memstore-skills-id,memstore-case-id}`
- Idempotency: re-run produces clean no-op with summary

---

### M9 — Security hardening pass (solo, post-M4+M5+M3)

**Scope:** Lift DESIGN.md §13 from spec to implementation. This is a cross-cutting pass — new spec needed for implementation-level details.

**Spec-then-plan deliverables:**

Spec first (`docs/hardening-impl.md`):
- Fence token derivation: `sha256(case_id||payload||nonce)[:16]` — exact format, where it's generated, where it's verified
- Untrusted-content wrapping format on evidence records (prefix/suffix, escape rules for the fence token inside the wrapped content)
- jq schema-check invocation pattern for step emissions at `bl run` entry
- Local ledger JSONL shape at `/var/lib/bl/ledger/<case-id>.jsonl`; sync semantics with `bl-case/actions/applied/`
- Rate-limit queue: `outbox/` filename convention, drain policy, backpressure

Plan implements the spec against existing M4/M5/M3 code.

---

### M10 — Ship-ready (solo, post-M9)

**Scope:** Repo polish + install path + public-face README.

**Deliverables:**
- `README.md` final: hero pitch + payoff + install block + "Why Managed Agents" + "Why Opus 4.7 + 1M" + skills-architecture reference + try-it walkthrough + model-choice rationale + FUTURE.md pointer. Lead with pain, never with AI.
- `install.sh` one-shot installer (curl-pipe-bash safe; verifies bash ≥4.1, curl, jq; copies `bl` to `/usr/local/bin/bl`; `bl setup` invocation prompt)
- `uninstall.sh` (remove binary, `/var/lib/bl/` with confirm, preserve backups)
- Copyright header audit (every source file; current year only for new files)
- `.gitattributes` audit (export-ignore for dev-only paths)
- LICENSE verification (GPL v2 at root)
- `bl --version` reports pinned version string grepped from `bl` source
- `bl --help` + subcommand help surfaces polished

---

### M11 — Demo (deferred)

Picks up after M10. Fixture envelope + script + recording + 100–200 word summary. Scoped when we get there.

---

## Open calls — resolve before dispatching M0

Two calls. Both have reasonable defaults, but either could reshape downstream work:

1. **Fence-token scope** (relevant to M9, but contract surface touches M0): is fence-token derivation per-case or per-payload? Per-payload is stronger (attacker can't reuse a witnessed fence across payloads) but makes the curator prompt longer and less cache-friendly. Per-case is cheaper and still forges-resistant at 64-bit entropy.
2. **`bl` single-file vs assembled-file**: DESIGN.md §5.8 is ambiguous. Is the shipped `bl` literally one source file, or is it concatenated at install from `files/bl.d/*.sh` parts? Assembled is lower merge-risk for parallel motions; single-file is simpler for operators reading the source. Decides the worktree layout for Waves 2–3.

Once those two are locked, M0 is fully dispatch-ready.
