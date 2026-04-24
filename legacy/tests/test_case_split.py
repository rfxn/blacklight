"""Tests for curator.case_engine.split_case."""
from datetime import datetime, timezone

import pytest

from curator.case_engine import split_case
from curator.case_schema import (
    CaseFile,
    Hypothesis,
    HypothesisCurrent,
)
from curator.evidence import EvidenceRow


def _prior_case() -> CaseFile:
    now = datetime(2026, 4, 25, 10, 0, 0, tzinfo=timezone.utc)
    return CaseFile(
        case_id="CASE-2026-0007",
        status="active",
        opened_at=now,
        last_updated_at=now,
        updated_by="orchestrator-v1",
        hypothesis=Hypothesis(current=HypothesisCurrent(
            summary="three-host PolyShell campaign",
            confidence=0.85,
            reasoning="three hosts with matching TTPs and shared C2",
        )),
        evidence_threads={"host-2": ["EV-0001"], "host-4": ["EV-0010"], "host-7": ["EV-0020"]},
    )


def _new_rows() -> list[EvidenceRow]:
    return [
        EvidenceRow(id="EV-0030", host="host-5", report_id="rpt-host5",
                    hunter="fs", category="unusual_php_path", confidence=0.7,
                    finding="skimmer dropper PHP", source_refs=["fs/.../skimmer.php"],
                    raw_evidence_excerpt="", observed_at="2026-04-25T10:00:00Z",
                    reported_at="2026-04-25T10:00:00Z"),
        EvidenceRow(id="EV-0031", host="host-5", report_id="rpt-host5",
                    hunter="log", category="suspicious_outbound", confidence=0.8,
                    finding="JS exfil to skimmer C2", source_refs=["logs/.../access.log:42"],
                    raw_evidence_excerpt="", observed_at="2026-04-25T10:00:00Z",
                    reported_at="2026-04-25T10:00:00Z"),
    ]


def test_split_returns_two_cases() -> None:
    updated_prior, new_case = split_case(
        _prior_case(), _new_rows(), host="host-5", new_case_id="CASE-2026-0012"
    )
    assert updated_prior.case_id == "CASE-2026-0007"
    assert new_case.case_id == "CASE-2026-0012"


def test_prior_records_split_into() -> None:
    updated_prior, _ = split_case(
        _prior_case(), _new_rows(), host="host-5", new_case_id="CASE-2026-0012"
    )
    assert updated_prior.split_into == ["CASE-2026-0012"]


def test_new_records_merged_from() -> None:
    _, new_case = split_case(
        _prior_case(), _new_rows(), host="host-5", new_case_id="CASE-2026-0012"
    )
    assert new_case.merged_from == ["CASE-2026-0007"]


def test_new_case_has_supplied_id() -> None:
    _, new_case = split_case(
        _prior_case(), _new_rows(), host="host-5", new_case_id="CASE-2026-0099"
    )
    assert new_case.case_id == "CASE-2026-0099"


def test_new_case_initial_hypothesis_from_rows() -> None:
    _, new_case = split_case(
        _prior_case(), _new_rows(), host="host-5", new_case_id="CASE-2026-0012"
    )
    assert new_case.hypothesis.current.confidence == 0.4
    assert "host-5" in new_case.hypothesis.current.summary
    assert new_case.evidence_threads == {"host-5": ["EV-0030", "EV-0031"]}


def test_split_rejects_self_reference() -> None:
    with pytest.raises(ValueError, match="must differ from prior"):
        split_case(
            _prior_case(), _new_rows(),
            host="host-5", new_case_id="CASE-2026-0007",
        )
