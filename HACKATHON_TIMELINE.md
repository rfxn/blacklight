# blacklight — hackathon development timeline

Running record of build cycles. Planned milestones (PLAN-Mx.md, archived under
`.rdf/archive/<date>-Mx/`) are listed alongside session-level work that
happened off-plan. Detail lives elsewhere: `CHANGELOG` for per-phase notes,
`DESIGN.md` for architecture, `PIVOT-v2.md` for strategy.

- **Start:** 2026-04-21 19:48 CT (`Initial commit — blacklight hackathon start`)
- **Submission target:** 2026-04-26 (current state)
- **HEAD:** main · v0.5.2 · 348/0 hermetic, 4/4 live

---

## Day 1 — 2026-04-21 (Tue) — v1 hackathon start

8 commits.

- Scaffolding: directory tree, requirements.txt, `.gitkeep`s.
- **Curator** (v1): Pydantic case-file schema lockdown; first-contact scaffold against Managed Agents.
- **Compose** (v1): 3-host fleet; curator local Flask glue.
- **bl-agent** + **bl-ctl** (v1): bash scaffolds for pull/apply/report.
- **Skills** (v1): INDEX router + 4 Day-1 stubs.
- Test scaffold (6 skipped, Day 3 target).

State: skills-as-Python-routed agent on a Flask substrate. Operator-content protected.

---

## Day 2 — 2026-04-22 (Wed) — v1 hunters + first case

83 commits — the highest-volume day of the hackathon.

- **Hunters** scaffolded (`fs`, `log`, `timeline` + base + prompts).
- **Evidence DB** (sqlite): schema + CRUD.
- **Orchestrator v1**: hunters → evidence.db → first materialized case (`CASE-2026-0007`).
- **Exhibits**: `host-2 staged exhibit — APSB25-94 PolyShell reconstruction`; `exhibits/fleet-01/EXPECTED.md` ground truth.
- **bl-report**: scoped fs + logs + cron collection.
- Day 2 P10 sentinel/anti-slop sweep (P1-SPEC, P3-BUG-{01..07}, P4-DATA-{01,02}).

State at end-of-day: "Day 2 checkpoint met (degraded) — hunters + first case".

---

## Day 3 — 2026-04-23 (Thu) — v1 Managed Agents wiring + audit

19 commits. Last day of the v1 architecture.

- `docs/managed-agents.md` first written (working reference).
- `docs/specs — curator Managed Agents session wiring design (MVW)`.
- `curator/agent_setup.py` (idempotent bootstrap) + `curator/session_runner.py` (revise path).
- `work-output/session-tool-invocation-probe.py` — P0 M2 gate probe.
- Audit P0/P1/P2 sweeps; spec-leak scrub; sentinel fixups.
- **MVW gate PASS** — "session-wired build ready for Saturday 18:00 CT recording".

Session log volume on this day: 12 jsonl sessions. Skill prompt hardening + injection guard work surfaced the structural issue that drove the next day's pivot.

---

## Day 4 — 2026-04-24 (Fri) — pivot + milestone-driven rebuild

81 commits. Two distinct halves.

### Morning — scorched earth

- `[New] PIVOT-v2.md — skills-first defensive agent rewrite plan`
- `[Change] scorched earth — archive v1 Python/curator/tests/compose + v1 planning to legacy/`
- `[Change] README stub + [New] DESIGN.md — v2 rewrite architecture + command surface`

v1 lived under `.rdf/archive/legacy/` from this point on (PLAN, BRIEF, EXHIBITS, PIVOT, AUDIT, etc.).

### Afternoon — M0–M9 spec + implementation in one day

`docs/specs/2026-04-24-M{0,1,2,4,5,5.5,9}-*.md` were authored same-day. Implementation followed immediately:

| Plan | Archive | Topic |
|------|---------|-------|
| M0 | `.rdf/archive/2026-04-24-M0/` | Contracts lockdown (exit codes, action tiers, setup flow, case layout) |
| M1 | `.rdf/archive/2026-04-24-M1/` | `bl` skeleton design (skill bundling and concat order) |
| M2 | `.rdf/archive/2026-04-24-M2/` | Case-templates (hypothesis/INDEX/attribution) |
| M3 | `.rdf/archive/2026-04-24-M3/` | Schemas + ledger scaffolding |
| M4 | `.rdf/archive/2026-04-24-M4/` | `bl observe` collectors (apache, fs, crons, htaccess) |
| M5 | `.rdf/archive/2026-04-24-M5/` | `bl consult/run/case` lifecycle (case open/attach/sweep) |
| M5.5 | `.rdf/archive/2026-04-24-M5.5/` | Component extraction (`src/bl.d/NN-*.sh` parts model) |
| M6 | `.rdf/archive/2026-04-24-M6/` | `bl defend` (ModSec / firewall / signature backends) |
| M7 | `.rdf/archive/2026-04-24-M7/` | `bl clean` (file/htaccess/cron/proc remediation) |
| M8 | `.rdf/archive/2026-04-24-M8/` | `bl case` close/reopen + ledger audit decode |
| M9 | `.rdf/archive/2026-04-24-M9/` | Hardening implementation (P1–P9 same day) |

Session log volume: 32 jsonl sessions — most of them short, milestone-scoped subagent dispatches.

---

## Day 5 — 2026-04-25 (Sat) — hardening, ship, demo, Skills realign

69 commits. Ship-ready by mid-day; Path C realignment closed by night.

| Plan | Archive | Topic |
|------|---------|-------|
| M9.5 | `.rdf/archive/2026-04-25-M9.5/` | Audit-driven hardening sweep (P1–P9) — `AUDIT.md`, baseline patterns |
| M10 | `.rdf/archive/2026-04-25-M10/` | Ship-ready (v0.1.0): `.gitattributes` export-ignore, packaging closeout |
| M11 | `.rdf/archive/2026-04-25-M11/` | Posture lift (v0.2.0): doc reconciliation, README pitch |
| M11.1 | `.rdf/archive/2026-04-25-M11.1/` | Deferred fixups: error-call paths, audit decode |
| M12 | `.rdf/archive/2026-04-25-M12/` | Demo readiness — live-trace harness, P5.5 Managed Agents API surface migration |
| M13 | `.rdf/archive/2026-04-25-M13/PLAN-M13.md` | Skills primitive realignment (Path C): Files API + Skills API helpers, agent + state.json schema, 6 routing Skills, live promotion eval gate (P11). Phase deliverables: `.rdf/work-output/phase-M13-{1,2,4,6,7,8,9}-result.md` |

**M12 P5.5 (2026-04-25)** is the last point at which sessions accepted the
bare-event shape on `/v1/sessions/<sid>/events`; the wrapper requirement
surfaced 24 hours later (see `ANTHROPIC-API-NOTES.md §3`).

Session log volume: 35 jsonl sessions — the heaviest day for ad-hoc subagent dispatch.

---

## Day 6 — 2026-04-26 (Sun, today) — closed-loop + API correctness

29 commits at time of writing. Three layered cycles.

### M14 — Substrate-hook (closed-loop response layer) — v0.3.0 → v0.4.0

| Plan | Archive | Topic |
|------|---------|-------|
| M14 | `.rdf/archive/2026-04-26-M14/` | LMD post_scan_hook adapter, `bl trigger`, vendor `alert_lib`/`tlog_lib`, cPanel Stage 4 ModSec userdata, unattended tier gate, install/uninstall provisioning, three new skill bundles (bl-capabilities, lmd-triggers, cpanel-easyapache) |

Closed with VERSION bump to 0.4.0.

### M15 — API correctness against live Anthropic Managed Agents

| Plan | Archive | Topic |
|------|---------|-------|
| M15 | `.rdf/archive/2026-04-26-M15/` | Eight phases of live-API drift remediation: load_state migration, corpus dry-run wording, reset uses archive verb, agent CAS via POST, sessions.create field rename (`agent_id`→`agent`), Path A workspace allowlist (delete dead `bl_skills_list`), doc drift sweep, live integration smoke + operator runbook |
| M15-final | `.rdf/archive/2026-04-26-M15-final/DESIGN.md` | Final-state design snapshot at submission time (the workspace-level architecture spec, frozen at last M15 P7 doc-drift sweep) |

### Off-plan session work (NOT in any PLAN-M*.md)

These cycles ran in the same day but were operator-driven, not phase-scoped. They live in conversation/session logs (14 jsonl entries on 2026-04-26), not in the milestone archive:

- **Post-M15 triage** (committed `ceffbe3`): debian12 + rocky9 baseline restored to GREEN (348/0). Five separate fixes: `synth-corpus.sh` REPO_ROOT path-doubling, `bl_is_unattended` BL_UNATTENDED=0 honoring, `bl_consult_attach` skip_probe positional, `bl_setup_eval` BL_REPO_ROOT path, observe-block lint anchor — none planned, all surfaced by the post-M15 test re-run.

- **Live integration smoke continuation** (uncommitted at write time): closed the previous session's `tests/live/setup-live.bats` test 3 failure. Root cause was the test (`head -1` on output that contained dedup-warning case-ids before the allocated one), not the bl code. Drive-bys: `bl_setup_seed_skills` Skills-probe shim-compatibility, agent body P6 test contract update.

- **Environments API probe + ANTHROPIC-API-NOTES.md**: operator-asked investigation into `packages` field support. Result: not supported; canonical body is `{name, config:{type, networking}}`. Spawned the formalized `ANTHROPIC-API-NOTES.md` gaps log (10 items).

- **Archive renames + this timeline**: the doc you're reading.

---

## Cumulative shape

| Day | Date | Commits | jsonl sessions | Era |
|-----|------|--------:|--------------:|------|
| 1 | 2026-04-21 | 8 | 5 | v1 scaffolding |
| 2 | 2026-04-22 | 83 | 21 | v1 hunters + first case |
| 3 | 2026-04-23 | 19 | 12 | v1 Managed Agents MVW |
| 4 | 2026-04-24 | 81 | 32 | **pivot** + M0–M9 |
| 5 | 2026-04-25 | 69 | 35 | M9.5–M13 (hardening, ship, demo, Path C) |
| 6 | 2026-04-26 | 29 | 14 | M14–M15 + off-plan triage + API gaps |

**Total:** 6 days, 289+ commits, 119 session logs, 0 → v0.5.2.

The v1 → v2 pivot at the start of Day 4 is the single most consequential
decision in the build — the v2 milestone-driven rebuild took half the
calendar time of the v1 attempt and produced a shippable artifact. The v1
archive (`.rdf/archive/legacy/`) is preserved as proof-of-work, not as a
fallback.

---

## Cross-references

- **Per-phase detail:** `CHANGELOG` (M10, M11, M12, M13, M14, M15 sections;
  M0–M9 rolled into the M10-complete summary block).
- **Architecture:** `DESIGN.md`.
- **Strategy / framing:** `PIVOT-v2.md`.
- **API friction log:** `ANTHROPIC-API-NOTES.md`.
- **v1 history (archived):** `.rdf/archive/legacy/{PLAN,BRIEF,EXHIBITS,PIVOT,AUDIT,…}.md`.
- **Specs (committed):** `docs/specs/2026-04-{24,25}-*.md`.
- **Milestone plans (archived):** `.rdf/archive/2026-04-{24,25,26}-M*/PLAN-M*.md`.
- **Phase deliverables (governance flow):** `.rdf/work-output/phase-M*-*-result.md` (M13 P1/2/4/6/7/8/9 + earlier per-phase outputs).
