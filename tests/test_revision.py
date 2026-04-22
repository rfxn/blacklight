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


# ---------------------------------------------------------------------------
# Day-3 P13: plumbing smoke — revise() builds correctly, parses mock JSON
# ---------------------------------------------------------------------------

def test_revise_mock_roundtrip(monkeypatch: pytest.MonkeyPatch) -> None:
    """revise() with a mock Anthropic client returns a RevisionResult."""
    from unittest.mock import MagicMock
    from curator.case_engine import revise
    from curator.evidence import EvidenceRow

    monkeypatch.delenv("BL_SKIP_LIVE", raising=False)

    payload = {
        "support_type": "supports",
        "revision_warranted": True,
        "new_hypothesis": {
            "summary": "Campaign — PolyShell across host-2 and host-4",
            "confidence": 0.6,
            "reasoning": "Prior hypothesis 'single host PolyShell' (conf 0.4). "
                         "New evidence EV-0011/0012/0013 shows host-4 with "
                         "matching callback vagqea4wrlkdg.top — extends to campaign.",
        },
        "evidence_thread_additions": {"host-4": ["EV-0011", "EV-0012", "EV-0013"]},
        "capability_map_updates": None,
        "open_questions_additions": [],
        "proposed_actions": [],
    }
    text_block = type("B", (), {"type": "text", "text": json.dumps(payload)})
    fake_response = type("R", (), {
        "content": [text_block],
        "stop_reason": "end_turn",
        "usage": None,
    })
    client = MagicMock()
    client.messages.create = MagicMock(return_value=fake_response)

    case = _state("a")
    rows = [
        EvidenceRow(
            id="EV-0011", case_id="CASE-2026-0007", report_id="rpt-supports-0001",
            host="host-4", hunter="fs", category="unusual_php_path",
            finding="PHP file b.php outside framework tree",
            confidence=0.75, source_refs=["fs/.../b.php"],
            raw_evidence_excerpt="", observed_at="2026-04-03T08:52:11Z",
            reported_at="2026-04-03T08:55:00Z",
        ),
    ]
    result = revise(case, rows, client=client)
    assert result.support_type == "supports"
    assert result.revision_warranted is True
    assert result.new_hypothesis is not None
    assert result.new_hypothesis.confidence == pytest.approx(0.6)
    assert result.evidence_thread_additions == {"host-4": ["EV-0011", "EV-0012", "EV-0013"]}

    # Discipline checks on the call kwargs
    kwargs = client.messages.create.call_args.kwargs
    assert kwargs["model"] == "claude-opus-4-7"
    assert kwargs["thinking"] == {"type": "adaptive", "display": "summarized"}
    assert kwargs["output_config"]["effort"] == "high"
    assert kwargs["output_config"]["format"]["type"] == "json_schema"
    assert "tool_choice" not in kwargs  # Opus 4.7 + thinking rejects forced tool_choice
    assert "budget_tokens" not in kwargs  # removed on Opus 4.7
    # Evidence summarization discipline: the JSON evidence batch must NOT contain
    # raw_evidence_excerpt as a key in the data. We check by parsing the JSON
    # portion after the known header separator.
    user_content = kwargs["messages"][0]["content"]
    separator = "NEW EVIDENCE BATCH (summaries; no raw_evidence_excerpt exposure):\n"
    assert separator in user_content, "user message missing expected evidence header"
    evidence_json_str = user_content.split(separator, 1)[1]
    evidence_data = json.loads(evidence_json_str)
    for ev in evidence_data:
        assert "raw_evidence_excerpt" not in ev, \
            "engine view must not expose raw_evidence_excerpt (CLAUDE.md §Pre-committed-mitigations)"


# ---------------------------------------------------------------------------
# Day-3 P14: apply_revision pure-data transform tests
# ---------------------------------------------------------------------------

def test_apply_supports_appends_history() -> None:
    from curator.case_engine import apply_revision
    from curator.case_schema import (
        HypothesisCurrent, RevisionResult,
    )
    case = _state("a")
    new_hyp = HypothesisCurrent(
        summary="Campaign — two hosts",
        confidence=0.6,
        reasoning="Prior 'Single host' extended to campaign by host-4 evidence EV-0011/12/13",
    )
    result = RevisionResult(
        support_type="supports",
        revision_warranted=True,
        new_hypothesis=new_hyp,
        evidence_thread_additions={"host-4": ["EV-0011", "EV-0012", "EV-0013"]},
    )
    updated = apply_revision(case, result, trigger="host-4 report")
    assert updated.hypothesis.current.summary.startswith("Campaign")
    assert updated.hypothesis.current.confidence == pytest.approx(0.6)
    assert len(updated.hypothesis.history) == 1
    assert updated.hypothesis.history[0].confidence == pytest.approx(0.4)
    assert updated.hypothesis.history[0].trigger == "host-4 report"
    # case immutability
    assert case.hypothesis.current.summary != updated.hypothesis.current.summary


def test_apply_noop_when_not_warranted() -> None:
    from curator.case_engine import apply_revision
    from curator.case_schema import RevisionResult
    case = _state("a")
    result = RevisionResult(
        support_type="ambiguous",
        revision_warranted=False,
        open_questions_additions=["does host-4 even run PHP?"],
    )
    updated = apply_revision(case, result, trigger="host-4 ambiguous probe")
    # hypothesis unchanged
    assert updated.hypothesis.current.summary == case.hypothesis.current.summary
    assert updated.hypothesis.history == case.hypothesis.history
    # open questions extended
    assert "does host-4 even run PHP?" in updated.open_questions


def test_apply_merges_evidence_threads_without_duplicates() -> None:
    from curator.case_engine import apply_revision
    from curator.case_schema import RevisionResult
    case = _state("a")  # has host-2: [EV-0001, EV-0002, EV-0003]
    result = RevisionResult(
        support_type="extends",
        revision_warranted=False,
        evidence_thread_additions={
            "host-2": ["EV-0002", "EV-0004"],  # EV-0002 is a dup
            "host-4": ["EV-0011"],
        },
    )
    updated = apply_revision(case, result, trigger="re-analysis")
    assert updated.evidence_threads["host-2"] == ["EV-0001", "EV-0002", "EV-0003", "EV-0004"]
    assert updated.evidence_threads["host-4"] == ["EV-0011"]


def test_apply_extends_capability_map_merges_without_duplicates() -> None:
    from curator.case_engine import apply_revision
    from curator.case_schema import (
        CapabilityMap, InferredCapability, ObservedCapability, RevisionResult,
    )
    case = _state("a")  # observed: [{cap:"arbitrary PHP execution", evidence:["EV-0001"]}]
    update = CapabilityMap(
        observed=[
            ObservedCapability(
                cap="arbitrary PHP execution",
                evidence=["EV-0011"],  # should merge into existing
                confidence=1.0,
            ),
            ObservedCapability(
                cap="C2 callback via .top domain",
                evidence=["EV-0013"],
                confidence=1.0,
            ),
        ],
        inferred=[
            InferredCapability(
                cap="credential harvest capability (PolyShell family standard)",
                basis="family pattern across host-2 and host-4",
                confidence=0.75,
            ),
        ],
    )
    result = RevisionResult(
        support_type="supports",
        revision_warranted=False,
        capability_map_updates=update,
    )
    updated = apply_revision(case, result, trigger="host-4 corroboration")
    caps = {o.cap: o for o in updated.capability_map.observed}
    assert "arbitrary PHP execution" in caps
    assert caps["arbitrary PHP execution"].evidence == ["EV-0001", "EV-0011"]
    assert "C2 callback via .top domain" in caps
    assert len(updated.capability_map.inferred) == 1
    assert updated.capability_map.inferred[0].cap.startswith("credential harvest")


def test_apply_warranted_without_hypothesis_raises() -> None:
    from curator.case_engine import apply_revision
    from curator.case_schema import RevisionResult
    case = _state("a")
    result = RevisionResult(
        support_type="supports",
        revision_warranted=True,
        new_hypothesis=None,  # inconsistent
    )
    with pytest.raises(ValueError, match="requires new_hypothesis"):
        apply_revision(case, result, trigger="x")
