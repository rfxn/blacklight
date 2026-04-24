"""Tests for curator/synthesizer.py — stub + mocked Opus + apachectl gate."""

from __future__ import annotations

import json
import shutil
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
import yaml

from curator.case_schema import CapabilityMap, CaseFile, Hypothesis, HypothesisCurrent
from curator.synthesizer import (
    Rule,
    SynthesisResult,
    _check_banned_actions,
    _split_by_confidence,
    _validate_and_partition,
    synthesize,
    validate_rule,
)

def _apachectl_supports_f() -> bool:
    """Return True only when apachectl accepts -t -f <file> (curator container or full apache2 install).

    Systemd-restricted apachectl wrappers on the host reject -f and print an error —
    those must be skipped to keep the test suite green outside the curator container.
    """
    if shutil.which("apachectl") is None:
        return False
    import subprocess as _sp
    result = _sp.run(
        ["apachectl", "-t", "-f", "/dev/null"],
        capture_output=True,
        text=True,
        timeout=5,
    )
    # A fully-functional apachectl will fail on /dev/null syntax, but with a
    # ModSec/httpd parse error — NOT with the systemd rejection message.
    # Note: this apachectl variant writes the rejection to stdout, not stderr.
    combined = result.stdout + result.stderr
    return "no longer supported" not in combined


_HAS_APACHECTL = _apachectl_supports_f()
_REQUIRES_APACHECTL = pytest.mark.skipif(
    not _HAS_APACHECTL,
    reason="requires apachectl with -f support — run inside curator container or install libapache2-mod-security2 locally",
)


def _fake_case() -> CaseFile:
    now = datetime.now(timezone.utc)
    return CaseFile(
        case_id="CASE-2026-0007",
        status="active",
        opened_at=now,
        last_updated_at=now,
        updated_by="test",
        hypothesis=Hypothesis(current=HypothesisCurrent(summary="PolyShell", confidence=0.6, reasoning="test")),
    )


def _fake_cap_map() -> CapabilityMap:
    data = yaml.safe_load(Path("tests/fixtures/capability_maps/observed_rce_c2.yaml").read_text())
    return CapabilityMap.model_validate(data)


def _text_block(t: str) -> SimpleNamespace:
    return SimpleNamespace(type="text", text=t)


def _mock_response(payload: dict) -> MagicMock:
    r = MagicMock()
    r.content = [_text_block(json.dumps(payload))]
    r.stop_reason = "end_turn"
    return r


def test_synthesize_stub_returns_valid_result(monkeypatch):
    monkeypatch.setenv("BL_SKIP_LIVE", "1")
    result = synthesize(_fake_cap_map(), _fake_case())
    assert len(result.rules) == 0
    assert len(result.suggested_rules) == 1
    assert result.suggested_rules[0].validation_error == "BL_SKIP_LIVE stub"


def _mock_payload(rules, suggested=None, exceptions=None, test="GET /x HTTP/1.1"):
    return {
        "rules": rules,
        "suggested_rules": suggested or [],
        "exceptions": exceptions or [],
        "validation_test": test,
    }


def _valid_rule_body(id_: int = 900001, path: str = "test") -> str:
    return f'SecRule REQUEST_URI "@rx {path}" "id:{id_},phase:2,deny,status:403,msg:\'test\'"'


def test_synthesize_mocked_returns_3_rules(monkeypatch):
    monkeypatch.delenv("BL_SKIP_LIVE", raising=False)
    rules = [
        {"rule_id": f"BL-cap-{i:03d}", "body": _valid_rule_body(900000 + i), "applies_to": ["apache", "apache-modsec"], "capability_ref": f"cap_{i}", "confidence": 0.85}
        for i in range(1, 4)
    ]
    mock = MagicMock()
    mock.messages.create.return_value = _mock_response(_mock_payload(rules))
    # patch apachectl gate to PASS for this test (decouples from env)
    import curator.synthesizer as synth_mod
    monkeypatch.setattr(synth_mod, "_validate_and_partition", lambda r: r)
    result = synthesize(_fake_cap_map(), _fake_case(), client=mock)
    assert len(result.rules) == 3


def test_synthesize_high_conf_stays_in_rules():
    res = SynthesisResult(
        rules=[Rule(rule_id="BL-a-001", body=_valid_rule_body(), applies_to=["apache"], capability_ref="x", confidence=0.85)],
        suggested_rules=[],
        exceptions=[],
    )
    split = _split_by_confidence(res, threshold=0.7)
    assert len(split.rules) == 1
    assert len(split.suggested_rules) == 0


def test_synthesize_low_conf_moves_to_suggested():
    res = SynthesisResult(
        rules=[Rule(rule_id="BL-a-001", body=_valid_rule_body(), applies_to=["apache"], capability_ref="x", confidence=0.4)],
        suggested_rules=[],
        exceptions=[],
    )
    split = _split_by_confidence(res, threshold=0.7)
    assert len(split.rules) == 0
    assert len(split.suggested_rules) == 1


@_REQUIRES_APACHECTL
def test_validate_rule_passing():
    body = Path("tests/fixtures/apachectl_pass.conf").read_text()
    passed, _ = validate_rule(body)
    assert passed is True


@_REQUIRES_APACHECTL
def test_validate_rule_failing():
    body = Path("tests/fixtures/apachectl_fail.conf").read_text()
    passed, stderr = validate_rule(body)
    assert passed is False
    assert stderr  # non-empty


def test_check_banned_actions_flags_engine_toggle():
    body = 'SecRule REQUEST_URI "@beginsWith /ok" "id:900001,phase:1,pass,ctl:ruleEngine=Off"'
    assert _check_banned_actions(body) == "ctl:ruleEngine toggle"


def test_check_banned_actions_flags_detectiononly():
    body = 'SecRule REQUEST_URI "@beginsWith /ok" "id:900002,phase:1,pass,ctl:ruleEngine=DetectionOnly"'
    assert _check_banned_actions(body) == "ctl:ruleEngine toggle"


def test_check_banned_actions_flags_removebytag():
    body = "SecRuleRemoveByTag attack-url-evasion"
    assert _check_banned_actions(body) == "SecRuleRemoveByTag"


def test_check_banned_actions_flags_unscoped_removebyid():
    body = "SecRuleRemoveById 900100"
    assert _check_banned_actions(body) == "SecRuleRemoveById without path scope"


def test_check_banned_actions_allows_scoped_removebyid():
    body = '<LocationMatch "^/vendor/legit/">\n    SecRuleRemoveById 900100\n</LocationMatch>'
    assert _check_banned_actions(body) is None


def test_check_banned_actions_allows_clean_rule():
    body = 'SecRule REQUEST_URI "@beginsWith /admin" "id:900003,phase:1,deny,status:403,log,msg:\'blacklight: admin\',tag:\'blacklight/admin\'"'
    assert _check_banned_actions(body) is None


def test_validate_and_partition_demotes_banned_action():
    banned = Rule(
        rule_id="BL-banned-001",
        body='SecRule REQUEST_URI "@beginsWith /x" "id:900004,phase:1,pass,ctl:ruleEngine=Off"',
        applies_to=["apache"],
        capability_ref="x",
        confidence=0.95,
    )
    res = SynthesisResult(rules=[banned], suggested_rules=[], exceptions=[])
    partitioned = _validate_and_partition(res)
    assert partitioned.rules == []
    assert len(partitioned.suggested_rules) == 1
    demoted = partitioned.suggested_rules[0]
    assert demoted.rule_id == "BL-banned-001"
    assert demoted.validation_error is not None
    assert "banned action shape" in demoted.validation_error
    assert "ctl:ruleEngine" in demoted.validation_error


@_REQUIRES_APACHECTL
def test_validate_and_partition_demotes_failing():
    rules = [
        Rule(rule_id="BL-pass-001", body=Path("tests/fixtures/apachectl_pass.conf").read_text(), applies_to=["apache"], capability_ref="x", confidence=0.85),
        Rule(rule_id="BL-fail-001", body=Path("tests/fixtures/apachectl_fail.conf").read_text(), applies_to=["apache"], capability_ref="y", confidence=0.85),
    ]
    res = SynthesisResult(rules=rules, suggested_rules=[], exceptions=[])
    partitioned = _validate_and_partition(res)
    assert len(partitioned.rules) == 1
    assert partitioned.rules[0].rule_id == "BL-pass-001"
    assert len(partitioned.suggested_rules) == 1
    assert partitioned.suggested_rules[0].rule_id == "BL-fail-001"
    assert partitioned.suggested_rules[0].validation_error  # non-empty


def test_synthesize_rule_id_sequence_deterministic(monkeypatch):
    # Prompt discipline locks rule_id = BL-{capability_ref_kebab}-{seq}; determinism is
    # enforced by the model's rule_id output given the same CapabilityMap input.
    # We can't verify model determinism here; this test asserts that our downstream
    # pipeline is id-pass-through (doesn't remap rule_ids).
    monkeypatch.delenv("BL_SKIP_LIVE", raising=False)
    rules_in = [
        {"rule_id": "BL-rce-via-webshell-001", "body": _valid_rule_body(900001), "applies_to": ["apache"], "capability_ref": "rce_via_webshell", "confidence": 0.85},
    ]
    mock = MagicMock()
    mock.messages.create.return_value = _mock_response(_mock_payload(rules_in))
    import curator.synthesizer as synth_mod
    monkeypatch.setattr(synth_mod, "_validate_and_partition", lambda r: r)
    result = synthesize(_fake_cap_map(), _fake_case(), client=mock)
    assert result.rules[0].rule_id == "BL-rce-via-webshell-001"
