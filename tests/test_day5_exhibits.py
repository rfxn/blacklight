"""Day-5 exhibit framing discipline + family-divergence checks (P36)."""
from pathlib import Path

EXHIBITS = Path(__file__).parent.parent / "exhibits" / "fleet-01"
FAKE_C2_POLYSHELL = "vagqea4wrlkdg.top"
FAKE_C2_SKIMMER = "skimmer-c2.example"


def test_all_day5_exhibit_files_exist() -> None:
    paths = [
        EXHIBITS / "host-1-anticipatory" / "access.log",
        EXHIBITS / "host-4-polyshell-second" / "a.php",
        EXHIBITS / "host-4-polyshell-second" / "access.log",
        EXHIBITS / "host-5-skimmer" / "skimmer.php",
        EXHIBITS / "host-5-skimmer" / "access.log",
        EXHIBITS / "host-7-polyshell-third" / "a.php",
        EXHIBITS / "host-7-polyshell-third" / "access.log",
    ]
    missing = [p for p in paths if not p.is_file()]
    assert missing == [], f"missing exhibit files: {missing}"


def test_provenance_marker_in_all_files() -> None:
    paths = (
        list((EXHIBITS / "host-1-anticipatory").glob("*"))
        + list((EXHIBITS / "host-4-polyshell-second").glob("*"))
        + list((EXHIBITS / "host-5-skimmer").glob("*"))
        + list((EXHIBITS / "host-7-polyshell-third").glob("*"))
    )
    missing_provenance = []
    for p in paths:
        head = p.read_text(errors="replace")[:600]
        if "staged exhibit" not in head or "NOT customer data" not in head:
            missing_provenance.append(p)
    assert missing_provenance == [], f"missing provenance: {missing_provenance}"


def test_polyshell_family_shares_c2() -> None:
    for host_dir in ("host-4-polyshell-second", "host-7-polyshell-third"):
        access = (EXHIBITS / host_dir / "access.log").read_text()
        assert FAKE_C2_POLYSHELL in access, f"{host_dir} missing PolyShell C2"


def test_skimmer_family_uses_distinct_c2() -> None:
    access = (EXHIBITS / "host-5-skimmer" / "access.log").read_text()
    assert FAKE_C2_SKIMMER in access
    assert FAKE_C2_POLYSHELL not in access, "skimmer must NOT share PolyShell C2"


def test_host1_has_modsec_block_line() -> None:
    access = (EXHIBITS / "host-1-anticipatory" / "access.log").read_text()
    assert " 403 " in access
    assert "ModSec-Block" in access or "id 920099" in access
