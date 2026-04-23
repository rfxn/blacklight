"""Shared async Sonnet 4.6 helper + dataclasses for blacklight hunters.

All three hunters use this module to call Sonnet 4.6 with forced tool use.
Extended thinking is explicitly disabled — hunters are pattern-match at
speed, not deep reasoning. That is the Day 3 case engine's job.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from pathlib import Path

import anthropic

from curator.managed_agents import MODEL_HUNTER

log = logging.getLogger(__name__)

TOOL_NAME = "report_findings"


@dataclass(frozen=True)
class HunterInput:
    host: str
    report_id: str
    work_root: Path
    skills: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class Finding:
    category: str
    finding: str
    confidence: float
    source_refs: list[str]
    raw_evidence_excerpt: str
    observed_at: str


@dataclass(frozen=True)
class HunterOutput:
    hunter: str
    findings: list[Finding]


_PROMPT_CACHE: dict[Path, str] = {}


def load_prompt(path: Path) -> str:
    if path in _PROMPT_CACHE:
        return _PROMPT_CACHE[path]
    text = path.read_text(encoding="utf-8")
    head = "\n".join(text.splitlines()[:3]) if text else ""
    if "TODO: operator content" in head:
        raise RuntimeError(
            f"prompt {path} is an operator-content stub — refusing to send to Sonnet"
        )
    _PROMPT_CACHE[path] = text
    return text


def build_tool_schema() -> dict:
    return {
        "name": TOOL_NAME,
        "description": "Report structured findings from this hunter invocation.",
        "input_schema": {
            "type": "object",
            "properties": {
                "findings": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "category": {"type": "string"},
                            "finding": {"type": "string", "maxLength": 200},
                            "confidence": {"type": "number", "minimum": 0.0, "maximum": 1.0},
                            "source_refs": {"type": "array", "items": {"type": "string"}},
                            "raw_evidence_excerpt": {"type": "string", "maxLength": 500},
                            "observed_at": {"type": "string"},
                        },
                        "required": [
                            "category", "finding", "confidence",
                            "source_refs", "raw_evidence_excerpt", "observed_at",
                        ],
                    },
                },
            },
            "required": ["findings"],
        },
    }


def _skip_mode_enabled() -> bool:
    return os.environ.get("BL_SKIP_LIVE") == "1"


def _stub_finding(prompt_path: Path) -> Finding:
    """Minimal synthetic finding for BL_STUB_FINDINGS=1 subprocess paths.

    Gives the orchestrator a non-empty row set so cases open and revise()
    branches execute — required for subprocess-level sim runner tests where
    unittest.mock.patch cannot reach into the child process.
    """
    return Finding(
        category="unusual_php_path",
        finding="stub: synthetic finding for sim-runner rehearsal",
        confidence=0.7,
        source_refs=[f"stub/{prompt_path.stem}"],
        raw_evidence_excerpt="",
        observed_at="2026-04-22T00:00:00Z",
    )


async def run_sonnet_hunter(
    prompt_path: Path,
    user_content: str,
    client: anthropic.AsyncAnthropic | None = None,
) -> list[Finding]:
    """Call Sonnet 4.6 with forced tool use. Returns parsed findings.

    BL_SKIP_LIVE=1 returns an empty findings list without an API call
    (tests + CI path). Callers that need fixture findings in skip mode
    supply them themselves before invoking this helper.

    BL_STUB_FINDINGS=1 (implies BL_SKIP_LIVE=1) returns one synthetic
    finding per hunter — used by subprocess-based sim runner tests where
    patch() cannot reach into the child process.
    """
    if _skip_mode_enabled():
        if os.environ.get("BL_STUB_FINDINGS") == "1":
            log.info("BL_STUB_FINDINGS=1 — returning synthetic finding for %s", prompt_path.name)
            return [_stub_finding(prompt_path)]
        log.info("BL_SKIP_LIVE=1 — skipping live API call for %s", prompt_path.name)
        return []

    c = client or anthropic.AsyncAnthropic()
    schema = build_tool_schema()
    # thinking kwarg deliberately absent — extended thinking off for hunters.
    response = await c.messages.create(
        model=MODEL_HUNTER,
        max_tokens=4096,
        system=load_prompt(prompt_path),
        tools=[schema],
        tool_choice={"type": "tool", "name": TOOL_NAME},
        messages=[{"role": "user", "content": user_content}],
    )
    return _parse_tool_output(response)


_REQUIRED_FIELDS = ("category", "confidence", "observed_at")


def _parse_tool_output(response: anthropic.types.Message) -> list[Finding]:
    for block in response.content:
        if block.type == "tool_use" and block.name == TOOL_NAME:
            raw = block.input.get("findings", [])
            out: list[Finding] = []
            for idx, item in enumerate(raw):
                # Spec 11b #9: malformed item → skip with warning, do not raise
                missing = [k for k in _REQUIRED_FIELDS if k not in item]
                if missing:
                    log.warning("finding #%d missing required fields %s — skipping", idx, missing)
                    continue
                # Spec 11b #12: confidence outside 0..1 → skip with warning
                try:
                    conf = float(item["confidence"])
                except (TypeError, ValueError):
                    log.warning("finding #%d confidence not numeric — skipping", idx)
                    continue
                if not (0.0 <= conf <= 1.0):
                    log.warning("finding #%d confidence %.3f outside [0,1] — skipping", idx, conf)
                    continue
                # Spec 11b #11: finding >200 chars → truncate + warn
                raw_finding = item.get("finding", "")
                if len(raw_finding) > 200:
                    log.warning("finding #%d truncated (was %d chars)", idx, len(raw_finding))
                finding_text = raw_finding[:200]
                excerpt = item.get("raw_evidence_excerpt", "")[:500]
                out.append(Finding(
                    category=item["category"],
                    finding=finding_text,
                    confidence=conf,
                    source_refs=list(item.get("source_refs", [])),
                    raw_evidence_excerpt=excerpt,
                    observed_at=item["observed_at"],
                ))
            return out
    # Spec INFORMATIONAL: no tool_use block → model returned prose; log warning
    log.warning("model response contained no %r tool_use block — 0 findings recorded", TOOL_NAME)
    return []
