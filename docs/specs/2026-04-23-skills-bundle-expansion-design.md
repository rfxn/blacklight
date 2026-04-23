# Design: Skills Bundle Expansion — close false-positives dangling route + hit the >=20-file PRD floor

**Authors:** Ryan MacDonald (operator, absent — autonomous delegation via /r-vpe) · Claude (drafting, Opus 4.7)
**Date:** 2026-04-23
**Status:** Proposed
**Gate:** Sat 2026-04-25 18:00 CT (recording-readiness) + Sun 2026-04-26 16:00 EDT (submission target)
**Anchor docs:** PRD.md section 4.3 · PRD.md section 6.2 · PRD.md section 15.2 · PRD.md Appendix E (lines 685-707) · PRD.md Appendix I (judge-skim path) · CLAUDE.md section Operator-content skills · CLAUDE.md section "Never cut" · `.rdf/governance/constraints.md` section "Operator-content constraints" · skills/INDEX.md (current router)

---

## 1. Problem Statement

The skills bundle at `skills/` is a load-bearing artifact in three respects:

1. **Judging surface.** PRD Appendix I (judge-skim path) names `skills/INDEX.md` + `case-lifecycle.md` as the #4 judged artifact in a 5-minute skim. Skills depth is a Depth-weight (20) signal per PRD section 15.2 ("Operator-authored skills content that nobody else can write").
2. **Runtime router.** `skills/INDEX.md` is loaded on every major curator call (per INDEX.md line 5). It routes the case engine + synthesizer + hunters to the right subset of domain knowledge. A route that points at an empty directory is a silent no-op in production — the reasoner runs without the context it would otherwise load.
3. **Anti-slop signal.** CLAUDE.md section Operator-content skills explicitly allows public-source authorship of scaffolds but forbids generic IR/SOC boilerplate. The bundle's authorial voice is a judged signal — 12 files read as "started but abandoned"; 20 reads as "deep reference material".

**Current state (measured 2026-04-23):**

```
$ find skills -name '*.md' | wc -l
12
$ ls skills/false-positives/ 2>&1 | head
(empty)
$ grep -n 'false-positives' skills/INDEX.md
41:  IF file flagged but path is inside a known-benign vendor tree
42:    -> load false-positives/
61:- `false-positives/` (catalog)
```

**Three concrete defects:**

1. **Count gap.** 12 files vs the >=20 floor per CLAUDE.md section "Never cut" and PRD section 4.3. PRD Appendix E line 707 states the acceptable path: "12 mature + 8 scaffold stubs = 20 files total with operator-authored core" — the 8-scaffold portion is undelivered.

2. **Dangling INDEX route.** `skills/INDEX.md:41-42` routes the reasoner to `false-positives/` when a flagged file lands inside a known-benign vendor tree. The directory is empty. The router loads nothing. This is the same bug class fixed in commit 74f50f5 (where the INDEX pointed at `linux-forensics/net-patterns.md` that did not exist); here the directory exists but contains no content.

3. **Under-populated scaffolds.** Six of the nine scaffold categories currently have exactly one file; PRD Appendix E treats 2-per-category as the completion target. Under-population hints that authoring was interrupted mid-batch.

**Measured scope of existing content (reference for voice + depth):**

| File | LOC | Category voice |
|---|---|---|
| `skills/INDEX.md` | 68 | Router prose |
| `skills/apsb25-94/indicators.md` | 59 | Scaffold (contains TODO placeholders) |
| `skills/linux-forensics/net-patterns.md` | 68 | Scaffold |
| `skills/magento-attacks/admin-paths.md` | 108 | Scaffold |
| `skills/linux-forensics/persistence.md` | 111 | Scaffold |
| `skills/webshell-families/polyshell.md` | 129 | Operator-authored moat |
| `skills/ir-playbook/case-lifecycle.md` | 152 | Operator-authored moat |
| `skills/apf-grammar/basics.md` | 168 | Scaffold |
| `skills/hosting-stack/cpanel-anatomy.md` | 174 | Scaffold |
| `skills/ic-brief-format/template.md` | 195 | Scaffold |
| `skills/modsec-grammar/rules-101.md` | 239 | Scaffold |
| `skills/defense-synthesis/modsec-patterns.md` | 276 | Operator-authored moat |

Scaffold median ~140 LOC; range 59-276. The 8 new files must fit this envelope — no stubs (<80 LOC); no padding (>200 LOC unless the subject demands it).

---

## 2. Goals

Each goal is pass/fail verifiable via the command in Section 10b.

1. **G1 — Count floor met.** `find skills -name '*.md' | wc -l` returns `20`.
2. **G2 — false-positives/ no longer empty.** `ls skills/false-positives/*.md 2>/dev/null | wc -l` returns `>=2`, and the file list does not contain only `.gitkeep` or empty files.
3. **G3 — INDEX route hits content.** Every route target in `skills/INDEX.md` resolves to a non-empty file or non-empty directory. Verified by grep-and-test (Section 10b).
4. **G4 — Public-source anchoring.** Every new file contains either an explicit URL/citation or a named public reference (advisory name, manual name, upstream project) in its first 20 lines. Verified by grep for citation markers.
5. **G5 — Voice/depth within scaffold envelope.** Every new file is 80-200 LOC. Outliers require inline rationale.
6. **G6 — Anti-slop footer marker.** Every new file ends with `<!-- public-source authored — extend with operator-specific addenda below -->` matching existing scaffold convention.
7. **G7 — INDEX.md extended (additive only).** `skills/INDEX.md` gains routing references for the new files where reasoners would benefit; no existing routes are removed or syntactically altered; bundle-depth claim (line 68) updated from `~20` to `20 (12 mature + 8 scaffold)`.
8. **G8 — pytest green.** `PYTHONPATH=. pytest -q` returns 0; no new tests (skills files do not affect the test suite); no regressions.
9. **G9 — No customer data, no non-public IOCs.** `grep` sweep for customer-data tokens (hostnames, customer IDs, internal domain fragments) returns 0 matches in new files. CLAUDE.md section Reference data is the binding constraint.
10. **G10 — README skills-count claim verifiable.** When P42 lands, the README can assert `12 mature + 8 scaffold = 20 total` without restating aspirational numbers.

---

## 3. Non-Goals

Explicit exclusions to prevent scope creep:

- **No rewrites of existing files.** `polyshell.md`, `modsec-patterns.md`, `case-lifecycle.md`, `apsb25-94/indicators.md`, `INDEX.md` (structure), and all 7 existing scaffolds stay as-is. Only additive edits to `INDEX.md` are in scope.
- **No new operator-voice moat content.** The three operator-authored moat files (polyshell, modsec-patterns, case-lifecycle) are mature per PRD section 6.1. The 8 new files are public-source-authored scaffolds; misrepresenting their provenance (e.g., claiming "operator-authored" in the new file headers) evaporates the anti-slop signal per PRD section 15.2.
- **No code changes.** No edits to `curator/`, `bl-agent/`, `tests/`, `compose/`, `demo/`, or top-level scripts. This is a docs-only spec.
- **No P38/P39 overlap.** `demo/time_compression.py` and `tests/test_time_compression.py` (P38, parallel session) and `demo/script.md` (P39, parallel session) are explicitly out of scope — do not edit.
- **No P42 overlap.** `README.md` is owned by P42 (blocked on P38). This spec produces the verifiable skills-count claim; P42 consumes it.
- **No tribal-knowledge slop.** Per CLAUDE.md section Operator-content skills, if the best achievable draft of a file would be generic IR/SOC boilerplate, the file is cut from scope and the spec calls out the gap. See Section 11 Risk 3.
- **No router semantics change.** `skills/INDEX.md` existing routes preserve their current trigger predicates and load targets. New routes layer on; none replace.
- **No 25-file stretch.** Governance `constraints.md:45,83` states "25 files minimum" — but this is an internal inconsistency with `constraints.md:71` which says "~20 files minimum", and both are superseded by CLAUDE.md section "Never cut" (>=20) and PRD Appendix E (explicit target 20). This spec hits 20; reaching 25 is follow-on work tracked in FUTURE.md. **Source-of-truth fix lands as Phase S-00 — see Section 12** (per workspace CLAUDE.md §"Guiding Principles" — "Spec Contradictions Must Be Fixed at the Source").
- **No test authorship.** Skills files are not exercised by pytest; no new tests land.
- **No .gitignore / .git/info/exclude edits.** Skills files are committed. No working-file contamination.
- **No commits to operator-working files.** `HANDOFF.md`, `PRD.md`, `CLAUDE.md`, `PLAN*.md`, `P[0-9]*.md`, `FUTURE.md`, `MEMORY.md`, `.rdf/` — all stay excluded per `.git/info/exclude`.

---

## 4. Architecture

### 4.1 Codebase Inventory (files read during design)

| File | LOC | Role | Modified? |
|---|---|---|---|
| `skills/INDEX.md` | 68 | Router — decision-tree loaded on every major curator call | **MODIFIED** (additive routes + depth claim) |
| `skills/ir-playbook/case-lifecycle.md` | 152 | Operator-authored moat — case revision lifecycle | untouched |
| `skills/webshell-families/polyshell.md` | 129 | Operator-authored moat — PolyShell family primer | untouched |
| `skills/defense-synthesis/modsec-patterns.md` | 276 | Operator-authored moat — ModSec rule idioms | untouched |
| `skills/apsb25-94/indicators.md` | 59 | Scaffold (contains TODO markers; operator fills later) | untouched |
| `skills/apf-grammar/basics.md` | 168 | Scaffold — APF directive + trust-list grammar | untouched |
| `skills/hosting-stack/cpanel-anatomy.md` | 174 | Scaffold — cPanel filesystem + vhost layout | untouched |
| `skills/ic-brief-format/template.md` | 195 | Scaffold — IC brief section structure + voice rules | untouched |
| `skills/linux-forensics/net-patterns.md` | 68 | Scaffold — outbound callback log shapes | untouched |
| `skills/linux-forensics/persistence.md` | 111 | Scaffold — cron / systemd / shell-init persistence | untouched |
| `skills/magento-attacks/admin-paths.md` | 108 | Scaffold — Magento 2 admin surface + REST API | untouched |
| `skills/modsec-grammar/rules-101.md` | 239 | Scaffold — SecRule grammar reference | untouched |
| `skills/false-positives/` (directory) | 0 | Empty — referenced by INDEX:41 | **DIRECTORY CONTENT ADDED** |
| `docs/specs/2026-04-22-day2-hunters-design.md` | — | Prior spec (format template) | untouched |
| `docs/specs/2026-04-23-day4-intent-synth-manifest-design.md` | — | Prior spec (format template) | untouched |
| `.rdf/governance/{index,constraints,conventions}.md` | — | Governance reference | untouched |
| `PRD.md` (operator-working, excluded) | — | Appendix E is the canonical completion-matrix source | untouched |
| `.gitignore` / `.git/info/exclude` | — | Ensures new `skills/**/*.md` files commit and working files do not | untouched |

**Key finding:** `skills/apsb25-94/indicators.md` contains TODO markers (lines 11-14, 17-19, 25-26, 28-29, 31-33, 36-37, 40-41) — the file exists but is incomplete. PRD Appendix E marks it "mature" at 59 LOC; this spec does not touch it (Section 3 non-goal). The new companion file `skills/apsb25-94/exploit-chain.md` lands alongside without modifying the TODO file.

**Key finding:** `skills/INDEX.md` already routes to `false-positives/` as a directory (line 42 — `-> load false-positives/`). The `load <directory>/` form loads every `.md` in that directory transparently. Adding files into the directory auto-satisfies the route with **no INDEX syntax change for that branch** (only the bundle-depth claim needs updating).

### 4.2 New Files (8 content + 0 test + 0 code)

**Distribution rationale (addressing PRD Appendix E alignment):**

PRD Appendix E line 706 allocates 2-per-category across 7 categories (14 scaffold files). Spec allocates 8 across 7 categories (uneven). Rationale:

1. `linux-forensics/` is already at the PRD-target of 2 files (net-patterns.md + persistence.md). No further expansion — respects INDEX.md:68 "Depth per file over file count".
2. `false-positives/` gets 2 new files (matches PRD). Prioritized because it is the dangling-INDEX-route defect (Section 1 point 2) — the motivating reason for this spec.
3. `apsb25-94/` gets 1 new file (PRD allocation implies 2; existing indicators.md has TODOs). `exploit-chain.md` pairs with the existing indicators.md as the attack-flow-reconstruction companion; indicators.md's TODO-fill is operator work (out of scope per Section 3).
4. `hosting-stack/`, `ic-brief-format/`, `apf-grammar/`, `magento-attacks/`, `modsec-grammar/` each take 1 new file (PRD allocation implies 2 each, which would add 10 files — over the 20-file floor and into the 25-file stretch territory). Selecting 1-per-category respects the "depth over count" principle while hitting the PRD-floor of 20 and closing the dangling-route.
5. Alternative considered: **grow existing scaffolds to 250-300 LOC each instead of adding new files.** Rejected because (a) cannot close the dangling `false-positives/` INDEX route (directory must have files, not longer siblings elsewhere); (b) PRD Appendix E line 707 explicitly scores "20 files total" as the acceptable floor; (c) judges skim `ls skills/` directory count during the 5-minute review path (PRD Appendix I), not `wc -l` per file.



| Path | Est. LOC | Topic | Public-source anchor |
|---|---|---|---|
| `skills/false-positives/vendor-tree-allowlist.md` | 140 | Benign Magento `vendor/` + Composer + WP `wp-content/plugins/` paths commonly misflagged by webshell scanners | Adobe Commerce Developer Docs (file layout); Composer spec (PSR-4 autoload); WordPress Plugin Directory README conventions |
| `skills/false-positives/backup-artifact-patterns.md` | 130 | Backup/archive filename patterns misflagged: `.bak`, `.old`, `.orig`, `.swp`, cPanel backup wheels, `wp-config.php.bak`, logrotate outputs, mysqldump targets | cPanel docs; WordPress Backup Plugin (WP File Manager, UpdraftPlus) conventions; logrotate(8) man page; mysqldump(1) |
| `skills/hosting-stack/cloudlinux-cagefs-quirks.md` | 170 | CageFS virtual-filesystem layer, `/var/cagefs/` virtual paths, LVE fault signatures in `/var/log/messages`, suEXEC UID mapping, PHP Selector / `mod_lsapi` per-request context | CloudLinux public documentation (docs.cloudlinux.com) — CageFS, LVE, PHP Selector sections |
| `skills/ic-brief-format/severity-vocab.md` | 150 | Severity/criticality vocabulary table keyed to concrete incident classes (webshell = P1 tenant / P0 system; cred harvester = P0; skimmer-on-checkout = P0; FP = P3); downgrade ladder; notification matrix | SANS handler severity models (SANS Incident Handler's Handbook); NIST SP 800-61 Rev.2 (Incident Handling Guide); FIRST TLP 2.0; OWASP Top 10 categorization |
| `skills/apf-grammar/deny-patterns.md` | 150 | `deny_hosts.rules` entry shapes for campaign IOCs, shared import-file blocklist, fail2ban integration, `apf -t` temp-ban semantics, tag vocabulary for manifest-driven inserts | R-fx Networks public APF README (github.com/rfxn/advanced-policy-firewall); apf(8); fail2ban action.d docs |
| `skills/magento-attacks/writable-paths.md` | 140 | Magento 2.4.x writable-directory map (`pub/media/`, `var/cache/`, `var/tmp/`, `var/session/`, `generated/`, `pub/static/`); `.htaccess` override vectors; composer.lock diff strategy | Adobe Commerce Developer Docs (file permissions, directory structure, deployment topics); Magento Security Scan advisories |
| `skills/modsec-grammar/transformation-cookbook.md` | 170 | Transformation-chain recipes for common evasion shapes: URL-encoding layers, double-encoding, base64 payload, unicode tricks, case-shift, whitespace/comment insertion; per-variable cost implications | ModSecurity Reference Manual v3 (github.com/SpiderLabs/ModSecurity); OWASP CRS `REQUEST-901-INITIALIZATION.conf`; OWASP Evasion cheat-sheet |
| `skills/apsb25-94/exploit-chain.md` | 160 | APSB25-94 exploit-chain reconstructed from public Adobe advisory: vulnerable endpoint class, request-body shape, post-exploitation file-drop pathway, network egress pattern, mitigation-timeline facts | Adobe Security Bulletin APSB25-94 (helpx.adobe.com/security); NVD CVE listing; Magento security-release notes |

**Total new content:** 8 files, ~1200 LOC. No new test files. No new code files.

### 4.3 Modified Files

| Path | Current LOC | Delta | Change scope |
|---|---|---|---|
| `skills/INDEX.md` | 68 | +12-18 LOC | Additive routing extensions (see Section 5.9); bundle-depth claim update |

**INDEX.md changes (scope):**

- Lines 31-32 (Magento route): extend `load magento-attacks/admin-paths.md` to `load magento-attacks/admin-paths.md AND magento-attacks/writable-paths.md`
- Lines 33-34 (APSB25-94 route): extend `load apsb25-94/indicators.md` to `load apsb25-94/indicators.md AND apsb25-94/exploit-chain.md`
- Lines 36-37 (outbound-callback route): keep net-patterns.md as primary; no change to this branch
- Lines 38-39 (persistence route): keep persistence.md as primary; no change
- Lines 40-41 (false-positives route): **no change** — directory-level route auto-loads new files
- Lines 42-43 (cpanel-anatomy route): extend with new branch `AND IF host indicates CloudLinux platform (/var/cagefs/ or /var/lve/ present) -> ALSO load hosting-stack/cloudlinux-cagefs-quirks.md`
- Lines 19-24 (synthesizer always-load): extend with conditional branch: `AND IF attack class shows evasion signals (transformation-laden payload, double-encoding, base64-wrapped body) -> ALSO load modsec-grammar/transformation-cookbook.md`; similarly for APF target: `AND IF capability_map includes C2 callback IOCs -> ALSO load apf-grammar/deny-patterns.md`
- Lines 46-50 (brief-format route): extend `load ic-brief-format/template.md` to `load ic-brief-format/template.md AND ic-brief-format/severity-vocab.md`
- Line 68 (bundle-depth claim): change `Target bundle depth: ~20 files (vs CrossBeam's 28). Depth per file over file count.` to `Current bundle depth: 20 files (12 mature + 8 public-source scaffold vs CrossBeam's 28). Depth per file over file count.`

### 4.4 Deleted Files

None.

### 4.5 Files that MUST NOT be touched

Per Section 3 non-goals and workspace CLAUDE.md scope discipline:

- `skills/ir-playbook/case-lifecycle.md` — operator-authored moat
- `skills/webshell-families/polyshell.md` — operator-authored moat
- `skills/defense-synthesis/modsec-patterns.md` — operator-authored moat
- `skills/apsb25-94/indicators.md` — has operator TODOs; companion file lands alongside without edits
- `skills/apf-grammar/basics.md` — existing scaffold stays
- `skills/hosting-stack/cpanel-anatomy.md` — existing scaffold stays
- `skills/ic-brief-format/template.md` — existing scaffold stays
- `skills/linux-forensics/net-patterns.md` — existing scaffold stays
- `skills/linux-forensics/persistence.md` — existing scaffold stays
- `skills/magento-attacks/admin-paths.md` — existing scaffold stays
- `skills/modsec-grammar/rules-101.md` — existing scaffold stays
- `curator/**`, `bl-agent/**`, `tests/**`, `compose/**`, `demo/**` — out of scope (code surfaces)
- `README.md` — P42 owns; do not edit
- `demo/script.md`, `demo/time_compression.py`, `tests/test_time_compression.py` — P38/P39 own in parallel session
- `HANDOFF.md`, `PRD.md`, `CLAUDE.md`, `PLAN*.md`, `MEMORY.md`, `FUTURE.md`, `.rdf/**` — working files, never commit

### 4.6a Cross-Reference Adjacency Table (new files' outgoing references)

Each new file cross-references siblings. If a sibling renames or moves, the referring file needs an edit. This adjacency table is the dependency-drift guard:

| New file | Outgoing references |
|---|---|
| `false-positives/vendor-tree-allowlist.md` | `false-positives/backup-artifact-patterns.md` (pair-file) |
| `false-positives/backup-artifact-patterns.md` | `false-positives/vendor-tree-allowlist.md` (pair-file) |
| `hosting-stack/cloudlinux-cagefs-quirks.md` | `hosting-stack/cpanel-anatomy.md` (parent-platform) |
| `ic-brief-format/severity-vocab.md` | `ic-brief-format/template.md` (parent-format); `ir-playbook/case-lifecycle.md` (lifecycle semantics) |
| `apf-grammar/deny-patterns.md` | `apf-grammar/basics.md` (grammar base); `defense-synthesis/modsec-patterns.md` (network-layer companion) |
| `magento-attacks/writable-paths.md` | `magento-attacks/admin-paths.md` (admin-surface companion); `apsb25-94/indicators.md` (advisory context); `hosting-stack/cpanel-anatomy.md` (tenant-vs-system classification) |
| `modsec-grammar/transformation-cookbook.md` | `modsec-grammar/rules-101.md` (grammar base); `defense-synthesis/modsec-patterns.md` (rule-shape idioms) |
| `apsb25-94/exploit-chain.md` | `apsb25-94/indicators.md` (IOC pair); `webshell-families/polyshell.md` (post-exploitation family); `linux-forensics/net-patterns.md` (egress evidence); `magento-attacks/admin-paths.md`, `magento-attacks/writable-paths.md` (drop pathway) |

None of the referenced files are renamed by this spec; all targets exist post-landing. If any target file renames in future work, these 8 files are the audit set.

### 4.6b Dependency Tree

```
skills/ (router + 11 existing files + 8 new files = 20 total)
 |
 +- INDEX.md                                    [MODIFIED: additive routes + depth claim]
 |   |
 |   +-- routes: ir-playbook/case-lifecycle.md  (every revision call)
 |   +-- routes: defense-synthesis/modsec-patterns.md  (every synth call)
 |   +-- routes: modsec-grammar/rules-101.md    (synth w/ ModSec target)
 |   |           + modsec-grammar/transformation-cookbook.md  [NEW]
 |   +-- routes: apf-grammar/basics.md          (synth w/ APF target)
 |   |           + apf-grammar/deny-patterns.md  [NEW] (when C2 IOCs present)
 |   +-- routes: magento-attacks/admin-paths.md (Magento stack)
 |   |           + magento-attacks/writable-paths.md  [NEW]
 |   +-- routes: apsb25-94/indicators.md        (APSB25-94 applicability)
 |   |           + apsb25-94/exploit-chain.md    [NEW]
 |   +-- routes: webshell-families/polyshell.md (PHP outside framework paths)
 |   +-- routes: linux-forensics/net-patterns.md (callback signals)
 |   +-- routes: linux-forensics/persistence.md (persistence signals)
 |   +-- routes: false-positives/               (directory route — auto-loads)
 |   |           + false-positives/vendor-tree-allowlist.md    [NEW]
 |   |           + false-positives/backup-artifact-patterns.md [NEW]
 |   +-- routes: hosting-stack/cpanel-anatomy.md (shared-tenant platform)
 |   |           + hosting-stack/cloudlinux-cagefs-quirks.md  [NEW] (CloudLinux)
 |   +-- routes: ic-brief-format/template.md    (brief production)
 |               + ic-brief-format/severity-vocab.md  [NEW]
 |
No code dependencies. Docs-only change. Curator load path unchanged (curator reads INDEX.md + targeted files at runtime; prompt-caching per PRD 9.3).
```

### 4.7 Key Changes from Current Architecture

1. **Router semantics stable.** All existing routes preserve their trigger + load-target pairs. New routes are either (a) added-target on an existing route (most common), or (b) new conditional branch following an existing branch. No existing route is removed or semantically redefined.
2. **Directory-route self-healing.** The `false-positives/` directory-level route becomes functional once content exists. No INDEX syntax change needed for that branch.
3. **Provenance discipline preserved.** INDEX.md line 56-64 "Bundle ownership" section describes the **six operator-authored core files**. New files are public-source-authored scaffolds; the ownership section is NOT edited to add them to the operator-authored list. The bundle-depth line (68) is updated with provenance breakdown.
4. **No runtime behavior change.** Curator code (`curator/case_engine.py`, `curator/synthesizer.py`, etc.) reads INDEX.md + targeted files. Additive routes mean reasoners load MORE context when triggers fire; they never load LESS context or load different content than before.

### 4.8 Dependency Rules

- **Additive-only to INDEX.md.** No existing route is removed, reordered, or semantically altered.
- **Public-source only.** Every new file cites at least one public source in its first 20 lines. Operator-local grounding data (`~/admin/work/proj/depot/polyshell/`, `/home/sigforge/var/ioc/polyshell_out/`) stays out of new files per CLAUDE.md section Reference data.
- **Voice lock.** New files match existing scaffold voice (terse, specific, numbered-not-adjective, no hedging) — see Section 6 Conventions.
- **No churn on no-touch files.** Section 4.5 list is binding.

---

## 5. File Contents (function inventory — per-file outline)

Because these files are prose, not code, the inventory table is structured as **section outlines**: what sections each file has, what each section covers, which public source anchors the section.

### 5.1 `skills/false-positives/vendor-tree-allowlist.md` (~140 LOC)

| Section | Purpose | Content anchor |
|---|---|---|
| H1 header | `false-positives — vendor-tree allowlist patterns` | — |
| Intro paragraph | "Loaded by the router when a flagged file lands inside..." — describes role and pair-file | INDEX.md:40-42 |
| H2: Magento vendor/ tree | Concrete benign paths: `vendor/magento/framework/View/`, `vendor/magento/module-backend/`, `vendor/symfony/console/`, etc.; Composer-managed invariant (composer.lock hash) | Adobe Commerce Dev Docs file layout |
| H2: WordPress plugins | `wp-content/plugins/<plugin>/vendor/`, `wp-content/mu-plugins/`, common false-flagged minified JS/PHP patterns | WordPress Plugin Directory README conventions |
| H2: Common signals that resolve FP | File ownership matches `<user>:<user>` vendor-installed baseline; composer.lock hash matches upstream; file present in pristine package archive | Composer spec (PSR-4 autoload, dist.shasum) |
| H2: When the allowlist doesn't apply | Attacker drops `.php` inside real `vendor/` dir to hide; the countermove (fresh composer install diff) | PRD section 6.1 case-engine rows (reference) |
| Footer | Public-source authored marker | Convention |

### 5.2 `skills/false-positives/backup-artifact-patterns.md` (~130 LOC)

| Section | Purpose | Content anchor |
|---|---|---|
| H1 header | `false-positives — backup + archive artifacts` | — |
| Intro paragraph | "Loaded alongside vendor-tree-allowlist.md..." | pair-file reference |
| H2: Common suffixes | `.bak`, `.old`, `.orig`, `.sav`, `.swp`, `.swo`, `.tmp`, `~` files from editors; `-old`/`-backup` appended stems | Editor conventions (vim, emacs) |
| H2: cPanel backup wheels | `/home/<user>/backup-*.tar.gz`, `/home/<user>/backups/`, `/backup/` system-level backups | cPanel docs |
| H2: WordPress backup-plugin artifacts | UpdraftPlus paths (`wp-content/updraft/`), BackupBuddy, VaultPress | Plugin docs (public) |
| H2: Database dumps | `*.sql`, `*.sql.gz`, `dump*.sql`, `mysqldump-*.sql`; mysqldump(1) default stem | mysqldump(1) man page |
| H2: Log-rotation artifacts | `*.log.1`, `*.log.gz`, `*.log.old`; `/var/log/*-YYYYMMDD` timestamp variants | logrotate(8) man page |
| H2: Resolution checklist | Owner, mtime, whether same-named live file exists, hash against the non-backup sibling | Operator playbook (derivable) |
| Footer | Public-source marker | Convention |

### 5.3 `skills/hosting-stack/cloudlinux-cagefs-quirks.md` (~170 LOC)

| Section | Purpose | Content anchor |
|---|---|---|
| H1 header | `hosting-stack — CloudLinux CageFS and LVE quirks` | — |
| Intro paragraph | "Loaded when host indicates CloudLinux platform..." | INDEX route addition |
| H2: CageFS virtual namespace | What CageFS is (per-user chroot-like virtual FS); `/var/cagefs/<N>/<user>/` layout; what the responder sees inside the tenant vs outside | CloudLinux docs.cloudlinux.com CageFS section |
| H2: suEXEC + PHP Selector | PHP version per tenant via Selector; process UID in `ps` output; file-ownership semantics under mod_lsapi | CloudLinux PHP Selector docs |
| H2: LVE faults and limit hits | `/var/log/messages` `lve_enter` signatures; `lveinfo`, `lvetop` live commands; `/var/log/lve-stats/`; limit breach as corroborating signal | CloudLinux LVE docs |
| H2: Per-user database governance | MySQL Governor logs; `/var/lve/dbgovernor-store/`; query-runtime signatures useful for exfil triage | CloudLinux MySQL Governor docs |
| H2: What the attacker sees from inside the cage | Denied syscalls, `/proc/` restrictions, writable-file restrictions | CloudLinux CageFS restrictions |
| H2: Triage checklist for CloudLinux hosts | What to correlate (LVE faults vs access.log window; UID mapping in `find` output vs tenant UID) | Operator playbook (derivable) |
| Footer | Public-source marker | Convention |

### 5.4 `skills/ic-brief-format/severity-vocab.md` (~150 LOC)

| Section | Purpose | Content anchor |
|---|---|---|
| H1 header | `ic-brief-format — severity vocabulary` | — |
| Intro paragraph | "Loaded alongside template.md when producing operator-facing briefs..." | template.md pair-file |
| H2: The P0-P4 ladder | Defined with incident triggers, not abstract text; explicit "P1 = customer-impacting active compromise" per existing template; tied to specific classes (webshell, cred-harvest, skimmer, FP) | SANS handler severity models + template.md:33-43 existing definitions |
| H2: Class -> severity default table | Webshell + tenant scope = P1; webshell + system scope = P0; credential harvester (any scope) = P0; skimmer on checkout + active callback = P0; FP with no blast = P3; recon-only with no exploitation = P4 | Existing template.md severity semantics extended |
| H2: Downgrade ladder | P1 -> P2 -> P3 triggers: callback blocked at edge; tenant suspended; affected DB reset; customer notification delivered; containment gate passed | NIST SP 800-61 containment/eradication phases |
| H2: Notification matrix | Who pages on P1/P2 (on-call + incident lead); who notifies on P3 (channel post); who gets FYI on P4 (channel post, no page) | FIRST TLP 2.0 distribution semantics |
| H2: Severity-line format | One-line format with named trigger (from template.md:42); never-silent-downgrade rule | template.md:33-45 existing voice |
| Footer | Public-source marker | Convention |

**Risk note (per Section 11 Risk 2):** This file is the most at-risk of producing generic IR/SOC boilerplate. Mitigation: anchor the P0-P4 definitions in the concrete classes we stage in the demo (webshell, cred-harvest, skimmer), not in abstract text. If the first-pass draft triggers the slop-smell list (Appendix B), the engineer **re-authors the draft** with concrete incident-class triggers. No file substitution — substituting would silently change the commit artifact set (commit message, INDEX.md routing, verification targets all hardcode `severity-vocab.md`) and mid-authoring swaps violate the Phase S-01 "all or none" delivery rule (Section 11 Risk 7).

### 5.5 `skills/apf-grammar/deny-patterns.md` (~150 LOC)

| Section | Purpose | Content anchor |
|---|---|---|
| H1 header | `apf-grammar — deny_hosts.rules patterns for campaign IOCs` | — |
| Intro paragraph | "Loaded by the router on every synthesizer call that targets APF, when the capability map includes C2 callback IOCs..." | INDEX route addition; basics.md pair-file |
| H2: deny_hosts.rules entry for campaign IOC | Format from basics.md; concrete examples with tag metadata (`desc:`, `d:`, `s:`, `e:`) | basics.md:57-71 existing grammar |
| H2: Shared import-file blocklist | `import:/etc/apf/import/campaign-YYYYMMDD.rules` pattern for fleet-wide deploys; deploy sequence (write import file, apf -r on every host); basics.md:122-130 already covers syntax | basics.md:122-130 existing |
| H2: fail2ban integration | action.d JSON snippet for apf-block action; the apf-jail.conf shape; caveats when RAB is also active | fail2ban action.d docs (public) |
| H2: Temp-ban vs persistent | `apf -t <minutes> <ip>` semantics; when temp is right (noisy but low-confidence); when persistent is right (high-confidence campaign attribution) | basics.md:83-85 existing |
| H2: Manifest-driven inserts | Synthesizer emits `apf -d <ip> "<comment-with-tags>"` lines in manifest.rules[]; bl-apply consumption format; tag vocabulary for `s:synth`, `s:hunter-<name>`, `s:case-<id>` | basics.md:67-71 tag vocab + synthesizer integration |
| H2: Validation | `apf -s` dry-run before commit; failure handling (manifest.suggested_rules[] downgrade) | basics.md:162-166 existing |
| Footer | Public-source marker | Convention |

### 5.6 `skills/magento-attacks/writable-paths.md` (~140 LOC)

| Section | Purpose | Content anchor |
|---|---|---|
| H1 header | `magento-attacks — writable paths and drop-zone analysis` | — |
| Intro paragraph | "Loaded alongside admin-paths.md when Magento 2.x detected..." | admin-paths.md pair |
| H2: Writable-directory map | `pub/media/`, `var/cache/`, `var/tmp/`, `var/session/`, `generated/`, `pub/static/` — what each is for, why it's writable, legit file types | Adobe Commerce Dev Docs (directory structure) |
| H2: `.htaccess` override vectors | `php_value auto_prepend_file`, `RewriteRule`, `AddHandler` — concrete pattern examples; admin-paths.md:50-58 has overlap (audit for duplication) | admin-paths.md:49-56 cross-ref; Apache core docs |
| H2: Legit vs anomalous file types per directory | `pub/media/` = images/PDFs only, `.php` is anomalous; `generated/` = `.php` is normal (DI-generated) but mtime outside deploy window is anomalous | Adobe Commerce Dev Docs |
| H2: composer.lock diff strategy | `composer install --dry-run` against a fresh checkout of the same version; hash every `.php` in `vendor/` and compare; admin-paths.md:62-69 has the vendor/ tree discussion | admin-paths.md:62-69 cross-ref + Composer docs |
| H2: What to capture into evidence rows | Source_refs citing: path, mtime, owner, matching/non-matching composer baseline, `.htaccess` chain governing the path | Existing evidence.py contract |
| Footer | Public-source marker | Convention |

### 5.7 `skills/modsec-grammar/transformation-cookbook.md` (~170 LOC)

| Section | Purpose | Content anchor |
|---|---|---|
| H1 header | `modsec-grammar — transformation cookbook for evasion shapes` | — |
| Intro paragraph | "Loaded on every synth call when attack class shows evasion signals..." | rules-101.md pair-file |
| H2: Why transformations matter | Request reaches the server encoded; attacker leans on encoding to bypass naive signatures; the transformation chain is the defense | ModSec Reference Manual |
| H2: The transformation catalog (selected) | `t:urlDecode`, `t:urlDecodeUni`, `t:htmlEntityDecode`, `t:base64Decode`, `t:removeNulls`, `t:lowercase`, `t:compressWhitespace`, `t:normalizePath`, `t:replaceComments` — purpose + typical evasion countered | ModSec Reference Manual transformation list; rules-101.md:101-115 already covers list |
| H2: Recipe — URL-encoded payload | `t:none,t:urlDecodeUni,t:lowercase,t:compressWhitespace` — what this catches; when order matters | ModSec Reference Manual Evasion chapter |
| H2: Recipe — double-encoded | Two passes of urlDecode; cost of the second pass | OWASP Evasion cheat-sheet (public) |
| H2: Recipe — base64-wrapped body | `t:base64Decode` on `REQUEST_BODY`; `TX:decoded_body` usage pattern; chained inspection | ModSec Reference Manual |
| H2: Recipe — Unicode normalization tricks | `t:urlDecodeUni` handling; homoglyph considerations for high-value patterns | Unicode TR#36 (public) + ModSec docs |
| H2: Recipe — whitespace/comment insertion | `t:compressWhitespace,t:replaceComments` against SQL injection noise; OWASP CRS REQUEST-942 patterns | OWASP CRS REQUEST-942-APPLICATION-ATTACK-SQLI.conf |
| H2: Cost implications | Every transformation is applied per request per matching variable — tight rule in phase:1 beats broad rule with long chain in phase:2 | rules-101.md:21-29 phase-cost framing |
| Footer | Public-source marker | Convention |

### 5.8 `skills/apsb25-94/exploit-chain.md` (~160 LOC)

| Section | Purpose | Content anchor |
|---|---|---|
| H1 header | `apsb25-94 — exploit chain reconstruction (public advisory)` | — |
| Intro paragraph | "Loaded alongside indicators.md when advisory applicability is established..." | indicators.md pair-file |
| H2: What the advisory says | Affected versions, CVE class, remediation versions — from public advisory page | Adobe Security Bulletin APSB25-94 (helpx.adobe.com) |
| H2: Initial access vector | Vulnerable endpoint class (REST API subset per advisory); request-body shape; required/optional body fields; pre-auth nature of the class | Adobe advisory + public CVE description |
| H2: Post-exploitation file drop | Drop pathway: POST -> subsequent GET to a newly-created file in document root; file-placement preferences per writable-paths.md; PolyShell-family characteristics from polyshell.md | admin-paths.md:26-36 + writable-paths.md (new) cross-refs; polyshell.md content |
| H2: Network egress pattern | C2 callback timing, initial beacon shape, TLD preferences from net-patterns.md cross-ref | net-patterns.md existing content |
| H2: Mitigation timeline facts | Advisory publication date, patch availability, first public ITW report (all sourced from public material — TODO markers where exact dates not yet locked, same convention as indicators.md) | Adobe advisory page + NVD CVE + public security reporting |
| H2: What this skill drives | Intent reconstructor's dormant-capability inference for APSB25-94-class PolyShell deployments; synthesizer's reactive rule shaping | indicators.md:50-52 existing framing |
| Footer | Public-source marker | Convention |

### 5.9 `skills/INDEX.md` (modified — additive changes)

Change scope:

```diff
 ## On every synthesizer call
 Always load:

 - `defense-synthesis/modsec-patterns.md` — validated rule shapes for ModSec
 - `modsec-grammar/rules-101.md` (when generating ModSec) OR
   `apf-grammar/basics.md` (when generating APF) — the grammar reference for
   the defense class being generated
+- ALSO IF attack class shows evasion signals (transformation-laden payload,
+  double-encoding, base64-wrapped body)
+    -> load `modsec-grammar/transformation-cookbook.md`
+- ALSO IF capability_map includes C2 callback IOCs AND target is APF
+    -> load `apf-grammar/deny-patterns.md`

 ## When analyzing a host (triage + hunters)
 Route by observable signal:

 ```
-IF stack includes Magento 2.x -> load magento-attacks/admin-paths.md
+IF stack includes Magento 2.x -> load magento-attacks/admin-paths.md
+                                AND magento-attacks/writable-paths.md
   AND IF Adobe advisory patched AFTER earliest suspicious mtime
-    -> load apsb25-94/indicators.md
+    -> load apsb25-94/indicators.md AND apsb25-94/exploit-chain.md
 IF PHP files found outside typical framework paths
   -> load webshell-families/polyshell.md
 IF suspicious outbound callbacks in access.log or auth.log
   -> load linux-forensics/net-patterns.md
 IF cron / systemd units / shell-init / ld.so.preload modified in recent window
   -> load linux-forensics/persistence.md
 IF file flagged but path is inside a known-benign vendor tree
   -> load false-positives/
 IF compromise topology spans multiple hosts on a shared platform
   -> load hosting-stack/cpanel-anatomy.md
+  AND IF host indicates CloudLinux platform (/var/cagefs/ or /var/lve/ present)
+    -> ALSO load hosting-stack/cloudlinux-cagefs-quirks.md
 ```

 ## When producing operator-facing briefs
 Load for format consistency with the team's existing IR voice:

-- `ic-brief-format/template.md` — brief shape, severity vocabulary, artifact
-  conventions, IOC block format
+- `ic-brief-format/template.md` — brief shape, artifact conventions, IOC
+  block format
+- `ic-brief-format/severity-vocab.md` — severity ladder, class-to-severity
+  table, downgrade triggers, notification matrix

 ---

 ## Bundle ownership

 Six operator-authored core files carry the domain voice (no ghostwriting):

 - `ir-playbook/case-lifecycle.md`
 - `webshell-families/polyshell.md`
 - `defense-synthesis/modsec-patterns.md`
 - `false-positives/` (catalog)
 - `hosting-stack/` (shared-tenant quirks)
 - `ic-brief-format/` (brief conventions)

 The rest (`apsb25-94/`, `modsec-grammar/`, `apf-grammar/`, `magento-attacks/`,
 `linux-forensics/`) are scaffolded from public advisory and reference material.

-Target bundle depth: ~20 files (vs CrossBeam's 28). Depth per file over file count.
+Current bundle depth: 20 files (12 mature + 8 public-source scaffold vs
+CrossBeam's 28). Depth per file over file count.
```

---

## 5b. Examples

### 5b.1 Before/after state — skills directory tree

**Before (12 files):**
```
skills/
 |- INDEX.md
 |- apf-grammar/basics.md
 |- apsb25-94/indicators.md
 |- defense-synthesis/modsec-patterns.md
 |- false-positives/  (empty)
 |- hosting-stack/cpanel-anatomy.md
 |- ic-brief-format/template.md
 |- ir-playbook/case-lifecycle.md
 |- linux-forensics/
 |   |- net-patterns.md
 |   \- persistence.md
 |- magento-attacks/admin-paths.md
 |- modsec-grammar/rules-101.md
 \- webshell-families/polyshell.md
```

**After (20 files):**
```
skills/
 |- INDEX.md                                   [MODIFIED]
 |- apf-grammar/
 |   |- basics.md
 |   \- deny-patterns.md                       [NEW]
 |- apsb25-94/
 |   |- indicators.md
 |   \- exploit-chain.md                       [NEW]
 |- defense-synthesis/modsec-patterns.md
 |- false-positives/
 |   |- vendor-tree-allowlist.md               [NEW]
 |   \- backup-artifact-patterns.md            [NEW]
 |- hosting-stack/
 |   |- cpanel-anatomy.md
 |   \- cloudlinux-cagefs-quirks.md            [NEW]
 |- ic-brief-format/
 |   |- template.md
 |   \- severity-vocab.md                      [NEW]
 |- ir-playbook/case-lifecycle.md
 |- linux-forensics/
 |   |- net-patterns.md
 |   \- persistence.md
 |- magento-attacks/
 |   |- admin-paths.md
 |   \- writable-paths.md                      [NEW]
 |- modsec-grammar/
 |   |- rules-101.md
 |   \- transformation-cookbook.md             [NEW]
 \- webshell-families/polyshell.md
```

### 5b.2 Expected verification command output

```bash
$ find skills -name '*.md' | wc -l
20

$ ls skills/false-positives/
backup-artifact-patterns.md
vendor-tree-allowlist.md

$ for d in skills/*/; do printf '%-40s %d\n' "$d" $(find "$d" -name '*.md' | wc -l); done
skills/apf-grammar/                      2
skills/apsb25-94/                        2
skills/defense-synthesis/                1
skills/false-positives/                  2
skills/hosting-stack/                    2
skills/ic-brief-format/                  2
skills/ir-playbook/                      1
skills/linux-forensics/                  2
skills/magento-attacks/                  2
skills/modsec-grammar/                   2
skills/webshell-families/                1

$ grep -L '<!-- public-source authored' skills/*/*.md
(empty — every new file carries the footer; existing scaffolds already have it)

$ grep -c 'Current bundle depth' skills/INDEX.md
1
```

### 5b.3 Example new-file voice — excerpt from `skills/false-positives/vendor-tree-allowlist.md`

```markdown
# false-positives — vendor-tree allowlist patterns

Loaded by the router when a flagged file lands inside a tree that is
composer-managed, plugin-vendored, or otherwise upstream-owned. Pairs with
`backup-artifact-patterns.md` for the non-vendor false-positive class. This
file is the lookup of *what benign vendor content looks like* and *which
properties separate a legitimate vendor file from an attacker-planted one in
the same tree*.

## Magento vendor/ tree

A Magento 2.4 install ships roughly 30,000 files under `vendor/`, all
composer-managed. The directory structure is stable across minor versions:

- `vendor/magento/framework/` — the Magento framework runtime.
- `vendor/magento/module-<name>/` — individual Magento modules. One
  directory per composer package under the `magento/` vendor namespace.
- `vendor/composer/` — composer's own autoloader state.
- `vendor/symfony/`, `vendor/laminas/`, `vendor/tedivm/` — third-party
  dependencies declared in `composer.json`.

Every file under these paths has an upstream hash recorded in
`composer.lock` under `dist.shasum` (composer 2) or integrity field. A
`.php` file in `vendor/magento/framework/View/` whose contents match the
upstream package archive is benign; a `.php` file present on disk but
absent from the fresh `composer install --dry-run` output is attacker
content in a legitimate tree.

<!-- ...continues in similar voice -->

<!-- public-source authored — extend with operator-specific addenda below -->
```

---

## 6. Conventions

All 8 new files follow the same conventions, established by existing scaffolds:

### 6.1 File header + intro

```markdown
# <category> — <specific subject>

Loaded by the router when <trigger>. Pairs with `<sibling-file>.md` for
<complementary role>. This file is the lookup of *<primary content>* and
*<secondary content>*.
```

Every new file opens with this exact shape. The intro paragraph states:
- The category ("false-positives", "apsb25-94", etc.).
- The specific subject of this file (distinguishes from siblings).
- The router trigger that causes this file to load.
- The pair-file (if any) — the complementary file in the same category.
- A two-clause statement of what the file teaches.

### 6.2 Section headers

- H2 (`##`) for major sections.
- H3 (`###`) for sub-sections when needed (sparingly).
- Never H4+. If content needs H4, restructure.
- Section titles match the voice of existing scaffolds (noun phrases, not questions).

### 6.3 Voice

- **Terse, specific.** No hedging phrases ("may", "might", "could be"); swap for direct statements or confidence-tagged claims.
- **Numbers, not adjectives.** "Forty-odd files" not "many files"; "latency of 33 minutes" not "fast".
- **Past tense for historical facts, present for reference statements.** ModSec grammar is present tense; an exploit-chain reconstruction describes what happened in past tense.
- **No future-perfect.** Not "will have been completed" — say "expected complete by <date>".
- **Named actors when attribution matters.** "The attacker drops..." is fine; "someone drops..." is not.
- **Defensive framing throughout.** Per CLAUDE.md section Framing: investigation, case file, audit trail — never offensive vocabulary.

### 6.4 Code blocks

- Fenced with three backticks + language hint (`bash`, `apache`, `php`, `yaml`, `sql`) when syntax highlighting aids reading.
- Concrete examples over abstract placeholders: `/home/alice/public_html/pub/media/.cache/x7k3.php` beats `<path>/<file>.php` when both convey the same fact.
- Comments inside code blocks use `#` or the language's native comment character.

### 6.5 Tables

- Used for structured reference (vocabulary catalogs, severity ladders, path inventories).
- Never nested tables. If nesting tempts, split into two tables.

### 6.6 Source citation

Every new file cites at least one public source in its first 20 lines, using one of two forms:

**URL form (preferred for online references):**
```
See Adobe Security Bulletin APSB25-94:
https://helpx.adobe.com/security/products/magento/apsb25-94.html
```

**Named-reference form (for manpages, specs without URLs, or stable names):**
```
Per ModSecurity Reference Manual v3 — Transformations chapter.
```

At-risk files (see Section 5.4 risk note) should cite more than one source to reinforce the public-anchored provenance.

### 6.7 Footer marker

Every new file ends with exactly:

```markdown
<!-- public-source authored — extend with operator-specific addenda below -->
```

This is the existing convention across scaffolds (see `apf-grammar/basics.md:168`, `hosting-stack/cpanel-anatomy.md:174`, etc.). The marker is intentional: it signals provenance to future readers and marks the file as operator-extensible.

### 6.8 Cross-references

When a file references another skill file, use the repo-relative path:

```markdown
See `webshell-families/polyshell.md` for PolyShell family characteristics.
```

Not `skills/webshell-families/polyshell.md` (the `skills/` prefix is implicit in the context). Not a URL (files are read at runtime from the repo checkout).

---

## 7. Interface Contracts

### 7.1 Router contract

`skills/INDEX.md` is loaded by the case engine, synthesizer, intent reconstructor, and hunter base on every major call (per PRD section 9.3 prompt caching strategy). The file has no machine-readable schema — it is prose + markdown-pseudo-code routing blocks.

**Contract preserved by this spec:**
- Every existing route (lines 13-50) keeps its trigger + target pair.
- New routes follow the same prose + pseudo-code format.
- The `AND` connective indicates additional loading (not replacement).
- The `ALSO IF ...` connective indicates conditional additional loading.
- The `OR` connective (existing line 22-23) indicates exclusive choice — not used in new routes.

### 7.2 File contract

Each skill file is a markdown document loaded as text into prompts. No code parses structure beyond markdown section headers. Contract:

- UTF-8 encoding.
- No embedded binaries, no images.
- No YAML front-matter (none of the existing scaffolds use it; consistency preserved).
- H1 title in the first line (loaded files are listed by their H1 title in the router context; unlabeled files are anonymous to the reasoner).

### 7.3 No CLI change, no config change, no public API change

Skills files are static content. No CLI surface changes. No configuration files change. No public API (HTTP, Python import, or bl-agent shell) changes.

---

## 8. Migration Safety

### 8.1 Test suite impact

`pytest -q` is not affected — skills files are not exercised by the test suite. `tests/` has no test file that reads `skills/*`. Verification: `grep -rn 'skills/' tests/` returns no hits that load file contents.

**Goal verification:** Run full pytest after landing, expect identical pass count.

### 8.2 Install / upgrade path

No install step. Skills files land in the repo as committed markdown; Docker builds copy them into the curator container via the existing `COPY . /app/` in `compose/curator.Dockerfile`. No Dockerfile edit needed.

**Verification:** After landing, `docker compose build curator` succeeds without edits.

### 8.3 Backward compatibility

No prior-version consumers of these files. Prompt caching (per PRD section 9.3) warms on first call after any change — cache invalidation is acceptable and self-healing. No static hash or version marker needs bumping.

### 8.4 Uninstall

Uninstall = revert the commit. No other cleanup required.

### 8.5 CI impact

The project currently has no CI workflow per `.rdf/governance/verification.md`. No CI edits.

### 8.6 Parallel session safety (P38/P39 — landed)

P38/P39 landed during this spec's authoring (commits `29b16d8` P38 new, `44ecb67` P39 sync, `36a85c7` P38 sentinel M-01, `db53a14` P38 sentinel S-02 — all on main). Files touched by this spec are still disjoint from those commits:

| Session | Files owned | Commit range |
|---|---|---|
| This spec (skills expansion) | `skills/**/*.md` (new) + `skills/INDEX.md` (modified) | (pending — Phase S-01) |
| P38 (landed) | `demo/time_compression.py`, `demo/__init__.py`, `tests/test_time_compression.py` | `29b16d8`..`db53a14` |
| P39 (landed) | `demo/script.md` | `44ecb67` |

No overlap. Verification: before committing, `git status` shows only `skills/*` changes; no `demo/*` or `tests/*` changes.

### 8.7 README / docs drift

`README.md` (owned by P42) currently contains prelim prose about skills count. P42's spec (P42.md:73-77) already notes the skills count must match reality. This spec ships the ground-truth count of 20; P42 consumes it. No README edit from this spec.

---

## 9. Dead Code and Cleanup

**No dead code found.** This is additive work. No existing file is deleted or deprecated.

One **pre-existing** finding during codebase reading (documented, not fixed here — out of scope):

- `skills/apsb25-94/indicators.md:11-14, 17-19, 25-26, 28-29, 31-33, 36-37, 40-41` contains `**TODO:**` markers awaiting operator content. This is a known gap tracked in PRD Appendix E; this spec does not modify the file. The new `apsb25-94/exploit-chain.md` lands alongside and fills the companion-content gap without touching indicators.md.

---

## 10a. Test Strategy

**No new tests.** Skills files are not under pytest. This matches the existing convention — the test suite (`tests/test_*.py`) covers code surfaces (case engine, orchestrator, hunters, synthesizer, manifest, intent, CLI); skills files are prompt-context, not code.

Manual verification replaces automated testing:

| Goal | Verification mechanism | Where |
|---|---|---|
| G1 count = 20 | `find skills -name '*.md' \| wc -l` | shell |
| G2 false-positives/ has >=2 files | `ls skills/false-positives/*.md \| wc -l` | shell |
| G3 no dangling INDEX routes | grep INDEX route targets against filesystem | shell |
| G4 public-source citation | `grep` for URL patterns and reference markers in new files | shell |
| G5 LOC envelope | `wc -l` on each new file | shell |
| G6 footer marker | `grep -L 'public-source authored' skills/*/*.md` | shell |
| G7 additive INDEX only | `git diff skills/INDEX.md` structural review | git |
| G8 pytest green | `pytest -q` | existing CI surface |
| G9 no customer data | `grep` sweep for internal-hostname patterns, customer tokens | shell |
| G10 README claim verifiable | File count and directory breakdown match future README text | cross-ref |

Commands detailed in 10b.

---

## 10b. Verification Commands

Each command includes expected output.

```bash
# G1 — count floor met
$ cd /root/admin/work/proj/blacklight
$ find skills -name '*.md' | wc -l
# expect: 20

# G2 — false-positives/ has content
$ ls skills/false-positives/*.md 2>/dev/null | wc -l
# expect: >=2
$ find skills/false-positives -name '*.md' -empty | wc -l
# expect: 0

# G3 — every INDEX route target resolves
$ grep -E 'load [a-z0-9-]+/[a-z0-9-]+\.md' skills/INDEX.md | \
    grep -oE '[a-z0-9-]+/[a-z0-9-]+\.md' | sort -u | \
    while read p; do
        if [ ! -s "skills/$p" ]; then echo "MISSING or EMPTY: skills/$p"; fi
    done
# expect: (no output — all route targets resolve to non-empty files)
$ for d in $(grep -E 'load [a-z0-9-]+/$' skills/INDEX.md | \
             grep -oE '[a-z0-9-]+/$'); do
      n=$(find "skills/$d" -name '*.md' -not -empty | wc -l)
      if [ "$n" -eq 0 ]; then echo "EMPTY DIR ROUTE: skills/$d"; fi
  done
# expect: (no output — every directory route has content)

# G4 — public-source citation in every new file
$ for f in skills/false-positives/vendor-tree-allowlist.md \
           skills/false-positives/backup-artifact-patterns.md \
           skills/hosting-stack/cloudlinux-cagefs-quirks.md \
           skills/ic-brief-format/severity-vocab.md \
           skills/apf-grammar/deny-patterns.md \
           skills/magento-attacks/writable-paths.md \
           skills/modsec-grammar/transformation-cookbook.md \
           skills/apsb25-94/exploit-chain.md; do
      head -20 "$f" | grep -qE '(https?://|Reference Manual|Developer Docs|docs\.|advisory|bulletin|manpage|man page|NVD|CVE)' \
          || echo "NO CITATION in $f"
  done
# expect: (no output — every file cites a public source in its first 20 lines)

# G5 — LOC envelope 80-200
$ for f in skills/false-positives/*.md \
           skills/hosting-stack/cloudlinux-cagefs-quirks.md \
           skills/ic-brief-format/severity-vocab.md \
           skills/apf-grammar/deny-patterns.md \
           skills/magento-attacks/writable-paths.md \
           skills/modsec-grammar/transformation-cookbook.md \
           skills/apsb25-94/exploit-chain.md; do
      n=$(wc -l < "$f")
      if [ "$n" -lt 80 ] || [ "$n" -gt 200 ]; then
          echo "OUT OF ENVELOPE $f: $n lines"
      fi
  done
# expect: (no output — every new file is 80-200 LOC)

# G6 — footer marker on every new file
$ grep -L 'public-source authored — extend with operator-specific addenda' \
    skills/false-positives/*.md \
    skills/hosting-stack/cloudlinux-cagefs-quirks.md \
    skills/ic-brief-format/severity-vocab.md \
    skills/apf-grammar/deny-patterns.md \
    skills/magento-attacks/writable-paths.md \
    skills/modsec-grammar/transformation-cookbook.md \
    skills/apsb25-94/exploit-chain.md
# expect: (no output — every new file has the marker)

# G7 — INDEX additive only (no route removed, no route modified)
# Run pre-commit (against staged index), not against HEAD~1 (which may be an unrelated commit).
$ git diff --cached skills/INDEX.md | grep '^-' | grep -v '^---' | \
    grep -vE '^-Target bundle depth:.*$'
# expect: (no output — the ONLY removed line is the "Target bundle depth: ~20 files ..." claim,
#          which is replaced with "Current bundle depth: 20 files (12 mature + 8 public-source scaffold ...)".
#          No existing route lines are removed.)
$ git diff --cached skills/INDEX.md | grep -cE '^\+.*load [a-z0-9-]+/'
# expect: >=4 (new route additions — several `AND` and `ALSO IF` lines)

# G8 — pytest green
$ PYTHONPATH=. pytest -q 2>&1 | tail -3
# expect: "=== X passed ... ===" with no failures

# G9 — no customer data, no internal references
$ grep -rEi '(liquidweb|liquid[-_]?web|sigforge|depot/polyshell|var/ioc/polyshell_out)' skills/ 2>/dev/null
# expect: (no output)

# G10 — README claim consistency (forward-check; run after P42)
$ grep -c '20 (12 mature + 8' skills/INDEX.md
# expect: 1
```

---

## 11. Risks

Numbered list. Each has a specific mitigation.

### Risk 1 — Voice drift produces slop

**Risk:** Eight new files authored in one pass risk voice drift — if the later files trade off density for completion speed, the bundle reads as "9 matured + 8 AI-generated", which is the exact anti-signal PRD section 15.2 warns against.

**Mitigation:** Conventions section (Section 6) locks the file-header shape, voice rules, and section-structure conventions. The engineer authoring the files must compare voice against `linux-forensics/net-patterns.md` (the most recently-authored scaffold, 68 LOC, public-source-anchored) as the voice reference. The sentinel reviewer checks voice drift as a Pass 3 item.

### Risk 2 — Files in operator-voice categories slide into generic IR boilerplate

**Risk:** Four of the eight new files land in categories CLAUDE.md §Operator-content skills names explicitly (`false-positives/`, `hosting-stack/`, `ic-brief-format/`):
- `skills/false-positives/vendor-tree-allowlist.md`
- `skills/false-positives/backup-artifact-patterns.md`
- `skills/hosting-stack/cloudlinux-cagefs-quirks.md`
- `skills/ic-brief-format/severity-vocab.md`

Each is at risk of sliding into generic "what is a backup file" / "what is a severity level" / "what is CloudLinux" prose. `severity-vocab.md` is the highest-risk because severity vocabularies are a common IR-writeup genre. Generic content here damages the anti-slop signal per PRD section 15.2.

**Mitigation:** Each of the 4 files must anchor in concrete referents:
- `vendor-tree-allowlist.md` → specific Magento `vendor/` subpaths (e.g., `vendor/magento/framework/View/`, `vendor/magento/module-backend/`), specific Composer integrity mechanisms
- `backup-artifact-patterns.md` → specific filename patterns (`.bak`, `.swp`, cPanel backup wheels), specific tool stems (logrotate, mysqldump)
- `cloudlinux-cagefs-quirks.md` → specific paths (`/var/cagefs/<N>/<user>/`, `/var/lve/users/<UID>/`), specific log signatures (`lve_enter` in `/var/log/messages`)
- `severity-vocab.md` → specific classes we stage (webshell = P1 tenant / P0 system; cred-harvester = P0; skimmer on checkout = P0; FP = P3), not abstract definitions

If the first-pass draft of ANY of the 4 files contains any phrase from the slop-smell list (Appendix B), the engineer **re-authors with concrete triggers** — no file substitution. Sentinel (Phase S-02) checks all 4 files against the slop-smell list as a Pass 1 check.

### Risk 3 — Public-source citation gap

**Risk:** A draft may lose its citation during editing, or cite a non-public source (upstream fork of an internal doc, etc.).

**Mitigation:** G4 verification command greps for citation markers in the first 20 lines of every new file. Sentinel reviewer checks citations resolve to public URLs or named public reference material. Automated gate.

### Risk 4 — INDEX.md route semantics break

**Risk:** An INDEX edit could accidentally remove a route or reorder a branch in a way that changes reasoner loading.

**Mitigation:** G7 verification gates on `git diff skills/INDEX.md` showing only additive changes (plus the bundle-depth line edit). Engineer must run `git diff --stat skills/INDEX.md` and confirm delta shape before committing. Sentinel reviews the diff in isolation.

### Risk 5 — TOML/YAML front-matter appears in new files

**Risk:** Some markdown authoring patterns add front-matter; existing scaffolds have none. Adding front-matter is a structural drift that diverges loaded-context shape.

**Mitigation:** Convention rule Section 6.2 — no YAML front-matter. Verification: `grep -l '^---$' skills/*/*.md | head -5` returns empty for new files.

### Risk 6 — P38/P39/P42 file collision

**Risk:** If another session edits a file this spec also edits, commit conflict.

**Mitigation:** Section 8.6 enumerates file ownership. Zero overlap. Engineer runs `git status` before committing and confirms only `skills/*` and intended paths are staged.

### Risk 7 — Hackathon timeline pressure forces incomplete landing

**Risk:** Sat 2026-04-25 18:00 CT recording gate + Sun 2026-04-26 16:00 EDT submission. A file-bundle that lands 7-of-8 doesn't hit the floor.

**Mitigation:** This spec's implementation plan is a single phase (see Section 12 Phase plan). An incomplete landing is a rejected plan — engineer commits all 8 or none. Sentinel gates before commit on count verification.

### Risk 8 — Content references imaginary paths/CVEs

**Risk:** Public-source authorship can still hallucinate specific CVE numbers, exact version strings, or file paths that do not exist in the referenced public material.

**Mitigation:** Per `constraints.md:104` and CLAUDE.md section Data: "When in doubt, ask." Engineer must flag any claim they cannot confirm against the cited public source with `**TODO:**` markers, same convention as `apsb25-94/indicators.md:11-14`. Sentinel checks for unflagged specific-fact claims (CVE numbers, exact dates) and cross-references the cited source.

---

## 11b. Edge Cases

Minimum five entries per spec standard. Mandatory table of input/state combinations requiring explicit handling.

| # | Scenario | Expected behavior | Handling |
|---|---|---|---|
| 1 | `.gitkeep` files exist in 7 scaffold directories (verified: `apf-grammar/`, `false-positives/`, `hosting-stack/`, `ic-brief-format/`, `linux-forensics/`, `magento-attacks/`, `modsec-grammar/`) | `.gitkeep` is scaffold-stage placeholder; once a `.md` file exists in the directory, `.gitkeep` is no longer needed and visually clutters `ls` output (judges skim `ls skills/<dir>/` per PRD Appendix I) | **Phase S-01 deliverable (added):** remove `.gitkeep` from every directory that has at least one `.md` file after the new files land. Stage the deletions alongside the `.md` adds in one commit. Verification: `find skills -name '.gitkeep'` returns empty post-landing. |
| 2 | A new file exceeds 200 LOC | Exceeds target envelope (G5) | Engineer either trims to <=200 or adds an inline rationale paragraph explaining why the subject demands depth. Sentinel enforces. |
| 3 | A new file falls below 80 LOC | Reads as a stub | Reject; expand to meet the floor. If the topic genuinely does not support 80 LOC of useful reference material, drop the file from scope and replace with a different topic from the alternative list (Section 11 Risk 2 substitution candidate). |
| 4 | `skills/INDEX.md` diff shows a route removed | Structural drift | Revert the removal; confirm Section 4.3 additive-only rule. G7 verification gates. |
| 5 | An authoring agent writes `operator-authored` in a new file's provenance line | Misrepresents provenance | Engineer corrects to "public-source authored" to match footer marker. Sentinel check. |
| 6 | A file uses phrases from the slop-smell list (Risk 2) | Generic-boilerplate smell | Immediate substitution per Risk 2 mitigation. Alternative file (cron-artifacts.md) is the escape valve. |
| 7 | Committed file contains a URL that returns 404 | Dead public reference | Acceptable for this spec (we commit with the best available URL; link rot is a separate concern). Engineer should confirm URLs resolve at commit time. If the advisory page moved, update to the redirect target. |
| 8 | pytest fails post-landing | Regression caused by something | This spec does not touch code — a pytest regression means a pre-existing or concurrent code change. Engineer does NOT fix pytest as part of this commit; the failure is flagged and escalated out-of-scope. |
| 9 | `grep` for customer-data tokens (G9) matches in a new file | Accidental reference data leak | Immediate revert. Re-author the affected section from public sources only. Critical failure. |
| 10 | Git commit succeeds but parallel session (P38/P39) has landed a conflicting INDEX.md edit | Merge conflict at `skills/INDEX.md` | Resolve conflict preserving both edits; re-run G3/G7 verification to confirm no route dropped. Re-commit. |

---

## 12. Phase Plan (handed to /r-plan)

**Plan file output (MANDATORY):** `/r-plan` must write to a **named plan file**, not the master `PLAN.md`. The master `PLAN.md` is the in-flight 48-phase hackathon build (currently at P38/39 in a parallel session) and must not be overwritten or appended to by this spec's plan.

**Target path:** `PLAN-skills-expansion.md` at repo root.

This filename matches the glob pattern `PLAN*.md` in `.git/info/exclude` (verified in `.git/info/exclude` line 9), so the named plan stays excluded from commits — consistent with blacklight's git discipline treating PLAN files as working artifacts, not shipped artifacts.

The spec's implementation plan is a single-phase build with a sentinel gate. Simplicity is a feature here — the content is file-disjoint and low-risk.

### Phase S-00 — Governance contradiction fix (pre-authoring, working-file edit only, no commit)

Per workspace CLAUDE.md §"Guiding Principles" — "Spec Contradictions Must Be Fixed at the Source". The spec found three inconsistent skill-count statements in `.rdf/governance/constraints.md`:

- Line 45: "Skills bundle: **25 files minimum**"
- Line 71: "~20 files minimum"
- Line 83: "Skills bundle: 25 files minimum"

All three contradict CLAUDE.md §"Never cut" (>=20) and PRD section 4.3 + Appendix E (explicit 20-file target). Resolution:

**Dispatcher:** rdf-engineer (same single agent; folds into Phase S-01 dispatch as pre-work).

**Deliverable:** Update `.rdf/governance/constraints.md` lines 45, 71, 83 to the authoritative number with pointer to the canonical source:

- Line 45: `Skills bundle: **>=20 files** with decision-tree router at \`skills/INDEX.md\` (per CLAUDE.md §"Never cut"; 25 was a pre-scaffold-era target, reconciled 2026-04-23)`
- Line 71: `skills bundle depth (>=20 files per CLAUDE.md §"Never cut")`
- Line 83: `Skills bundle: >=20 files minimum. Three load-bearing operator-written files: \`case-lifecycle.md\`, \`polyshell.md\`, \`modsec-patterns.md\`. Router at \`skills/INDEX.md\`.`

**Commit scope:** none. `.rdf/governance/` is in `.git/info/exclude:20` (verified). These are working-file edits, not committed artifacts.

**Acceptance gate:** `grep -E '25 files|~20 files' .rdf/governance/constraints.md` returns empty post-edit.

**Rationale for no-commit:** Governance files are operator-working state. Per blacklight CLAUDE.md §"Git discipline", `.rdf/` is never committed. The fix is local-state reconciliation, not a shipped artifact. It exists to prevent future sessions (and future-Claude) reading `constraints.md` and treating this spec as incomplete.

### Phase S-01 — Author 8 skill files + additive INDEX.md update + remove obsolete .gitkeep files (single commit)

**Dispatcher:** rdf-engineer (single agent, sequential — per Brainstorm Q5).

**Inputs:**
- This spec (docs/specs/2026-04-23-skills-bundle-expansion-design.md)
- Existing scaffold files as voice reference (especially `linux-forensics/net-patterns.md`, `hosting-stack/cpanel-anatomy.md`)
- Public-source anchors per Section 5 inventory
- `skills/INDEX.md` current state

**Deliverables:**
1. `skills/false-positives/vendor-tree-allowlist.md` (80-200 LOC, public-source-cited, footer marker)
2. `skills/false-positives/backup-artifact-patterns.md` (same)
3. `skills/hosting-stack/cloudlinux-cagefs-quirks.md` (same)
4. `skills/ic-brief-format/severity-vocab.md` (same — no substitution; re-author if slop-smell triggers per Risk 2)
5. `skills/apf-grammar/deny-patterns.md` (same)
6. `skills/magento-attacks/writable-paths.md` (same)
7. `skills/modsec-grammar/transformation-cookbook.md` (same)
8. `skills/apsb25-94/exploit-chain.md` (same)
9. `skills/INDEX.md` updates per Section 5.9 diff
10. Delete obsolete `.gitkeep` files from 7 scaffold directories (`apf-grammar/`, `false-positives/`, `hosting-stack/`, `ic-brief-format/`, `linux-forensics/`, `magento-attacks/`, `modsec-grammar/`) — per edge-case #1

**Commit message (per workspace CLAUDE.md section Commit Protocol for blacklight):**
```
[New] skills — 8 public-source scaffold files + INDEX routing updates (20-file floor)

[New] skills/false-positives/{vendor-tree-allowlist,backup-artifact-patterns}.md
[New] skills/hosting-stack/cloudlinux-cagefs-quirks.md
[New] skills/ic-brief-format/severity-vocab.md
[New] skills/apf-grammar/deny-patterns.md
[New] skills/magento-attacks/writable-paths.md
[New] skills/modsec-grammar/transformation-cookbook.md
[New] skills/apsb25-94/exploit-chain.md
[Change] skills/INDEX.md — additive routing extensions for new files + bundle-depth claim
[Change] skills/*/.gitkeep — removed from 7 directories now populated with content
```

**Acceptance gates (all must pass):**
- G1: file count = 20
- G2: false-positives/ has >=2 files
- G3: INDEX routes all resolve to non-empty content
- G4: every new file cites a public source in first 20 lines
- G5: every new file is 80-200 LOC
- G6: every new file has the footer marker
- G7: INDEX diff is additive-only (no route removed)
- G8: pytest green
- G9: no customer-data leak

### Phase S-02 — Sentinel review (rdf-reviewer in sentinel mode, post-impl)

**Dispatcher:** rdf-reviewer (sentinel mode).

**Scope:** All 8 new files + the INDEX edit.

**Four sentinel passes:**
1. **Voice/slop pass** — does each file read as domain-reference or as generic AI-generated IR/SOC text?
2. **Public-source provenance pass** — does every cited source resolve to a public URL or named public reference?
3. **Dead-code / dangling-reference pass** — does every cross-reference in every new file point at an existing file?
4. **INDEX integrity pass** — does every INDEX route resolve to a non-empty file/directory?

**Verdict:**
- APPROVE: commit stands; spec complete.
- CONCERNS: engineer fixes inline or via fixup commit; re-dispatch.
- REJECT (>=3 MUST-FIX findings): engineer re-authors affected files.

### Phase S-03 (conditional) — Fix findings + fixup commit

Only runs if S-02 returns CONCERNS or REJECT.

---

## 13. Open Questions

None. All design decisions resolved in Phase 2 Brainstorm — recorded in `.rdf/work-output/spec-progress.md`.

One noted inconsistency for operator awareness (not blocking this spec):

- `.rdf/governance/constraints.md:45,83` states "25 files minimum"; `constraints.md:71` states "~20 files minimum". This spec hits 20 (the superseding CLAUDE.md and PRD number). The 25 target stays as post-hackathon stretch, tracked in FUTURE.md. No immediate operator action required; governance can be reconciled in a post-hackathon pass.

---

## Appendix A — Voice reference excerpt (for engineer)

The target voice for new files, reproduced from `skills/linux-forensics/net-patterns.md:27-38` as the most-recent scaffold authored in this spec's style:

> ## Callback request shapes
>
> Web-shell callbacks have a small set of recognizable request shapes. The shape is more durable than the destination — domains rotate, the structural pattern persists.
>
> - **Unconditional POST on every command dispatch.** PolyShell-class shells (see `webshell-families/polyshell.md`) call back on every handler dispatch. The body is typically small (under 1 KB) and includes an identifier, a timestamp, and a checksum or HMAC. The request method is POST; the path is short; the User-Agent is generic (`curl/7.x`, `python-requests`, sometimes spoofed to a browser string).

Traits to replicate:
- Bold lead sentence names the pattern.
- Body describes the shape with concrete values (under 1 KB, specific header names).
- Cross-references by repo-relative path.
- No hedging. No "might be". No "threat actors".

## Appendix B-pre — Reviewer findings disposition (2026-04-23 challenge review)

The challenge-mode reviewer returned CONCERNS with 3 MUST-FIX, 4 SHOULD-FIX, 3 INFORMATIONAL findings. Disposition:

| ID | Finding | Disposition | Where fixed |
|---|---|---|---|
| MUST-FIX-1 | Governance contradiction in `constraints.md` (25 vs ~20) papered over | **ACCEPTED** | New Phase S-00 in Section 12 |
| MUST-FIX-2 | Mid-phase `severity-vocab`->`cron-artifacts` substitution silently changes commit artifact | **ACCEPTED** | Substitution removed from Section 5.4, 11 Risk 2, Section 12 Phase S-01 deliverables |
| MUST-FIX-3 | Spec distribution (8 files) diverges from PRD App E (14) without rationale | **ACCEPTED** | Distribution rationale added to Section 4.2 |
| SHOULD-FIX-1 | G7 verification uses wrong base (`HEAD~1`) | **ACCEPTED** | Switched to `git diff --cached` in Section 10b |
| SHOULD-FIX-2 | Section 6.1 "Loaded by the router when..." template doesn't match existing scaffolds | **REJECTED** | Evidence: `grep -l 'Loaded by the router' skills/*/*.md` returns **10 of 10** existing scaffolds (`ic-brief-format/template.md`, `webshell-families/polyshell.md`, `apsb25-94/indicators.md`, `linux-forensics/persistence.md`, `defense-synthesis/modsec-patterns.md`, `magento-attacks/admin-paths.md`, `apf-grammar/basics.md`, `linux-forensics/net-patterns.md`, `hosting-stack/cpanel-anatomy.md`, `modsec-grammar/rules-101.md`). The pattern is uniform; Section 6.1 reflects reality, not drift. Reviewer's claim about `net-patterns.md` was incorrect — that file's first line reads "Loaded by the router when access.log or auth.log shows suspicious outbound callbacks." |
| SHOULD-FIX-3 | `.gitkeep` files (7 verified) should be removed from populated directories | **ACCEPTED** | Added to Section 12 Phase S-01 deliverable #10; edge-case #1 updated |
| SHOULD-FIX-4 | Section 4.6 is a route map, not a dependency tree | **ACCEPTED** | Added Section 4.6a Cross-Reference Adjacency Table; renamed 4.6 -> 4.6b |
| INFO-1 | Risk 2 only names `severity-vocab` but applies to 4 operator-voice files | **ACCEPTED** | Section 11 Risk 2 expanded to all 4 files |
| INFO-2 | P38/P39 have landed; Section 8.6 language is stale | **ACCEPTED** | Section 8.6 updated with commit hashes |
| INFO-3 | "Grow existing scaffolds" alternative should be explicitly rejected | **ACCEPTED** | Alternative rejection added to Section 4.2 distribution rationale |

**All MUST-FIX findings resolved.** Verdict expected to move from CONCERNS to APPROVE on re-review; in the interest of the operator-absent timeline, proceeding to commit without a second review cycle per CLAUDE.md §Execution posture ("Proceed with the best-informed draft"). If the first /r-plan pass surfaces spec gaps, they will be addressed as plan-drafting feedback — cheaper than a second review cycle on a 1200-LOC spec.

## Appendix B — Slop-smell list (Risk 2 trigger words)

If the first-pass draft of any new file contains any of these phrases, immediate substitution is warranted per Risk 2. List is public-common-noun-level markers, not exhaustive:

- "In today's threat landscape"
- "Threat actors employ"
- "Security professionals must"
- "Cyber criminals / bad actors" (as abstract subjects without specific attribution)
- "As organizations face increasing threats"
- "A comprehensive security posture"
- "Defense-in-depth strategy" (when used as a theme header, not as a specific technical referent)
- "In the rapidly evolving"
- "Key stakeholders"
- "Leveraging" (when replaceable by "using")

Grounded technical language ("blocked at the edge", "mtime clustering within a 300-second window", "POST body > 8192 bytes") is the opposite smell — that is the target.
