"""Managed Agents session runner — the MVW revise path.

Opens or reuses a fleet-wide session with the blacklight-curator agent,
sends evidence + case state as a user.message, consumes the event stream
until session.status_idle, dispatches agent.custom_tool_use events to
pydantic validation, returns a RevisionResult. Spec §4/§8/§9.

Invoked from orchestrator._revise_via_session() when
BL_USE_MANAGED_SESSION=1 (default). The fallback path is
orchestrator._revise_direct() → case_engine.revise(), selected by the
flag. Rollback is one env var flip.
"""

from __future__ import annotations

import json
import logging
import os
import threading
from datetime import datetime, timezone
from typing import Optional

import anthropic

from curator.case_engine import _stub_result
from curator.case_schema import CaseFile, RevisionResult
from curator.evidence import EvidenceRow

log = logging.getLogger("session_runner")

_SESSION_LOCK = threading.Lock()  # E8: serialize access to the shared session
# E4: on pydantic rejection, send error user.custom_tool_result so the agent can retry within
# the same turn; retry depth is agent-managed (session manages turn depth, not a client counter).
_INSTRUCTION_FOOTER = (
    "\n\nReason about whether the new evidence supports, contradicts, "
    "extends, is unrelated to, or is ambiguous with the current hypothesis. "
    "Then invoke report_case_revision with your structured revision. "
    "The tool is the only valid output path — do not emit the revision "
    "as plain text."
)


class SessionProtocolError(RuntimeError):
    """Raised when the session protocol fails in a way the runner cannot recover.

    Caller (orchestrator) may fall back to _revise_direct() if
    BL_USE_MANAGED_SESSION_FALLBACK=1 (default).
    """


def _client() -> anthropic.Anthropic:
    return anthropic.Anthropic()


def _render_evidence(rows: list[EvidenceRow]) -> list[dict]:
    # Spec §7 — summaries only, no raw_evidence_excerpt
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


def _render_case(case: CaseFile) -> dict:
    return case.model_dump(mode="json")


def _build_user_message(case: CaseFile, rows: list[EvidenceRow]) -> str:
    hosts = sorted({r.host for r in rows})
    report_ids = sorted({r.report_id for r in rows})
    body = (
        f"NEW EVIDENCE for {case.case_id}:\n\n"
        f"```json\n{json.dumps(_render_case(case), indent=2, default=str)}\n```\n\n"
        f"NEW REPORT: hosts={hosts}, report_ids={report_ids}\n\n"
        f"NEW EVIDENCE ROWS (hunter summaries):\n"
        f"```json\n{json.dumps(_render_evidence(rows), indent=2)}\n```"
        f"{_INSTRUCTION_FOOTER}"
    )
    return body


def _get_or_create_session(client: anthropic.Anthropic) -> str:
    """Reuse BL_CURATOR_SESSION_ID if idle, else create a new one."""
    sid = os.environ.get("BL_CURATOR_SESSION_ID")
    if sid:
        try:
            sess = client.beta.sessions.retrieve(sid)
            if sess.status in ("idle", "running"):
                log.info("session reused sid=%s status=%s", sid, sess.status)
                return sid
            log.info("session %s status=%s — opening fresh", sid, sess.status)
        except Exception as exc:  # noqa: BLE001 — API may 404 on deleted/expired
            log.warning("session %s retrieve failed (%s) — opening fresh", sid, exc)

    agent_id = os.environ.get("BL_CURATOR_AGENT_ID")
    env_id = os.environ.get("BL_CURATOR_ENV_ID")
    if not (agent_id and env_id):
        raise SessionProtocolError(
            "BL_CURATOR_AGENT_ID and BL_CURATOR_ENV_ID must be set. "
            "Run `python -m curator.agent_setup --update` first."
        )
    new = client.beta.sessions.create(
        agent=agent_id,
        environment_id=env_id,
        title=f"blacklight investigation {datetime.now(timezone.utc).isoformat()}",
    )
    log.info("session opened sid=%s", new.id)
    # Note: we do not write BL_CURATOR_SESSION_ID back to .secrets/env
    # automatically — operator controls .secrets/env; runner-only session
    # reuse is fine for a single process.
    os.environ["BL_CURATOR_SESSION_ID"] = new.id
    return new.id


def _parse_custom_tool_input(raw: dict) -> RevisionResult:
    """Validate the agent's custom-tool input against RevisionResult.

    Mirrors case_engine.revise's post-hoc normalization: convert
    evidence_thread_additions from array-of-pairs to dict; clamp
    confidences; drop non-ISO proposed_actions.at entries.
    """
    from curator.case_engine import _clamp_confidences

    payload = dict(raw)  # shallow copy

    # array → dict normalization
    raw_threads = payload.get("evidence_thread_additions", [])
    if isinstance(raw_threads, list):
        merged: dict[str, list[str]] = {}
        for item in raw_threads:
            if not isinstance(item, dict) or "host" not in item:
                continue
            bucket = merged.setdefault(item["host"], [])
            seen = set(bucket)
            for eid in item.get("evidence_ids", []):
                if eid not in seen:
                    bucket.append(eid)
                    seen.add(eid)
        payload["evidence_thread_additions"] = merged

    _clamp_confidences(payload)

    raw_actions = payload.get("proposed_actions", [])
    if raw_actions:
        from datetime import datetime as _dt
        valid = []
        for act in raw_actions:
            try:
                _dt.fromisoformat(str(act.get("at", "")).replace("Z", "+00:00"))
                valid.append(act)
            except (ValueError, TypeError):
                log.warning("proposed_action dropped (at invalid): %r", act.get("at"))
        payload["proposed_actions"] = valid

    return RevisionResult.model_validate(payload)


def _run_session_turn(client: anthropic.Anthropic, sid: str, user_text: str) -> RevisionResult:
    """One user.message turn. Returns the validated RevisionResult.

    Raises SessionProtocolError on unrecoverable protocol failure.
    """
    tool_result: Optional[RevisionResult] = None
    agent_text_chunks: list[str] = []
    thinking_events = 0

    with client.beta.sessions.events.stream(session_id=sid) as stream:
        client.beta.sessions.events.send(
            session_id=sid,
            events=[{
                "type": "user.message",
                "content": [{"type": "text", "text": user_text}],
            }],
        )

        for event in stream:
            et = getattr(event, "type", None)
            if et == "agent.thinking":
                thinking_events += 1
            elif et == "agent.message":
                for block in getattr(event, "content", []):
                    if getattr(block, "type", None) == "text":
                        agent_text_chunks.append(block.text)
            elif et == "agent.custom_tool_use":
                if getattr(event, "name", None) == "report_case_revision":
                    try:
                        tool_result = _parse_custom_tool_input(event.input)
                    except Exception as exc:  # noqa: BLE001 — pydantic ValidationError
                        # E4: send error tool_result; agent retries within its turn
                        log.warning("tool payload rejected: %s — sending error result", exc)
                        client.beta.sessions.events.send(
                            session_id=sid,
                            events=[{
                                "type": "user.custom_tool_result",
                                "custom_tool_use_id": event.id,
                                "content": [{"type": "text", "text": f"ERROR: {exc!s}"}],
                                "is_error": True,
                            }],
                        )
                        continue
                    # Success path: ack with empty result; agent will finish turn
                    client.beta.sessions.events.send(
                        session_id=sid,
                        events=[{
                            "type": "user.custom_tool_result",
                            "custom_tool_use_id": event.id,
                            "content": [{"type": "text", "text": "revision accepted"}],
                        }],
                    )
            elif et == "session.status_idle":
                break
            elif et == "session.status_terminated":
                # E2 — invalidate cached session so next call reopens
                os.environ.pop("BL_CURATOR_SESSION_ID", None)
                raise SessionProtocolError(
                    f"session {sid} terminated mid-turn before tool emit"
                )

    log.info("session turn complete thinking_events=%d", thinking_events)
    if thinking_events == 0:
        log.warning("no agent.thinking events — Opus 4.7 auto-think not observed")

    if tool_result is not None:
        return tool_result

    # E3: agent emitted only text. Try to parse JSON from accumulated text.
    joined = "".join(agent_text_chunks).strip()
    if joined:
        for start in (joined.find("{"), 0):
            if start < 0:
                continue
            try:
                candidate = json.loads(joined[start:])
                return _parse_custom_tool_input(candidate)
            except Exception:  # noqa: BLE001
                continue

    raise SessionProtocolError(
        "session idled without report_case_revision invocation and no JSON "
        f"found in {len(joined)} chars of agent text"
    )


def revise_via_session(case: CaseFile, new_rows: list[EvidenceRow]) -> RevisionResult:
    """MVW entry — revise the case hypothesis via a Managed Agents session.

    BL_SKIP_LIVE=1 short-circuits to case_engine._stub_result (parity with
    the direct revise path). All other failure modes raise
    SessionProtocolError; the orchestrator decides whether to fall back.
    """
    if os.environ.get("BL_SKIP_LIVE") == "1":
        log.info("BL_SKIP_LIVE=1 — session_runner returns stub RevisionResult")
        return _stub_result(case, new_rows)

    user_text = _build_user_message(case, new_rows)
    with _SESSION_LOCK:  # E8
        c = _client()
        sid = _get_or_create_session(c)
        return _run_session_turn(c, sid, user_text)
