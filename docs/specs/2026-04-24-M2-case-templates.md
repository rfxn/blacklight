# M2 — Case templates (blacklight v2 case-open skeleton)

**Spec date:** 2026-04-24
**Author:** clean-room, operator-absent autonomous progression per CLAUDE.md §Execution posture
**Plan target:** PLAN-M2.md (excluded from tracking per `.git/info/exclude` PLAN*.md glob)
**Wave:** 1 (parallel-safe with M1 `bl` skeleton, M3 knowledge surface) — PLAN.md "Per-motion dispatch sketches" §M2

---

## 1. Problem statement

blacklight v2's case memory store (`bl-case/`) has a locked contract at `docs/case-layout.md` (234 lines, committed at M0 commit `4ec1c23`), but no templates exist on disk. Without templates, the M5 `bl_case_new` handler (wave-2 deliverable) has nothing to seed when `bl case --new` opens a case — and the curator's first `report_step` emit finds a blank memory store where hypothesis context, attribution state, and evidence pointer files are expected.

Concretely:

- `ls /root/admin/work/proj/blacklight/case-templates/` → directory does not exist.
- `grep -l 'writer:' case-templates/*.md 2>/dev/null | wc -l` → `0`.
- `case-layout.md` §3 writer-owner table enumerates 18 distinct paths (17 if `STEP_COUNTER` is excluded per NG2); 8 of these are file templates that must materialize on case-open (§5 "empty skeleton templates materialized (per M2)"); 1 more (`closed.md`) is a schema stub that never seeds on open but must exist as a reference file so the M5 `bl_case_close` handler (wave-2) can consult its shape.
- `case-layout.md` §11 change-control says "additions to the tree require M2 template update if on-open-materialized" — M2 is the forward-declared owner of this surface.

Any downstream motion depending on case-open state (M5 `bl consult`/`bl run`/`bl case`, M6 `bl defend`, M7 `bl clean`, M8 `bl setup` idempotency checks) will fail or produce silently-blank state without M2 in place. M2 is a wave-1 dependency gate, not a cosmetic polish pass.

---

## 2. Goals

1. **G1** — Ship 10 files under `case-templates/`: 8 on-open seeds + `closed.md` (schema-only, present-iff-closed, not materialized on open) + `README.md` (contract manifest).
2. **G2** — Each of the 9 per-case artifact templates (all except `README.md`, which is a repo-tracked contract file) declares its writer/when/lifecycle via a grep-able HTML-comment header keyed exactly to `docs/case-layout.md` §3.
3. **G3** — `attribution.md` contains exactly 5 kill-chain stanza headers (Upload, Exec, Persist, Lateral, Exfil) — grep-verifiable.
4. **G4** — `README.md` enumerates the on-open-seed set (8 files — 7 per-case templates + workspace-wide `INDEX.md`) and explicitly excludes `closed.md` from on-open materialization.
5. **G5** — `INDEX.md` template carries the table shape from `case-layout.md` §6 (`Case | Opened | Status | Hypothesis (30-char preview) | Closed brief (file_id)`) with header row only (no data rows).
6. **G6** — `closed.md` template carries a YAML-frontmatter schema with placeholder fields for `brief_file_id_md`, `brief_file_id_pdf`, `brief_file_id_html`, `closed_at`, `retirement_schedule[]`, `case_id` + a prose body with placeholder narrative.
7. **G7** — `open-questions.md` initial content is the literal string `none` (case-close precondition per `case-layout.md` §5 "must be empty (or explicit 'none') for case-close").
8. **G8** — `hypothesis.md` initial content is the placeholder `investigation open, no hypothesis yet` per `case-layout.md` §5.
9. **G9** — `ip-clusters.md`, `url-patterns.md`, `file-patterns.md` each reference their matching `skills/ioc-aggregation/*` file by path-intent (forward-declaration; M3 lands the skill files).
10. **G10** — All 10 files pass clean-room grep (no matches for operator-local hostnames, customer-tree paths, or Liquid Web internal references per project CLAUDE.md §Data).

---

## 3. Non-goals

- **NG1** — M5 handler implementation (`bl_case_new`, `bl_case_close`, `bl_case_reopen`, `bl_case_list`, `bl_case_show`, `bl_case_log`). These handlers read M2's manifest; they do not belong to M2.
- **NG2** — `STEP_COUNTER` initialization semantics. case-layout.md §3 covers it; the init value (`0\n`) is wrapper-authored on `bl case --new` (M5), not a template file.
- **NG3** — Directory placeholders for `evidence/`, `history/`, `pending/`, `results/`, `actions/pending/`, `actions/applied/`, `actions/retired/`. M5's `mkdir -p` handles these lazily. M2 ships file templates only.
- **NG4** — DESIGN.md §7.2 unification patch. case-layout.md §11 ("welcomed at any time") permits it but does not require it in M2.
- **NG5** — Live probe against Managed Agents memstore create-time schema. M0 ran the probes; this spec consumes their output.
- **NG6** — Skills bundle (M3) authoring of `skills/ioc-aggregation/ip-clustering.md`, `url-pattern-extraction.md`, `file-pattern-extraction.md`. M2 references these by path; M3 writes them.
- **NG7** — Test infrastructure (`tests/` BATS scaffold). M1's spec (parallel wave-1) owns test infra; M2 piggybacks on whatever lands.
- **NG8** — Packaging (`.gitattributes` export-ignore rules for `case-templates/`). M10 ship-ready handles packaging.

---

## 4. Architecture

### 4.1 File map

All new. No modifications to existing files. No deletions.

| File | Est. lines | Purpose |
|---|---:|---|
| `case-templates/README.md` | 60 | Contract manifest — enumerates on-open-seed set, ties each file to case-layout.md §3 writer-owner row, includes validation-grep one-liner |
| `case-templates/INDEX.md` | 12 | Workspace roster seed — header row per case-layout.md §6, zero data rows |
| `case-templates/hypothesis.md` | 20 | Hypothesis placeholder + Confidence + Reasoning section headers |
| `case-templates/open-questions.md` | 12 | Literal `none` body + explanatory preamble |
| `case-templates/attribution.md` | 40 | 5 flat `##` kill-chain stanzas with `**Evidence:**` / `**IoC:**` sub-bullet skeletons |
| `case-templates/ip-clusters.md` | 25 | Table scaffold keyed to `skills/ioc-aggregation/ip-clustering.md` (M3) |
| `case-templates/url-patterns.md` | 25 | Table scaffold keyed to `skills/ioc-aggregation/url-pattern-extraction.md` (M3) |
| `case-templates/file-patterns.md` | 25 | Table scaffold keyed to `skills/ioc-aggregation/file-pattern-extraction.md` (M3) |
| `case-templates/defense-hits.md` | 18 | Append-log header row only, no data |
| `case-templates/closed.md` | 40 | YAML-frontmatter schema + prose-body placeholders; present-iff-closed |

**Total:** 10 files, ~277 lines estimated.

### 4.2 Size comparison

| Metric | Before | After |
|---|---|---|
| `case-templates/` exists | no | yes |
| Files under `case-templates/` | 0 | 10 |
| Lines across templates | 0 | ~277 |
| Grep `writer: (curator\|wrapper)` case-templates/ (9 per-case templates; `README.md` excluded — M2-spec writer) | 0 | 9 |
| Grep `^## (Upload\|Exec\|Persist\|Lateral\|Exfil)$` case-templates/attribution.md | 0 | 5 |

### 4.3 Dependency tree

```
docs/case-layout.md ─── (contract source, unchanged)
         │
         ├──► case-templates/README.md ──────┐
         │                                   │
         │                      (manifest consumed by M5 bl_case_new)
         │
         ├──► case-templates/hypothesis.md
         ├──► case-templates/open-questions.md
         ├──► case-templates/attribution.md ──── (kill-chain anchor: skills/ir-playbook/kill-chain-reconstruction.md — M3)
         ├──► case-templates/ip-clusters.md  ──── (skills/ioc-aggregation/ip-clustering.md — M3, path-intent only)
         ├──► case-templates/url-patterns.md ──── (skills/ioc-aggregation/url-pattern-extraction.md — M3)
         ├──► case-templates/file-patterns.md ── (skills/ioc-aggregation/file-pattern-extraction.md — M3)
         ├──► case-templates/defense-hits.md
         ├──► case-templates/closed.md
         └──► case-templates/INDEX.md  ──── (wrapper-roster; workspace-wide, not per-case)

docs/action-tiers.md ─── (referenced by defense-hits.md Tier column)
schemas/step.md     ─── (referenced by README.md for STEP_COUNTER context)
DESIGN.md §12.1.1   ─── (referenced by README.md for report_step tool context)
```

**Dependency rules:**

- Templates bind TO `docs/case-layout.md` §3; they do not edit it.
- `ip-clusters.md`, `url-patterns.md`, `file-patterns.md` reference M3 skill files by path only — no content copy. M3 authors the skill bodies; M2 references by name.
- `attribution.md` kill-chain vocabulary anchors to `skills/ir-playbook/kill-chain-reconstruction.md` (M3). M2 uses the 5 stanza names (`Upload/Exec/Persist/Lateral/Exfil`) already canonized in case-layout.md §2 and DESIGN.md §7.2 tree comment — no M3 runtime dependency.
- `closed.md` YAML frontmatter shape mirrors `actions/*.yaml` precedent (wrapper-structured). Field names are M2-authored in this spec; future alignment with `actions/applied/*.yaml` YAML is additive, not breaking.
- `README.md` validation-grep one-liner names files by path; M5 handler (wave-2) consumes the path list.

### 4.4 Key changes from current state

- **Create** `case-templates/` directory (did not exist at HEAD `694b0cf`).
- **No-touch** `docs/case-layout.md` — contract source; M2 consumes it.
- **No-touch** `DESIGN.md` — §7.2 tree and §12.1 curator shape referenced by templates, not edited.
- **No-touch** `schemas/*` — step.md / step.json / evidence-envelope.md referenced, not edited.

### 4.5 Dependency rules

- **Clean-room origin.** No copy from `legacy/` (v1 Python curator tree). No copy from operator-local paths per CLAUDE.md §Data (`/home/sigforge/var/ioc/polyshell_out/`, `~/admin/work/proj/depot/polyshell/`).
- **Public-source-only vocabulary.** Kill-chain terminology is from Lockheed Martin's publicly-published Cyber Kill Chain® (Upload/Exec/Persist/Lateral/Exfil tailored to post-intrusion forensics, not the original 7-stage preparatory model) — but the 5 stanza names used here are already canonized in case-layout.md §2 and DESIGN.md §7.2 as the blacklight vocabulary. No external vocabulary import.
- **No runtime logic.** Templates are markdown with placeholders. The only "code" is the optional validation-grep one-liner in README.md.
- **Idempotent re-materialization.** If M5 re-runs `bl case --new` on an existing case, the templates must not be destructive — the wrapper's behavior is to refuse, not to overwrite. M2's contribution is to keep templates byte-stable (no dates, no hostnames, no case-ids) so comparison is cheap.

---

## 5. File contents

### 5.1 `case-templates/README.md`

**Purpose:** Contract manifest. Tells `bl_case_new` (M5) which files to materialize on open; ties each to case-layout.md §3 writer-owner row; includes one-line validation-grep.

**Structure inventory:**

| Section | Content | Lines |
|---|---|---:|
| H1 title | `# case-templates/` — contract manifest | 1 |
| Preamble | Role: "M5 `bl_case_new` reads this list; materializes each on-open file into `bl-case/CASE-<YYYY>-<NNNN>/`" | 4 |
| §1 On-open-seed manifest | Table: filename, writer, when, cap, source case-layout.md §3 row | 12 |
| §2 Schema-only file | 1 row for `closed.md` explaining NOT on-open-seed; wrapper materializes on `bl case close` | 6 |
| §3 Validation | Single grep one-liner M5 uses post-materialize: `grep -L 'writer:' bl-case/CASE-*/{hypothesis,open-questions,attribution,ip-clusters,url-patterns,file-patterns,defense-hits,INDEX}.md \| wc -l` → expect `0` | 8 |
| §4 Change control | Cite case-layout.md §11; additions to case-layout.md §3 writer-owner table require matching M2 template update in same commit | 4 |
| Footer | HTML-comment writer-tag for the README itself (writer: M2-spec, on-authoring, immutable-after-commit, cap: 8 KB) | 2 |

**On-open-seed manifest table (content):**

| Filename | Writer | When | Cap | case-layout.md §3 row |
|---|---|---|---|---|
| hypothesis.md | curator | on-open + on-hypothesis-revision | 50 KB | §3 row 2 |
| open-questions.md | curator | on-hypothesis-revision | 15 KB | §3 row 10 |
| attribution.md | curator | on-hypothesis-revision | 40 KB | §3 row 6 |
| ip-clusters.md | curator | on-evidence-ingest | 30 KB | §3 row 7 |
| url-patterns.md | curator | on-evidence-ingest | 20 KB | §3 row 8 |
| file-patterns.md | curator | on-evidence-ingest | 20 KB | §3 row 9 |
| defense-hits.md | wrapper | on-evidence-ingest | 30 KB | §3 row 16 |
| INDEX.md | wrapper | on-open + on-close | 100 KB | §3 row 1 |

**Schema-only file table (content):**

| Filename | Writer | When | Cap | Reason not on-open |
|---|---|---|---|---|
| closed.md | wrapper | on-close | 20 KB | case-layout.md §3 lifecycle `present-iff-closed` — materializing on open violates the lifecycle invariant |

### 5.2 `case-templates/INDEX.md`

**Purpose:** Workspace-roster template. Wrapper populates on each `bl case --new`. Shape per case-layout.md §6 verbatim.

| Element | Content |
|---|---|
| HTML-comment header | `<!-- writer: wrapper, when: on-open + on-close, lifecycle: append-mostly, cap: 100 KB workspace-wide, src: case-layout.md §3 row 1 + §6 -->` |
| H1 | `# bl-case workspace index` |
| Preamble | One sentence: "Workspace roster. One line per case. Wrapper-maintained per `docs/case-layout.md` §6." |
| Table header | `\| Case \| Opened \| Status \| Hypothesis (30-char preview) \| Closed brief (file_id) \|` |
| Table separator | `\|------\|--------\|--------\|------------------------------\|-------------------------\|` |
| Data rows | (none — wrapper appends on first `bl case --new`) |
| Wrapper append marker | `<!-- WRAPPER-APPEND -->` (comment anchor M5 greps to append before) |

### 5.3 `case-templates/hypothesis.md`

**Purpose:** Hypothesis + Confidence + Reasoning seed. Curator overwrites in full on first revision (placeholder is byte-stable for memstore idempotency).

| Section | Content |
|---|---|
| HTML-comment header | `<!-- writer: curator, when: on-open + on-hypothesis-revision (prior values archived to history/<ISO-ts>.md before mutating in place per §7), lifecycle: mutable, cap: 50 KB, src: case-layout.md §3 row 2 + §7 -->` |
| H1 | `# Hypothesis` |
| Preamble | `<!-- TODO(curator): replace this entire file on first hypothesis revision. History is preserved in history/<ISO-ts>.md per case-layout.md §7. -->` |
| ## Current | Body: `investigation open, no hypothesis yet` |
| ## Confidence | Body: `<!-- TODO(curator): low / medium / high with evidence cite -->` |
| ## Reasoning | Body: `<!-- TODO(curator): narrative — observations, inferences, cited obs-<id> evidence pointers. Attacker-reachable fields treated as untrusted per DESIGN.md §13.2. -->` |

### 5.4 `case-templates/open-questions.md`

**Purpose:** Unresolved-question list. case-close precondition: file must be empty or contain literal `none`.

| Section | Content |
|---|---|
| HTML-comment header | `<!-- writer: curator, when: on-hypothesis-revision; must be empty or literal "none" for case-close, lifecycle: mutable, cap: 15 KB, src: case-layout.md §3 row 10 + §5 -->` |
| H1 | `# Open questions` |
| Preamble | `<!-- curator appends one line per unresolved question. Case-close requires this file empty OR literal "none" per case-layout.md §5 blocking condition. -->` |
| Body | `none` |

### 5.5 `case-templates/attribution.md`

**Purpose:** Kill-chain stanza scaffold. 5 flat `##` headers per case-layout.md §2 parenthetical.

| Section | Content |
|---|---|
| HTML-comment header | `<!-- writer: curator, when: on-hypothesis-revision (when kill chain advances), lifecycle: mutable, cap: 40 KB, src: case-layout.md §3 row 6, DESIGN.md §7.2 tree -->` |
| H1 | `# Attribution — kill chain` |
| Preamble | `<!-- Five stanzas below follow the blacklight kill-chain vocabulary (upload/exec/persist/lateral/exfil). Curator fills each with **Evidence:** and **IoC:** sub-bullets as evidence lands. Grep anchor: `^## (Upload\|Exec\|Persist\|Lateral\|Exfil)$` must return 5. -->` |
| ## Upload | `**Evidence:** <!-- TODO(curator): obs-<id> pointers -->` / `**IoC:** <!-- TODO(curator): file sha256 / URL / path -->` |
| ## Exec | (same skeleton) |
| ## Persist | (same skeleton) |
| ## Lateral | (same skeleton) |
| ## Exfil | (same skeleton) |

### 5.6 `case-templates/ip-clusters.md`

**Purpose:** IP-cluster scaffold. References `skills/ioc-aggregation/ip-clustering.md` (M3) by path-intent.

| Section | Content |
|---|---|
| HTML-comment header | `<!-- writer: curator, when: on-evidence-ingest (after IP aggregation), lifecycle: mutable, cap: 30 KB, src: case-layout.md §3 row 7, skill: skills/ioc-aggregation/ip-clustering.md (M3) -->` |
| H1 | `# IP clusters` |
| Preamble | `<!-- Curator populates per skills/ioc-aggregation/ip-clustering.md methodology (M3). Columns follow the skill's canonical shape; adjust when M3 lands. -->` |
| Table header | `\| Cluster | IPs | ASN(s) | Obs range | CDN-safelist? | Evidence pointers \|` |
| Table separator | `\|---------\|-----\|--------\|-----------\|---------------\|---------------------\|` |
| Data rows | (none — curator appends) |
| WRAPPER-APPEND anchor | `<!-- WRAPPER-APPEND -->` |

### 5.7 `case-templates/url-patterns.md`

**Purpose:** URL-evasion pattern scaffold. References `skills/ioc-aggregation/url-pattern-extraction.md` (M3).

| Section | Content |
|---|---|
| HTML-comment header | `<!-- writer: curator, when: on-evidence-ingest (after URL-pattern generalization), lifecycle: mutable, cap: 20 KB, src: case-layout.md §3 row 8, skill: skills/ioc-aggregation/url-pattern-extraction.md (M3) -->` |
| H1 | `# URL patterns` |
| Preamble | `<!-- Curator populates per skills/ioc-aggregation/url-pattern-extraction.md methodology (M3). Evasion-shape → generalized regex; keyed to phase:2/phase:4 ModSec placement. -->` |
| Table header | `\| Pattern name | Generalized regex | Evasion shape | Obs evidence | Target ModSec phase \|` |
| Table separator | `\|--------------\|--------------------\|---------------\|---------------\|----------------------\|` |
| Data rows | (none — curator appends) |
| WRAPPER-APPEND anchor | `<!-- WRAPPER-APPEND -->` |

### 5.8 `case-templates/file-patterns.md`

**Purpose:** File magic + naming scaffold. References `skills/ioc-aggregation/file-pattern-extraction.md` (M3).

| Section | Content |
|---|---|
| HTML-comment header | `<!-- writer: curator, when: on-evidence-ingest (after magic/yara synthesis), lifecycle: mutable, cap: 20 KB, src: case-layout.md §3 row 9, skill: skills/ioc-aggregation/file-pattern-extraction.md (M3) -->` |
| H1 | `# File patterns` |
| Preamble | `<!-- Curator populates per skills/ioc-aggregation/file-pattern-extraction.md methodology (M3). Magic-byte signatures + naming conventions → yara synthesis candidates. -->` |
| Table header | `\| Pattern name | Magic prefix (hex) | Naming regex | File-type claim | YARA candidate? \|` |
| Table separator | `\|--------------\|---------------------\|---------------\|------------------\|------------------\|` |
| Data rows | (none — curator appends) |
| WRAPPER-APPEND anchor | `<!-- WRAPPER-APPEND -->` |

### 5.9 `case-templates/defense-hits.md`

**Purpose:** Append-only log of applied-action block-hits. Wrapper writes one row per hit event.

| Section | Content |
|---|---|
| HTML-comment header | `<!-- writer: wrapper, when: on-evidence-ingest (when a new block-hit record ingests for an applied action), lifecycle: append-only, cap: 30 KB, src: case-layout.md §3 row 16, tier: docs/action-tiers.md §2 -->` |
| H1 | `# Defense hits` |
| Preamble | `<!-- Wrapper appends one row per block-hit event for actions in `actions/applied/`. Tier column maps to docs/action-tiers.md §2 enum. -->` |
| Table header | `\| Timestamp (ISO-8601) | Act-id | Tier | Hit source | Hit count (window) | Notes \|` |
| Table separator | `\|----------------------\|--------\|------\|------------\|--------------------\|--------\|` |
| Data rows | (none — wrapper appends) |
| WRAPPER-APPEND anchor | `<!-- WRAPPER-APPEND -->` |

### 5.10 `case-templates/closed.md`

**Purpose:** Closed-case schema. Present-iff-closed. Wrapper materializes on `bl case close` by rendering placeholders with real values.

| Section | Content |
|---|---|
| HTML-comment header | `<!-- writer: wrapper, when: on-close, lifecycle: present-iff-closed, cap: 20 KB, src: case-layout.md §3 row 17 + §5 -->` |
| YAML frontmatter | `---` <br> `case_id: {CASE_ID}` <br> `closed_at: {ISO_8601_TIMESTAMP}` <br> `brief_file_id_md: {FILE_ID_OR_EMPTY}` <br> `brief_file_id_pdf: {FILE_ID_OR_EMPTY}` <br> `brief_file_id_html: {FILE_ID_OR_EMPTY}` <br> `retirement_schedule:` <br> `  - act_id: {ACT_ID}` <br> `    retire_when: {ISO_DATE_OR_CONDITION}` <br> `    reason: {PROSE}` <br> `---` |
| H1 | `# Closed case: {CASE_ID}` |
| ## Summary | `<!-- wrapper renders from hypothesis.md final revision + operator closure note -->` |
| ## Retirement schedule | `<!-- wrapper renders table from retirement_schedule[] frontmatter; mirrors actions/applied/<act-id>.yaml retire_hint field per case-layout.md §9 -->` |
| ## Ledger pointer | `<!-- wrapper writes: /var/lib/bl/ledger/{CASE_ID}.jsonl — authoritative post-memstore-expiry per case-layout.md §10 -->` |

---

## 5b. Examples

### 5b.1 Post-M2 tree

```
$ find case-templates/ -type f | sort
case-templates/INDEX.md
case-templates/README.md
case-templates/attribution.md
case-templates/closed.md
case-templates/defense-hits.md
case-templates/file-patterns.md
case-templates/hypothesis.md
case-templates/ip-clusters.md
case-templates/open-questions.md
case-templates/url-patterns.md
```

Expected: 10 files.

### 5b.2 Grep verifications

```bash
# Per-case artifact templates — 9 files with curator|wrapper writer
$ grep -l 'writer: \(curator\|wrapper\)' \
    case-templates/{hypothesis,open-questions,attribution,ip-clusters,url-patterns,file-patterns,defense-hits,INDEX,closed}.md | wc -l
9
```

```bash
# README.md is the contract file (writer: M2-spec, out-of-band per §5.1)
$ grep -l 'writer: M2-spec' case-templates/README.md
case-templates/README.md
```

```bash
$ grep -E '^## (Upload|Exec|Persist|Lateral|Exfil)$' case-templates/attribution.md
## Upload
## Exec
## Persist
## Lateral
## Exfil
```

Expected: exactly 5 lines.

```bash
$ cat case-templates/open-questions.md | tail -1
none
```

Expected: literal `none` as the last content line (case-close precondition).

### 5b.3 hypothesis.md rendered content

```markdown
<!-- writer: curator, when: on-open + on-hypothesis-revision (prior values archived to history/<ISO-ts>.md before mutating in place per §7), lifecycle: mutable, cap: 50 KB, src: case-layout.md §3 row 2 + §7 -->

# Hypothesis

<!-- TODO(curator): replace this entire file on first hypothesis revision. History is preserved in history/<ISO-ts>.md per case-layout.md §7. -->

## Current

investigation open, no hypothesis yet

## Confidence

<!-- TODO(curator): low / medium / high with evidence cite -->

## Reasoning

<!-- TODO(curator): narrative — observations, inferences, cited obs-<id> evidence pointers. Attacker-reachable fields treated as untrusted per DESIGN.md §13.2. -->
```

### 5b.4 Failure case: malformed writer header

If the header on any template is missing or malformed:

```bash
$ grep -L 'writer: \(curator\|wrapper\)' case-templates/*.md
case-templates/ip-clusters.md

$ echo "FAIL: missing or malformed writer header on ip-clusters.md"
```

Expected: on success, zero files returned by `grep -L`; any file returned is a MUST-FIX.

---

## 6. Conventions

### 6.1 HTML-comment header format (one-liner, all templates)

```
<!-- writer: {curator|wrapper}, when: {trigger events}, lifecycle: {mutable|append-only|append-mostly|present-iff-closed}, cap: {N}KB, src: case-layout.md §3 row {N} + {optional §N cross-ref} -->
```

**Field discipline:**

- `writer` — exactly `curator` or `wrapper` (the two values in M2's template bundle; operator is a third value in case-layout.md §3 but no M2 template uses it). Grep-exact. The `README.md` contract file is an exception: its writer tag is `M2-spec` because it is an out-of-band repo-tracked manifest, not a per-case artifact (see §5.1).
- `when` — free-form but cite the case-layout.md §3 "When" column verbatim where possible.
- `lifecycle` — exactly one token from the vocabulary M2 actually uses: `{mutable, append-only, append-mostly, present-iff-closed}`. case-layout.md §3 preamble additionally names `immutable-after-write`, `immutable-after-close`, and `monotonic-non-decreasing`, but M2 templates do not bind to those paths (they apply to `history/`, `evidence/`, `actions/applied/`, `actions/retired/`, and `STEP_COUNTER` which M5 creates lazily — not on-open seeds). `append-mostly` is the token case-layout.md §3 row 1 (INDEX.md) actually uses in the table; M2 mirrors that value.
- `cap` — integer KB matching case-layout.md §3 row.
- `src` — always start with `case-layout.md §3 row N`; additional cross-refs (§5, §6, §7, §9) append with `+`.

### 6.2 Placeholder convention

- `<!-- TODO(curator): ... -->` — curator fills on first relevant revision. Mandatory for every empty section body that the curator will later populate.
- `<!-- WRAPPER-APPEND -->` — anchor comment the wrapper greps to insert new rows above. Used on every append-only table and on `INDEX.md`.
- `{PLACEHOLDER}` (curly braces, UPPER_SNAKE_CASE) — wrapper replaces on materialization. Used only in `closed.md` YAML frontmatter.

### 6.3 Markdown table discipline

- Tables use `|---|` separators with explicit left-padding on long cells.
- Empty template tables have header row + separator row only; no data rows; no stub `—` placeholders (the curator's first append is the first data row).

### 6.4 Cross-reference discipline

- Every reference to case-layout.md cites the `§N` section (not the line number — case-layout.md may be re-versioned).
- Every reference to DESIGN.md cites the `§N.N` subsection.
- Every skill-file reference uses the DESIGN.md §9.1 path name exactly (e.g., `skills/ioc-aggregation/ip-clustering.md` NOT `skills/ioc-aggregation/ip-clusters.md`).

### 6.5 Kill-chain stanza vocabulary

- Headers: `Upload`, `Exec`, `Persist`, `Lateral`, `Exfil` (title case, singular, exactly as case-layout.md §2 parenthetical `(upload/exec/persist/lateral/exfil)`).
- Order: Upload → Exec → Persist → Lateral → Exfil (causal).
- Under each stanza: `**Evidence:**` (bolded label) and `**IoC:**` (bolded label) as sub-bullet anchors. The curator appends per-indicator lines below each.

---

## 7. Interface contracts

### 7.1 Contract with M5 `bl_case_new` handler (wave-2, not M2)

M5 reads `case-templates/README.md` §1 on-open-seed manifest to determine which files to copy (or render) into `bl-case/CASE-<YYYY>-<NNNN>/`. Expected handler behavior:

- Read `case-templates/README.md` §1 table (8 rows, excluding INDEX.md which is workspace-wide).
- `cp` each listed template into the per-case directory.
- Separately, the M5 handler appends the new case row into `bl-case/INDEX.md` using the template's table-shape.
- `closed.md` is NEVER copied on-open. M5's `bl_case_close` handler renders it from the template on close.

### 7.2 Contract with M5 `bl_case_close` handler

M5's close handler reads `case-templates/closed.md` as a template, substitutes the `{PLACEHOLDER}` tokens using the real case values (case_id, closed_at, brief file_ids from Anthropic Files API, retirement_schedule derived from `actions/applied/*.yaml` retire_hint fields), and writes the rendered file as `bl-case/CASE-<id>/closed.md`.

### 7.3 Contract with `docs/case-layout.md` §3

M2 templates are a forward-implementation of case-layout.md §3 writer-owner table. Any additions to the §3 table (new paths) trigger a matching M2 template update per §11 change control. Reviewer MUST-FIX on drift.

### 7.4 Contract with `docs/action-tiers.md`

`defense-hits.md` Tier column values map to the `docs/action-tiers.md` §2 enum (`read-only`, `auto`, `suggested`, `destructive`, `unknown`). The wrapper writes the tier slug at each hit-event.

### 7.5 CLI interface

**Unchanged.** M2 ships zero runtime code. No new `bl` flags, no new exit codes, no new env vars.

---

## 8. Migration safety

### 8.1 Upgrade path

**N/A for M2** — blacklight v2 is a scorched-earth rewrite per `PIVOT-v2.md`. There is no v1 `case-templates/` directory to migrate from. The legacy Python curator (archived at `legacy-pre-pivot` tag) used a Flask-rendered JSON schema, not on-disk templates.

### 8.2 Install path

M2 ships markdown templates only. They land in the repo source tree at `case-templates/`. No install-time relocation. M10 packaging (`pkg/`) will include `case-templates/` in the tarball shape.

### 8.3 Uninstall path

**N/A** — templates are inert markdown. Removal is `rm -r case-templates/`. No registry, no service, no residue.

### 8.4 Rollback path

`git revert` the M2 commit. `case-templates/` disappears. Any M5 handler code that reads the manifest will fail with "file not found" — which is the correct failure mode (do not silently open a case with no seeded state).

### 8.5 Re-materialization safety

If M5 accidentally calls `bl_case_new` twice on the same `CASE-<id>/`, the wrapper must detect and reject (wave-2 concern). M2's contribution: templates are byte-stable (no timestamps, no case-ids, no hostnames baked in), so a bytewise diff will always show `wc -l` matching when comparing fresh-materialized state to the canonical template.

### 8.6 Test-suite impact

M1 owns test scaffold (wave-1 parallel). M2 adds zero BATS files. Post-M1-merge, the M1-authored smoke suite should grow a single test asserting `[ -d case-templates ] && [ "$(find case-templates -type f | wc -l)" -eq 10 ]`. That test falls under M1 or M5 (whichever lands the `bl_case_new` handler first), not M2.

---

## 9. Dead code and cleanup

**None.** `case-templates/` does not currently exist; M2 is purely additive. No files are renamed, deleted, or moved.

Incidental finding during spec authoring: `case-layout.md` §3 preamble refers to "STEP_COUNTER is referenced by schemas/step.md §step_id" — confirmed present in `schemas/step.md` line 13. No drift. No fix needed.

---

## 10a. Test strategy

| Goal | Test location | Test description |
|---|---|---|
| G1 | `tests/02-case-templates.bats` (M1-scaffold target; M2 may author) | `@test "case-templates has exactly 10 files"` — `find case-templates -type f \| wc -l` → 10 |
| G2 | `tests/02-case-templates.bats` | `@test "9 per-case artifact templates declare curator\|wrapper writer metadata"` — `grep -L 'writer: \(curator\|wrapper\)' case-templates/{hypothesis,open-questions,attribution,ip-clusters,url-patterns,file-patterns,defense-hits,INDEX,closed}.md \| wc -l` → 0; and `grep -c 'writer: M2-spec' case-templates/README.md` → 1 |
| G3 | `tests/02-case-templates.bats` | `@test "attribution.md has exactly 5 kill-chain stanzas"` — `grep -Ec '^## (Upload\|Exec\|Persist\|Lateral\|Exfil)$' case-templates/attribution.md` → 5 |
| G4 | Manual verification + visual review of README.md §2 | `grep -A2 'Schema-only file' case-templates/README.md \| grep -q closed.md` → pass; closed.md not in §1 table |
| G5 | `tests/02-case-templates.bats` | `@test "INDEX.md shape matches case-layout.md §6"` — `grep -c '^\\| Case \\\|' case-templates/INDEX.md` → 1 (header only) |
| G6 | `tests/02-case-templates.bats` | `@test "closed.md YAML frontmatter has required keys"` — grep for `brief_file_id_md:`, `retirement_schedule:` → both present |
| G7 | `tests/02-case-templates.bats` | `@test "open-questions.md ends with literal none"` — `tail -1 case-templates/open-questions.md` → `none` |
| G8 | `tests/02-case-templates.bats` | `@test "hypothesis.md placeholder matches case-layout §5"` — `grep -q 'investigation open, no hypothesis yet' case-templates/hypothesis.md` |
| G9 | `tests/02-case-templates.bats` | `@test "IoC pointer-files reference skills/ioc-aggregation/"` — 3 assertions across ip-clusters.md, url-patterns.md, file-patterns.md |
| G10 | `tests/02-case-templates.bats` + manual clean-room audit | `@test "no operator-local hostnames in templates"` — grep for `liquidweb\|sigforge\|polyshell_out` → 0 |

**Test dependency note:** M1's BATS scaffold must exist before M2's test file runs. If M1 is still in-flight when M2's build phases dispatch, M2 defers the BATS authoring to a post-merge follow-up phase; the grep assertions in §5b run from the engineer and sentinel reviewer directly. This is a known wave-1-parallelism trade-off.

---

## 10b. Verification commands

```bash
# G1 — file count
find case-templates -type f | wc -l
# expect: 10

# G2 — every per-case artifact template has curator|wrapper writer metadata (README.md is M2-spec, scoped out)
grep -L 'writer: \(curator\|wrapper\)' \
  case-templates/{hypothesis,open-questions,attribution,ip-clusters,url-patterns,file-patterns,defense-hits,INDEX,closed}.md | wc -l
# expect: 0

# G2 companion — README.md contract file carries the out-of-band writer tag
grep -c 'writer: M2-spec' case-templates/README.md
# expect: 1

# G3 — kill-chain stanzas (exactly 5)
grep -Ec '^## (Upload|Exec|Persist|Lateral|Exfil)$' case-templates/attribution.md
# expect: 5

# G4 — closed.md excluded from on-open seed
grep -A20 '^## 1\. On-open-seed manifest' case-templates/README.md | grep -c '^| closed\.md'
# expect: 0

# G5 — INDEX.md is header-row only
grep -c '^| CASE-' case-templates/INDEX.md
# expect: 0

# G6 — closed.md YAML frontmatter keys present
grep -c '^\(brief_file_id_md\|brief_file_id_pdf\|brief_file_id_html\|closed_at\|retirement_schedule\|case_id\):' case-templates/closed.md
# expect: 6

# G7 — open-questions.md body is literal "none"
tail -1 case-templates/open-questions.md
# expect: none

# G8 — hypothesis.md placeholder text
grep -c 'investigation open, no hypothesis yet' case-templates/hypothesis.md
# expect: 1

# G9 — ioc-aggregation skill references
grep -l 'skills/ioc-aggregation/' case-templates/ip-clusters.md case-templates/url-patterns.md case-templates/file-patterns.md | wc -l
# expect: 3

# G10 — clean-room (no operator-local references)
grep -riE 'liquidweb|sigforge|polyshell_out' case-templates/ | wc -l
# expect: 0

# composite pass — lifecycle vocabulary exact match (M2 bundle uses 4 of the 7-value preamble)
grep -hoE 'lifecycle: [a-z-]+' case-templates/*.md | sort -u
# expect: 4 unique values
#   lifecycle: append-mostly
#   lifecycle: append-only
#   lifecycle: mutable
#   lifecycle: present-iff-closed
```

---

## 11. Risks

1. **R1 — Drift against case-layout.md §3.** If the §3 writer-owner table is edited during M2 build (e.g., a parallel M9 hardening pass adds a new path), templates will be out of sync.
   **Mitigation:** case-layout.md §11 change-control already flags this as a MUST-FIX category. M2's sentinel review pass must re-read case-layout.md §3 and cross-check every template header. Build phase 0 locks the §3 row count as a baseline.

2. **R2 — Path-name drift vs. skills/ioc-aggregation.** M3 landed skill files at `ip-clustering.md` (not `ip-clusters.md`) etc. If M2 templates reference `ip-clusters.md` as the skill name, dead reference.
   **Mitigation:** §6.4 cross-reference discipline mandates DESIGN.md §9.1 path name exactly. Spec and build phases grep-check `skills/ioc-aggregation/ip-clustering.md` (not `ip-clusters.md`) before commit.

3. **R3 — YAML frontmatter collision with memstore structured-parse.** If Managed Agents memstore file-renderers coerce YAML frontmatter into metadata (not body content), `closed.md` loses the frontmatter block when read back.
   **Mitigation:** M0 live probes did not surface memstore YAML coercion. If M2 build phase discovers coercion, fall back to an explicit ```yaml fenced block with the same keys. Build phase includes a memstore round-trip probe for closed.md (fixture: write → read → diff).

4. **R4 — kill-chain stanza vocabulary drift.** If a future DESIGN.md §13 hardening pass renames (e.g., `Upload` → `Staging`), the grep-exact `^## Upload$` assertion breaks.
   **Mitigation:** case-layout.md §2 parenthetical is the anchor. Renaming requires updating both files in same commit per §11 change-control. Sentinel-review pass re-greps both files.

5. **R5 — Clean-room origin violation.** If the engineer copy-pastes placeholder prose from `legacy/` (archived v1 curator) or operator-local `~/admin/work/proj/depot/polyshell/` the clean-room bar fails.
   **Mitigation:** §10b G10 grep assertion covers the known operator-local tokens. Engineer prompt includes explicit "no legacy copy" directive. Sentinel reviewer re-greps.

6. **R6 — Test infrastructure unavailable at M2 build time.** M1 is parallel; BATS scaffold may not be present when M2 dispatches.
   **Mitigation:** Per §10a, the grep assertions are all executable without BATS. Engineer runs them from bash; sentinel re-runs. `tests/02-case-templates.bats` authoring is deferred to post-M1-merge if M1 is still in flight.

7. **R7 — `STEP_COUNTER` confusion.** case-layout.md §3 preamble adds STEP_COUNTER as a path not in DESIGN.md §7.2 tree. If M2 templates try to include a STEP_COUNTER template, scope-creep into M5.
   **Mitigation:** Explicit NG2 in §3 non-goals. STEP_COUNTER is M5-runtime-only; no template.

---

## 11b. Edge cases

| Scenario | Expected behavior | Handling |
|---|---|---|
| Template file already exists (incremental re-build) | `Write` tool errors without Read-first | Build phase check: `[ -e case-templates/<file> ] && { Read first; overwrite-with-intent }`. Never `mv` or `rm` mid-phase. |
| case-layout.md §3 has added row since spec was written | Template count mismatch: M2 ships 10, §3 has 18 rows | Phase 0 baseline lock + sentinel-review re-read of §3. If drift detected, spec is MUST-FIX not skip. |
| `attribution.md` has 4 or 6 kill-chain stanzas (not 5) | G3 verification fails | Exact grep count assertion in §10b; sentinel reviewer re-runs. |
| `open-questions.md` body is empty (zero bytes) | case-close precondition `open-questions.md empty OR literal 'none'` — zero bytes technically passes | Spec mandates literal `none`; grep assertion in §10b. Literal is more discoverable for the curator. |
| `closed.md` materialized on-open by mistake | Violates case-layout.md §3 lifecycle `present-iff-closed` | README.md §2 explicit callout; M5 handler contract §7.1 explicitly excludes closed.md from on-open-seed list. |
| `ip-clusters.md` references `skills/ioc-aggregation/ip-clusters.md` (wrong name) | Dead reference when M3 lands | §6.4 cross-reference discipline + §10b G9 grep check (but grep alone matches prefix; strict check in sentinel review). |
| YAML frontmatter block in closed.md uses tab indentation | YAML spec forbids tabs; memstore-side parser rejects | Build phase: spaces-only indent; `cat -A case-templates/closed.md \| grep -c '\\^I'` → 0. |
| `INDEX.md` WRAPPER-APPEND anchor missing or malformed | M5 append handler cannot find insertion point | `grep -c '<!-- WRAPPER-APPEND -->' case-templates/INDEX.md` → 1. |
| Template header uses curly-quote `—` instead of ASCII `-` | Grep assertions with ASCII `-` miss | All template content is plain ASCII; build phase `file case-templates/*.md \| grep -v 'UTF-8'` permissive (markdown allows UTF-8 content-dictionary) but headers are ASCII. |
| `case-templates/README.md` HTML-comment header lists writer as `M2-spec` which isn't in case-layout.md §3 vocabulary | Drift from writer enum `{curator, wrapper, operator}` | README.md is a repo-tracked contract file, not a per-case artifact — the writer-tag is out-of-band (M2-authored, immutable-after-commit). Spec §5.1 defines this as intentional distinction. |

---

## 12. Open questions

None. All load-bearing decisions resolved in Phase 2 brainstorm (4 resolved questions in `.rdf/work-output/spec-progress.md`).

---

## 13. Build-posture handoff

Per `/r-vpe` invocation:

- **Plan naming:** `PLAN-M2.md` (excluded from tracking per `.git/info/exclude` PLAN*.md glob).
- **Dispatch mode:** subagent-fork-per-phase with sentinel review on completion + engineer FP-check/fixup loop. Consider 2 parallel phases: (A) seed files (hypothesis, open-questions, attribution, defense-hits, INDEX, README), (B) IoC + closed files (ip-clusters, url-patterns, file-patterns, closed). Both phases converge into one commit.
- **End condition:** all §10b verification commands pass with expected output; sentinel reviewer approves; one commit lands on `main` with message `[New] case-templates/ — M2 per-case skeletons + workspace roster + manifest`.
