"""Managed Agents first-contact wrapper — Agent/Environment/Session creation.

Day 1 scaffolding. Functions import-ready; first live smoke test is an
operator action (see first_contact_smoke_test).
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Iterator, Optional

try:
    import anthropic
except ImportError as exc:  # pragma: no cover
    raise ImportError(
        "anthropic SDK required — pip install anthropic (>=0.96.0). "
        "See requirements.txt."
    ) from exc


# Model identifiers — anchored by CLAUDE.md and HANDOFF §"model choice"
MODEL_CURATOR = "claude-opus-4-7"       # case-file engine, intent reconstructor, synthesizer
MODEL_HUNTER = "claude-sonnet-4-6"      # parallel hunters (fs, log, timeline)


@dataclass(frozen=True)
class SessionHandle:
    """Lightweight reference to a running Managed Agents session.

    The session is the long-running Claude instance that holds case state
    across evidence arrivals. blacklight's curator owns one session per active
    investigation cycle (v1 keeps it simple: a single fleet-wide session).
    """
    session_id: str
    agent_id: str
    environment_id: str


def _client(api_key: Optional[str] = None) -> "anthropic.Anthropic":
    """Construct an Anthropic client. Fails fast if no key configured."""
    key = api_key or os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        raise RuntimeError(
            "ANTHROPIC_API_KEY not set. Required for Managed Agents calls. "
            "Export in shell or pass api_key= explicitly."
        )
    return anthropic.Anthropic(api_key=key)


def create_curator_agent(
    name: str,
    system_prompt: str,
    *,
    model: str = MODEL_CURATOR,
    skills: Optional[list[str]] = None,
    client: Optional["anthropic.Anthropic"] = None,
) -> str:
    """Create the curator Agent. Returns agent_id.

    The curator agent is the outer orchestration loop: receives evidence
    reports, invokes hunters as sub-tasks, reads/writes the case file,
    invokes the intent reconstructor and synthesizer at the right times.
    Extended thinking enabled via the session configuration on creation.

    TODO(operator): verify (a) exact field name for system prompt on
    beta.agents.create (system_prompt vs system vs instructions), (b) how
    skills references are attached (IDs from client.beta.skills.list vs
    inline skill file paths), (c) whether extended thinking is an agent-level
    or session-level toggle. All three confirmable on first live call.
    """
    c = client or _client()
    # SDK surface per introspection: client.beta.agents.create()
    agent = c.beta.agents.create(  # type: ignore[attr-defined]
        name=name,
        model=model,
        # system_prompt + skills shape TBD on first live call — see TODO above.
        system_prompt=system_prompt,  # type: ignore[call-arg]
        skills=skills or [],  # type: ignore[call-arg]
    )
    return agent.id


def create_fleet_environment(
    name: str,
    *,
    client: Optional["anthropic.Anthropic"] = None,
) -> str:
    """Create the Environment template the curator Session runs in. Returns env_id.

    The Environment is a cloud container template with the tools/runtimes
    Claude has access to during the session. For blacklight:
    - bash, file ops, web search/fetch (default)
    - HTTP client to hit the local manifest endpoint + report inbox
    - MCP servers: TBD — sqlite access for evidence.db summaries may ship
      as a dedicated MCP server on Day 2.

    TODO(operator): confirm MCP server registration shape on first live call.
    """
    c = client or _client()
    env = c.beta.environments.create(  # type: ignore[attr-defined]
        name=name,
        # TODO: fill in container_template + mcp_servers once verified live.
    )
    return env.id


def start_session(
    agent_id: str,
    environment_id: str,
    *,
    client: Optional["anthropic.Anthropic"] = None,
) -> SessionHandle:
    """Start a Session pairing an Agent with an Environment. Returns a handle."""
    c = client or _client()
    session = c.beta.sessions.create(  # type: ignore[attr-defined]
        agent_id=agent_id,
        environment_id=environment_id,
    )
    return SessionHandle(
        session_id=session.id,
        agent_id=agent_id,
        environment_id=environment_id,
    )


def stream_events(
    session_id: str,
    *,
    client: Optional["anthropic.Anthropic"] = None,
) -> Iterator[dict]:
    """Yield events from the session's SSE stream as dicts.

    Events shape is TBD until first live call — documented types include
    agent_turn, tool_use, tool_result, thinking, and terminal events.
    The curator's outer loop consumes these to drive local state updates
    (writing case files to disk, pushing manifest versions).
    """
    c = client or _client()
    # TODO(operator): verify iteration pattern — events.list() vs events.stream()
    # vs SSE helper. Current SDK surface exposes client.beta.sessions.events.
    stream = c.beta.sessions.events.list(session_id=session_id)  # type: ignore[attr-defined]
    for event in stream:
        yield event.model_dump() if hasattr(event, "model_dump") else dict(event)


def first_contact_smoke_test() -> SessionHandle:
    """Operator-run smoke test — creates a minimal Agent+Environment+Session.

    Run:
        export ANTHROPIC_API_KEY=sk-...
        python -m curator.managed_agents

    Success = session_id printed, $0.08/hr timer starts, an event consumable.
    Failure mode most likely from field-name drift in the 2-week-old beta;
    map traceback to the TODO markers above and patch the call sites.
    """
    c = _client()
    agent_id = create_curator_agent(
        name="blacklight-curator-smoketest",
        system_prompt=(
            "You are the blacklight curator. For the smoke test only, reply "
            "with a one-sentence acknowledgment and terminate the session."
        ),
        client=c,
    )
    env_id = create_fleet_environment(name="blacklight-fleet-smoketest", client=c)
    handle = start_session(agent_id, env_id, client=c)
    return handle


if __name__ == "__main__":  # pragma: no cover
    h = first_contact_smoke_test()
    print(f"session {h.session_id} on agent {h.agent_id} env {h.environment_id}")
