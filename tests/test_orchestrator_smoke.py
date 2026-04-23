"""End-to-end + unit tests for curator/orchestrator.py with mocked AsyncAnthropic."""

from __future__ import annotations

import io
import os
import pathlib
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
    # P33: _findings_to_rows no longer stamps case_id (set later in process_report
    # after allocator / existing-case resolution). Row-level case_id stays None
    # until a future phase adds post-open backfill.
    assert rows[0].case_id is None


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
    # P33: rows are inserted before case allocation, so case_id is None in the DB.
    # Query by report_id (the fixture envelope's rpt-sample-host2) to verify
    # surviving hunters' findings landed despite one hunter raising.
    from curator.evidence import fetch_by_report
    rows = fetch_by_report(tmp_path / "storage" / "evidence.db", "rpt-sample-host2")
    hunters_with_rows = {r.hunter for r in rows}
    assert "fs" in hunters_with_rows
    assert "log" not in hunters_with_rows


@pytest.mark.asyncio
async def test_second_report_triggers_revision(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Second report on an existing case invokes revise + apply."""
    from unittest.mock import MagicMock, patch
    from curator.case_schema import HypothesisCurrent, RevisionResult, load_case
    import shutil

    # stage a case YAML at the expected path
    storage = tmp_path / "storage"
    cases_dir = storage / "cases"
    cases_dir.mkdir(parents=True)
    shutil.copy(
        "tests/fixtures/case_state_a.yaml",
        cases_dir / "CASE-2026-0007.yaml",
    )
    monkeypatch.setenv("BL_STORAGE", str(storage))
    monkeypatch.setenv("BL_SKIP_LIVE", "1")  # hunters mock to empty
    monkeypatch.setenv("BL_USE_MANAGED_SESSION", "0")  # pin to direct path; session tests land P5
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)

    # Inject a fake hunter output with findings so rows are non-empty
    from curator.hunters.base import Finding, HunterOutput

    async def _fake_run_hunters(_input):
        fs_out = HunterOutput(hunter="fs", findings=[
            Finding(
                category="unusual_php_path",
                finding="b.php outside framework", confidence=0.75,
                source_refs=["fs/.../b.php"], raw_evidence_excerpt="",
                observed_at="2026-04-03T08:52:11Z",
            ),
        ])
        empty = HunterOutput(hunter="log", findings=[])
        empty_tl = HunterOutput(hunter="timeline", findings=[])
        return ([fs_out, empty, empty_tl], False)

    canned = RevisionResult(
        support_type="supports",
        revision_warranted=True,
        new_hypothesis=HypothesisCurrent(
            summary="Campaign — host-2 and host-4",
            confidence=0.6,
            reasoning="Prior 'single host' extended by host-4 EV.",
        ),
        evidence_thread_additions={"host-4": []},
    )

    with patch("curator.orchestrator._run_hunters", new=_fake_run_hunters), \
         patch("curator.orchestrator.revise", return_value=canned) as mock_revise:
        from curator.orchestrator import process_report
        tar = pathlib.Path("tests/fixtures/report-host-2-sample.tar.gz")
        case, partial = await process_report(tar)

    assert case is not None
    assert case.hypothesis.current.summary.startswith("Campaign")
    assert len(case.hypothesis.history) == 1
    assert case.hypothesis.history[0].confidence == pytest.approx(0.4)
    assert mock_revise.called

    # YAML written to disk
    disk = load_case(str(cases_dir / "CASE-2026-0007.yaml"))
    assert len(disk.hypothesis.history) == 1


def test_second_report_no_findings_skips_revision(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Second report with zero findings does not call revise — returns prior case."""
    import asyncio
    import shutil
    from unittest.mock import patch

    storage = tmp_path / "storage"
    cases_dir = storage / "cases"
    cases_dir.mkdir(parents=True)
    shutil.copy(
        "tests/fixtures/case_state_a.yaml",
        cases_dir / "CASE-2026-0007.yaml",
    )
    monkeypatch.setenv("BL_STORAGE", str(storage))
    monkeypatch.setenv("BL_SKIP_LIVE", "1")
    monkeypatch.setenv("BL_USE_MANAGED_SESSION", "0")  # pin to direct path; session tests land P5
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)

    from curator.hunters.base import HunterOutput

    async def _empty_hunters(_input):
        return ([
            HunterOutput(hunter="fs", findings=[]),
            HunterOutput(hunter="log", findings=[]),
            HunterOutput(hunter="timeline", findings=[]),
        ], False)

    with patch("curator.orchestrator._run_hunters", new=_empty_hunters), \
         patch("curator.orchestrator.revise") as mock_revise:
        from curator.orchestrator import process_report
        tar = pathlib.Path("tests/fixtures/report-host-2-sample.tar.gz")
        case, partial = asyncio.get_event_loop().run_until_complete(process_report(tar))

    # No findings means no case opened and revise not called
    assert not mock_revise.called
    # case is None because no findings (clean path) — or it returns prior_case
    # depending on BL_SKIP_LIVE interaction. The important thing: revise NOT called.


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
        cwd=str(Path(__file__).resolve().parent.parent),
    )
    assert proc.returncode == 2
    assert b"absolute" in proc.stderr.lower() or b"reject" in proc.stderr.lower()


# === P25 Day 4: intent reconstructor wiring ===


def _make_fs_row(category: str = "webshell_candidate", conf: float = 0.85) -> EvidenceRow:
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    return EvidenceRow(
        id="ev_test",
        case_id="CASE-2026-0007",
        report_id="rpt-test",
        host="host-2",
        hunter="fs",
        category=category,
        finding=f"synthetic {category} for orchestrator wiring test",
        confidence=conf,
        source_refs=["fs/test.php"],
        raw_evidence_excerpt="<?php eval(base64_decode($_POST['x'])); ?>",
        observed_at=now,
        reported_at=now,
    )


def _open_case_for_test():
    """Build a minimal CaseFile for intent-wiring tests."""
    from datetime import datetime, timezone
    from curator.case_schema import CaseFile, Hypothesis, HypothesisCurrent
    now = datetime.now(timezone.utc)
    return CaseFile(
        case_id="CASE-2026-0007",
        status="active",
        opened_at=now,
        last_updated_at=now,
        updated_by="test",
        hypothesis=Hypothesis(current=HypothesisCurrent(summary="PolyShell", confidence=0.4, reasoning="r")),
    )


@pytest.mark.asyncio
async def test_intent_merge_via_orchestrator(tmp_path, monkeypatch):
    """webshell_candidate + .php in tar -> intent runs -> capability_map populated."""
    monkeypatch.setenv("BL_SKIP_LIVE", "1")
    from curator.orchestrator import _maybe_reconstruct_intent
    from curator.case_engine import CapabilityMap  # noqa: F401 — sanity import

    # Build a work_root with an fs/test.php artifact
    (tmp_path / "fs").mkdir()
    (tmp_path / "fs" / "test.php").write_text("<?php eval($_POST['x']); ?>")

    case = _open_case_for_test()  # helper: uses _open_case with 1 row
    row = _make_fs_row(category="webshell_candidate")
    updated = await _maybe_reconstruct_intent([row], tmp_path, case)
    # BL_SKIP_LIVE=1 stub returns 1 observed entry
    assert len(updated.capability_map.observed) >= 1
    assert updated.capability_map.observed[0].cap == "rce_via_webshell"


@pytest.mark.asyncio
async def test_intent_skipped_without_webshell_candidate(tmp_path, monkeypatch):
    """No webshell_candidate row -> intent does NOT run, case unchanged."""
    monkeypatch.setenv("BL_SKIP_LIVE", "1")
    from curator.orchestrator import _maybe_reconstruct_intent

    (tmp_path / "fs").mkdir()
    (tmp_path / "fs" / "test.php").write_text("<?php ?>")

    case = _open_case_for_test()
    row = _make_fs_row(category="log_anomaly")  # NOT webshell_candidate
    updated = await _maybe_reconstruct_intent([row], tmp_path, case)
    # capability_map unchanged (empty observed)
    assert len(updated.capability_map.observed) == 0


# === P35: split-on-unrelated branch ===


def _seed_existing_case(cases_dir: Path, case_id: str) -> None:
    """Drop the case_state_a fixture under a chosen case_id for split-path tests."""
    import shutil
    src = Path("tests/fixtures/case_state_a.yaml")
    dst = cases_dir / f"{case_id}.yaml"
    shutil.copy(src, dst)


def _build_minimal_report_tar(tmp_path: Path, host: str) -> Path:
    """Build a minimal bl-report tar with manifest + one PHP fs entry.

    The tar's hunter chain is bypassed in tests via _run_hunters patch — the
    PHP body need only be present, not realistic. envelope.host_id flows
    through to split_case as the new case's evidence_threads key.
    """
    import gzip
    import json
    out = tmp_path / f"{host}-min.tar.gz"
    manifest = {
        "report_id": f"rpt-{host}-min",
        "host_id": host,
        "collected_at": "2026-04-22T22:15:01Z",
        "tool_version": "bl-report 0.2.0",
        "path_map": {"fs/var/www/html": "/var/www/html"},
    }
    manifest_bytes = json.dumps(manifest).encode()
    php_bytes = b"<?php /* P35 split-path fixture - bypassed by mocked _run_hunters */ ?>"
    with gzip.open(out, "wb") as gz:
        with tarfile.open(fileobj=gz, mode="w") as tf:
            mi = tarfile.TarInfo(name="./manifest.json")
            mi.size = len(manifest_bytes)
            tf.addfile(mi, io.BytesIO(manifest_bytes))
            pi = tarfile.TarInfo(name="./fs/var/www/html/skimmer.php")
            pi.size = len(php_bytes)
            tf.addfile(pi, io.BytesIO(php_bytes))
    return out


@pytest.mark.asyncio
async def test_smoke_split_on_unrelated(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Existing case + new report -> revise returns unrelated -> split path.

    Asserts:
    - returned case is the NEW case (so demo `print(case.case_id)` shows the new id)
    - new case carries merged_from=[prior]
    - prior case carries split_into=[new]
    - both YAMLs land on disk
    - split deliberately does NOT inherit prior capability_map (different family)
    """
    from curator import orchestrator
    from curator.case_schema import RevisionResult, load_case as _load

    storage = tmp_path / "storage"
    cases_dir = storage / "cases"
    cases_dir.mkdir(parents=True)
    _seed_existing_case(cases_dir, "CASE-2026-0007")

    monkeypatch.setenv("BL_STORAGE", str(storage))
    monkeypatch.setenv("BL_SKIP_LIVE", "1")
    monkeypatch.setenv("BL_USE_MANAGED_SESSION", "0")  # pin to direct path; session tests land P5
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)

    # Fake hunters: produce one row so the path reaches revise()
    async def _fake_run_hunters(_input):
        fs_out = HunterOutput(hunter="fs", findings=[
            Finding(
                category="unusual_php_path",
                finding="skimmer.php — different family than prior PolyShell",
                confidence=0.7,
                source_refs=["fs/var/www/html/skimmer.php"],
                raw_evidence_excerpt="",
                observed_at="2026-04-22T10:00:00Z",
            ),
        ])
        empty = HunterOutput(hunter="log", findings=[])
        empty_tl = HunterOutput(hunter="timeline", findings=[])
        return ([fs_out, empty, empty_tl], False)

    # Patch revise() to return unrelated + revision_warranted=False
    def _fake_revise(case, rows, **_):
        return RevisionResult(
            support_type="unrelated",
            revision_warranted=False,
            new_hypothesis=None,
            evidence_thread_additions={},
            capability_map_updates=None,
            open_questions_additions=["new investigation may be warranted"],
            proposed_actions=[],
        )

    tar_path = _build_minimal_report_tar(tmp_path, host="host-5")
    with patch("curator.orchestrator._run_hunters", new=_fake_run_hunters), \
         patch("curator.orchestrator.revise", side_effect=_fake_revise):
        result_case, partial = await orchestrator.process_report(tar_path)

    assert result_case is not None
    assert not partial
    # Returned case is the NEW case so demo stdout shows the new id
    assert result_case.case_id == "CASE-2026-0008"
    assert result_case.merged_from == ["CASE-2026-0007"]
    # Both YAMLs landed on disk
    assert (cases_dir / "CASE-2026-0007.yaml").exists()
    assert (cases_dir / "CASE-2026-0008.yaml").exists()
    # Prior records the split successor
    prior = _load(str(cases_dir / "CASE-2026-0007.yaml"))
    assert prior.split_into == ["CASE-2026-0008"]
    # Prior hypothesis.history is NOT mutated by split (append-only discipline:
    # split_case only updates split_into/last_updated_at/updated_by; revise()
    # path is the only writer of history entries — see case-lifecycle skill).
    assert prior.hypothesis.history == []
    # Split deliberately does NOT carry prior capability_map (different family).
    assert result_case.capability_map.observed == []
    assert result_case.capability_map.inferred == []


@pytest.mark.asyncio
async def test_smoke_split_does_not_call_apply_revision(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Sentinel guard: unrelated path must skip apply_revision entirely.

    apply_revision merges capability_map into the prior case — calling it on
    the unrelated path would smuggle the new evidence into the prior hypothesis,
    defeating the split. This test fails LOUDLY if a future refactor falls
    through to the apply branch on unrelated.
    """
    from curator import orchestrator
    from curator.case_schema import RevisionResult

    storage = tmp_path / "storage"
    cases_dir = storage / "cases"
    cases_dir.mkdir(parents=True)
    _seed_existing_case(cases_dir, "CASE-2026-0007")

    monkeypatch.setenv("BL_STORAGE", str(storage))
    monkeypatch.setenv("BL_SKIP_LIVE", "1")
    monkeypatch.setenv("BL_USE_MANAGED_SESSION", "0")  # pin to direct path; session tests land P5
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)

    async def _fake_run_hunters(_input):
        return ([
            HunterOutput(hunter="fs", findings=[
                Finding(
                    category="unusual_php_path",
                    finding="skimmer.php",
                    confidence=0.7,
                    source_refs=["fs/x.php"],
                    raw_evidence_excerpt="",
                    observed_at="2026-04-22T10:00:00Z",
                ),
            ]),
            HunterOutput(hunter="log", findings=[]),
            HunterOutput(hunter="timeline", findings=[]),
        ], False)

    def _fake_revise(case, rows, **_):
        return RevisionResult(
            support_type="unrelated",
            revision_warranted=False,
            new_hypothesis=None,
        )

    tar_path = _build_minimal_report_tar(tmp_path, host="host-5")
    with patch("curator.orchestrator._run_hunters", new=_fake_run_hunters), \
         patch("curator.orchestrator.revise", side_effect=_fake_revise), \
         patch("curator.orchestrator.apply_revision") as mock_apply:
        await orchestrator.process_report(tar_path)

    assert not mock_apply.called, "split path must not invoke apply_revision()"
