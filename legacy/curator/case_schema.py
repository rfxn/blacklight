"""Case-file Pydantic schema — locked 2026-04-21 (Day 1).

The case file is blacklight's central artifact. Hypothesis revision reads and
writes this structure on every evidence arrival. Schema changes after Day 1
require an operator gate (see HANDOFF §"case-file schema").

YAML on disk at curator/storage/cases/CASE-YYYY-NNNN.yaml. The case-file
engine receives instances as tool-use schema for Claude (forced structured
output). Keep field names YAML-native (snake_case) — we do not translate.
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator

CaseStatus = Literal["active", "resolved", "merged", "split"]
DefenseCategory = Literal["reactive", "predictive", "anticipatory"]
SupportType = Literal["supports", "contradicts", "extends", "unrelated", "ambiguous"]


class _Base(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)


class HypothesisCurrent(_Base):
    summary: str
    confidence: float = Field(ge=0.0, le=1.0)
    reasoning: str


class HypothesisHistoryEntry(_Base):
    at: datetime
    confidence: float = Field(ge=0.0, le=1.0)
    summary: str
    trigger: str


class Hypothesis(_Base):
    current: HypothesisCurrent
    history: list[HypothesisHistoryEntry] = Field(default_factory=list)


class ObservedCapability(_Base):
    cap: str
    evidence: list[str] = Field(default_factory=list)
    confidence: float = Field(ge=0.0, le=1.0, default=1.0)


class InferredCapability(_Base):
    cap: str
    basis: str
    confidence: float = Field(ge=0.0, le=1.0)


class LikelyNextAction(_Base):
    action: str
    basis: str
    confidence: float = Field(ge=0.0, le=1.0)
    ranked: int = Field(ge=1)


class CapabilityMap(_Base):
    observed: list[ObservedCapability] = Field(default_factory=list)
    inferred: list[InferredCapability] = Field(default_factory=list)
    likely_next: list[LikelyNextAction] = Field(default_factory=list)


class ActionTaken(_Base):
    at: datetime
    action: str
    defense_id: Optional[str] = None
    category: Optional[DefenseCategory] = None
    reason: str


class CaseFile(_Base):
    case_id: str = Field(pattern=r"^CASE-\d{4}-\d{4}$")
    status: CaseStatus = "active"
    opened_at: datetime
    last_updated_at: datetime
    updated_by: str

    hypothesis: Hypothesis

    evidence_threads: dict[str, list[str]] = Field(default_factory=dict)
    capability_map: CapabilityMap = Field(default_factory=CapabilityMap)

    open_questions: list[str] = Field(default_factory=list)
    actions_taken: list[ActionTaken] = Field(default_factory=list)

    merged_from: list[str] = Field(default_factory=list)
    split_into: list[str] = Field(default_factory=list)

    @field_validator("merged_from", "split_into")
    @classmethod
    def _case_id_format(cls, v: list[str]) -> list[str]:
        import re
        pat = re.compile(r"^CASE-\d{4}-\d{4}$")
        for cid in v:
            if not pat.match(cid):
                raise ValueError(f"invalid case_id in relation list: {cid!r}")
        return v


class RevisionResult(_Base):
    """Structured output of one case-engine revision call (Opus 4.7 + thinking).

    The case-file engine forces this schema via tool-use on every call.
    Fields mirror the HANDOFF §"hypothesis revision" spec verbatim.
    """

    support_type: SupportType
    revision_warranted: bool
    new_hypothesis: Optional[HypothesisCurrent] = None
    evidence_thread_additions: dict[str, list[str]] = Field(default_factory=dict)
    capability_map_updates: Optional[CapabilityMap] = None
    open_questions_additions: list[str] = Field(default_factory=list)
    proposed_actions: list[ActionTaken] = Field(default_factory=list)


def load_case(path: str) -> CaseFile:
    """Parse a CaseFile from YAML on disk."""
    import yaml
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    return CaseFile.model_validate(data)


def dump_case(case: CaseFile, path: str) -> None:
    """Write a CaseFile to YAML on disk. Deterministic field order."""
    import yaml
    data = case.model_dump(mode="json", exclude_none=False)
    with open(path, "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, sort_keys=False, default_flow_style=False)
