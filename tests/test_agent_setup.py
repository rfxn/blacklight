"""Unit tests for curator/agent_setup.py (schema probe + idempotence)."""

from __future__ import annotations

import os
from unittest.mock import MagicMock, patch

import pytest

from curator.agent_setup import (
    _strip_additional_properties,
    build_custom_tool,
    create_or_update_agent,
    schema_roundtrip_probe,
)
from curator.case_schema import RevisionResult


def test_schema_roundtrip_probe_passes_on_current_schema() -> None:
    # Should not raise on the currently-shipped _build_revision_schema
    schema_roundtrip_probe()


def test_build_custom_tool_has_required_shape() -> None:
    t = build_custom_tool()
    assert t["type"] == "custom"
    assert t["name"] == "report_case_revision"
    assert "input_schema" in t
    assert t["input_schema"]["type"] == "object"
    assert "support_type" in t["input_schema"]["required"]


def test_custom_tool_input_schema_lifts_unchanged() -> None:
    # The tool's input_schema is the stripped form of _build_revision_schema().
    # additionalProperties keys are removed before submission to the Managed
    # Agents API (beta.agents.create rejects them — HTTP 400, both `false` and
    # object forms; distinct from /v1/messages output_config.format.json_schema
    # which accepts them). See _strip_additional_properties() for the invariant.
    from curator.case_engine import _build_revision_schema
    t = build_custom_tool()
    expected = _strip_additional_properties(_build_revision_schema())
    assert t["input_schema"] == expected
    # Confirm additionalProperties is absent from all nested nodes
    import json
    serialized = json.dumps(t["input_schema"])
    assert "additionalProperties" not in serialized


def test_create_or_update_agent_creates_when_no_env_var(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("BL_CURATOR_AGENT_ID", raising=False)
    client = MagicMock()
    client.beta.agents.create.return_value = MagicMock(id="agent_test_new", version=1)
    agent_id, version = create_or_update_agent(client)
    assert agent_id == "agent_test_new"
    assert version == 1
    client.beta.agents.create.assert_called_once()
    client.beta.agents.update.assert_not_called()


def test_create_or_update_agent_updates_when_env_var_set(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("BL_CURATOR_AGENT_ID", "agent_preexisting_01")
    client = MagicMock()
    client.beta.agents.retrieve.return_value = MagicMock(version=3)
    client.beta.agents.update.return_value = MagicMock(id="agent_preexisting_01", version=4)
    agent_id, version = create_or_update_agent(client)
    assert agent_id == "agent_preexisting_01"
    assert version == 4
    client.beta.agents.update.assert_called_once()
    client.beta.agents.create.assert_not_called()


def test_schema_roundtrip_probe_catches_drift(monkeypatch: pytest.MonkeyPatch) -> None:
    """Regression: malformed schema must be rejected at create time."""
    from curator import agent_setup
    monkeypatch.setattr(agent_setup, "_build_revision_schema", lambda: {"type": "object"})  # missing required[]
    with pytest.raises(ValueError, match="required-fields drift"):
        agent_setup.schema_roundtrip_probe()
