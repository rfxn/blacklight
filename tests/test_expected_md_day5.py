"""EXPECTED.md Day-5 section presence + cross-reference checks (P41)."""
from pathlib import Path

EXPECTED = Path(__file__).parent.parent / "exhibits" / "fleet-01" / "EXPECTED.md"


def test_expected_md_has_host_sections() -> None:
    text = EXPECTED.read_text()
    for host in ("## host-1", "## host-4", "## host-5", "## host-7"):
        assert host in text, f"missing section: {host}"


def test_expected_md_documents_case_split() -> None:
    text = EXPECTED.read_text()
    assert "Case-split scenario" in text or "## Case split" in text
    assert "CASE-2026-0008" in text


def test_expected_md_c2_references_match_exhibits() -> None:
    text = EXPECTED.read_text()
    assert "vagqea4wrlkdg.top" in text
    assert "skimmer-c2.example" in text


def test_expected_md_host1_negative_assertion() -> None:
    text = EXPECTED.read_text()
    h1_start = text.index("## host-1")
    h1_end = text.index("## host-", h1_start + 1) if "## host-" in text[h1_start + 1:] else len(text)
    h1 = text[h1_start:h1_end]
    assert "zero fs" in h1.lower() or "no fs finding" in h1.lower() or "negative" in h1.lower()
