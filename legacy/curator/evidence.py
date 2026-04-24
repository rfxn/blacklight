"""sqlite evidence store for blacklight curator.

Day-2 scope: single-writer (orchestrator); callers wrap in
asyncio.to_thread when invoked from coroutines.
"""

from __future__ import annotations

import json
import sqlite3
import uuid
from pathlib import Path
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field


_DDL = """
CREATE TABLE IF NOT EXISTS evidence (
    id TEXT PRIMARY KEY,
    case_id TEXT,
    report_id TEXT NOT NULL,
    host TEXT NOT NULL,
    hunter TEXT NOT NULL,
    category TEXT NOT NULL,
    finding TEXT NOT NULL,
    confidence REAL NOT NULL CHECK (confidence BETWEEN 0.0 AND 1.0),
    source_refs TEXT NOT NULL,
    raw_evidence_excerpt TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    reported_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_evidence_case ON evidence(case_id);
CREATE INDEX IF NOT EXISTS idx_evidence_report ON evidence(report_id);
CREATE INDEX IF NOT EXISTS idx_evidence_host ON evidence(host);
"""


class EvidenceRow(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    case_id: Optional[str] = None
    report_id: str
    host: str
    hunter: str
    category: str
    finding: str = Field(max_length=200)
    confidence: float = Field(ge=0.0, le=1.0)
    source_refs: list[str] = Field(default_factory=list)
    raw_evidence_excerpt: str = Field(max_length=500)
    observed_at: str
    reported_at: str


def init_db(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path) as conn:
        conn.executescript(_DDL)


def insert_evidence(path: Path, rows: list[EvidenceRow]) -> None:
    if not rows:
        return
    materialized = []
    for r in rows:
        rid = r.id or uuid.uuid4().hex
        materialized.append((
            rid, r.case_id, r.report_id, r.host, r.hunter, r.category,
            r.finding, r.confidence, json.dumps(r.source_refs),
            r.raw_evidence_excerpt, r.observed_at, r.reported_at,
        ))
    with sqlite3.connect(path) as conn:
        conn.executemany(
            """INSERT INTO evidence (id, case_id, report_id, host, hunter,
                   category, finding, confidence, source_refs,
                   raw_evidence_excerpt, observed_at, reported_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            materialized,
        )
        conn.commit()
    # mutate input list's ids in place so caller sees assigned IDs
    for r, mat in zip(rows, materialized):
        if not r.id:
            object.__setattr__(r, "id", mat[0])


def _row_to_model(row: sqlite3.Row) -> EvidenceRow:
    d = dict(row)
    d["source_refs"] = json.loads(d["source_refs"])
    return EvidenceRow.model_validate(d)


def fetch_by_case(path: Path, case_id: str) -> list[EvidenceRow]:
    with sqlite3.connect(path) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.execute(
            "SELECT * FROM evidence WHERE case_id = ? ORDER BY reported_at",
            (case_id,),
        )
        return [_row_to_model(r) for r in cur]


def fetch_by_report(path: Path, report_id: str) -> list[EvidenceRow]:
    with sqlite3.connect(path) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.execute(
            "SELECT * FROM evidence WHERE report_id = ? ORDER BY reported_at",
            (report_id,),
        )
        return [_row_to_model(r) for r in cur]
