"""Unit tests for curator/hunters/fs_hunter.py — local candidate filter."""

from __future__ import annotations

from pathlib import Path

from curator.hunters.fs_hunter import _collect_candidates, _is_suspicious


def test_filters_vendor_paths(tmp_path: Path) -> None:
    (tmp_path / "vendor" / "magento").mkdir(parents=True)
    (tmp_path / "vendor" / "magento" / "helper.php").write_text("<?php ?>")
    (tmp_path / "pub" / "media" / ".cache").mkdir(parents=True)
    (tmp_path / "pub" / "media" / ".cache" / "a.php").write_text("<?php ?>")
    cands = _collect_candidates(tmp_path)
    paths = [c["path"] for c in cands]
    assert any(".cache/a.php" in p for p in paths)
    assert not any("vendor/" in p for p in paths)


def test_empty_fs_root_returns_empty() -> None:
    assert _collect_candidates(Path("/nonexistent/path/that/does/not/exist")) == []


def test_suspicious_php_outside_vendor() -> None:
    class S:
        st_mode = 0o644
    assert _is_suspicious("pub/media/.cache/a.php", S()) is True


def test_not_suspicious_inside_vendor() -> None:
    class S:
        st_mode = 0o644
    assert _is_suspicious("vendor/mage/x.php", S()) is False
