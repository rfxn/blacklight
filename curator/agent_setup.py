"""Idempotent Managed Agents bootstrap for the blacklight curator.

Creates (or updates) the curator agent with:
  - system prompt from prompts/curator-agent.md
  - 1 custom tool: report_case_revision (input_schema = RevisionResult)
  - skills: ir-playbook/case-lifecycle, webshell-families/polyshell,
    defense-synthesis/modsec-patterns (3 load-bearing operator files)

Skills must be uploaded to the Anthropic API before agent creation.
Run with --update to upload skills and create/update the agent.
Emits `.secrets/env`-ready export lines for BL_CURATOR_AGENT_ID +
BL_CURATOR_AGENT_VERSION + BL_CURATOR_ENV_ID + BL_SKILL_ID_{NAME}.
Run once before first session; rerun idempotently after any schema/prompt change.

Platform quirks (skills-2025-10-02 beta):
  - agents.create skills field takes {type, skill_id} references only —
    inline content is rejected with 400. Skills must be pre-uploaded via
    beta.skills.create().
  - Skill file upload requires: filename = "{dirname}/SKILL.md",
    content must start with YAML frontmatter (---).
  - The dirname becomes the skill's `name` on the server.
  - additionalProperties in tool input_schema is rejected by agents.create
    (both `false` and object forms); strip before submitting.
"""

from __future__ import annotations

import argparse
import copy
import io
import json
import os
import sys
import textwrap
from pathlib import Path

import anthropic

from curator.case_engine import _build_revision_schema
from curator.case_schema import RevisionResult
from curator.managed_agents import MODEL_CURATOR

AGENT_NAME = "blacklight-curator"
ENV_NAME = "blacklight-fleet"

REPO_ROOT = Path(__file__).resolve().parent.parent
PROMPT_PATH = REPO_ROOT / "prompts" / "curator-agent.md"

REVISION_TOOL_DESCRIPTION = (
    "Emit the structured revision of the current case hypothesis. Call this "
    "tool exactly once per user.message carrying new evidence. Set "
    "revision_warranted=true only if new_hypothesis differs from the current "
    "hypothesis in summary, reasoning, or confidence. Set support_type to one "
    "of 'supports', 'contradicts', 'extends', 'unrelated', 'ambiguous' — pick "
    "'unrelated' when the new evidence does not belong to this case and a "
    "split should be triggered downstream. Confidence values must be in "
    "[0.0, 1.0]. See skills/ir-playbook/case-lifecycle.md for per-value "
    "discipline. Never emit the revision as plain text — this tool is the "
    "only valid output path."
)

# Skills: (path relative to skills/, BL_SKILL_ID_{env_suffix}, display title)
_SKILL_DEFS = [
    ("ir-playbook/case-lifecycle.md", "CASE_LIFECYCLE", "case-lifecycle"),
    ("webshell-families/polyshell.md", "POLYSHELL", "polyshell"),
    ("defense-synthesis/modsec-patterns.md", "MODSEC_PATTERNS", "modsec-patterns"),
]


def _strip_ap_recursive(node: object) -> None:
    """Recursively remove all additionalProperties keys from a schema dict.

    Platform quirk: the Managed Agents beta.agents.create endpoint rejects
    any JSON-schema that carries additionalProperties — both the boolean
    `false` form and the object form cause HTTP 400. This is distinct from
    /v1/messages output_config.format.json_schema, which accepts both forms.
    Verified live 2026-04-22 (session-tool-invocation-probe.py).
    """
    if isinstance(node, dict):
        node.pop("additionalProperties", None)
        for v in node.values():
            _strip_ap_recursive(v)
    elif isinstance(node, list):
        for item in node:
            _strip_ap_recursive(item)


def _strip_additional_properties(schema: dict) -> dict:
    """Return a deep copy of schema with all additionalProperties keys removed."""
    schema = copy.deepcopy(schema)
    _strip_ap_recursive(schema)
    return schema


def build_custom_tool() -> dict:
    # additionalProperties keys stripped — Managed Agents API rejects them
    # (both `false` and object forms cause 400; see _strip_additional_properties).
    return {
        "type": "custom",
        "name": "report_case_revision",
        "description": REVISION_TOOL_DESCRIPTION,
        "input_schema": _strip_additional_properties(_build_revision_schema()),
    }


def schema_roundtrip_probe() -> None:
    """Validate _build_revision_schema() shape + pydantic compatibility.

    Raises ValueError if the schema would be rejected by pydantic or if a
    minimal sample payload matching the schema cannot validate as a
    RevisionResult. This catches drift between schema and model before
    a live agent.create call would silently accept an unusable shape.

    Validates the stripped shape (additionalProperties removed) since that
    is the form actually submitted to the Managed Agents API.
    """
    schema = _strip_additional_properties(_build_revision_schema())
    sample = {
        "support_type": "extends",
        "revision_warranted": False,
        "evidence_thread_additions": [],
        "open_questions_additions": [],
        "proposed_actions": [],
    }
    RevisionResult.model_validate({
        **sample,
        "evidence_thread_additions": {},  # dict-after-normalization
    })
    required = schema.get("required", [])
    missing = [k for k in ("support_type", "revision_warranted") if k not in required]
    if missing:
        raise ValueError(f"schema-roundtrip-probe: required-fields drift {missing}")


def _skill_frontmatter(title: str) -> str:
    """Generate minimal YAML frontmatter for a skill file upload.

    Platform quirk: beta.skills.create requires SKILL.md to start with
    YAML frontmatter (---). Without it the API returns HTTP 400.
    """
    return textwrap.dedent(f"""\
        ---
        title: {title}
        description: {title}
        ---

        """)


def _upload_skill(
    client: anthropic.Anthropic,
    rel: str,
    env_suffix: str,
    display_title: str,
) -> str:
    """Upload a skill file and return the skill_id. Reuses existing if env var set.

    Platform quirk — skills upload:
      filename must be "{dirname}/SKILL.md" (directory prefix required;
      bare "SKILL.md" causes 400 "must be exactly in the top-level folder").
      The dirname becomes the skill's `name` on the server.
    """
    env_key = f"BL_SKILL_ID_{env_suffix}"
    existing_id = os.environ.get(env_key)
    if existing_id:
        return existing_id

    p = REPO_ROOT / "skills" / rel
    if not p.exists():
        raise FileNotFoundError(f"skill file missing: {p}")

    dirname = p.stem  # e.g. "case-lifecycle" from "case-lifecycle.md"
    raw_content = p.read_text(encoding="utf-8")
    full_content = _skill_frontmatter(display_title) + raw_content
    filename = f"{dirname}/SKILL.md"

    result = client.beta.skills.create(
        display_title=display_title,
        files=[(filename, io.BytesIO(full_content.encode("utf-8")))],
        betas=["skills-2025-10-02"],
    )
    return result.id


def _upload_all_skills(client: anthropic.Anthropic) -> list[tuple[str, str, str]]:
    """Upload all skills. Returns list of (env_suffix, skill_id, display_title)."""
    results = []
    for rel, env_suffix, display_title in _SKILL_DEFS:
        skill_id = _upload_skill(client, rel, env_suffix, display_title)
        results.append((env_suffix, skill_id, display_title))
    return results


def _skill_refs(uploaded: list[tuple[str, str, str]]) -> list[dict]:
    """Convert upload results to agents.create skill reference dicts."""
    return [{"type": "custom", "skill_id": skill_id} for _, skill_id, _ in uploaded]


def _load_system() -> str:
    if not PROMPT_PATH.exists():
        raise FileNotFoundError(f"curator-agent system prompt missing at {PROMPT_PATH}")
    return PROMPT_PATH.read_text(encoding="utf-8")


def _agent_params(skill_refs: list[dict] | None = None) -> dict:
    params: dict = {
        "name": AGENT_NAME,
        "model": MODEL_CURATOR,
        "system": _load_system(),
        "tools": [build_custom_tool()],
    }
    if skill_refs:
        params["skills"] = skill_refs
    return params


def _env_params() -> dict:
    return {
        "name": ENV_NAME,
        "config": {"type": "cloud", "networking": {"type": "unrestricted"}},
    }


def create_or_update_agent(
    client: anthropic.Anthropic,
    skill_refs: list[dict] | None = None,
) -> tuple[str, int]:
    """Returns (agent_id, version). Idempotent over re-invocation."""
    params = _agent_params(skill_refs)
    existing_id = os.environ.get("BL_CURATOR_AGENT_ID")
    if existing_id:
        existing = client.beta.agents.retrieve(existing_id)
        updated = client.beta.agents.update(
            existing_id,
            version=existing.version,
            **{k: v for k, v in params.items() if k != "name"},
        )
        return updated.id, updated.version
    created = client.beta.agents.create(**params)
    return created.id, created.version


def create_or_reuse_env(client: anthropic.Anthropic) -> str:
    existing_id = os.environ.get("BL_CURATOR_ENV_ID")
    if existing_id:
        return existing_id
    env = client.beta.environments.create(**_env_params())
    return env.id


def main() -> int:
    p = argparse.ArgumentParser(prog="curator.agent_setup")
    p.add_argument("--dry-run", action="store_true", help="print config, do not call API")
    p.add_argument("--update", action="store_true", help="create-or-update against live API")
    args = p.parse_args()

    schema_roundtrip_probe()
    print("[agent_setup] schema-roundtrip probe PASS", file=sys.stderr)

    if args.dry_run:
        dry_skills = [
            {"type": "custom", "skill_id": f"<BL_SKILL_ID_{env_suffix}>"}
            for _, env_suffix, _ in _SKILL_DEFS
        ]
        print(json.dumps({
            "agent": _agent_params(skill_refs=dry_skills),
            "environment": _env_params(),
            "skills_upload": [
                {"rel": rel, "env_key": f"BL_SKILL_ID_{s}", "display_title": dt}
                for rel, s, dt in _SKILL_DEFS
            ],
        }, indent=2, default=lambda o: str(o)[:80]))
        return 0

    if not args.update:
        print("pass --dry-run to preview, --update to create/update live", file=sys.stderr)
        return 2

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("ANTHROPIC_API_KEY not set", file=sys.stderr)
        return 1

    client = anthropic.Anthropic()
    uploaded = _upload_all_skills(client)
    refs = _skill_refs(uploaded)
    agent_id, agent_version = create_or_update_agent(client, refs)
    env_id = create_or_reuse_env(client)

    print("# Paste into .secrets/env:")
    print(f'export BL_CURATOR_AGENT_ID="{agent_id}"')
    print(f'export BL_CURATOR_AGENT_VERSION="{agent_version}"')
    print(f'export BL_CURATOR_ENV_ID="{env_id}"')
    for env_suffix, skill_id, _ in uploaded:
        print(f'export BL_SKILL_ID_{env_suffix}="{skill_id}"')
    return 0


if __name__ == "__main__":
    sys.exit(main())
