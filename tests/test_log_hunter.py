"""Unit tests for curator/hunters/log_hunter.py — regex prefilter."""

from __future__ import annotations

from pathlib import Path

from curator.hunters.log_hunter import _extract_suspicious


def test_url_evasion_matches(tmp_path: Path) -> None:
    log = tmp_path / "access.log"
    log.write_text(
        '192.0.2.1 - - [22/Apr/2026:10:00:00 +0000] "GET /pub/media/.cache/a.php/image.jpg HTTP/1.1" 200 512\n'
        '192.0.2.2 - - [22/Apr/2026:10:00:01 +0000] "GET /index.php HTTP/1.1" 200 2048\n'
    )
    hits = _extract_suspicious(log)
    assert len(hits) == 1
    assert hits[0]["kind"] == "url_evasion"


def test_suspicious_tld_matches(tmp_path: Path) -> None:
    log = tmp_path / "access.log"
    log.write_text('outbound POST to http://vagqea4wrlkdg.top/gate\n')
    hits = _extract_suspicious(log)
    assert len(hits) == 1
    assert hits[0]["kind"] == "suspicious_callback"


def test_no_matches_empty(tmp_path: Path) -> None:
    log = tmp_path / "access.log"
    log.write_text("all clean\n")
    assert _extract_suspicious(log) == []
