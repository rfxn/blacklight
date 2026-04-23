"""Hypothesis-revision engine — Opus 4.7 + adaptive thinking (Day 3 load-bearing).

Given a prior case file and a batch of new evidence rows, the engine asks
Opus 4.7 whether the new evidence supports, contradicts, extends, is
unrelated to, or is ambiguous w.r.t. the prior hypothesis, and returns a
structured RevisionResult matching curator.case_schema. Apply-path is in
apply_revision().
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

import anthropic

from curator.case_schema import (
    CaseFile,
    CapabilityMap,
    Hypothesis,
    HypothesisCurrent,
    HypothesisHistoryEntry,
    RevisionResult,
)
from curator.evidence import EvidenceRow
from curator.hunters.base import load_prompt
from curator.managed_agents import MODEL_CURATOR

log = logging.getLogger(__name__)

_PROMPT_PATH = Path(__file__).parent.parent / "prompts" / "case-engine.md"
_SKILL_PATH = Path(__file__).parent.parent / "skills" / "ir-playbook" / "case-lifecycle.md"


class RevisionParseError(RuntimeError):
    """Raised when the Opus 4.7 response cannot be parsed into a RevisionResult."""


def _render_evidence_summaries(rows: list[EvidenceRow]) -> list[dict]:
    """Project EvidenceRow -> engine-view dict. raw_evidence_excerpt EXCLUDED.

    Per CLAUDE.md §Pre-committed-mitigations: engine reads summaries, not
    raw log lines.
    """
    return [
        {
            "id": r.id,
            "host": r.host,
            "hunter": r.hunter,
            "category": r.category,
            "finding": r.finding,
            "confidence": r.confidence,
            "source_refs": r.source_refs,
            "observed_at": r.observed_at,
        }
        for r in rows
    ]


def _render_case_for_engine(case: CaseFile) -> dict:
    """Project CaseFile -> JSON-safe dict for the user message."""
    return case.model_dump(mode="json")


def _build_revision_schema() -> dict:
    """Flat JSON schema for output_config.format.json_schema.

    Derived by hand from curator.case_schema.RevisionResult so we inline
    the definitions (Anthropic's output_config.format.json_schema expects
    a flat schema in practice — matches the probe shape).
    """
    hypothesis_current = {
        "type": "object",
        "properties": {
            "summary": {"type": "string"},
            "confidence": {"type": "number"},
            "reasoning": {"type": "string"},
        },
        "required": ["summary", "confidence", "reasoning"],
        "additionalProperties": False,
    }
    observed_capability = {
        "type": "object",
        "properties": {
            "cap": {"type": "string"},
            "evidence": {"type": "array", "items": {"type": "string"}},
            "confidence": {"type": "number"},
        },
        "required": ["cap"],
        "additionalProperties": False,
    }
    inferred_capability = {
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
    capability_map = {
        "type": "object",
        "properties": {
            "observed": {"type": "array", "items": observed_capability},
            "inferred": {"type": "array", "items": inferred_capability},
            "likely_next": {"type": "array", "items": likely_next},
        },
        "required": [],
        "additionalProperties": False,
    }
    action_taken = {
        "type": "object",
        "properties": {
            "at": {"type": "string"},
            "action": {"type": "string"},
            "defense_id": {"type": "string"},
            "category": {"type": "string", "enum": ["reactive", "predictive", "anticipatory"]},
            "reason": {"type": "string"},
        },
        "required": ["at", "action", "reason"],
        "additionalProperties": False,
    }
    return {
        "type": "object",
        "properties": {
            "support_type": {
                "type": "string",
                "enum": ["supports", "contradicts", "extends", "unrelated", "ambiguous"],
            },
            "revision_warranted": {"type": "boolean"},
            "new_hypothesis": hypothesis_current,  # omitted when not warranted
            "evidence_thread_additions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "host": {"type": "string"},
                        "evidence_ids": {"type": "array", "items": {"type": "string"}},
                    },
                    "required": ["host", "evidence_ids"],
                    "additionalProperties": False,
                },
            },
            "capability_map_updates": capability_map,  # omitted when no cap updates
            "open_questions_additions": {"type": "array", "items": {"type": "string"}},
            "proposed_actions": {"type": "array", "items": action_taken},
        },
        "required": [
            "support_type",
            "revision_warranted",
            "evidence_thread_additions",
            "open_questions_additions",
            "proposed_actions",
        ],
        "additionalProperties": False,
    }


def _load_system_prompt() -> str:
    """Return the case-engine system prompt with the skill file appended.

    The skill file (`skills/ir-playbook/case-lifecycle.md`) is operator-
    content; it may be a stub until the operator lands real content.
    We read it with open() (not load_prompt) so the stub-check does not
    refuse — load_prompt applies only to agent system prompts.
    """
    prompt = load_prompt(_PROMPT_PATH)
    try:
        skill = _SKILL_PATH.read_text(encoding="utf-8")
    except FileNotFoundError:
        skill = ""
    if skill:
        return f"{prompt}\n\n---\n\n## ir-playbook/case-lifecycle.md (loaded on every call)\n\n{skill}"
    return prompt


def _stub_result(
    case: "CaseFile | None" = None,
    new_rows: "list[EvidenceRow] | None" = None,
) -> RevisionResult:
    """BL_SKIP_LIVE=1 path: return a deterministic RevisionResult.

    BL_STUB_UNRELATED_HOST=<host_id> triggers support_type="unrelated" when
    all new_rows come from that specific host — required for subprocess-based
    sim runner rehearsal where the Day-14 host-5 skimmer beat must exercise
    the split branch without a model call.
    """
    unrelated_host = os.environ.get("BL_STUB_UNRELATED_HOST", "")
    if unrelated_host and case is not None and new_rows:
        new_hosts = {r.host for r in new_rows}
        if new_hosts == {unrelated_host}:
            log.info(
                "BL_SKIP_LIVE=1 stub: host %s matches BL_STUB_UNRELATED_HOST — returning unrelated",
                unrelated_host,
            )
            return RevisionResult(
                support_type="unrelated",
                revision_warranted=False,
                new_hypothesis=None,
                evidence_thread_additions={},
                capability_map_updates=None,
                open_questions_additions=[
                    f"support_type=unrelated (stub: {unrelated_host} designated unrelated).",
                ],
                proposed_actions=[],
            )
    return RevisionResult(
        support_type="ambiguous",
        revision_warranted=False,
        new_hypothesis=None,
        evidence_thread_additions={},
        capability_map_updates=None,
        open_questions_additions=[
            "no revision proposed (model call skipped in this run).",
        ],
        proposed_actions=[],
    )


def _clamp_confidences(payload: dict) -> None:
    """Clamp every confidence field in a raw revision payload to [0.0, 1.0].

    The output_config.format live-beta schema cannot carry minimum/maximum
    (commit 36863d6), but curator.case_schema still enforces ge=0.0/le=1.0
    via pydantic — a 1.2 from the model would raise before we see it. Walk
    the known confidence paths and clamp in place, logging WARN on any fire.
    Paths tracked: new_hypothesis.confidence + every entry in
    capability_map_updates.{observed,inferred,likely_next}[*].confidence.
    """
    def _clamp(container: dict, key: str, where: str) -> None:
        v = container.get(key)
        if not isinstance(v, (int, float)):
            return
        if v < 0.0 or v > 1.0:
            clamped = max(0.0, min(1.0, float(v)))
            log.warning("clamp confidence at %s: %r -> %r", where, v, clamped)
            container[key] = clamped

    new_hyp = payload.get("new_hypothesis")
    if isinstance(new_hyp, dict):
        _clamp(new_hyp, "confidence", "new_hypothesis")

    cap_updates = payload.get("capability_map_updates")
    if isinstance(cap_updates, dict):
        for bucket in ("observed", "inferred", "likely_next"):
            entries = cap_updates.get(bucket)
            if not isinstance(entries, list):
                continue
            for idx, entry in enumerate(entries):
                if isinstance(entry, dict):
                    _clamp(entry, "confidence", f"capability_map_updates.{bucket}[{idx}]")


def _extract_json_text(response: "anthropic.types.Message") -> str:
    """Pull the first text block that parses as JSON. Raise otherwise."""
    candidates: list[str] = []
    for block in response.content:
        if getattr(block, "type", None) == "text":
            candidates.append(block.text)
    for txt in candidates:
        try:
            json.loads(txt)
            return txt
        except json.JSONDecodeError:
            continue
    raise RevisionParseError(
        f"no text block in response parsed as JSON (stop_reason={response.stop_reason}, "
        f"text_blocks={len(candidates)})"
    )


def revise(
    case: CaseFile,
    new_rows: list[EvidenceRow],
    *,
    client: Optional["anthropic.Anthropic"] = None,
) -> RevisionResult:
    """Call Opus 4.7 + adaptive thinking to revise the case hypothesis.

    BL_SKIP_LIVE=1 short-circuits to a deterministic null-revision stub.
    """
    if os.environ.get("BL_SKIP_LIVE") == "1":
        log.info("BL_SKIP_LIVE=1 — returning null-revision stub")
        return _stub_result(case, new_rows)

    c = client or anthropic.Anthropic()
    schema = _build_revision_schema()
    system = _load_system_prompt()

    user_content = (
        "CURRENT CASE FILE:\n"
        f"{json.dumps(_render_case_for_engine(case), indent=2, default=str)}\n\n"
        "NEW EVIDENCE BATCH (summaries; no raw_evidence_excerpt exposure):\n"
        f"{json.dumps(_render_evidence_summaries(new_rows), indent=2)}"
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
        # Convert evidence_thread_additions from array-of-pairs to dict
        # (API json_schema can't express dict[str, list[str]] — we use an array
        # shape in the schema and normalize here before pydantic validation).
        # Duplicate host keys must merge (not overwrite) — the model may emit
        # host-by-host rather than one entry per host.
        raw_threads = payload.get("evidence_thread_additions", [])
        if isinstance(raw_threads, list):
            merged_threads: dict[str, list[str]] = {}
            for item in raw_threads:
                if not isinstance(item, dict) or "host" not in item:
                    continue
                bucket = merged_threads.setdefault(item["host"], [])
                seen = set(bucket)
                for eid in item.get("evidence_ids", []):
                    if eid not in seen:
                        bucket.append(eid)
                        seen.add(eid)
            payload["evidence_thread_additions"] = merged_threads
        # Clamp out-of-range confidences — schema dropped min/max bounds
        # for the live-beta (36863d6), but pydantic still enforces ge/le.
        _clamp_confidences(payload)
        # Drop proposed_actions items with non-datetime 'at' fields —
        # the model occasionally puts host names or plain text in 'at'
        # rather than an ISO timestamp, causing pydantic datetime parse failures.
        raw_actions = payload.get("proposed_actions", [])
        if raw_actions:
            from datetime import datetime as _dt
            valid_actions = []
            for act in raw_actions:
                try:
                    _dt.fromisoformat(str(act.get("at", "")).replace("Z", "+00:00"))
                    valid_actions.append(act)
                except (ValueError, TypeError):
                    log.warning(
                        "proposed_action dropped: 'at' field not a valid datetime: %r",
                        act.get("at"),
                    )
            payload["proposed_actions"] = valid_actions
        return RevisionResult.model_validate(payload)
    except Exception as exc:  # pydantic ValidationError or JSONDecodeError
        raise RevisionParseError(
            f"response failed RevisionResult validation: {exc!s}\n--- raw text ---\n{text[:400]}"
        ) from exc


# Not idempotent: caller guarantees one invocation per distinct RevisionResult.
# Repeat calls append to hypothesis.history / open_questions / actions_taken each time.
def apply_revision(
    case: CaseFile,
    result: RevisionResult,
    *,
    trigger: str,
    updated_by: str = "case_engine",
    clock: Optional[Callable[[], datetime]] = None,
) -> CaseFile:
    """Apply a RevisionResult to a CaseFile, returning a new CaseFile.

    Does NOT mutate `case` in place. `trigger` is recorded on the history
    entry that was the PRIOR current-hypothesis (i.e. the one being moved
    into history by this call).
    """
    if result.revision_warranted and result.new_hypothesis is None:
        raise ValueError("revision_warranted=True requires new_hypothesis")

    now = (clock or (lambda: datetime.now(timezone.utc)))()

    updated = case.model_copy(deep=True)
    updated.last_updated_at = now
    updated.updated_by = updated_by

    # 1. Hypothesis history + current swap
    if result.revision_warranted and result.new_hypothesis is not None:
        prior_entry = HypothesisHistoryEntry(
            at=now,
            confidence=case.hypothesis.current.confidence,
            summary=case.hypothesis.current.summary,
            trigger=trigger,
        )
        updated.hypothesis = Hypothesis(
            current=result.new_hypothesis,
            history=[*case.hypothesis.history, prior_entry],
        )

    # 2. Evidence-thread merge (dedupe while preserving order)
    if result.evidence_thread_additions:
        merged_threads = dict(updated.evidence_threads)
        for host, new_ids in result.evidence_thread_additions.items():
            existing = merged_threads.get(host, [])
            seen = set(existing)
            for eid in new_ids:
                if eid not in seen:
                    existing = [*existing, eid]
                    seen.add(eid)
            merged_threads[host] = existing
        updated.evidence_threads = merged_threads

    # 3. Capability-map merge (dedupe cap string; extend evidence list)
    if result.capability_map_updates is not None:
        updated.capability_map = _merge_capability_maps(
            updated.capability_map, result.capability_map_updates,
        )

    # 4. Open questions extend
    if result.open_questions_additions:
        updated.open_questions = [
            *updated.open_questions,
            *result.open_questions_additions,
        ]

    # 5. Actions taken: proposed -> taken. at is the model's own timestamp.
    if result.proposed_actions:
        updated.actions_taken = [*updated.actions_taken, *result.proposed_actions]

    return updated


def _merge_capability_maps(base: CapabilityMap, update: CapabilityMap) -> CapabilityMap:
    """Merge two CapabilityMaps. Dedupe observed/inferred by `cap` string;
    extend evidence lists with dedupe. likely_next is replaced if non-empty
    (ranked list — no sensible merge)."""
    # observed
    observed_by_cap = {o.cap: o for o in base.observed}
    for o in update.observed:
        if o.cap in observed_by_cap:
            existing = observed_by_cap[o.cap]
            seen = set(existing.evidence)
            merged_ev = list(existing.evidence)
            for eid in o.evidence:
                if eid not in seen:
                    merged_ev.append(eid)
                    seen.add(eid)
            observed_by_cap[o.cap] = existing.model_copy(update={"evidence": merged_ev})
        else:
            observed_by_cap[o.cap] = o

    # inferred
    inferred_by_cap = {i.cap: i for i in base.inferred}
    for i in update.inferred:
        existing = inferred_by_cap.get(i.cap)
        if existing is None or i.confidence > existing.confidence:
            # keep higher-confidence update only — never downgrade silently
            inferred_by_cap[i.cap] = i

    # likely_next
    new_likely_next = update.likely_next if update.likely_next else base.likely_next

    return CapabilityMap(
        observed=list(observed_by_cap.values()),
        inferred=list(inferred_by_cap.values()),
        likely_next=new_likely_next,
    )


def split_case(
    prior_case: CaseFile,
    new_rows: list[EvidenceRow],
    *,
    host: str,
    new_case_id: str,
    updated_by: str = "case_engine.split",
    clock: Optional[Callable[[], datetime]] = None,
) -> tuple[CaseFile, CaseFile]:
    """Split a prior case into prior+new on unrelated-evidence detection.

    Returns (updated_prior, new_case). Prior case gets `new_case_id` appended
    to `split_into[]`. New case carries `merged_from=[prior_case.case_id]` and
    a deterministic initial hypothesis (no model call).
    """
    if new_case_id == prior_case.case_id:
        raise ValueError(
            f"split_case: new_case_id must differ from prior ({new_case_id!r})"
        )
    now = (clock or (lambda: datetime.now(timezone.utc)))()

    updated_prior = prior_case.model_copy(deep=True)
    updated_prior.last_updated_at = now
    updated_prior.updated_by = updated_by
    updated_prior.split_into = [*prior_case.split_into, new_case_id]

    summary = (
        f"Split-off from {prior_case.case_id}: separate actor on {host}; "
        f"family markers do not match prior hypothesis."
    )
    reasoning = (
        f"Routed via case_engine.split_case after revise() returned support_type=unrelated. "
        f"{len(new_rows)} new evidence rows from {host} form the seed for {new_case_id}."
    )
    new_case = CaseFile(
        case_id=new_case_id,
        status="active",
        opened_at=now,
        last_updated_at=now,
        updated_by=updated_by,
        hypothesis=Hypothesis(current=HypothesisCurrent(
            summary=summary,
            confidence=0.4,
            reasoning=reasoning,
        )),
        evidence_threads={host: [r.id for r in new_rows]},
        merged_from=[prior_case.case_id],
    )
    return updated_prior, new_case


def merge_capability_map(
    case: CaseFile,
    cap_map: CapabilityMap,
    *,
    updated_by: str = "intent_reconstructor",
    clock: Optional[Callable[[], datetime]] = None,
) -> CaseFile:
    """Merge a CapabilityMap into a case's capability_map. Returns a new CaseFile.

    Intended caller: intent reconstructor path (orchestrator P25). Does NOT
    mutate hypothesis, evidence_threads, open_questions, or actions_taken —
    those are revise()'s domain.
    """
    now = (clock or (lambda: datetime.now(timezone.utc)))()
    updated = case.model_copy(deep=True)
    updated.last_updated_at = now
    updated.updated_by = updated_by
    updated.capability_map = _merge_capability_maps(updated.capability_map, cap_map)
    return updated
