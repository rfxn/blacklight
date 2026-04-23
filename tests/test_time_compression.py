"""Tests for demo.time_compression sim runner."""
from __future__ import annotations

import asyncio
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent

# BL_STUB_FINDINGS=1 tells run_sonnet_hunter to return one synthetic finding
# per hunter instead of the empty-list skip — required in subprocess paths
# where unittest.mock.patch cannot reach into the child process. Without this
# the orchestrator opens no cases and the end-to-end + split assertions fail.
# BL_STUB_UNRELATED_HOST=host-5 tells the case engine stub to return
# support_type="unrelated" for Day-14 host-5 evidence so the split branch
# fires without a model call (demo arc: host-5 skimmer → CASE-2026-0008).
_STUB_ENV = {"BL_SKIP_LIVE": "1", "BL_STUB_FINDINGS": "1", "BL_STUB_UNRELATED_HOST": "host-5"}


@pytest.fixture(autouse=True)
def _ensure_sim_tars() -> None:
    """Build sim tars if absent (P37 may not have run on a fresh checkout)."""
    sim_dir = REPO_ROOT / "tests" / "fixtures" / "sim"
    if not (sim_dir / "host-4-day5.tar.gz").is_file():
        subprocess.run(
            [sys.executable, str(sim_dir / "build_sim_tars.py")],
            check=True, capture_output=True,
        )


def test_runs_end_to_end_in_stub_mode(tmp_path: Path,
                                      monkeypatch: pytest.MonkeyPatch) -> None:
    env = {**os.environ, "BL_STORAGE": str(tmp_path / "storage"), **_STUB_ENV}
    result = subprocess.run(
        [sys.executable, "-m", "demo.time_compression", "--mode=stub", "--fast"],
        capture_output=True, text=True, check=False,
        env=env,
    )
    assert result.returncode == 0, f"sim failed:\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
    cases_dir = tmp_path / "storage" / "cases"
    assert (cases_dir / "CASE-2026-0007.yaml").is_file()
    assert (cases_dir / "CASE-2026-0008.yaml").is_file()


def test_emits_sim_day_captions_in_order(tmp_path: Path,
                                         monkeypatch: pytest.MonkeyPatch) -> None:
    env = {**os.environ, "BL_STORAGE": str(tmp_path / "storage"), **_STUB_ENV}
    result = subprocess.run(
        [sys.executable, "-m", "demo.time_compression", "--mode=stub", "--fast"],
        capture_output=True, text=True, check=False,
        env=env,
    )
    out = result.stdout
    i5  = out.find("[demo sim_day=5]")
    i7  = out.find("[demo sim_day=7]")
    i10 = out.find("[demo sim_day=10]")
    i14 = out.find("[demo sim_day=14]")
    assert -1 < i5 < i7 < i10 < i14, f"caption ordering broken in stdout:\n{out}"


def test_paced_mode_sleeps_between_beats(tmp_path: Path,
                                         monkeypatch: pytest.MonkeyPatch) -> None:
    """In paced mode, time.sleep is called once per beat with the BEATS dwells."""
    monkeypatch.setenv("BL_STORAGE", str(tmp_path / "storage"))
    monkeypatch.setenv("BL_SKIP_LIVE", "1")
    monkeypatch.setenv("BL_STUB_FINDINGS", "1")
    monkeypatch.setenv("BL_STUB_UNRELATED_HOST", "host-5")
    from demo import time_compression
    sleeps: list[int] = []
    monkeypatch.setattr(time_compression.time, "sleep",
                        lambda s: sleeps.append(s))
    asyncio.run(time_compression._run(mode="stub", paced=True))
    # Pin invocation count + per-beat dwells to the BEATS table itself. The
    # earlier `sum(sleeps) >= 60` magic-number floor was disconnected from
    # BEATS (actual 12+14+22+18=66, 6s headroom) — any future sleep_after_sec
    # tuning below 60s total would silently pass. The 90s recording envelope
    # belongs in a separate timing test, not this invocation check.
    expected_total = sum(b.sleep_after_sec for b in time_compression.BEATS)
    assert len(sleeps) == len(time_compression.BEATS)
    assert sum(sleeps) == expected_total


def test_fast_mode_does_not_sleep(tmp_path: Path,
                                  monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("BL_STORAGE", str(tmp_path / "storage"))
    monkeypatch.setenv("BL_SKIP_LIVE", "1")
    monkeypatch.setenv("BL_STUB_FINDINGS", "1")
    monkeypatch.setenv("BL_STUB_UNRELATED_HOST", "host-5")
    from demo import time_compression
    sleeps: list[int] = []
    monkeypatch.setattr(time_compression.time, "sleep",
                        lambda s: sleeps.append(s))
    asyncio.run(time_compression._run(mode="stub", paced=False))
    assert sleeps == []


def test_split_beat_produces_second_case(tmp_path: Path,
                                         monkeypatch: pytest.MonkeyPatch) -> None:
    """Day-14 beat must split CASE-0007 → CASE-0008."""
    env = {**os.environ, "BL_STORAGE": str(tmp_path / "storage"), **_STUB_ENV}
    subprocess.run(
        [sys.executable, "-m", "demo.time_compression", "--mode=stub", "--fast"],
        env=env, check=True, capture_output=True,
    )
    from curator.case_schema import load_case
    prior = load_case(str(tmp_path / "storage" / "cases" / "CASE-2026-0007.yaml"))
    new   = load_case(str(tmp_path / "storage" / "cases" / "CASE-2026-0008.yaml"))
    assert "CASE-2026-0008" in prior.split_into
    assert "CASE-2026-0007" in new.merged_from


def test_stub_mode_self_injects_findings_env(tmp_path: Path) -> None:
    """Regression for P38 sentinel M-01.

    With ONLY BL_STORAGE in the child env (no BL_STUB_FINDINGS, no
    BL_STUB_UNRELATED_HOST), `--mode=stub` must still produce the full
    4-beat arc: CASE-2026-0007 opens and splits to CASE-2026-0008 on Day 14.
    Prior to M-01's fix, _check_preconditions("stub") set only BL_SKIP_LIVE +
    BL_STUB_UNRELATED_HOST, so hunters returned empty findings and no case
    materialized. The Day-14 caption degraded to "Splitting to <no-case>."
    """
    # Scrub parent-process leakage so the child starts from a clean slate.
    env = {
        k: v for k, v in os.environ.items()
        if k not in ("BL_SKIP_LIVE", "BL_STUB_FINDINGS", "BL_STUB_UNRELATED_HOST")
    }
    env["BL_STORAGE"] = str(tmp_path / "storage")
    result = subprocess.run(
        [sys.executable, "-m", "demo.time_compression", "--mode=stub", "--fast"],
        env=env, capture_output=True, text=True, check=False,
    )
    assert result.returncode == 0, (
        f"sim failed:\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
    )
    cases_dir = tmp_path / "storage" / "cases"
    assert (cases_dir / "CASE-2026-0007.yaml").is_file(), (
        f"CASE-2026-0007.yaml missing — stub self-injection regressed.\n"
        f"STDOUT:\n{result.stdout}"
    )
    assert (cases_dir / "CASE-2026-0008.yaml").is_file(), (
        f"CASE-2026-0008.yaml missing — split beat produced no second case.\n"
        f"STDOUT:\n{result.stdout}"
    )
    # Day-14 caption must carry the allocator-assigned id, not "<no-case>".
    assert "Splitting to CASE-2026-0008." in result.stdout, (
        f"Day-14 caption regressed to <no-case>:\n{result.stdout}"
    )
