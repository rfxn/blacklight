"""Tests for curator/case_engine.merge_capability_map()."""

from __future__ import annotations

from datetime import datetime, timezone

from curator.case_engine import merge_capability_map
from curator.case_schema import (
    CapabilityMap,
    CaseFile,
    Hypothesis,
    HypothesisCurrent,
    ObservedCapability,
)


def _fake_case(caps=None) -> CaseFile:
    now = datetime(2026, 4, 23, 12, 0, 0, tzinfo=timezone.utc)
    return CaseFile(
        case_id="CASE-2026-0007",
        status="active",
        opened_at=now,
        last_updated_at=now,
        updated_by="prior",
        hypothesis=Hypothesis(current=HypothesisCurrent(summary="original", confidence=0.4, reasoning="r")),
        capability_map=CapabilityMap(observed=caps or [], inferred=[], likely_next=[]),
    )


def test_merge_updates_last_updated_at_and_updated_by():
    case = _fake_case()
    later = datetime(2026, 4, 24, 12, 0, 0, tzinfo=timezone.utc)
    updated = merge_capability_map(
        case,
        CapabilityMap(observed=[ObservedCapability(cap="rce_via_webshell", evidence=[], confidence=1.0)]),
        updated_by="intent_reconstructor",
        clock=lambda: later,
    )
    assert updated.last_updated_at == later
    assert updated.updated_by == "intent_reconstructor"
    assert case.last_updated_at != later
    assert case.updated_by == "prior"


def test_merge_does_not_touch_hypothesis():
    case = _fake_case()
    updated = merge_capability_map(
        case,
        CapabilityMap(observed=[ObservedCapability(cap="rce_via_webshell", evidence=[], confidence=1.0)]),
    )
    assert updated.hypothesis.current.summary == "original"
    assert updated.hypothesis.current.confidence == 0.4
    assert updated.hypothesis.history == []


def test_merge_dedupes_observed_by_cap():
    case = _fake_case(caps=[ObservedCapability(cap="rce_via_webshell", evidence=["e1"], confidence=1.0)])
    update = CapabilityMap(observed=[ObservedCapability(cap="rce_via_webshell", evidence=["e2"], confidence=1.0)])
    updated = merge_capability_map(case, update)
    assert len(updated.capability_map.observed) == 1
    assert set(updated.capability_map.observed[0].evidence) == {"e1", "e2"}
