"""Tests for curator/intent.py — stub + mocked Opus 4.7 paths."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

from curator.case_schema import CaseFile, Hypothesis, HypothesisCurrent
from curator.intent import (
    IntentParseError,
    _read_artifact,
    _render_case_context,
    reconstruct,
)


def _fake_case() -> CaseFile:
    now = datetime.now(timezone.utc)
    return CaseFile(
        case_id="CASE-2026-0007",
        status="active",
        opened_at=now,
        last_updated_at=now,
        updated_by="test",
        hypothesis=Hypothesis(current=HypothesisCurrent(
            summary="single-host PolyShell",
            confidence=0.4,
            reasoning="initial triage",
        )),
        evidence_threads={"host-2": ["EV-0001"]},
    )


def _fake_text_block(text: str) -> SimpleNamespace:
    return SimpleNamespace(type="text", text=text)


def _mock_response(payload: dict) -> MagicMock:
    r = MagicMock()
    r.content = [_fake_text_block(json.dumps(payload))]
    r.stop_reason = "end_turn"
    return r


def test_intent_stub_returns_valid_capability_map(tmp_path, monkeypatch):
    monkeypatch.setenv("BL_SKIP_LIVE", "1")
    artifact = tmp_path / "a.php"
    artifact.write_text("<?php echo 'test'; ?>")
    result = reconstruct(artifact, _fake_case())
    assert len(result.observed) == 1
    assert result.observed[0].cap == "rce_via_webshell"


def test_intent_mocked_opus_returns_observed_rce(tmp_path, monkeypatch):
    monkeypatch.delenv("BL_SKIP_LIVE", raising=False)
    artifact = tmp_path / "a.php"
    artifact.write_text("<?php eval(base64_decode($_POST['x'])); ?>")
    payload = {
        "observed": [{"cap": "rce_via_webshell", "evidence": ["eval(base64_decode(...))"], "confidence": 1.0}],
        "inferred": [{"cap": "credential_harvest", "basis": "PolyShell family pattern", "confidence": 0.6}],
        "likely_next": [],
    }
    mock_client = MagicMock()
    mock_client.messages.create.return_value = _mock_response(payload)
    result = reconstruct(artifact, _fake_case(), client=mock_client)
    assert result.observed[0].cap == "rce_via_webshell"
    assert result.inferred[0].cap == "credential_harvest"


def test_intent_mocked_malformed_response_raises(tmp_path, monkeypatch):
    monkeypatch.delenv("BL_SKIP_LIVE", raising=False)
    artifact = tmp_path / "a.php"
    artifact.write_text("<?php ?>")
    mock_client = MagicMock()
    mock_client.messages.create.return_value = SimpleNamespace(
        content=[_fake_text_block("not json at all")],
        stop_reason="end_turn",
    )
    with pytest.raises(IntentParseError):
        reconstruct(artifact, _fake_case(), client=mock_client)


def test_intent_mocked_confidence_out_of_range_clamped(tmp_path, monkeypatch):
    monkeypatch.delenv("BL_SKIP_LIVE", raising=False)
    artifact = tmp_path / "a.php"
    artifact.write_text("<?php ?>")
    payload = {
        "observed": [{"cap": "rce_via_webshell", "evidence": [], "confidence": 1.5}],  # out of range
        "inferred": [],
        "likely_next": [],
    }
    mock_client = MagicMock()
    mock_client.messages.create.return_value = _mock_response(payload)
    result = reconstruct(artifact, _fake_case(), client=mock_client)
    assert result.observed[0].confidence == 1.0  # clamped


def test_intent_reads_truncated_artifact(tmp_path, monkeypatch):
    monkeypatch.setenv("BL_SKIP_LIVE", "1")
    artifact = tmp_path / "big.php"
    artifact.write_bytes(b"A" * 128000)  # 128 KB
    text = _read_artifact(artifact)
    assert len(text) == 64000  # truncated to _MAX_ARTIFACT_BYTES


def test_intent_case_context_excludes_raw_evidence():
    case = _fake_case()
    ctx = _render_case_context(case)
    # Must surface only the hypothesis-only projection keys:
    assert set(ctx.keys()) == {"summary", "confidence", "hosts_seen", "observed_caps_so_far"}
    # Must NOT surface any raw_evidence_excerpt field or similar:
    assert "raw_evidence_excerpt" not in json.dumps(ctx)
    assert "evidence_threads" not in ctx  # threads are summary-only; ids OK in hosts_seen
