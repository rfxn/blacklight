"""Timeline hunter — correlates fs + log findings chronologically. Sequential after fs/log."""

from __future__ import annotations

from pathlib import Path

from curator.hunters.base import Finding, HunterInput, HunterOutput, run_sonnet_hunter

_PROMPT_PATH = Path(__file__).parent.parent.parent / "prompts" / "timeline-hunter.md"


def _merge_timeline(fs_findings: list[Finding], log_findings: list[Finding]) -> list[dict]:
    items: list[dict] = []
    for f in fs_findings:
        items.append({"source": "fs", "at": f.observed_at, "finding": f.finding, "refs": f.source_refs})
    for f in log_findings:
        items.append({"source": "log", "at": f.observed_at, "finding": f.finding, "refs": f.source_refs})
    items.sort(key=lambda x: x["at"])
    return items


def _format_timeline(items: list[dict]) -> str:
    if not items:
        return "No events to correlate (fs and log hunters returned no findings)."
    lines = ["Chronological event stream:"]
    for it in items:
        lines.append(f"  [{it['at']}] ({it['source']}) {it['finding']} refs={it['refs']}")
    return "\n".join(lines)


async def run(
    input: HunterInput,
    fs_out: HunterOutput,
    log_out: HunterOutput,
) -> HunterOutput:
    merged = _merge_timeline(fs_out.findings, log_out.findings)
    user_content = _format_timeline(merged)
    findings = await run_sonnet_hunter(_PROMPT_PATH, user_content)
    return HunterOutput(hunter="timeline", findings=findings)
