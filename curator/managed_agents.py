"""Managed Agents first-contact wrapper — Agent/Environment/Session creation."""

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
    system: str,
    *,
    model: str = MODEL_CURATOR,
    skills: Optional[list[dict]] = None,
    client: Optional["anthropic.Anthropic"] = None,
) -> tuple[str, int]:
    """Create the curator Agent. Returns (agent_id, version).

    The curator is the outer orchestration loop: receives evidence reports,
    invokes hunters, reads/writes the case file, and runs intent + synthesis
    at the right times. Thinking is adaptive and configured per-request in
    the session, not on the agent.

    `skills` accepts the GA reference shape: e.g. {"type": "custom",
    "skill_id": "skill_...", "version": "latest"} or {"type": "anthropic",
    "skill_id": "xlsx"}. Pass None for the first-contact smoke test.
    """
    c = client or _client()
    kwargs: dict = {
        "name": name,
        "model": model,
        "system": system,
        "tools": [{"type": "agent_toolset_20260401"}],
    }
    if skills:
        kwargs["skills"] = skills
    agent = c.beta.agents.create(**kwargs)
    return agent.id, agent.version


def create_fleet_environment(
    name: str,
    *,
    client: Optional["anthropic.Anthropic"] = None,
) -> str:
    """Create the Environment template the curator Session runs in. Returns env_id.

    Cloud container with unrestricted egress — required for Claude to reach
    the local manifest endpoint + future MCP servers. Networking can be
    tightened later via `package_managers_and_custom` + allowed_hosts.
    """
    c = client or _client()
    env = c.beta.environments.create(
        name=name,
        config={
            "type": "cloud",
            "networking": {"type": "unrestricted"},
        },
    )
    return env.id


def start_session(
    agent_id: str,
    environment_id: str,
    *,
    agent_version: Optional[int] = None,
    title: Optional[str] = None,
    client: Optional["anthropic.Anthropic"] = None,
) -> SessionHandle:
    """Start a Session pairing an Agent with an Environment. Returns a handle.

    Pass `agent_version` to pin the session to a specific agent version
    (reproducibility). Omit to use the agent's latest version at create time.
    """
    c = client or _client()
    if agent_version is not None:
        agent_ref: str | dict = {"type": "agent", "id": agent_id, "version": agent_version}
    else:
        agent_ref = agent_id
    kwargs: dict = {
        "agent": agent_ref,
        "environment_id": environment_id,
    }
    if title:
        kwargs["title"] = title
    session = c.beta.sessions.create(**kwargs)
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

    Stream-first: open the stream before sending the kickoff event, or early
    events arrive in one buffered batch. See shared/managed-agents-events.md
    §Steering Patterns for reconnection + dedupe guidance.
    """
    c = client or _client()
    with c.beta.sessions.events.stream(session_id=session_id) as stream:
        for event in stream:
            yield event.model_dump() if hasattr(event, "model_dump") else dict(event)


def first_contact_smoke_test() -> SessionHandle:
    """Smoke test — creates a minimal Agent+Environment+Session.

    Run:
        . .secrets/env && python -m curator.managed_agents

    Success = session_id printed, session transitions idle after one agent
    turn. The agent is reusable — store agent_id and reuse via AGENT_ID env
    var to avoid accumulating throwaways. Env var likewise for environment_id.
    """
    c = _client()

    agent_id = os.environ.get("BL_CURATOR_AGENT_ID")
    agent_version: Optional[int] = None
    if agent_id:
        agent_version_raw = os.environ.get("BL_CURATOR_AGENT_VERSION")
        agent_version = int(agent_version_raw) if agent_version_raw else None
    else:
        agent_id, agent_version = create_curator_agent(
            name="blacklight-curator-smoketest",
            system=(
                "You are the blacklight curator. For the smoke test only, reply "
                "with a one-sentence acknowledgment and terminate the session."
            ),
            client=c,
        )

    env_id = os.environ.get("BL_CURATOR_ENV_ID") or create_fleet_environment(
        name="blacklight-fleet-smoketest",
        client=c,
    )

    handle = start_session(
        agent_id,
        env_id,
        agent_version=agent_version,
        title="blacklight first-contact smoke",
        client=c,
    )
    return handle


if __name__ == "__main__":  # pragma: no cover
    h = first_contact_smoke_test()
    print(f"session {h.session_id} on agent {h.agent_id} env {h.environment_id}")
    print(
        "Persist for reuse:\n"
        f"  export BL_CURATOR_AGENT_ID={h.agent_id}\n"
        f"  export BL_CURATOR_ENV_ID={h.environment_id}"
    )
