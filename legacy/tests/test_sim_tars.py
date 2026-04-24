"""Day-5 sim-tar fixture sanity (P37).

Pre-baked tarballs at ``tests/fixtures/sim/host-{N}-day{D}.tar.gz`` feed
``demo/time_compression.py`` (P38). These tests guard:

  - all 4 expected tars exist after the build,
  - each tar passes ``validate_tar_safety`` and round-trips through
    ``parse_envelope`` cleanly with the right ``host_id`` / ``report_id``,
  - the builder is idempotent — re-running it produces byte-identical
    artifacts (sha256 unchanged), which is the contract the demo replay
    relies on.
"""
from __future__ import annotations

import hashlib
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest

from curator.report_envelope import parse_envelope, validate_tar_safety

SIM_DIR = Path(__file__).parent / "fixtures" / "sim"
BUILDER = SIM_DIR / "build_sim_tars.py"

EXPECTED: tuple[tuple[str, str], ...] = (
    # (basename, expected host_id)
    ("host-4-day5", "host-4"),
    ("host-7-day7", "host-7"),
    ("host-1-day10", "host-1"),
    ("host-5-day14", "host-5"),
)


def _tar_path(basename: str) -> Path:
    return SIM_DIR / f"{basename}.tar.gz"


def test_all_4_tars_exist() -> None:
    missing = [n for n, _ in EXPECTED if not _tar_path(n).is_file()]
    assert missing == [], f"missing sim tars: {missing}"


def test_tars_parse_with_envelope(tmp_path: Path) -> None:
    for basename, expected_host in EXPECTED:
        tar_path = _tar_path(basename)
        # tar-safety first (matches orchestrator._extract_tar order)
        validate_tar_safety(tar_path)
        dest = tmp_path / basename
        dest.mkdir()
        with tarfile.open(tar_path) as tf:
            tf.extractall(dest, filter="data")
        env = parse_envelope(dest)
        assert env.host_id == expected_host, f"{basename}: bad host_id {env.host_id!r}"
        assert env.report_id.startswith("rpt-"), (
            f"{basename}: report_id must match rpt-* pattern, got {env.report_id!r}"
        )


@pytest.mark.parametrize("basename, expected_host", EXPECTED)
def test_tar_layout_matches_bl_report_shape(
    tmp_path: Path, basename: str, expected_host: str
) -> None:
    """Each tar contains manifest.json + logs/ tree, plus fs/ tree on
    compromised hosts (host-1 is anticipatory: no on-disk PHP)."""
    with tarfile.open(_tar_path(basename)) as tf:
        names = set(tf.getnames())
    assert "manifest.json" in names, f"{basename} missing manifest.json"
    assert any(n.startswith("logs/") for n in names), f"{basename} missing logs/"
    if expected_host == "host-1":
        assert not any(n.startswith("fs/") for n in names), (
            "host-1 is anticipatory — must not stage on-disk PHP"
        )
    else:
        assert any(n.startswith("fs/") and n.endswith(".php") for n in names), (
            f"{basename} missing fs/ PHP entry"
        )


def test_builder_is_idempotent() -> None:
    """Re-running the builder must produce byte-identical tars.

    Captures sha256 before, re-runs the builder via the same Python
    interpreter pytest is using (avoids PATH ambiguity), then re-captures
    and asserts the digests match exactly.
    """
    before = {
        n: hashlib.sha256(_tar_path(n).read_bytes()).hexdigest()
        for n, _ in EXPECTED
    }
    result = subprocess.run(
        [sys.executable, str(BUILDER)],
        check=True,
        capture_output=True,
        text=True,
    )
    # Sanity check: builder reported one "built:" line per tar.
    assert result.stdout.count("built: ") == len(EXPECTED), (
        f"builder output unexpected: {result.stdout!r}"
    )
    after = {
        n: hashlib.sha256(_tar_path(n).read_bytes()).hexdigest()
        for n, _ in EXPECTED
    }
    assert before == after, f"non-deterministic build: {before} != {after}"
