"""Orchestrator v1 — CLI entry for Day 2 hunter dispatch + case open.

The initial hypothesis is computed deterministically (no model call)
to preserve the Day-3 revision-test baseline.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import sys
import tarfile
import uuid
from datetime import datetime, timezone
from pathlib import Path

from curator.case_schema import (
    CaseFile,
    Hypothesis,
    HypothesisCurrent,
    dump_case,
)
from curator.evidence import EvidenceRow, init_db, insert_evidence
from curator.hunters.base import HunterInput, HunterOutput
from curator.hunters import fs_hunter, log_hunter, timeline_hunter
from curator.report_envelope import parse_envelope, validate_tar_safety

log = logging.getLogger("orchestrator")

# Day 2: fixed case id. Auto-allocation lands Day 3+ when the case engine wires in.
_DAY2_CASE_ID = "CASE-2026-0007"


def _storage_root() -> Path:
    return Path(os.environ.get("BL_STORAGE", "curator/storage"))


def _check_preconditions() -> None:
    if os.environ.get("BL_SKIP_LIVE") == "1":
        return  # skip mode: no API key needed
    if not os.environ.get("ANTHROPIC_API_KEY"):
        sys.stderr.write(
            "ANTHROPIC_API_KEY not set and BL_SKIP_LIVE not set — refusing to proceed\n"
        )
        sys.exit(1)


def _extract_tar(tar_path: Path, work_parent: Path) -> Path:
    validate_tar_safety(tar_path)
    work_dir = f"rpt-{uuid.uuid4().hex[:8]}"
    work_root = work_parent / work_dir
    work_root.mkdir(parents=True, exist_ok=True)
    with tarfile.open(tar_path, "r:*") as t:
        # filter="data" silences the Python 3.12 deprecation warning and hardens
        # extraction against future default changes in 3.14+. validate_tar_safety
        # runs first as the primary guard.
        t.extractall(work_root, filter="data")
    return work_root


def _findings_to_rows(
    hunter_outputs: list[HunterOutput],
    host: str,
    report_id: str,
) -> list[EvidenceRow]:
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    rows: list[EvidenceRow] = []
    for out in hunter_outputs:
        for f in out.findings:
            rows.append(
                EvidenceRow(
                    id="",  # filled by insert_evidence
                    case_id=_DAY2_CASE_ID,
                    report_id=report_id,
                    host=host,
                    hunter=out.hunter,
                    category=f.category,
                    finding=f.finding,
                    confidence=f.confidence,
                    source_refs=f.source_refs,
                    raw_evidence_excerpt=f.raw_evidence_excerpt,
                    observed_at=f.observed_at,
                    reported_at=now,
                )
            )
    return rows


def _build_initial_hypothesis(rows: list[EvidenceRow]) -> HypothesisCurrent:
    if not rows:
        raise ValueError("cannot build hypothesis from zero evidence rows")
    # spec §5.6: top_category = argmax(per_category_max_confidence). High-confidence
    # single-row categories must outrank low-confidence many-row categories.
    per_cat_max: dict[str, float] = {}
    for r in rows:
        prev = per_cat_max.get(r.category, 0.0)
        if r.confidence > prev:
            per_cat_max[r.category] = r.confidence
    # Deterministic tie-break on category name so hypothesis text is stable
    # under any rows ordering — sqlite fetches in Day-3+ revision paths do
    # not guarantee insertion order.
    top_category = max(per_cat_max.items(), key=lambda kv: (kv[1], kv[0]))[0]
    hosts = sorted({r.host for r in rows})
    conf = min(max(r.confidence for r in rows), 0.4)
    top3 = sorted(rows, key=lambda r: -r.confidence)[:3]
    indicator_fragments = "; ".join(
        f"{r.id[:8]}={r.finding[:60]}" for r in top3
    )
    hunters_used = sorted({r.hunter for r in rows})
    reasoning = (
        f"initial triage — {top_category} pattern flagged by {len(rows)} evidence "
        f"rows across hunters {hunters_used}. Top indicators: {indicator_fragments}"
    )
    summary = f"{len(hosts)}-host {top_category} on {hosts[0]}"
    return HypothesisCurrent(summary=summary, confidence=conf, reasoning=reasoning)


def _existing_case_path(cases_dir: Path, case_id: str) -> "Path | None":
    p = cases_dir / f"{case_id}.yaml"
    return p if p.is_file() else None


def _open_case(host: str, rows: list[EvidenceRow]) -> CaseFile:
    now = datetime.now(timezone.utc)
    return CaseFile(
        case_id=_DAY2_CASE_ID,
        status="active",
        opened_at=now,
        last_updated_at=now,
        updated_by="orchestrator-v1",
        hypothesis=Hypothesis(current=_build_initial_hypothesis(rows)),
        evidence_threads={host: [r.id for r in rows]},
    )


async def _run_hunters(input: HunterInput) -> tuple[list[HunterOutput], bool]:
    """Run fs+log in parallel, timeline on their outputs. Soft-fail per spec 11b #5.

    Returns (outputs, had_partial_failure). Partial failure means at least one
    hunter raised; remaining hunters' findings are preserved and written.
    """
    fs_result, log_result = await asyncio.gather(
        fs_hunter.run(input),
        log_hunter.run(input),
        return_exceptions=True,
    )
    partial = False
    outputs: list[HunterOutput] = []

    if isinstance(fs_result, BaseException):
        log.warning("fs_hunter raised %s: %s", type(fs_result).__name__, fs_result)
        partial = True
        fs_out = HunterOutput(hunter="fs", findings=[])
    else:
        fs_out = fs_result
    outputs.append(fs_out)

    if isinstance(log_result, BaseException):
        log.warning("log_hunter raised %s: %s", type(log_result).__name__, log_result)
        partial = True
        log_out = HunterOutput(hunter="log", findings=[])
    else:
        log_out = log_result
    outputs.append(log_out)

    # timeline runs on partial data if one of fs/log failed (soft-fail)
    try:
        tl_out = await timeline_hunter.run(input, fs_out, log_out)
    except BaseException as e:  # noqa: BLE001 — soft-fail by spec 11b #5
        log.warning("timeline_hunter raised %s: %s", type(e).__name__, e)
        partial = True
        tl_out = HunterOutput(hunter="timeline", findings=[])
    outputs.append(tl_out)

    return outputs, partial


async def process_report(tar_path: Path) -> tuple[CaseFile | None, bool]:
    """Process one bl-report tar. Returns (case, had_partial_failure).

    Returns (None, False) when all hunters succeed but produce zero findings
    (clean host). Returns (None, True) when partial failure leaves zero
    surviving findings.
    """
    storage = _storage_root()
    work_parent = storage / "work"
    cases_dir = storage / "cases"
    db_path = storage / "evidence.db"

    work_parent.mkdir(parents=True, exist_ok=True)
    cases_dir.mkdir(parents=True, exist_ok=True)
    init_db(db_path)

    work_root = _extract_tar(tar_path, work_parent)
    envelope = parse_envelope(work_root)

    h_input = HunterInput(
        host=envelope.host_id,
        report_id=envelope.report_id,
        work_root=work_root,
        skills=[],  # Day 2: empty; _route_skills lands here Day 3+
    )

    log.info("dispatching fs_hunter, log_hunter, timeline_hunter on %s", envelope.host_id)
    outputs, partial = await _run_hunters(h_input)
    for o in outputs:
        log.info("%s: %d findings", o.hunter, len(o.findings))

    rows = _findings_to_rows(outputs, envelope.host_id, envelope.report_id)
    if not rows:
        log.info("no findings on %s — no case opened", envelope.host_id)
        return (None, partial)

    # Assign IDs via insert (mutates rows in place)
    await asyncio.to_thread(insert_evidence, db_path, rows)
    log.info("wrote %d evidence rows", len(rows))

    case_path = cases_dir / f"{_DAY2_CASE_ID}.yaml"
    existing = _existing_case_path(cases_dir, _DAY2_CASE_ID)

    if existing is None:
        case = _open_case(envelope.host_id, rows)
        await asyncio.to_thread(dump_case, case, str(case_path))
        log.info("opened %s; wrote %s", case.case_id, case_path)
        return (case, partial)

    # Second+ report on an existing case: revise.
    from curator.case_engine import apply_revision, revise
    from curator.case_schema import load_case as _load_case  # avoid top-level cycle-risk

    prior_case = await asyncio.to_thread(_load_case, str(existing))
    if not rows:
        log.info(
            "second report on case %s had no findings; no revision",
            prior_case.case_id,
        )
        return (prior_case, partial)

    log.info(
        "existing case %s found; invoking revise() with %d new rows",
        prior_case.case_id, len(rows),
    )
    revision = await asyncio.to_thread(revise, prior_case, rows)
    trigger = f"{envelope.host_id} report {envelope.report_id}"
    updated = apply_revision(prior_case, revision, trigger=trigger)
    await asyncio.to_thread(dump_case, updated, str(case_path))
    log.info(
        "revised %s: support_type=%s, revision_warranted=%s, history len=%d",
        updated.case_id, revision.support_type, revision.revision_warranted,
        len(updated.hypothesis.history),
    )
    return (updated, partial)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="[%(name)s] %(message)s")
    parser = argparse.ArgumentParser(prog="curator.orchestrator")
    parser.add_argument("tar_path", type=Path, help="Path to bl-report tar (.tar or .tar.gz)")
    args = parser.parse_args()

    _check_preconditions()

    try:
        result = asyncio.run(process_report(args.tar_path))
    except ValueError as e:
        sys.stderr.write(f"[orchestrator] ERROR: {e}\n")
        sys.exit(2)
    except Exception as e:  # io / precondition  # noqa: BLE001 — top-level CLI catch-all
        sys.stderr.write(f"[orchestrator] ERROR: {type(e).__name__}: {e}\n")
        sys.exit(1)

    case, partial = result
    if case is None:
        if partial:
            # zero findings due to partial failure — non-zero exit per spec 11b #5
            sys.exit(1)
        print("")  # clean host — exit 0
        return
    print(case.case_id)
    if partial:
        # findings recorded but at least one hunter failed; soft-fail exit
        sys.exit(1)


if __name__ == "__main__":
    main()
