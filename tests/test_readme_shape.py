"""README structure tests — judges skim, not run."""
from pathlib import Path

README = Path(__file__).parent.parent / "README.md"


def test_above_fold_has_pitch_and_try_block() -> None:
    lines = README.read_text().splitlines()
    above_fold = "\n".join(lines[:50])
    assert "docker compose up" in above_fold, "try-it block must be above fold (line 50)"


def test_has_why_these_models_section() -> None:
    text = README.read_text()
    assert "## Why these models" in text or "## Why These Models" in text


def test_names_both_models() -> None:
    text = README.read_text()
    assert "Sonnet 4.6" in text or "claude-sonnet-4-6" in text
    assert "Opus 4.7" in text or "claude-opus-4-7" in text


def test_documents_time_compression_invocation() -> None:
    text = README.read_text()
    assert "time_compression" in text


def test_under_300_lines() -> None:
    lines = README.read_text().splitlines()
    assert len(lines) < 300, f"README is {len(lines)} lines — judges skim"
