"""Report envelope + tar-safety validation for bl-report payloads.

bl-report writes a manifest.json at the root of the tar describing the
upload. Orchestrator parses this before extracting the archive. Tar safety
validator rejects absolute paths and traversal (`..`) before extraction.
"""

from __future__ import annotations

import json
import os
import tarfile
from datetime import datetime
from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field


class ReportEnvelope(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    report_id: str = Field(pattern=r"^rpt-[a-zA-Z0-9_-]{4,}$")
    host_id: str
    collected_at: datetime
    tool_version: str
    path_map: dict[str, str] = Field(default_factory=dict)


def parse_envelope(work_root: Path) -> ReportEnvelope:
    manifest = work_root / "manifest.json"
    if not manifest.exists():
        raise FileNotFoundError(
            f"malformed envelope — missing manifest.json at {manifest}"
        )
    with manifest.open("r", encoding="utf-8") as f:
        data = json.load(f)
    return ReportEnvelope.model_validate(data)


def validate_tar_safety(tar_path: Path) -> None:
    """Reject tars with entries that escape extraction root.

    Checks: no absolute paths, no `..` traversal, no symlinks pointing
    outside root. Raises ValueError on violation.
    """
    with tarfile.open(tar_path, "r:*") as t:
        for member in t.getmembers():
            name = member.name
            if os.path.isabs(name):
                raise ValueError(
                    f"tar entry {name!r} is an absolute path — rejecting"
                )
            # Normalize and check for escape via ..
            normalized = os.path.normpath(name)
            if normalized.startswith("..") or "/../" in f"/{normalized}":
                raise ValueError(
                    f"tar entry {name!r} would escape extraction root — rejecting"
                )
            if member.issym() or member.islnk():
                link = member.linkname
                if os.path.isabs(link) or link.startswith("..") or "/../" in f"/{link}":
                    raise ValueError(
                        f"tar symlink {name!r} → {link!r} would escape root — rejecting"
                    )
