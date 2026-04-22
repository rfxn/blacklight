"""Unit tests for curator/evidence.py — sqlite evidence store."""

from __future__ import annotations

import json
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import pytest

from curator.evidence import EvidenceRow, fetch_by_case, fetch_by_report, init_db, insert_evidence


def _sample_row(report_id: str = "rpt-test", case_id: str | None = None, hunter: str = "fs") -> EvidenceRow:
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    return EvidenceRow(
        id="",  # assigned by insert
        case_id=case_id,
        report_id=report_id,
        host="host-2",
        hunter=hunter,
        category="unusual_php_path",
        finding="PHP file outside vendor tree",
        confidence=0.7,
        source_refs=["fs/var/www/html/a.php"],
        raw_evidence_excerpt="<?php eval(...)",
        observed_at=now,
        reported_at=now,
    )


def test_init_db_creates_table(tmp_path: Path) -> None:
    db = tmp_path / "evidence.db"
    init_db(db)
    init_db(db)  # idempotent
    assert db.exists()


def test_insert_and_fetch_by_report(tmp_path: Path) -> None:
    db = tmp_path / "evidence.db"
    init_db(db)
    r1 = _sample_row(report_id="rpt-A", hunter="fs")
    r2 = _sample_row(report_id="rpt-A", hunter="log")
    r3 = _sample_row(report_id="rpt-B", hunter="fs")
    insert_evidence(db, [r1, r2, r3])

    rows_a = fetch_by_report(db, "rpt-A")
    rows_b = fetch_by_report(db, "rpt-B")
    assert len(rows_a) == 2
    assert len(rows_b) == 1
    assert {r.hunter for r in rows_a} == {"fs", "log"}
    assert all(isinstance(r.id, str) and len(r.id) == 32 for r in rows_a)


def test_fetch_by_case_filters_correctly(tmp_path: Path) -> None:
    db = tmp_path / "evidence.db"
    init_db(db)
    r1 = _sample_row(report_id="rpt-X", case_id="CASE-2026-0007")
    r2 = _sample_row(report_id="rpt-X", case_id=None)
    insert_evidence(db, [r1, r2])

    assigned = fetch_by_case(db, "CASE-2026-0007")
    assert len(assigned) == 1
    assert assigned[0].case_id == "CASE-2026-0007"
