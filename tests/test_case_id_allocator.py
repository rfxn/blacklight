"""Tests for curator.orchestrator._allocate_case_id."""
from pathlib import Path

from curator.orchestrator import _allocate_case_id


def test_allocator_first_returns_0007(tmp_path: Path) -> None:
    assert _allocate_case_id(tmp_path, year=2026) == "CASE-2026-0007"


def test_allocator_skips_existing(tmp_path: Path) -> None:
    (tmp_path / "CASE-2026-0007.yaml").write_text("case_id: CASE-2026-0007\n")
    assert _allocate_case_id(tmp_path, year=2026) == "CASE-2026-0008"


def test_allocator_handles_gaps(tmp_path: Path) -> None:
    (tmp_path / "CASE-2026-0007.yaml").write_text("case_id: CASE-2026-0007\n")
    (tmp_path / "CASE-2026-0009.yaml").write_text("case_id: CASE-2026-0009\n")
    assert _allocate_case_id(tmp_path, year=2026) == "CASE-2026-0010"


def test_allocator_year_param_override(tmp_path: Path) -> None:
    (tmp_path / "CASE-2026-0007.yaml").write_text("case_id: CASE-2026-0007\n")
    assert _allocate_case_id(tmp_path, year=2027) == "CASE-2027-0007"


def test_allocator_ignores_malformed_filenames(tmp_path: Path) -> None:
    (tmp_path / "CASE-bogus.yaml").write_text("noise\n")
    (tmp_path / "CASE-2026-0007.yaml").write_text("case_id: CASE-2026-0007\n")
    (tmp_path / "stray.txt").write_text("noise\n")
    assert _allocate_case_id(tmp_path, year=2026) == "CASE-2026-0008"
