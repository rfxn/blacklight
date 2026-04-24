"""Managed Agents model-identifier anchors.

Production agent/env/session creation lives in `curator/agent_setup.py` (the
idempotent bootstrap) and `curator/session_runner.py` (the revise-via-session
path). This module now only carries the two model constants that code paths
across curator/ + curator/hunters/ import for parity with the README
"Why these models" block and HANDOFF §model choice.
"""

from __future__ import annotations

# Model identifiers — anchored by CLAUDE.md and HANDOFF §"model choice"
MODEL_CURATOR = "claude-opus-4-7"       # case-file engine, intent reconstructor, synthesizer
MODEL_HUNTER = "claude-sonnet-4-6"      # parallel hunters (fs, log, timeline)
