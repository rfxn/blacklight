"""Unit tests for curator/hunters/timeline_hunter.py — merge + sort."""

from __future__ import annotations

from curator.hunters.base import Finding
from curator.hunters.timeline_hunter import _merge_timeline


def _f(at: str, finding: str) -> Finding:
    return Finding(
        category="test",
        finding=finding,
        confidence=0.5,
        source_refs=["x"],
        raw_evidence_excerpt="",
        observed_at=at,
    )


def test_merge_sorts_by_observed_at() -> None:
    fs = [_f("2026-04-22T10:00:05Z", "fs-late")]
    log = [_f("2026-04-22T10:00:01Z", "log-early")]
    merged = _merge_timeline(fs, log)
    assert merged[0]["source"] == "log"
    assert merged[1]["source"] == "fs"


def test_merge_empty_inputs() -> None:
    assert _merge_timeline([], []) == []
