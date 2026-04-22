# Day 2 — Hunters + First Case Materialization (Design Spec)

**Date:** 2026-04-22
**Checkpoint:** Wed 2026-04-22 22:00 CT (per HANDOFF.md §"Day 2 checkpoint")
**Authoritative sources:** HANDOFF.md §"Day 2 — Wednesday April 22" (lines 347–358) · EXHIBITS.md §"PolyShell staging (host-2...)" · `.rdf/governance/architecture.md` · `.rdf/governance/constraints.md` · `.rdf/governance/anti-patterns.md`
**Non-authoritative design input:** spec-progress.md decisions (Q1–Q4)

---

## Section 1 — Problem Statement

Day 1 scaffold landed: repo, GPL v2, locked Pydantic case-file schema (`curator/case_schema.py`, 138 LOC), 3-host Compose with curator + host-2 Apache/ModSec + host-3 Nginx-clean, Managed Agents scaffold (`curator/managed_agents.py`, 185 LOC), skills router + 4 stubs, `tests/test_revision.py` with 6 skipped fixtures and 2 parse-check tests assuming `CASE-2026-0007` at confidence 0.4.

Day 2 must ship the evidence-collection layer — three parallel hunters, evidence sqlite store, orchestrator v1 that consumes a bl-report tar from the inbox and produces one materialized case file. Current state of `curator/hunters/` is empty; orchestrator does not exist; evidence schema not written; `bl-report` collects `ps auxwwf` + `ss -tlnp` only and does not collect filesystem scope.

Without Day 2 landing tonight, Day 3's load-bearing hypothesis-revision work has no input to revise. The checkpoint is a hard prerequisite for Thursday 22:00 CT's go/no-go gate.

## Section 2 — Goals

1. **Evidence schema** — sqlite table `evidence` at `curator/storage/evidence.db` holds structured rows from hunter output; schema columns match HANDOFF envelope.
2. **Three hunters** — `fs_hunter`, `log_hunter`, `timeline_hunter` as async Python functions calling Sonnet 4.6 with extended thinking **off**, writing summarized evidence rows (no raw log lines).
3. **Orchestrator v1** — accepts a bl-report tar path, extracts, dispatches hunters in parallel via `asyncio.gather`, writes evidence rows, opens `CASE-2026-0007` at confidence 0.4, writes `curator/storage/cases/CASE-2026-0007.yaml` deserializable via existing `load_case()`.
4. **bl-report scope extension** — collects configurable filesystem paths (default `/var/www/html /var/log/apache2 /etc/cron.d`) into the tar envelope; stays under 400-line bl-agent budget.
5. **Hunter prompts** — three `prompts/{fs,log,timeline}-hunter.md` files, VOICE.md-compliant, loaded by hunter module at call time; skills-routed per `skills/INDEX.md`.
6. **End-to-end acceptance** — `python -m curator.orchestrator <tar-path>` produces evidence.db rows + `CASE-2026-0007.yaml` that `test_case_state_a_parses` passes against (already-written Day 1 assertion).
7. **Deterministic initial hypothesis** — no model call; synthesized from hunter output via template; preserves Day-3 revision-test baseline isolation.
8. **Operator gates preserved** — case-file schema untouched; operator-content skill files stay stubs; PolyShell staging surfaces as operator-review ASK before commit.

## Section 3 — Non-Goals

- **NOT** case-engine revision logic — `curator/case_engine.py` does not exist this spec; Day 3.
- **NOT** intent reconstructor — Day 4.
- **NOT** synthesizer — Day 4.
- **NOT** `bl-ctl` CLI beyond `cat` + grep wrappers — out per constraints.md.
- **NOT** net-hunter (4th hunter) — pre-cut.
- **NOT** live Managed Agents integration — curator Managed Agent wraps the async orchestrator Day 3+; scaffold stays as-is this phase.
- **NOT** schema changes to `curator/case_schema.py` — locked Day 1; change requires operator gate (HANDOFF.md line 225).
- **NOT** authoring operator-content skill files (`case-lifecycle.md`, `polyshell.md`, `modsec-patterns.md`) — stubs remain stubs.
- **NOT** host-3 Nginx hunter coverage this phase — host-3 sits in compose unaffected.
- **NOT** host-4 PolyShell staging this phase — EXHIBITS.md §"Build order" schedules host-4 for "Day 2 (expand)" but that's a compose-level expansion. Actual staging is **deferred to Day 3 morning** (before the Day 3 revision smoke test, which needs a second host's tar to produce a conf 0.4 → 0.6 revision). This deferral is explicit to protect tonight's 22:00 CT checkpoint; surfacing as a Day 3 AM task so the deadline is set, not silent.
- **NOT** inbox watcher thread in Flask — orchestrator invoked via CLI for Day 2 smoke; Flask wiring Day 3+.
- **NOT** evidence.db migration or versioning — fresh schema, no back-compat needed.

## Section 4 — Architecture

### 4.1 File map

| File | Status | Est. lines | Purpose |
|---|---|---|---|
| `curator/evidence.py` | NEW | ~180 | sqlite schema + CRUD: `init_db()`, `insert_evidence()`, `fetch_by_case()`, `fetch_by_report()` |
| `curator/hunters/__init__.py` | NEW | ~30 | Exports `run_hunters()` entry point + `HunterInput`/`HunterOutput` dataclasses |
| `curator/hunters/base.py` | NEW | ~90 | Shared async Sonnet 4.6 call helper, prompt loader, evidence row construction |
| `curator/hunters/fs_hunter.py` | NEW | ~80 | Walks extracted filesystem, flags unusual PHP paths, mtime clusters, SUID, permission oddities |
| `curator/hunters/log_hunter.py` | NEW | ~80 | Parses access.log / auth.log for URL-evasion + outbound-callback patterns |
| `curator/hunters/timeline_hunter.py` | NEW | ~80 | Correlates mtime events + log events into a chronological feed |
| `curator/orchestrator.py` | NEW | ~210 | CLI + library entry; extracts tar, dispatches hunters, writes evidence, opens case; deterministic initial hypothesis |
| `curator/report_envelope.py` | NEW | ~80 | Pydantic models for bl-report tar envelope (manifest.json inside tar) + parsing |
| `prompts/fs-hunter.md` | NEW | ~60 | System prompt, VOICE-compliant, loaded at hunter call time |
| `prompts/log-hunter.md` | NEW | ~60 | Same, log scope |
| `prompts/timeline-hunter.md` | NEW | ~60 | Same, correlation scope |
| `bl-agent/bl-report` | MODIFY | +40 (→104) | Accept `BL_REPORT_PATHS` env, collect scoped filesystem + logs into tar; write `manifest.json` inside tar with host_id/collected_at/path_map |
| `exhibits/fleet-01/host-2-polyshell/a.php` | NEW (staging) | ~15 | 2-layer obfuscated PHP, minimal realistic template — **operator gate before commit** |
| `exhibits/fleet-01/host-2-polyshell/access.log` | NEW (staging) | ~50 | Interleaved legitimate + URL-evasion request log — **operator gate before commit** |
| `exhibits/fleet-01/EXPECTED.md` | NEW | ~80 | Ground-truth findings per host for grading hunter output |
| `tests/test_orchestrator_smoke.py` | NEW | ~90 | End-to-end: fixture tar → evidence.db + CASE-2026-0007.yaml; mocked AsyncAnthropic; asserts `test_case_state_a_parses` still passes |
| `tests/test_evidence.py` | NEW | ~60 | evidence.db CRUD unit tests |
| `tests/test_report_envelope.py` | NEW | ~40 | Report envelope parse tests |
| `tests/fixtures/report-host-2-sample.tar.gz` | NEW | — | Small tar matching bl-report envelope, for orchestrator smoke |
| `requirements.txt` | MODIFY | +1 | Add `aiosqlite` (optional — see Section 6) OR keep stdlib `sqlite3` with asyncio.to_thread wrapping |
| `.gitignore` | MODIFY | +1 | Add `curator/storage/work/` and `curator/storage/inbox/` — orchestrator extracts tars to these dirs; accumulated runs must not stage accidentally |

### 4.2 Size comparison

| Metric | Before Day 2 | After Day 2 | Delta |
|---|---|---|---|
| Python LOC in `curator/` | 390 | ~1,280 | +890 |
| Hunter modules | 0 | 3 | +3 |
| Test files | 1 | 4 | +3 |
| Prompt files | 0 | 3 | +3 |
| Skipped tests | 6 | 6 (unchanged) | 0 |
| Executing tests | 5 | ~15 | +10 |
| bl-agent LOC | ~260 (wc: bl-report 63 + bl-pull 46 + bl-apply 53 + install.sh 29 + bl-ctl 68 = 259) | ~300 | +40 |

bl-agent ceiling is 400 lines (constraints.md §"Platform targets" via HANDOFF line 87). After Day 2: ~300, comfortably within budget.

### 4.3 Dependency tree

```
bl-agent/bl-report ──POST──> curator/server.py:POST /reports
                                       │
                                       │ writes tar to /app/inbox
                                       ▼
                             curator/storage/inbox/<host>-<hex>.tar
                                       │
                                       │ (CLI: python -m curator.orchestrator <tar>)
                                       ▼
                        ┌──── curator/orchestrator.py ────┐
                        │                                  │
                        │  1. extract tar → work/<rid>/   │
                        │  2. parse manifest.json         │
                        │     └─ report_envelope.py       │
                        │  3. init evidence.db            │
                        │     └─ evidence.py              │
                        │  4a. fs, log = await             │
                        │        asyncio.gather(           │
                        │          fs_hunter.run(input),  │
                        │          log_hunter.run(input)  │
                        │        )                         │
                        │  4b. tl = await                  │
                        │        timeline_hunter.run(      │
                        │          input, fs, log)         │
                        │     └─ hunters/base.py           │
                        │        └─ AsyncAnthropic        │
                        │  5. write evidence rows         │
                        │  6. build initial hypothesis    │
                        │     (deterministic template)    │
                        │  7. write CASE-2026-0007.yaml   │
                        │     └─ case_schema.dump_case()  │
                        └──────────────────────────────────┘
                                       │
                                       ▼
                        curator/storage/cases/CASE-2026-0007.yaml
                        curator/storage/evidence.db (rows)
```

### 4.4 Key changes from current architecture

- **Adds the curator-side ingest pathway** that server.py's `POST /reports` previously only staged to disk. Day 2 does not wire Flask to the orchestrator — the orchestrator runs as CLI. Flask→orchestrator coupling lands Day 3+ when the curator Managed Agent is the entry.
- **bl-report scope extension** (from process-snapshot-only to filesystem-scoped tar) is the production-shape bl-agent Day 4 will use — this phase just advances it one step.
- **Evidence summarization boundary is architectural.** Hunters write 1-line `finding` + short `raw_evidence_excerpt` (≤500 chars) to evidence.db. The case engine (Day 3) reads summaries only. Anti-pattern #1 in governance (context exhaustion).

### 4.5 Dependency rules

- **Hunters MUST NOT import from `orchestrator.py`** — one-way dependency to prevent cycles.
- **Hunters MUST NOT invoke each other** — `fs_hunter` and `log_hunter` run in parallel via `asyncio.gather` and know nothing about each other. `timeline_hunter` is the single exception: the orchestrator awaits fs+log first, then passes their outputs to `timeline_hunter.run(input, fs_out, log_out)`. Timeline's signature is asymmetric by design (Section 5.5); all other hunters use `run(input: HunterInput) -> HunterOutput`.
- **Orchestrator MUST NOT call the case engine** — case engine doesn't exist Day 2; the deterministic template lives in `orchestrator.py`.
- **Hunters MUST NOT write to evidence.db directly** — they return `HunterOutput`; orchestrator is the single writer.
- **`case_schema.py` is read-only this phase** — add no fields, modify no validators.
- **`managed_agents.py` is untouched** — beta-surface TODOs stay as-is.

## Section 5 — File Contents

### 5.1 `curator/evidence.py` (NEW, ~180 lines)

sqlite evidence store. stdlib `sqlite3` + `asyncio.to_thread` wrapping for non-blocking writes. No async sqlite dependency added.

| Function | Signature | Purpose | Dependencies |
|---|---|---|---|
| `init_db(path: Path) -> None` | idempotent DDL | Create `evidence` table + indexes if missing | sqlite3 |
| `insert_evidence(path: Path, rows: list[EvidenceRow]) -> None` | batch insert | Write hunter output rows; generates UUID7-ish `id` per row | sqlite3 |
| `fetch_by_case(path: Path, case_id: str) -> list[EvidenceRow]` | read | Return rows for a case | sqlite3 |
| `fetch_by_report(path: Path, report_id: str) -> list[EvidenceRow]` | read | Return rows from one report ingest | sqlite3 |
| `EvidenceRow` | Pydantic model | In-memory representation | pydantic |
| `_dict_factory(cursor, row)` | internal | Row → dict mapping | — |

**Schema DDL** (embedded in `init_db`):

```sql
CREATE TABLE IF NOT EXISTS evidence (
    id TEXT PRIMARY KEY,                   -- uuid4 hex, generated by orchestrator
    case_id TEXT,                          -- nullable until case assigned
    report_id TEXT NOT NULL,               -- groups rows from one bl-report ingest
    host TEXT NOT NULL,                    -- e.g. "host-2"
    hunter TEXT NOT NULL,                  -- "fs"|"log"|"timeline"
    category TEXT NOT NULL,                -- "unusual_php_path"|"url_evasion"|"mtime_cluster"|...
    finding TEXT NOT NULL,                 -- one-line human-legible summary (≤200 chars)
    confidence REAL NOT NULL CHECK (confidence BETWEEN 0.0 AND 1.0),
    source_refs TEXT NOT NULL,             -- JSON array of source locations
    raw_evidence_excerpt TEXT NOT NULL,    -- ≤500 chars, truncated
    observed_at TEXT NOT NULL,             -- ISO-8601 Z — when event occurred on host
    reported_at TEXT NOT NULL              -- ISO-8601 Z — when hunter wrote row
);
CREATE INDEX IF NOT EXISTS idx_evidence_case ON evidence(case_id);
CREATE INDEX IF NOT EXISTS idx_evidence_report ON evidence(report_id);
CREATE INDEX IF NOT EXISTS idx_evidence_host ON evidence(host);
```

**Notes:**
- `case_id` is a soft FK (no FK constraint, no `cases` table — cases live in YAML on disk per governance/architecture.md §"Case file (central object)"). Evidence and case YAMLs are cross-referenced by ID string.
- `source_refs` stored as JSON blob (sqlite TEXT); parsed on read. Rationale: sqlite JSON1 extension availability across distros is not guaranteed; storing as JSON string is portable.
- `raw_evidence_excerpt` is truncated at the hunter boundary, not at read time — governance anti-pattern #1 says the engine must never see raw log lines.

### 5.2 `curator/hunters/base.py` (NEW, ~90 lines)

Shared infrastructure for all three hunters.

| Function | Signature | Purpose | Dependencies |
|---|---|---|---|
| `run_sonnet_hunter(prompt_path, user_content, tool_schema) -> HunterOutput` | async | Sonnet 4.6 call with forced tool use; extended thinking disabled; returns parsed tool result | anthropic, json |
| `load_prompt(path: Path) -> str` | sync | Read `prompts/*.md` file; cache | pathlib |
| `build_tool_schema() -> dict` | sync | Shared schema for all hunters: `{"findings": [{"category": str, "finding": str, "confidence": float, "source_refs": list[str], "raw_evidence_excerpt": str, "observed_at": str}]}` | — |
| `HunterInput` dataclass | `(host: str, report_id: str, work_root: Path, skills: list[str])` | — | dataclasses |
| `HunterOutput` dataclass | `(hunter: str, findings: list[Finding])` | — | dataclasses |
| `Finding` dataclass | matches tool-schema items | — | dataclasses |

**Sonnet call shape** (embedded):

```python
async def run_sonnet_hunter(prompt_path, user_content, tool_schema):
    client = anthropic.AsyncAnthropic()
    response = await client.messages.create(
        model="claude-sonnet-4-6",   # hunters: Sonnet 4.6 locked (constraints.md §Locked decisions)
        max_tokens=4096,
        system=load_prompt(prompt_path),
        tools=[tool_schema],
        tool_choice={"type": "tool", "name": "report_findings"},
        # extended thinking explicitly off; hunters are pattern-match at speed.
        messages=[{"role": "user", "content": user_content}],
    )
    return _parse_tool_output(response)
```

### 5.3 `curator/hunters/fs_hunter.py` (NEW, ~80 lines)

| Function | Signature | Purpose | Dependencies |
|---|---|---|---|
| `run(input: HunterInput) -> HunterOutput` | async | Main entry; walks `input.work_root`, summarizes candidates, calls Sonnet 4.6 | base.run_sonnet_hunter, pathlib |
| `_collect_candidates(root: Path) -> list[dict]` | sync | Walk, filter by heuristic (php outside vendor, mtime anomaly, SUID bits, world-writable); cap at 50 | os, stat |
| `_format_candidates(cands: list[dict]) -> str` | sync | Render candidate list as concise user message (paths + stat metadata only, no file contents) | — |

**Behavior:** filesystem walk with early local filters (no Claude call per file). Aggregated candidate list passed to Sonnet 4.6 in one call. Hunter summarizes patterns (e.g., "3 PHP files in Magento media paths with mtime clustering within 4-hour window"). **Raw file contents are never sent to the model or stored in evidence_excerpt** — just paths + stat metadata + the first 200 chars of any suspicious file (for pattern recognition, not deobfuscation).

### 5.4 `curator/hunters/log_hunter.py` (NEW, ~80 lines)

| Function | Signature | Purpose | Dependencies |
|---|---|---|---|
| `run(input: HunterInput) -> HunterOutput` | async | Parses access.log + auth.log under `work_root`, calls Sonnet 4.6 | base.run_sonnet_hunter |
| `_extract_suspicious(log_path: Path) -> list[dict]` | sync | Regex pre-filter: `.jpg|.png|.gif` routing to PHP paths, unusual user-agents, 5xx clusters, failed-auth bursts; cap per-log at 100 lines | re |
| `_format_excerpts(hits: list[dict]) -> str` | sync | Render redacted excerpts (no full log lines — just method/path/status/ts) | — |

### 5.5 `curator/hunters/timeline_hunter.py` (NEW, ~80 lines)

| Function | Signature | Purpose | Dependencies |
|---|---|---|---|
| `run(input: HunterInput, fs_out: HunterOutput, log_out: HunterOutput) -> HunterOutput` | async | Correlates mtime events (from fs_hunter) + log timestamps (from log_hunter); calls Sonnet 4.6 | base.run_sonnet_hunter |
| `_merge_timeline(fs_findings, log_findings) -> list[dict]` | sync | Sort all events by `observed_at`; compute inter-event gaps; flag clusters | datetime |

**Note on dependency:** timeline_hunter depends on fs_hunter and log_hunter output. The orchestrator runs `asyncio.gather(fs, log)` first, then awaits `timeline(fs_result, log_result)`. Two-phase dispatch, not three-way parallel. Rationale: timeline is derivative-by-design — correlating events that the other hunters surface. Passing shared state between three parallel coroutines would duplicate fs/log work inside timeline. Two-phase is simpler *and* correct. Risk of partial-failure degradation (one of fs/log fails → timeline runs on partial data) is accepted per Section 11b edge case 5 (soft-fail with `return_exceptions=True`).

### 5.6 `curator/orchestrator.py` (NEW, ~210 lines)

| Function | Signature | Purpose | Dependencies |
|---|---|---|---|
| `main()` | CLI entry | `python -m curator.orchestrator <tar-path>`; calls `process_report()`; prints case_id on success | argparse, asyncio |
| `process_report(tar_path: Path) -> CaseFile` | async | Full pipeline: extract, parse envelope, route skills, dispatch hunters, write evidence, build case | all hunters + evidence + report_envelope + case_schema |
| `_extract_tar(tar_path: Path) -> Path` | sync | Extract to `curator/storage/work/{report_id}/`; validate paths (no absolute, no `..`); return work root | tarfile, pathlib |
| `_route_skills(work_root: Path, envelope: ReportEnvelope) -> list[str]` | sync | Consult `skills/INDEX.md` decision tree against detected host signals (Magento path present, PHP outside vendor, Apache config, cron edits). Returns absolute paths of **non-stub** skill files to attach to HunterInput.skills. Day 2: hardcoded signal detectors + static path list; INDEX.md is a reference, not a runtime parser (parser lands Day 3+ when case-engine needs dynamic routing). Stub files (containing `TODO: operator content` in first 3 lines) are skipped with a log warning. | pathlib, re |
| `_build_initial_hypothesis(evidence_rows: list[EvidenceRow]) -> HypothesisCurrent` | sync | Deterministic template (see below) | case_schema |
| `_open_case(report_id: str, host: str, rows: list[EvidenceRow]) -> CaseFile` | sync | Construct CaseFile with case_id="CASE-2026-0007" (Day 2 fixed; auto-allocation Day 3+), initial hypothesis, evidence_threads={host: [ev.id for ev in rows]} | case_schema |
| `_write_case(case: CaseFile, cases_dir: Path) -> Path` | sync | Wrapper around `dump_case()` (file I/O wrapped in `asyncio.to_thread` at caller; Day-2 single-shot CLI accepts the brief event-loop block — see Section 11 risk #10) | case_schema |

**Deterministic initial hypothesis algorithm:**

```
Input: list[EvidenceRow]
1. group rows by category; compute per-category max confidence
2. top_category = argmax(per_category_max_confidence)
3. distinct_hosts = {row.host for row in rows}
4. confidence = min(max(r.confidence for r in rows), 0.4)    # capped at 0.4 per HANDOFF line 355
5. summary = f"{len(distinct_hosts)}-host {top_category} on {sorted(distinct_hosts)[0]}"
   (Day-2 fixture case has one host; the "{N}-host" formulation is forward-compatible with Day 3)
6. top_3_ev = sorted(rows, key=lambda r: -r.confidence)[:3]
7. reasoning = (
     f"initial triage — {top_category} pattern flagged by {len(rows)} evidence rows "
     f"across hunters {sorted({r.hunter for r in rows})}. "
     f"Top indicators: {'; '.join(f'{r.id[:8]}={r.finding[:60]}' for r in top_3_ev)}"
   )
8. return HypothesisCurrent(summary=summary, confidence=confidence, reasoning=reasoning)
```

No model call. Fully unit-testable against known evidence row sets.

### 5.7 `curator/report_envelope.py` (NEW, ~80 lines)

| Function | Signature | Purpose | Dependencies |
|---|---|---|---|
| `ReportEnvelope` | Pydantic model | `{report_id: str, host_id: str, collected_at: datetime, tool_version: str, path_map: dict[str, str]}` | pydantic |
| `parse_envelope(work_root: Path) -> ReportEnvelope` | sync | Read `work_root/manifest.json`; validate via Pydantic | json, pydantic |
| `validate_tar_safety(tar_path: Path) -> None` | sync | Reject tars with absolute paths, `..`, symlinks escaping root | tarfile |

### 5.8 `bl-agent/bl-report` (MODIFY, +40 lines → ~104)

| Function | Current behavior | New behavior | Lines affected |
|---|---|---|---|
| `main()` | Tars ps + ss snapshot only | Accepts `BL_REPORT_PATHS` (default `/var/www/html /var/log/apache2 /etc/cron.d`); tars scoped content + writes `manifest.json` inside tar | 26–61 |

**New tar layout:**
```
report-host-2-<ts>.tar.gz
├── manifest.json           # {report_id, host_id, collected_at, tool_version, path_map}
├── fs/
│   └── var/www/html/...    # scoped filesystem snapshot (paths preserved under fs/)
├── logs/
│   └── var/log/apache2/access.log
│   └── var/log/apache2/error.log
├── cron/
│   └── etc/cron.d/...
└── procs/
    ├── ps.txt              # existing
    └── sockets.txt         # existing
```

**Guardrails retained:**
- `command` prefix on all coreutils (workspace CLAUDE.md §Shell Standards).
- No `|| true` / `2>/dev/null` without inline same-line comment.
- `local var=$(...)` anti-pattern avoided (declare separately).
- Bash 4.1+ compatible.
- Size budget: ~104 lines total — within bl-agent 400-line ceiling (constraints.md §Platform targets).
- Collection size cap: `BL_REPORT_MAX_MB` (default 50) — `du` check + abort-with-log if exceeded.

### 5.9 Prompt files

**`prompts/fs-hunter.md` (~60 lines):** Sonnet 4.6 system prompt. VOICE.md-compliant (short declarative sentences, no hedging, no marketing). Tasks the hunter to flag unusual PHP paths, mtime clusters, SUID changes, permission oddities. Forces `report_findings` tool use. Loads `skills/INDEX.md` routing context inline.

**`prompts/log-hunter.md`** — same shape, scoped to access/auth log patterns.

**`prompts/timeline-hunter.md`** — same shape, scoped to correlation of mtime + log events.

All three reference (do not inline) operator-content skill files. If a routed skill file is a stub (`TODO: operator content` header), the hunter proceeds without it and logs a warning — stub skills do not block execution.

### 5.10 `exhibits/fleet-01/host-2-polyshell/*` (NEW, operator-gate)

**⚠ OPERATOR GATE — realism review before commit.**

Plan phase writes:
- `a.php` — 2-layer base64/gzinflate obfuscated PHP skeleton, POST/GET command shim, `.top` callback template (`vagqea4wrlkdg.top` per EXHIBITS.md — randomly-generated, depot-excluded), realistic Magento media path simulation. ~15 lines.
- `access.log` — ~50 lines: interleaved legitimate Magento traffic + URL-evasion hits (`GET /pub/media/catalog/product/.cache/a.php/product.jpg`).

Inline provenance marker at top of each file: `# staged exhibit — APSB25-94 public advisory reconstruction — NOT customer data`.

**Operator clears before commit.** If operator unreachable by phase gate, fallback: commit toy fixtures tagged `pre-realism-check` + open follow-up task.

### 5.11 `exhibits/fleet-01/EXPECTED.md` (NEW, ~80 lines)

Ground-truth findings per host, per HANDOFF.md line 48. For host-2, enumerates:
- fs_hunter expected findings: the shell at `/var/www/html/pub/media/catalog/product/.cache/a.php`, mtime-cluster anomaly.
- log_hunter expected findings: URL-evasion pattern, `.top` callback evidence in logs.
- timeline_hunter expected findings: correlation between shell-file mtime and first log hit.
- Initial-hypothesis expected: summary contains "host-2", "unusual_php_path" or equivalent category, confidence == 0.4.

## Section 5b — Examples

### CLI end-to-end smoke

```bash
$ cd /root/admin/work/proj/blacklight
$ docker compose -f compose/docker-compose.yml up -d
$ docker exec bl-host-2 /opt/bl-agent/bl-report
[bl-report 2026-04-22T22:15:01Z] uploading report-host-2-20260422T221501Z.tar.gz to http://bl-curator:8080/reports
[bl-report 2026-04-22T22:15:02Z] report accepted; removing local copy

$ ls curator/storage/inbox/
host-2-a7f3c9e1.tar

$ .venv/bin/python -m curator.orchestrator curator/storage/inbox/host-2-a7f3c9e1.tar
[orchestrator] extracted to curator/storage/work/rpt-a7f3c9e1/
[orchestrator] dispatching fs_hunter, log_hunter on host-2...
[orchestrator] fs_hunter: 3 findings
[orchestrator] log_hunter: 5 findings
[orchestrator] timeline_hunter: 2 correlations
[orchestrator] wrote 10 evidence rows to curator/storage/evidence.db
[orchestrator] opened CASE-2026-0007 (confidence 0.4)
[orchestrator] wrote curator/storage/cases/CASE-2026-0007.yaml
CASE-2026-0007

$ sqlite3 curator/storage/evidence.db 'SELECT hunter, count(*) FROM evidence GROUP BY hunter'
fs|3
log|5
timeline|2

$ .venv/bin/pytest tests/test_revision.py::test_case_state_a_parses -v
tests/test_revision.py::test_case_state_a_parses PASSED
```

### CASE-2026-0007.yaml (emitted)

```yaml
case_id: CASE-2026-0007
status: active
opened_at: '2026-04-22T22:15:02Z'
last_updated_at: '2026-04-22T22:15:02Z'
updated_by: orchestrator-v1
hypothesis:
  current:
    summary: 1-host unusual_php_path on host-2
    confidence: 0.4
    reasoning: "initial triage — unusual_php_path pattern flagged by 10 evidence rows across hunters ['fs', 'log', 'timeline']. Top indicators: 7c9e1a3b=PolyShell-shaped PHP at pub/media/.cache; 4f2d1ab9=URL-evasion hit on a.php/product.jpg; 9e8a3c5d=mtime cluster within 4h window"
  history: []
evidence_threads:
  host-2: [7c9e1a3b..., 4f2d1ab9..., ...]
capability_map:
  observed: []
  inferred: []
  likely_next: []
open_questions: []
actions_taken: []
merged_from: []
split_into: []
```

### Error: tar safety reject

```bash
$ .venv/bin/python -m curator.orchestrator /tmp/malicious.tar
[orchestrator] ERROR: tar entry '../etc/passwd' escapes work root — rejecting
exit 2
```

## Section 6 — Conventions

- **Python:** 3.12 floor (constraints.md). Pydantic v2 syntax (`model_config = ConfigDict(...)`). Type hints mandatory on public functions. Snake_case module names.
- **Async:** `async def` on all hunter entry points + `base.run_sonnet_hunter`. `asyncio.run(main())` at orchestrator CLI entry. No blocking calls inside coroutines — sqlite wrapped in `asyncio.to_thread`.
- **sqlite:** stdlib `sqlite3`. No `aiosqlite` dependency — `asyncio.to_thread(cursor.execute, ...)` is sufficient for Day 2. If contention emerges Day 4+, reconsider.
- **anthropic SDK:** `AsyncAnthropic()`. Model literals from `curator.managed_agents`: `MODEL_HUNTER = "claude-sonnet-4-6"`. Extended thinking **explicitly disabled** on all hunter calls — no `thinking=` kwarg passed.
- **Tool use:** forced via `tool_choice={"type": "tool", "name": "report_findings"}`. Schema centralized in `hunters/base.build_tool_schema()`.
- **Evidence IDs:** `uuid.uuid4().hex` (32 char). Displayed truncated to 8 chars in reasoning strings.
- **Prompts:** system prompts in `prompts/*.md`, loaded by `hunters/base.load_prompt()`. VOICE.md governs prose style.
- **Bash (bl-report):** `command` prefix on coreutils. Same-line inline comment on any `|| true` / `2>/dev/null`. `cd` guarded. Bash 4.1+.
- **YAML:** `yaml.safe_dump(..., sort_keys=False)` — case_schema.py already uses this.
- **Commits:** per governance/conventions.md recommendation — `[New]` / `[Change]` body tags. One logical unit per commit.
- **Repo layout note:** `prompts/` is a new top-level directory not listed in HANDOFF.md §"Repo layout". This is an intentional addition — prompts are Claude-authored artifacts distinct from operator-authored `skills/` files, and collocating them in `skills/` would muddy the operator-content boundary. Callout for README traceability only; not a scope expansion.

## Section 7 — Interface Contracts

### Report envelope (`manifest.json` inside tar)

```json
{
  "report_id": "rpt-a7f3c9e1",           // generated by bl-report
  "host_id": "host-2",                   // matches X-Host-Id header
  "collected_at": "2026-04-22T22:15:01Z",
  "tool_version": "bl-report 0.2.0",
  "path_map": {
    "fs/var/www/html": "/var/www/html",  // tar-internal → host path
    "logs/var/log/apache2": "/var/log/apache2"
  }
}
```

### `HunterInput` / `HunterOutput`

```python
@dataclass(frozen=True)
class HunterInput:
    host: str
    report_id: str
    work_root: Path          # extracted tar root on curator disk
    skills: list[str]        # paths to skill files to load (routed per INDEX.md)

@dataclass(frozen=True)
class Finding:
    category: str
    finding: str             # ≤200 chars
    confidence: float        # 0..1
    source_refs: list[str]   # e.g. ["fs/var/www/html/pub/media/.cache/a.php:L1"]
    raw_evidence_excerpt: str  # ≤500 chars
    observed_at: str         # ISO-8601 Z

@dataclass(frozen=True)
class HunterOutput:
    hunter: str              # "fs"|"log"|"timeline"
    findings: list[Finding]
```

### Orchestrator CLI

```
python -m curator.orchestrator <tar-path>

Arguments:
  <tar-path>   Path to bl-report tar (uncompressed or .gz). Required.

Exit codes:
  0  success — case_id printed to stdout
  1  hunter failure or model API error (details to stderr)
  2  tar validation failure (safety reject)
  3  evidence.db write failure
  4  case YAML write failure

Environment:
  BL_STORAGE=/path     override curator/storage root
  ANTHROPIC_API_KEY=   required when making live hunter calls
  BL_SKIP_LIVE=1       opt-in skip mode — hunters return fixture findings instead of
                       calling the API. Required for offline tests and CI.
                       If BL_SKIP_LIVE is unset AND ANTHROPIC_API_KEY is unset,
                       orchestrator errors out at startup with a clear message.
                       If BL_SKIP_LIVE=1, ANTHROPIC_API_KEY is ignored.
```

### evidence.db schema

See Section 5.1 DDL.

### CaseFile YAML format

**Unchanged** from case_schema.py locked Day 1. Day 2 orchestrator writes a subset (empty capability_map, empty history, empty open_questions, empty actions_taken) — all valid per schema defaults.

## Section 8 — Migration Safety

- **Install path:** N/A — no installer for curator module (runs via `python -m` or Docker). `bl-report` install via `bl-agent/install.sh` unchanged in shape; only the script contents grow.
- **Upgrade path:** N/A — greenfield files; no prior version to migrate.
- **Backward compatibility:** N/A — evidence.db is fresh; case YAMLs are fresh.
- **Uninstall:** `rm -rf curator/storage/` cleans all Day-2 output. Gitignore already covers `curator/storage/evidence.db*` and `curator/storage/cases/*.yaml`; this phase adds `curator/storage/work/` and `curator/storage/inbox/` to `.gitignore` so orchestrator runs cannot accidentally stage extracted tar content.
- **Test suite impact:**
  - Existing `tests/test_revision.py` **unchanged** — Day 2 does not touch the case engine or Day 3 fixtures.
  - `test_case_state_a_parses` currently passes against the static fixture at `tests/fixtures/case_state_a.yaml`. Day 2 smoke produces an equivalent case at `curator/storage/cases/CASE-2026-0007.yaml`. **The Day 1 fixture is retained** — tests still use it. Orchestrator output is a new artifact, not a replacement.
  - New tests (`test_orchestrator_smoke.py`, `test_evidence.py`, `test_report_envelope.py`) are additive; run in the same `pytest tests/ -v` pass.
- **Docker Compose:** no service change Day 2. `docker compose up` continues to work exactly as Day 1. Orchestrator invocation is out-of-band (CLI on curator container or host venv).
- **Rollback:** git revert is clean — all new files; modified `bl-report` reverts to Day-1 shape without orphan references.

## Section 9 — Dead Code and Cleanup

No dead code found during reading. The Day 1 scaffold is disciplined — every file has a purpose traceable to HANDOFF.md.

**Forward-looking cleanup note:** `bl-agent/bl-report` line 44–45 has two `|| true` / `2>/dev/null` pairs with inline comments (compliant). Day 2 modification must preserve those comments; do not introduce new suppressions without same-line rationale.

## Section 10a — Test Strategy

| Goal | Test file | Test function | Coverage |
|---|---|---|---|
| 1. Evidence schema correct | `tests/test_evidence.py` | `test_init_db_creates_table` | DDL applies idempotently |
| 1. Evidence schema correct | `tests/test_evidence.py` | `test_insert_and_fetch_by_report` | round-trip works |
| 1. Evidence schema correct | `tests/test_evidence.py` | `test_fetch_by_case_filters_correctly` | FK-like filter works |
| 2. Three hunters | `tests/test_orchestrator_smoke.py` | `test_all_three_hunters_invoked` | mocked AsyncAnthropic; asserts 3 calls with `claude-sonnet-4-6` model + `thinking` kwarg absent |
| 2. Three hunters | `tests/test_orchestrator_smoke.py` | `test_fs_hunter_filters_vendor_paths` | candidate filter rejects paths under `vendor/` |
| 3. Orchestrator v1 | `tests/test_orchestrator_smoke.py` | `test_process_report_end_to_end` | fixture tar → evidence.db populated + CASE-2026-0007.yaml written |
| 3. Orchestrator v1 | `tests/test_orchestrator_smoke.py` | `test_tar_safety_rejects_absolute_paths` | exit code 2 on bad tar |
| 3. Orchestrator v1 | `tests/test_orchestrator_smoke.py` | `test_tar_safety_rejects_dotdot` | exit code 2 on `..` entries |
| 4. bl-report scope extension | `tests/test_bl_report.bats` (if BATS available) OR manual | bash -n + shellcheck | scope ENV respected, tar structure matches contract |
| 5. Hunter prompts exist | `tests/test_orchestrator_smoke.py` | `test_prompt_files_exist` | all three `prompts/*.md` present, non-empty, no `TODO: operator content` header (hunter prompts are Claude-authored, not operator-content) |
| 6. End-to-end acceptance | `tests/test_orchestrator_smoke.py` | `test_produced_case_passes_day1_assertions` | replay `test_case_state_a_parses` logic against produced YAML |
| 7. Deterministic initial hypothesis | `tests/test_orchestrator_smoke.py` | `test_initial_hypothesis_is_deterministic` | given fixture evidence rows, hypothesis is byte-identical across runs |
| 7. Deterministic initial hypothesis | `tests/test_orchestrator_smoke.py` | `test_initial_hypothesis_confidence_capped_at_04` | even with max-confidence evidence, case opens at 0.4 |
| 8. No case-schema drift | `tests/test_orchestrator_smoke.py` | `test_produced_yaml_validates_via_load_case` | emitted YAML parses through unchanged `load_case()` |
| Report envelope | `tests/test_report_envelope.py` | `test_valid_envelope_parses` | happy path |
| Report envelope | `tests/test_report_envelope.py` | `test_missing_host_id_rejected` | Pydantic validation fires |

**Live vs mocked:** `test_orchestrator_smoke.py` sets `BL_SKIP_LIVE=1` in the test environment and uses `unittest.mock.patch` on `anthropic.AsyncAnthropic` to inject a stub returning deterministic tool-use responses when `BL_SKIP_LIVE` is not set. No `ANTHROPIC_API_KEY` required for CI / local test.

**Manual live smoke (Phase 9):** a separate ad-hoc shell command run by the operator before the 22:00 CT checkpoint — **not committed**. The command is documented in Section 10b Goal 6 directly (`BL_SKIP_LIVE=1 … orchestrator`) for offline, and an additional live-API variant in the Phase 9 phase-breakdown below. No `scripts/` directory is created this phase; live-smoke invocation is a one-liner, not a committed artifact.

## Section 10b — Verification Commands

```bash
# Goal 1: evidence schema correct
cd /root/admin/work/proj/blacklight
.venv/bin/pytest tests/test_evidence.py -v
# expect: 3 passed

# Goal 2 + 3 + 5 + 6 + 7 + 8: orchestrator end-to-end with mocked hunters
.venv/bin/pytest tests/test_orchestrator_smoke.py -v
# expect: 10 passed (or more — see Section 10a)

# Goal 2: hunters use Sonnet 4.6 with thinking off
.venv/bin/pytest tests/test_orchestrator_smoke.py::test_all_three_hunters_invoked -v
# expect: 1 passed

# Goal 3: produced case file matches existing Day-3 fixture assertions
.venv/bin/pytest tests/test_revision.py::test_case_state_a_parses -v
# expect: 1 passed (continues to pass — Day 1 assertion is unchanged)

# Goal 4: bl-report scope extension — shell lint
bash -n bl-agent/bl-report
shellcheck bl-agent/bl-report
# expect: 0 output (silent = clean)

# Goal 4: bl-report coreutils prefix compliance
grep -rn '^\s*cp \|^\s*mv \|^\s*rm ' bl-agent/bl-report
grep -rn '^\s*chmod \|^\s*mkdir \|^\s*touch \|^\s*ln ' bl-agent/bl-report
grep -rn '\bcat\b' bl-agent/bl-report | grep -v 'command cat' | grep -v 'cat <<'
# expect: 0 hits (each) — all coreutils must use 'command' prefix

# Goal 4: bl-report |2>/dev/null & || true inline-comment discipline
grep -n '|| true' bl-agent/bl-report
grep -n '2>/dev/null' bl-agent/bl-report
# expect: every hit has an inline comment on the same line explaining the suppression

# Goal 5: prompt files exist and are non-empty
ls -la prompts/{fs,log,timeline}-hunter.md
wc -l prompts/{fs,log,timeline}-hunter.md
# expect: 3 files, each > 20 lines

# Goal 6: end-to-end CLI smoke (skip-live fixture mode — no real API)
BL_SKIP_LIVE=1 .venv/bin/python -m curator.orchestrator tests/fixtures/report-host-2-sample.tar.gz 2>&1 | tail -3
# expect: final line prints "CASE-2026-0007"

# Verify produced case YAML
cat curator/storage/cases/CASE-2026-0007.yaml | head -10
# expect: case_id: CASE-2026-0007, status: active, confidence: 0.4

# Goal 7: deterministic template (second run must produce identical hypothesis)
BL_SKIP_LIVE=1 .venv/bin/python -m curator.orchestrator tests/fixtures/report-host-2-sample.tar.gz
cp curator/storage/cases/CASE-2026-0007.yaml /tmp/case-run1.yaml
BL_SKIP_LIVE=1 .venv/bin/python -m curator.orchestrator tests/fixtures/report-host-2-sample.tar.gz
diff <(yq .hypothesis.current.reasoning /tmp/case-run1.yaml) <(yq .hypothesis.current.reasoning curator/storage/cases/CASE-2026-0007.yaml)
# expect: empty diff (determinism holds across runs)

# Goal 8: no case-schema drift
grep -n 'class CaseFile' curator/case_schema.py
git diff 9edbced -- curator/case_schema.py
# expect: CaseFile unchanged (schema locked Day 1)

# Governance: operator-content skills untouched
grep -l 'TODO: operator content' skills/ir-playbook/case-lifecycle.md skills/webshell-families/polyshell.md skills/defense-synthesis/modsec-patterns.md
# expect: all three still contain the TODO header

# Framing discipline (governance anti-pattern #4)
grep -rnE '\b(exploit|offensive|find vulnerabilit|attack surface from)' curator/ prompts/ bl-agent/bl-report
# expect: 0 hits — defensive forensics framing only
```

## Section 11 — Risks

1. **Anthropic SDK Managed Agents beta surface drift.** `curator/managed_agents.py` carries TODO markers. Day 2 does not call Managed Agents live; orchestrator uses `AsyncAnthropic().messages.create()` directly. The curator-Agent wiring lands Day 3+. **Mitigation:** Day 2 avoids the beta surface entirely. Managed Agents integration tested separately, not on the load-bearing path tonight.

2. **Sonnet 4.6 model ID resolution.** The SDK may accept either `claude-sonnet-4-6` or `claude-sonnet-4-5-20250929`-style ID. `curator/managed_agents.py` declares `MODEL_HUNTER = "claude-sonnet-4-6"`. **Mitigation:** re-import from managed_agents so there is one source of truth; if a live call fails with unknown-model, patch the constant and re-run. Not a spec-blocking issue.

3. **PolyShell staging realism operator-gate unresolved by phase execution time.** If operator unreachable when staging phase runs, fallback is toy fixtures tagged `pre-realism-check`. **Mitigation:** build toy-fixture fallback into the plan; operator review task stays open; realism check can land Day 3 morning without blocking tonight's checkpoint. **Explicit spec ASK below.**

4. **Evidence summarization discipline slippage.** A hunter could, under time pressure, dump raw log lines into `raw_evidence_excerpt`. Anti-pattern #1 in governance. **Mitigation:** tool schema caps `raw_evidence_excerpt` via validator; test `test_evidence_excerpt_under_500_chars` asserts. Code review checkpoint in phase-complete review.

5. **Tar extraction path traversal.** A malicious tar could write outside work root. **Mitigation:** `validate_tar_safety()` rejects absolute paths, `..`, symlinks escaping root before extract. Test `test_tar_safety_rejects_*` asserts rejection.

6. **sqlite write contention.** Day 2 is single-writer (orchestrator) so no contention. Day 3+ may need WAL mode. **Mitigation:** document in Section 11b edge cases; not an issue this phase.

7. **bl-report tar size explosion.** A host with 100k files in `/var/www/html` produces a huge tar. **Mitigation:** `BL_REPORT_MAX_MB=50` cap with abort-with-log. Test manually on host-2 container.

8. **Initial-hypothesis template brittleness.** Template assumes at least one evidence row. Zero-finding reports (clean host) would crash. **Mitigation:** zero-finding case returns early with `"no evidence — no case opened"` log; no case YAML written; exit 0. Test `test_zero_evidence_no_case_opened` asserts.

9. **Prompt file lint.** Hunter prompt prose could drift from VOICE.md during authoring. **Mitigation:** reviewer explicitly checks prompt files for marketing language / hedging during Phase 3 challenge review.

## Section 11b — Edge Cases

| # | Scenario | Expected behavior | Handling location |
|---|---|---|---|
| 1 | bl-report tar missing `manifest.json` | Orchestrator exits 2 with "malformed envelope — missing manifest.json" | `report_envelope.parse_envelope` raises; orchestrator catches |
| 2 | Tar entry contains `/etc/passwd` (absolute path) | Reject before extract, exit 2 | `validate_tar_safety` |
| 3 | Tar entry contains `../../../root/.ssh/id_rsa` | Reject before extract, exit 2 | `validate_tar_safety` |
| 4 | Zero evidence findings (clean host) | Log "no findings on {host}"; exit 0; no case YAML written | `orchestrator.process_report` early return |
| 5 | One hunter errors (network/API failure), others succeed | Continue — partial findings recorded; log the failed hunter; exit 1 (soft fail) | `asyncio.gather(..., return_exceptions=True)` in orchestrator |
| 6 | `BL_SKIP_LIVE=1` set | Hunters return fixture findings (no API calls); `ANTHROPIC_API_KEY` ignored. Dev/test mode. | `hunters/base.run_sonnet_hunter` guard |
| 6b | `BL_SKIP_LIVE` unset AND `ANTHROPIC_API_KEY` unset | Orchestrator exits 1 at startup with `"ANTHROPIC_API_KEY not set and BL_SKIP_LIVE not set — refusing to proceed"` | `orchestrator.main()` precondition check |
| 7 | Case YAML already exists (re-run) | Overwrite with updated `last_updated_at`; evidence.db gets new rows with same report_id (idempotency via report_id unique constraint? no — multiple reports per case eventually; Day 2 keeps append-only) | `orchestrator._write_case` overwrites; evidence.db accepts duplicates by design for Day 2 |
| 8 | Report tar is gzipped (`.tar.gz`) vs plain `.tar` | Both accepted via `tarfile.open(mode='r:*')` | `_extract_tar` |
| 9 | Hunter returns malformed tool output (missing field) | Pydantic validation fails → raise; surfaces as hunter failure per case #5 | `hunters/base._parse_tool_output` |
| 10 | Operator-content skill file is stub (TODO header) | Hunter logs warning "skill {path} is stub — proceeding without enriched context"; does not block | `hunters/base.load_prompt` check |
| 11 | Evidence row with `finding` over 200 chars | Truncate + log warning | `hunters/base._parse_tool_output` |
| 12 | Evidence row with `confidence` outside 0..1 | Pydantic validation rejects row; hunter output logs skipped row | `evidence.EvidenceRow` validator |

## Section 12 — Open Questions

**OPERATOR GATE — surfaced ASKs:**

1. **PolyShell realism check.** Plan phase writes minimal-realistic-template PolyShell + access log to `exhibits/fleet-01/host-2-polyshell/`. Operator review before commit. **Blocks:** realism-sensitive commit. **Does not block:** orchestrator development (toy fixtures in `tests/fixtures/report-host-2-sample.tar.gz` are sufficient for code path validation).

2. **Anthropic SDK model ID.** `managed_agents.py` declares `MODEL_HUNTER = "claude-sonnet-4-6"`. If the SDK rejects this literal, patch the constant. No design decision — mechanical fix if it surfaces on first live call.

3. **(Not operator-gated)** Flask → orchestrator wiring deferred to Day 3+. Not a Day 2 open question.

Everything else resolved in brainstorming.

---

## Phase breakdown (for /r-plan consumption)

Phases ordered by dependency. Each phase is one commit per governance/conventions.md.

**Phase 1 — evidence.db foundation** (tests-first)
- Write `tests/test_evidence.py` (3 tests; initially failing)
- Implement `curator/evidence.py` DDL + CRUD
- Green the tests
- No hunters yet; unblocks Phase 2

**Phase 2 — report envelope + tar safety** (tests-first)
- Write `tests/test_report_envelope.py` (2 tests)
- Implement `curator/report_envelope.py` + `ReportEnvelope` Pydantic model
- Implement tar-safety validator (sketches fixture tars)
- Green the tests

**Phase 3 — hunter base + prompts**
- Write `prompts/fs-hunter.md`, `prompts/log-hunter.md`, `prompts/timeline-hunter.md` (VOICE-compliant)
- Implement `curator/hunters/base.py`: shared Sonnet 4.6 call helper, dataclasses, tool schema
- Unit test: `test_prompt_files_exist`, `test_base_sonnet_call_shape` (mocked AsyncAnthropic)

**Phase 4 — hunters implementation**
- Implement `curator/hunters/fs_hunter.py`, `log_hunter.py`, `timeline_hunter.py`
- Unit tests: per-hunter candidate/regex-filter tests (no API calls)

**Phase 5 — orchestrator v1**
- Write `tests/test_orchestrator_smoke.py` (all 10 tests, initially failing on mocked path)
- Build `tests/fixtures/report-host-2-sample.tar.gz` (small staged tar matching envelope)
- Implement `curator/orchestrator.py` (CLI + process_report + deterministic initial hypothesis)
- Green all tests
- Run `test_case_state_a_parses` to confirm no regression

**Phase 6 — bl-report scope extension**
- Modify `bl-agent/bl-report` to accept `BL_REPORT_PATHS` + collect fs/logs/cron; write `manifest.json` inside tar
- `bash -n` + `shellcheck` clean
- Full coreutils-prefix grep pass
- Optional: BATS test if infra available; otherwise manual smoke

**Phase 7 — PolyShell staging (OPERATOR GATE)**
- Draft minimal-realistic-template PolyShell + access log under `exhibits/fleet-01/host-2-polyshell/`
- Inline provenance markers
- **Pause for operator review.**
- On approval: commit. On unreachable operator by gate: commit toy fixtures tagged `pre-realism-check` + open follow-up task.

**Phase 8 — exhibits/fleet-01/EXPECTED.md**
- Ground-truth findings per host (host-2 focus)

**Phase 9 — live smoke + checkpoint**
- Run `docker compose up`; `bl-report` on host-2 (`docker exec bl-host-2 /opt/bl-agent/bl-report`)
- Invoke orchestrator on the resulting inbox tar with a live API key:
  `ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY .venv/bin/python -m curator.orchestrator curator/storage/inbox/host-2-*.tar`
  (no `BL_SKIP_LIVE`; real Sonnet 4.6 calls)
- Confirm `curator/storage/cases/CASE-2026-0007.yaml` materializes with real hunter evidence
- Run full `pytest tests/ -v` — all green + 6 still-skipped Day-3 tests (remain skipped, not erroring)
- Commit "Day 2 checkpoint met: hunters + first case" referencing this spec
- Ad-hoc live smoke command is NOT committed; no `scripts/` directory created this phase

**Phase 10 — sentinel review**
- Reviewer adversarial sweep across all phases
- Framing-discipline grep (governance anti-pattern #4)
- Operator-content skill grep (all three still stubs)
- Case-schema diff check (unchanged since 9edbced)
