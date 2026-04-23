"""Unit tests for curator/session_runner.py (SDK mocked)."""

from __future__ import annotations

from datetime import datetime, timezone
from unittest.mock import patch

import pytest

from curator.case_schema import CaseFile, Hypothesis, HypothesisCurrent
from curator.evidence import EvidenceRow
from curator.session_runner import (
    SessionProtocolError,
    _build_user_message,
    revise_via_session,
)
from tests._session_mock import (
    agent_message,
    agent_thinking,
    custom_tool_use,
    mock_session_run,
    session_idle,
    session_terminated,
)


def _row() -> EvidenceRow:
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    return EvidenceRow(
        id="ev-001", report_id="rpt-1", host="host-4", hunter="fs",
        category="unusual_php_path", finding="PolyShell",
        confidence=0.85, source_refs=["fs/x.php"],
        raw_evidence_excerpt="", observed_at=now, reported_at=now,
    )


def _case() -> CaseFile:
    now = datetime.now(timezone.utc)
    return CaseFile(
        case_id="CASE-2026-0007", status="active",
        opened_at=now, last_updated_at=now, updated_by="orchestrator-v1",
        hypothesis=Hypothesis(current=HypothesisCurrent(
            summary="1-host unusual_php_path on host-2",
            confidence=0.4, reasoning="initial triage",
        )),
        evidence_threads={"host-2": ["ev-0"]},
    )


_VALID_REVISION_PAYLOAD = {
    "support_type": "extends",
    "revision_warranted": True,
    "new_hypothesis": {
        "summary": "2-host campaign on host-2, host-4",
        "confidence": 0.6,
        "reasoning": "host-4 matches host-2 TTPs",
    },
    "evidence_thread_additions": [
        {"host": "host-4", "evidence_ids": ["ev-001"]},
    ],
    "capability_map_updates": None,
    "open_questions_additions": [],
    "proposed_actions": [],
}


def test_skip_live_shortcircuit_matches_stub(monkeypatch: pytest.MonkeyPatch) -> None:
    """BL_SKIP_LIVE=1 → session_runner returns the same stub as direct path."""
    from curator.case_engine import _stub_result
    monkeypatch.setenv("BL_SKIP_LIVE", "1")
    case = _case()
    rows = [_row()]
    via_session = revise_via_session(case, rows)
    direct = _stub_result(case, rows)
    assert via_session == direct


def test_happy_path_returns_validated_revision(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("BL_SKIP_LIVE", raising=False)
    events = [
        agent_thinking("analyzing new evidence..."),
        custom_tool_use("report_case_revision", _VALID_REVISION_PAYLOAD),
        session_idle(),
    ]
    with mock_session_run(events=events):
        result = revise_via_session(_case(), [_row()])
    assert result.support_type == "extends"
    assert result.revision_warranted is True
    assert result.new_hypothesis.confidence == 0.6


def test_session_terminated_midstream_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("BL_SKIP_LIVE", raising=False)
    events = [agent_message("thinking..."), session_terminated()]
    with mock_session_run(events=events, session_status="idle"):
        with pytest.raises(SessionProtocolError, match="terminated"):
            revise_via_session(_case(), [_row()])


def test_tool_payload_validation_failure_sends_error(monkeypatch: pytest.MonkeyPatch) -> None:
    """When tool payload fails pydantic, runner sends error tool_result + continues."""
    monkeypatch.delenv("BL_SKIP_LIVE", raising=False)
    bad = {"support_type": "invalid_enum_value", "revision_warranted": False}
    events = [
        custom_tool_use("report_case_revision", bad),
        # Agent retries — emits correct payload second time
        custom_tool_use("report_case_revision", _VALID_REVISION_PAYLOAD, tool_use_id="tu-stub-2"),
        session_idle(),
    ]
    with mock_session_run(events=events) as client:
        result = revise_via_session(_case(), [_row()])
    assert result.support_type == "extends"
    # Verify the error tool_result was sent (2 sends: original user.message + error tool_result + success tool_result = 3)
    assert client.beta.sessions.events.send.call_count >= 2


def test_agent_emits_text_only_json_fallback(monkeypatch: pytest.MonkeyPatch) -> None:
    """E3 — agent emits structured JSON in agent.message text (no tool call)."""
    import json
    monkeypatch.delenv("BL_SKIP_LIVE", raising=False)
    events = [
        agent_message(f"Here is my revision: {json.dumps(_VALID_REVISION_PAYLOAD)}"),
        session_idle(),
    ]
    with mock_session_run(events=events):
        result = revise_via_session(_case(), [_row()])
    assert result.support_type == "extends"


def test_agent_emits_no_json_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("BL_SKIP_LIVE", raising=False)
    events = [
        agent_message("I cannot make a decision at this time."),
        session_idle(),
    ]
    with mock_session_run(events=events):
        with pytest.raises(SessionProtocolError, match="idled without"):
            revise_via_session(_case(), [_row()])


def test_build_user_message_excludes_raw_evidence_excerpt() -> None:
    """Context-bloat fence (spec §7)."""
    row = _row()
    row_with_excerpt = row.model_copy(update={"raw_evidence_excerpt": "SECRET RAW LOG LINE"})
    body = _build_user_message(_case(), [row_with_excerpt])
    assert "SECRET RAW LOG LINE" not in body
    assert row.finding in body
