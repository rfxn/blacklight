"""Versioned defense manifest writer — YAML + SHA-256 sidecar (Day 4).

Writes curator/storage/manifest.yaml + manifest.yaml.sha256 atomically.
Pinned yaml.safe_dump parameters produce deterministic bytes; sidecar is
sha256sum-compatible (`sha256sum -c manifest.yaml.sha256` verifies).
"""

from __future__ import annotations

import hashlib
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import yaml
from pydantic import BaseModel, ConfigDict, Field


_DEFAULT_STORAGE = Path(os.environ.get("BL_STORAGE", "curator/storage"))


class Manifest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    version: int = Field(ge=1)
    generated_at: str
    rules: list[dict] = Field(default_factory=list)
    suggested_rules: list[dict] = Field(default_factory=list)
    exceptions: list[dict] = Field(default_factory=list)
    validation_test: Optional[str] = None


def _canonical_bytes(manifest: Manifest) -> bytes:
    """Deterministic YAML bytes. Pinned parameters — change breaks sidecar."""
    return yaml.safe_dump(
        manifest.model_dump(mode="json"),
        sort_keys=True,
        default_flow_style=False,
        allow_unicode=False,
        width=120,
    ).encode("utf-8")


def _load_current_version(storage_dir: Path) -> int:
    """Return current manifest version on disk, or 0 if absent / unparseable."""
    p = storage_dir / "manifest.yaml"
    if not p.exists():
        return 0
    try:
        data = yaml.safe_load(p.read_text(encoding="utf-8"))
        v = data.get("version", 0) if isinstance(data, dict) else 0
        return int(v) if isinstance(v, int) else 0
    except (yaml.YAMLError, OSError, ValueError):
        return 0


def publish(
    synth_result,
    *,
    storage_dir: Optional[Path] = None,
) -> int:
    """Write next manifest version. Monotonic: refuses rollback.

    synth_result is a curator.synthesizer.SynthesisResult (duck-typed to avoid
    import cycle — we read .rules / .suggested_rules / .exceptions /
    .validation_test attrs + model_dump()).
    """
    sd = storage_dir or _DEFAULT_STORAGE
    sd.mkdir(parents=True, exist_ok=True)
    new_version = _load_current_version(sd) + 1

    manifest = Manifest(
        version=new_version,
        generated_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        rules=[r.model_dump(mode="json") for r in synth_result.rules],
        suggested_rules=[r.model_dump(mode="json") for r in synth_result.suggested_rules],
        exceptions=[e.model_dump(mode="json") for e in synth_result.exceptions],
        validation_test=synth_result.validation_test,
    )

    body = _canonical_bytes(manifest)
    sha = hashlib.sha256(body).hexdigest()
    sidecar = f"{sha}  manifest.yaml\n".encode("ascii")

    stage_body = sd / "manifest.yaml.stage"
    stage_sidecar = sd / "manifest.yaml.sha256.stage"
    stage_body.write_bytes(body)
    stage_sidecar.write_bytes(sidecar)
    # Atomic rename — write sidecar FIRST (so a racing bl-pull that fetched
    # manifest before rename sees the OLD sidecar; bl-pull sidecar-first
    # fetch order prevents mismatch).
    stage_sidecar.rename(sd / "manifest.yaml.sha256")
    stage_body.rename(sd / "manifest.yaml")
    return new_version


def load(storage_dir: Optional[Path] = None) -> Manifest:
    """Parse manifest.yaml → Manifest (for tests + demo inspection)."""
    sd = storage_dir or _DEFAULT_STORAGE
    p = sd / "manifest.yaml"
    data = yaml.safe_load(p.read_text(encoding="utf-8"))
    return Manifest.model_validate(data)
