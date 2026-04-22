"""Hypothesis-revision unit test — THE Day 3 10pm CT go/no-go gate.

Six fixtures = 2 case states × 3 evidence types. All skipped until Day 3.
Each test loads a case state and an evidence report, calls the case-engine
revision entry point, and asserts the RevisionResult carries the expected
`support_type`.

Per HANDOFF §"load-bearing capability":
  If green Thu 22:00 CT, the demo has a spine.
  If red, Fri 09:00 CT decision: one more attempt or degrade to V4.

Six API calls per run. Cheap. Run with:
  .venv/bin/pytest -v tests/test_revision.py
"""

from __future__ import annotations

import json
import pathlib

import pytest

from curator.case_schema import CaseFile, load_case

FIXTURES = pathlib.Path(__file__).parent / "fixtures"
REPORTS = FIXTURES / "evidence_reports"

SKIP_REASON = "Day 3 implementation — case_engine.revise() not yet wired"


# ---------------------------------------------------------------------------
# helpers (stay import-time cheap; no network)
# ---------------------------------------------------------------------------

def _state(name: str) -> CaseFile:
    """Load a case-state fixture by short name (a|b)."""
    return load_case(str(FIXTURES / f"case_state_{name}.yaml"))


def _report(kind: str) -> pathlib.Path:
    """Return path to an evidence-report fixture by kind.

    Day 3 fills these; Day 1 ships empty-shell placeholders so pytest collects.
    """
    return REPORTS / f"{kind}.yaml"


def _rows_from_json(kind: str, *, case_id: str = "CASE-2026-0007") -> list:
    """Load evidence rows from tests/fixtures/evidence_reports/<kind>_rows.json."""
    from curator.evidence import EvidenceRow
    data = json.loads((REPORTS / f"{kind}_rows.json").read_text(encoding="utf-8"))
    return [
        EvidenceRow(
            id=d["id"],
            case_id=case_id,
            report_id=f"rpt-{kind}-0001",
            host=d["host"],
            hunter=d["hunter"],
            category=d["category"],
            finding=d["finding"],
            confidence=d["confidence"],
            source_refs=d["source_refs"],
            raw_evidence_excerpt="",
            observed_at=d["observed_at"],
            reported_at=d["observed_at"],
        )
        for d in data
    ]


def _mock_anthropic(response_payload: dict):
    """Build a MagicMock anthropic.Anthropic client that returns response_payload as a text block."""
    from unittest.mock import MagicMock
    text_block = type("B", (), {"type": "text", "text": json.dumps(response_payload)})
    fake_response = type("R", (), {
        "content": [text_block], "stop_reason": "end_turn", "usage": None,
    })
    client = MagicMock()
    client.messages.create = MagicMock(return_value=fake_response)
    return client


# ---------------------------------------------------------------------------
# fixture sanity (runs today, not skipped)
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("kind", ["supports", "contradicts", "extends"])
def test_fixture_rows_parse_as_evidence_rows(kind: str) -> None:
    """P11: JSON row fixtures parse into EvidenceRow with required fields present."""
    rows = _rows_from_json(kind)
    assert len(rows) >= 1
    for row in rows:
        assert row.id.startswith("EV-")
        assert row.host
        assert row.hunter
        assert row.category
        assert row.finding
        assert 0.0 <= row.confidence <= 1.0
        assert row.observed_at


def test_case_state_a_parses() -> None:
    c = _state("a")
    assert c.case_id == "CASE-2026-0007"
    assert c.hypothesis.current.confidence == pytest.approx(0.4)
    assert list(c.evidence_threads) == ["host-2"]
    assert c.hypothesis.history == []


def test_case_state_b_parses() -> None:
    c = _state("b")
    assert c.case_id == "CASE-2026-0007"
    assert c.hypothesis.current.confidence == pytest.approx(0.6)
    assert set(c.evidence_threads) == {"host-2", "host-4"}
    assert len(c.hypothesis.history) == 1
    assert c.hypothesis.history[0].confidence == pytest.approx(0.4)


# ---------------------------------------------------------------------------
# revision matrix — skipped until Day 3
# ---------------------------------------------------------------------------

@pytest.mark.skip(reason=SKIP_REASON)
def test_state_a_supports() -> None:
    """state_a (single-host, 0.4) + supports evidence → support_type == 'supports'.
    Confidence should rise modestly (not a bare bump)."""
    raise NotImplementedError


@pytest.mark.skip(reason=SKIP_REASON)
def test_state_a_contradicts() -> None:
    """state_a + contradicting evidence → 'contradicts'. Current hypothesis
    must be acknowledged and updated, not silently replaced."""
    raise NotImplementedError


@pytest.mark.skip(reason=SKIP_REASON)
def test_state_a_extends() -> None:
    """state_a + extending evidence → 'extends'. Hypothesis gains detail
    without significant confidence shift."""
    raise NotImplementedError


@pytest.mark.skip(reason=SKIP_REASON)
def test_state_b_supports() -> None:
    """state_b (two-host, 0.6) + supports → 'supports'. Campaign attribution
    should strengthen; confidence moves but with explicit reasoning."""
    raise NotImplementedError


@pytest.mark.skip(reason=SKIP_REASON)
def test_state_b_contradicts() -> None:
    """state_b + contradicting evidence (e.g. different family markers) →
    'contradicts'. open_questions should flag the competing hypothesis
    rather than force-fit into the existing case."""
    raise NotImplementedError


@pytest.mark.skip(reason=SKIP_REASON)
def test_state_b_extends() -> None:
    """state_b + extending evidence (third host, same TTPs) → 'extends'.
    evidence_thread_additions should land on the correct host."""
    raise NotImplementedError


# ---------------------------------------------------------------------------
# placeholder path checks — confirm fixture files exist so Day 3 has targets
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("kind", ["supports", "contradicts", "extends"])
def test_evidence_report_fixture_exists(kind: str) -> None:
    assert _report(kind).exists(), f"missing evidence report fixture: {kind}.yaml"
