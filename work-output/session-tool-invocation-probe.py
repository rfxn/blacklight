"""P0 spike — measure custom-tool invocation reliability across 5 live probes.

Gate: >=4/5 direct tool invocations to green-light MVW. <4/5 aborts MVW
before any implementation commits land. See spec §4 M2 pushback.
"""

from __future__ import annotations

import copy
import json
import os
import sys
from pathlib import Path

import anthropic

# Reuse the existing revision schema — MVW lifts this into the custom tool
# input_schema unchanged (spec §8).
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))
from curator.case_engine import _build_revision_schema  # noqa: E402


def _strip_additional_properties(schema: dict) -> dict:
    """Strip additionalProperties keys — Managed Agents API rejects them."""
    schema = copy.deepcopy(schema)
    _strip_ap_recursive(schema)
    return schema


def _strip_ap_recursive(node: object) -> None:
    if isinstance(node, dict):
        node.pop("additionalProperties", None)
        for v in node.values():
            _strip_ap_recursive(v)
    elif isinstance(node, list):
        for item in node:
            _strip_ap_recursive(item)

PROBE_AGENT_NAME = "blacklight-probe-mca-reliability"
PROBE_ENV_NAME = "blacklight-probe-env"

SYSTEM_PROMPT = (
    "You are the blacklight curator, investigating multi-host incidents on a "
    "managed hosting fleet. When new evidence arrives for an existing case, "
    "you reason about whether it supports, contradicts, extends, is unrelated "
    "to, or is ambiguous w.r.t. the prior hypothesis, then emit your revision "
    "through the report_case_revision custom tool. The tool is the ONLY valid "
    "output path for your revision — never emit revisions as plain text."
)

USER_MESSAGE = """NEW EVIDENCE for CASE-2026-0007:

  Current case (excerpt):
    hypothesis.current.summary: "1-host unusual_php_path on host-2"
    hypothesis.current.confidence: 0.4
    hypothesis.current.reasoning: "initial triage — unusual_php_path pattern flagged..."
    evidence_threads: {host-2: [ev-1, ev-2, ev-3]}

  NEW REPORT: host=host-4, report_id=rpt-probe-001

  NEW EVIDENCE ROWS (hunter summaries):
    - {host: host-4, hunter: fs, category: unusual_php_path, finding: "PolyShell-shape at /var/www/html/pub/media/wysiwyg/.system/helper.php", confidence: 0.89}
    - {host: host-4, hunter: log, category: url_evasion, finding: "helper.php/image.png GET rpath_traversal", confidence: 0.82}
    - {host: host-4, hunter: timeline, category: mtime_cluster, finding: "3 files written within 42s matching host-2's TTP", confidence: 0.75}

  Reason about whether this new evidence supports, contradicts, or extends the
  prior hypothesis. Then invoke report_case_revision with your structured
  revision. Do not emit the revision as plain text — the tool is the only
  valid output path."""


def _ensure_agent_env(client: anthropic.Anthropic) -> tuple[str, str]:
    """Create a throwaway agent+env for the probe. Archived after."""
    agent = client.beta.agents.create(
        name=PROBE_AGENT_NAME,
        model="claude-opus-4-7",
        system=SYSTEM_PROMPT,
        tools=[
            {
                "type": "custom",
                "name": "report_case_revision",
                "description": (
                    "Emit the structured revision of the current case hypothesis. "
                    "Call this tool exactly once per user.message carrying new "
                    "evidence. Set revision_warranted=true only if new_hypothesis "
                    "differs from the current. Set support_type to one of "
                    "'supports', 'contradicts', 'extends', 'unrelated', 'ambiguous'. "
                    "Confidence values must be in [0.0, 1.0]."
                ),
                "input_schema": _strip_additional_properties(_build_revision_schema()),
            }
        ],
    )
    env = client.beta.environments.create(
        name=PROBE_ENV_NAME,
        config={"type": "cloud", "networking": {"type": "unrestricted"}},
    )
    return agent.id, env.id


def _one_probe(client: anthropic.Anthropic, agent_id: str, env_id: str, run_num: int) -> bool:
    session = client.beta.sessions.create(agent=agent_id, environment_id=env_id)
    tool_invoked = False
    with client.beta.sessions.events.stream(session_id=session.id) as stream:
        client.beta.sessions.events.send(
            session_id=session.id,
            events=[{
                "type": "user.message",
                "content": [{"type": "text", "text": USER_MESSAGE}],
            }],
        )
        for event in stream:
            et = getattr(event, "type", None)
            if et == "agent.custom_tool_use" and getattr(event, "name", None) == "report_case_revision":
                tool_invoked = True
                print(f"[probe {run_num}/5] tool_invoked=True (support_type={event.input.get('support_type')})")
            elif et == "session.status_idle":
                break
            elif et == "session.status_terminated":
                break
    if not tool_invoked:
        print(f"[probe {run_num}/5] tool_invoked=False")
    try:
        client.beta.sessions.archive(session.id)
    except Exception:  # noqa: BLE001 — cleanup best-effort
        pass
    return tool_invoked


def main() -> int:
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("ANTHROPIC_API_KEY not set", file=sys.stderr)
        return 1
    client = anthropic.Anthropic()
    print("[probe] creating throwaway agent + env...")
    agent_id, env_id = _ensure_agent_env(client)
    print(f"[probe] agent={agent_id} env={env_id}")
    successes = 0
    for i in range(1, 6):
        if _one_probe(client, agent_id, env_id, i):
            successes += 1
    print(f"[probe] rate={successes}/5")
    try:
        client.beta.agents.archive(agent_id)
    except Exception:  # noqa: BLE001
        pass
    if successes >= 4:
        print("[probe] GREEN — proceed with MVW")
        return 0
    print("[probe] ABORT MVW — ship Option 2 (soften README, remove managed-agent claim)")
    return 2


if __name__ == "__main__":
    sys.exit(main())
