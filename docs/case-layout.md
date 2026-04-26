# `bl-case/` directory contract

Canonical per-case memory-store directory contract. Every motion that reads or writes case state (M2 case templates, M5 `bl consult`/`bl run`/`bl case`, M6 `bl defend`, M7 `bl clean`) binds against this file. Promoted from `DESIGN.md §7.2` and expanded with a **writer-owner table** the motion-map needs before parallel worktrees start fighting over `hypothesis.md` edits.

---

## 1. Purpose

One workspace contains one `bl-case` memory store (see `DESIGN.md §7.2`). Inside that store lives:

- One **workspace roster** file (`INDEX.md`) that lists every case + pointers to closed briefs.
- One **per-case subtree** under `bl-case/CASE-<YYYY>-<NNNN>/` containing hypothesis state, evidence pointers, agent-proposed steps, wrapper-written results, remediation actions, and case closure artifacts.

M2 owns the **templates** written on `bl case --new`. M5 owns **the case lifecycle** (open → active → close). M6 writes **action proposals** into `actions/pending/`; the wrapper promotes them to `actions/applied/` on operator approval. Every write is auditable — the memory store's `memver_` versioning provides a 30-day immutable audit trail per Managed Agents platform contract.

---

## 2. Tree

Reproduces `DESIGN.md §7.2` lines 368–392 verbatim. This tree is canonical; additions require a §3 writer-owner row + a DESIGN.md §7.2 patch (or a waiver with rationale inline — see §7 change control).

```
bl-case/
├── INDEX.md                          # workspace case roster + pointers to closed briefs
├── CASE-<YYYY>-<NNNN>/
│   ├── hypothesis.md                 # current hypothesis + confidence + reasoning
│   ├── history/<ISO-ts>.md           # each hypothesis revision immutable
│   ├── evidence/                     # pointer-style, one per observation
│   │   ├── evid-<id>.md              # {source, sha256, summary, file_id?}
│   │   └── obs-<id>-<kind>.json      # raw observation output (JSONL usually)
│   ├── attribution.md                # kill chain (upload/exec/persist/lateral/exfil)
│   ├── ip-clusters.md                # IP cluster analysis per skills/ioc-aggregation
│   ├── url-patterns.md               # URL evasion → generalized regex
│   ├── file-patterns.md              # magic bytes + naming → yara synthesis
│   ├── open-questions.md             # unresolved; gates case close
│   ├── pending/                      # agent-emitted proposed steps
│   │   └── s-<id>.json
│   ├── results/                      # wrapper-written step results
│   │   └── s-<id>.json
│   ├── actions/
│   │   ├── pending/<act-id>.json     # awaiting operator approval
│   │   ├── applied/<act-id>.json     # applied; carries retire-hint
│   │   └── retired/<act-id>.json     # closed; no longer active
│   ├── defense-hits.md               # running log of blocks that fired
│   ├── closed.md                     # present iff case closed: brief file_ids + retirement schedule
│   └── STEP_COUNTER                  # wrapper-managed step-id allocator (see §3 note)
```

---

## 3. Writer-owner contract

**Preamble.** Every path below is labeled with `{writer, when, cap, lifecycle}` where:

- **writer** ∈ `{curator, wrapper, operator}` — the only actor permitted to create or modify the path. Cross-writes (e.g., the wrapper editing `hypothesis.md`) are policy violations and are logged.
- **when** ∈ `{on-open, on-step-emit, on-step-run, on-action-apply, on-close, on-hypothesis-revision, on-evidence-ingest, allocated-on-demand}` — the event that triggers the write.
- **cap** — approximate per-file size cap. The Managed Agents platform enforces 100 KB per file; the numbers here are target steady-state footprint.
- **lifecycle** ∈ `{mutable, append-only, immutable-after-write, immutable-after-close, monotonic-non-decreasing}` — how the path evolves over the case's life.

**Note on `STEP_COUNTER`:** `STEP_COUNTER` is referenced by `schemas/step.md §step_id` as the wrapper's step-id allocator state file — the curator requests a fresh `s-NNNN` from the counter before emitting a `report_step`. The path is NOT listed in DESIGN.md §7.2 tree at spec authoring time (`4ec1c23`); this doc adds it to the canonical per-case layout. A later DESIGN.md §7.2 edit to unify is welcomed and does not require re-issuing this doc (§7 change control permits it).

| Path | Writer | When | Cap | Lifecycle |
|------|--------|------|-----|-----------|
| `bl-case/INDEX.md` | wrapper | on-open + on-close | 100 KB workspace-wide | append-mostly; closed-case lines may be edited to update brief `file_id` |
| `bl-case/CASE-<id>/hypothesis.md` | curator | on-open + on-hypothesis-revision | 50 KB | mutable; previous values archived to `history/` before in-place update |
| `bl-case/CASE-<id>/history/<ISO-ts>.md` | curator | on-hypothesis-revision (before mutating hypothesis.md) | 20 KB | append-only; immutable after write |
| `bl-case/CASE-<id>/evidence/evid-<id>.md` | curator | on-evidence-ingest | 10 KB | immutable-after-write; carries `{source, sha256, summary, file_id?}` |
| `bl-case/CASE-<id>/evidence/obs-<id>-<kind>.json` | wrapper | on-evidence-ingest (paired with evid-<id>.md) | 50 KB | immutable-after-write; JSONL raw observation |
| `bl-case/CASE-<id>/attribution.md` | curator | on-hypothesis-revision (when kill chain advances) | 40 KB | mutable; typically edited ≤10 times per case |
| `bl-case/CASE-<id>/ip-clusters.md` | curator | on-evidence-ingest (after IP aggregation) | 30 KB | mutable; grows as evidence compounds |
| `bl-case/CASE-<id>/url-patterns.md` | curator | on-evidence-ingest (after URL-pattern generalization) | 20 KB | mutable |
| `bl-case/CASE-<id>/file-patterns.md` | curator | on-evidence-ingest (after magic/yara synthesis) | 20 KB | mutable |
| `bl-case/CASE-<id>/open-questions.md` | curator | on-hypothesis-revision (gates case-close) | 15 KB | mutable; must be empty (or explicit "none") for case-close |
| `bl-case/CASE-<id>/pending/s-<id>.json` | curator (via `report_step`) | on-step-emit | 10 KB | mutable until `bl run`; then the wrapper moves the file to `results/` and clears `pending/` |
| `bl-case/CASE-<id>/results/s-<id>.json` | wrapper | on-step-run | 50 KB | immutable-after-write |
| `bl-case/CASE-<id>/actions/pending/<act-id>.json` | curator (via `synthesize_defense`) | on-step-emit (from `synthesize_defense` tool) | 40 KB | mutable until operator `bl run --yes`; then wrapper moves to `applied/` |
| `bl-case/CASE-<id>/actions/applied/<act-id>.json` | wrapper | on-action-apply | 40 KB | immutable-after-write; carries `applied_at`, `backup_path`, `retire_hint` |
| `bl-case/CASE-<id>/actions/retired/<act-id>.json` | wrapper | on-retire (manual removal, case-close, or retire_hint trigger) | 40 KB | immutable-after-close |
| `bl-case/CASE-<id>/defense-hits.md` | wrapper | on-evidence-ingest (when a new block-hit record ingests for an applied action) | 30 KB | append-only |
| `bl-case/CASE-<id>/closed.md` | wrapper | on-close | 20 KB | present-iff-closed; immutable-after-close; carries brief `file_id`s + retirement schedule |
| `bl-case/CASE-<id>/STEP_COUNTER` | wrapper | allocated-on-demand (pre-step-emit); incremented at each allocation | 16 bytes | mutable; monotonic non-decreasing |

**Implications for parallel work:**

- M2 templates (case-open skeleton): wrapper writes every path except `hypothesis.md` and `history/`, `attribution.md`, `ip-clusters.md`, `url-patterns.md`, `file-patterns.md`, `open-questions.md` (which are curator-written on first revision). Templates exist as empty-or-placeholder skeletons.
- M5 `bl case --new`: wrapper-only writes (INDEX.md append + directory skeleton). No curator interaction until `bl consult --attach` elevates the case into an active session.
- M6 + M7 never write to `hypothesis.md` or `history/` — only to `actions/pending/` (for `defend` proposals) and `backups/` (out-of-tree, under `/var/lib/bl/`).
- Curator never writes to `results/` or `actions/applied/` — those are wrapper-authored, wrapper-immutable.

---

## 4. Size budget

Managed Agents platform caps every memory-store file at 100 KB (see `docs/internal/managed-agents.md §memory_stores.file_size`). The caps in §3 are steady-state targets — if any file approaches 80 KB, the wrapper emits a warning and the curator's `open-questions.md` gets a new entry to compress, split, or promote-to-Files.

**Per-case steady-state estimate** (assuming ~50 evidence ingests, ~20 step emits, ~10 action applies):

| Bucket | Files | Total size |
|--------|-------|------------|
| hypothesis + history (10 revisions) | 11 | ~250 KB |
| evidence (50 obs) | 100 | ~3 MB (obs-<id>-<kind>.json is the largest) |
| pointer-kind files (attribution, ip-clusters, url-patterns, file-patterns, open-questions) | 5 | ~125 KB |
| pending + results (20 steps) | 40 | ~1.2 MB |
| actions (10 applies) | 30 | ~1.2 MB |
| defense-hits | 1 | ~30 KB |
| STEP_COUNTER | 1 | 16 bytes |
| **Total per case** | **~190 files** | **~6 MB** |

Memory stores tolerate this footprint (platform spec documents no aggregate cap per store). Workspace-wide with ~20 concurrent cases = ~120 MB, well within Managed Agents limits.

---

## 5. Lifecycle transitions

```
CASE-OPEN ─► ACTIVE ─► CLOSED
   │            │         │
   │            │         └─► INDEX.md line mutated to carry brief file_id
   │            │             closed.md written (immutable-after-close)
   │            │             actions/retired/ sweep (per retire_hint)
   │            │
   │            ├─► step loop (curator report_step → pending → bl run → results)
   │            ├─► action loop (curator synthesize_defense → actions/pending → bl run --yes → actions/applied)
   │            ├─► hypothesis revision (history/<ISO-ts>.md written before hypothesis.md mutated)
   │            └─► evidence ingest (evid-<id>.md + obs-<id>-<kind>.json written)
   │
   └─► INDEX.md line appended
       empty skeleton templates materialized (per M2)
       STEP_COUNTER initialized to 0
       hypothesis.md placeholder written ("investigation open, no hypothesis yet")
```

**Blocking conditions:**

- `bl case close` requires `open-questions.md` to be empty (or contain the literal `none`). Wrapper rejects with exit 68 otherwise.
- `bl case close` requires every `pending/s-<id>.json` to have a paired `results/s-<id>.json` (no un-run steps).
- `bl case close` requires every `actions/applied/<act-id>.json` to have a `retire_hint` field (even if the hint is `manual`).
- Case cannot be re-opened after close — operator runs `bl case --new --split-from <closed-id>` to create a linked successor case.

---

## 6. INDEX.md format

Workspace roster. One line per case. Wrapper-maintained. Shape:

```
| Case | Opened | Status | Hypothesis (30-char preview) | Closed brief (file_id) |
|------|--------|--------|------------------------------|-------------------------|
| CASE-2026-0007 | 2026-04-24T14:00Z | active | polyshell staging on host-2 | — |
| CASE-2026-0006 | 2026-04-23T18:00Z | closed | magecart skimmer, host-5 | file_011C... |
```

Update events:

- `bl case --new`: append one row; `Status: active`; brief `file_id` column is `—`.
- `bl case close`: mutate the case's row — `Status: closed` + populate brief `file_id`.
- `bl case reopen`: not supported; see §5.

---

## 7. History append discipline

`bl-case/CASE-<id>/history/<ISO-ts>.md` is append-only. Each file captures one hypothesis revision. Filename = the ISO-8601 timestamp of the revision (millisecond precision permitted for ordering tight-loop revisions).

Shape:

```
# Hypothesis revision — <ISO-ts>

## Prior
<copy of the prior hypothesis.md contents>

## New
<copy of the new hypothesis.md contents>

## Trigger
<one paragraph — the evidence, open question, or external input that drove the revision>

## Open questions
<any new unresolved lines the revision introduces; forwarded to open-questions.md>
```

Curator writes the history file BEFORE mutating `hypothesis.md`. If the write fails (memory store quota, network), the mutation is aborted — consistency > performance.

**Never edit a history file in place.** Even typo fixes get a new revision. `git blame` — or in this case `memver_` audit — is the only source of truth for when a claim was made.

---

## 8. Pending vs results

Enforced separation:

- `pending/s-<id>.json` is **curator-written** (via `report_step` custom tool — see `DESIGN.md §12.1.1`). Wrapper reads it for `bl run`, never modifies it.
- `results/s-<id>.json` is **wrapper-written** after `bl run` executes. Curator reads it for evidence-revision; never modifies it.
- When `bl run` completes, the wrapper moves `pending/s-<id>.json` → `results/s-<id>.json` with the result payload appended. This is the only directory the wrapper mutates on behalf of a curator-authored step.

Cross-writes are forbidden. The wrapper's system sanity check runs on every boot: `find bl-case -path '*/pending/*' -newer <bl-case/CASE-*/STEP_COUNTER>` should return nothing — if it does, something wrote to `pending/` outside the curator's step-emit path.

---

## 9. Actions pending → applied → retired

Three states, linear transitions:

- `actions/pending/<act-id>.json` — written by the curator via `synthesize_defense` (`DESIGN.md §12.2`). Wrapper runs kind-specific FP-gate (modsec: `apachectl -t`; firewall: ASN safelist check; sig: FP-corpus scan) before promotion.
- `actions/applied/<act-id>.json` — wrapper writes after `bl run --yes` successfully applies. Carries `applied_at`, `backup_path`, `retire_hint` (conditions under which the wrapper should retire the action — e.g., "retire if no defense-hits in 14 days").
- `actions/retired/<act-id>.json` — wrapper writes when one of: (a) operator runs `bl defend <kind> --remove <id>`; (b) `retire_hint` fires; (c) case closes. The retired JSON preserves the full apply payload + retirement reason + `retired_at`.

Retired actions stay in the store for the memstore's 30-day audit window. After that they age out of `memver_` but the local ledger (`/var/lib/bl/ledger/<case>.jsonl`) preserves the full history indefinitely.

---

## 10. Local mirrors

**`bl-case/` is remote (memory store).** **`/var/lib/bl/ledger/<case-id>.jsonl` is local (append-only).** Dual-write per `DESIGN.md §13.4`.

Dual-write protects against:

- **Memory corrupted / workspace wiped:** local ledger preserves the full action history; operator reconstructs via `bl case log --from-ledger`.
- **Host wiped:** remote memstore preserves hypothesis + evidence + actions; new host's `/var/lib/bl/` boots empty and re-reads from memstore on next `bl consult`.

The ledger is NOT a cache — it is authoritative for local state after a memstore wipe. `bl case log --audit` prints the ledger in a regulator-friendly format regardless of memstore reachability.

---

## 11. Path C primitives — Files API evidence paths (M13)

M13 (Skills primitive realignment) migrated per-case evidence blobs from the `bl-case`
memstore to the Anthropic Files API. The memstore retains hypothesis + steps + working
memory only; raw evidence and summaries live in mounted Files.

### Evidence path convention

| Kind | Path in Files API mount | Description |
|------|------------------------|-------------|
| Raw observation bundle | `/case/<id>/raw/<source>.<ext>` | JSONL observation output (was `bl-case/<id>/evidence/obs-<id>-<kind>.json`) |
| Summary | `/case/<id>/summary/<source>.md` | curator-authored evidence summary (was `bl-case/<id>/evidence/evid-<id>.md`) |

`<source>` is a kebab-slug derived from the observation command (e.g., `apache-log`, `mtime-cluster-fs`, `htaccess`). `<ext>` is `jsonl` for structured observation output, `json` for single-record envelopes.

### Per-case Files mounts vs memstore working-memory keys

| Surface | Holds | Mount point | Access |
|---------|-------|-------------|--------|
| Files API | Raw evidence bundles + closed-case briefs + shell samples | `/case/<id>/raw/` + `/case/<id>/summary/` | hot-attachable mid-session via `sessions.resources.add` |
| `bl-case` memstore | Hypothesis + steps (pending + results) + actions + open-questions + attribution | `bl-case/CASE-<id>/` key prefix | always-on read_write |

Key invariant: the Files API is the blob store; the memstore is the reasoning scratchpad.
Evidence is uploaded to Files on observation (`bl observe`) and attached to the curator
session at `bl consult`. After `bl case close`, the per-case Files are moved to
`files_pending_deletion[]` in `state.json` and deleted by `bl setup --gc` once no live
sessions hold them.

See also: `DESIGN.md §3.4` (Primitives map), `docs/managed-agents.md §11` (Path C primitives map).

---

## 12. Change control

Additions to the tree: new path → §3 writer-owner row (required) + §2 tree entry (or waiver inline) + M2 template update if on-open-materialized + any consuming handler (M5/M6/M7/setup) updated. Reviewer flags missing targets as MUST-FIX.

Renames: not recommended; remote memstore carries historical paths for 30 days under old names, and the curator's context window persists prior paths in-session. If a rename is required, run it as a two-commit dance: (1) emit under both old and new paths for one memory-store versioning cycle; (2) stop emitting under old path. Never rename with a hard cutover.

Removals: only if no M2/M5/M6/M7 handler writes the path. Grep `bl_*_*()` function bodies across `bl` for every reference before removing.

Unification with `DESIGN.md §7.2`: welcomed at any time; the §7.2 tree block can grow or add entries that this file already covers. No re-issue of this doc is required. The `STEP_COUNTER` row in §3 is the canonical forward-reference; a DESIGN.md §7.2 edit to add it closes that loop.
