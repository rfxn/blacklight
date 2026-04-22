"""ModSec rule synthesizer — Opus 4.7 + apachectl validator (Day 4).

Takes a CapabilityMap + case context, returns a SynthesisResult with ModSec
rules + exceptions + validation test. Every rule is gated through
`apachectl -t` before promotion to manifest.rules[]; failures are demoted to
manifest.suggested_rules[] with captured stderr.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path
from typing import Optional

import anthropic
from pydantic import BaseModel, ConfigDict, Field

from curator.case_engine import _extract_json_text
from curator.case_schema import CapabilityMap, CaseFile
from curator.hunters.base import load_prompt
from curator.managed_agents import MODEL_CURATOR

log = logging.getLogger(__name__)

_PROMPT_PATH = Path(__file__).parent.parent / "prompts" / "synthesizer.md"
_CONFIDENCE_THRESHOLD = 0.7
_APACHECTL_TIMEOUT = 10


class _Base(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Rule(_Base):
    rule_id: str
    body: str
    applies_to: list[str]
    capability_ref: str
    confidence: float = Field(ge=0.0, le=1.0)
    validation_error: Optional[str] = None


class ExceptionEntry(_Base):
    rule_id_ref: str
    path_glob: str
    reason: str


class SynthesisResult(_Base):
    rules: list[Rule] = Field(default_factory=list)
    suggested_rules: list[Rule] = Field(default_factory=list)
    exceptions: list[ExceptionEntry] = Field(default_factory=list)
    validation_test: Optional[str] = None


class SynthesisParseError(RuntimeError):
    """Raised when the Opus 4.7 response cannot be parsed into a SynthesisResult."""


def _build_synthesis_schema() -> dict:
    rule_shape = {
        "type": "object",
        "properties": {
            "rule_id": {"type": "string"},
            "body": {"type": "string"},
            "applies_to": {"type": "array", "items": {"type": "string"}},
            "capability_ref": {"type": "string"},
            "confidence": {"type": "number"},
            "validation_error": {"type": "string"},
        },
        "required": ["rule_id", "body", "applies_to", "capability_ref", "confidence"],
        "additionalProperties": False,
    }
    exc_shape = {
        "type": "object",
        "properties": {
            "rule_id_ref": {"type": "string"},
            "path_glob": {"type": "string"},
            "reason": {"type": "string"},
        },
        "required": ["rule_id_ref", "path_glob", "reason"],
        "additionalProperties": False,
    }
    return {
        "type": "object",
        "properties": {
            "rules": {"type": "array", "items": rule_shape},
            "suggested_rules": {"type": "array", "items": rule_shape},
            "exceptions": {"type": "array", "items": exc_shape},
            "validation_test": {"type": "string"},
        },
        "required": ["rules", "suggested_rules", "exceptions"],
        "additionalProperties": False,
    }


def validate_rule(rule_text: str) -> tuple[bool, str]:
    """Write rule to tempfile, wrap in apache2+mod_security conf, run apachectl -t.

    Returns (passed, stderr). On timeout: returns (False, 'apachectl timeout').
    Requires apachectl + libapache2-mod-security2 on PATH.
    """
    if shutil.which("apachectl") is None:
        return (False, "apachectl not on PATH")

    with tempfile.TemporaryDirectory() as td:
        tdir = Path(td)
        rule_path = tdir / f"rule-{uuid.uuid4().hex[:8]}.conf"
        rule_path.write_text(rule_text)
        wrapper = tdir / "wrapper.conf"
        wrapper.write_text(
            f"""ServerRoot /etc/apache2
Mutex file:/tmp
PidFile /tmp/bl-validate-{uuid.uuid4().hex[:8]}.pid
ErrorLog /dev/null
Listen 127.0.0.1:65535
LoadModule security2_module /usr/lib/apache2/modules/mod_security2.so
LoadModule unique_id_module /usr/lib/apache2/modules/mod_unique_id.so
<IfModule security2_module>
    SecRuleEngine DetectionOnly
    Include {rule_path}
</IfModule>
"""
        )
        try:
            proc = subprocess.run(
                ["apachectl", "-t", "-f", str(wrapper)],
                capture_output=True,
                text=True,
                timeout=_APACHECTL_TIMEOUT,
            )
            return (proc.returncode == 0, proc.stderr or proc.stdout)
        except subprocess.TimeoutExpired:
            return (False, "apachectl timeout")


def _stub_result(_cap_map: CapabilityMap) -> SynthesisResult:
    """BL_SKIP_LIVE path: deterministic stub with 1 suggested_rule."""
    return SynthesisResult(
        rules=[],
        suggested_rules=[
            Rule(
                rule_id="BL-stub-001",
                body="# BL_SKIP_LIVE stub — no real rule synthesized",
                applies_to=["apache"],
                capability_ref="stub",
                confidence=0.0,
                validation_error="BL_SKIP_LIVE stub",
            )
        ],
        exceptions=[],
        validation_test=None,
    )


def _split_by_confidence(result: SynthesisResult, threshold: float = _CONFIDENCE_THRESHOLD) -> SynthesisResult:
    """Move rules below threshold from rules[] to suggested_rules[]."""
    keep = [r for r in result.rules if r.confidence >= threshold]
    demote = [r for r in result.rules if r.confidence < threshold]
    return SynthesisResult(
        rules=keep,
        suggested_rules=[*result.suggested_rules, *demote],
        exceptions=result.exceptions,
        validation_test=result.validation_test,
    )


def _validate_and_partition(result: SynthesisResult) -> SynthesisResult:
    """Run apachectl -t on every rule in rules[]. Demote failures to suggested_rules[]."""
    keep: list[Rule] = []
    demote: list[Rule] = []
    for r in result.rules:
        # Reject non-ASCII bodies early (yaml.safe_dump(..., allow_unicode=False) would raise later)
        try:
            r.body.encode("ascii")
        except UnicodeEncodeError:
            demote.append(r.model_copy(update={"validation_error": "non-ASCII in rule body"}))
            continue
        passed, stderr = validate_rule(r.body)
        if passed:
            keep.append(r)
        else:
            demote.append(r.model_copy(update={"validation_error": stderr[:500]}))
    return SynthesisResult(
        rules=keep,
        suggested_rules=[*result.suggested_rules, *demote],
        exceptions=result.exceptions,
        validation_test=result.validation_test,
    )


def synthesize(
    capability_map: CapabilityMap,
    case_context: CaseFile,
    *,
    client: Optional["anthropic.Anthropic"] = None,
) -> SynthesisResult:
    """Call Opus 4.7 to synthesize rules from a CapabilityMap.

    BL_SKIP_LIVE=1 returns a deterministic stub WITHOUT calling the model.
    apachectl validation still runs on non-stub paths.
    """
    if os.environ.get("BL_SKIP_LIVE") == "1":
        log.info("BL_SKIP_LIVE=1 — returning synthesis stub")
        return _stub_result(capability_map)

    c = client or anthropic.Anthropic()
    schema = _build_synthesis_schema()
    system = load_prompt(_PROMPT_PATH)

    user_content = (
        "CASE CONTEXT:\n"
        f"{json.dumps({'summary': case_context.hypothesis.current.summary, 'confidence': case_context.hypothesis.current.confidence, 'open_questions': case_context.open_questions}, indent=2)}\n\n"
        "CAPABILITY MAP:\n"
        f"{json.dumps(capability_map.model_dump(mode='json'), indent=2)}"
    )

    response = c.messages.create(
        model=MODEL_CURATOR,
        max_tokens=16000,
        thinking={"type": "adaptive", "display": "summarized"},
        output_config={
            "effort": "high",
            "format": {"type": "json_schema", "schema": schema},
        },
        system=system,
        messages=[{"role": "user", "content": user_content}],
    )

    text = _extract_json_text(response)
    try:
        payload = json.loads(text)
        raw = SynthesisResult.model_validate(payload)
    except Exception as exc:
        raise SynthesisParseError(
            f"response failed SynthesisResult validation: {exc!s}\n--- raw text ---\n{text[:400]}"
        ) from exc

    # confidence split first, then apachectl gate
    split = _split_by_confidence(raw)
    return _validate_and_partition(split)
