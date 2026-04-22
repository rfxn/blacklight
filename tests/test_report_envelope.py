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


def _make_tar_with_symlink(path: Path, member_name: str, linkname: str) -> None:
    """Build a tar containing a benign file + a single symlink entry.

    Mirrors the bl-report P9 class: a tarball with manifest.json + a log-file
    symlink whose linkname points outside the extraction root (e.g., an
    Apache-container /var/log symlink pointing to /dev/stdout).
    """
    with tarfile.open(path, "w") as t:
        manifest = b"{}"
        info = tarfile.TarInfo(name="manifest.json")
        info.size = len(manifest)
        t.addfile(info, io.BytesIO(manifest))
        sym = tarfile.TarInfo(name=member_name)
        sym.type = tarfile.SYMTYPE
        sym.linkname = linkname
        t.addfile(sym)


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


@pytest.mark.parametrize(
    "linkname",
    [
        "/dev/stdout",        # device-symlink escape (bl-report P9 class)
        "../../../etc/passwd",  # traversal-symlink escape
    ],
)
def test_tar_safety_rejects_symlink_escape(tmp_path: Path, linkname: str) -> None:
    """P3-BUG-13: symlinks whose linkname escapes the extraction root are rejected.

    Guards the Day-2 P9 shape — bl-report tarred /var/log/apache2/*.log symlinks
    that pointed to /dev/stdout inside the php:8.3-apache container; the
    validator correctly refused. Also covers the traversal-symlink variant.
    """
    t = tmp_path / "bad.tar"
    _make_tar_with_symlink(t, "logs/access.log", linkname)
    with pytest.raises(ValueError, match="escape"):
        validate_tar_safety(t)


def test_tar_safety_accepts_in_root_relative_symlink(tmp_path: Path) -> None:
    """Positive companion: a benign in-root relative symlink passes validation."""
    t = tmp_path / "ok.tar"
    _make_tar_with_symlink(t, "logs/latest.log", "relative/target.txt")
    validate_tar_safety(t)  # must not raise
