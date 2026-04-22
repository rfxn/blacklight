"""Unit tests for curator/report_envelope.py."""

from __future__ import annotations

import io
import json
import tarfile
from datetime import datetime, timezone
from pathlib import Path

import pytest
from pydantic import ValidationError

from curator.report_envelope import ReportEnvelope, parse_envelope, validate_tar_safety


def _valid_envelope_dict() -> dict:
    return {
        "report_id": "rpt-test-abc",
        "host_id": "host-2",
        "collected_at": "2026-04-22T22:15:01Z",
        "tool_version": "bl-report 0.2.0",
        "path_map": {"fs/var/www/html": "/var/www/html"},
    }


def test_valid_envelope_parses(tmp_path: Path) -> None:
    (tmp_path / "manifest.json").write_text(json.dumps(_valid_envelope_dict()))
    env = parse_envelope(tmp_path)
    assert env.report_id == "rpt-test-abc"
    assert env.host_id == "host-2"


def test_missing_host_id_rejected(tmp_path: Path) -> None:
    bad = _valid_envelope_dict()
    del bad["host_id"]
    (tmp_path / "manifest.json").write_text(json.dumps(bad))
    with pytest.raises(ValidationError):
        parse_envelope(tmp_path)


def _make_tar_with_entry(path: Path, member_name: str) -> None:
    """Build a tar with a single member whose name is attacker-controlled."""
    with tarfile.open(path, "w") as t:
        data = b"payload"
        info = tarfile.TarInfo(name=member_name)
        info.size = len(data)
        t.addfile(info, io.BytesIO(data))


def test_tar_safety_rejects_absolute_path(tmp_path: Path) -> None:
    t = tmp_path / "bad.tar"
    _make_tar_with_entry(t, "/etc/passwd")
    with pytest.raises(ValueError, match="absolute"):
        validate_tar_safety(t)


def test_tar_safety_rejects_dotdot(tmp_path: Path) -> None:
    t = tmp_path / "bad.tar"
    _make_tar_with_entry(t, "../../../root/.ssh/id_rsa")
    with pytest.raises(ValueError, match="escape"):
        validate_tar_safety(t)
