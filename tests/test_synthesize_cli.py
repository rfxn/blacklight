"""Tests for curator/synthesize.py — CLI happy path + error modes."""

from __future__ import annotations

import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest
import yaml

from curator.case_schema import CaseFile, CapabilityMap, Hypothesis, HypothesisCurrent


def _write_fixture_case(storage_dir: Path, case_id: str = "CASE-2026-0007") -> Path:
    cases = storage_dir / "cases"
    cases.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc)
    case = CaseFile(
        case_id=case_id,
        status="active",
        opened_at=now,
        last_updated_at=now,
        updated_by="test",
        hypothesis=Hypothesis(current=HypothesisCurrent(summary="test", confidence=0.4, reasoning="r")),
    )
    path = cases / f"{case_id}.yaml"
    with open(path, "w") as f:
        yaml.safe_dump(case.model_dump(mode="json"), f, sort_keys=False)
    return path


def _run_cli(storage: Path, case_id: str, env_extra=None):
    env = {"PATH": Path("/usr/bin:/bin").as_posix(), "BL_STORAGE": str(storage)}
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        [sys.executable, "-m", "curator.synthesize", case_id],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )


def test_cli_happy_path_skip_live(tmp_path):
    _write_fixture_case(tmp_path)
    proc = _run_cli(tmp_path, "CASE-2026-0007", env_extra={"BL_SKIP_LIVE": "1", "PYTHONPATH": "."})
    assert proc.returncode == 0, f"stderr: {proc.stderr}"
    assert "manifest v1" in proc.stdout


def test_cli_case_not_found_exits_2(tmp_path):
    proc = _run_cli(tmp_path, "CASE-9999-9999", env_extra={"BL_SKIP_LIVE": "1", "PYTHONPATH": "."})
    assert proc.returncode == 2
    assert "case not found" in proc.stderr


def test_cli_missing_api_key_exits_1(tmp_path):
    _write_fixture_case(tmp_path)
    # No BL_SKIP_LIVE, no ANTHROPIC_API_KEY
    proc = _run_cli(tmp_path, "CASE-2026-0007", env_extra={"PYTHONPATH": "."})
    assert proc.returncode == 1
    assert "ANTHROPIC_API_KEY not set" in proc.stderr
