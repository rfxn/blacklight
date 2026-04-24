"""Demo script structure tests."""
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "demo" / "script.md"
TIMING_MARKERS = ("0:00", "0:15", "0:35", "1:15", "1:55", "2:25", "2:50", "3:00")


def test_script_exists() -> None:
    assert SCRIPT.is_file()


def test_script_contains_all_timing_markers() -> None:
    text = SCRIPT.read_text()
    missing = [m for m in TIMING_MARKERS if m not in text]
    assert missing == [], f"missing timing markers: {missing}"


def test_script_documents_compose_invocation() -> None:
    text = SCRIPT.read_text()
    assert "docker compose up" in text


def test_script_documents_sim_invocation() -> None:
    text = SCRIPT.read_text()
    assert "python -m demo.time_compression" in text
    assert "--mode=live" in text


def test_script_has_recovery_section() -> None:
    text = SCRIPT.read_text().lower()
    assert "recording fails" in text or "recovery" in text
