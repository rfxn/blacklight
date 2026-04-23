"""Shared test fixture — mock anthropic.Anthropic().beta.sessions.* surface.

Used by tests that exercise curator/session_runner.py without hitting live
Anthropic API. Builds declarative event sequences consumed by the runner's
`for event in stream` loop.
"""

from __future__ import annotations

from contextlib import contextmanager
from types import SimpleNamespace
from typing import Iterator
from unittest.mock import MagicMock, patch


def _text_block(text: str) -> SimpleNamespace:
    return SimpleNamespace(type="text", text=text)


def agent_message(text: str) -> SimpleNamespace:
    return SimpleNamespace(
        type="agent.message",
        content=[_text_block(text)],
    )


def agent_thinking(summary: str) -> SimpleNamespace:
    return SimpleNamespace(type="agent.thinking", summary=summary)


def custom_tool_use(tool_name: str, payload: dict, tool_use_id: str = "tu-stub-1") -> SimpleNamespace:
    return SimpleNamespace(
        type="agent.custom_tool_use",
        name=tool_name,
        tool_use_id=tool_use_id,
        input=payload,
    )


def session_idle() -> SimpleNamespace:
    return SimpleNamespace(type="session.status_idle")


def session_terminated() -> SimpleNamespace:
    return SimpleNamespace(type="session.status_terminated")


class _MockStreamCtx:
    def __init__(self, events: list):
        self._events = list(events)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def __iter__(self) -> Iterator:
        return iter(self._events)


@contextmanager
def mock_session_run(*, events: list, session_status: str = "idle", agent_id: str = "agent_stub_01", env_id: str = "env_stub_01"):
    """Patch anthropic.Anthropic() + env vars for one session_runner call."""
    client = MagicMock()
    client.beta.sessions.retrieve.return_value = SimpleNamespace(id="sess_stub_01", status=session_status)
    client.beta.sessions.create.return_value = SimpleNamespace(id="sess_stub_01", status="idle")
    client.beta.sessions.events.stream.return_value = _MockStreamCtx(events)
    client.beta.sessions.events.send.return_value = None
    with patch("curator.session_runner._client", return_value=client), \
         patch.dict("os.environ", {
             "BL_CURATOR_AGENT_ID": agent_id,
             "BL_CURATOR_ENV_ID": env_id,
             "BL_CURATOR_SESSION_ID": "sess_stub_01",
         }, clear=False):
        yield client
