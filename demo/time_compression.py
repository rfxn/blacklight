"""Time-compression simulator for the Day-5 demo (HANDOFF.md §387-453).

Replays 4 pre-baked sim reports (host-4 day-5, host-7 day-7, host-1 day-10,
host-5 day-14) through the orchestrator with deliberate per-beat pacing,
producing the visible 90-second arc:

    Day 5  → revise CASE-2026-0007 to "campaign"
    Day 7  → predictive cred-harvest rule promoted (synthesize)
    Day 10 → host-1 anticipatory ModSec block reported
    Day 14 → host-5 skimmer → split to CASE-2026-0008

Modes:
    --mode=live   real Opus + Sonnet calls (default; recording mode)
    --mode=stub   BL_SKIP_LIVE=1 short-circuits (rehearsal + CI)

Pacing:
    --paced       (default) sleep between beats; ~90s total
    --fast        no sleep; for tests
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger("demo")

REPO_ROOT = Path(__file__).resolve().parent.parent
SIM_DIR = REPO_ROOT / "tests" / "fixtures" / "sim"


@dataclass(frozen=True)
class Beat:
    sim_day: int
    tar_name: str
    caption: str
    synthesize_after: bool  # invoke `python -m curator.synthesize <case_id>` after this beat
    sleep_after_sec: int   # paced-mode dwell


# Captions use {case_id} placeholders interpolated at run time from the
# actual case object the orchestrator returns — keeps the on-screen number
# honest regardless of allocator state. HANDOFF.md:452 narrates the split as
# "CASE-2026-0012" but the operator narration adapts to whatever the
# allocator produces (see split_case caption substitution below).
BEATS: tuple[Beat, ...] = (
    Beat(5,  "host-4-day5.tar.gz",
         "Two hosts, matching TTPs, shared C2. Revising to 'campaign'. Confidence 0.60.",
         synthesize_after=True, sleep_after_sec=12),
    Beat(7,  "host-7-day7.tar.gz",
         "Three hosts, same C2 across all. Confidence 0.85. Predictive cred-harvest rule promoted.",
         synthesize_after=True, sleep_after_sec=14),
    Beat(10, "host-1-day10.tar.gz",
         "Anticipatory rule fired on a host that was never compromised. "
         "Hypothesis confirmed. Actor reached second-stage, was blocked.",
         synthesize_after=False, sleep_after_sec=22),
    Beat(14, "host-5-day14.tar.gz",
         "Revising. host-5 is a separate actor, skimmer campaign. Splitting to {case_id}.",
         synthesize_after=False, sleep_after_sec=18),
)


def _check_preconditions(mode: str) -> None:
    if mode == "stub":
        os.environ["BL_SKIP_LIVE"] = "1"
        # Without BL_STUB_FINDINGS=1 the hunters return empty findings
        # (curator/hunters/base.py) so no case ever materializes and Day-14
        # captions degrade to "<no-case>". setdefault lets an operator who
        # wants the empty-findings path opt out by pre-setting the var to "0".
        os.environ.setdefault("BL_STUB_FINDINGS", "1")
        # host-5 is the skimmer campaign that should split on Day 14; tell the
        # case engine stub to return support_type="unrelated" for that host so
        # the split branch fires without a model call (rehearsal + CI path).
        os.environ.setdefault("BL_STUB_UNRELATED_HOST", "host-5")
        return
    if not os.environ.get("ANTHROPIC_API_KEY"):
        sys.stderr.write(
            "ANTHROPIC_API_KEY not set and --mode=live requested — refusing to proceed\n"
        )
        sys.exit(1)


def _verify_tars_present() -> None:
    missing = [b.tar_name for b in BEATS if not (SIM_DIR / b.tar_name).is_file()]
    if missing:
        sys.stderr.write(
            f"missing sim tars in {SIM_DIR}: {missing}\n"
            f"run: python tests/fixtures/sim/build_sim_tars.py\n"
        )
        sys.exit(2)


def _run_synthesize(case_id: str, mode: str) -> None:
    log.info("[demo] invoking synthesize for %s (mode=%s)", case_id, mode)
    env = os.environ.copy()
    if mode == "stub":
        env["BL_SKIP_LIVE"] = "1"
    result = subprocess.run(
        [sys.executable, "-m", "curator.synthesize", case_id],
        env=env, capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        log.warning("synthesize returned %d: %s", result.returncode, result.stderr)
    else:
        log.info("synthesize: %s", result.stdout.strip())


async def _play_beat(beat: Beat, mode: str, *, sleep: bool) -> "object | None":
    from curator.orchestrator import process_report
    tar_path = SIM_DIR / beat.tar_name
    case, partial = await process_report(tar_path)
    # Caption interpolation happens AFTER process_report so {case_id} reflects
    # the actual id the allocator/split produced (host-5 day-14 substitutes the
    # split-off case id; other beats are no-ops because the caption has no
    # placeholders).
    caption = beat.caption.format(case_id=(case.case_id if case is not None else "<no-case>"))
    print(f"[demo sim_day={beat.sim_day}] {caption}", flush=True)
    if case is not None:
        log.info("[demo] sim_day=%d → case %s", beat.sim_day, case.case_id)
    if beat.synthesize_after and case is not None:
        _run_synthesize(case.case_id, mode)
    if sleep:
        time.sleep(beat.sleep_after_sec)
    return case


async def _run(mode: str, paced: bool) -> int:
    for beat in BEATS:
        await _play_beat(beat, mode, sleep=paced)
    return 0


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="[%(name)s] %(message)s")
    p = argparse.ArgumentParser(prog="demo.time_compression")
    p.add_argument("--mode", choices=("live", "stub"), default="live")
    p.add_argument("--paced", action="store_true", default=True,
                   help="(default) sleep between beats")
    p.add_argument("--fast", action="store_false", dest="paced",
                   help="no sleep — for tests")
    args = p.parse_args()

    _check_preconditions(args.mode)
    _verify_tars_present()
    try:
        rc = asyncio.run(_run(args.mode, args.paced))
    except Exception as e:  # noqa: BLE001 — top-level CLI catch-all
        sys.stderr.write(f"[demo] FATAL: {type(e).__name__}: {e}\n")
        sys.exit(1)
    sys.exit(rc)


if __name__ == "__main__":
    main()
