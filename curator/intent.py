"""Intent reconstructor — Opus 4.7 + adaptive thinking (Day 4).

Reads a staged webshell or compromise artifact (raw bytes), returns a
CapabilityMap describing observed / inferred / likely_next capabilities.
This is the one curator call that consumes raw artifact content — all
other model calls read evidence summaries (architecture.md:51 boundary).
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Optional

import anthropic

from curator.case_engine import _clamp_confidences, _extract_json_text
from curator.case_schema import (
    CapabilityMap,
    CaseFile,
    ObservedCapability,
)
from curator.hunters.base import load_prompt
from curator.managed_agents import MODEL_CURATOR

log = logging.getLogger(__name__)

_PROMPT_PATH = Path(__file__).parent.parent / "prompts" / "intent.md"

_MAX_ARTIFACT_BYTES = int(os.environ.get("BL_INTENT_MAX_BYTES", "64000"))


class IntentParseError(RuntimeError):
    """Raised when the Opus 4.7 response cannot be parsed into a CapabilityMap."""


def _build_intent_schema() -> dict:
    """Flat JSON schema for output_config.format. Mirrors the CapabilityMap
    sub-schema from curator/case_engine._build_revision_schema:117-126."""
    observed = {
        "type": "object",
        "properties": {
            "cap": {"type": "string"},
            "evidence": {"type": "array", "items": {"type": "string"}},
            "confidence": {"type": "number"},
        },
        "required": ["cap"],
        "additionalProperties": False,
    }
    inferred = {
        "type": "object",
        "properties": {
            "cap": {"type": "string"},
            "basis": {"type": "string"},
            "confidence": {"type": "number"},
        },
        "required": ["cap", "basis", "confidence"],
        "additionalProperties": False,
    }
    likely_next = {
        "type": "object",
        "properties": {
            "action": {"type": "string"},
            "basis": {"type": "string"},
            "confidence": {"type": "number"},
            "ranked": {"type": "integer"},
        },
        "required": ["action", "basis", "confidence", "ranked"],
        "additionalProperties": False,
    }
    return {
        "type": "object",
        "properties": {
            "observed": {"type": "array", "items": observed},
            "inferred": {"type": "array", "items": inferred},
            "likely_next": {"type": "array", "items": likely_next},
        },
        "required": ["observed", "inferred", "likely_next"],
        "additionalProperties": False,
    }


def _read_artifact(path: Path, max_bytes: int = _MAX_ARTIFACT_BYTES) -> str:
    """Read artifact as utf-8 text with 'replace' for non-utf8 bytes. Truncate."""
    raw = path.read_bytes()[:max_bytes]
    return raw.decode("utf-8", errors="replace")


def _render_case_context(case: CaseFile) -> dict:
    """Hypothesis-only projection. NO raw evidence exposure."""
    return {
        "summary": case.hypothesis.current.summary,
        "confidence": case.hypothesis.current.confidence,
        "hosts_seen": sorted(case.evidence_threads.keys()),
        "observed_caps_so_far": [o.cap for o in case.capability_map.observed],
    }


def _stub_result() -> CapabilityMap:
    """BL_SKIP_LIVE=1 path: deterministic null-intent stub."""
    return CapabilityMap(
        observed=[ObservedCapability(cap="rce_via_webshell", evidence=[], confidence=1.0)],
        inferred=[],
        likely_next=[],
    )


def reconstruct(
    artifact_path: Path,
    case_context: CaseFile,
    *,
    client: Optional["anthropic.Anthropic"] = None,
) -> CapabilityMap:
    """Call Opus 4.7 + adaptive thinking to reconstruct capability map from a raw artifact.

    BL_SKIP_LIVE=1 short-circuits to the deterministic stub.
    """
    if os.environ.get("BL_SKIP_LIVE") == "1":
        log.info("BL_SKIP_LIVE=1 — returning intent stub for %s", artifact_path.name)
        return _stub_result()

    c = client or anthropic.Anthropic()
    schema = _build_intent_schema()
    system = load_prompt(_PROMPT_PATH)

    artifact_text = _read_artifact(artifact_path)
    user_content = (
        "CASE CONTEXT (hypothesis-only projection):\n"
        f"{json.dumps(_render_case_context(case_context), indent=2, default=str)}\n\n"
        f"RAW ARTIFACT ({artifact_path}, {len(artifact_text)} chars after utf-8 decode):\n"
        f"{artifact_text}"
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

    text: str = ""
    try:
        text = _extract_json_text(response)
        payload = json.loads(text)
        _clamp_confidences({"new_hypothesis": None, "capability_map_updates": payload})
        return CapabilityMap.model_validate(payload)
    except Exception as exc:
        raise IntentParseError(
            f"response failed CapabilityMap validation: {exc!s}\n--- raw text ---\n{text[:400]}"
        ) from exc
