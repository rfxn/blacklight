"""Unit tests for curator/hunters/base.py — helpers + mocked API call."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import AsyncMock

import pytest

from curator.hunters.base import (
    Finding,
    build_tool_schema,
    load_prompt,
    run_sonnet_hunter,
)


def test_load_prompt(tmp_path: Path) -> None:
    p = tmp_path / "x.md"
    p.write_text("# hello\nworld")
    assert load_prompt(p).startswith("# hello")


def test_load_prompt_refuses_operator_stub(tmp_path: Path) -> None:
    """P3-BUG-02: prompt whose head contains a stub marker must raise, not warn.

    Guards against shipping a TODO skeleton to Sonnet 4.6 at $3/Mtok.
    """
    p = tmp_path / "stub.md"
    p.write_text("TODO: operator content — fill this in\nline2\nline3\n")
    with pytest.raises(RuntimeError, match="operator-content stub"):
        load_prompt(p)


def test_build_tool_schema_shape() -> None:
    s = build_tool_schema()
    assert s["name"] == "report_findings"
    assert "findings" in s["input_schema"]["properties"]
    assert s["input_schema"]["properties"]["findings"]["items"]["properties"]["finding"]["maxLength"] == 200


def test_parse_tool_output_skips_malformed(caplog) -> None:
    """Spec 11b #9: missing-field item is skipped with warning, not raised."""
    import logging
    from curator.hunters.base import _parse_tool_output
    # build a fake response with one good + one missing-category item
    fake_block = type("B", (), {
        "type": "tool_use",
        "name": "report_findings",
        "input": {"findings": [
            {"category": "ok", "finding": "a", "confidence": 0.5,
             "source_refs": [], "raw_evidence_excerpt": "",
             "observed_at": "2026-04-22T00:00:00Z"},
            {"finding": "missing category", "confidence": 0.5,
             "source_refs": [], "raw_evidence_excerpt": "",
             "observed_at": "2026-04-22T00:00:00Z"},
        ]},
    })
    fake_response = type("R", (), {"content": [fake_block]})
    caplog.set_level(logging.WARNING)
    out = _parse_tool_output(fake_response)
    assert len(out) == 1
    assert out[0].category == "ok"
    assert any("missing required fields" in r.message for r in caplog.records)


def test_parse_tool_output_truncates_long_finding(caplog) -> None:
    """Spec 11b #11: finding >200 chars → truncate + warn."""
    import logging
    from curator.hunters.base import _parse_tool_output
    long_finding = "x" * 250
    fake_block = type("B", (), {
        "type": "tool_use",
        "name": "report_findings",
        "input": {"findings": [{
            "category": "c", "finding": long_finding, "confidence": 0.5,
            "source_refs": [], "raw_evidence_excerpt": "",
            "observed_at": "2026-04-22T00:00:00Z",
        }]},
    })
    fake_response = type("R", (), {"content": [fake_block]})
    caplog.set_level(logging.WARNING)
    out = _parse_tool_output(fake_response)
    assert len(out) == 1
    assert len(out[0].finding) == 200
    assert any("truncated" in r.message for r in caplog.records)


def test_parse_tool_output_skips_out_of_range_confidence(caplog) -> None:
    """Spec 11b #12: confidence outside [0,1] → skip with warning."""
    import logging
    from curator.hunters.base import _parse_tool_output
    fake_block = type("B", (), {
        "type": "tool_use",
        "name": "report_findings",
        "input": {"findings": [{
            "category": "c", "finding": "x", "confidence": 1.5,
            "source_refs": [], "raw_evidence_excerpt": "",
            "observed_at": "2026-04-22T00:00:00Z",
        }]},
    })
    fake_response = type("R", (), {"content": [fake_block]})
    caplog.set_level(logging.WARNING)
    out = _parse_tool_output(fake_response)
    assert out == []


@pytest.mark.asyncio
async def test_run_sonnet_hunter_mock_returns_findings(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    prompt = tmp_path / "p.md"
    prompt.write_text("test prompt")

    # Mock response with a tool_use block
    fake_block = type("B", (), {
        "type": "tool_use",
        "name": "report_findings",
        "input": {"findings": [{
            "category": "unusual_php_path",
            "finding": "test",
            "confidence": 0.7,
            "source_refs": ["fs/x.php"],
            "raw_evidence_excerpt": "",
            "observed_at": "2026-04-22T00:00:00Z",
        }]},
    })
    fake_response = type("R", (), {"content": [fake_block]})

    class FakeClient:
        def __init__(self):
            self.messages = AsyncMock()
            self.messages.create = AsyncMock(return_value=fake_response)

    client = FakeClient()
    # Isolate BL_SKIP_LIVE via monkeypatch so teardown restores the
    # original env (raw os.environ.pop leaks across tests).
    monkeypatch.delenv("BL_SKIP_LIVE", raising=False)
    findings = await run_sonnet_hunter(prompt, "user content", client=client)

    assert len(findings) == 1
    assert findings[0].category == "unusual_php_path"
    # Extended thinking discipline: thinking kwarg NOT passed
    call_kwargs = client.messages.create.call_args.kwargs
    assert "thinking" not in call_kwargs
    assert call_kwargs["model"] == "claude-sonnet-4-6"
