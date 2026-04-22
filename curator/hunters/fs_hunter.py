"""Filesystem hunter — walks extracted work_root/fs/, flags candidates, calls Sonnet 4.6."""

from __future__ import annotations

import os
import stat
from datetime import datetime, timezone
from pathlib import Path

from curator.hunters.base import Finding, HunterInput, HunterOutput, run_sonnet_hunter

_PROMPT_PATH = Path(__file__).parent.parent.parent / "prompts" / "fs-hunter.md"

# Paths that are legitimate Magento framework locations — not candidates.
_BENIGN_PREFIXES = (
    "vendor/",
    "app/code/",
    "lib/internal/",
    "pub/static/",
    "generated/",
    "var/cache/",
)

_MAX_CANDIDATES = 50


def _is_suspicious(rel_path: str, stat_result: os.stat_result) -> bool:
    if any(rel_path.startswith(p) for p in _BENIGN_PREFIXES):
        return False
    if rel_path.endswith(".php"):
        return True
    mode = stat_result.st_mode
    if mode & (stat.S_ISUID | stat.S_ISGID):
        return True
    if mode & stat.S_IWOTH:
        return True
    return False


def _collect_candidates(fs_root: Path) -> list[dict]:
    candidates: list[dict] = []
    if not fs_root.exists():
        return candidates
    for root, dirs, files in os.walk(fs_root):
        for name in files:
            abs_path = Path(root) / name
            try:
                st = abs_path.stat()
            except OSError:
                continue
            rel = str(abs_path.relative_to(fs_root))
            if _is_suspicious(rel, st):
                candidates.append({
                    "path": f"fs/{rel}",
                    "size": st.st_size,
                    "mtime": datetime.fromtimestamp(st.st_mtime, timezone.utc).isoformat().replace("+00:00", "Z"),
                    "mode": oct(st.st_mode & 0o7777),
                })
                if len(candidates) >= _MAX_CANDIDATES:
                    return candidates
    return candidates


def _format_candidates(cands: list[dict]) -> str:
    if not cands:
        return "No filesystem candidates found."
    lines = ["Candidate list (path, size, mtime, mode):"]
    for c in cands:
        lines.append(f"  {c['path']} | {c['size']}B | mtime={c['mtime']} | mode={c['mode']}")
    return "\n".join(lines)


async def run(input: HunterInput) -> HunterOutput:
    fs_root = input.work_root / "fs"
    candidates = _collect_candidates(fs_root)
    user_content = _format_candidates(candidates)
    findings = await run_sonnet_hunter(_PROMPT_PATH, user_content)
    return HunterOutput(hunter="fs", findings=findings)
