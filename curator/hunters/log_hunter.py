"""Log hunter — regex-prefilters access.log + auth.log, calls Sonnet 4.6."""

from __future__ import annotations

import re
from pathlib import Path

from curator.hunters.base import Finding, HunterInput, HunterOutput, run_sonnet_hunter

_PROMPT_PATH = Path(__file__).parent.parent.parent / "prompts" / "log-hunter.md"

# Double-extension URL evasion: e.g., /x.php/image.jpg
_URL_EVASION = re.compile(r"\.(php|phtml|php5|php7)/[^\s\"]+\.(jpg|jpeg|png|gif|webp|ico)\b", re.IGNORECASE)
_SUSPICIOUS_TLD = re.compile(r"\.(top|pw|xyz|icu)(\b|[/:])", re.IGNORECASE)
_FAILED_AUTH = re.compile(r"\b(Failed password|authentication failure|Invalid user)\b")

_MAX_LINES_PER_LOG = 100


def _extract_suspicious(log_path: Path) -> list[dict]:
    if not log_path.exists():
        return []
    hits: list[dict] = []
    with log_path.open("r", encoding="utf-8", errors="replace") as f:
        for idx, line in enumerate(f):
            if len(hits) >= _MAX_LINES_PER_LOG:
                break
            match_kind = None
            if _URL_EVASION.search(line):
                match_kind = "url_evasion"
            elif _SUSPICIOUS_TLD.search(line):
                match_kind = "suspicious_callback"
            elif _FAILED_AUTH.search(line):
                match_kind = "auth_anomaly"
            if match_kind:
                # redacted excerpt: first 160 chars only
                hits.append({
                    "log": str(log_path.name),
                    "line_no": idx + 1,
                    "kind": match_kind,
                    "excerpt": line.strip()[:160],
                })
    return hits


def _format_excerpts(hits: list[dict]) -> str:
    if not hits:
        return "No suspicious log patterns matched."
    lines = ["Regex-prefiltered log hits:"]
    for h in hits:
        lines.append(f"  {h['log']}:{h['line_no']} [{h['kind']}] {h['excerpt']}")
    return "\n".join(lines)


async def run(input: HunterInput) -> HunterOutput:
    logs_root = input.work_root / "logs"
    all_hits: list[dict] = []
    if logs_root.exists():
        for log_file in sorted(logs_root.rglob("*.log")):
            all_hits.extend(_extract_suspicious(log_file))
    user_content = _format_excerpts(all_hits)
    findings = await run_sonnet_hunter(_PROMPT_PATH, user_content)
    return HunterOutput(hunter="log", findings=findings)
