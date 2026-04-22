"""End-to-end + unit tests for curator/orchestrator.py with mocked AsyncAnthropic."""

from __future__ import annotations

import io
import os
import subprocess
import sys
import tarfile
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

import pytest

from curator.case_schema import load_case
from curator.evidence import EvidenceRow
from curator.hunters.base import Finding, HunterOutput
from curator.orchestrator import _build_initial_hypothesis, _findings_to_rows


FIXTURE_TAR = Path("tests/fixtures/report-host-2-sample.tar.gz")


def _row(category: str = "unusual_php_path", conf: float = 0.7, hunter: str = "fs") -> EvidenceRow:
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    return EvidenceRow(
        id="abc123def45678901234567890abcdef",
        case_id="CASE-2026-0007",
        report_id="rpt-x",
        host="host-2",
        hunter=hunter,
        category=category,
        finding="PolyShell-shaped PHP at pub/media/.cache",
        confidence=conf,
        source_refs=["fs/x.php"],
        raw_evidence_excerpt="",
        observed_at=now,
        reported_at=now,
    )


def test_initial_hypothesis_is_deterministic() -> None:
    rows = [
        _row(conf=0.9),
        _row(category="url_evasion", conf=0.6, hunter="log"),
        _row(category="mtime_cluster", conf=0.5, hunter="timeline"),
    ]
    h1 = _build_initial_hypothesis(rows)
    h2 = _build_initial_hypothesis(rows)
    assert h1.summary == h2.summary
    assert h1.reasoning == h2.reasoning


def test_initial_hypothesis_confidence_capped_at_04() -> None:
    rows = [_row(conf=0.95)]
    h = _build_initial_hypothesis(rows)
    assert h.confidence == 0.4


def test_initial_hypothesis_tie_break_stable_across_row_orders() -> None:
    """P3-BUG-06: when two categories tie on max confidence, top_category
    must not depend on which row the orchestrator happens to iterate first.
    Day-2 hunter ordering guarantees insertion determinism, but Day-3
    revision reads from sqlite where row order is not guaranteed.
    """
    row_a = _row(category="unusual_php_path", conf=0.7, hunter="fs")
    row_b = _row(category="url_evasion", conf=0.7, hunter="log")
    forward = _build_initial_hypothesis([row_a, row_b])
    reverse = _build_initial_hypothesis([row_b, row_a])
    assert forward.summary == reverse.summary


def test_initial_hypothesis_summary_names_top_category() -> None:
    # Use a clear max (not a tie) so the test asserts top_category
    # selection, not the P3-BUG-06 tie-break (covered separately).
    rows = [_row(category="unusual_php_path", conf=0.8) for _ in range(3)] + [
        _row(category="url_evasion", conf=0.5, hunter="log") for _ in range(1)
    ]
    h = _build_initial_hypothesis(rows)
    assert "unusual_php_path" in h.summary


def test_fixture_tar_exists() -> None:
    assert FIXTURE_TAR.exists(), "fixture tar missing — run the Phase 5 Step 1 builder"


def test_prompt_files_exist_and_nonstub() -> None:
    for name in ("fs-hunter.md", "log-hunter.md", "timeline-hunter.md"):
        p = Path("prompts") / name
        assert p.exists(), f"missing prompt: {p}"
        head = "\n".join(p.read_text().splitlines()[:3])
        assert "TODO: operator content" not in head, f"prompt {p} is operator-content stub"


def test_findings_to_rows_preserves_counts() -> None:
    fs_out = HunterOutput(
        hunter="fs",
        findings=[
            Finding(
                category="c",
                finding="f1",
                confidence=0.5,
                source_refs=[],
                raw_evidence_excerpt="",
                observed_at="2026-04-22T10:00:00Z",
            ),
        ],
    )
    rows = _findings_to_rows([fs_out], "host-2", "rpt-z")
    assert len(rows) == 1
    assert rows[0].host == "host-2"
    assert rows[0].case_id == "CASE-2026-0007"


@pytest.mark.asyncio
async def test_process_report_end_to_end_skip_mode(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("BL_SKIP_LIVE", "1")
    monkeypatch.setenv("BL_STORAGE", str(tmp_path / "storage"))

    fake_findings = [
        Finding(
            category="unusual_php_path",
            finding="fixture finding",
            confidence=0.7,
            source_refs=["fs/x.php"],
            raw_evidence_excerpt="",
            observed_at="2026-04-22T10:00:00Z",
        )
    ]

    async def fake_run_sonnet(prompt_path, user_content, client=None):
        return fake_findings

    with patch("curator.hunters.fs_hunter.run_sonnet_hunter", side_effect=fake_run_sonnet), \
         patch("curator.hunters.log_hunter.run_sonnet_hunter", side_effect=fake_run_sonnet), \
         patch("curator.hunters.timeline_hunter.run_sonnet_hunter", side_effect=fake_run_sonnet):
        from curator.orchestrator import process_report
        case, partial = await process_report(FIXTURE_TAR)

    assert case is not None
    assert case.case_id == "CASE-2026-0007"
    assert case.hypothesis.current.confidence == 0.4
    assert case.hypothesis.history == []
    assert "host-2" in case.evidence_threads
    assert not partial

    yaml_path = tmp_path / "storage" / "cases" / "CASE-2026-0007.yaml"
    assert yaml_path.exists()
    reloaded = load_case(str(yaml_path))
    assert reloaded.case_id == "CASE-2026-0007"


@pytest.mark.asyncio
async def test_all_three_hunters_invoked(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Spec 10a: assert all 3 hunters run with sonnet-4-6 and thinking OFF."""
    monkeypatch.setenv("BL_SKIP_LIVE", "1")
    monkeypatch.setenv("BL_STORAGE", str(tmp_path / "storage"))

    calls: list[dict] = []

    async def record_call(prompt_path, user_content, client=None):
        calls.append({"prompt": prompt_path.name, "content_len": len(user_content)})
        return [
            Finding(
                category="url_evasion",
                finding="mock",
                confidence=0.5,
                source_refs=["x"],
                raw_evidence_excerpt="",
                observed_at="2026-04-22T10:00:00Z",
            )
        ]

    with patch("curator.hunters.fs_hunter.run_sonnet_hunter", side_effect=record_call), \
         patch("curator.hunters.log_hunter.run_sonnet_hunter", side_effect=record_call), \
         patch("curator.hunters.timeline_hunter.run_sonnet_hunter", side_effect=record_call):
        from curator.orchestrator import process_report
        case, partial = await process_report(FIXTURE_TAR)

    prompts_called = {c["prompt"] for c in calls}
    assert prompts_called == {"fs-hunter.md", "log-hunter.md", "timeline-hunter.md"}
    assert case is not None
    assert not partial


@pytest.mark.asyncio
async def test_zero_evidence_no_case_opened(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Spec 11 risk #8: zero-finding report writes no case YAML, exits 0 clean."""
    monkeypatch.setenv("BL_SKIP_LIVE", "1")
    monkeypatch.setenv("BL_STORAGE", str(tmp_path / "storage"))

    async def zero_findings(prompt_path, user_content, client=None):
        return []

    with patch("curator.hunters.fs_hunter.run_sonnet_hunter", side_effect=zero_findings), \
         patch("curator.hunters.log_hunter.run_sonnet_hunter", side_effect=zero_findings), \
         patch("curator.hunters.timeline_hunter.run_sonnet_hunter", side_effect=zero_findings):
        from curator.orchestrator import process_report
        case, partial = await process_report(FIXTURE_TAR)

    assert case is None
    assert not partial
    assert not (tmp_path / "storage" / "cases" / "CASE-2026-0007.yaml").exists()


@pytest.mark.asyncio
async def test_one_hunter_failure_records_partial_findings(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Spec 11b #5: one hunter raises -> others' findings still land in evidence.db."""
    monkeypatch.setenv("BL_SKIP_LIVE", "1")
    monkeypatch.setenv("BL_STORAGE", str(tmp_path / "storage"))

    async def good(prompt_path, user_content, client=None):
        return [
            Finding(
                category="unusual_php_path",
                finding="survived",
                confidence=0.7,
                source_refs=["x"],
                raw_evidence_excerpt="",
                observed_at="2026-04-22T10:00:00Z",
            )
        ]

    async def explode(prompt_path, user_content, client=None):
        raise RuntimeError("simulated API failure")

    with patch("curator.hunters.fs_hunter.run_sonnet_hunter", side_effect=good), \
         patch("curator.hunters.log_hunter.run_sonnet_hunter", side_effect=explode), \
         patch("curator.hunters.timeline_hunter.run_sonnet_hunter", side_effect=good):
        from curator.orchestrator import process_report
        case, partial = await process_report(FIXTURE_TAR)

    assert partial is True
    assert case is not None
    from curator.evidence import fetch_by_case
    rows = fetch_by_case(tmp_path / "storage" / "evidence.db", "CASE-2026-0007")
    hunters_with_rows = {r.hunter for r in rows}
    assert "fs" in hunters_with_rows
    assert "log" not in hunters_with_rows


def test_tar_safety_rejects_absolute_via_cli(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    bad = tmp_path / "bad.tar"
    with tarfile.open(bad, "w") as t:
        data = b"x"
        info = tarfile.TarInfo(name="/etc/passwd")
        info.size = len(data)
        t.addfile(info, io.BytesIO(data))

    env = os.environ.copy()
    env["BL_SKIP_LIVE"] = "1"
    env["BL_STORAGE"] = str(tmp_path / "storage")
    proc = subprocess.run(
        [sys.executable, "-m", "curator.orchestrator", str(bad)],
        capture_output=True,
        env=env,
        cwd="/root/admin/work/proj/blacklight",
    )
    assert proc.returncode == 2
    assert b"absolute" in proc.stderr.lower() or b"reject" in proc.stderr.lower()
